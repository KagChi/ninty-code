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

@Suite("AgentSession")
struct AgentSessionTests {
    func makeSession(
        scripts: [[StreamEvent]],
        agent: Agent = .build,
        base: URL
    ) async throws -> (AgentSession, MockProvider, SessionStore) {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("ninty-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let provider = MockProvider(scripts: scripts)
        let todoStore = TodoStore()
        var registry = ToolRegistry.builtIns(todoStore: todoStore)
        try registry.register(EchoTool())
        let store = SessionStore(projectRoot: project, baseDirectory: base)
        _ = try await store.create(id: "test-session", title: "t", agentID: agent.id, model: "mock/m")
        let session = AgentSession(
            id: "test-session",
            agent: agent,
            provider: provider,
            model: "m",
            contextWindow: 100_000,
            registry: registry,
            store: store,
            todoStore: todoStore,
            projectRoot: project,
            projectInstructions: nil
        )
        return (session, provider, store)
    }

    func collectEvents(_ session: AgentSession, until predicate: @Sendable @escaping (SessionEvent) -> Bool) -> [SessionEvent] {
        var collected: [SessionEvent] = []
        // Drain the stream in a detached task; poll until predicate satisfied or timeout.
        let seen = Locked<[SessionEvent]>([])
        let task = Task.detached {
            for await event in session.events {
                seen.value.append(event)
            }
        }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let match = seen.value.first(where: predicate) {
                collected = seen.value
                _ = match
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        task.cancel()
        return collected
    }

    @Test("plain text turn completes with done")
    func textTurn() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let (session, _, store) = try await makeSession(scripts: [[
            .textDelta("Hello"), .textDelta(" back"),
            .usage(input: 10, output: 4), .finish(reason: .stop)
        ]], base: base)
        await session.send("hi")
        let events = collectEvents(session) { if case .done = $0 { return true }; return false }
        let text = events.compactMap { if case .textDelta(let d) = $0 { d } else { nil } }.joined()
        #expect(text == "Hello back")
        #expect(events.contains { if case .done(let i, let o) = $0 { i == 10 && o == 4 }; return false })
        // History persisted: user + assistant.
        let loaded = try #require(await store.load(id: "test-session"))
        #expect(loaded.messages.count == 2)
        #expect(loaded.messages[1].role == .assistant)
    }

    @Test("tool call executes and results feed back")
    func toolTurn() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let args = "{\"text\": \"pong\"}"
        let (session, provider, store) = try await makeSession(scripts: [
            [.toolCallStart(id: "c1", name: "echo"), .toolCallDelta(id: "c1", argumentsFragment: args),
             .toolCallEnd(id: "c1"), .finish(reason: .toolCalls)],
            [.textDelta("Used echo."), .usage(input: 30, output: 8), .finish(reason: .stop)]
        ], base: base)
        await session.send("use echo")
        let events = collectEvents(session) { if case .done = $0 { return true }; return false }
        #expect(events.contains { if case .toolResult(let id, let name, let output, let isError) = $0 {
            id == "c1" && name == "echo" && output == "pong" && !isError
        }; return false })
        // Second provider request must include tool result message.
        let requests = await provider.requests
        #expect(requests.count == 2)
        let toolMsg = requests[1].messages.last
        #expect(toolMsg?.role == .tool)
        // History: user, assistant(toolCall), tool(result), assistant(text) = 4.
        let loaded = try #require(await store.load(id: "test-session"))
        #expect(loaded.messages.count == 4)
    }

    @Test("plan mode denies write tool without asking")
    func planDenies() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let args = "{\"path\": \"x.txt\", \"content\": \"hi\"}"
        let (session, _, _) = try await makeSession(scripts: [
            [.toolCallStart(id: "c1", name: "write"), .toolCallDelta(id: "c1", argumentsFragment: args),
             .toolCallEnd(id: "c1"), .finish(reason: .toolCalls)],
            [.textDelta("Cannot write in plan mode."), .finish(reason: .stop)]
        ], agent: .plan, base: base)
        await session.send("write a file")
        let events = collectEvents(session) { if case .done = $0 { return true }; return false }
        // Denial surfaces as error tool result; no permissionAsked event.
        #expect(events.contains { if case .toolResult(_, let name, _, let isError) = $0 {
            name == "write" && isError
        }; return false })
        #expect(!events.contains { if case .permissionAsked = $0 { return true }; return false })
    }

    @Test("plan mode bash asks, approval runs command")
    func planBashAsk() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let args = "{\"command\": \"echo allowed-cmd\"}"
        let (session, _, _) = try await makeSession(scripts: [
            [.toolCallStart(id: "c1", name: "bash"), .toolCallDelta(id: "c1", argumentsFragment: args),
             .toolCallEnd(id: "c1"), .finish(reason: .toolCalls)],
            [.textDelta("Done."), .finish(reason: .stop)]
        ], agent: .plan, base: base)
        await session.send("run something")
        // Wait for the ask, then approve.
        let askEvents = collectEvents(session) { if case .permissionAsked = $0 { return true }; return false }
        let request = askEvents.compactMap { if case .permissionAsked(let r) = $0 { r } else { nil } }.first
        #expect(request?.tool == "bash")
        #expect(request?.preview == "echo allowed-cmd")
        await session.replyPermission(try #require(request).id, .once)
        let events = collectEvents(session) { if case .done = $0 { return true }; return false }
        #expect(events.contains { if case .toolResult(_, let name, let output, let isError) = $0 {
            name == "bash" && output.contains("allowed-cmd") && !isError
        }; return false })
    }
}
