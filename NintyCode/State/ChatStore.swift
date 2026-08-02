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

    let sessionID: String
    let agent: Agent
    let model: String

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
        projectRoot: URL,
        projectInstructions: String?,
        mcpManager: MCPManager?,
        onChange: @escaping () -> Void
    ) {
        self.sessionID = sessionID
        self.agent = agent
        self.model = model
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

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !streaming else { return }
        messages.append(DisplayMessage(role: .user, text: trimmed))
        streaming = true
        lastError = nil
        // First message creates the on-disk meta so the session lists in the sidebar.
        if !metaCreated {
            metaCreated = true
            let title = String(trimmed.prefix(60))
            Task {
                try? await store.create(id: sessionID, title: title, agentID: agent.id, model: model)
                onChange()
            }
        }
        Task { await session.send(trimmed) }
    }

    func abort() {
        Task { await session.abort() }
        streaming = false
        pendingPermission = nil
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
}
