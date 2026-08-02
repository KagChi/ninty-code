import Foundation

public enum SessionEvent: Sendable {
    case textDelta(String)
    case toolCallStarted(id: String, name: String)
    case toolCallUpdated(id: String, arguments: JSONValue)
    case toolResult(id: String, name: String, output: String, isError: Bool)
    case permissionAsked(PermissionRequest)
    case permissionResolved(id: String, reply: PermissionReply)
    case todosChanged([TodoItem])
    case compacted
    case queueChanged([String])
    case titleGenerated(String)
    case agentChanged(Agent)
    case modelChanged(String)
    /// File revert/redo performed; count = current redo depth (0 = not reverted).
    case revertStateChanged(restoredFiles: [String], redoDepth: Int)
    case error(String)
    case done(input: Int, output: Int)
}

public enum AgentSessionError: Error, Sendable {
    case providerFailed(String)
}

/// One live agent conversation: stream → tool calls → results → repeat.
/// opencode parity: steer queue (send while busy enqueues), mutable agent/model,
/// compaction at input-limit minus reserve, LLM session titles.
public actor AgentSession {
    public let id: String
    public private(set) var agent: Agent
    public private(set) var model: String
    public nonisolated let events: AsyncStream<SessionEvent>

    private let continuation: AsyncStream<SessionEvent>.Continuation
    private let provider: any ModelProvider
    private let contextWindow: Int
    private let maxOutput: Int
    private let registry: ToolRegistry
    private let permissionEngine: PermissionEngine
    private let store: SessionStore
    private let todoStore: TodoStore
    private let snapshots = SnapshotStore()
    private let projectRoot: URL
    private let projectInstructions: String?
    private var systemPrompt: String

    private var history: [Message]
    private var lastInputTokens = 0
    private var currentTask: Task<Void, Never>?
    /// Steer queue: messages sent while a turn is running, drained between turns.
    private var followups: [String] = []
    private var busy = false
    /// Monotonic turn id: a cancelled turn only clears `busy` if it is still current.
    private var turnEpoch = 0
    private var titleTask: Task<Void, Never>?

    public init(
        id: String = UUID().uuidString,
        agent: Agent,
        provider: any ModelProvider,
        model: String,
        contextWindow: Int,
        maxOutput: Int = 8_192,
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
        self.maxOutput = maxOutput
        self.registry = registry
        self.store = store
        self.todoStore = todoStore
        self.projectRoot = projectRoot
        self.projectInstructions = projectInstructions
        self.permissionEngine = PermissionEngine()

        self.systemPrompt = ""
        self.history = []
        var continuation: AsyncStream<SessionEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.continuation = continuation
        self.systemPrompt = Self.buildSystemPrompt(
            agent: agent, projectRoot: projectRoot, projectInstructions: projectInstructions
        )
    }

    private static func buildSystemPrompt(agent: Agent, projectRoot: URL, projectInstructions: String?) -> String {
        var prompt = agent.systemPrompt + """

        Environment:
        - Project root: \(projectRoot.path)
        - OS: macOS (Apple Silicon)
        - Date: \(ISO8601DateFormatter().string(from: Date()).prefix(10))
        """
        if let instructions = projectInstructions, !instructions.isEmpty {
            prompt += "\n\nProject instructions (AGENTS.md):\n\(instructions)"
        }
        return prompt
    }

    /// Resume an existing session from disk.
    public func restoreHistory(_ messages: [Message]) {
        history = messages
    }

    // MARK: - Public API

    /// Start a user turn, or steer: if a turn is running, queue and return.
    /// opencode default is "steer" — the queued message is sent when the turn ends.
    public func send(_ text: String, images: [String] = []) {
        if busy {
            followups.append(text)
            continuation.yield(.queueChanged(followups))
            return
        }
        startTurn(text, images: images)
    }

    /// Pull a queued follow-up back out (user edited it into the composer).
    public func dequeueFollowup(at index: Int) -> String? {
        guard followups.indices.contains(index) else { return nil }
        let item = followups.remove(at: index)
        continuation.yield(.queueChanged(followups))
        return item
    }

    /// Send the head of the queue immediately (interrupts current turn like opencode "Send now").
    public func sendFollowupNow(at index: Int) {
        guard let item = dequeueFollowup(at: index) else { return }
        currentTask?.cancel()
        busy = false
        startTurn(item)
    }

    /// Interrupt the current turn. Queue is paused, NOT cleared (opencode Esc semantics).
    public func abort() {
        currentTask?.cancel()
        busy = false
        Task { await permissionEngine.rejectAll() }
        continuation.yield(.queueChanged(followups))
    }

    /// Switch agent mid-session: history kept, next message carries new agent.
    public func setAgent(_ newAgent: Agent) {
        agent = newAgent
        systemPrompt = Self.buildSystemPrompt(
            agent: newAgent, projectRoot: projectRoot, projectInstructions: projectInstructions
        )
        continuation.yield(.agentChanged(newAgent))
    }

    public func setModel(_ newModel: String) {
        model = newModel
        continuation.yield(.modelChanged(newModel))
    }

    public func replyPermission(_ id: String, _ reply: PermissionReply) async {
        continuation.yield(.permissionResolved(id: id, reply: reply))
        await permissionEngine.reply(id, reply)
    }

    /// Auto-accept mode (⇧⌘A): every ask is replied "once" without UI.
    public func setAutoAccept(_ enabled: Bool) async {
        await permissionEngine.setAutoAccept(enabled)
    }

    // MARK: - Revert (undo/redo)

    public var redoDepth: Int { get async { await snapshots.redoDepth } }

    /// /undo: restore files changed during the last user turn. Caller hides the messages.
    public func revert() async -> [String] {
        if busy { abort() }
        let restored = await snapshots.revert()
        continuation.yield(.revertStateChanged(restoredFiles: restored, redoDepth: await snapshots.redoDepth))
        return restored
    }

    /// /redo: re-apply the most recently reverted turn's files.
    public func unrevert() async -> [String] {
        let restored = await snapshots.redo()
        continuation.yield(.revertStateChanged(restoredFiles: restored, redoDepth: await snapshots.redoDepth))
        return restored
    }

    /// New prompt while reverted is permanent: drop redo stash + delete hidden messages.
    public func commitRevertedState(keepingMessages keepCount: Int) async {
        await snapshots.clearReverted()
        if keepCount < history.count {
            history = Array(history.prefix(keepCount))
            try? await store.truncate(keepingMessages: keepCount, sessionID: id)
        }
        continuation.yield(.revertStateChanged(restoredFiles: [], redoDepth: 0))
    }

    private func startTurn(_ text: String, images: [String] = []) {
        busy = true
        turnEpoch += 1
        let epoch = turnEpoch
        currentTask = Task { await self.runTurn(text, images: images, epoch: epoch) }
    }

    // MARK: - Turn loop

    private func runTurn(_ text: String, images: [String] = [], epoch: Int) async {
        let isFirstUserMessage = !history.contains { $0.role == .user }
        let userMessage = images.isEmpty ? Message.user(text) : Message.user(text, images: images)
        history.append(userMessage)
        try? await store.append(userMessage, sessionID: id)
        await snapshots.beginTurn()

        // Only the current epoch clears busy — a cancelled superseded turn must not.
        defer { if epoch == turnEpoch { busy = false } }

        while !Task.isCancelled {
            await compactIfNeeded()

            let request = ChatRequest(
                model: model,
                system: systemPrompt,
                messages: history,
                tools: registry.definitions(excluding: agent.hiddenTools)
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
                busy = false
                drainQueue()
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

            if isFirstUserMessage { scheduleTitleGeneration(from: text) }

            guard finishReason == .toolCalls, !completedCalls.isEmpty else {
                busy = false
                continuation.yield(.done(input: usage?.input ?? 0, output: usage?.output ?? 0))
                drainQueue()
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
                continuation.yield(.toolCallUpdated(id: callID, arguments: arguments))
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

    /// Steer drain: if follow-ups queued while busy, send the head as the next turn.
    private func drainQueue() {
        guard !busy, !followups.isEmpty else { return }
        let next = followups.removeFirst()
        continuation.yield(.queueChanged(followups))
        startTurn(next)
    }

    /// LLM session title, opencode-style: fired once after first user message's turn.
    private func scheduleTitleGeneration(from firstPrompt: String) {
        titleTask?.cancel()
        titleTask = Task { [provider, continuation] in
            let request = ChatRequest(
                model: self.model,
                system: "Write a ≤6-word title for this conversation. Output the title only, no quotes, no punctuation at the end.",
                messages: [.user(firstPrompt)]
            )
            var title = ""
            do {
                for try await event in provider.stream(request) {
                    if Task.isCancelled { return }
                    if case .textDelta(let delta) = event { title += delta }
                }
            } catch { return }
            let cleaned = title
                .components(separatedBy: .newlines)
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !cleaned.isEmpty else { return }
            let truncated = cleaned.count > 97 ? String(cleaned.prefix(97)) + "..." : cleaned
            try? await self.store.updateTitle(truncated, sessionID: self.id)
            continuation.yield(.titleGenerated(truncated))
        }
    }

    private func executeWithPermission(
        tool: any AgentTool, arguments: JSONValue, callID: String
    ) async -> ToolResult {
        let preview = Self.preview(for: tool.name, arguments: arguments)
        // Plan agent: write/edit allowed for plans files only (opencode parity).
        let effectiveAction = agent.permissions.action(for: tool.name, arguments: arguments, isPlan: agent.id == "plan")
        if effectiveAction == .allow {
            do {
                if tool.name == "edit" || tool.name == "write",
                   let path = arguments["path"]?.stringValue {
                    await snapshots.recordOriginal(path: ToolContext(projectRoot: projectRoot, sessionID: id).resolve(path).path)
                }
                return try await tool.execute(arguments, ctx: ToolContext(projectRoot: projectRoot, sessionID: id))
            } catch {
                return .error("Tool error: \(error.localizedDescription)")
            }
        }
        do {
            try await permissionEngine.authorize(
                tool: tool.name, arguments: arguments, preview: preview,
                rules: agent.permissions,
                onAsk: { [continuation] request in continuation.yield(.permissionAsked(request)) }
            )
        } catch {
            return .error("Permission denied: \(tool.name)")
        }
        // Snapshot before mutation (opencode revert support).
        if tool.name == "edit" || tool.name == "write",
           let path = arguments["path"]?.stringValue {
            await snapshots.recordOriginal(path: ToolContext(projectRoot: projectRoot, sessionID: id).resolve(path).path)
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

    /// opencode usable-limit: contextWindow - min(20_000, maxOutput).
    private var usableInputLimit: Int {
        contextWindow - min(20_000, maxOutput)
    }

    private func compactIfNeeded() async {
        guard contextWindow > 0, lastInputTokens >= usableInputLimit, history.count > 6 else { return }
        await compactNow()
    }

    /// Manual (/compact) or automatic compaction. Summarize all but recent tail.
    public func compactNow() async {
        let summaryRequest = ChatRequest(
            model: model,
            system: "Summarize the conversation so far for continuation. Preserve decisions made, file paths touched, and open tasks. Be terse.",
            messages: history.dropLast(2) + [.user("Summarize our work so far.")]
        )
        var summary = ""
        do {
            for try await event in provider.stream(summaryRequest) {
                if Task.isCancelled { return }
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
