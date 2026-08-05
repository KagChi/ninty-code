import SwiftUI
import NintyCore

/// opencode v2 message rows.
/// User: right-aligned bubble (max 82%, bg layer-02, radius 10), hover meta row.
/// Assistant: full-width markdown + tool rows, hover meta row.
struct MessageView: View {
    @Environment(AppState.self) private var appState
    let message: DisplayMessage
    let agentID: String
    let model: String
    @State private var hovered = false
    @State private var copied = false

    var body: some View {
        if message.isMarker {
            markerDivider
        } else {
            switch message.role {
            case .user:
                userMessage
            case .assistant:
                assistantMessage
            default:
                EmptyView()
            }
        }
    }

    /// opencode "Compaction" divider line.
    private var markerDivider: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Theme.borderMuted).frame(height: 1)
            Text(message.text)
                .font(Theme.caption)
                .foregroundStyle(Theme.textFaint)
                .fixedSize()
            Rectangle().fill(Theme.borderMuted).frame(height: 1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    // MARK: - User

    private var userMessage: some View {
        VStack(alignment: .trailing, spacing: 4) {
            // Attached images (data URLs) — without this they send invisibly.
            if !message.images.isEmpty {
                HStack(spacing: 6) {
                    ForEach(message.images, id: \.self) { dataURL in
                        if let image = AttachmentImage.decode(dataURL) {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: 240, maxHeight: 240)
                                .clipShape(.rect(cornerRadius: 8))
                                .onTapGesture { appState.previewAttachment = dataURL }
                        }
                    }
                }
                .frame(maxWidth: 520, alignment: .trailing)
            }
            // No empty bubble for image-only messages.
            if !message.text.isEmpty {
                Text(message.text)
                    .font(Theme.sans)
                    .foregroundStyle(Theme.textBase)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.layer01, in: .rect(cornerRadius: Theme.radiusLarge))
                    .frame(maxWidth: 520, alignment: .trailing)
            }
            metaRow(alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .onHover { hovered = $0 }
    }

    // MARK: - Assistant

    private var assistantMessage: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Blocks render in emission order: text → tool call → text → tool call.
            ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let text):
                    if !text.isEmpty {
                        MarkdownText(content: text)
                            .font(Theme.sans)
                            .foregroundStyle(Theme.textBase)
                            .textSelection(.enabled)
                    }
                case .toolCall(let call):
                    ToolCallRow(call: call)
                }
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
