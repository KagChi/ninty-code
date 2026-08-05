import Foundation

/// Raw per-file facts collected during extraction, resolved into edges once
/// the workspace-wide symbol index exists (two-phase extraction).
public struct GraphFileFacts: Sendable {
    public struct ImportRef: Sendable {
        public let module: String
        public let strategy: LanguageSpec.ImportStrategy
        public let stripPrefix: NSRegularExpression?
    }
    public struct InheritRef: Sendable {
        public let childKey: String
        public let clause: String
        public let edgeKind: String // inherits | implements
    }
    public struct CallRef: Sendable {
        public let fromKey: String
        public let name: String
    }

    public var imports: [ImportRef] = []
    public var inherits: [InheritRef] = []
    public var calls: [CallRef] = []

    public init() {}
}

/// Deterministic regex-based source extractor. No parsing, no LLM:
/// line patterns + scope heuristics per `LanguageSpec`.
public struct GraphExtractor: Sendable {

    public init() {}

    // MARK: - Configuration

    public static let skippedDirectories: Set<String> = [
        ".git", ".build", ".swiftpm", "DerivedData", "node_modules", "target",
        "vendor", "dist", "build", "out", "bin", "obj", "Pods", ".next",
        ".nuxt", "__pycache__", ".venv", "venv", "coverage", ".idea",
        ".vscode", ".gradle", ".dart_tool",
    ]

    public static let maxFileSize = 1_000_000
    public static let maxNodesPerFile = 500
    public static let maxCallsPerFile = 200

    /// Words never treated as call targets.
    static let callKeywords: Set<String> = [
        "if", "for", "while", "switch", "catch", "return", "sizeof", "print",
        "println", "func", "function", "def", "class", "struct", "enum", "new",
        "delete", "super", "self", "this", "init", "deinit", "guard", "else",
        "do", "try", "await", "async", "throw", "throws", "raise", "echo",
        "isset", "empty", "array", "echo", "require", "include", "import",
    ]

    // MARK: - Paths

    /// Root-relative key path: plain relative for single-root workspaces,
    /// folder-prefixed for multi-root (mentionPath parity).
    public static func relativePath(for url: URL, in roots: [URL]) -> String? {
        let path = url.standardizedFileURL.path
        for root in roots {
            let rootPath = root.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            let rel = String(path.dropFirst(rootPath.count + 1))
            return roots.count > 1 ? "\(root.lastPathComponent)/\(rel)" : rel
        }
        return nil
    }

    // MARK: - File discovery

    /// All extractable source files under the roots.
    public func listSourceFiles(roots: [URL]) -> [URL] {
        var result: [URL] = []
        let fm = FileManager.default
        for root in roots {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir {
                    if Self.skippedDirectories.contains(url.lastPathComponent) {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard LanguageSpec.spec(for: url) != nil else { continue }
                let name = url.lastPathComponent
                if name.hasSuffix(".min.js") || name.hasSuffix(".min.css") { continue }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                guard size > 0, size <= Self.maxFileSize else { continue }
                result.append(url)
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    /// Staleness stamp: mtime + size (no crypto needed).
    public static func stamp(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = values?.fileSize ?? 0
        return "\(mtime)_\(size)"
    }

    // MARK: - Extraction (phase 1: nodes + contains + raw facts)

    private struct ScopeEntry {
        var name: String
        var isType: Bool
        var depth: Int
        var nodeIndex: Int
    }

    /// Extract one file. Returns nodes + contains edges (imports/calls/
    /// inherits come later via `resolveCrossFileEdges`) plus raw facts.
    public func extractFile(
        url: URL,
        relativePath: String
    ) -> (extraction: GraphFileExtraction, facts: GraphFileFacts)? {
        guard let spec = LanguageSpec.spec(for: url),
              let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        let lines = content.components(separatedBy: "\n")
        var nodes: [GraphNodeInput] = []
        var edges: [GraphEdgeInput] = []
        var facts = GraphFileFacts()

        // File node.
        nodes.append(GraphNodeInput(
            nodeKey: relativePath,
            kind: "file",
            name: url.lastPathComponent,
            file: relativePath,
            line: 1,
            endLine: lines.count
        ))

        var stack: [ScopeEntry] = []
        var depth = 0
        var pendingBlocks = 0 // ruby: non-symbol block openers

        for (index, rawLine) in lines.enumerated() {
            let lineNo = index + 1
            let line = Self.stripComment(rawLine, prefix: spec.lineComment)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // --- scope maintenance (pre-symbol) ---
            switch spec.scopeStyle {
            case .braces:
                let closes = line.filter { $0 == "}" }.count
                if trimmed.hasPrefix("}") {
                    depth -= closes
                    popScopes(&stack, depth: depth, nodes: &nodes, lineNo: lineNo)
                }
            case .indent:
                let indent = line.prefix { $0 == " " || $0 == "\t" }.count
                popScopes(&stack, depth: indent, nodes: &nodes, lineNo: lineNo, inclusive: true)
            case .keywordEnd:
                if Self.isRubyEnd(trimmed) {
                    if pendingBlocks > 0 {
                        pendingBlocks -= 1
                    } else if let entry = stack.popLast() {
                        nodes[entry.nodeIndex].endLine = lineNo
                    }
                } else if Self.isRubyBlockOpener(trimmed) {
                    pendingBlocks += 1
                }
            case .atEnd:
                if trimmed.hasPrefix("@end") {
                    while let entry = stack.popLast() {
                        nodes[entry.nodeIndex].endLine = lineNo
                        if entry.isType { break }
                    }
                }
            }

            // --- symbol match (first pattern wins) ---
            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)
            for pattern in spec.symbols {
                guard let match = pattern.regex.firstMatch(in: line, range: range),
                      match.range.location != NSNotFound,
                      let name = Self.groupString(nsLine, match: match, group: pattern.nameGroup) else { continue }

                let parent = stack.last { $0.isType }
                let receiver = pattern.receiverGroup.flatMap { Self.groupString(nsLine, match: match, group: $0) }

                if pattern.requiresTypeParent, parent == nil, receiver == nil { continue }

                var kind = pattern.kind
                if kind == "func", parent != nil || receiver != nil { kind = "method" }

                let parentChain: [String]
                if let receiver {
                    parentChain = [receiver]
                } else if let parent {
                    parentChain = [parent.name] // full dotted path of the type scope
                } else {
                    parentChain = []
                }
                let symbolPath = (parentChain + [name]).joined(separator: ".")
                let nodeKey = "\(relativePath)#\(symbolPath)"

                let signature = trimmed.count > 200 ? String(trimmed.prefix(200)) : trimmed
                nodes.append(GraphNodeInput(
                    nodeKey: nodeKey,
                    kind: kind,
                    name: name,
                    file: relativePath,
                    line: lineNo,
                    endLine: lines.count,
                    signature: signature
                ))
                let nodeIndex = nodes.count - 1

                // contains edge from immediate parent (type scope or file)
                let containerKey = parent.map { "\(relativePath)#\($0.name)" } ?? relativePath
                edges.append(GraphEdgeInput(fromKey: containerKey, toKey: nodeKey, kind: "contains", confidence: "extracted"))

                // inheritance / implements refs
                if let group = pattern.inheritGroup,
                   let clause = Self.groupString(nsLine, match: match, group: group) {
                    facts.inherits.append(.init(childKey: nodeKey, clause: clause, edgeKind: "inherits"))
                }
                if let group = pattern.implementsGroup,
                   let clause = Self.groupString(nsLine, match: match, group: group) {
                    facts.inherits.append(.init(childKey: nodeKey, clause: clause, edgeKind: "implements"))
                }

                // scope push
                switch spec.scopeStyle {
                case .braces:
                    let opens = line.filter { $0 == "{" }.count
                    if opens > 0 {
                        stack.append(ScopeEntry(name: symbolPath, isType: pattern.isType, depth: depth + opens, nodeIndex: nodeIndex))
                    }
                case .indent:
                    let indent = line.prefix { $0 == " " || $0 == "\t" }.count
                    stack.append(ScopeEntry(name: symbolPath, isType: pattern.isType, depth: indent, nodeIndex: nodeIndex))
                case .keywordEnd:
                    stack.append(ScopeEntry(name: symbolPath, isType: pattern.isType, depth: 0, nodeIndex: nodeIndex))
                case .atEnd:
                    if pattern.isType {
                        stack.append(ScopeEntry(name: symbolPath, isType: true, depth: 0, nodeIndex: nodeIndex))
                    }
                }

                if nodes.count >= Self.maxNodesPerFile { break }
                break
            }

            // --- scope maintenance (post-symbol) ---
            if case .braces = spec.scopeStyle {
                let opens = line.filter { $0 == "{" }.count
                let closes = line.filter { $0 == "}" }.count
                depth += opens - (trimmed.hasPrefix("}") ? 0 : closes)
                popScopes(&stack, depth: depth, nodes: &nodes, lineNo: lineNo)
            }

            if nodes.count >= Self.maxNodesPerFile { break }
        }

        // Flush unclosed scopes.
        for entry in stack {
            nodes[entry.nodeIndex].endLine = lines.count
        }

        // --- import refs ---
        for rawLine in lines {
            let nsRaw = rawLine as NSString
            let rawRange = NSRange(location: 0, length: nsRaw.length)
            for pattern in spec.imports {
                guard let match = pattern.regex.firstMatch(in: rawLine, range: rawRange),
                      let module = Self.groupString(nsRaw, match: match, group: 1) else { continue }
                facts.imports.append(.init(module: module, strategy: pattern.strategy, stripPrefix: pattern.stripPrefixRegex))
            }
        }

        // --- call refs (bodies of funcs/methods) ---
        let callRegex = try? NSRegularExpression(pattern: #"\b([A-Za-z_]\w{3,})\s*\("#)
        var callCount = 0
        var seenCalls: Set<String> = []
        for node in nodes where (node.kind == "func" || node.kind == "method") && node.endLine >= node.line {
            guard callCount < Self.maxCallsPerFile else { break }
            let body = lines[(node.line - 1)..<min(node.endLine, lines.count)].joined(separator: "\n")
            let nsBody = body as NSString
            let bodyRange = NSRange(location: 0, length: nsBody.length)
            for match in callRegex?.matches(in: body, range: bodyRange) ?? [] {
                let name = nsBody.substring(with: match.range(at: 1))
                guard !Self.callKeywords.contains(name), name != node.name else { continue }
                let dedupeKey = "\(node.nodeKey)->\(name)"
                guard seenCalls.insert(dedupeKey).inserted else { continue }
                facts.calls.append(.init(fromKey: node.nodeKey, name: name))
                callCount += 1
                if callCount >= Self.maxCallsPerFile { break }
            }
        }

        return (GraphFileExtraction(file: relativePath, nodes: nodes, edges: edges), facts)
    }

    // MARK: - Resolution (phase 2: imports / inherits / calls edges)

    /// Append cross-file edges to an extraction using the workspace index.
    public func resolveCrossFileEdges(
        extraction: inout GraphFileExtraction,
        facts: GraphFileFacts,
        index: GraphWorkspaceIndex,
        roots: [URL]
    ) {
        var seen: Set<String> = Set(extraction.edges.map { "\($0.fromKey)|\($0.toKey)|\($0.kind)" })
        func append(_ edge: GraphEdgeInput) {
            let key = "\(edge.fromKey)|\(edge.toKey)|\(edge.kind)"
            guard seen.insert(key).inserted else { return }
            extraction.edges.append(edge)
        }

        // imports
        for ref in facts.imports {
            var module = ref.module
            if let strip = ref.stripPrefix {
                let ns = module as NSString
                module = strip.stringByReplacingMatches(
                    in: module,
                    range: NSRange(location: 0, length: ns.length),
                    withTemplate: ""
                )
            }
            for target in resolveImport(module: module, strategy: ref.strategy, fromFile: extraction.file, index: index, roots: roots) {
                guard target != extraction.file else { continue }
                append(GraphEdgeInput(fromKey: extraction.file, toKey: target, kind: "imports", confidence: "extracted"))
            }
        }

        // inherits / implements
        for ref in facts.inherits {
            for name in Self.identifiers(in: ref.clause) {
                guard let target = resolveType(name: name, index: index) else { continue }
                if target != ref.childKey {
                    append(GraphEdgeInput(fromKey: ref.childKey, toKey: target, kind: ref.edgeKind, confidence: "extracted"))
                }
                if ref.edgeKind == "inherits" { break } // first resolvable parent wins
            }
        }

        // calls
        for ref in facts.calls {
            guard let candidates = index.symbolsByName[ref.name], candidates.count <= 30 else { continue }
            for target in candidates.sorted().prefix(3) where target != ref.fromKey {
                append(GraphEdgeInput(fromKey: ref.fromKey, toKey: target, kind: "calls", confidence: "inferred"))
            }
        }
    }

    // MARK: - Import resolution

    private func resolveImport(
        module: String,
        strategy: LanguageSpec.ImportStrategy,
        fromFile: String,
        index: GraphWorkspaceIndex,
        roots: [URL]
    ) -> [String] {
        switch strategy {
        case .relativePath(let extensions):
            return resolvePathCandidates(module, extensions: extensions, fromFile: fromFile, roots: roots)
        case .modulePath(let extensions):
            let path = module.replacingOccurrences(of: ".", with: "/")
            var found = resolvePathCandidates(path, extensions: extensions, fromFile: fromFile, roots: roots, anchors: ["", "src", "lib", "Sources"])
            if found.isEmpty {
                // package directories (python __init__)
                for root in roots {
                    for anchor in ["", "src", "lib", "Sources"] {
                        for ext in extensions {
                            let candidate = (anchor.isEmpty ? root : root.appendingPathComponent(anchor))
                                .appendingPathComponent(path)
                                .appendingPathComponent("__init__.\(ext)")
                            if let key = Self.relativePath(for: candidate, in: roots), index.extractions[key] != nil {
                                found.append(key)
                            }
                        }
                    }
                }
            }
            return Array(found.prefix(5))
        case .basenameMatch:
            let last = module.split { ".: \\/".contains($0) }.map(String.init).last ?? module
            return Array((index.filesByBasename[last] ?? []).prefix(5))
        case .directoryMatch:
            let last = module.split(separator: "/").map(String.init).last ?? module
            return Array((index.filesByDirectory[last] ?? []).filter { $0 != fromFile }.prefix(10))
        }
    }

    private func resolvePathCandidates(
        _ path: String,
        extensions: [String],
        fromFile: String,
        roots: [URL],
        anchors: [String] = [""]
    ) -> [String] {
        let fm = FileManager.default
        var bases: [URL] = []
        // importing file's directory
        if roots.count > 1 {
            for root in roots where fromFile.hasPrefix(root.lastPathComponent + "/") {
                let stripped = String(fromFile.dropFirst(root.lastPathComponent.count + 1))
                bases.append(root.appendingPathComponent(stripped).deletingLastPathComponent())
            }
        } else if let root = roots.first {
            bases.append(root.appendingPathComponent(fromFile).deletingLastPathComponent())
        }
        for root in roots {
            for anchor in anchors {
                bases.append(anchor.isEmpty ? root : root.appendingPathComponent(anchor))
            }
        }

        var result: [String] = []
        let hasExtension = extensions.contains((path as NSString).pathExtension)
        for base in bases {
            var candidates: [URL] = []
            let target = base.appendingPathComponent(path)
            if hasExtension {
                candidates.append(target)
            }
            for ext in extensions {
                candidates.append(base.appendingPathComponent("\(path).\(ext)"))
                candidates.append(target.appendingPathComponent("index.\(ext)"))
                candidates.append(target.appendingPathComponent("mod.\(ext)"))
            }
            for candidate in candidates {
                let standardized = candidate.standardizedFileURL
                guard fm.fileExists(atPath: standardized.path),
                      let key = Self.relativePath(for: standardized, in: roots),
                      !result.contains(key) else { continue }
                result.append(key)
                if result.count >= 5 { return result }
            }
        }
        return result
    }

    private func resolveType(name: String, index: GraphWorkspaceIndex) -> String? {
        guard let candidates = index.symbolsByName[name] else { return nil }
        // Prefer type-kind nodes.
        for key in candidates.sorted() {
            if let kind = index.symbolKinds[key], LanguageSpec.typeKinds.contains(kind) {
                return key
            }
        }
        return candidates.sorted().first
    }

    // MARK: - Helpers

    /// Capture group text, nil when the group did not participate in the match.
    static func groupString(_ line: NSString, match: NSTextCheckingResult, group: Int) -> String? {
        guard match.numberOfRanges > group else { return nil }
        let range = match.range(at: group)
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        return line.substring(with: range)
    }

    static func identifiers(in clause: String) -> [String] {
        let regex = try? NSRegularExpression(pattern: #"\b([A-Z]\w*)\b"#)
        let ns = clause as NSString
        return regex?.matches(in: clause, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) } ?? []
    }

    static func stripComment(_ line: String, prefix: String) -> String {
        guard let range = line.range(of: prefix) else { return line }
        // Naive: cuts at first marker even inside strings — acceptable heuristic.
        return String(line[line.startIndex..<range.lowerBound])
    }

    private func popScopes(
        _ stack: inout [ScopeEntry],
        depth: Int,
        nodes: inout [GraphNodeInput],
        lineNo: Int,
        inclusive: Bool = false
    ) {
        while let last = stack.last, inclusive ? last.depth >= depth : last.depth > depth {
            stack.removeLast()
            nodes[last.nodeIndex].endLine = lineNo
        }
    }

    private static func isRubyEnd(_ trimmed: String) -> Bool {
        trimmed == "end" || trimmed.hasPrefix("end ") || trimmed.hasPrefix("end.") || trimmed.hasPrefix("end#")
    }

    private static func isRubyBlockOpener(_ trimmed: String) -> Bool {
        // Non-symbol block openers whose `end` must not pop a symbol scope.
        guard let regex = Self.rubyBlockOpenerRegex else { return false }
        let ns = trimmed as NSString
        return regex.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)) != nil
    }

    private static let rubyBlockOpenerRegex = try? NSRegularExpression(
        pattern: #"(^|\s)(if|unless|case|while|until|for|begin|do)\b"#
    )
}
