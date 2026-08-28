import Foundation
import Testing
@testable import NintyCore

/// Scripted provider: returns queued event batches, one per stream() call.
actor MockProvider: ModelProvider {
    var scripts: [[StreamEvent]]
    var requests: [ChatRequest] = []

    init(scripts: [[StreamEvent]]) {
        self.scripts = scripts
    }

    nonisolated var id: String { "mock" }

    nonisolated func models() async throws -> [ModelInfo] { [] }

    nonisolated func stream(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let batch = await self.nextBatch(request: request)
                for event in batch {
                    continuation.yield(event)
                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
                continuation.finish()
            }
        }
    }

    private func nextBatch(request: ChatRequest) -> [StreamEvent] {
        requests.append(request)
        return scripts.isEmpty ? [.finish(reason: .stop)] : scripts.removeFirst()
    }
}

/// In-memory test tool.
struct EchoTool: AgentTool {
    let name = "echo"
    let description = "Echo arguments back"
    let parameters: JSONSchema = .object(properties: ["text": .string("Text")], required: ["text"])

    func execute(_ args: JSONValue, ctx: ToolContext) async throws -> ToolResult {
        ToolResult(output: args["text"]?.stringValue ?? "(empty)")
    }
}

/// Single event collector for a session: one consumer, polls for predicates.
final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SessionEvent] = []
    private var task: Task<Void, Never>?

    init(session: AgentSession) {
        task = nil
        let collector = Task { [storage = AppendBox(self)] in
            for await event in session.events {
                storage.append(event)
            }
        }
        task = collector
    }

    /// Indirection so init can reference self before full initialization.
    private struct AppendBox: Sendable {
        let collector: EventCollector
        init(_ collector: EventCollector) { self.collector = collector }
        func append(_ event: SessionEvent) { collector.append(event) }
    }

    private func append(_ event: SessionEvent) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(event)
    }

    var events: [SessionEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    /// Poll until an event matches or timeout (seconds).
    func waitFor(_ timeout: TimeInterval = 10, _ predicate: @escaping (SessionEvent) -> Bool) -> [SessionEvent] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if events.contains(where: predicate) { return events }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return events
    }

    deinit { task?.cancel() }
}

@Suite("AgentSession", .serialized)
struct AgentSessionTests {
    var base: URL
    var project: URL

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("ninty-agenttest-\(UUID().uuidString)")
        project = base.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    func makeSession(scripts: [[StreamEvent]], agent: Agent = .build) throws -> (AgentSession, MockProvider, SessionStore, EventCollector) {
        // Unique project + session per test: no cross-test file interference.
        let testProject = project.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: testProject, withIntermediateDirectories: true)
        let sessionID = UUID().uuidString
        let provider = MockProvider(scripts: scripts)
        let todoStore = TodoStore()
        let registry = ToolRegistry.builtIns(todoStore: todoStore)
        try? registry.register(EchoTool())
        let store = SessionStore(projectRoot: testProject, baseDirectory: base)
        let session = AgentSession(
            id: sessionID,
            agent: agent,
            provider: provider,
            model: "m",
            contextWindow: 100_000,
            registry: registry,
            store: store,
            todoStore: todoStore,
            projectRoots: [testProject],
            projectInstructions: nil
        )
        let collector = EventCollector(session: session)
        return (session, provider, store, collector)
    }

    func isDone(_ event: SessionEvent) -> Bool {
        if case .done = event { return true }
        return false
    }

    @Test("plain text turn completes with done")
    func textTurn() async throws {
        let (session, _, store, collector) = try makeSession(scripts: [[
            .textDelta("Hello"), .textDelta(" back"),
            .usage(TokenUsage(input: 10, output: 4)), .finish(reason: .stop)
        ]])
        _ = try await store.create(id: session.id, title: "t", agentID: "build", model: "m")
        await session.send("hi")
        let events = collector.waitFor(10, isDone)
        let text = events.compactMap { if case .textDelta(let d) = $0 { d } else { nil } }.joined()
        #expect(text == "Hello back")
        #expect(events.contains {
            if case .done(let i, let o) = $0 { return i == 10 && o == 4 }
            return false
        })
        let loaded = try #require(await store.load(id: session.id))
        #expect(loaded.messages.count == 2)
        #expect(loaded.messages[1].role == .assistant)
        try await store.delete(id: session.id)
    }

    @Test("tool call executes and results feed back")
    func toolTurn() async throws {
        let args = "{\"text\": \"pong\"}"
        let (session, provider, store, collector) = try makeSession(scripts: [
            [.toolCallStart(id: "c1", name: "echo"), .toolCallDelta(id: "c1", argumentsFragment: args),
             .toolCallEnd(id: "c1"), .finish(reason: .toolCalls)],
            [.textDelta("Used echo."), .usage(TokenUsage(input: 30, output: 8)), .finish(reason: .stop)]
        ])
        _ = try await store.create(id: session.id, title: "t", agentID: "build", model: "m")
        await session.send("use echo")
        let events = collector.waitFor(10, isDone)
        #expect(events.contains {
            if case .toolResult(let id, let name, let output, let isError) = $0 {
                return id == "c1" && name == "echo" && output == "pong" && !isError
            }
            return false
        })
        let requests = await provider.requests
        #expect(requests.count == 2)
        #expect(requests[1].messages.last?.role == .tool)
        let loaded = try #require(await store.load(id: session.id))
        #expect(loaded.messages.count == 4)
        try await store.delete(id: session.id)
    }

    @Test("plan mode denies write tool without asking")
    func planDenies() async throws {
        let args = "{\"path\": \"x.txt\", \"content\": \"hi\"}"
        let (session, _, store, collector) = try makeSession(scripts: [
            [.toolCallStart(id: "c1", name: "write"), .toolCallDelta(id: "c1", argumentsFragment: args),
             .toolCallEnd(id: "c1"), .finish(reason: .toolCalls)],
            [.textDelta("Cannot write in plan mode."), .finish(reason: .stop)]
        ], agent: .plan)
        _ = try await store.create(id: session.id, title: "t", agentID: "plan", model: "m")
        await session.send("write a file")
        let events = collector.waitFor(10, isDone)
        #expect(events.contains {
            if case .toolResult(_, let name, _, let isError) = $0 { return name == "write" && isError }
            return false
        })
        #expect(!events.contains {
            if case .permissionAsked = $0 { return true }
            return false
        })
        try await store.delete(id: session.id)
    }

    @Test("plan mode bash read-only runs without asking")
    func planBashReadOnly() async throws {
        let args = "{\"command\": \"echo allowed-cmd\"}"
        let (session, _, store, collector) = try makeSession(scripts: [
            [.toolCallStart(id: "c1", name: "bash"), .toolCallDelta(id: "c1", argumentsFragment: args),
             .toolCallEnd(id: "c1"), .finish(reason: .toolCalls)],
            [.textDelta("Done."), .finish(reason: .stop)]
        ], agent: .plan)
        _ = try await store.create(id: session.id, title: "t", agentID: "plan", model: "m")
        await session.send("run something")
        let events = collector.waitFor(10, isDone)
        #expect(events.contains {
            if case .toolResult(_, let name, let output, let isError) = $0 {
                return name == "bash" && output.contains("allowed-cmd") && !isError
            }
            return false
        })
        #expect(!events.contains { if case .permissionAsked = $0 { return true }; return false })
        try await store.delete(id: session.id)
    }

    @Test("plan mode bash mutating denied without asking")
    func planBashMutatingDenied() async throws {
        let args = "{\"command\": \"echo hi > /tmp/x\"}"
        let (session, _, store, collector) = try makeSession(scripts: [
            [.toolCallStart(id: "c1", name: "bash"), .toolCallDelta(id: "c1", argumentsFragment: args),
             .toolCallEnd(id: "c1"), .finish(reason: .toolCalls)],
            [.textDelta("Done."), .finish(reason: .stop)]
        ], agent: .plan)
        _ = try await store.create(id: session.id, title: "t", agentID: "plan", model: "m")
        await session.send("mutate")
        let events = collector.waitFor(10, isDone)
        #expect(events.contains {
            if case .toolResult(_, let name, _, let isError) = $0 { return name == "bash" && isError }
            return false
        })
        #expect(!events.contains { if case .permissionAsked = $0 { return true }; return false })
        try await store.delete(id: session.id)
    }

    @Test("plan mode MCP write denied")
    func planMcpWriteDenied() async throws {
        let mcpTool = MCPBridgedTool(serverName: "ltm", remoteName: "store_memory", toolDescription: "store", schema: .object(properties: [:])) { _ in ToolResult(output: "stored") }
        let todoStore = TodoStore()
        let registry = ToolRegistry.builtIns(todoStore: todoStore)
        try registry.register(mcpTool)
        let testProject = project.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: testProject, withIntermediateDirectories: true)
        let sessionID = UUID().uuidString
        let provider = MockProvider(scripts: [
            [.toolCallStart(id: "c1", name: "ltm:store_memory"), .toolCallDelta(id: "c1", argumentsFragment: "{}"),
             .toolCallEnd(id: "c1"), .finish(reason: .toolCalls)],
            [.textDelta("Done."), .finish(reason: .stop)]
        ])
        let store = SessionStore(projectRoot: testProject, baseDirectory: base)
        let session = AgentSession(id: sessionID, agent: .plan, provider: provider, model: "m", contextWindow: 100_000, registry: registry, store: store, todoStore: todoStore, projectRoots: [testProject], projectInstructions: nil)
        let collector = EventCollector(session: session)
        _ = try await store.create(id: sessionID, title: "t", agentID: "plan", model: "m")
        await session.send("store")
        let events = collector.waitFor(10, isDone)
        #expect(events.contains {
            if case .toolResult(_, let name, _, let isError) = $0 { return name == "ltm:store_memory" && isError }
            return false
        })
        try await store.delete(id: sessionID)
    }
}
