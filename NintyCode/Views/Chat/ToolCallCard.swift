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
        switch call.name {
        case "edit":
            guard let oldString = call.arguments["oldString"]?.stringValue,
                  let newString = call.arguments["newString"]?.stringValue else { return nil }
            return (newString.components(separatedBy: .newlines).count,
                    oldString.components(separatedBy: .newlines).count)
        case "write":
            guard let content = call.arguments["content"]?.stringValue else { return nil }
            return (content.components(separatedBy: .newlines).count, 0)
        default:
            return nil
        }
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if call.name == "edit", let diff = editDiff {
                DiffView(diff: diff)
            } else if call.name == "write", let diff = writeDiff {
                DiffView(diff: diff)
            } else if call.name == "bash", let command = call.arguments["command"]?.stringValue {
                BashOutputBlock(command: command, output: call.output)
            } else if let output = call.output, !output.isEmpty {
                OutputBlock(text: output, isError: call.isError)
            }
        }
    }

    private var editDiff: (path: String, removed: [String], added: [String])? {
        guard call.name == "edit",
              let path = call.arguments["path"]?.stringValue,
              let oldString = call.arguments["oldString"]?.stringValue,
              let newString = call.arguments["newString"]?.stringValue else { return nil }
        return (path,
                oldString.components(separatedBy: .newlines),
                newString.components(separatedBy: .newlines))
    }

    /// Write renders its content as all-added diff (opencode FileDiff on write).
    private var writeDiff: (path: String, removed: [String], added: [String])? {
        guard call.name == "write",
              let path = call.arguments["path"]?.stringValue,
              let content = call.arguments["content"]?.stringValue else { return nil }
        return (path, [], content.components(separatedBy: .newlines))
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

struct DiffView: View {
    let diff: (path: String, removed: [String], added: [String])

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(diff.path)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textFaint)
                Spacer()
                DiffChangesText(adds: diff.added.count, deletes: diff.removed.count)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diff.removed.enumerated()), id: \.offset) { _, line in
                        Text("- " + line)
                            .foregroundStyle(Theme.diffDelete)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.diffDeleteBg)
                    }
                    ForEach(Array(diff.added.enumerated()), id: \.offset) { _, line in
                        Text("+ " + line)
                            .foregroundStyle(Theme.diffAdd)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.diffAddBg)
                    }
                }
                .font(Theme.mono)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
        }
        .background(Theme.bgDeep, in: .rect(cornerRadius: Theme.radiusSmall))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).stroke(Theme.borderBase, lineWidth: 0.5))
    }
}
