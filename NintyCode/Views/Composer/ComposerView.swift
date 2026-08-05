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
    // Attachments live on the ChatStore: the chat card is the drop target,
    // staging is per-session.
    // @State attachments REMOVED — use store.attachments.
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
        .onChange(of: store.mentionToInsert) {
            // Card-wide drop of a non-image file lands here as an @mention.
            if let mention = store.mentionToInsert {
                text += "@\(mention) "
                store.mentionToInsert = nil
            }
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
            if !store.attachments.isEmpty {
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
                        // Mention popup open → Return completes the selection, not send.
                        if mentionPopupOpen {
                            insertSelectedMention()
                            return .handled
                        }
                        send()
                        return .handled
                    }
                    .onKeyPress(.tab, phases: .down) { _ in
                        guard mentionPopupOpen else { return .ignored }
                        insertSelectedMention()
                        return .handled
                    }
                    .onKeyPress(.upArrow, phases: .down) { _ in
                        if mentionPopupOpen {
                            moveMentionSelection(-1)
                            return .handled
                        }
                        return historyBack() ? .handled : .ignored
                    }
                    .onKeyPress(.downArrow, phases: .down) { _ in
                        if mentionPopupOpen {
                            moveMentionSelection(1)
                            return .handled
                        }
                        return historyForward() ? .handled : .ignored
                    }
                    .onKeyPress(.escape, phases: .down) { _ in
                        // Popup open → Esc only closes the popup (no abort).
                        if mentionPopupOpen {
                            mentionQuery = nil
                            mentionResults = []
                            return .handled
                        }
                        return escapeTapped() ? .handled : .ignored
                    }
                    .onKeyPress(characters: .init(charactersIn: "v"), phases: .down) { press in
                        // Manual ⌘V fallback: the TextEditor can swallow the
                        // paste command before onPasteCommand sees it. Only
                        // image/file clipboard content is handled here —
                        // text paste falls through to the editor untouched.
                        guard press.modifiers.contains(.command) else { return .ignored }
                        return pasteFromClipboard() ? .handled : .ignored
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
        // No local dropDestination: the chat card above is the drop zone.
    }

    // MARK: - Attachments

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.attachments) { attachment in
                    AttachmentChip(attachment: attachment) {
                        store.attachments.removeAll { $0.id == attachment.id }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
        }
    }

    private static let pasteStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH-mm-ss"
        return formatter
    }()

    /// Manual ⌘V ingestion (see the onKeyPress fallback). Returns false for
    /// plain-text clipboards so the editor's own paste proceeds.
    private func pasteFromClipboard() -> Bool {
        let pasteboard = NSPasteboard.general
        // Finder-copied file (⌘C): real URL → attachFile keeps the filename.
        if let string = pasteboard.string(forType: .fileURL),
           let url = URL(string: string), url.isFileURL {
            attachFile(url)
            return true
        }
        // Raw image data (screenshot in clipboard, browser copy) → PNG data URL.
        if let image = NSImage(pasteboard: pasteboard),
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            let name = "Pasted Image \(Self.pasteStamp.string(from: Date())).png"
            store.attachments.append(ComposerAttachment(
                name: name,
                dataURL: "data:image/png;base64,\(png.base64EncodedString())"
            ))
            return true
        }
        return false
    }

    private func handlePaste(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data, let mime = data.imageMIME else { return }
                    let ext = mime == "image/jpeg" ? "jpg" : String(mime.dropFirst("image/".count))
                    let name = "Pasted Image \(Self.pasteStamp.string(from: Date())).\(ext)"
                    Task { @MainActor in
                        store.attachments.append(ComposerAttachment(
                            name: name,
                            dataURL: "data:\(mime);base64,\(data.base64EncodedString())"
                        ))
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

    /// Images attach as data URLs; other files become @mentions (opencode file: drop behavior).
    private func attachFile(_ url: URL) {
        if let data = try? Data(contentsOf: url), let mime = data.imageMIME {
            store.attachments.append(ComposerAttachment(
                name: url.lastPathComponent,
                dataURL: "data:\(mime);base64,\(data.base64EncodedString())"
            ))
        } else if let workspace = appState.workspace {
            // Multi-root: folder-prefixed relative path (ToolContext resolves it back).
            let relative = ToolContext(projectRoots: workspace.folders, sessionID: "composer")
                .mentionPath(for: url)
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
        appState.modelLabel(appState.selectedModel)
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
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && store.attachments.isEmpty)
            .opacity(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && store.attachments.isEmpty ? 0.5 : 1)
            .keyboardShortcut(.return, modifiers: .command)
            .help(shellMode ? "Run command" : "Send (⌘↵)")
        }
    }

    // MARK: - @ mentions (cached project files)

    /// Keyboard selection index into mentionResults (opencode ↑↓+Enter nav).
    @State private var mentionSelection = 0

    /// Popup visible — arrow/return/tab/escape keys route to it, not the editor.
    private var mentionPopupOpen: Bool {
        mentionQuery != nil && !mentionResults.isEmpty
    }

    private func updateMentions() {
        guard let lastToken = text.components(separatedBy: .whitespacesAndNewlines).last,
              lastToken.hasPrefix("@") else {
            mentionQuery = nil
            mentionResults = []
            return
        }
        let query = String(lastToken.dropFirst())
        mentionQuery = query
        mentionResults = Self.fuzzyMentions(query, in: appState.projectFiles)
        mentionSelection = 0
    }

    /// ↑/↓ with wrap-around while the mention popup is open.
    private func moveMentionSelection(_ delta: Int) {
        guard !mentionResults.isEmpty else { return }
        let count = mentionResults.count
        mentionSelection = (mentionSelection + delta + count) % count
    }

    private func insertSelectedMention() {
        guard mentionResults.indices.contains(mentionSelection) else { return }
        insertMention(mentionResults[mentionSelection])
    }

    /// opencode-style fuzzy file matching: subsequence with bonuses for
    /// segment starts and consecutive runs; directories (trailing "/")
    /// included. Bare "@" → first corpus entries.
    static func fuzzyMentions(_ query: String, in corpus: [String], limit: Int = 10) -> [String] {
        guard !query.isEmpty else { return Array(corpus.prefix(limit)) }
        let lowered = query.lowercased()
        var scored: [(path: String, score: Int)] = []
        scored.reserveCapacity(64)
        for entry in corpus {
            let path = entry.hasSuffix("/") ? String(entry.dropLast()) : entry
            guard let score = fuzzyScore(query: lowered, path: path.lowercased()) else { continue }
            scored.append((entry, score))
        }
        return scored
            .sorted { $0.score == $1.score ? $0.path.count < $1.path.count : $0.score > $1.score }
            .prefix(limit)
            .map(\.path)
    }

    /// Subsequence score: +1 per matched char, +10 at a path-segment start,
    /// +5 for consecutive matches. nil = query is not a subsequence.
    static func fuzzyScore(query: String, path: String) -> Int? {
        var score = 0
        var queryIndex = query.startIndex
        var previousMatched = false
        var position = 0
        for char in path {
            defer { position += 1 }
            guard queryIndex < query.endIndex, char == query[queryIndex] else {
                previousMatched = false
                continue
            }
            let segmentStart = position == 0
                || path[path.index(path.startIndex, offsetBy: position - 1)] == "/"
            score += 1
            if segmentStart { score += 10 }
            if previousMatched { score += 5 }
            queryIndex = query.index(after: queryIndex)
            previousMatched = true
        }
        return queryIndex == query.endIndex ? score : nil
    }

    private var mentionPopup: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(mentionResults.enumerated()), id: \.element) { index, path in
                let selected = index == mentionSelection
                Button {
                    insertMention(path)
                } label: {
                    HStack(spacing: 8) {
                        FileTypeIcon(path: path)
                        Text(path)
                            .font(Theme.small)
                            .foregroundStyle(selected ? Theme.textBase : Theme.textMuted)
                            .lineLimit(1)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // opencode: the keyboard-selected row stays highlighted;
                // hovering moves the selection to the mouse.
                .background(
                    selected ? Theme.overlayPressed : .clear,
                    in: .rect(cornerRadius: Theme.radiusSmall)
                )
                .onHover { if $0 { mentionSelection = index } }
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
        let images = store.attachments.map(\.dataURL)
        text = ""
        store.attachments = []
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

/// Named image attachment staged in the composer (data URL + display name
/// for the chip). Name source: file name for panel/drop, synthesized for paste.
struct ComposerAttachment: Identifiable {
    let id = UUID()
    let name: String
    let dataURL: String
}

/// Attachment chip: thumbnail + filename + always-visible remove button,
/// shown above the editor inside the message box.
struct AttachmentChip: View {
    @Environment(AppState.self) private var appState
    let attachment: ComposerAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if let image = AttachmentImage.decode(attachment.dataURL) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 24, height: 24)
                    .clipShape(.rect(cornerRadius: 4))
            } else {
                Image(systemName: "doc")
                    .font(.system(size: 10))
                    .frame(width: 24, height: 24)
                    .background(Theme.layer02, in: .rect(cornerRadius: 4))
            }
            Text(attachment.name)
                .font(Theme.small)
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180)
                .onTapGesture { appState.previewAttachment = attachment.dataURL }
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textFaint)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove attachment")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Theme.layer01, in: .capsule)
    }
}

/// Shared data-URL → NSImage decoding (composer chips + chat timeline).
enum AttachmentImage {
    static func decode(_ dataURL: String) -> NSImage? {
        guard let comma = dataURL.firstIndex(of: ","),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else { return nil }
        return NSImage(data: data)
    }
}

/// File-type icon for the @-mention popup and side panel file rows.
/// SF Symbols only cover a handful of languages, so: known types get
/// symbols (swift logo, terminal, photo…), everything else gets a colored
/// extension badge (JS yellow, TS blue, PY green…) — covers every
/// language without bundling assets. Resolution: directory → special
/// basename (Dockerfile, Makefile…) → symbol ext → badge ext → doc.
struct FileTypeIcon: View {
    let path: String

    var body: some View {
        Group {
            if let (symbol, color) = resolvedSymbol {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(color)
            } else {
                let badge = resolvedBadge
                Text(badge.label)
                    .font(.system(size: badge.label.count > 3 ? 5.5 : 7, weight: .heavy, design: .monospaced))
                    .foregroundStyle(badge.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
        }
        .frame(width: 16)
    }

    private var ext: String { (path as NSString).pathExtension.lowercased() }
    private var base: String { (path as NSString).lastPathComponent.lowercased() }

    private var resolvedSymbol: (String, Color)? {
        if path.hasSuffix("/") { return ("folder.fill", .blue) }
        if let entry = Self.symbolBasenames[base] { return entry }
        if Self.badgeBasenames[base] != nil { return nil }
        return Self.symbols[ext]
    }

    private var resolvedBadge: (label: String, color: Color) {
        if let entry = Self.badgeBasenames[base] { return entry }
        if let color = Self.badgeColors[ext] { return (ext.uppercased(), color) }
        return ("", .gray) // unreachable in practice: resolvedSymbol covers it
    }

    /// Extensions rendered as SF Symbols.
    static let symbols: [String: (String, Color)] = [
        "swift": ("swift", .orange),
        "md": ("doc.richtext", .blue), "markdown": ("doc.richtext", .blue),
        "txt": ("doc.text", .gray), "log": ("doc.text", .gray), "rst": ("doc.text", .gray),
        "json": ("curlybraces", .yellow), "jsonc": ("curlybraces", .yellow), "json5": ("curlybraces", .yellow),
        "yml": ("doc.text", .red), "yaml": ("doc.text", .red),
        "xml": ("doc.text", .orange), "plist": ("doc.text", .gray), "toml": ("doc.text", .orange),
        "ini": ("gear", .gray), "cfg": ("gear", .gray), "conf": ("gear", .gray), "env": ("gear", .yellow),
        "csv": ("tablecells", .green), "tsv": ("tablecells", .green),
        "sql": ("cylinder", .blue), "db": ("cylinder", .blue), "sqlite": ("cylinder", .blue),
        "sh": ("terminal", .green), "bash": ("terminal", .green), "zsh": ("terminal", .green),
        "fish": ("terminal", .green), "ps1": ("terminal", .blue),
        "png": ("photo", .purple), "jpg": ("photo", .purple), "jpeg": ("photo", .purple),
        "gif": ("photo", .purple), "webp": ("photo", .purple), "heic": ("photo", .purple),
        "svg": ("photo", .purple), "ico": ("photo", .purple),
        "mp3": ("waveform", .pink), "wav": ("waveform", .pink), "m4a": ("waveform", .pink), "flac": ("waveform", .pink),
        "mp4": ("film", .indigo), "mov": ("film", .indigo), "mkv": ("film", .indigo), "webm": ("film", .indigo),
        "zip": ("doc.zipper", .gray), "tar": ("doc.zipper", .gray), "gz": ("doc.zipper", .gray),
        "xz": ("doc.zipper", .gray), "7z": ("doc.zipper", .gray), "rar": ("doc.zipper", .gray),
        "pdf": ("doc", .red),
        "ttf": ("textformat", .gray), "otf": ("textformat", .gray),
        "woff": ("textformat", .gray), "woff2": ("textformat", .gray),
        "lock": ("lock", .gray),
        "pem": ("key", .yellow), "key": ("key", .yellow), "cer": ("key", .yellow), "crt": ("key", .yellow),
        "html": ("globe", .orange), "htm": ("globe", .orange),
        "css": ("paintpalette", .blue), "scss": ("paintpalette", .pink),
        "sass": ("paintpalette", .pink), "less": ("paintpalette", .indigo),
        "ipynb": ("doc.text", .orange)
    ]

    /// Extensions rendered as colored text badges (label = uppercased ext).
    static let badgeColors: [String: Color] = [
        "js": .yellow, "jsx": .yellow, "mjs": .yellow, "cjs": .yellow,
        "ts": .blue, "tsx": .blue, "mts": .blue, "cts": .blue,
        "py": .green, "pyi": .green, "pyw": .green,
        "rb": .red, "erb": .red,
        "go": .cyan,
        "rs": .orange,
        "java": .red, "kt": .purple, "kts": .purple, "scala": .red, "groovy": .teal,
        "c": .indigo, "h": .indigo, "cpp": .indigo, "cc": .indigo, "cxx": .indigo, "hpp": .indigo,
        "m": .indigo, "mm": .indigo,
        "cs": .green, "fs": .teal,
        "php": .indigo,
        "lua": .blue, "r": .blue, "jl": .purple,
        "hs": .purple, "lhs": .purple, "ml": .orange, "mli": .orange,
        "ex": .purple, "exs": .purple, "erl": .red, "hrl": .red,
        "clj": .green, "cljs": .green, "edn": .green,
        "vue": .green, "svelte": .orange, "astro": .orange,
        "dart": .cyan, "zig": .orange, "nim": .yellow, "cr": .gray,
        "wasm": .purple,
        "proto": .teal, "graphql": .pink, "gql": .pink,
        "tf": .purple, "hcl": .purple,
        "vim": .green, "el": .purple,
        "pl": .cyan, "pm": .cyan,
        "lisp": .purple, "scm": .purple,
        "d": .red, "ada": .blue, "adb": .blue, "ads": .blue,
        "cob": .gray, "cobol": .gray,
        "f": .purple, "f90": .purple, "f95": .purple, "f03": .purple, "f08": .purple,
        "v": .blue, "sv": .teal, "vhd": .teal, "vhdl": .teal,
        "sol": .gray, "move": .purple,
        "asm": .gray, "s": .gray,
        "pas": .gray, "pp": .gray,
        "tcl": .orange,
        "cmake": .teal,
        "gradle": .teal,
        "diff": .pink, "patch": .pink
    ]

    /// Special basenames rendered as SF Symbols (no useful extension).
    static let symbolBasenames: [String: (String, Color)] = [
        "dockerfile": ("shippingbox", .blue),
        "makefile": ("hammer", .gray),
        "license": ("doc.text", .gray),
        ".gitignore": ("eye.slash", .gray),
        ".gitattributes": ("eye.slash", .gray),
        ".dockerignore": ("eye.slash", .gray)
    ]

    /// Special basenames rendered as badges with explicit short labels.
    static let badgeBasenames: [String: (label: String, color: Color)] = [
        "podfile": ("RB", .red),
        "gemfile": ("RB", .red),
        "rakefile": ("RB", .red),
        "brewfile": ("RB", .red),
        "vagrantfile": ("VF", .purple),
        "justfile": ("JF", .gray)
    ]
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

/// Row hover highlight for menu-like lists (@-mention popup, dialogs).
private struct BackgroundHover: ViewModifier {
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusSmall)
                    .fill(hovered ? Theme.overlayHover : .clear)
            )
            .onHover { hovered = $0 }
            .animation(.easeInOut(duration: 0.1), value: hovered)
    }
}

extension View {
    /// Row hover highlight for menu-like lists.
    var backgroundHover: some View {
        modifier(BackgroundHover())
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
