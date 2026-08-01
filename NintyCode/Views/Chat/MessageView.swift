import SwiftUI
import NintyCore

struct MessageView: View {
    let message: DisplayMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .glassEffect(.regular.tint(.accentColor.opacity(0.25)), in: .rect(cornerRadius: 16))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 10) {
                if !message.text.isEmpty {
                    MarkdownText(content: message.text)
                        .textSelection(.enabled)
                }
                ForEach(message.toolCalls) { call in
                    ToolCallCard(call: call)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            EmptyView()
        }
    }
}

/// Markdown renderer: segments fenced code blocks, renders text via AttributedString.
struct MarkdownText: View {
    let content: String

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

    enum Segment {
        case text(String)
        case code(language: String, code: String)
    }

    var segments: [Segment] {
        var result: [Segment] = []
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
                    if !textBuffer.trimmingCharacters(in: .newlines).isEmpty {
                        result.append(.text(textBuffer.trimmingCharacters(in: .newlines)))
                    }
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
        } else if !textBuffer.trimmingCharacters(in: .newlines).isEmpty {
            result.append(.text(textBuffer.trimmingCharacters(in: .newlines)))
        }
        return result
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
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.body, design: .monospaced))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(.black.opacity(0.25), in: .rect(cornerRadius: 10))
    }
}
