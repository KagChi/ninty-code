import Foundation
import Observation
import NintyCore

// MARK: - Display models

struct ToolCallDisplay: Identifiable, Equatable {
    enum Status: Equatable { case running, done, failed }
    var id: String
    var name: String
    var arguments: JSONValue
    var output: String?
    var isError: Bool = false
    var status: Status = .running
}

/// One rendered unit inside a message, in emission order (opencode part order):
/// text → toolCall → text → toolCall. Tool results update their call in place.
enum DisplayBlock: Equatable {
    case text(String)
    case toolCall(ToolCallDisplay)
}

struct DisplayMessage: Identifiable, Equatable {
    var id = UUID()
    var role: Role
    var blocks: [DisplayBlock] = []
    var timestamp: Date = Date()
    /// Timeline marker (e.g. "Compaction") — rendered as a divider, not a bubble.
    var isMarker = false
    /// Attached images (data URLs).
    var images: [String] = []

    init(role: Role, text: String = "", blocks: [DisplayBlock]? = nil, isMarker: Bool = false, images: [String] = []) {
        self.role = role
        self.blocks = blocks ?? (text.isEmpty ? [] : [.text(text)])
        self.isMarker = isMarker
        self.images = images
    }

    /// Joined text blocks (compat: fork, previews, copy).
    var text: String {
        blocks.compactMap { if case .text(let t) = $0 { return t }; return nil }.joined()
    }

    /// All tool call blocks (compat: tool status checks).
    var toolCalls: [ToolCallDisplay] {
        blocks.compactMap { if case .toolCall(let c) = $0 { return c }; return nil }
    }

    /// Tool result landed: update its call block in place (preserves order),
    /// or append an orphan-result block if the call wasn't seen.
    mutating func updateToolCallBlock(id: String, output: String, isError: Bool) {
        for index in blocks.indices.reversed() {
            guard case .toolCall(var call) = blocks[index], call.id == id else { continue }
            call.output = output
            call.isError = isError
            call.status = isError ? .failed : .done
            blocks[index] = .toolCall(call)
            return
        }
        blocks.append(.toolCall(ToolCallDisplay(
            id: id, name: "", arguments: .object([:]),
            output: output, isError: isError, status: isError ? .failed : .done
        )))
    }
}

// MARK: - ChatStore

@Observable
@MainActor
final class ChatStore {
    var messages: [DisplayMessage] = []
    var streaming = false
    var pendingPermission: PermissionRequest?
    var todos: [TodoItem] = []
    var compacted = false
    var lastError: String?
    /// Steer queue: messages sent while streaming, drained by the session.
    var followups: [String] = []
    /// Messages hidden by /undo (not deleted — opencode revert semantics).
    var revertedMessages: [DisplayMessage] = []
    /// HTTP retry in progress: (attempt, delay seconds). Nil = not retrying.
    var retry: (attempt: Int, delay: Int)?
    /// Files changed during the last completed turn ("Changed N files" accordion).
    var changedFiles: [String] = []
    /// Set by AppState: whether this tab is currently visible.
    var isActive = false
    /// Background activity marker (opencode unread dot).
    var hasUnread = false
    /// Last turn's token usage (context meter in session header).
    var lastInputTokens = 0
    var contextWindow = 128_000
    /// Full token accounting of the last turn (context tab).
    private(set) var lastUsage: TokenUsage?
    /// Live system prompt from the session (context tab card).
    private(set) var systemPrompt = ""

    let sessionID: String
    let projectRoot: URL
    private(set) var agent: Agent
    private(set) var model: String
    /// Full "provider/model" reference — persisted in meta so reopening restores the provider too.
    private(set) var modelReference: String

    private let session: AgentSession
    private let store: SessionStore
    private var metaCreated = false
    nonisolated(unsafe) private var eventTask: Task<Void, Never>? // deinit access only
    private let onChange: () -> Void

    init(
        sessionID: String,
        agent: Agent,
        provider: any ModelProvider,
        model: String,
        modelReference: String,
        contextWindow: Int,
        maxOutput: Int = 8_192,
        projectRoot: URL,
        projectInstructions: String?,
        mcpManager: MCPManager?,
        onChange: @escaping () -> Void
    ) {
        self.sessionID = sessionID
        self.agent = agent
        self.model = model
        self.modelReference = modelReference
        self.projectRoot = projectRoot
        self.contextWindow = contextWindow
        self.onChange = onChange

        let todoStore = TodoStore()
        var registry = ToolRegistry.builtIns(todoStore: todoStore)
        if let mcpManager {
            // Bridge MCP tools synchronously unavailable; kick off async registration.
            Task {
                for tool in await mcpManager.bridgedTools() {
                    try? registry.register(tool)
                }
            }
        }
        let store = SessionStore(projectRoot: projectRoot)
        self.store = store
        self.session = AgentSession(
            id: sessionID,
            agent: agent,
            provider: provider,
            model: model,
            contextWindow: contextWindow,
            maxOutput: maxOutput,
            registry: registry,
            store: store,
            todoStore: todoStore,
            projectRoot: projectRoot,
            projectInstructions: projectInstructions
        )
        // Restore existing history when reopening a session.
        Task {
            systemPrompt = await session.currentSystemPrompt
            if let loaded = try? await store.load(id: sessionID) {
                self.metaCreated = true
                await session.restoreHistory(loaded.messages)
                self.messages = loaded.messages.map(Self.displayMessage(from:))
            }
        }
        subscribe()
    }

    deinit { eventTask?.cancel() }

    private static func displayMessage(from message: Message) -> DisplayMessage {
        var display = DisplayMessage(role: message.role)
        for part in message.parts {
            switch part {
            case .text(let text):
                if case .text(let existing) = display.blocks.last {
                    display.blocks[display.blocks.count - 1] = .text(existing + text)
                } else {
                    display.blocks.append(.text(text))
                }
            case .image(let dataURL):
                display.images.append(dataURL)
            case .toolCall(let id, let name, let arguments):
                display.blocks.append(.toolCall(ToolCallDisplay(id: id, name: name, arguments: arguments, status: .done)))
            case .toolResult(let id, _, let output, let isError):
                display.updateToolCallBlock(id: id, output: output, isError: isError)
            }
        }
        return display
    }

    // MARK: - Event subscription

    private func subscribe() {
        let stream = session.events
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await MainActor.run { self.handle(event) }
            }
        }
    }

    private func handle(_ event: SessionEvent) {
        if !isActive { hasUnread = true }
        switch event {
        case .textDelta(let delta):
            // opencode: a new assistant message starts per loop iteration — text
            // after tool results is a new bubble, not appended to the old one.
            ensureAssistantMessage()
            var last = messages.count - 1
            if case .toolCall(let call) = messages[last].blocks.last, call.status != .running {
                messages.append(DisplayMessage(role: .assistant))
                last = messages.count - 1
            }
            if case .text(let existing) = messages[last].blocks.last {
                messages[last].blocks[messages[last].blocks.count - 1] = .text(existing + delta)
            } else {
                messages[last].blocks.append(.text(delta))
            }
        case .toolCallStarted(let id, let name):
            ensureAssistantMessage()
            messages[messages.count - 1].blocks.append(
                .toolCall(ToolCallDisplay(id: id, name: name, arguments: .object([:])))
            )
        case .toolCallUpdated(let id, let arguments):
            guard let last = messages.indices.last else { return }
            for index in messages[last].blocks.indices.reversed() {
                guard case .toolCall(var call) = messages[last].blocks[index], call.id == id else { continue }
                call.arguments = arguments
                messages[last].blocks[index] = .toolCall(call)
                return
            }
        case .toolResult(let id, let name, let output, let isError):
            updateToolCall(id: id, name: name, output: output, isError: isError)
        case .permissionAsked(let request):
            pendingPermission = request
        case .permissionResolved:
            pendingPermission = nil
        case .todosChanged(let items):
            todos = items
        case .compacted:
            compacted = true
            messages.append(DisplayMessage(role: .assistant, text: "Compaction", isMarker: true))
        case .queueChanged(let queue):
            followups = queue
        case .revertStateChanged:
            break // revertedMessages array is the UI source of truth
        case .retrying(let attempt, let delay):
            retry = (attempt, delay)
        case .retryResolved:
            retry = nil
        case .changedFiles(let files):
            changedFiles = files
        case .titleGenerated:
            onChange() // sidebar refresh picks up new title
        case .agentChanged(let newAgent):
            agent = newAgent
        case .modelChanged(let newModel):
            model = newModel
        case .error(let message):
            lastError = message
            streaming = false
            retry = nil
        case .done(let input, _):
            lastInputTokens = input
            streaming = false
            pendingPermission = nil
            retry = nil
            Task { lastUsage = await session.lastUsage }
            onChange()
        }
    }

    private func ensureAssistantMessage() {
        if messages.last?.role != .assistant {
            messages.append(DisplayMessage(role: .assistant))
        }
    }

    private func updateToolCall(id: String, name: String, output: String, isError: Bool) {
        guard let last = messages.indices.last else { return }
        let known = messages[last].blocks.contains {
            if case .toolCall(let call) = $0 { return call.id == id }
            return false
        }
        if known {
            messages[last].updateToolCallBlock(id: id, output: output, isError: isError)
        } else {
            messages[last].blocks.append(.toolCall(ToolCallDisplay(
                id: id, name: name, arguments: .object([:]),
                output: output, isError: isError, status: isError ? .failed : .done
            )))
        }
    }

    // MARK: - Actions

    /// opencode steer semantics: sending while streaming queues the message
    /// (server-side in the session); the UI mirrors the queue as a dock.
    /// Sending while reverted permanently deletes the reverted messages.
    func send(_ text: String, images: [String] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty else { return }
        lastError = nil
        if !revertedMessages.isEmpty {
            revertedMessages = []
            // Everything currently visible (non-marker) is persisted history to keep.
            let keep = messages.filter { !$0.isMarker }.count
            Task { await session.commitRevertedState(keepingMessages: keep) }
        }
        if streaming {
            Task { await session.send(trimmed, images: images) } // session enqueues
            return
        }
        messages.append(DisplayMessage(role: .user, text: trimmed, images: images))
        streaming = true
        // First message creates the on-disk meta so the session lists in the sidebar.
        if !metaCreated {
            metaCreated = true
            let title = String(trimmed.prefix(60))
            Task {
                try? await store.create(id: sessionID, title: title, agentID: agent.id, model: modelReference)
                onChange()
            }
        }
        Task { await session.send(trimmed, images: images) }
    }

    /// Set when a queued follow-up is pulled back for editing; composer consumes + clears it.
    var restoredDraft: String?
    /// /fork dialog visibility.
    var showForkDialog = false

    /// Pull a queued follow-up back into the composer for editing.
    func editFollowup(at index: Int) {
        Task {
            if let text = await session.dequeueFollowup(at: index) {
                restoredDraft = text
            }
        }
    }

    func sendFollowupNow(at index: Int) {
        messages.append(DisplayMessage(role: .user, text: followups[index]))
        streaming = true
        Task { await session.sendFollowupNow(at: index) }
    }

    func abort() {
        Task { await session.abort() }
        streaming = false
        pendingPermission = nil
    }

    /// ⇧⌘A auto-accept: every permission ask auto-replied "once" (opencode per-session toggle).
    var autoAccept = false {
        didSet { Task { await session.setAutoAccept(autoAccept) } }
    }

    // MARK: - Undo / redo (opencode revert semantics)

    /// /undo: hide messages from the last user message onward + restore files to
    /// before that turn. Reverted prompt text returns to the composer.
    func undo() {
        guard !streaming, let boundary = messages.lastIndex(where: { $0.role == .user && !$0.isMarker }) else { return }
        let reverted = Array(messages[boundary...])
        restoredDraft = reverted.first?.text
        revertedMessages.append(contentsOf: reverted)
        messages.removeLast(messages.count - boundary)
        Task { await session.revert() }
    }

    /// /redo: restore the next batch of reverted messages (up to and including the
    /// next user message) + re-apply that turn's file changes.
    func redo() {
        guard !revertedMessages.isEmpty else { return }
        // Restore through the next user message boundary (or everything if none).
        var end = revertedMessages.count
        for (index, message) in revertedMessages.enumerated() where index > 0 {
            if message.role == .user && !message.isMarker { end = index; break }
        }
        let restored = Array(revertedMessages.prefix(end))
        revertedMessages.removeFirst(end)
        messages.append(contentsOf: restored)
        Task { await session.unrevert() }
    }

    /// Restore one specific reverted message (and everything before it), dock-style.
    func restoreReverted(upTo index: Int) {
        guard revertedMessages.indices.contains(index) else { return }
        let restored = Array(revertedMessages.prefix(through: index))
        revertedMessages.removeFirst(index + 1)
        messages.append(contentsOf: restored)
        Task { await session.unrevert() }
    }

    /// Switch agent in place — history kept, next message uses the new agent.
    func setAgent(_ newAgent: Agent) {
        Task { await session.setAgent(newAgent) }
        persistSelection(agentID: newAgent.id, model: modelReference)
    }

    /// Switch model in place. Provider is rebuilt by AppState and swapped too —
    /// without this the stream would keep hitting the old vendor's endpoint.
    func setModel(provider: any ModelProvider, reference: String, contextWindow: Int, maxOutput: Int) {
        guard let (_, modelID) = ProviderRegistry.split(reference) else { return }
        model = modelID
        modelReference = reference
        self.contextWindow = contextWindow
        Task { await session.setProvider(provider, model: modelID, contextWindow: contextWindow, maxOutput: maxOutput) }
        persistSelection(agentID: agent.id, model: reference)
    }

    private func persistSelection(agentID: String, model: String) {
        guard metaCreated else { return }
        Task { try? await store.updateSelection(agentID: agentID, model: model, sessionID: sessionID) }
    }

    /// Cancel stream + turn; call before discarding so nothing retains the session.
    func teardown() {
        eventTask?.cancel()
        Task { await session.abort() }
    }

    func replyPermission(_ reply: PermissionReply) {
        guard let request = pendingPermission else { return }
        pendingPermission = nil
        Task { await session.replyPermission(request.id, reply) }
    }

    // MARK: - Slash commands

    /// /compact — summarize context with the current model.
    func compact() {
        Task { await session.compactNow() }
    }

    /// Rename the session (sidecar meta).
    func rename(_ title: String) {
        Task { try? await store.updateTitle(title, sessionID: sessionID) }
    }

    /// Shell mode submit: run via BashTool, output as a tool-style message.
    func runShell(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(DisplayMessage(role: .user, text: trimmed))
        streaming = true
        if !metaCreated {
            metaCreated = true
            Task {
                try? await store.create(
                    id: sessionID, title: "$ \(trimmed.prefix(55))",
                    agentID: agent.id, model: modelReference
                )
                onChange()
            }
        }
        Task {
            let callID = UUID().uuidString
            let display = ToolCallDisplay(id: callID, name: "bash",
                                          arguments: .object(["command": .string(trimmed)]))
            messages.append(DisplayMessage(role: .assistant, blocks: [.toolCall(display)]))
            do {
                let result = try await BashTool().execute(
                    ["command": .string(trimmed)],
                    ctx: ToolContext(projectRoot: projectRoot, sessionID: sessionID)
                )
                updateToolCall(id: callID, name: "bash", output: result.output, isError: result.isError)
            } catch {
                updateToolCall(id: callID, name: "bash", output: error.localizedDescription, isError: true)
            }
            streaming = false
        }
    }

    /// /fork: new session id with history up to (excluding) the given user message index.
    /// Returns (newSessionID, promptToRestore).
    func fork(beforeUserMessageAt displayIndex: Int) async -> (String, String)? {
        guard messages.indices.contains(displayIndex),
              messages[displayIndex].role == .user else { return nil }
        let keep = messages[..<displayIndex].filter { !$0.isMarker }.count
        let prompt = messages[displayIndex].text
        let newID = UUID().uuidString
        guard let _ = try? await store.fork(id: sessionID, keepingMessages: keep, newID: newID) else {
            return nil
        }
        return (newID, prompt)
    }
}
