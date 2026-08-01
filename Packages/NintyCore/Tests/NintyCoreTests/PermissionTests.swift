import Foundation
import Testing
@testable import NintyCore

@Suite("PermissionSet")
struct PermissionSetTests {
    @Test("exact match beats wildcard")
    func exactWins() {
        let rules = PermissionSet(rules: ["*": .allow, "bash": .deny])
        #expect(rules.action(for: "bash") == .deny)
        #expect(rules.action(for: "read") == .allow)
    }

    @Test("prefix wildcard matches namespaced tools")
    func prefixWildcard() {
        let rules = PermissionSet(rules: ["mcp:*": .ask, "*": .allow])
        #expect(rules.action(for: "mcp:filesystem:read") == .ask)
        #expect(rules.action(for: "fs:read") == .allow)
    }

    @Test("deny > ask > allow among wildcard matches")
    func precedence() {
        let deny = PermissionSet(rules: ["mcp:*": .deny, "*": .allow])
        #expect(deny.action(for: "mcp:x") == .deny)
        let ask = PermissionSet(rules: ["mcp:*": .ask, "*": .allow, "other:*": .deny])
        #expect(ask.action(for: "mcp:x") == .ask)
    }

    @Test("no match defaults to allow")
    func defaultAllow() {
        let rules = PermissionSet(rules: ["bash": .deny])
        #expect(rules.action(for: "read") == .allow)
    }

    @Test("plan agent rules")
    func planAgent() {
        let plan = Agent.plan.permissions
        #expect(plan.action(for: "write") == .deny)
        #expect(plan.action(for: "edit") == .deny)
        #expect(plan.action(for: "todowrite") == .deny)
        #expect(plan.action(for: "bash") == .ask)
        #expect(plan.action(for: "read") == .allow)
        #expect(plan.action(for: "grep") == .allow)
        #expect(plan.action(for: "glob") == .allow)
    }

    @Test("build agent allows everything")
    func buildAgent() {
        let build = Agent.build.permissions
        for tool in ["read", "write", "edit", "bash", "glob", "grep", "list", "todowrite", "mcp:x"] {
            #expect(build.action(for: tool) == .allow)
        }
    }
}

@Suite("PermissionEngine")
struct PermissionEngineTests {
    @Test("denied tool throws without asking")
    func denied() async {
        let engine = PermissionEngine()
        await #expect(throws: PermissionEngineError.self) {
            try await engine.authorize(
                tool: "write", arguments: [:], preview: "",
                rules: Agent.plan.permissions,
                onAsk: { _ in Issue.record("should not ask for denied tool") }
            )
        }
    }

    @Test("ask suspends until reply, always allowlists")
    func askFlow() async throws {
        let engine = PermissionEngine()
        let rules = Agent.plan.permissions
        let asked = Locked<PermissionRequest?>(nil)

        let task = Task {
            try await engine.authorize(
                tool: "bash", arguments: ["command": "ls"], preview: "ls",
                rules: rules, onAsk: { request in asked.value = request }
            )
        }
        // Wait for the ask to surface.
        while asked.value == nil { try? await Task.sleep(nanoseconds: 10_000_000) }
        let request = try #require(asked.value)
        #expect(request.tool == "bash")
        await engine.reply(request.id, .always)
        try await task.value

        // Second call: no ask, resolves immediately.
        try await engine.authorize(
            tool: "bash", arguments: ["command": "pwd"], preview: "pwd",
            rules: rules, onAsk: { _ in Issue.record("should not ask after always") }
        )
    }

    @Test("reject throws")
    func reject() async {
        let engine = PermissionEngine()
        let asked = Locked<PermissionRequest?>(nil)
        let task = Task {
            try await engine.authorize(
                tool: "bash", arguments: [:], preview: "rm -rf x",
                rules: Agent.plan.permissions, onAsk: { asked.value = $0 }
            )
        }
        while asked.value == nil { try? await Task.sleep(nanoseconds: 10_000_000) }
        await engine.reply(asked.value!.id, .reject)
        await #expect(throws: PermissionEngineError.self) { try await task.value }
    }
}

/// Tiny lock for test state crossing task boundaries.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T
    init(_ value: T) { storage = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); defer { lock.unlock() }; storage = newValue }
    }
}
