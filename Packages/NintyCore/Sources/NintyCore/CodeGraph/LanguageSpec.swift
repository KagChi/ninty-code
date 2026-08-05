import Foundation

/// Declarative per-language extraction spec. Adding a language = adding an
/// entry to `LanguageSpec.all`; the engine (`GraphExtractor`) is generic.
public struct LanguageSpec: Sendable {
    /// How symbol scopes nest.
    public enum ScopeStyle: Sendable {
        case braces     // { } depth (C-like, JS, Java, Swift, ...)
        case indent     // significant indentation (Python)
        case keywordEnd // class/module/def ... end (Ruby)
        case atEnd      // @interface/@implementation ... @end (Objective-C)
    }

    /// How import strings resolve to workspace files.
    public enum ImportStrategy: Sendable {
        /// Path relative to the importing file's directory, then each root.
        /// Tries `<path>.<ext>`, `<path>/index.<ext>`, `<path>/mod.<ext>`.
        case relativePath(extensions: [String])
        /// Dotted module (a.b.C) -> a/b/C, resolved like relativePath from
        /// roots, plus `<path>/__init__.<ext>` for packages.
        case modulePath(extensions: [String])
        /// Last segment matched against indexed file basenames.
        case basenameMatch
        /// Last path segment matched against directory names; links to the
        /// files inside that directory (Go packages).
        case directoryMatch
    }

    public struct ImportPattern: Sendable {
        public let regex: NSRegularExpression
        public let strategy: ImportStrategy
        /// Prefix stripped before resolution (e.g. "package:foo/" in Dart).
        public let stripPrefixRegex: NSRegularExpression?

        public init(_ pattern: String, _ strategy: ImportStrategy, stripPrefix: String? = nil) {
            // All import patterns are compile-time constants.
            // swiftlint:disable:next force_try
            regex = try! NSRegularExpression(pattern: pattern)
            self.strategy = strategy
            stripPrefixRegex = stripPrefix.flatMap { try? NSRegularExpression(pattern: $0) }
        }
    }

    public struct SymbolPattern: Sendable {
        public let kind: String
        public let regex: NSRegularExpression
        public let nameGroup: Int
        /// Type-like symbols can parent methods (class/struct/enum/...).
        public let isType: Bool
        /// Only valid inside a type scope (JS/Java/C#/Dart methods).
        public let requiresTypeParent: Bool
        /// Go-style receiver: `func (r *Type) Name(` — receiver type group.
        public let receiverGroup: Int?
        /// Capture group holding the parent type clause (inherits edge).
        public let inheritGroup: Int?
        /// Capture group holding an implements clause (implements edge).
        public let implementsGroup: Int?

        public init(
            kind: String,
            _ pattern: String,
            nameGroup: Int = 1,
            isType: Bool = false,
            requiresTypeParent: Bool = false,
            receiverGroup: Int? = nil,
            inheritGroup: Int? = nil,
            implementsGroup: Int? = nil
        ) {
            self.kind = kind
            // All symbol patterns are compile-time constants.
            // swiftlint:disable:next force_try
            regex = try! NSRegularExpression(pattern: pattern)
            self.nameGroup = nameGroup
            self.isType = isType
            self.requiresTypeParent = requiresTypeParent
            self.receiverGroup = receiverGroup
            self.inheritGroup = inheritGroup
            self.implementsGroup = implementsGroup
        }
    }

    public let name: String
    public let extensions: Set<String>
    public let scopeStyle: ScopeStyle
    public let symbols: [SymbolPattern]
    public let imports: [ImportPattern]
    /// Line comment prefix stripped before brace counting ("//", "#").
    public let lineComment: String

    public init(
        name: String,
        extensions: Set<String>,
        scopeStyle: ScopeStyle,
        symbols: [SymbolPattern],
        imports: [ImportPattern],
        lineComment: String = "//"
    ) {
        self.name = name
        self.extensions = extensions
        self.scopeStyle = scopeStyle
        self.symbols = symbols
        self.imports = imports
        self.lineComment = lineComment
    }
}

extension LanguageSpec {
    /// Kinds that act as type scopes / inheritance targets.
    public static let typeKinds: Set<String> = [
        "class", "struct", "enum", "protocol", "interface", "trait",
        "object", "record", "actor", "namespace", "extension", "impl",
        "module", "type"
    ]

    /// Shared visibility/modifier fragment used by several specs.
    static let visibility = #"(?:public|private|protected|internal|fileprivate|open|static|final|abstract|sealed|virtual|override|async|synchronized|extern|inline|const|mutating)\s+"#

    /// Extension → spec lookup.
    public static let byExtension: [String: LanguageSpec] = {
        var map: [String: LanguageSpec] = [:]
        for spec in all {
            for ext in spec.extensions {
                map[ext] = spec
            }
        }
        return map
    }()

    public static func spec(for url: URL) -> LanguageSpec? {
        byExtension[url.pathExtension.lowercased()]
    }
}
