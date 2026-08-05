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
    /// A queued follow-up became the active turn (timing reset for the UI;
    /// the user bubble was already shown when the message was queued).
    case followupStarted(String)
    case titleGenerated(String)
    case agentChanged(Agent)
    case modelChanged(String)
    /// File revert/redo performed; count = current redo depth (0 = not reverted).
    case revertStateChanged(restoredFiles: [String], redoDepth: Int)
    /// HTTP retry in progress (opencode SessionRetry indicator).
    case retrying(attempt: Int, delay: Int)
    /// Provider call resumed after retry.
    case retryResolved
    /// Files mutated by edit/write during this turn (for "Changed N files" UI).
    case changedFiles([ChangedFile])
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
    private var provider: any ModelProvider
    private var contextWindow: Int
    private var maxOutput: Int
    private let registry: ToolRegistry
    private let permissionEngine: PermissionEngine
    private let store: SessionStore
    private let todoStore: TodoStore
    private let snapshots = SnapshotStore()
    private var projectRoots: [URL]
    private let projectInstructions: String?
    private let workspaceID: String?
    private var systemPrompt: String
    /// Context appended after init (MCP recall); preserved across prompt rebuilds.
    private var extraSystemContext = ""

    private var history: [Message]
    /// Last known input tokens (post-compaction estimate after summarization).
    public private(set) var lastInputTokens = 0
    /// Last assistant turn's full token accounting (context tab).
    public private(set) var lastUsage: TokenUsage?
    private var currentTask: Task<Void, Never>?
    /// Steer queue: messages sent while a turn is running, drained between turns.
    private var followups: [String] = []
    private var busy = false
    /// Monotonic turn id: a cancelled turn only clears `busy` if it is still current.
    private var turnEpoch = 0
    private var titleTask: Task<Void, Never>?
    /// Files mutated by edit/write in the current turn ("Changed N files" UI).
    private var turnChangedFiles: Set<String> = []

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
        projectRoots: [URL],
        projectInstructions: String?,
        workspaceID: String? = nil
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
        self.projectRoots = projectRoots
        self.projectInstructions = projectInstructions
        self.workspaceID = workspaceID
        self.permissionEngine = PermissionEngine()

        self.systemPrompt = ""
        self.history = []
        var continuation: AsyncStream<SessionEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.continuation = continuation
        self.systemPrompt = Self.buildSystemPrompt(
            agent: agent, projectRoots: projectRoots, projectInstructions: projectInstructions,
            workspaceID: workspaceID
        )
    }

    private static func buildSystemPrompt(
        agent: Agent, projectRoots: [URL], projectInstructions: String?, workspaceID: String?
    ) -> String {
        var prompt = agent.systemPrompt + """

        Environment:
        - Project root (primary): \(projectRoots[0].path)
        """
        if projectRoots.count > 1 {
            prompt += "\n- Workspace roots (multi-root):"
            for (index, root) in projectRoots.enumerated() {
                prompt += index == 0
                    ? "\n  - \(root.path) (primary — plain relative paths resolve here)"
                    : "\n  - \(root.path) (address as \"\(root.lastPathComponent)/<path>\")"
            }
            prompt += """


            Multi-root workspace: to address a non-primary root, prefix paths with that \
            root's folder name (e.g. "\(projectRoots[1].lastPathComponent)/<path>"). \
            Read tools also fall back to other roots when a plain relative path is \
            missing from the primary root; writes always go to the primary root \
            unless prefixed.
            """
        }
        prompt += """

        - OS: macOS (Apple Silicon)
        - Date: \(ISO8601DateFormatter().string(from: Date()).prefix(10))
        """
        let memoryScope = workspaceID ?? "this workspace's id"
        prompt += """


        Bridged MCP tools (when the tool list includes them):
        - `*:graph_query` / `*:graph_explain` / `*:graph_path`: the workspace's code is \
        pre-indexed as a symbol graph. Use these to locate symbols and trace dependencies \
        INSTEAD of grep/read scans — they are cheaper and return relationships directly.
        - `*:graph_search`: semantic "where is X implemented" lookup over the same graph.

        Long-term memory (`*:search_memories`, `*:list_memories`, `*:store_memory`, \
        `*:update_memory`) — a learning loop across sessions:
        - Recall: check memories before re-deriving established facts. Use scope \
        "\(memoryScope)" for project facts, scope "global" for cross-project knowledge, \
        no scope filter when unsure.
        - Store: when you learn something durable, decide its scope — "global" if it \
        stays true in other projects (user preferences, general patterns), the workspace \
        id if it only holds for this codebase (architecture, build gotchas, decisions, \
        bug root causes). When in doubt, use the workspace id.
        - Triggers: after fixing a bug (root cause + fix), when the user corrects you \
        (their preference), when you discover non-obvious architecture, when a design \
        decision is made (with the why).
        - Hygiene: search before storing; if the topic already exists, update_memory \
        instead of duplicating. Keep memories short and factual.
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
            agent: newAgent, projectRoots: projectRoots, projectInstructions: projectInstructions,
            workspaceID: workspaceID
        ) + extraSystemContext
        continuation.yield(.agentChanged(newAgent))
    }

    /// Workspace folders changed (edit-workspace flow): live chats adopt the
    /// new root set and rebuild the system prompt's multi-root section.
    public func setProjectRoots(_ roots: [URL]) {
        guard !roots.isEmpty, roots != projectRoots else { return }
        projectRoots = roots
        systemPrompt = Self.buildSystemPrompt(
            agent: agent, projectRoots: roots, projectInstructions: projectInstructions,
            workspaceID: workspaceID
        ) + extraSystemContext
    }

    public func setModel(_ newModel: String) {
        model = newModel
        continuation.yield(.modelChanged(newModel))
    }

    /// Switch provider mid-session (model dialog picked a different vendor):
    /// history kept, next turn streams from the new provider.
    public func setProvider(_ newProvider: any ModelProvider, model newModel: String, contextWindow: Int, maxOutput: Int) {
        provider = newProvider
        model = newModel
        self.contextWindow = contextWindow
        self.maxOutput = maxOutput
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

    /// Current system prompt (context tab "System Prompt" card).
    public var currentSystemPrompt: String { systemPrompt }

    /// Append extra context to the system prompt (e.g. MCP recall injected
    /// after bridged tools connect, which happens after init).
    public func appendSystemContext(_ text: String) {
        extraSystemContext += "\n\n" + text
        systemPrompt += "\n\n" + text
    }

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
        let turnStarted = Date()
        var turnUsage: TokenUsage?
        let isFirstUserMessage = !history.contains { $0.role == .user }
        let userMessage = images.isEmpty ? Message.user(text) : Message.user(text, images: images)
        history.append(userMessage)
        try? await store.append(userMessage, sessionID: id)
        await snapshots.beginTurn()
        turnChangedFiles = []

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
            var usage: TokenUsage?
            var wasRetrying = false

            let stream = provider.stream(request)
            do {
                for try await event in stream {
                    if Task.isCancelled { return }
                    switch event {
                    case .retrying(let attempt, let delay):
                        wasRetrying = true
                        continuation.yield(.retrying(attempt: attempt, delay: delay))
                    case .textDelta(let delta):
                        if wasRetrying { wasRetrying = false; continuation.yield(.retryResolved) }
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
                    case .usage(let tokenUsage):
                        usage = tokenUsage
                        lastInputTokens = tokenUsage.input
                        lastUsage = tokenUsage
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

            // Final iteration = no tool calls follow; its assistant message carries
            // the whole turn's usage + duration (timeline footer after reload).
            let isFinal = finishReason != .toolCalls || completedCalls.isEmpty
            if let usage { turnUsage = (turnUsage ?? TokenUsage()).adding(usage) }

            // Persist assistant message.
            var parts: [Message.Part] = []
            if !assistantText.isEmpty { parts.append(.text(assistantText)) }
            for callID in completedCalls {
                guard let call = toolCalls[callID] else { continue }
                let arguments = (try? JSONDecoder().decode(JSONValue.self, from: Data(call.arguments.utf8))) ?? .object([:])
                parts.append(.toolCall(id: callID, name: call.name, arguments: arguments))
            }
            if !parts.isEmpty {
                let assistantMessage = Message(
                    role: .assistant,
                    parts: parts,
                    usage: isFinal ? turnUsage : nil,
                    durationMs: isFinal ? Int(Date().timeIntervalSince(turnStarted) * 1000) : nil
                )
                history.append(assistantMessage)
                try? await store.append(assistantMessage, sessionID: id)
            }

            if isFirstUserMessage { scheduleTitleGeneration(from: text) }

            guard finishReason == .toolCalls, !completedCalls.isEmpty else {
                busy = false
                if !turnChangedFiles.isEmpty {
                    continuation.yield(.changedFiles(await changedFilesWithDiffs()))
                }
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
        continuation.yield(.followupStarted(next))
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

    /// Build turn-end changed files with line diffs against pre-turn snapshots.
    private func changedFilesWithDiffs() async -> [ChangedFile] {
        var result: [ChangedFile] = []
        for path in turnChangedFiles.sorted() {
            let resolved = ToolContext(projectRoots: projectRoots, sessionID: id).resolve(path).path
            let oldText: String?
            if let original = await snapshots.originalContent(path: resolved) {
                oldText = original.flatMap { String(data: $0, encoding: .utf8) }
            } else {
                // Never recorded (e.g. permission flow raced) — fall back to no diff.
                oldText = nil
            }
            let newText = FileManager.default.contents(atPath: resolved)
                .flatMap { String(data: $0, encoding: .utf8) }
            result.append(LineDiff.changedFile(path: path, old: oldText, new: newText))
        }
        return result
    }

    private func executeWithPermission(
        tool: any AgentTool, arguments: JSONValue, callID: String
    ) async -> ToolResult {
        let preview = Self.preview(for: tool.name, arguments: arguments)
        // Snapshot + changed-file tracking before any edit/write mutation.
        if tool.name == "edit" || tool.name == "write",
           let path = arguments["path"]?.stringValue {
            let resolved = ToolContext(projectRoots: projectRoots, sessionID: id).resolve(path).path
            await snapshots.recordOriginal(path: resolved)
            turnChangedFiles.insert(path)
        }
        // Plan agent: write/edit allowed for plans files only (opencode parity).
        let effectiveAction = agent.permissions.action(for: tool.name, arguments: arguments, isPlan: agent.id == "plan")
        if effectiveAction == .allow {
            do {
                return try await tool.execute(arguments, ctx: ToolContext(projectRoots: projectRoots, sessionID: id))
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
        do {
            return try await tool.execute(arguments, ctx: ToolContext(projectRoots: projectRoots, sessionID: id))
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
        // Post-compaction estimate (chars/4, same as context tab) so the header
        // usage ring shows a realistic small value instead of disappearing.
        let remainingChars = history.reduce(0) { total, message in
            total + message.parts.reduce(0) { partTotal, part in
                switch part {
                case .text(let text): return partTotal + text.count
                case .toolResult(_, _, let output, _): return partTotal + output.count
                case .toolCall(_, _, let arguments):
                    let count = (try? JSONEncoder().encode(arguments).count) ?? 0
                    return partTotal + count
                case .image(let dataURL): return partTotal + dataURL.count
                }
            }
        }
        lastInputTokens = remainingChars / 4
        continuation.yield(.compacted)
    }
}
