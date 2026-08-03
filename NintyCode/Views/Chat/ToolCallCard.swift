import SwiftUI
import NintyCore

/// opencode v2 tool row: 32px ghost collapsible.
/// [title 14 medium (shimmer while running)] [subtitle 14 muted, truncated] [args] … chevron on hover.
struct ToolCallRow: View {
    let call: ToolCallDisplay
    @State private var expanded = false
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    titleView
                    Text(subtitle)
                        .font(Theme.sans)
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if let changes = diffChanges {
                        DiffChangesText(adds: changes.adds, deletes: changes.deletes)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textFaint)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .opacity(hovered || expanded ? 1 : 0)
                }
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            if expanded {
                detail
                    .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private var titleView: some View {
        let title = toolTitle
        if call.status == .running {
            ShimmerText(text: title, font: Theme.sansMedium, color: Theme.textBase)
        } else {
            Text(title)
                .font(Theme.sansMedium)
                .foregroundStyle(call.status == .failed ? Theme.danger : Theme.textBase)
        }
    }

    /// opencode getToolInfo-style titles.
    private var toolTitle: String {
        switch call.name {
        case "read": return "Read"
        case "list": return "List"
        case "glob": return "Glob"
        case "grep": return "Grep"
        case "bash": return "Shell"
        case "edit": return "Edit"
        case "write": return "Write"
        case "todowrite": return "Todos"
        default:
            if call.name.contains(":") { return "Called \(call.name)" }
            return call.name.prefix(1).uppercased() + call.name.dropFirst()
        }
    }

    private var subtitle: String {
        let args = call.arguments
        switch call.name {
        case "read", "edit", "write":
            return args["path"]?.stringValue.map { ($0 as NSString).lastPathComponent } ?? ""
        case "list":
            return args["path"]?.stringValue ?? "."
        case "glob", "grep":
            return "pattern=\(args["pattern"]?.stringValue ?? "")"
        case "bash":
            return args["command"]?.stringValue ?? ""
        default:
            return ""
        }
    }

    private var diffChanges: (adds: Int, deletes: Int)? {
        guard let diff = toolDiff else { return nil }
        return (diff.additions, diff.deletions)
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let diff = toolDiff {
                InlineDiffView(lines: diff.lines)
                    .background(Theme.bgDeep, in: .rect(cornerRadius: Theme.radiusSmall))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).stroke(Theme.borderBase, lineWidth: 0.5))
            } else if call.name == "bash", let command = call.arguments["command"]?.stringValue {
                BashOutputBlock(command: command, output: call.output)
            } else if let output = call.output, !output.isEmpty {
                OutputBlock(text: output, isError: call.isError)
            }
        }
    }

    /// Edit and write share the same line diff: edit = oldString → newString,
    /// write = nil → content (all added). Matches the turn-end changed-files card.
    private var toolDiff: ChangedFile? {
        switch call.name {
        case "edit":
            guard let path = call.arguments["path"]?.stringValue,
                  let oldString = call.arguments["oldString"]?.stringValue,
                  let newString = call.arguments["newString"]?.stringValue else { return nil }
            return LineDiff.changedFile(path: path, old: oldString, new: newString)
        case "write":
            guard let path = call.arguments["path"]?.stringValue,
                  let content = call.arguments["content"]?.stringValue else { return nil }
            return LineDiff.changedFile(path: path, old: nil, new: content)
        default:
            return nil
        }
    }
}

/// opencode DiffChanges: "+N -M" colored counts.
struct DiffChangesText: View {
    let adds: Int
    let deletes: Int

    var body: some View {
        HStack(spacing: 4) {
            Text("+\(adds)").foregroundStyle(Theme.diffAdd)
            Text("-\(deletes)").foregroundStyle(Theme.diffDelete)
        }
        .font(Theme.mono)
    }
}

/// opencode bash-output: bordered box, mono, "$ cmd\n\noutput", max-height 240.
struct BashOutputBlock: View {
    let command: String
    let output: String?

    var body: some View {
        ScrollView([.vertical], showsIndicators: false) {
            Text(verbatim: "$ \(command)\n\n\(output ?? "")")
                .font(Theme.mono)
                .foregroundStyle(Theme.textMuted)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 240)
        .background(Theme.bgDeep, in: .rect(cornerRadius: Theme.radiusSmall))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).stroke(Theme.borderBase, lineWidth: 0.5))
    }
}

struct OutputBlock: View {
    let text: String
    var isError: Bool = false

    var body: some View {
        ScrollView([.vertical], showsIndicators: false) {
            Text(text)
                .font(Theme.mono)
                .foregroundStyle(isError ? Theme.danger : Theme.textMuted)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 240)
        .background(isError ? Theme.dangerBg.opacity(0.4) : Theme.bgDeep, in: .rect(cornerRadius: Theme.radiusSmall))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).stroke(
            isError ? Theme.danger.opacity(0.4) : Theme.borderBase, lineWidth: 0.5))
    }
}

/// Line-numbered inline diff; long context runs collapse to "N unmodified lines".
/// Shared by tool cards (edit/write) and the turn-end changed-files section.
struct InlineDiffView: View {
    let lines: [DiffLine]
    @State private var revealedBlocks: Set<Int> = []

    /// Consecutive context lines beyond this collapse to a summary band.
    private static let collapseThreshold = 8
    /// Context lines kept visible on each side of a collapsed block.
    private static let contextKeep = 3

    private enum Row: Identifiable {
        case line(Int, DiffLine)
        case collapsed(Int, Int) // block id, hidden count

        var id: Int {
            switch self {
            case .line(let index, _): return index
            case .collapsed(let blockID, _): return -1 - blockID
            }
        }
    }

    private var rows: [Row] {
        var rows: [Row] = []
        var contextRun: [(Int, DiffLine)] = []
        var blockID = 0

        func flushContext() {
            guard !contextRun.isEmpty else { return }
            if contextRun.count > Self.collapseThreshold {
                let keep = Self.contextKeep
                for (index, line) in contextRun.prefix(keep) {
                    rows.append(.line(index, line))
                }
                let hidden = Array(contextRun.dropFirst(keep).dropLast(keep))
                if revealedBlocks.contains(blockID) {
                    for (index, line) in hidden {
                        rows.append(.line(index, line))
                    }
                } else {
                    rows.append(.collapsed(blockID, hidden.count))
                }
                for (index, line) in contextRun.suffix(keep) {
                    rows.append(.line(index, line))
                }
                blockID += 1
            } else {
                for (index, line) in contextRun {
                    rows.append(.line(index, line))
                }
            }
            contextRun = []
        }

        for (index, line) in lines.enumerated() {
            if case .context = line {
                contextRun.append((index, line))
            } else {
                flushContext()
                rows.append(.line(index, line))
            }
        }
        flushContext()
        return rows
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    switch row {
                    case .line(_, let line):
                        lineRow(line)
                    case .collapsed(let blockID, let count):
                        Button {
                            revealedBlocks.insert(blockID)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                                Text("\(count) unmodified lines")
                                    .font(Theme.caption)
                            }
                            .foregroundStyle(Theme.textFaint)
                            .padding(.leading, 40)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.overlayHover)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func lineRow(_ line: DiffLine) -> some View {
        switch line {
        case .context(let text, let newNo):
            row(gutter: "\(newNo)", text: text, color: Theme.textMuted)
        case .added(let text, let newNo):
            row(gutter: "\(newNo)", text: text, color: Theme.textBase,
                background: Theme.diffAddBg, bar: Theme.diffAdd)
        case .removed(let text):
            row(gutter: "", text: text, color: Theme.textMuted,
                background: Theme.diffDeleteBg, bar: Theme.diffDelete)
        }
    }

    private func row(gutter: String, text: String, color: Color,
                     background: Color = .clear, bar: Color = .clear) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(bar)
                .frame(width: 3)
            Text(gutter)
                .font(Theme.mono)
                .foregroundStyle(Theme.textFaint)
                .frame(width: 34, alignment: .trailing)
                .padding(.trailing, 8)
            Text(text.isEmpty ? " " : text)
                .font(Theme.mono)
                .foregroundStyle(color)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
    }
}
