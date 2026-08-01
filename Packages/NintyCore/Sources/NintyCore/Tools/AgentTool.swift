import Foundation

public struct ToolContext: Sendable {
    public var projectRoot: URL
    public var sessionID: String

    public init(projectRoot: URL, sessionID: String) {
        self.projectRoot = projectRoot
        self.sessionID = sessionID
    }

    /// Resolve a user-supplied path against the project root.
    /// Absolute paths pass through; relative paths are root-relative.
    public func resolve(_ path: String) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return projectRoot.appendingPathComponent(path).standardizedFileURL
    }

    /// True when `url` lies inside the project root.
    public func isInsideProject(_ url: URL) -> Bool {
        let rootPath = projectRoot.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
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
