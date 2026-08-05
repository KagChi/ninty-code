import Foundation

public struct SessionMeta: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var agentID: String
    public var model: String
    public var created: Date
    public var updated: Date
    /// Last known input token count (header usage ring survives reloads).
    public var inputTokens: Int?

    public init(id: String, title: String, agentID: String, model: String, created: Date, updated: Date, inputTokens: Int? = nil) {
        self.id = id
        self.title = title
        self.agentID = agentID
        self.model = model
        self.created = created
        self.updated = updated
        self.inputTokens = inputTokens
    }
}

/// One append-only JSONL event per line.
enum SessionRecord: Codable {
    case meta(SessionMeta)
    case message(Message)

    enum CodingKeys: String, CodingKey { case type, meta, message }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "meta":
            self = .meta(try container.decode(SessionMeta.self, forKey: .meta))
        case "message":
            self = .message(try container.decode(Message.self, forKey: .message))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "unknown record type")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .meta(let meta):
            try container.encode("meta", forKey: .type)
            try container.encode(meta, forKey: .meta)
        case .message(let message):
            try container.encode("message", forKey: .type)
            try container.encode(message, forKey: .message)
        }
    }
}

/// Persists sessions as JSONL files under ~/.local/share/ninty/project/<hash>/sessions/.
public actor SessionStore {
    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(projectRoot: URL, baseDirectory: URL? = nil) {
        let base = baseDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/ninty/project")
        let hash = Self.projectHash(projectRoot)
        self.directory = base.appendingPathComponent(hash).appendingPathComponent("sessions")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    static func projectHash(_ url: URL) -> String {
        // FNV-1a 64-bit — stable, no CryptoKit import needed.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in url.standardizedFileURL.path.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    private func fileURL(id: String) -> URL {
        directory.appendingPathComponent("\(id).jsonl")
    }

    /// Create a new session file with its meta record.
    @discardableResult
    public func create(id: String, title: String, agentID: String, model: String) throws -> SessionMeta {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        let meta = SessionMeta(id: id, title: title, agentID: agentID, model: model, created: now, updated: now)
        let data = try encoder.encode(SessionRecord.meta(meta))
        try (data + Data("\n".utf8)).write(to: fileURL(id: id), options: .atomic)
        setIndexMeta(meta)
        return meta
    }

    /// Append a message record + refresh meta.updated in the sidecar index.
    public func append(_ message: Message, sessionID: String) throws {
        let data = try encoder.encode(SessionRecord.message(message))
        let handle = try FileHandle(forWritingTo: fileURL(id: sessionID))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data + Data("\n".utf8))
        if var meta = index[sessionID] {
            meta.updated = Date()
            index[sessionID] = meta
            saveIndex()
        }
    }

    // MARK: - Sidecar index (O(1) listing, no full-file parses)

    private var indexURL: URL {
        directory.appendingPathComponent(".index.json")
    }

    private var indexCache: [String: SessionMeta]?
    private var index: [String: SessionMeta] {
        get {
            if let indexCache { return indexCache }
            if let data = try? Data(contentsOf: indexURL),
               let decoded = try? decoder.decode([String: SessionMeta].self, from: data) {
                return decoded
            }
            return [:]
        }
        set { indexCache = newValue }
    }

    private func saveIndex() {
        guard let data = try? encoder.encode(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private func setIndexMeta(_ meta: SessionMeta) {
        index[meta.id] = meta
        saveIndex()
    }

    /// List session metas, newest updated first. Reads only the sidecar index — cheap.
    public func listMetas() throws -> [SessionMeta] {
        index.values.sorted { $0.updated > $1.updated }
    }

    /// Load meta + full message history. Corrupt lines are skipped.
    /// Mutable fields (title, selection, usage) come from the sidecar index —
    /// the file's meta record keeps the original values.
    public func load(id: String) throws -> (meta: SessionMeta, messages: [Message])? {
        let (fileMeta, messages) = try readAll(id: id)
        guard var meta = fileMeta else { return nil }
        if let indexed = index[id] {
            meta.title = indexed.title
            meta.agentID = indexed.agentID
            meta.model = indexed.model
            meta.inputTokens = indexed.inputTokens
        }
        return (meta, messages)
    }

    private func readAll(id: String) throws -> (SessionMeta?, [Message]) {
        let url = fileURL(id: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return (nil, []) }
        let text = try String(contentsOf: url, encoding: .utf8)
        var meta: SessionMeta?
        var messages: [Message] = []
        for line in text.components(separatedBy: .newlines) where !line.isEmpty {
            guard let record = try? decoder.decode(SessionRecord.self, from: Data(line.utf8)) else {
                continue // corrupt line — skip
            }
            switch record {
            case .meta(let value): meta = value
            case .message(let value): messages.append(value)
            }
        }
        return (meta, messages)
    }

    /// List all sessions, newest updated first. Reads only first lines — cheap.
    public func list() throws -> [SessionMeta] {
        try listMetas()
    }

    public func delete(id: String) throws {
        try FileManager.default.removeItem(at: fileURL(id: id))
        index[id] = nil
        saveIndex()
    }

    /// Wipe every session of this project (delete-project flow): removes
    /// the whole per-project directory (<base>/<hash>/), index included.
    public func deleteAll() throws {
        let projectDirectory = directory.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: projectDirectory.path) else { return }
        try FileManager.default.removeItem(at: projectDirectory)
    }

    /// Fork: copy meta + first `keepCount` messages into a new session id (opencode /fork).
    @discardableResult
    public func fork(id sourceID: String, keepingMessages keepCount: Int, newID: String) throws -> SessionMeta? {
        let (meta, messages) = try readAll(id: sourceID)
        guard let meta else { return nil }
        let now = Date()
        let forked = SessionMeta(
            id: newID, title: meta.title + " (fork)", agentID: meta.agentID, model: meta.model,
            created: now, updated: now
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var lines: [Data] = [try encoder.encode(SessionRecord.meta(forked))]
        for message in messages.prefix(keepCount) {
            lines.append(try encoder.encode(SessionRecord.message(message)))
        }
        let data = lines.map { $0 + Data("\n".utf8) }.reduce(Data(), +)
        try data.write(to: fileURL(id: newID), options: .atomic)
        setIndexMeta(forked)
        return forked
    }

    /// Permanently drop all messages after the first `keepCount` (opencode cleanup on new prompt after revert).
    public func truncate(keepingMessages keepCount: Int, sessionID: String) throws {
        let (meta, messages) = try readAll(id: sessionID)
        guard let meta else { return }
        var lines: [Data] = [try encoder.encode(SessionRecord.meta(meta))]
        for message in messages.prefix(keepCount) {
            lines.append(try encoder.encode(SessionRecord.message(message)))
        }
        let data = lines.map { $0 + Data("\n".utf8) }.reduce(Data(), +)
        try data.write(to: fileURL(id: sessionID), options: .atomic)
    }

    /// Update the session title (sidecar index only — meta record in the file keeps the original).
    public func updateTitle(_ title: String, sessionID: String) throws {
        guard var meta = index[sessionID] else { return }
        meta.title = title
        index[sessionID] = meta
        saveIndex()
    }

    /// Update agent/model selection (sidecar index only).
    public func updateSelection(agentID: String, model: String, sessionID: String) throws {
        guard var meta = index[sessionID] else { return }
        meta.agentID = agentID
        meta.model = model
        index[sessionID] = meta
        saveIndex()
    }

    /// Persist last known input token count (sidecar index only).
    public func updateUsage(inputTokens: Int, sessionID: String) throws {
        guard var meta = index[sessionID] else { return }
        meta.inputTokens = inputTokens
        index[sessionID] = meta
        saveIndex()
    }
}
