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

struct DisplayMessage: Identifiable, Equatable {
    var id = UUID()
    var role: Role
    var text: String = ""
    var toolCalls: [ToolCallDisplay] = []
    var timestamp: Date = Date()
    /// Timeline marker (e.g. "Compaction") — rendered as a divider, not a bubble.
    var isMarker = false
    /// Attached images (data URLs).
    var images: [String] = []
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

    let sessionID: String
    let projectRoot: URL
    private(set) var agent: Agent
    private(set) var model: String

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
        self.projectRoot = projectRoot
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
                display.text += text
            case .image(let dataURL):
                display.images.append(dataURL)
            case .toolCall(let id, let name, let arguments):
                display.toolCalls.append(ToolCallDisplay(id: id, name: name, arguments: arguments, status: .done))
            case .toolResult(let id, _, let output, let isError):
                if let index = display.toolCalls.firstIndex(where: { $0.id == id }) {
                    display.toolCalls[index].output = output
                    display.toolCalls[index].isError = isError
                    display.toolCalls[index].status = isError ? .failed : .done
                } else {
                    display.toolCalls.append(ToolCallDisplay(
                        id: id, name: "", arguments: .object([:]),
                        output: output, isError: isError, status: isError ? .failed : .done
                    ))
                }
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
        switch event {
        case .textDelta(let delta):
            ensureAssistantMessage()
            messages[messages.count - 1].text += delta
        case .toolCallStarted(let id, let name):
            ensureAssistantMessage()
            messages[messages.count - 1].toolCalls.append(
                ToolCallDisplay(id: id, name: name, arguments: .object([:]))
            )
        case .toolCallUpdated(let id, let arguments):
            guard let last = messages.indices.last,
                  let index = messages[last].toolCalls.firstIndex(where: { $0.id == id }) else { return }
            messages[last].toolCalls[index].arguments = arguments
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
        case .titleGenerated:
            onChange() // sidebar refresh picks up new title
        case .agentChanged(let newAgent):
            agent = newAgent
        case .modelChanged(let newModel):
            model = newModel
        case .error(let message):
            lastError = message
            streaming = false
        case .done:
            streaming = false
            pendingPermission = nil
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
        if let index = messages[last].toolCalls.firstIndex(where: { $0.id == id }) {
            messages[last].toolCalls[index].output = output
            messages[last].toolCalls[index].isError = isError
            messages[last].toolCalls[index].status = isError ? .failed : .done
        } else {
            messages[last].toolCalls.append(ToolCallDisplay(
                id: id, name: name, arguments: .object([:]),
                output: output, isError: isError, status: isError ? .failed : .done
            ))
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
                try? await store.create(id: sessionID, title: title, agentID: agent.id, model: model)
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
        persistSelection(agentID: newAgent.id, model: model)
    }

    func setModel(_ newModel: String) {
        Task { await session.setModel(newModel) }
        persistSelection(agentID: agent.id, model: newModel)
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
                    agentID: agent.id, model: model
                )
                onChange()
            }
        }
        Task {
            let callID = UUID().uuidString
            let display = ToolCallDisplay(id: callID, name: "bash",
                                          arguments: .object(["command": .string(trimmed)]))
            messages.append(DisplayMessage(role: .assistant, toolCalls: [display]))
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
