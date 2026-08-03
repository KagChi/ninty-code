import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NintyCore

/// Slash command definition (opencode builtin set).
struct SlashCommand: Identifiable {
    let id: String      // "new", "undo", ...
    let title: String   // "/new"
    let hint: String
}

/// opencode v2 PromptInput: raised panel, editor top, control bar bottom.
/// Parity: slash commands, prompt history (↑/↓), shell mode (!), attachments,
/// rotating placeholders, per-session draft persistence.
struct ComposerView: View {
    let store: ChatStore
    @Environment(AppState.self) private var appState

    @State private var text = ""
    @State private var mentionQuery: String?
    @State private var mentionResults: [String] = []
    @State private var slashQuery: String?
    @State private var shellMode = false
    @State private var attachments: [String] = [] // data URLs
    @State private var placeholderIndex = 0
    @State private var showAgentPicker = false
    @FocusState private var focused: Bool

    private let history = PromptHistory()
    private let shellHistory = PromptHistory(shell: true)
    private let placeholderTimer = Timer.publish(every: 6.5, on: .main, in: .common).autoconnect()

    static let placeholders = [
        "Ask anything, @ for context…",
        "Fix the failing tests…",
        "Explain how auth works…",
        "Refactor this function…",
        "Add dark mode support…",
        "Find where errors are handled…",
        "Write a plan for the migration…",
        "Review my last change…"
    ]

    static let slashCommands: [SlashCommand] = [
        SlashCommand(id: "new", title: "/new", hint: "New session"),
        SlashCommand(id: "undo", title: "/undo", hint: "Revert last turn"),
        SlashCommand(id: "redo", title: "/redo", hint: "Re-apply reverted turn"),
        SlashCommand(id: "compact", title: "/compact", hint: "Summarize context"),
        SlashCommand(id: "fork", title: "/fork", hint: "Fork from a message"),
        SlashCommand(id: "agent", title: "/agent", hint: "Cycle agent"),
        SlashCommand(id: "model", title: "/model", hint: "Model dialog")
    ]

    private var activeHistory: PromptHistory { shellMode ? shellHistory : history }

    var body: some View {
        VStack(spacing: 0) {
            if slashQuery != nil, !filteredSlashCommands.isEmpty {
                slashPopup
            } else if mentionQuery != nil, !mentionResults.isEmpty {
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
        .onReceive(placeholderTimer) { _ in
            guard store.messages.isEmpty else { return }
            placeholderIndex = (placeholderIndex + 1) % Self.placeholders.count
        }
        .onAppear { restoreDraft() }
        .onChange(of: store.sessionID) { restoreDraft() }
    }

    // MARK: - Panel

    private var panel: some View {
        VStack(spacing: 0) {
            if !attachments.isEmpty {
                attachmentStrip
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(shellMode ? Theme.mono : Theme.small)
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
                    .onKeyPress(.upArrow, phases: .down) { _ in
                        historyBack() ? .handled : .ignored
                    }
                    .onKeyPress(.downArrow, phases: .down) { _ in
                        historyForward() ? .handled : .ignored
                    }
                    .onKeyPress(.escape, phases: .down) { _ in
                        escapeTapped() ? .handled : .ignored
                    }
                    .onKeyPress(characters: .init(charactersIn: "!"), phases: .down) { _ in
                        if text.isEmpty && !shellMode {
                            shellMode = true
                            return .handled // eat the "!"
                        }
                        return .ignored
                    }
                    .onChange(of: text) { oldValue, newValue in
                        if shellMode && oldValue.isEmpty == false && newValue.isEmpty {
                            shellMode = false // backspace on empty shell prompt exits
                        }
                        activeHistory.reset()
                        updateTriggers()
                        persistDraft()
                    }
                if text.isEmpty {
                    Text(shellMode ? "git status" : Self.placeholders[placeholderIndex])
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
        .glassEffect(.regular.tint(Theme.bgBase.opacity(0.5)), in: .rect(cornerRadius: Theme.radiusXL))
        .padding(.horizontal, 12)
        .frame(maxWidth: 800)
        .onPasteCommand(of: [.png, .tiff, .jpeg, .fileURL]) { providers in
            handlePaste(providers)
        }
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls)
        }
    }

    // MARK: - Attachments

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(attachments.enumerated()), id: \.offset) { index, dataURL in
                    AttachmentThumb(dataURL: dataURL) {
                        attachments.remove(at: index)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
        }
    }

    private func handlePaste(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data, let mime = data.imageMIME else { return }
                    Task { @MainActor in
                        attachments.append("data:\(mime);base64,\(data.base64EncodedString())")
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in attachFile(url) }
                }
            }
        }
    }

    private func handleDrop(_ urls: [URL]) -> Bool {
        guard let url = urls.first else { return false }
        attachFile(url)
        return true
    }

    /// Images attach as data URLs; other files become @mentions (opencode file: drop behavior).
    private func attachFile(_ url: URL) {
        if let data = try? Data(contentsOf: url), let mime = data.imageMIME {
            attachments.append("data:\(mime);base64,\(data.base64EncodedString())")
        } else if let projectRoot = appState.projectRoot {
            let path = url.path
            let relative = path.hasPrefix(projectRoot.path + "/")
                ? String(path.dropFirst(projectRoot.path.count + 1))
                : path
            text += "@\(relative) "
        }
    }

    // MARK: - History (↑/↓)

    /// opencode gating: Up only when caret at pos 0 (or empty); once navigating, free.
    private func historyBack() -> Bool {
        guard text.isEmpty || activeHistory.isNavigating else { return false }
        if let recalled = activeHistory.older(currentDraft: text) {
            text = recalled
            return true
        }
        return activeHistory.isNavigating // swallow key even at oldest
    }

    private func historyForward() -> Bool {
        guard activeHistory.isNavigating else { return false }
        if let recalled = activeHistory.newer() {
            text = recalled
        }
        return true
    }

    // MARK: - Escape cascade (opencode: popover → shell → abort → blur)

    private func escapeTapped() -> Bool {
        if slashQuery != nil || mentionQuery != nil {
            slashQuery = nil
            mentionQuery = nil
            return true
        }
        if shellMode {
            shellMode = false
            return true
        }
        if store.streaming {
            store.abort()
            return true
        }
        focused = false
        return true
    }

    // MARK: - Triggers (@ / slash)

    private func updateTriggers() {
        // Slash: whole text matches /^\/(\S*)$/ (opencode), not in shell mode.
        if !shellMode, let match = text.wholeMatch(of: /^\/(\S*)$/) {
            slashQuery = String(match.1)
            mentionQuery = nil
            mentionResults = []
            return
        }
        slashQuery = nil
        updateMentions()
    }

    private var filteredSlashCommands: [SlashCommand] {
        let query = slashQuery ?? ""
        return Self.slashCommands.filter { query.isEmpty || $0.id.hasPrefix(query) }
    }

    private var slashPopup: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(filteredSlashCommands) { command in
                Button {
                    runSlashCommand(command)
                } label: {
                    HStack {
                        Text(command.title)
                            .font(Theme.smallMedium)
                            .foregroundStyle(Theme.textBase)
                        Spacer()
                        Text(command.hint)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textFaint)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .backgroundHover
            }
        }
        .padding(6)
        .glassEffect(.regular.tint(Theme.bgBase.opacity(0.5)), in: .rect(cornerRadius: Theme.radiusXL))
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .frame(maxWidth: 800)
    }

    private func runSlashCommand(_ command: SlashCommand) {
        text = ""
        slashQuery = nil
        switch command.id {
        case "new": appState.newChat()
        case "undo": store.undo()
        case "redo": store.redo()
        case "compact": store.compact()
        case "fork": store.showForkDialog = true
        case "agent": appState.cycleAgent()
        case "model": appState.showModelDialog = true
        default: break
        }
    }

    // MARK: - Control bar

    private var controlBar: some View {
        HStack(spacing: 6) {
            attachButton
            agentMenu
            modelMenu
            if store.autoAccept {
                Image(systemName: "shield.checkered")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.warning)
                    .help("Auto-accept on (⇧⌘A)")
            }
            Spacer()
            submitButton
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
    }

    private var attachButton: some View {
        Button {
            pickAttachment()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textFaint)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("u", modifiers: .command)
        .help("Attach image or file")
    }

    private func pickAttachment() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .pdf, .text, .json, .sourceCode]
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK else { return }
            Task { @MainActor in
                for url in panel.urls { attachFile(url) }
            }
        }
    }

    /// Agent selector: capitalized name + chevron (opencode PromptInputV2Select).
    /// Plain Button + popover — a SwiftUI Menu draws AppKit chrome (extra
    /// indicator chevron, selected-item checkmark) on top of the custom label.
    private var agentMenu: some View {
        Button {
            showAgentPicker.toggle()
        } label: {
            HStack(spacing: 4) {
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
        .buttonStyle(.plain)
        .popover(isPresented: $showAgentPicker, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(appState.agents) { agent in
                    Button {
                        appState.selectAgent(agent)
                        showAgentPicker = false
                    } label: {
                        HStack(spacing: 6) {
                            Text(agent.name)
                                .font(Theme.small)
                                .foregroundStyle(Theme.textBase)
                            Spacer()
                            if agent.id == store.agent.id {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Theme.textAccent)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(AgentPickerRowStyle())
                }
            }
            .padding(4)
            .frame(width: 170)
            .background(Theme.bgBase)
        }
        .help("Choose agent (⌘.)")
    }

    /// Model selector: opens the searchable model dialog (⌘') — same surface,
    /// search + recents + provider groups instead of a flat menu.
    private var modelMenu: some View {
        Button {
            appState.showModelDialog = true
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
        .buttonStyle(.plain)
        .help("Choose model (⌘')")
    }

    private var shortModelName: String {
        guard let (_, model) = ProviderRegistry.split(appState.selectedModel) else {
            return appState.selectedModel
        }
        return model
    }

    /// Submit: 28px rounded-md contrast button, arrow-up / stop / shell-undo icon.
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
            .help("Stop (Esc)")
        } else {
            Button {
                send()
            } label: {
                Image(systemName: shellMode ? "arrow.uturn.down" : "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.bgBase)
                    .frame(width: 28, height: 28)
                    .background(Theme.textBase, in: .rect(cornerRadius: Theme.radiusSmall))
            }
            .buttonStyle(.plain)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
            .opacity(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty ? 0.5 : 1)
            .keyboardShortcut(.return, modifiers: .command)
            .help(shellMode ? "Run command" : "Send (⌘↵)")
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
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .backgroundHover
            }
        }
        .padding(6)
        .glassEffect(.regular.tint(Theme.bgBase.opacity(0.5)), in: .rect(cornerRadius: Theme.radiusXL))
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

    // MARK: - Draft persistence (per session)

    private var draftKey: String { "draft-\(store.sessionID)" }

    private func restoreDraft() {
        text = UserDefaults.standard.string(forKey: draftKey) ?? ""
    }

    private func persistDraft() {
        UserDefaults.standard.set(text.isEmpty ? nil : text, forKey: draftKey)
    }

    // MARK: - Send

    private func send() {
        let value = text
        let images = attachments
        text = ""
        attachments = []
        mentionQuery = nil
        mentionResults = []
        slashQuery = nil
        UserDefaults.standard.removeObject(forKey: draftKey)
        if shellMode {
            shellHistory.push(value)
            store.runShell(value)
        } else {
            history.push(value)
            store.send(value, images: images)
        }
        focused = true
    }
}

/// Attachment thumbnail with hover-remove (opencode image-attachments).
struct AttachmentThumb: View {
    let dataURL: String
    let onRemove: () -> Void
    @State private var hovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let image = Self.decode(dataURL) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 48, height: 48)
                    .clipShape(.rect(cornerRadius: Theme.radiusSmall))
            } else {
                Image(systemName: "doc")
                    .frame(width: 48, height: 48)
                    .background(Theme.layer02, in: .rect(cornerRadius: Theme.radiusSmall))
            }
            if hovered {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white, Theme.danger)
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
            }
        }
        .onHover { hovered = $0 }
    }

    static func decode(_ dataURL: String) -> NSImage? {
        guard let comma = dataURL.firstIndex(of: ","),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else { return nil }
        return NSImage(data: data)
    }
}

extension Data {
    /// Sniff common image formats by magic bytes.
    var imageMIME: String? {
        guard count >= 4 else { return nil }
        let bytes = [UInt8](prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        if bytes.count >= 12, bytes[8...11] == [0x57, 0x45, 0x42, 0x50] { return "image/webp" }
        return nil
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

/// Hover-highlight row for the agent picker popover.
struct AgentPickerRowStyle: ButtonStyle {
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusSmall)
                    .fill(hovered || configuration.isPressed ? Theme.overlayHover : .clear)
            )
            .onHover { hovered = $0 }
    }
}
