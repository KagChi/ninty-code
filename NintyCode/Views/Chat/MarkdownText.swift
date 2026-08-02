import SwiftUI

enum MarkdownSegment: Equatable {
    case text(String)
    case code(language: String, code: String)
}

/// Segments markdown into text/code. Memoized — parse once per unique content.
enum MarkdownSegmenter {
    nonisolated(unsafe) private static var cache: [String: [MarkdownSegment]] = [:] // guarded by lock
    private static let lock = NSLock()
    private static let maxEntries = 500

    static func segments(for content: String) -> [MarkdownSegment] {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[content] { return cached }
        let result = parse(content)
        if cache.count >= maxEntries { cache.removeAll(keepingCapacity: true) }
        cache[content] = result
        return result
    }

    private static func parse(_ content: String) -> [MarkdownSegment] {
        var result: [MarkdownSegment] = []
        var textBuffer = ""
        var codeBuffer = ""
        var codeLanguage = ""
        var inCode = false
        for line in content.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode {
                    result.append(.code(language: codeLanguage, code: codeBuffer.trimmingCharacters(in: .newlines)))
                    codeBuffer = ""
                    codeLanguage = ""
                    inCode = false
                } else {
                    let trimmed = textBuffer.trimmingCharacters(in: .newlines)
                    if !trimmed.isEmpty { result.append(.text(trimmed)) }
                    textBuffer = ""
                    codeLanguage = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    inCode = true
                }
                continue
            }
            if inCode {
                codeBuffer += line + "\n"
            } else {
                textBuffer += line + "\n"
            }
        }
        if inCode && !codeBuffer.isEmpty {
            result.append(.code(language: codeLanguage, code: codeBuffer.trimmingCharacters(in: .newlines)))
        } else {
            let trimmed = textBuffer.trimmingCharacters(in: .newlines)
            if !trimmed.isEmpty { result.append(.text(trimmed)) }
        }
        return result
    }
}

/// Markdown renderer: pre-segmented content, AttributedString for prose.
struct MarkdownText: View {
    let segments: [MarkdownSegment]

    init(content: String) {
        self.segments = MarkdownSegmenter.segments(for: content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let text):
                    if let attributed = try? AttributedString(
                        markdown: text,
                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                    ) {
                        Text(attributed)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .code(let language, let code):
                    CodeBlockView(language: language, code: code)
                }
            }
        }
    }
}

struct CodeBlockView: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.white.opacity(0.04))
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.body, design: .monospaced))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(.black.opacity(0.35), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.08), lineWidth: 1))
    }
}
