import SwiftUI
import NintyCore

struct ToolCallCard: View {
    let call: ToolCallDisplay
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                Divider()
                body_
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                statusIcon
                Text(call.name.isEmpty ? "tool" : call.name)
                    .font(.system(.callout, design: .monospaced))
                    .fontWeight(.medium)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var statusIcon: some View {
        Group {
            switch call.status {
            case .running:
                ProgressView().controlSize(.mini)
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
        }
        .frame(width: 14, height: 14)
    }

    private var summary: String {
        let args = call.arguments
        switch call.name {
        case "bash": return args["command"]?.stringValue ?? ""
        case "read", "write", "edit": return args["path"]?.stringValue ?? ""
        case "grep", "glob": return args["pattern"]?.stringValue ?? ""
        default: return ""
        }
    }

    @ViewBuilder
    private var body_: some View {
        VStack(alignment: .leading, spacing: 8) {
            if call.name == "edit", let diff = editDiff {
                DiffView(diff: diff)
            } else if call.name == "bash", let command = call.arguments["command"]?.stringValue {
                TerminalBlock(title: "command", text: command)
            }
            if let output = call.output, !output.isEmpty {
                TerminalBlock(title: call.isError ? "error" : "output", text: output)
            }
        }
        .padding(12)
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
}

struct TerminalBlock: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            ScrollView([.horizontal, .vertical], showsIndicators: false) {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
        }
        .background(.black.opacity(0.25), in: .rect(cornerRadius: 8))
    }
}

struct DiffView: View {
    let diff: (path: String, removed: [String], added: [String])

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(diff.path)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diff.removed.enumerated()), id: \.offset) { _, line in
                        Text("- " + line)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.red.opacity(0.12))
                    }
                    ForEach(Array(diff.added.enumerated()), id: \.offset) { _, line in
                        Text("+ " + line)
                            .foregroundStyle(.green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.green.opacity(0.12))
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
        }
        .background(.black.opacity(0.25), in: .rect(cornerRadius: 8))
    }
}
