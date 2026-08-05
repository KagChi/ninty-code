import Foundation
import Testing
@testable import NintyCore

@Suite("CodeGraph")
struct CodeGraphTests {

    // MARK: - Helpers

    func withTempWorkspace(_ files: [String: String], _ body: (URL) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ninty-graph-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (path, content) in files {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        try await body(dir)
    }

    func extract(_ root: URL, _ relativePath: String) -> (GraphFileExtraction, GraphFileFacts)? {
        GraphExtractor().extractFile(url: root.appendingPathComponent(relativePath), relativePath: relativePath)
    }

    func nodes(_ extraction: GraphFileExtraction, kind: String) -> [GraphNodeInput] {
        extraction.nodes.filter { $0.kind == kind }
    }

    // MARK: - Language specs registry

    @Test("all 16 languages registered by extension")
    func specRegistry() {
        #expect(LanguageSpec.all.count == 16)
        for ext in ["swift", "rs", "go", "c", "h", "cpp", "hpp", "cs", "java", "kt", "js", "ts", "py", "rb", "php", "dart", "scala", "m"] {
            #expect(LanguageSpec.byExtension[ext] != nil, "missing spec for .\(ext)")
        }
    }

    // MARK: - Swift

    @Test("swift: types, methods, scope end lines, calls")
    func swiftExtraction() async throws {
        try await withTempWorkspace(["test.swift": """
            import Foundation

            final class AppState: ObservableObject {
                func load() async {
                    fetchConfig()
                }
            }

            func fetchConfig() {
            }
            """]) { root in
            let (extraction, _) = try #require(extract(root, "test.swift"))

            let classNode = try #require(nodes(extraction, kind: "class").first)
            #expect(classNode.nodeKey == "test.swift#AppState")
            #expect(classNode.line == 3)
            #expect(classNode.endLine == 7)

            let method = try #require(nodes(extraction, kind: "method").first)
            #expect(method.nodeKey == "test.swift#AppState.load")

            let function = try #require(nodes(extraction, kind: "func").first)
            #expect(function.nodeKey == "test.swift#fetchConfig")

            // contains edges
            #expect(extraction.edges.contains(.init(fromKey: "test.swift", toKey: "test.swift#AppState", kind: "contains", confidence: "extracted")))
            #expect(extraction.edges.contains(.init(fromKey: "test.swift#AppState", toKey: "test.swift#AppState.load", kind: "contains", confidence: "extracted")))
            #expect(extraction.edges.contains(.init(fromKey: "test.swift", toKey: "test.swift#fetchConfig", kind: "contains", confidence: "extracted")))
        }
    }

    // MARK: - Python

    @Test("python: indent scopes, import resolution, cross-file calls")
    func pythonExtraction() async throws {
        try await withTempWorkspace([
            "main.py": """
                import os
                from pkg.util import helper

                class Base:
                    def start(self):
                        pass

                def main():
                    helper()
                """,
            "pkg/util.py": """
                def helper():
                    pass
                """,
        ]) { root in
            let (main, mainFacts) = try #require(extract(root, "main.py"))
            let (util, utilFacts) = try #require(extract(root, "pkg/util.py"))

            // symbols
            #expect(main.nodes.map(\.nodeKey).contains("main.py#Base"))
            #expect(main.nodes.map(\.nodeKey).contains("main.py#Base.start"))
            #expect(main.nodes.map(\.nodeKey).contains("main.py#main"))
            let method = try #require(nodes(main, kind: "method").first)
            #expect(method.name == "start")

            // index + resolution
            var index = GraphWorkspaceIndex()
            index.insert(main, stamp: "1")
            index.insert(util, stamp: "1")
            var resolved = main
            GraphExtractor().resolveCrossFileEdges(extraction: &resolved, facts: mainFacts, index: index, roots: [root])

            // import edge main.py -> pkg/util.py (from pkg.util), none to os
            let imports = resolved.edges.filter { $0.kind == "imports" }
            #expect(imports.count == 1)
            #expect(imports.first?.toKey == "pkg/util.py")

            // call edge main -> helper (inferred)
            #expect(resolved.edges.contains(.init(fromKey: "main.py#main", toKey: "pkg/util.py#helper", kind: "calls", confidence: "inferred")))
            _ = utilFacts
        }
    }

    // MARK: - TypeScript

    @Test("typescript: relative imports, implements, method calls")
    func typescriptExtraction() async throws {
        try await withTempWorkspace([
            "app.ts": """
                import { Store } from './store';

                export class App extends Base implements Runnable {
                    run() { this.store.fetch(); }
                }
                """,
            "store.ts": """
                export class Store {
                    fetch() { return 1; }
                }
                """,
        ]) { root in
            let (app, appFacts) = try #require(extract(root, "app.ts"))
            let (store, _) = try #require(extract(root, "store.ts"))

            #expect(app.nodes.map(\.nodeKey).contains("app.ts#App"))
            #expect(app.nodes.map(\.nodeKey).contains("app.ts#App.run"))
            #expect(store.nodes.map(\.nodeKey).contains("store.ts#Store.fetch"))

            var index = GraphWorkspaceIndex()
            index.insert(app, stamp: "1")
            index.insert(store, stamp: "1")
            var resolved = app
            GraphExtractor().resolveCrossFileEdges(extraction: &resolved, facts: appFacts, index: index, roots: [root])

            #expect(resolved.edges.contains(.init(fromKey: "app.ts", toKey: "store.ts", kind: "imports", confidence: "extracted")))
            #expect(resolved.edges.contains(.init(fromKey: "app.ts#App.run", toKey: "store.ts#Store.fetch", kind: "calls", confidence: "inferred")))
        }
    }

    // MARK: - Go

    @Test("go: receiver methods, package directory imports")
    func goExtraction() async throws {
        try await withTempWorkspace([
            "main.go": """
                package main

                import "example.com/app/store"

                func main() {
                    s.Start()
                }
                """,
            "store/store.go": """
                package store

                type Server struct{}

                func (s *Server) Start() {
                }
                """,
        ]) { root in
            let (main, mainFacts) = try #require(extract(root, "main.go"))
            let (store, _) = try #require(extract(root, "store/store.go"))

            let method = try #require(nodes(store, kind: "method").first)
            #expect(method.nodeKey == "store/store.go#Server.Start")

            var index = GraphWorkspaceIndex()
            index.insert(main, stamp: "1")
            index.insert(store, stamp: "1")
            var resolved = main
            GraphExtractor().resolveCrossFileEdges(extraction: &resolved, facts: mainFacts, index: index, roots: [root])

            // directory match: last segment "store" -> store/store.go
            #expect(resolved.edges.contains(.init(fromKey: "main.go", toKey: "store/store.go", kind: "imports", confidence: "extracted")))
            // call to receiver method
            #expect(resolved.edges.contains(.init(fromKey: "main.go#main", toKey: "store/store.go#Server.Start", kind: "calls", confidence: "inferred")))
        }
    }

    // MARK: - Rust

    @Test("rust: impl blocks, use basename resolution")
    func rustExtraction() async throws {
        try await withTempWorkspace([
            "src/main.rs": """
                use crate::store::Store;

                pub struct App;

                impl App {
                    pub fn run(&self) {
                        Store::fetch();
                    }
                }
                """,
            "src/store.rs": """
                pub struct Store;

                impl Store {
                    pub fn fetch() {
                    }
                }
                """,
        ]) { root in
            let (mainRs, mainFacts) = try #require(extract(root, "src/main.rs"))
            let (storeRs, _) = try #require(extract(root, "src/store.rs"))

            #expect(mainRs.nodes.map(\.nodeKey).contains("src/main.rs#App"))
            #expect(mainRs.nodes.map(\.nodeKey).contains("src/main.rs#App.run"))

            var index = GraphWorkspaceIndex()
            index.insert(mainRs, stamp: "1")
            index.insert(storeRs, stamp: "1")
            var resolved = mainRs
            GraphExtractor().resolveCrossFileEdges(extraction: &resolved, facts: mainFacts, index: index, roots: [root])

            #expect(resolved.edges.contains(.init(fromKey: "src/main.rs", toKey: "src/store.rs", kind: "imports", confidence: "extracted")))
            #expect(resolved.edges.contains(.init(fromKey: "src/main.rs#App.run", toKey: "src/store.rs#Store.fetch", kind: "calls", confidence: "inferred")))
        }
    }

    // MARK: - Inheritance

    @Test("inherits edge resolves to type node")
    func inheritsResolution() async throws {
        try await withTempWorkspace([
            "a.swift": """
                public protocol Fetchable {
                }
                """,
            "b.swift": """
                final class Store: Fetchable {
                }
                """,
        ]) { root in
            let (a, _) = try #require(extract(root, "a.swift"))
            let (b, bFacts) = try #require(extract(root, "b.swift"))

            var index = GraphWorkspaceIndex()
            index.insert(a, stamp: "1")
            index.insert(b, stamp: "1")
            var resolved = b
            GraphExtractor().resolveCrossFileEdges(extraction: &resolved, facts: bFacts, index: index, roots: [root])

            #expect(resolved.edges.contains(.init(fromKey: "b.swift#Store", toKey: "a.swift#Fetchable", kind: "inherits", confidence: "extracted")))
        }
    }

    // MARK: - File discovery

    @Test("listSourceFiles skips junk directories and non-source files")
    func fileDiscovery() async throws {
        try await withTempWorkspace([
            "src/a.swift": "func a() {}",
            "node_modules/pkg/b.js": "function b() {}",
            ".git/x.swift": "func x() {}",
            "target/debug/c.rs": "fn c() {}",
            "README.md": "# hi",
            "src/nested/d.ts": "const d = 1;",
        ]) { root in
            let files = GraphExtractor().listSourceFiles(roots: [root]).map { $0.lastPathComponent }.sorted()
            #expect(files == ["a.swift", "d.ts"])
        }
    }

    // MARK: - Sync service

    actor PayloadRecorder {
        var payloads: [GraphUpsertPayload] = []
        func record(_ payload: GraphUpsertPayload) { payloads.append(payload) }
        func clear() { payloads.removeAll() }
    }

    @Test("syncFull upserts everything once, second run is a no-op")
    func syncFullAndStamps() async throws {
        try await withTempWorkspace(["a.swift": "func a() {}"]) { root in
            let recorder = PayloadRecorder()
            let stateDir = root.appendingPathComponent(".state")
            let service = GraphSyncService(
                upsert: { payload in
                    await recorder.record(payload)
                    return true
                },
                stateDirectory: stateDir
            )

            let first = await service.syncFull(workspace: "w", roots: [root])
            #expect(first?.files == 1)
            var payloads = await recorder.payloads
            #expect(payloads.count == 1)
            #expect(payloads.first?.workspace == "w")
            #expect(payloads.first?.files.first?.file == "a.swift")

            await recorder.clear()
            let second = await service.syncFull(workspace: "w", roots: [root])
            #expect(second?.files == 0)
            payloads = await recorder.payloads
            #expect(payloads.isEmpty)
        }
    }

    @Test("syncIncremental replaces changed files and deletes removed ones")
    func syncIncremental() async throws {
        try await withTempWorkspace([
            "a.swift": "func a() {}",
            "b.swift": "func b() {}",
        ]) { root in
            let recorder = PayloadRecorder()
            let stateDir = root.appendingPathComponent(".state")
            let service = GraphSyncService(
                upsert: { payload in
                    await recorder.record(payload)
                    return true
                },
                stateDirectory: stateDir
            )
            _ = await service.syncFull(workspace: "w", roots: [root])
            await recorder.clear()

            // modify a.swift, delete b.swift
            try "func a2() {}".write(to: root.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(at: root.appendingPathComponent("b.swift"))

            let stats = await service.syncIncremental(workspace: "w", roots: [root], changedPaths: ["a.swift", "b.swift"])
            #expect(stats?.files == 1)
            #expect(stats?.deletedFiles == 1)
            let payload = try #require(await recorder.payloads.first)
            #expect(payload.files.first?.nodes.contains { $0.name == "a2" } == true)
            #expect(payload.deletedFiles == ["b.swift"])
        }
    }

    @Test("sync returns nil when no graph server is bridged")
    func syncUnavailable() async throws {
        try await withTempWorkspace(["a.swift": "func a() {}"]) { root in
            let service = GraphSyncService(
                upsert: { _ in false },
                stateDirectory: root.appendingPathComponent(".state")
            )
            let stats = await service.syncFull(workspace: "w", roots: [root])
            #expect(stats == nil)
        }
    }

    @Test("multi-root: node keys are folder-prefixed")
    func multiRootKeys() throws {
        let dirA = FileManager.default.temporaryDirectory.appendingPathComponent("wsA-\(UUID().uuidString)")
        let dirB = FileManager.default.temporaryDirectory.appendingPathComponent("wsB-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
        }
        try "func a() {}".write(to: dirA.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        try "func b() {}".write(to: dirB.appendingPathComponent("b.swift"), atomically: true, encoding: .utf8)

        let roots = [dirA, dirB]
        let keyA = GraphExtractor.relativePath(for: dirA.appendingPathComponent("a.swift"), in: roots)
        let keyB = GraphExtractor.relativePath(for: dirB.appendingPathComponent("b.swift"), in: roots)
        #expect(keyA == "\(dirA.lastPathComponent)/a.swift")
        #expect(keyB == "\(dirB.lastPathComponent)/b.swift")
    }
}
