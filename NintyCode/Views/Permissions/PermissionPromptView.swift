import SwiftUI
import NintyCore

struct PermissionPromptView: View {
    let request: PermissionRequest
    let onReply: (PermissionReply) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
                Text("Allow \(request.tool)?")
                    .font(.headline)
            }
            preview
            HStack(spacing: 10) {
                Button("Allow Once") { onReply(.once) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                Button("Always Allow") { onReply(.always) }
                Spacer()
                Button("Deny", role: .destructive) { onReply(.reject) }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(14)
        .glassEffect(.regular.tint(.orange.opacity(0.15)), in: .rect(cornerRadius: 14))
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var preview: some View {
        if request.tool == "edit",
           let oldString = request.arguments["oldString"]?.stringValue,
           let newString = request.arguments["newString"]?.stringValue {
            DiffView(diff: (
                path: request.arguments["path"]?.stringValue ?? "",
                removed: oldString.components(separatedBy: .newlines),
                added: newString.components(separatedBy: .newlines)
            ))
        } else {
            Text(request.preview)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.black.opacity(0.25), in: .rect(cornerRadius: 8))
        }
    }
}
