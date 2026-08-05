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

    // MARK: - Meta row (hover-revealed): Agent · Model · HH:MM · elapsed · tokens + copy

    private func metaRow(alignment: HorizontalAlignment) -> some View {
        HStack(spacing: 6) {
            if alignment == .trailing { Spacer() }
            if hovered || copied {
                Text(metaText)
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

    private var metaText: String {
        var parts = [agentID, shortModel, message.timestamp.formatted(date: .omitted, time: .shortened)]
        if let elapsed = message.elapsed { parts.append(TimelineFormat.elapsed(elapsed)) }
        if let tokens = message.tokenCount { parts.append("\(TimelineFormat.tokens(tokens)) tok") }
        return parts.joined(separator: " · ")
    }

    private var shortModel: String {
        appState.modelLabel(model)
    }
}

/// Compact formatting shared by the thinking row and completion footer.
enum TimelineFormat {
    /// 8s / 2m 50s / 1h 3m
    static func elapsed(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m \(seconds % 60)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    /// 1.2k / 34k compact token count.
    static func tokens(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName))
    }
}

/// Streaming "Thinking..." shimmer row (opencode TimelineThinkingRow) with
/// live elapsed seconds while the turn is running.
struct ThinkingRow: View {
    var startedAt: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            ShimmerText(text: label(at: context.date), font: Theme.sansMedium, color: Theme.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func label(at now: Date) -> String {
        guard let startedAt else { return "Thinking..." }
        return "Thinking... \(TimelineFormat.elapsed(now.timeIntervalSince(startedAt)))"
    }
}
