import SwiftUI
import NintyCore

struct ComposerView: View {
    let store: ChatStore
    @Environment(AppState.self) private var appState
    @State private var text = ""
    @State private var mentionQuery: String?
    @State private var mentionResults: [String] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let mentionQuery, !mentionResults.isEmpty {
                mentionPopup(query: mentionQuery)
            }
            composer
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 40, maxHeight: 160)
                .fixedSize(horizontal: false, vertical: true)
                .focused($focused)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    send()
                    return .handled
                }
                .onChange(of: text) { updateMentions() }
            HStack(spacing: 12) {
                agentPicker
                modelPicker
                Spacer()
                if store.streaming {
                    Button {
                        store.abort()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                    .help("Stop")
                } else {
                    Button {
                        send()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Send (⌘↵)")
                }
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var agentPicker: some View {
        Picker(selection: Binding(
            get: { appState.selectedAgentID },
            set: { appState.selectedAgentID = $0 }
        )) {
            ForEach(appState.agents) { agent in
                Text(agent.name).tag(agent.id)
            }
        } label: {
            Image(systemName: "person.crop.circle")
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help("Agent mode")
    }

    private var modelPicker: some View {
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
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                Text(shortModelName)
                    .font(.caption)
            }
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

    // MARK: - @ mentions

    private func updateMentions() {
        guard let lastToken = text.components(separatedBy: .whitespacesAndNewlines).last,
              lastToken.hasPrefix("@"), lastToken.count > 1 else {
            mentionQuery = nil
            mentionResults = []
            return
        }
        mentionQuery = String(lastToken.dropFirst())
        searchFiles(query: mentionQuery ?? "")
    }

    private func searchFiles(query: String) {
        guard let root = appState.projectRoot else { return }
        Task {
            let tool = GlobTool()
            let pattern = query.isEmpty ? "**/*" : "**/*\(query)*"
            let result = try? await tool.execute(
                ["pattern": .string(pattern)],
                ctx: ToolContext(projectRoot: root, sessionID: store.sessionID)
            )
            let paths = result?.output.components(separatedBy: .newlines)
                .filter { !$0.isEmpty && !$0.hasPrefix("(") } ?? []
            mentionResults = Array(paths.prefix(8)).map { path in
                path.hasPrefix(root.path) ? String(path.dropFirst(root.path.count + 1)) : path
            }
        }
    }

    private func mentionPopup(query: String) -> some View {
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
        .padding(.horizontal, 20)
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
