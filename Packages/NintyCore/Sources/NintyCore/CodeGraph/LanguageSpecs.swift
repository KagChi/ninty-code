import Foundation

/// The 16 built-in language specs. Patterns are line-oriented heuristics:
/// deterministic, fast, and good enough for graph navigation — no full parse.
extension LanguageSpec {

    public static let swift = LanguageSpec(
        name: "Swift",
        extensions: ["swift"],
        scopeStyle: .braces,
        symbols: [
            .init(kind: "class", #"^\s*(?:"# + visibility + #")*class\s+(\w+)(?:\s*:\s*([^\{]+?))?\s*\{?"#, isType: true, inheritGroup: 2),
            .init(kind: "struct", #"^\s*(?:"# + visibility + #")*struct\s+(\w+)(?:\s*:\s*([^\{]+?))?\s*\{?"#, isType: true, inheritGroup: 2),
            .init(kind: "enum", #"^\s*(?:"# + visibility + #")*enum\s+(\w+)(?:\s*:\s*([^\{]+?))?\s*\{?"#, isType: true, inheritGroup: 2),
            .init(kind: "protocol", #"^\s*(?:"# + visibility + #")*protocol\s+(\w+)(?:\s*:\s*([^\{]+?))?\s*\{?"#, isType: true, inheritGroup: 2),
            .init(kind: "actor", #"^\s*(?:"# + visibility + #")*actor\s+(\w+)\s*\{?"#, isType: true),
            .init(kind: "extension", #"^\s*extension\s+(\w+)"#, isType: true),
            .init(kind: "func", #"^\s*(?:"# + visibility + #")*func\s+(\w+)"#),
        ],
        imports: [
            .init(#"^\s*import\s+(?:class|struct|enum|protocol|func\s+)?(\w+)"#, .basenameMatch)
        ]
    )

    public static let rust = LanguageSpec(
        name: "Rust",
        extensions: ["rs"],
        scopeStyle: .braces,
        symbols: [
            .init(kind: "struct", #"^\s*(?:pub(?:\(\w+\))?\s+)?struct\s+(\w+)"#, isType: true),
            .init(kind: "enum", #"^\s*(?:pub(?:\(\w+\))?\s+)?enum\s+(\w+)"#, isType: true),
            .init(kind: "trait", #"^\s*(?:pub(?:\(\w+\))?\s+)?(?:unsafe\s+)?trait\s+(\w+)"#, isType: true),
            .init(kind: "impl", #"^\s*impl(?:\s*<[^>]*>)?(?:\s+(\w+)(?:\s*<[^>]*>)?\s+for)?\s+(\w+)"#, nameGroup: 2, isType: true, implementsGroup: 1),
            .init(kind: "module", #"^\s*(?:pub(?:\(\w+\))?\s+)?mod\s+(\w+)\s*\{"#, isType: true),
            .init(kind: "func", #"^\s*(?:pub(?:\(\w+\))?\s+)?(?:async\s+)?(?:unsafe\s+)?fn\s+(\w+)"#),
        ],
        imports: [
            .init(#"^\s*use\s+(?:crate|self|super)?::?([\w:]+)"#, .basenameMatch),
            .init(#"^\s*mod\s+(\w+)\s*;"#, .relativePath(extensions: ["rs"])),
        ]
    )

    public static let go = LanguageSpec(
        name: "Go",
        extensions: ["go"],
        scopeStyle: .braces,
        symbols: [
            .init(kind: "method", #"^func\s+\(\s*\w+\s+\*?(\w+)\s*\)\s+(\w+)"#, nameGroup: 2, receiverGroup: 1),
            .init(kind: "func", #"^func\s+(\w+)"#),
            .init(kind: "struct", #"^type\s+(\w+)\s+struct"#, isType: true),
            .init(kind: "interface", #"^type\s+(\w+)\s+interface"#, isType: true),
        ],
        imports: [
            .init(#"^\s*"([\w./\-]+)"\s*$"#, .directoryMatch),
            .init(#"^import\s+"([\w./\-]+)""#, .directoryMatch),
        ]
    )

    public static let c = LanguageSpec(
        name: "C",
        extensions: ["c", "h"],
        scopeStyle: .braces,
        symbols: [
            .init(kind: "struct", #"^\s*(?:typedef\s+)?struct\s+(\w+)"#, isType: true),
            .init(kind: "enum", #"^\s*(?:typedef\s+)?enum\s+(\w+)"#, isType: true),
            .init(kind: "func", #"^(?!if\b|for\b|while\b|switch\b|return\b|sizeof\b)[\w\s\*&]+?\b(\w+)\s*\([^;]*\)\s*\{"#),
        ],
        imports: [
            .init(#"^\s*#\s*include\s+"([^"]+)""#, .relativePath(extensions: ["h", "c"]))
        ]
    )

    public static let cpp = LanguageSpec(
        name: "C++",
        extensions: ["cpp", "cc", "cxx", "hpp", "hh", "hxx"],
        scopeStyle: .braces,
        symbols: [
            .init(kind: "class", #"^\s*(?:template\s*<[^>]*>\s*)?class\s+(\w+)(?:\s*:\s*(?:public|private|protected)\s+(\w+))?"#, isType: true, inheritGroup: 2),
            .init(kind: "struct", #"^\s*(?:typedef\s+)?struct\s+(\w+)"#, isType: true),
            .init(kind: "enum", #"^\s*(?:typedef\s+)?enum\s+(?:class\s+)?(\w+)"#, isType: true),
            .init(kind: "namespace", #"^\s*namespace\s+(\w+)"#, isType: true),
            .init(kind: "func", #"^(?!if\b|for\b|while\b|switch\b|return\b|sizeof\b)[\w\s\*&:<>,~]+?\b(\w+)\s*\([^;]*\)\s*(?:const\s*)?(?:noexcept\s*)?\{"#),
        ],
        imports: [
            .init(#"^\s*#\s*include\s+"([^"]+)""#, .relativePath(extensions: ["hpp", "hh", "hxx", "h", "cpp", "cc"]))
        ]
    )

    public static let csharp = LanguageSpec(
        name: "C#",
        extensions: ["cs"],
        scopeStyle: .braces,
        symbols: [
            .init(kind: "namespace", #"^\s*namespace\s+([\w.]+)"#, isType: true),
            .init(kind: "class", #"^\s*(?:"# + visibility + #")*class\s+(\w+)(?:\s*:\s*([^\{]+?))?\s*\{?"#, isType: true, inheritGroup: 2),
            .init(kind: "interface", #"^\s*(?:"# + visibility + #")*interface\s+(\w+)"#, isType: true),
            .init(kind: "struct", #"^\s*(?:"# + visibility + #")*struct\s+(\w+)"#, isType: true),
            .init(kind: "enum", #"^\s*(?:"# + visibility + #")*enum\s+(\w+)"#, isType: true),
            .init(kind: "record", #"^\s*(?:"# + visibility + #")*record\s+(\w+)"#, isType: true),
            .init(kind: "method", #"^\s*(?:"# + visibility + #")+[\w<>\[\],\?\.]+\s+(\w+)\s*\([^;]*\)\s*(?:\{|=>)"#, requiresTypeParent: true),
        ],
        imports: [
            .init(#"^\s*using\s+(?:static\s+)?([\w.]+)\s*;"#, .basenameMatch)
        ]
    )

    public static let java = LanguageSpec(
        name: "Java",
        extensions: ["java"],
        scopeStyle: .braces,
        symbols: [
            .init(kind: "class", #"^\s*(?:"# + visibility + #")*class\s+(\w+)(?:\s+extends\s+(\w+))?(?:\s+implements\s+([\w,\s]+?))?\s*\{?"#, isType: true, inheritGroup: 2, implementsGroup: 3),
            .init(kind: "interface", #"^\s*(?:"# + visibility + #")*interface\s+(\w+)"#, isType: true),
            .init(kind: "enum", #"^\s*(?:"# + visibility + #")*enum\s+(\w+)"#, isType: true),
            .init(kind: "record", #"^\s*(?:"# + visibility + #")*record\s+(\w+)"#, isType: true),
            .init(kind: "method", #"^\s*(?:"# + visibility + #")+[\w<>\[\],\?\.]+\s+(\w+)\s*\([^;]*\)\s*(?:throws\s+[\w,\s]+)?\{"#, requiresTypeParent: true),
        ],
        imports: [
            .init(#"^\s*import\s+(?:static\s+)?([\w.]+)\s*;"#, .modulePath(extensions: ["java"]))
        ]
    )

    public static let kotlin = LanguageSpec(
        name: "Kotlin",
        extensions: ["kt", "kts"],
        scopeStyle: .braces,
        symbols: [
            .init(kind: "class", #"^\s*(?:(?:"# + visibility + #")|data\s+)*class\s+(\w+)(?:\s*:\s*([^\{]+?))?\s*\{?"#, isType: true, inheritGroup: 2),
            .init(kind: "object", #"^\s*(?:"# + visibility + #")*object\s+(\w+)"#, isType: true),
            .init(kind: "interface", #"^\s*(?:"# + visibility + #")*interface\s+(\w+)"#, isType: true),
            .init(kind: "func", #"^\s*(?:"# + visibility + #")*fun\s+(?:<[^>]+>\s+)?(?:\w+\.)?(\w+)"#),
        ],
        imports: [
            .init(#"^\s*import\s+([\w.]+)"#, .modulePath(extensions: ["kt"]))
        ]
    )
}
