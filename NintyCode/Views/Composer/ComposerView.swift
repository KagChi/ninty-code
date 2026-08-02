import SwiftUI
import NintyCore

/// opencode v2 PromptInput: rounded-xl raised panel, editor top, control bar bottom (h-11).
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
            panel
        }
        .onChange(of: store.restoredDraft) {
            if let draft = store.restoredDraft {
                text = draft
                store.restoredDraft = nil
                focused = true
            }
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(Theme.small)
                    .foregroundStyle(Theme.textBase)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 60, maxHeight: 180)
                    .fixedSize(horizontal: false, vertical: true)
                    .focused($focused)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        send()
                        return .handled
                    }
                    .onChange(of: text) { updateMentions() }
                if text.isEmpty {
                    Text("Ask anything, @ for context…")
                        .font(Theme.small)
                        .foregroundStyle(Theme.textFaint)
                        .padding(.top, 1)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 4)

            controlBar
        }
        .frame(minHeight: 96)
        .glassEffect(.regular.tint(Theme.layer01.opacity(0.5)), in: .rect(cornerRadius: Theme.radiusXL))
        .padding(.horizontal, 12)
        .frame(maxWidth: 800)
    }

    private var controlBar: some View {
        HStack(spacing: 6) {
            agentMenu
            modelMenu
            Spacer()
            submitButton
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
    }

    /// Agent selector: capitalized name + chevron (opencode PromptInputV2Select).
    private var agentMenu: some View {
        Menu {
            ForEach(appState.agents) { agent in
                Button {
                    appState.selectAgent(agent)
                } label: {
                    if agent.id == store.agent.id {
                        Label(agent.name, systemImage: "checkmark")
                    } else {
                        Text(agent.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(Theme.agentColor(store.agent.id))
                    .frame(width: 6, height: 6)
                Text(store.agent.name)
                    .font(Theme.smallMedium)
                    .foregroundStyle(Theme.textMuted)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose agent")
    }

    /// Model selector: provider icon + model name + chevron.
    private var modelMenu: some View {
        Menu {
            if let registry = appState.registry {
                ForEach(registry.presets, id: \.id) { preset in
                    if !preset.models.isEmpty {
                        Section(preset.name) {
                            ForEach(preset.models, id: \.id) { model in
                                Button(model.name) {
                                    appState.selectModel("\(preset.id)/\(model.id)")
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textFaint)
                Text(shortModelName)
                    .font(Theme.smallMedium)
                    .foregroundStyle(Theme.textMuted)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose model")
    }

    private var shortModelName: String {
        guard let (_, model) = ProviderRegistry.split(appState.selectedModel) else {
            return appState.selectedModel
        }
        return model
    }

    /// Submit: 28px rounded-md contrast button, arrow-up / stop.
    @ViewBuilder
    private var submitButton: some View {
        if store.streaming {
            Button {
                store.abort()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.bgBase)
                    .frame(width: 28, height: 28)
                    .background(Theme.textBase, in: .rect(cornerRadius: Theme.radiusSmall))
            }
            .buttonStyle(.plain)
            .help("Stop")
        } else {
            Button {
                send()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.bgBase)
                    .frame(width: 28, height: 28)
                    .background(Theme.textBase, in: .rect(cornerRadius: Theme.radiusSmall))
            }
            .buttonStyle(.plain)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
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
                        .font(Theme.small)
                        .foregroundStyle(Theme.textBase)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Theme.overlayHover.opacity(0))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .backgroundHover
            }
        }
        .padding(6)
        .glassEffect(.regular.tint(Theme.layer01.opacity(0.5)), in: .rect(cornerRadius: Theme.radiusXL))
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .frame(maxWidth: 800)
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

extension View {
    /// Row hover highlight for menu-like lists.
    var backgroundHover: some View {
        self.overlay(
            RoundedRectangle(cornerRadius: Theme.radiusSmall)
                .fill(Theme.overlayHover)
                .opacity(0)
        )
    }
}
