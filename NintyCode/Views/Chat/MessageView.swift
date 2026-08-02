import SwiftUI
import NintyCore

/// Opencode-style message rows: user = right-aligned tinted block, assistant = full-width plain.
struct MessageView: View {
    let message: DisplayMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 120)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.white.opacity(0.08), in: .rect(cornerRadius: 12))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                if !message.text.isEmpty {
                    MarkdownText(content: message.text)
                        .textSelection(.enabled)
                }
                ForEach(message.toolCalls) { call in
                    ToolCallRow(call: call)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            EmptyView()
        }
    }
}
