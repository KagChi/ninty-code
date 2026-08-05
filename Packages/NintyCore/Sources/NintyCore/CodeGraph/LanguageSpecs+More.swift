import Foundation

/// Specs for the curly-scripting + indented/keyword languages, and the
/// `all` registry.
extension LanguageSpec {

    public static let javascript = LanguageSpec(
        name: "JavaScript",
        extensions: ["js", "jsx", "mjs", "cjs"],
        scopeStyle: .braces,
        symbols: [
            .init(kind: "class", #"^\s*(?:export\s+)?(?:default\s+)?class\s+(\w+)(?:\s+extends\s+(\w+))?"#, isType: true, inheritGroup: 2),
            .init(kind: "func", #"^\s*(?:export\s+)?(?:async\s+)?function\s*\*?\s*(\w+)"#),
            .init(kind: "func", #"^\s*(?:export\s+)?const\s+(\w+)\s*=\s*(?:async\s*)?(?:\([^)]*\)|\w+)\s*=>"#),
            .init(kind: "method", #"^\s*(?:async\s+)?(?!if\b|for\b|while\b|switch\b|catch\b|return\b|else\b|do\b|function\b|const\b|let\b|var\b)(\w+)\s*\([^;]*\)\s*(?::\s*[^{]+)?\{"#, requiresTypeParent: true),
        ],
        imports: [
            .init(#"from\s+['"]([^'"]+)['"]"#, .relativePath(extensions: ["ts", "tsx", "js", "jsx", "mjs", "cjs"])),
            .init(#"require\(\s*['"]([^'"]+)['"]\s*\)"#, .relativePath(extensions: ["ts", "tsx", "js", "jsx", "mjs", "cjs"])),
            .init(#"^\s*import\s+['"]([^'"]+)['"]"#, .relativePath(extensions: ["ts", "tsx", "js", "jsx", "mjs", "cjs"])),
        ]
    )

    public static let typescript = LanguageSpec(
        name: "TypeScript",
        extensions: ["ts", "tsx", "mts", "cts"],
        scopeStyle: .braces,
        symbols: [
            .init(kind: "class", #"^\s*(?:export\s+)?(?:default\s+)?(?:abstract\s+)?class\s+(\w+)(?:\s+extends\s+(\w+))?(?:\s+implements\s+([\w,\s]+?))?\s*\{?"#, isType: true, inheritGroup: 2, implementsGroup: 3),
            .init(kind: "interface", #"^\s*(?:export\s+)?interface\s+(\w+)(?:\s+extends\s+([\w,\s]+?))?\s*\{?"#, isType: true, inheritGroup: 2),
            .init(kind: "enum", #"^\s*(?:export\s+)?enum\s+(\w+)"#, isType: true),
            .init(kind: "type", #"^\s*(?:export\s+)?type\s+(\w+)\s*="#),
            .init(kind: "func", #"^\s*(?:export\s+)?(?:async\s+)?function\s*\*?\s*(\w+)"#),
            .init(kind: "func", #"^\s*(?:export\s+)?const\s+(\w+)\s*=\s*(?:async\s*)?(?:\([^)]*\)|\w+)\s*=>"#),
            .init(kind: "method", #"^\s*(?:public|private|protected|static|async|readonly|abstract|override|\s)*(?!if\b|for\b|while\b|switch\b|catch\b|return\b|else\b|do\b|function\b|const\b|let\b|var\b)(\w+)\s*(\([^;]*\)|<[^>]+>\s*\([^;]*\))\s*(?::\s*[^{]+)?\{"#, requiresTypeParent: true),
        ],
        imports: javascript.imports
    )

    public static let python = LanguageSpec(
        name: "Python",
        extensions: ["py"],
        scopeStyle: .indent,
        symbols: [
            .init(kind: "class", #"^(\s*)class\s+(\w+)(?:\(([^)]*)\))?\s*:"#, nameGroup: 2, isType: true, inheritGroup: 3),
            .init(kind: "func", #"^(\s*)(?:async\s+)?def\s+(\w+)"#, nameGroup: 2),
        ],
        imports: [
            .init(#"^\s*from\s+([\w.]+)\s+import"#, .modulePath(extensions: ["py"])),
            .init(#"^\s*import\s+([\w.]+)"#, .modulePath(extensions: ["py"])),
        ],
        lineComment: "#"
    )

    public static let ruby = LanguageSpec(
        name: "Ruby",
        extensions: ["rb"],
        scopeStyle: .keywordEnd,
        symbols: [
            .init(kind: "class", #"^\s*class\s+(\w+)(?:\s*<\s*(\w+))?"#, isType: true, inheritGroup: 2),
            .init(kind: "module", #"^\s*module\s+(\w+)"#, isType: true),
            .init(kind: "func", #"^\s*def\s+(?:self\.)?(\w+[!?=]?)"#),
        ],
        imports: [
            .init(#"^\s*require(?:_relative)?\s+['"]([^'"]+)['"]"#, .relativePath(extensions: ["rb"]))
        ],
        lineComment: "#"
    )

    public static let php = LanguageSpec(
        name: "PHP",
        extensions: ["php"],
        scopeStyle: .braces,
        symbols: [
            .init(kind: "class", #"^\s*(?:abstract\s+|final\s+)?class\s+(\w+)(?:\s+extends\s+([\w\\]+))?(?:\s+implements\s+([\w,\s\\]+?))?\s*\{?"#, isType: true, inheritGroup: 2, implementsGroup: 3),
            .init(kind: "interface", #"^\s*interface\s+(\w+)"#, isType: true),
            .init(kind: "trait", #"^\s*trait\s+(\w+)"#, isType: true),
            .init(kind: "func", #"^\s*(?:"# + visibility + #")*function\s+(\w+)"#),
        ],
        imports: [
            .init(#"^\s*use\s+([\w\\]+)\s*;"#, .basenameMatch),
            .init(#"^\s*(?:require|include)(?:_once)?\s*\(?\s*['"]([^'"]+)['"]"#, .relativePath(extensions: ["php"])),
        ]
    )

    public static let dart = LanguageSpec(
        name: "Dart",
        extensions: ["dart"],
        scopeStyle: .braces,
        symbols: [
            .init(kind: "class", #"^\s*(?:abstract\s+)?class\s+(\w+)(?:\s+extends\s+(\w+))?(?:\s+with\s+([\w,\s]+?))?(?:\s+implements\s+([\w,\s]+?))?\s*\{?"#, isType: true, inheritGroup: 2, implementsGroup: 4),
            .init(kind: "enum", #"^\s*enum\s+(\w+)"#, isType: true),
            .init(kind: "func", #"^\s*(?:static\s+)?[\w<>?\.]+\s+(?!if\b|for\b|while\b|switch\b|catch\b|return\b)(\w+)\s*\([^;]*\)\s*(?:async\s*)?\{"#),
        ],
        imports: [
            .init(#"^\s*import\s+['"]([^'"]+)['"]"#, .relativePath(extensions: ["dart"]), stripPrefix: #"^package:[\w_]+/"#),
        ]
    )

    public static let scala = LanguageSpec(
        name: "Scala",
        extensions: ["scala"],
        scopeStyle: .braces,
        symbols: [
            .init(kind: "class", #"^\s*(?:case\s+)?class\s+(\w+)"#, isType: true),
            .init(kind: "object", #"^\s*object\s+(\w+)"#, isType: true),
            .init(kind: "trait", #"^\s*trait\s+(\w+)"#, isType: true),
            .init(kind: "enum", #"^\s*enum\s+(\w+)"#, isType: true),
            .init(kind: "func", #"^\s*(?:"# + visibility + #")*def\s+(\w+)"#),
        ],
        imports: [
            .init(#"^\s*import\s+([\w.]+)"#, .modulePath(extensions: ["scala"]))
        ]
    )

    public static let objectiveC = LanguageSpec(
        name: "Objective-C",
        extensions: ["m", "mm"],
        scopeStyle: .atEnd,
        symbols: [
            .init(kind: "class", #"^@interface\s+(\w+)(?:\s*:\s*(\w+))?"#, isType: true, inheritGroup: 2),
            .init(kind: "impl", #"^@implementation\s+(\w+)"#, isType: true),
            .init(kind: "method", #"^\s*[-+]\s*\([^)]+\)\s*(\w+)"#, requiresTypeParent: true),
        ],
        imports: [
            .init(#"^\s*#\s*import\s+"([^"]+)""#, .relativePath(extensions: ["h", "m", "mm"]))
        ]
    )

    /// Every supported language. Lookup by extension via `byExtension`.
    public static let all: [LanguageSpec] = [
        swift, rust, go, c, cpp, csharp, java, kotlin,
        javascript, typescript, python, ruby, php, dart, scala, objectiveC,
    ]
}
