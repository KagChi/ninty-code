import Testing
import Foundation
@testable import NintyCore

/// Tiny lock-protected box for cross-task captures in tests.
final class LockedBox<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func set(_ newValue: T) { lock.lock(); defer { lock.unlock() }; value = newValue }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}

@Suite("SnapshotStore")
struct SnapshotStoreTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("revert restores original content; redo re-applies")
    func revertRedo() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try "original".write(to: file, atomically: true, encoding: .utf8)

        let snapshots = SnapshotStore()
        await snapshots.beginTurn()
        await snapshots.recordOriginal(path: file.path)
        try "modified".write(to: file, atomically: true, encoding: .utf8)
        await snapshots.beginTurn() // close segment

        let restored = await snapshots.revert()
        #expect(restored == [file.path])
        #expect(try String(contentsOf: file, encoding: .utf8) == "original")
        #expect(await snapshots.redoDepth == 1)

        await snapshots.redo()
        #expect(try String(contentsOf: file, encoding: .utf8) == "modified")
    }

    @Test("revert deletes file that did not exist before the turn")
    func revertDeletesNewFile() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("new.txt")

        let snapshots = SnapshotStore()
        await snapshots.recordOriginal(path: file.path) // nil original
        try "created".write(to: file, atomically: true, encoding: .utf8)

        await snapshots.revert()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        await snapshots.redo()
        #expect(try String(contentsOf: file, encoding: .utf8) == "created")
    }

    @Test("first touch per turn wins")
    func firstTouchWins() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("b.txt")
        try "v1".write(to: file, atomically: true, encoding: .utf8)

        let snapshots = SnapshotStore()
        await snapshots.recordOriginal(path: file.path)
        try "v2".write(to: file, atomically: true, encoding: .utf8)
        await snapshots.recordOriginal(path: file.path) // must NOT overwrite v1 capture

        await snapshots.revert()
        #expect(try String(contentsOf: file, encoding: .utf8) == "v1")
    }

    @Test("clearReverted drops redo history")
    func clearReverted() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("c.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        let snapshots = SnapshotStore()
        await snapshots.recordOriginal(path: file.path)
        try "y".write(to: file, atomically: true, encoding: .utf8)
        await snapshots.revert()
        await snapshots.clearReverted()
        #expect(await snapshots.redoDepth == 0)
        let restored = await snapshots.redo()
        #expect(restored.isEmpty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "x")
    }
}

@Suite("PermissionEngine patterns")
struct PermissionPatternTests {
    @Test("always auto-approves same bash command")
    func alwaysApprovesSameCommand() async throws {
        let engine = PermissionEngine()
        let rules = PermissionSet(rules: ["bash": .ask])
        // First call: ask → reply always.
        await withCheckedContinuation { (gate: CheckedContinuation<Void, Never>) in
            Task {
                try? await engine.authorize(
                    tool: "bash", arguments: ["command": "git status"],
                    preview: "git status", rules: rules,
                    onAsk: { request in
                        Task { await engine.reply(request.id, .always) }
                        gate.resume()
                    }
                )
            }
        }
        // Second call with same command: no ask.
        try await engine.authorize(
            tool: "bash", arguments: ["command": "git status"],
            preview: "git status", rules: rules,
            onAsk: { _ in Issue.record("should not ask again") }
        )
    }

    @Test("always for one command does not approve another")
    func alwaysScopedToPattern() async throws {
        let engine = PermissionEngine()
        let rules = PermissionSet(rules: ["bash": .ask])
        await withCheckedContinuation { (gate: CheckedContinuation<Void, Never>) in
            Task {
                try? await engine.authorize(
                    tool: "bash", arguments: ["command": "git status"],
                    preview: "git status", rules: rules,
                    onAsk: { request in
                        Task { await engine.reply(request.id, .always) }
                        gate.resume()
                    }
                )
            }
        }
        let asked = LockedBox(false)
        let task = Task {
            try await engine.authorize(
                tool: "bash", arguments: ["command": "rm -rf /tmp/x"],
                preview: "rm", rules: rules,
                onAsk: { _ in asked.set(true) }
            )
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(asked.get())
        await engine.rejectAll()
        _ = try? await task.value
    }

    @Test("reject cascades to all pending")
    func rejectCascades() async throws {
        let engine = PermissionEngine()
        let rules = PermissionSet(rules: ["bash": .ask])
        let firstID = LockedBox<String?>(nil)
        let gate = AsyncStream<Void>.makeStream()
        let task1 = Task {
            try await engine.authorize(
                tool: "bash", arguments: ["command": "cmd1"], preview: "1", rules: rules,
                onAsk: { request in firstID.set(request.id); gate.continuation.yield() }
            )
        }
        var iterator = gate.stream.makeAsyncIterator()
        _ = await iterator.next()
        let task2 = Task {
            try await engine.authorize(
                tool: "bash", arguments: ["command": "cmd2"], preview: "2", rules: rules,
                onAsk: { _ in }
            )
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        await engine.reply(firstID.get()!, .reject)
        await #expect(throws: PermissionEngineError.self) { try await task1.value }
        await #expect(throws: PermissionEngineError.self) { try await task2.value }
    }

    @Test("autoAccept skips ask entirely")
    func autoAccept() async throws {
        let engine = PermissionEngine()
        await engine.setAutoAccept(true)
        try await engine.authorize(
            tool: "bash", arguments: ["command": "anything"],
            preview: "x", rules: PermissionSet(rules: ["bash": .ask]),
            onAsk: { _ in Issue.record("must not ask in auto-accept") }
        )
    }

    @Test("plan agent plans-file exception")
    func planFileException() {
        let rules = PermissionSet(rules: ["write": .deny, "edit": .deny, "*": .allow])
        #expect(rules.action(
            for: "write",
            arguments: ["path": ".ninty/plans/2026-01-01-x.md"],
            isPlan: true
        ) == .allow)
        #expect(rules.action(for: "write", arguments: ["path": "src/main.swift"], isPlan: true) == .deny)
        #expect(rules.action(
            for: "write",
            arguments: ["path": ".ninty/plans/x.md"],
            isPlan: false
        ) == .deny)
        #expect(rules.action(for: "write", arguments: ["path": ".ninty/plans/x.txt"], isPlan: true) == .deny)
    }
}

@Suite("AgentSession steer queue", .serialized)
struct SteerQueueTests {
    @Test("send while busy enqueues and drains in order")
    func steerQueue() async throws {
        let provider = SlowMockProvider(delay: 0.3)
        let session = makeSession(provider: provider)
        let collector = EventCollector(session: session)

        await session.send("first")
        try? await Task.sleep(nanoseconds: 100_000_000) // let turn start
        await session.send("second")
        await session.send("third")

        // Wait for 3 done events (one per drained turn).
        let deadline = Date().addingTimeInterval(10)
        var queueSeen = false
        while Date() < deadline {
            let events = collector.events
            if events.contains(where: {
                if case .queueChanged(let queue) = $0 { return queue == ["second", "third"] }
                return false
            }) { queueSeen = true }
            let dones = events.filter { if case .done = $0 { return true }; return false }.count
            if dones >= 3 { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(queueSeen)
        let prompts = await provider.receivedPrompts
        #expect(prompts == ["first", "second", "third"])
    }

    @Test("abort pauses queue without clearing")
    func abortPausesQueue() async throws {
        let provider = SlowMockProvider(delay: 1.0)
        let session = makeSession(provider: provider)
        _ = EventCollector(session: session)

        await session.send("first")
        try? await Task.sleep(nanoseconds: 100_000_000)
        await session.send("queued")
        await session.abort()
        try? await Task.sleep(nanoseconds: 300_000_000)
        // Queue still holds the message — abort doesn't drain.
        let prompts = await provider.receivedPrompts
        #expect(prompts == ["first"])
    }

    private func makeSession(provider: any ModelProvider) -> AgentSession {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("steer-tests-\(UUID().uuidString)")
        return AgentSession(
            agent: .build,
            provider: provider,
            model: "mock",
            contextWindow: 128_000,
            registry: ToolRegistry.builtIns(todoStore: TodoStore()),
            store: SessionStore(projectRoot: tempRoot),
            todoStore: TodoStore(),
            projectRoots: [tempRoot],
            projectInstructions: nil
        )
    }
}

/// Mock that takes `delay` seconds per response so steer queueing is observable.
actor SlowMockProvider: ModelProvider {
    let delay: Double
    private(set) var receivedPrompts: [String] = []

    init(delay: Double) { self.delay = delay }

    nonisolated var id: String { "mock" }

    nonisolated func models() async throws -> [ModelInfo] { [] }

    nonisolated func stream(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        let prompt = request.messages.last?.parts.compactMap {
            if case .text(let t) = $0 { t } else { nil }
        }.joined() ?? ""
        let delay = self.delay
        return AsyncThrowingStream { continuation in
            let task = Task {
                await self.record(prompt)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                continuation.yield(.textDelta("reply"))
                continuation.yield(.usage(TokenUsage(input: 10, output: 5)))
                continuation.yield(.finish(reason: .stop))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func record(_ prompt: String) {
        receivedPrompts.append(prompt)
    }
}
