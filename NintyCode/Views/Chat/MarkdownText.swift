import SwiftUI

enum MarkdownSegment: Equatable {
    case text(String)
    case code(language: String, code: String)
    case heading(level: Int, text: String)
    case table(headers: [String], rows: [[String]])
    case list(items: [String], ordered: Bool)
    case quote(String)
}

/// Segments markdown into block-level segments. Memoized — parse once per unique content.
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
        let lines = content.components(separatedBy: .newlines)
        var textBuffer: [String] = []
        var index = 0

        func flushText() {
            let text = textBuffer.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !text.isEmpty { result.append(.text(text)) }
            textBuffer = []
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block
            if trimmed.hasPrefix("```") {
                flushText()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                index += 1
                while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[index])
                    index += 1
                }
                index += 1 // skip closing fence
                result.append(.code(
                    language: language,
                    code: codeLines.joined(separator: "\n").trimmingCharacters(in: .newlines)
                ))
                continue
            }

            // Heading
            if let heading = parseHeading(trimmed) {
                flushText()
                result.append(heading)
                index += 1
                continue
            }

            // Table: | h | h | followed by |---|---|
            if isTableRow(trimmed), index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
                flushText()
                let headers = splitTableRow(trimmed)
                index += 2 // header + separator
                var rows: [[String]] = []
                while index < lines.count && isTableRow(lines[index].trimmingCharacters(in: .whitespaces)) {
                    rows.append(splitTableRow(lines[index].trimmingCharacters(in: .whitespaces)))
                    index += 1
                }
                result.append(.table(headers: headers, rows: rows))
                continue
            }

            // List: consecutive - / * / + or N. items
            if listMarker(trimmed) != nil {
                flushText()
                var items: [String] = []
                var ordered = false
                while index < lines.count, let (item, isOrdered) = listMarker(lines[index].trimmingCharacters(in: .whitespaces)) {
                    ordered = ordered || isOrdered
                    items.append(item)
                    index += 1
                }
                result.append(.list(items: items, ordered: ordered))
                continue
            }

            // Blockquote
            if trimmed.hasPrefix(">") {
                flushText()
                var quoteLines: [String] = []
                while index < lines.count && lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var q = lines[index].trimmingCharacters(in: .whitespaces)
                    q = String(q.dropFirst()).trimmingCharacters(in: .whitespaces)
                    quoteLines.append(q)
                    index += 1
                }
                result.append(.quote(quoteLines.joined(separator: "\n")))
                continue
            }

            textBuffer.append(line)
            index += 1
        }
        flushText()
        return result
    }

    private static func parseHeading(_ line: String) -> MarkdownSegment? {
        var level = 0
        for char in line {
            if char == "#" { level += 1 } else { break }
        }
        guard level >= 1, level <= 6, line.count > level, line[line.index(line.startIndex, offsetBy: level)] == " " else {
            return nil
        }
        let text = String(line.dropFirst(level + 1)).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : .heading(level: level, text: text)
    }

    private static func isTableRow(_ line: String) -> Bool {
        line.hasPrefix("|") && line.hasSuffix("|") && line.count > 1
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|") else { return false }
        let cells = splitTableRow(trimmed)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let dashes = cell.filter { $0 == "-" }.count
            let others = cell.filter { $0 != "-" && $0 != ":" }.count
            return dashes >= 1 && others == 0
        }
    }

    private static func splitTableRow(_ line: String) -> [String] {
        var row = line.trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("|") { row = String(row.dropFirst()) }
        if row.hasSuffix("|") { row = String(row.dropLast()) }
        return row.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Returns (itemText, isOrdered) for list lines, nil otherwise.
    private static func listMarker(_ line: String) -> (String, Bool)? {
        for marker in ["- ", "* ", "+ "] {
            if line.hasPrefix(marker) {
                let item = String(line.dropFirst(marker.count))
                return item.isEmpty ? nil : (item, false)
            }
        }
        // Ordered: "1. ", "12. " etc.
        var digits = 0
        for char in line {
            if char.isNumber { digits += 1 } else { break }
        }
        if digits > 0, line.count > digits + 1 {
            let rest = line[line.index(line.startIndex, offsetBy: digits)...]
            if rest.hasPrefix(". ") {
                let item = String(rest.dropFirst(2))
                return item.isEmpty ? nil : (item, true)
            }
        }
        return nil
    }
}

/// Markdown renderer: pre-segmented content, block views for structure.
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
                    InlineMarkdownText(text: text)
                case .code(let language, let code):
                    CodeBlockView(language: language, code: code)
                case .heading(let level, let text):
                    InlineMarkdownText(text: text)
                        .font(headingFont(level))
                        .foregroundStyle(Theme.textBase)
                case .table(let headers, let rows):
                    MarkdownTableView(headers: headers, rows: rows)
                case .list(let items, let ordered):
                    MarkdownListView(items: items, ordered: ordered)
                case .quote(let text):
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Theme.textFaint)
                            .frame(width: 3)
                        InlineMarkdownText(text: text)
                            .foregroundStyle(Theme.textMuted)
                    }
                }
            }
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .system(size: 20, weight: .bold)
        case 2: return .system(size: 17, weight: .bold)
        case 3: return .system(size: 15, weight: .semibold)
        default: return .system(size: 14, weight: .semibold)
        }
    }
}

/// Inline markdown (bold/italic/code/links) via AttributedString.
struct InlineMarkdownText: View {
    let text: String

    var body: some View {
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
    }
}

/// GFM table: header row on layer01, zebra rows, cell borders, horizontal scroll.
struct MarkdownTableView: View {
    let headers: [String]
    let rows: [[String]]

    private var columnCount: Int {
        max(headers.count, rows.map(\.count).max() ?? 0)
    }

    private func cell(_ row: [String], _ column: Int) -> String {
        column < row.count ? row[column] : ""
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(0..<columnCount, id: \.self) { column in
                        InlineMarkdownText(text: cell(headers, column))
                            .font(Theme.smallMedium)
                            .foregroundStyle(Theme.textBase)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(minWidth: 80, alignment: .leading)
                    }
                }
                .background(Theme.layer01)
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    HStack(spacing: 0) {
                        ForEach(0..<columnCount, id: \.self) { column in
                            InlineMarkdownText(text: cell(row, column))
                                .font(Theme.small)
                                .foregroundStyle(Theme.textMuted)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .frame(minWidth: 80, alignment: .leading)
                        }
                    }
                    .background(rowIndex.isMultiple(of: 2) ? .clear : Theme.layer02.opacity(0.4))
                }
            }
        }
        .background(Theme.bgDeep, in: .rect(cornerRadius: Theme.radiusSmall))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).stroke(Theme.borderBase, lineWidth: 0.5))
    }
}

/// Bullet/numbered list: marker column + inline markdown items.
struct MarkdownListView: View {
    let items: [String]
    let ordered: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ordered ? "\(index + 1)." : "•")
                        .font(Theme.small)
                        .foregroundStyle(Theme.textFaint)
                        .frame(width: ordered ? 20 : 10, alignment: .trailing)
                    InlineMarkdownText(text: item)
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
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textFaint)
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
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textFaint)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Theme.layer01)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(Theme.mono)
                    .foregroundStyle(Theme.textBase)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.bgDeep, in: .rect(cornerRadius: Theme.radiusLarge))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusLarge).stroke(Theme.borderBase, lineWidth: 0.5))
    }
}
