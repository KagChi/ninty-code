import Foundation

public struct SessionMeta: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var agentID: String
    public var model: String
    public var created: Date
    public var updated: Date

    public init(id: String, title: String, agentID: String, model: String, created: Date, updated: Date) {
        self.id = id
        self.title = title
        self.agentID = agentID
        self.model = model
        self.created = created
        self.updated = updated
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
        return meta
    }

    /// Append a message record + touch updated timestamp (rewrites meta line).
    public func append(_ message: Message, sessionID: String) throws {
        let data = try encoder.encode(SessionRecord.message(message))
        let handle = try FileHandle(forWritingTo: fileURL(id: sessionID))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data + Data("\n".utf8))
    }

    /// Load meta + full message history. Corrupt lines are skipped.
    public func load(id: String) throws -> (meta: SessionMeta, messages: [Message])? {
        let (meta, messages) = try readAll(id: id)
        guard let meta else { return nil }
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

    /// List all sessions, newest updated first.
    public func list() throws -> [SessionMeta] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return [] }
        var metas: [SessionMeta] = []
        for file in files where file.pathExtension == "jsonl" {
            let id = file.deletingPathExtension().lastPathComponent
            let (meta, _) = try readAll(id: id)
            if let meta {
                metas.append(meta)
            }
        }
        return metas.sorted { $0.updated > $1.updated }
    }

    public func delete(id: String) throws {
        try FileManager.default.removeItem(at: fileURL(id: id))
    }
}
