import Foundation

/// A multi-root workspace (VS Code style): one project unit spanning several
/// folders. folders[0] is the primary root — bash cwd, config source, and the
/// default for relative paths. Migrated single-folder projects keep the legacy
/// path-hash as id so their SessionStore directory (base/<hash>/sessions) is
/// preserved across the upgrade.
public struct Workspace: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var folders: [URL]
    /// Extra per-workspace instructions appended to the system prompt after
    /// AGENTS.md (editable in the workspace dialog). Optional — older
    /// workspaces.json files simply lack the key.
    public var systemContext: String?
    public var created: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        folders: [URL],
        systemContext: String? = nil,
        created: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.folders = folders
        self.systemContext = systemContext
        self.created = created
    }

    // Folders encode as plain path strings (hand-editable workspaces.json);
    // decoding also accepts the earlier "file:///…" URL form.
    enum CodingKeys: String, CodingKey { case id, name, folders, systemContext, created }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        let rawFolders = try container.decode([String].self, forKey: .folders)
        folders = rawFolders.map { raw in
            if raw.hasPrefix("file://"), let url = URL(string: raw) { return url }
            return URL(fileURLWithPath: raw)
        }
        systemContext = try container.decodeIfPresent(String.self, forKey: .systemContext)
        created = try container.decode(Date.self, forKey: .created)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(folders.map(\.path), forKey: .folders)
        try container.encodeIfPresent(systemContext, forKey: .systemContext)
        try container.encode(created, forKey: .created)
    }

    /// Primary root: bash cwd, config source, default for relative paths.
    public var primaryRoot: URL { folders[0] }

    /// Wrap one folder as a workspace, keeping the legacy SessionStore hash so
    /// existing sessions remain readable (migration path).
    public static func legacy(folder: URL) -> Workspace {
        Workspace(
            id: SessionStore.projectHash(folder),
            name: folder.lastPathComponent,
            folders: [folder]
        )
    }
}

/// Persists workspaces at ~/.config/ninty/workspaces.json.
public actor WorkspaceStore {
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ninty/workspaces.json")
    }

    public func load() -> [Workspace] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Workspace].self, from: data)) ?? []
    }

    public func save(_ workspaces: [Workspace]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(workspaces).write(to: fileURL, options: .atomic)
    }
}
