import Foundation

public struct ToolContext: Sendable {
    /// Workspace roots, first = primary. Multi-root workspaces address
    /// non-primary roots via a folder-name prefix ("api/app/main.py").
    public var projectRoots: [URL]
    public var sessionID: String

    public init(projectRoots: [URL], sessionID: String) {
        self.projectRoots = projectRoots
        self.sessionID = sessionID
    }

    public init(projectRoot: URL, sessionID: String) {
        self.init(projectRoots: [projectRoot], sessionID: sessionID)
    }

    /// Primary root: bash cwd, config source, default for relative paths.
    public var projectRoot: URL { projectRoots[0] }

    /// Resolve a user-supplied path against the workspace roots.
    /// Absolute paths pass through; "folderName/relative" addresses the root
    /// whose last path component matches; a bare root folder name ("meetily")
    /// addresses that root itself; plain relative paths are primary-relative.
    public func resolve(_ path: String) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        if projectRoots.count > 1 {
            if let (root, rest) = prefixedMatch(path) {
                return root.appendingPathComponent(rest).standardizedFileURL
            }
            if !path.contains("/"), let root = root(named: path) {
                return root.standardizedFileURL
            }
        }
        return projectRoot.appendingPathComponent(path).standardizedFileURL
    }

    /// Read-side resolve for multi-root workspaces: primary-relative when the
    /// file exists there, otherwise the first root where it exists. Misses
    /// fall back to the primary path (familiar error messages). Models rarely
    /// prefix reliably — this keeps plain relative paths working across roots.
    public func resolveExisting(_ path: String) -> URL {
        if path.hasPrefix("/") { return resolve(path) }
        if projectRoots.count > 1 {
            if let (root, rest) = prefixedMatch(path) {
                return root.appendingPathComponent(rest).standardizedFileURL
            }
            if !path.contains("/"), let root = root(named: path) {
                return root.standardizedFileURL
            }
            let primary = projectRoot.appendingPathComponent(path).standardizedFileURL
            if FileManager.default.fileExists(atPath: primary.path) { return primary }
            for root in projectRoots.dropFirst() {
                let candidate = root.appendingPathComponent(path).standardizedFileURL
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        return resolve(path)
    }

    /// True when `url` lies inside any workspace root.
    public func isInsideProject(_ url: URL) -> Bool {
        root(containing: url) != nil
    }

    /// Root containing `url` (standardized prefix match), nil when outside all roots.
    public func root(containing url: URL) -> URL? {
        let path = url.standardizedFileURL.path
        return projectRoots.first {
            let rootPath = $0.standardizedFileURL.path
            return path == rootPath || path.hasPrefix(rootPath + "/")
        }
    }

    /// Display/mention path for a URL: relative to its root, prefixed with the
    /// root's folder name when the workspace has multiple roots. URLs outside
    /// all roots stay absolute.
    public func mentionPath(for url: URL) -> String {
        guard let root = root(containing: url) else { return url.path }
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let relative = path == rootPath ? "" : String(path.dropFirst(rootPath.count + 1))
        guard projectRoots.count > 1 else { return relative }
        return relative.isEmpty ? root.lastPathComponent : "\(root.lastPathComponent)/\(relative)"
    }

    /// Split "folderName/rest" when folderName matches a root's last component.
    private func prefixedMatch(_ path: String) -> (URL, String)? {
        guard let slash = path.firstIndex(of: "/") else { return nil }
        let prefix = String(path[..<slash])
        guard let root = root(named: prefix) else { return nil }
        return (root, String(path[path.index(after: slash)...]))
    }

    /// Root whose folder (last path component) is exactly `name`.
    private func root(named name: String) -> URL? {
        projectRoots.first { $0.lastPathComponent == name }
    }
}

public struct ToolResult: Sendable, Equatable {
    public var output: String
    public var isError: Bool

    public init(output: String, isError: Bool = false) {
        self.output = output
        self.isError = isError
    }

    public static func error(_ message: String) -> ToolResult {
        ToolResult(output: message, isError: true)
    }
}

public enum ToolError: Error, Sendable, Equatable {
    case missingParameter(String)
    case invalidParameter(String, String)
}

public protocol AgentTool: Sendable {
    var name: String { get }
    var description: String { get }
    var parameters: JSONSchema { get }
    func execute(_ args: JSONValue, ctx: ToolContext) async throws -> ToolResult
}

extension AgentTool {
    public var definition: ToolDefinition {
        ToolDefinition(name: name, description: description, parameters: parameters)
    }
}

extension JSONValue {
    func requireString(_ key: String) throws -> String {
        guard let value = self[key]?.stringValue else { throw ToolError.missingParameter(key) }
        return value
    }

    func optionalString(_ key: String) -> String? {
        self[key]?.stringValue
    }

    func optionalInt(_ key: String) -> Int? {
        self[key]?.intValue
    }

    func optionalBool(_ key: String) -> Bool? {
        self[key]?.boolValue
    }
}
