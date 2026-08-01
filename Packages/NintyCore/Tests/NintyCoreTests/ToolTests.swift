import Foundation
import Testing
@testable import NintyCore

@Suite("FileTools")
struct FileToolTests {
    func withTempProject(_ body: (ToolContext) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ninty-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await body(ToolContext(projectRoot: dir, sessionID: "test"))
    }

    @Test("write then read roundtrip")
    func writeRead() async throws {
        try await withTempProject { ctx in
            let write = try await WriteTool().execute(["path": "src/a.txt", "content": "line1\nline2"], ctx: ctx)
            #expect(!write.isError)
            let read = try await ReadTool().execute(["path": "src/a.txt"], ctx: ctx)
            #expect(read.output.contains("1: line1"))
            #expect(read.output.contains("2: line2"))
        }
    }

    @Test("read offset/limit + truncation notice")
    func readPaging() async throws {
        try await withTempProject { ctx in
            let content = (1...10).map { "line \($0)" }.joined(separator: "\n")
            _ = try await WriteTool().execute(["path": "big.txt", "content": .string(content)], ctx: ctx)
            let page = try await ReadTool().execute(["path": "big.txt", "offset": 3, "limit": 2], ctx: ctx)
            #expect(page.output.contains("3: line 3"))
            #expect(page.output.contains("4: line 4"))
            #expect(!page.output.contains("5: line 5"))
            #expect(page.output.contains("more lines"))
        }
    }

    @Test("read missing file is error, not throw")
    func readMissing() async throws {
        try await withTempProject { ctx in
            let result = try await ReadTool().execute(["path": "nope.txt"], ctx: ctx)
            #expect(result.isError)
        }
    }

    @Test("edit unique replacement")
    func editUnique() async throws {
        try await withTempProject { ctx in
            _ = try await WriteTool().execute(["path": "e.txt", "content": "hello world"], ctx: ctx)
            let result = try await EditTool().execute(
                ["path": "e.txt", "oldString": "world", "newString": "swift"], ctx: ctx
            )
            #expect(!result.isError)
            let read = try await ReadTool().execute(["path": "e.txt"], ctx: ctx)
            #expect(read.output.contains("hello swift"))
        }
    }

    @Test("edit ambiguous fails without replaceAll")
    func editAmbiguous() async throws {
        try await withTempProject { ctx in
            _ = try await WriteTool().execute(["path": "e.txt", "content": "foo bar foo"], ctx: ctx)
            let ambiguous = try await EditTool().execute(
                ["path": "e.txt", "oldString": "foo", "newString": "baz"], ctx: ctx
            )
            #expect(ambiguous.isError)
            let all = try await EditTool().execute(
                ["path": "e.txt", "oldString": "foo", "newString": "baz", "replaceAll": true], ctx: ctx
            )
            #expect(!all.isError)
            let read = try await ReadTool().execute(["path": "e.txt"], ctx: ctx)
            #expect(read.output.contains("baz bar baz"))
        }
    }

    @Test("edit identical strings rejected")
    func editIdentical() async throws {
        try await withTempProject { ctx in
            _ = try await WriteTool().execute(["path": "e.txt", "content": "same"], ctx: ctx)
            let result = try await EditTool().execute(
                ["path": "e.txt", "oldString": "same", "newString": "same"], ctx: ctx
            )
            #expect(result.isError)
        }
    }

    @Test("list marks directories")
    func list() async throws {
        try await withTempProject { ctx in
            _ = try await WriteTool().execute(["path": "sub/file.txt", "content": "x"], ctx: ctx)
            let result = try await ListTool().execute(["path": "."], ctx: ctx)
            #expect(result.output.contains("sub/"))
        }
    }
}

@Suite("SearchTools")
struct SearchToolTests {
    func withTempProject(_ body: (ToolContext) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ninty-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await body(ToolContext(projectRoot: dir, sessionID: "test"))
    }

    @Test("glob matcher semantics")
    func matcher() {
        #expect(GlobMatcher(pattern: "*.swift").matches("main.swift"))
        #expect(!GlobMatcher(pattern: "*.swift").matches("src/main.swift"))
        #expect(GlobMatcher(pattern: "**/*.swift").matches("src/deep/main.swift"))
        #expect(GlobMatcher(pattern: "src/*.md").matches("src/README.md"))
        #expect(!GlobMatcher(pattern: "src/*.md").matches("src/nested/README.md"))
        #expect(GlobMatcher(pattern: "file?.txt").matches("file1.txt"))
    }

    @Test("glob finds files, skips .git")
    func glob() async throws {
        try await withTempProject { ctx in
            _ = try await WriteTool().execute(["path": "a/b.swift", "content": "x"], ctx: ctx)
            _ = try await WriteTool().execute(["path": "a/c.md", "content": "x"], ctx: ctx)
            _ = try await WriteTool().execute(["path": ".git/hidden.swift", "content": "x"], ctx: ctx)
            let result = try await GlobTool().execute(["pattern": "**/*.swift"], ctx: ctx)
            #expect(result.output.contains("b.swift"))
            #expect(!result.output.contains("c.md"))
            #expect(!result.output.contains("hidden.swift"))
        }
    }

    @Test("grep finds matches with line numbers, respects include")
    func grep() async throws {
        try await withTempProject { ctx in
            _ = try await WriteTool().execute(["path": "code.swift", "content": "let a = 1\n// TODO: fix\nlet b = 2"], ctx: ctx)
            _ = try await WriteTool().execute(["path": "notes.md", "content": "TODO item"], ctx: ctx)
            let all = try await GrepTool().execute(["pattern": "TODO"], ctx: ctx)
            #expect(all.output.contains("code.swift:2:"))
            #expect(all.output.contains("notes.md:1:"))
            let swiftOnly = try await GrepTool().execute(["pattern": "TODO", "include": "*.swift"], ctx: ctx)
            #expect(swiftOnly.output.contains("code.swift"))
            #expect(!swiftOnly.output.contains("notes.md"))
        }
    }

    @Test("grep invalid regex is error")
    func grepInvalid() async throws {
        try await withTempProject { ctx in
            let result = try await GrepTool().execute(["pattern": "([invalid"], ctx: ctx)
            #expect(result.isError)
        }
    }
}

@Suite("BashTool")
struct BashToolTests {
    @Test("captures output and exit code")
    func output() async throws {
        let ctx = ToolContext(projectRoot: FileManager.default.temporaryDirectory, sessionID: "t")
        let ok = try await BashTool().execute(["command": "echo hello"], ctx: ctx)
        #expect(ok.output.contains("hello"))
        #expect(!ok.isError)
        let fail = try await BashTool().execute(["command": "exit 42"], ctx: ctx)
        #expect(fail.isError)
        #expect(fail.output.contains("exit code 42"))
    }

    @Test("timeout terminates long command")
    func timeout() async throws {
        let ctx = ToolContext(projectRoot: FileManager.default.temporaryDirectory, sessionID: "t")
        let start = Date()
        let result = try await BashTool().execute(["command": "sleep 30", "timeout": 1], ctx: ctx)
        #expect(Date().timeIntervalSince(start) < 10)
        #expect(result.isError)
    }

    @Test("runs in project directory")
    func cwd() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ninty-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ctx = ToolContext(projectRoot: dir, sessionID: "t")
        let result = try await BashTool().execute(["command": "pwd"], ctx: ctx)
        #expect(result.output.contains(dir.lastPathComponent))
    }
}
