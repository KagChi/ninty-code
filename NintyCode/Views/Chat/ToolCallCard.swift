import SwiftUI
import NintyCore

/// Opencode-style compact tool row: status icon + name + summary, click to expand.
struct ToolCallRow: View {
    let call: ToolCallDisplay
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    statusIcon
                    Text(call.name.isEmpty ? "tool" : call.name)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.primary)
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if call.output != nil || call.name == "edit" || call.name == "bash" {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                detail
                    .padding(.leading, 22)
                    .padding(.top, 4)
                    .padding(.bottom, 6)
            }
        }
    }

    private var statusIcon: some View {
        Group {
            switch call.status {
            case .running:
                ProgressView().controlSize(.mini)
            case .done:
                Image(systemName: "checkmark").foregroundStyle(.green)
            case .failed:
                Image(systemName: "xmark").foregroundStyle(.red)
            }
        }
        .font(.system(.caption, weight: .bold))
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
    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if call.name == "edit", let diff = editDiff {
                DiffView(diff: diff)
            } else if call.name == "bash", let command = call.arguments["command"]?.stringValue {
                DetailBlock(title: "command", text: command)
            }
            if let output = call.output, !output.isEmpty {
                DetailBlock(title: call.isError ? "error" : "output", text: output)
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
}

struct DetailBlock: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.tertiary)
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
        .background(.black.opacity(0.35), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.08), lineWidth: 1))
    }
}

struct DiffView: View {
    let diff: (path: String, removed: [String], added: [String])

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(diff.path)
                .font(.caption2)
                .foregroundStyle(.tertiary)
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
        .background(.black.opacity(0.35), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.08), lineWidth: 1))
    }
}
