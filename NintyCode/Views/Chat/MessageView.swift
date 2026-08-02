import SwiftUI
import NintyCore

/// opencode v2 message rows.
/// User: right-aligned bubble (max 82%, bg layer-02, radius 10), hover meta row.
/// Assistant: full-width markdown + tool rows, hover meta row.
struct MessageView: View {
    let message: DisplayMessage
    let agentID: String
    let model: String
    @State private var hovered = false
    @State private var copied = false

    var body: some View {
        switch message.role {
        case .user:
            userMessage
        case .assistant:
            assistantMessage
        default:
            EmptyView()
        }
    }

    // MARK: - User

    private var userMessage: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(message.text)
                .font(Theme.sans)
                .foregroundStyle(Theme.textBase)
                .lineSpacing(3)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.layer02, in: .rect(cornerRadius: Theme.radiusLarge))
                .frame(maxWidth: 520, alignment: .trailing)
            metaRow(alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .onHover { hovered = $0 }
    }

    // MARK: - Assistant

    private var assistantMessage: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !message.text.isEmpty {
                MarkdownText(content: message.text)
                    .font(Theme.sans)
                    .foregroundStyle(Theme.textBase)
                    .textSelection(.enabled)
            }
            ForEach(message.toolCalls) { call in
                ToolCallRow(call: call)
            }
            metaRow(alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovered = $0 }
    }

    // MARK: - Meta row (hover-revealed): Agent · Model · HH:MM + copy

    private func metaRow(alignment: HorizontalAlignment) -> some View {
        HStack(spacing: 6) {
            if alignment == .trailing { Spacer() }
            if hovered || copied {
                Text("\(agentID) · \(shortModel) · \(message.timestamp.formatted(date: .omitted, time: .shortened))")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textFaint)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.text, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textFaint)
                }
                .buttonStyle(.plain)
            } else {
                Text(" ").font(Theme.caption)
            }
            if alignment == .leading { Spacer() }
        }
        .frame(minHeight: 18)
        .animation(.easeInOut(duration: 0.15), value: hovered)
    }

    private var shortModel: String {
        ProviderRegistry.split(model)?.model ?? model
    }
}

/// Streaming "Thinking..." shimmer row (opencode TimelineThinkingRow).
struct ThinkingRow: View {
    var body: some View {
        ShimmerText(text: "Thinking...", font: Theme.sansMedium, color: Theme.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
