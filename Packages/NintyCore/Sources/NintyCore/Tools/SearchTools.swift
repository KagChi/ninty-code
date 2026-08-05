import Foundation

// MARK: - glob

public struct GlobTool: AgentTool {
    public init() {}
    public let name = "glob"
    public let description = "Find files by wildcard pattern (e.g. \"**/*.swift\"). Sorted by modification time, newest first."
    public let parameters: JSONSchema = .object(
        properties: [
            "pattern": .string("Glob pattern. ** matches any number of directories."),
            "path": .string("Directory to search (default: project root)")
        ],
        required: ["pattern"]
    )

    static let maxResults = 100
    static let skippedDirectories: Set<String> = [".git", "node_modules", ".build", "DerivedData", ".swiftpm"]

    /// Synchronous directory walk (enumerator iteration is unavailable in async contexts).
    /// Stops after `limit` files to bound time/memory on large trees.
    /// `includeDirectories` adds directories to the result (used by the
    /// @-mention corpus — opencode lets you mention folders); skipped
    /// directories are never included, nor are their contents.
    public static func collectFiles(base: URL, keys: [URLResourceKey], limit: Int = 10_000, includeDirectories: Bool = false) -> [URL]? {
        guard let enumerator = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return nil }
        var files: [URL] = []
        files.reserveCapacity(min(limit, 1_024))
        for case let url as URL in enumerator {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                if skippedDirectories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                } else if includeDirectories {
                    files.append(url)
                }
                if files.count >= limit { break }
                continue
            }
            files.append(url)
            if files.count >= limit { break }
        }
        return files
    }

    public func execute(_ args: JSONValue, ctx: ToolContext) async throws -> ToolResult {
        let pattern = try args.requireString("pattern")
        let base = ctx.resolveExisting(args.optionalString("path") ?? ".")
        let matcher = GlobMatcher(pattern: pattern)
        guard let files = Self.collectFiles(base: base, keys: [.contentModificationDateKey, .isDirectoryKey]) else {
            return .error("Cannot enumerate: \(base.path)")
        }
        var matches: [(url: URL, mtime: Date)] = []
        let basePath = base.resolvingSymlinksInPath().path
        for url in files {
            let filePath = url.resolvingSymlinksInPath().path
            let relative = filePath.hasPrefix(basePath + "/")
                ? String(filePath.dropFirst(basePath.count + 1))
                : filePath
            if matcher.matches(relative) {
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                matches.append((url, mtime))
            }
        }
        matches.sort { $0.mtime > $1.mtime }
        let shown = matches.prefix(Self.maxResults)
        var output = shown.map(\.url.path).joined(separator: "\n")
        if matches.count > Self.maxResults {
            output += "\n(\(matches.count - Self.maxResults) more matches)"
        }
        return ToolResult(output: output.isEmpty ? "No matches." : output)
    }
}

/// Minimal glob matcher: * (any within segment), ** (any across segments), ? (single char).
struct GlobMatcher: Sendable {
    let regex: NSRegularExpression

    init(pattern: String) {
        var regex = "^"
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let char = pattern[index]
            let next = pattern.index(after: index)
            if char == "*" {
                if next < pattern.endIndex && pattern[next] == "*" {
                    // `**/` matches zero or more directories; bare `**` matches anything.
                    let afterDouble = next < pattern.endIndex ? pattern.index(after: next) : next
                    if afterDouble < pattern.endIndex && pattern[afterDouble] == "/" {
                        regex += "(?:.*/)?"
                        index = pattern.index(after: afterDouble)
                        continue
                    }
                    regex += ".*"
                    index = afterDouble
                    continue
                }
                regex += "[^/]*"
            } else if char == "?" {
                regex += "[^/]"
            } else {
                regex += NSRegularExpression.escapedPattern(for: String(char))
            }
            index = next
        }
        regex += "$"
        self.regex = (try? NSRegularExpression(pattern: regex)) ?? (try! NSRegularExpression(pattern: "a^"))
    }

    func matches(_ path: String) -> Bool {
        regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }
}

// MARK: - grep

public struct GrepTool: AgentTool {
    public init() {}
    public let name = "grep"
    public let description = "Search file contents with a regular expression. Returns file:line matches."
    public let parameters: JSONSchema = .object(
        properties: [
            "pattern": .string("Regular expression"),
            "path": .string("Directory or file to search (default: project root)"),
            "include": .string("Limit to files matching glob, e.g. \"*.swift\"")
        ],
        required: ["pattern"]
    )

    static let maxMatches = 100

    public func execute(_ args: JSONValue, ctx: ToolContext) async throws -> ToolResult {
        let pattern = try args.requireString("pattern")
        let base = ctx.resolveExisting(args.optionalString("path") ?? ".")
        let include = args.optionalString("include").map(GlobMatcher.init(pattern:))
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return .error("Invalid regular expression: \(pattern)")
        }
        var matches: [String] = []
        var isDir: ObjCBool = false
        let files: [URL]
        if FileManager.default.fileExists(atPath: base.path, isDirectory: &isDir), !isDir.boolValue {
            files = [base]
        } else {
            guard let collected = GlobTool.collectFiles(base: base, keys: [.isDirectoryKey]) else {
                return .error("Cannot enumerate: \(base.path)")
            }
            files = collected
        }
        outer: for file in files {
            if let include, !include.matches(file.lastPathComponent) { continue }
            guard let data = try? Data(contentsOf: file), !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else { continue }
            let lines = text.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                if regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                    matches.append("\(file.path):\(index + 1): \(line.prefix(200))")
                    if matches.count >= Self.maxMatches { break outer }
                }
            }
        }
        return ToolResult(output: matches.isEmpty ? "No matches." : matches.joined(separator: "\n"))
    }
}
