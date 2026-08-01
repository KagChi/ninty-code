import Foundation

// MARK: - read

public struct ReadTool: AgentTool {
    public init() {}
    public let name = "read"
    public let description = "Read a file with line numbers. Use offset/limit for large files."
    public let parameters: JSONSchema = .object(
        properties: [
            "path": .string("File path (relative to project root or absolute)"),
            "offset": .integer("Line number to start from (1-based)"),
            "limit": .integer("Max lines to read (default 2000)")
        ],
        required: ["path"]
    )

    static let maxLines = 2000
    static let maxLineLength = 2000

    public func execute(_ args: JSONValue, ctx: ToolContext) async throws -> ToolResult {
        let url = ctx.resolve(try args.requireString("path"))
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return .error("Cannot read file: \(url.path)")
        }
        let lines = text.components(separatedBy: .newlines)
        let offset = max((args.optionalInt("offset") ?? 1) - 1, 0)
        let limit = args.optionalInt("limit") ?? Self.maxLines
        guard offset < lines.count else {
            return .error("Offset \(offset + 1) beyond end of file (\(lines.count) lines)")
        }
        let slice = lines[offset..<min(offset + limit, lines.count)]
        var output = ""
        for (index, line) in slice.enumerated() {
            let truncated = line.count > Self.maxLineLength ? String(line.prefix(Self.maxLineLength)) : line
            output += "\(offset + index + 1): \(truncated)\n"
        }
        if offset + limit < lines.count {
            output += "(\(lines.count - offset - limit) more lines — use offset to continue)"
        }
        return ToolResult(output: output)
    }
}

// MARK: - write

public struct WriteTool: AgentTool {
    public init() {}
    public let name = "write"
    public let description = "Create or overwrite a file. Parent directories are created."
    public let parameters: JSONSchema = .object(
        properties: [
            "path": .string("File path (relative to project root or absolute)"),
            "content": .string("Full file content")
        ],
        required: ["path", "content"]
    )

    public func execute(_ args: JSONValue, ctx: ToolContext) async throws -> ToolResult {
        let url = ctx.resolve(try args.requireString("path"))
        let content = try args.requireString("content")
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return .error("Write failed: \(error.localizedDescription)")
        }
        return ToolResult(output: "Wrote \(content.count) characters to \(url.path)")
    }
}

// MARK: - edit

public struct EditTool: AgentTool {
    public init() {}
    public let name = "edit"
    public let description = "Replace an exact string in a file. Fails when oldString is absent or ambiguous (unless replaceAll)."
    public let parameters: JSONSchema = .object(
        properties: [
            "path": .string("File path"),
            "oldString": .string("Exact text to replace"),
            "newString": .string("Replacement text"),
            "replaceAll": .boolean("Replace every occurrence")
        ],
        required: ["path", "oldString", "newString"]
    )

    public func execute(_ args: JSONValue, ctx: ToolContext) async throws -> ToolResult {
        let url = ctx.resolve(try args.requireString("path"))
        let oldString = try args.requireString("oldString")
        let newString = try args.requireString("newString")
        let replaceAll = args.optionalBool("replaceAll") ?? false
        guard oldString != newString else {
            return .error("oldString and newString are identical")
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return .error("Cannot read file: \(url.path)")
        }
        let occurrences = text.components(separatedBy: oldString).count - 1
        guard occurrences > 0 else {
            return .error("oldString not found in \(url.lastPathComponent)")
        }
        guard replaceAll || occurrences == 1 else {
            return .error("oldString matches \(occurrences) times — provide more context or set replaceAll")
        }
        let updated = text.replacingOccurrences(of: oldString, with: newString)
        do {
            try updated.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return .error("Write failed: \(error.localizedDescription)")
        }
        return ToolResult(output: "Edited \(url.lastPathComponent): \(replaceAll ? "\(occurrences) replacements" : "1 replacement")")
    }
}

// MARK: - list

public struct ListTool: AgentTool {
    public init() {}
    public let name = "list"
    public let description = "List directory contents. Directories are suffixed with /."
    public let parameters: JSONSchema = .object(
        properties: ["path": .string("Directory path (default: project root)")]
    )

    static let maxEntries = 200

    public func execute(_ args: JSONValue, ctx: ToolContext) async throws -> ToolResult {
        let url = ctx.resolve(args.optionalString("path") ?? ".")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return .error("Cannot list directory: \(url.path)")
        }
        var names: [String] = []
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            names.append(entry.lastPathComponent + (isDir ? "/" : ""))
        }
        names.sort { a, b in
            let aHidden = a.hasPrefix("."), bHidden = b.hasPrefix(".")
            if aHidden != bHidden { return !aHidden }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
        let shown = names.prefix(Self.maxEntries)
        var output = shown.joined(separator: "\n")
        if names.count > Self.maxEntries {
            output += "\n(\(names.count - Self.maxEntries) more entries)"
        }
        return ToolResult(output: output.isEmpty ? "(empty directory)" : output)
    }
}
