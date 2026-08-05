import SwiftUI
import NintyCore

/// opencode session-context-tab: stats grid, context breakdown bar,
/// system prompt card, raw messages accordion.
struct ContextTabView: View {
    @Environment(AppState.self) private var appState
    let chat: ChatStore

    @State private var showSystemPrompt = false
    @State private var rawMessages: [Message] = []
    @State private var expandedRaw: Set<Int> = []

    private var meta: SessionMeta? {
        appState.sessions.first { $0.id == chat.sessionID }
    }

    private var providerLabel: String {
        guard let (providerID, _) = ProviderRegistry.split(chat.modelReference) else { return "—" }
        return appState.registry?.preset(id: providerID)?.name ?? providerID
    }

    private var modelLabel: String {
        guard let (providerID, modelID) = ProviderRegistry.split(chat.modelReference) else {
            return chat.model
        }
        return appState.registry?.preset(id: providerID)?.models.first { $0.id == modelID }?.name ?? modelID
    }

    private var userCount: Int { chat.messages.filter { $0.role == .user && !$0.isMarker }.count }
    private var assistantCount: Int { chat.messages.filter { $0.role == .assistant && !$0.isMarker }.count }
    private var messageCount: Int { userCount + assistantCount }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statsGrid
                if let breakdown = contextBreakdown, !breakdown.isEmpty {
                    breakdownSection(breakdown)
                }
                if !chat.systemPrompt.isEmpty {
                    systemPromptCard
                }
                rawMessagesSection
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await loadRaw() }
        .onChange(of: chat.messages.count) { _, _ in
            Task { await loadRaw() }
        }
    }

    // MARK: - Stats grid (opencode 2-col Stat rows)

    private var statsGrid: some View {
        let usage = chat.lastUsage
        let stats: [(String, String)] = [
            ("Session", meta?.title ?? "—"),
            ("Messages", messageCount.formatted()),
            ("Provider", providerLabel),
            ("Model", modelLabel),
            ("Context Limit", chat.contextWindow.formatted()),
            ("Total Tokens", (usage?.total ?? 0).formatted()),
            ("Usage", usagePercent),
            ("Input Tokens", (usage?.input ?? 0).formatted()),
            ("Output Tokens", (usage?.output ?? 0).formatted()),
            ("Reasoning Tokens", (usage?.reasoning ?? 0).formatted()),
            ("Cache Tokens (read/write)", "\((usage?.cacheRead ?? 0).formatted()) / \((usage?.cacheWrite ?? 0).formatted())"),
            ("User Messages", userCount.formatted()),
            ("Assistant Messages", assistantCount.formatted()),
            ("Total Cost", "$0.00"),
            ("Session Created", formatted(meta?.created)),
            ("Last Activity", formatted(meta?.updated)),
        ]
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ForEach(Array(stats.enumerated()), id: \.offset) { _, stat in
                VStack(alignment: .leading, spacing: 2) {
                    Text(stat.0)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textFaint)
                    Text(stat.1)
                        .font(Theme.captionMedium)
                        .foregroundStyle(Theme.textBase)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var usagePercent: String {
        guard let usage = chat.lastUsage, chat.contextWindow > 0 else { return "—" }
        let percent = Int((Double(usage.total) / Double(chat.contextWindow)) * 100)
        return "\(percent)%"
    }

    private func formatted(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - Context breakdown (ported chars/4 estimator)

    private struct BreakdownSegment {
        let key: String
        let tokens: Int
        let width: Double
        let percent: Double
        let color: Color
    }

    private var contextBreakdown: [BreakdownSegment]? {
        guard let input = chat.lastUsage?.input, input > 0 else { return nil }
        var system = chat.systemPrompt.count
        var user = 0
        var assistant = 0
        var tool = 0
        for message in rawMessages {
            for part in message.parts {
                switch (message.role, part) {
                case (.user, .text(let text)): user += text.count
                case (.user, .image(let dataURL)): user += dataURL.count
                case (.assistant, .text(let text)): assistant += text.count
                case (.assistant, .toolCall(_, _, let arguments)):
                    tool += (try? String(data: JSONEncoder().encode(arguments), encoding: .utf8)?.count) ?? 0
                case (.tool, .toolResult(_, _, let output, _)): tool += output.count
                default: break
                }
            }
        }
        system += chat.messages.filter { $0.role == .assistant }.count * 0 // no-op, keeps structure clear

        func estimate(_ chars: Int) -> Int { Int(ceil(Double(chars) / 4.0)) }
        var tokens = (
            system: estimate(system),
            user: estimate(user),
            assistant: estimate(assistant),
            tool: estimate(tool)
        )
        let estimated = tokens.system + tokens.user + tokens.assistant + tokens.tool
        var other: Int
        if estimated <= input {
            other = input - estimated
        } else {
            let scale = Double(input) / Double(estimated)
            tokens = (
                system: Int(Double(tokens.system) * scale),
                user: Int(Double(tokens.user) * scale),
                assistant: Int(Double(tokens.assistant) * scale),
                tool: Int(Double(tokens.tool) * scale)
            )
            other = max(0, input - tokens.system - tokens.user - tokens.assistant - tokens.tool)
        }

        func segment(_ key: String, _ value: Int, _ color: Color) -> BreakdownSegment? {
            guard value > 0 else { return nil }
            return BreakdownSegment(
                key: key, tokens: value,
                width: Double(value) / Double(input) * 100,
                percent: (Double(value) / Double(input) * 1000).rounded() / 10,
                color: color
            )
        }
        return [
            segment("System", tokens.system, Theme.textAccent),
            segment("User", tokens.user, Theme.success),
            segment("Assistant", tokens.assistant, Color(red: 0x66 / 255, green: 0xc2 / 255, blue: 0xa5 / 255)),
            segment("Tool Calls", tokens.tool, Theme.warning),
            segment("Other", other, Theme.textFaint),
        ].compactMap { $0 }
    }

    private func breakdownSection(_ segments: [BreakdownSegment]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Context Breakdown")
                .font(Theme.caption)
                .foregroundStyle(Theme.textFaint)
            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: max(2, CGFloat(segment.width) / 100 * barWidth))
                }
            }
            .frame(height: 8)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .background(GeometryReader { proxy in
                Color.clear.preference(key: BarWidthKey.self, value: proxy.size.width)
            })
            .onPreferenceChange(BarWidthKey.self) { barWidth = $0 }
            .background(Theme.layer02, in: .rect(cornerRadius: 4))
            FlowLayout(spacing: 8) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(segment.color)
                            .frame(width: 8, height: 8)
                        Text(segment.key)
                            .font(Theme.tiny)
                            .foregroundStyle(Theme.textMuted)
                        Text("\(segment.percent, specifier: "%.1f")%")
                            .font(Theme.tiny)
                            .foregroundStyle(Theme.textFaint)
                    }
                }
            }
        }
    }

    @State private var barWidth: CGFloat = 400

    // MARK: - System prompt card

    private var systemPromptCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showSystemPrompt.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("System Prompt")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textFaint)
                    Image(systemName: showSystemPrompt ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textFaint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showSystemPrompt {
                MarkdownText(content: chat.systemPrompt)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textMuted)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.layer02, in: .rect(cornerRadius: Theme.radiusSmall))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).stroke(Theme.borderMuted, lineWidth: 0.5))
            }
        }
    }

    // MARK: - Raw messages accordion

    private var rawMessagesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Raw Messages")
                .font(Theme.caption)
                .foregroundStyle(Theme.textFaint)
            VStack(spacing: 1) {
                ForEach(Array(rawMessages.enumerated()), id: \.offset) { index, message in
                    rawRow(index: index, message: message)
                }
            }
            .background(Theme.layer02, in: .rect(cornerRadius: Theme.radiusSmall))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).stroke(Theme.borderMuted, lineWidth: 0.5))
        }
    }

    private func rawRow(index: Int, message: Message) -> some View {
        let expanded = expandedRaw.contains(index)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if expanded { expandedRaw.remove(index) } else { expandedRaw.insert(index) }
            } label: {
                HStack(spacing: 6) {
                    Text(message.role.rawValue)
                        .font(Theme.captionMedium)
                        .foregroundStyle(Theme.textBase)
                    Text("• #\(index)")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textFaint)
                    Spacer()
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textFaint)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Text(prettyJSON(message))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textMuted)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.bgDeep)
            }
        }
    }

    private func prettyJSON(_ message: Message) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(message),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    private func loadRaw() async {
        let store = SessionStore(storageKey: chat.workspaceID)
        if let loaded = try? await store.load(id: chat.sessionID) {
            rawMessages = loaded.messages
        }
    }
}

private struct BarWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 400
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Minimal wrap layout for the legend chips.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
