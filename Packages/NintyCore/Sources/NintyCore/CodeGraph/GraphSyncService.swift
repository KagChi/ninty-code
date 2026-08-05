import Foundation

/// Keeps the remote code graph (graph-mcp via MCP) in sync with the
/// workspace on disk. Extraction is local and deterministic; the server
/// owns storage, embeddings, and queries.
///
/// Triggers: full sync on workspace open (stale-only), debounced
/// incremental sync on agent turn end (changed files). Silently no-ops
/// when no graph server is bridged.
public actor GraphSyncService {

    public struct Stats: Sendable, Equatable {
        public var files: Int
        public var nodes: Int
        public var edges: Int
        public var deletedFiles: Int
        public var skipped: Bool

        public init(files: Int = 0, nodes: Int = 0, edges: Int = 0, deletedFiles: Int = 0, skipped: Bool = false) {
            self.files = files
            self.nodes = nodes
            self.edges = edges
            self.deletedFiles = deletedFiles
            self.skipped = skipped
        }
    }

    /// Returns false when no graph server is available (caller skips silently).
    public typealias UpsertHandler = @Sendable (GraphUpsertPayload) async throws -> Bool

    private let extractor = GraphExtractor()
    private let upsert: UpsertHandler
    private let stateDirectory: URL

    private var indexes: [String: GraphWorkspaceIndex] = [:]
    private var factsByWorkspace: [String: [String: GraphFileFacts]] = [:]
    private var pendingSyncs: [String: Task<Void, Never>] = [:]

    public init(
        upsert: @escaping UpsertHandler,
        stateDirectory: URL? = nil
    ) {
        self.upsert = upsert
        self.stateDirectory = stateDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/share/ninty/graph", isDirectory: true)
    }

    // MARK: - Full sync

    /// Extract source files and upsert what changed. Files whose
    /// mtime/size stamp matches the persisted state are reused as-is (no
    /// re-extract, no re-upsert — avoids server-side re-embedding churn on
    /// every app launch). `force` re-upserts everything (manual resync,
    /// recovery after a server-side clear). Returns nil when no graph
    /// server is bridged.
    @discardableResult
    public func syncFull(workspace: String, roots: [URL], force: Bool = false) async -> Stats? {
        let previous = loadState(workspace: workspace)
        let files = extractor.listSourceFiles(roots: roots)
        var index = GraphWorkspaceIndex()
        var facts: [String: GraphFileFacts] = [:]
        var extractions: [String: GraphFileExtraction] = [:]
        var dirtyFiles: [GraphFileExtraction] = []

        // Phase 1: extract changed files; reuse persisted ones untouched.
        for url in files {
            guard let key = GraphExtractor.relativePath(for: url, in: roots) else { continue }
            let stamp = GraphExtractor.stamp(for: url)

            if !force, previous.stamps[key] == stamp, let cached = previous.extractions[key] {
                index.insert(cached, stamp: stamp)
                extractions[key] = cached
                continue
            }

            guard let (extraction, fileFacts) = extractor.extractFile(url: url, relativePath: key) else { continue }
            index.insert(extraction, stamp: stamp)
            extractions[key] = extraction
            facts[key] = fileFacts
        }

        // Phase 2: resolve cross-file edges for newly extracted files.
        for key in facts.keys.sorted() {
            guard var extraction = extractions[key], let fileFacts = facts[key] else { continue }
            extractor.resolveCrossFileEdges(extraction: &extraction, facts: fileFacts, index: index, roots: roots)
            extractions[key] = extraction
            index.extractions[key] = extraction
            dirtyFiles.append(extraction)
        }

        // Deletions: previously synced files no longer on disk.
        let deleted = previous.stamps.keys.filter { extractions[$0] == nil }.sorted()

        // Upsert in batches (dirty files only, unless forced).
        var stats = Stats(deletedFiles: deleted.count)
        let toUpsert = force ? extractions.keys.sorted().map { extractions[$0]! } : dirtyFiles
        let batchSize = 100
        var batch: [GraphFileExtraction] = []
        var firstBatch = true
        for extraction in toUpsert {
            batch.append(extraction)
            if batch.count >= batchSize {
                let deletions = firstBatch ? deleted : []
                guard await send(workspace: workspace, files: batch, deletedFiles: deletions, stats: &stats) else { return nil }
                firstBatch = false
                batch.removeAll()
            }
        }
        if !batch.isEmpty || !deleted.isEmpty && firstBatch {
            let deletions = firstBatch ? deleted : []
            guard await send(workspace: workspace, files: batch, deletedFiles: deletions, stats: &stats) else { return nil }
        }

        indexes[workspace] = index
        factsByWorkspace[workspace] = facts
        saveState(workspace: workspace, index: index)
        return stats
    }

    // MARK: - Incremental sync

    /// Debounced incremental sync for agent-mutated files (turn end hook).
    public func scheduleIncremental(workspace: String, roots: [URL], changedPaths: [String]) {
        let key = workspace
        pendingSyncs[key]?.cancel()
        pendingSyncs[key] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            _ = await self?.syncIncremental(workspace: workspace, roots: roots, changedPaths: changedPaths)
        }
    }

    /// Re-extract changed files and upsert them (replace-per-file
    /// server-side). Falls back to a full sync when no index exists yet.
    @discardableResult
    public func syncIncremental(workspace: String, roots: [URL], changedPaths: [String]) async -> Stats? {
        guard var index = indexes[workspace] else {
            return await syncFull(workspace: workspace, roots: roots)
        }
        var facts = factsByWorkspace[workspace] ?? [:]

        var updated: [GraphFileExtraction] = []
        var deleted: [String] = []
        let fm = FileManager.default

        for path in Set(changedPaths) {
            guard let url = resolveURL(path: path, roots: roots) else { continue }
            guard let key = GraphExtractor.relativePath(for: url, in: roots) else { continue }

            let exists = fm.fileExists(atPath: url.path)
            let isSource = LanguageSpec.spec(for: url) != nil
            if !exists || !isSource {
                if index.extractions[key] != nil {
                    index.remove(key)
                    facts.removeValue(forKey: key)
                    deleted.append(key)
                }
                continue
            }

            guard let extracted = extractor.extractFile(url: url, relativePath: key) else { continue }
            var extraction = extracted.extraction
            let fileFacts = extracted.facts
            let stamp = GraphExtractor.stamp(for: url)
            index.insert(extraction, stamp: stamp)
            facts[key] = fileFacts
            extractor.resolveCrossFileEdges(extraction: &extraction, facts: fileFacts, index: index, roots: roots)
            index.extractions[key] = extraction
            updated.append(extraction)
        }

        guard !updated.isEmpty || !deleted.isEmpty else {
            return Stats(skipped: true)
        }

        var stats = Stats(deletedFiles: deleted.count)
        guard await send(workspace: workspace, files: updated, deletedFiles: deleted, stats: &stats) else { return nil }

        indexes[workspace] = index
        factsByWorkspace[workspace] = facts
        saveState(workspace: workspace, index: index)
        return stats
    }

    /// Drop local state (e.g. after a server-side clear).
    public func reset(workspace: String) {
        indexes.removeValue(forKey: workspace)
        factsByWorkspace.removeValue(forKey: workspace)
        try? FileManager.default.removeItem(at: stateFile(workspace: workspace))
    }

    // MARK: - Internals

    private func send(
        workspace: String,
        files: [GraphFileExtraction],
        deletedFiles: [String],
        stats: inout Stats
    ) async -> Bool {
        let payload = GraphUpsertPayload(workspace: workspace, files: files, deletedFiles: deletedFiles)
        do {
            guard try await upsert(payload) else { return false }
            stats.files += files.count
            stats.nodes += files.reduce(0) { $0 + $1.nodes.count }
            stats.edges += files.reduce(0) { $0 + $1.edges.count }
            return true
        } catch {
            return false
        }
    }

    private func resolveURL(path: String, roots: [URL]) -> URL? {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        if roots.count > 1 {
            for root in roots where path.hasPrefix(root.lastPathComponent + "/") {
                return root.appendingPathComponent(String(path.dropFirst(root.lastPathComponent.count + 1)))
            }
        }
        return roots.first?.appendingPathComponent(path)
    }

    private func stateFile(workspace: String) -> URL {
        stateDirectory.appendingPathComponent("\(workspace).json")
    }

    /// Persisted sync state: stamps for staleness, extractions for reuse.
    struct PersistedState: Codable, Sendable {
        var stamps: [String: String]
        var extractions: [String: GraphFileExtraction]
    }

    private func loadState(workspace: String) -> PersistedState {
        guard let data = try? Data(contentsOf: stateFile(workspace: workspace)),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else {
            return PersistedState(stamps: [:], extractions: [:])
        }
        return state
    }

    private func saveState(workspace: String, index: GraphWorkspaceIndex) {
        let state = PersistedState(stamps: index.fileStamps, extractions: index.extractions)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try? data.write(to: stateFile(workspace: workspace), options: .atomic)
    }
}
