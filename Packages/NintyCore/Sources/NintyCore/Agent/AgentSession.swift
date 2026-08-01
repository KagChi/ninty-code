import Foundation

public enum SessionEvent: Sendable {
    case textDelta(String)
    case toolCallStarted(id: String, name: String)
    case toolResult(id: String, name: String, output: String, isError: Bool)
    case permissionAsked(PermissionRequest)
    case permissionResolved(id: String, reply: PermissionReply)
    case todosChanged([TodoItem])
    case compacted
    case error(String)
    case done(input: Int, output: Int)
}

public enum AgentSessionError: Error, Sendable {
    case providerFailed(String)
}

/// One live agent conversation: stream → tool calls → results → repeat.
public actor AgentSession {
    public let id: String
    public let agent: Agent
    public nonisolated let events: AsyncStream<SessionEvent>

    private let continuation: AsyncStream<SessionEvent>.Continuation
    private let provider: any ModelProvider
    private let model: String
    private let contextWindow: Int
    private let registry: ToolRegistry
    private let permissionEngine: PermissionEngine
    private let store: SessionStore
    private let todoStore: TodoStore
    private let projectRoot: URL
    private let systemPrompt: String

    private var history: [Message]
    private var lastInputTokens = 0
    private var currentTask: Task<Void, Never>?

    public init(
        id: String = UUID().uuidString,
        agent: Agent,
        provider: any ModelProvider,
        model: String,
        contextWindow: Int,
        registry: ToolRegistry,
        store: SessionStore,
        todoStore: TodoStore,
        projectRoot: URL,
        projectInstructions: String?
    ) {
        self.id = id
        self.agent = agent
        self.provider = provider
        self.model = model
        self.contextWindow = contextWindow
        self.registry = registry
        self.store = store
        self.todoStore = todoStore
        self.projectRoot = projectRoot
        self.permissionEngine = PermissionEngine()

        var prompt = agent.systemPrompt + """

        Environment:
        - Project root: \(projectRoot.path)
        - OS: macOS (Apple Silicon)
        - Date: \(ISO8601DateFormatter().string(from: Date()).prefix(10))
        """
        if let instructions = projectInstructions, !instructions.isEmpty {
            prompt += "\n\nProject instructions (AGENTS.md):\n\(instructions)"
        }
        self.systemPrompt = prompt

        self.history = []
        var continuation: AsyncStream<SessionEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    /// Resume an existing session from disk.
    public func restoreHistory(_ messages: [Message]) {
        history = messages
    }

    // MARK: - Public API

    /// Start a user turn. Returns immediately; progress arrives via `events`.
    public func send(_ text: String) {
        currentTask?.cancel()
        currentTask = Task { await self.runTurn(text) }
    }

    public func replyPermission(_ id: String, _ reply: PermissionReply) async {
        continuation.yield(.permissionResolved(id: id, reply: reply))
        await permissionEngine.reply(id, reply)
    }

    public func abort() {
        currentTask?.cancel()
        Task { await permissionEngine.rejectAll() }
    }

    // MARK: - Turn loop

    private func runTurn(_ text: String) async {
        let userMessage = Message.user(text)
        history.append(userMessage)
        try? await store.append(userMessage, sessionID: id)

        while !Task.isCancelled {
            await compactIfNeeded()

            let request = ChatRequest(
                model: model,
                system: systemPrompt,
                messages: history,
                tools: registry.definitions(excluding: agent.permissions.deniedTools)
            )

            var assistantText = ""
            var toolCalls: [String: (name: String, arguments: String)] = [:]
            var completedCalls: [String] = []
            var finishReason: FinishReason = .stop
            var usage: (input: Int, output: Int)?

            let stream = provider.stream(request)
            do {
                for try await event in stream {
                    if Task.isCancelled { return }
                    switch event {
                    case .textDelta(let delta):
                        assistantText += delta
                        continuation.yield(.textDelta(delta))
                    case .toolCallStart(let id, let name):
                        if toolCalls[id] == nil {
                            toolCalls[id] = (name: name, arguments: "")
                            if !name.isEmpty {
                                continuation.yield(.toolCallStarted(id: id, name: name))
                            }
                        } else if !name.isEmpty, toolCalls[id]?.name.isEmpty == true {
                            toolCalls[id]?.name = name
                            continuation.yield(.toolCallStarted(id: id, name: name))
                        }
                    case .toolCallDelta(let id, let fragment):
                        toolCalls[id]?.arguments += fragment
                    case .toolCallEnd(let id):
                        if !completedCalls.contains(id) { completedCalls.append(id) }
                    case .usage(let input, let output):
                        usage = (input, output)
                        lastInputTokens = input
                    case .finish(let reason):
                        finishReason = reason
                    }
                }
            } catch {
                continuation.yield(.error(error.localizedDescription))
                return
            }

            // Persist assistant message.
            var parts: [Message.Part] = []
            if !assistantText.isEmpty { parts.append(.text(assistantText)) }
            for callID in completedCalls {
                guard let call = toolCalls[callID] else { continue }
                let arguments = (try? JSONDecoder().decode(JSONValue.self, from: Data(call.arguments.utf8))) ?? .object([:])
                parts.append(.toolCall(id: callID, name: call.name, arguments: arguments))
            }
            if !parts.isEmpty {
                let assistantMessage = Message(role: .assistant, parts: parts)
                history.append(assistantMessage)
                try? await store.append(assistantMessage, sessionID: id)
            }

            guard finishReason == .toolCalls, !completedCalls.isEmpty else {
                continuation.yield(.done(input: usage?.input ?? 0, output: usage?.output ?? 0))
                return
            }

            // Execute tool calls sequentially.
            var results: [Message.Part] = []
            for callID in completedCalls {
                if Task.isCancelled { return }
                guard let call = toolCalls[callID],
                      let tool = registry.tool(named: call.name) else {
                    results.append(.toolResult(id: callID, name: toolCalls[callID]?.name ?? "unknown",
                                               output: "Unknown tool", isError: true))
                    continue
                }
                let arguments = (try? JSONDecoder().decode(JSONValue.self, from: Data(call.arguments.utf8))) ?? .object([:])
                let result = await executeWithPermission(
                    tool: tool, arguments: arguments, callID: callID
                )
                results.append(.toolResult(id: callID, name: call.name,
                                           output: result.output, isError: result.isError))
                continuation.yield(.toolResult(id: callID, name: call.name,
                                               output: result.output, isError: result.isError))
                if tool.name == "todowrite" {
                    continuation.yield(.todosChanged(await todoStore.items))
                }
            }
            let toolMessage = Message(role: .tool, parts: results)
            history.append(toolMessage)
            try? await store.append(toolMessage, sessionID: id)
        }
    }

    private func executeWithPermission(
        tool: any AgentTool, arguments: JSONValue, callID: String
    ) async -> ToolResult {
        let preview = Self.preview(for: tool.name, arguments: arguments)
        do {
            try await permissionEngine.authorize(
                tool: tool.name, arguments: arguments, preview: preview,
                rules: agent.permissions,
                onAsk: { [continuation] request in continuation.yield(.permissionAsked(request)) }
            )
        } catch {
            return .error("Permission denied: \(tool.name)")
        }
        do {
            return try await tool.execute(arguments, ctx: ToolContext(projectRoot: projectRoot, sessionID: id))
        } catch {
            return .error("Tool error: \(error.localizedDescription)")
        }
    }

    static func preview(for tool: String, arguments: JSONValue) -> String {
        switch tool {
        case "bash":
            return arguments["command"]?.stringValue ?? tool
        case "read", "write", "edit":
            return arguments["path"]?.stringValue ?? tool
        case "grep", "glob":
            return arguments["pattern"]?.stringValue ?? tool
        default:
            return tool
        }
    }

    // MARK: - Compaction

    private func compactIfNeeded() async {
        guard contextWindow > 0, lastInputTokens > Int(Double(contextWindow) * 0.9),
              history.count > 6 else { return }
        let summaryRequest = ChatRequest(
            model: model,
            system: "Summarize the conversation so far for continuation. Preserve decisions made, file paths touched, and open tasks. Be terse.",
            messages: history.dropLast(2) + [.user("Summarize our work so far.")]
        )
        var summary = ""
        do {
            for try await event in provider.stream(summaryRequest) {
                if case .textDelta(let delta) = event { summary += delta }
            }
        } catch {
            return // keep full history on summarization failure
        }
        guard !summary.isEmpty else { return }
        let tail = history.suffix(4)
        history = [.assistant("Conversation summary:\n\(summary)")] + tail
        lastInputTokens = 0
        continuation.yield(.compacted)
    }
}
