import SwiftUI
import NintyCore

/// Opencode-style composer: text area top, agent/model/send row bottom.
struct ComposerView: View {
    let store: ChatStore
    @Environment(AppState.self) private var appState
    @State private var text = ""
    @State private var mentionQuery: String?
    @State private var mentionResults: [String] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if mentionQuery != nil, !mentionResults.isEmpty {
                mentionPopup
            }
            composer
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 38, maxHeight: 160)
                .fixedSize(horizontal: false, vertical: true)
                .focused($focused)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    send()
                    return .handled
                }
                .onKeyPress(.tab, phases: .down) { _ in
                    cycleAgent()
                    return .handled
                }
                .onChange(of: text) { updateMentions() }
            HStack(spacing: 10) {
                agentButton
                modelMenu
                Spacer()
                sendButton
            }
        }
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
    }

    /// Agent pill — opencode shows active agent, tab/click cycles.
    private var agentButton: some View {
        Button {
            cycleAgent()
        } label: {
            Text(store.agent.id.uppercased())
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(agentColor.opacity(0.2), in: .capsule)
                .foregroundStyle(agentColor)
        }
        .buttonStyle(.plain)
        .help("Agent mode (Tab to switch)")
    }

    private var agentColor: Color {
        store.agent.id == "plan" ? .orange : .accentColor
    }

    private func cycleAgent() {
        let agents = appState.agents
        guard !agents.isEmpty else { return }
        let current = agents.firstIndex { $0.id == appState.selectedAgentID } ?? 0
        let next = agents[(current + 1) % agents.count]
        appState.selectedAgentID = next.id
        // Agent applies per session — recreate chat with same session id on next send.
        appState.reopenChatWithAgent()
    }

    private var modelMenu: some View {
        Menu {
            if let registry = appState.registry {
                ForEach(registry.presets, id: \.id) { preset in
                    if !preset.models.isEmpty {
                        Section(preset.name) {
                            ForEach(preset.models, id: \.id) { model in
                                Button(model.name) {
                                    appState.selectedModel = "\(preset.id)/\(model.id)"
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            Text(shortModelName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Model")
    }

    private var shortModelName: String {
        guard let (_, model) = ProviderRegistry.split(appState.selectedModel) else {
            return appState.selectedModel
        }
        return model
    }

    @ViewBuilder
    private var sendButton: some View {
        if store.streaming {
            Button {
                store.abort()
            } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Stop")
        } else {
            Button {
                send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Send (⌘↵)")
        }
    }

    // MARK: - @ mentions (cached project files)

    private func updateMentions() {
        guard let lastToken = text.components(separatedBy: .whitespacesAndNewlines).last,
              lastToken.hasPrefix("@"), lastToken.count > 1 else {
            mentionQuery = nil
            mentionResults = []
            return
        }
        let query = String(lastToken.dropFirst())
        mentionQuery = query
        mentionResults = appState.projectFiles
            .filter { $0.localizedCaseInsensitiveContains(query) }
            .prefix(8)
            .map { $0 }
    }

    private var mentionPopup: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(mentionResults, id: \.self) { path in
                Button {
                    insertMention(path)
                } label: {
                    Text(path)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
        .padding(.horizontal, 24)
        .padding(.bottom, 4)
    }

    private func insertMention(_ path: String) {
        guard let range = text.range(of: "@\(mentionQuery ?? "")", options: .backwards) else { return }
        text = text.replacingCharacters(in: range, with: "@\(path) ")
        mentionQuery = nil
        mentionResults = []
    }

    private func send() {
        let value = text
        text = ""
        mentionQuery = nil
        mentionResults = []
        store.send(value)
        focused = true
    }
}
