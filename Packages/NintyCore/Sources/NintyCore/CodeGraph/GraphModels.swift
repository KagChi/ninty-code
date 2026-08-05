import Foundation

/// DTOs matching graph-mcp's `graph_upsert` schema (snake_case on the wire).

public struct GraphNodeInput: Codable, Sendable, Equatable {
    public var nodeKey: String
    public var kind: String
    public var name: String
    public var file: String
    public var line: Int
    public var endLine: Int
    public var signature: String?
    public var doc: String?

    public init(nodeKey: String, kind: String, name: String, file: String, line: Int = 0, endLine: Int = 0, signature: String? = nil, doc: String? = nil) {
        self.nodeKey = nodeKey
        self.kind = kind
        self.name = name
        self.file = file
        self.line = line
        self.endLine = endLine
        self.signature = signature
        self.doc = doc
    }

    private enum CodingKeys: String, CodingKey {
        case nodeKey = "node_key"
        case kind, name, file, line
        case endLine = "end_line"
        case signature, doc
    }
}

public struct GraphEdgeInput: Codable, Sendable, Equatable {
    public var fromKey: String
    public var toKey: String
    public var kind: String
    public var confidence: String?

    public init(fromKey: String, toKey: String, kind: String, confidence: String? = nil) {
        self.fromKey = fromKey
        self.toKey = toKey
        self.kind = kind
        self.confidence = confidence
    }

    private enum CodingKeys: String, CodingKey {
        case fromKey = "from_key"
        case toKey = "to_key"
        case kind, confidence
    }
}

public struct GraphFileExtraction: Codable, Sendable, Equatable {
    public var file: String
    public var nodes: [GraphNodeInput]
    public var edges: [GraphEdgeInput]

    public init(file: String, nodes: [GraphNodeInput] = [], edges: [GraphEdgeInput] = []) {
        self.file = file
        self.nodes = nodes
        self.edges = edges
    }
}

public struct GraphUpsertPayload: Codable, Sendable {
    public var workspace: String
    public var files: [GraphFileExtraction]
    public var deletedFiles: [String]

    public init(workspace: String, files: [GraphFileExtraction], deletedFiles: [String] = []) {
        self.workspace = workspace
        self.files = files
        self.deletedFiles = deletedFiles
    }

    private enum CodingKeys: String, CodingKey {
        case workspace, files
        case deletedFiles = "deleted_files"
    }
}

/// Per-workspace extraction index: everything needed to resolve cross-file
/// edges incrementally without re-reading every file.
public struct GraphWorkspaceIndex: Sendable {
    /// file (node_key) → extraction (nodes/edges as last synced)
    public var extractions: [String: GraphFileExtraction] = [:]
    /// symbol name → node keys (all files)
    public var symbolsByName: [String: [String]] = [:]
    /// node_key → kind (type-preference during inheritance resolution)
    public var symbolKinds: [String: String] = [:]
    /// file basename without extension → file node_keys (import resolution)
    public var filesByBasename: [String: [String]] = [:]
    /// directory basename → file node_keys inside it (Go package resolution)
    public var filesByDirectory: [String: [String]] = [:]
    /// staleness stamp per file (mtime_size)
    public var fileStamps: [String: String] = [:]

    public init() {}

    public mutating func remove(_ file: String) {
        fileStamps.removeValue(forKey: file)
        removeFromNameIndexes(file)
        guard let old = extractions.removeValue(forKey: file) else { return }
        for node in old.nodes where node.kind != "file" {
            symbolsByName[node.name, default: []].removeAll { $0 == node.nodeKey }
            if symbolsByName[node.name]?.isEmpty == true {
                symbolsByName.removeValue(forKey: node.name)
            }
            symbolKinds.removeValue(forKey: node.nodeKey)
        }
    }

    public mutating func insert(_ extraction: GraphFileExtraction, stamp: String) {
        remove(extraction.file)
        fileStamps[extraction.file] = stamp
        for node in extraction.nodes {
            if node.kind == "file" {
                addToNameIndexes(node.file)
            } else {
                symbolsByName[node.name, default: []].append(node.nodeKey)
                symbolKinds[node.nodeKey] = node.kind
            }
        }
        extractions[extraction.file] = extraction
    }

    private mutating func addToNameIndexes(_ file: String) {
        let ns = file as NSString
        let basename = (ns.lastPathComponent as NSString).deletingPathExtension
        filesByBasename[basename, default: []].append(file)
        let directory = (ns.deletingLastPathComponent as NSString).lastPathComponent
        if !directory.isEmpty {
            filesByDirectory[directory, default: []].append(file)
        }
    }

    private mutating func removeFromNameIndexes(_ file: String) {
        let ns = file as NSString
        let basename = (ns.lastPathComponent as NSString).deletingPathExtension
        filesByBasename[basename, default: []].removeAll { $0 == file }
        if filesByBasename[basename]?.isEmpty == true {
            filesByBasename.removeValue(forKey: basename)
        }
        let directory = (ns.deletingLastPathComponent as NSString).lastPathComponent
        filesByDirectory[directory, default: []].removeAll { $0 == file }
        if filesByDirectory[directory]?.isEmpty == true {
            filesByDirectory.removeValue(forKey: directory)
        }
    }
}
