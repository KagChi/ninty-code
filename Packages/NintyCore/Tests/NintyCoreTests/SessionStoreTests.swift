import Foundation
import Testing
@testable import NintyCore

@Suite("SessionStore")
struct SessionStoreTests {
    func withStore(_ body: (SessionStore, URL) async throws -> Void) async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ninty-sessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let project = URL(fileURLWithPath: "/tmp/fake-project")
        try await body(SessionStore(projectRoot: project, baseDirectory: base), base)
    }

    @Test("create + append + load roundtrip")
    func roundtrip() async throws {
        try await withStore { store, _ in
            let meta = try await store.create(id: "s1", title: "Test chat", agentID: "build", model: "m")
            #expect(meta.title == "Test chat")
            try await store.append(.user("hello"), sessionID: "s1")
            try await store.append(.assistant("hi there"), sessionID: "s1")
            let loaded = try #require(await store.load(id: "s1"))
            #expect(loaded.meta.id == "s1")
            #expect(loaded.messages.count == 2)
            #expect(loaded.messages[0].role == .user)
            #expect(loaded.messages[1].role == .assistant)
        }
    }

    @Test("usage persists in meta; old metas without it decode as nil")
    func usageRoundtrip() async throws {
        try await withStore { store, _ in
            _ = try await store.create(id: "s1", title: "T", agentID: "build", model: "m")
            try await store.updateUsage(inputTokens: 42_000, sessionID: "s1")
            let loaded = try #require(await store.load(id: "s1"))
            #expect(loaded.meta.inputTokens == 42_000)
        }
        // Meta JSON lacking inputTokens must still decode (backward compat).
        let json = """
        {"id":"x","title":"t","agentID":"build","model":"m",\
        "created":"2026-01-01T00:00:00Z","updated":"2026-01-01T00:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let meta = try #require(try? decoder.decode(SessionMeta.self, from: Data(json.utf8)))
        #expect(meta.inputTokens == nil)
    }

    @Test("list sorts newest first, delete removes")
    func listDelete() async throws {
        try await withStore { store, _ in
            _ = try await store.create(id: "a", title: "First", agentID: "build", model: "m")
            try await Task.sleep(nanoseconds: 20_000_000)
            _ = try await store.create(id: "b", title: "Second", agentID: "plan", model: "m")
            let metas = try await store.list()
            #expect(metas.map(\.id) == ["b", "a"])
            try await store.delete(id: "a")
            #expect(try await store.list().map(\.id) == ["b"])
        }
    }

    @Test("corrupt lines skipped on load")
    func corruptTolerance() async throws {
        try await withStore { store, base in
            _ = try await store.create(id: "s1", title: "T", agentID: "build", model: "m")
            try await store.append(.user("good line"), sessionID: "s1")
            // Inject garbage line.
            let dir = base.appendingPathComponent(SessionStore.projectHash(URL(fileURLWithPath: "/tmp/fake-project"))).appendingPathComponent("sessions")
            let file = dir.appendingPathComponent("s1.jsonl")
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("{garbage!!!\n".utf8))
            try handle.close()
            try await store.append(.assistant("still works"), sessionID: "s1")
            let loaded = try #require(await store.load(id: "s1"))
            #expect(loaded.messages.count == 2)
        }
    }

    @Test("turn usage + duration persist on assistant message; old messages decode as nil")
    func turnStatsRoundtrip() async throws {
        try await withStore { store, _ in
            _ = try await store.create(id: "s1", title: "T", agentID: "build", model: "m")
            try await store.append(.user("hi"), sessionID: "s1")
            let usage = TokenUsage(input: 1200, output: 340, reasoning: 50, cacheRead: 600, cacheWrite: 0)
            try await store.append(
                Message(role: .assistant, parts: [.text("done")], usage: usage, durationMs: 83_000),
                sessionID: "s1"
            )
            let loaded = try #require(await store.load(id: "s1"))
            let assistant = loaded.messages[1]
            #expect(assistant.usage == usage)
            #expect(assistant.usage?.total == 2190)
            #expect(assistant.durationMs == 83_000)
            // User message written without stats decodes as nil (backward compat).
            #expect(loaded.messages[0].usage == nil)
            #expect(loaded.messages[0].durationMs == nil)
        }
    }

    @Test("project hash stable + path-distinct")
    func hashing() {
        let a = SessionStore.projectHash(URL(fileURLWithPath: "/tmp/proj"))
        #expect(SessionStore.projectHash(URL(fileURLWithPath: "/tmp/proj")) == a)
        #expect(SessionStore.projectHash(URL(fileURLWithPath: "/tmp/other")) != a)
    }

    @Test("legacy workspace keeps path-hash id — sessions shared with projectRoot store")
    func legacyWorkspaceCompat() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ninty-sessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let project = URL(fileURLWithPath: "/tmp/fake-project")
        // Old world: write via the path-hash store.
        let legacyStore = SessionStore(projectRoot: project, baseDirectory: base)
        _ = try await legacyStore.create(id: "s1", title: "Old", agentID: "build", model: "m")
        try await legacyStore.append(.user("hello"), sessionID: "s1")
        // New world: migrated workspace reads the same directory.
        let workspace = Workspace.legacy(folder: project)
        #expect(workspace.id == SessionStore.projectHash(project))
        let workspaceStore = SessionStore(workspace: workspace, baseDirectory: base)
        let loaded = try #require(await workspaceStore.load(id: "s1"))
        #expect(loaded.meta.title == "Old")
        #expect(loaded.messages.count == 1)
    }

    @Test("WorkspaceStore roundtrip")
    func workspaceStoreRoundtrip() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ninty-workspaces-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = WorkspaceStore(fileURL: file)
        #expect(await store.load().isEmpty)
        let workspaces = [
            Workspace(name: "web", folders: [URL(fileURLWithPath: "/tmp/web")]),
            Workspace.legacy(folder: URL(fileURLWithPath: "/tmp/api"))
        ]
        try await store.save(workspaces)
        let loaded = await store.load()
        #expect(loaded.count == 2)
        #expect(loaded[0].name == "web")
        #expect(loaded[0].primaryRoot.lastPathComponent == "web")
        #expect(loaded[1].id == SessionStore.projectHash(URL(fileURLWithPath: "/tmp/api")))
    }

    @Test("workspace folders: plain paths on disk, legacy file:// form still decodes, systemContext optional")
    func workspaceCodableCompat() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // New form: plain path strings + systemContext.
        let workspace = Workspace(
            name: "mix", folders: [URL(fileURLWithPath: "/tmp/web"), URL(fileURLWithPath: "/tmp/api")],
            systemContext: "Always answer in Indonesian."
        )
        let data = try encoder.encode([workspace])
        let raw = try #require(String(data: data, encoding: .utf8))
        #expect(raw.contains("\"/tmp/web\""))
        #expect(!raw.contains("file://"))
        let decoded = try decoder.decode([Workspace].self, from: data)
        #expect(decoded[0].folders.map(\.path) == ["/tmp/web", "/tmp/api"])
        #expect(decoded[0].systemContext == "Always answer in Indonesian.")

        // Legacy form: file:/// URLs, no systemContext key.
        let legacy = """
        [{"id":"x","name":"old","folders":["file:///tmp/web/"],\
        "created":"2026-08-05T00:00:00Z"}]
        """
        let migrated = try decoder.decode([Workspace].self, from: Data(legacy.utf8))
        #expect(migrated[0].folders[0].path == "/tmp/web")
        #expect(migrated[0].systemContext == nil)
    }
}
