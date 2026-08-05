import SwiftUI
import NintyCore

/// opencode v2 session view: centered timeline (max 800px), docks above composer, jump-to-latest.
struct ChatView: View {
    let store: ChatStore
    @Environment(AppState.self) private var appState
    @State private var userScrolledUp = false

    var body: some View {
        VStack(spacing: 0) {
            SessionHeader(store: store)
            ZStack(alignment: .bottom) {
                messageTimeline
                VStack(spacing: 6) {
                if let request = store.pendingPermission {
                    PermissionDock(request: request) { reply in
                        store.replyPermission(reply)
                    }
                }
                if !store.followups.isEmpty {
                    FollowupDock(store: store)
                }
                if !store.revertedMessages.isEmpty {
                    RevertDock(store: store)
                }
                if !store.todos.isEmpty {
                    TodoDock(todos: store.todos)
                }
                    // opencode: composer hidden while a permission blocks the session.
                    if store.pendingPermission == nil {
                        ComposerView(store: store)
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            // ⇧⌘A auto-accept toggle (opencode per-session).
            Button("") { store.autoAccept.toggle() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .hidden()
        )
        // Card-wide drop target (opencode "Drop files to attach"): images
        // stage as attachments, other files become @mentions.
        .overlay {
            if store.dropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .foregroundStyle(Theme.textAccent)
                    .background(Theme.textAccent.opacity(0.08), in: .rect(cornerRadius: 10))
                    .overlay {
                        Text("Drop files to attach")
                            .font(Theme.smallMedium)
                            .foregroundStyle(Theme.textAccent)
                    }
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        // Drop handling is AppKit-level (WindowDropCapture behind the
        // window's contentView) — SwiftUI onDrop never fired here.
        .alert("Error", isPresented: .constant(store.lastError != nil)) {
            Button("OK") { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
        .sheet(isPresented: Binding(
            get: { store.showForkDialog },
            set: { store.showForkDialog = $0 }
        )) {
            ForkDialog(store: store)
                .environment(appState)
        }
    }

    private var messageTimeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(store.messages) { message in
                        MessageView(message: message, agentID: store.agent.id, model: store.model)
                            .id(message.id)
                    }
                    if store.streaming, store.messages.last?.role != .assistant || store.messages.last?.text.isEmpty == true && store.messages.last?.toolCalls.isEmpty == true {
                        if let retry = store.retry {
                            RetryRow(attempt: retry.attempt, delay: retry.delay)
                        } else {
                            ThinkingRow()
                        }
                    }
                    if !store.streaming, !store.changedFiles.isEmpty {
                        ChangedFilesSection(files: store.changedFiles)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 180) // room for composer + docks
                .frame(maxWidth: 800)
                .frame(maxWidth: .infinity)
                Color.clear
                    .frame(height: 1)
                    .id("bottom")
                    .onAppear { userScrolledUp = false }
                    .onDisappear { userScrolledUp = true }
            }
            .onChange(of: store.messages.last?.text.count ?? 0) {
                guard !userScrolledUp else { return }
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: store.messages.count) {
                userScrolledUp = false
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: store.changedFiles.count) { _, count in
                // Turn-end summary lands after the last message — keep it visible.
                guard count > 0 else { return }
                userScrolledUp = false
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .overlay(alignment: .bottom) {
                if userScrolledUp {
                    Button {
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                        userScrolledUp = false
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textBase)
                            .frame(width: 32, height: 28)
                            .glassEffect(.regular, in: .rect(cornerRadius: Theme.radiusMedium))
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 190)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: userScrolledUp)
        }
    }
}

/// opencode v2 todo dock: "done/total" counter + current task + chevron, expandable.
struct TodoDock: View {
    let todos: [TodoItem]
    @State private var expanded = false

    private var doneCount: Int {
        todos.filter { $0.status == "completed" }.count
    }

    private var currentTask: String {
        todos.first { $0.status == "in_progress" }?.content ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text("\(doneCount)/\(todos.count)")
                        .font(Theme.smallMedium)
                        .foregroundStyle(Theme.textBase)
                    Text(currentTask)
                        .font(Theme.small)
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textFaint)
                        .rotationEffect(.degrees(expanded ? 0 : 180))
                }
                .padding(.horizontal, 16)
                .frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(todos.enumerated()), id: \.offset) { _, todo in
                        HStack(spacing: 8) {
                            statusIcon(todo.status)
                            Text(todo.content)
                                .font(Theme.small)
                                .foregroundStyle(todo.status == "completed" ? Theme.textFaint : Theme.textBase)
                                .strikethrough(todo.status == "completed")
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .glassEffect(.regular.tint(Theme.bgBase.opacity(0.5)), in: .rect(cornerRadius: Theme.radiusXL))
        .padding(.horizontal, 12)
        .frame(maxWidth: 800)
    }

    @ViewBuilder
    private func statusIcon(_ status: String) -> some View {
        switch status {
        case "completed":
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.success)
        case "in_progress":
            PulsingDot(color: Theme.textAccent)
        case "cancelled":
            Image(systemName: "xmark.circle")
                .foregroundStyle(Theme.danger)
        default:
            Image(systemName: "circle")
                .foregroundStyle(Theme.textFaint)
        }
    }
}

/// opencode follow-up dock: "N queued messages", per-item Send now / Edit.
struct FollowupDock: View {
    let store: ChatStore
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "tray.full")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textFaint)
                    Text("\(store.followups.count) queued message\(store.followups.count == 1 ? "" : "s")")
                        .font(Theme.smallMedium)
                        .foregroundStyle(Theme.textBase)
                    Spacer()
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textFaint)
                        .rotationEffect(.degrees(expanded ? 0 : 180))
                }
                .padding(.horizontal, 16)
                .frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(store.followups.enumerated()), id: \.offset) { index, text in
                        HStack(spacing: 8) {
                            Text(text)
                                .font(Theme.small)
                                .foregroundStyle(Theme.textMuted)
                                .lineLimit(2)
                            Spacer()
                            Button("Send now") { store.sendFollowupNow(at: index) }
                                .buttonStyle(DockButtonStyle(variant: .secondary))
                                .controlSize(.small)
                            Button("Edit") { store.editFollowup(at: index) }
                                .buttonStyle(DockButtonStyle(variant: .ghost))
                                .controlSize(.small)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .glassEffect(.regular.tint(Theme.bgBase.opacity(0.5)), in: .rect(cornerRadius: Theme.radiusXL))
        .padding(.horizontal, 12)
        .frame(maxWidth: 800)
    }
}

/// opencode revert dock: reverted messages with per-message Restore + Redo all.
struct RevertDock: View {
    let store: ChatStore
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.warning)
                    Text("\(store.revertedMessages.count) reverted message\(store.revertedMessages.count == 1 ? "" : "s")")
                        .font(Theme.smallMedium)
                        .foregroundStyle(Theme.textBase)
                    Spacer()
                    Button("Redo all") {
                        while !store.revertedMessages.isEmpty { store.redo() }
                    }
                    .buttonStyle(DockButtonStyle(variant: .secondary))
                    .controlSize(.small)
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textFaint)
                        .rotationEffect(.degrees(expanded ? 0 : 180))
                }
                .padding(.horizontal, 16)
                .frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(store.revertedMessages.enumerated()), id: \.offset) { index, message in
                        HStack(spacing: 8) {
                            Image(systemName: message.role == .user ? "person" : "sparkle")
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.textFaint)
                            Text(message.text.isEmpty ? "(tool calls)" : message.text)
                                .font(Theme.small)
                                .foregroundStyle(Theme.textMuted)
                                .lineLimit(1)
                            Spacer()
                            Button("Restore") { store.restoreReverted(upTo: index) }
                                .buttonStyle(DockButtonStyle(variant: .ghost))
                                .controlSize(.small)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .glassEffect(.regular.tint(Theme.bgBase.opacity(0.5)), in: .rect(cornerRadius: Theme.radiusXL))
        .padding(.horizontal, 12)
        .frame(maxWidth: 800)
    }
}

/// opencode /fork: user messages (newest first, 200-char preview) → fork → navigate.
struct ForkDialog: View {
    let store: ChatStore
    @Environment(AppState.self) private var appState

    private var userMessages: [(index: Int, text: String)] {
        store.messages.enumerated().compactMap { index, message in
            message.role == .user && !message.isMarker ? (index, message.text) : nil
        }.reversed()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Fork from message")
                .font(Theme.sansMedium)
                .foregroundStyle(Theme.textBase)
                .padding(16)
            Divider().overlay(Theme.borderMuted)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(userMessages, id: \.index) { item in
                        Button {
                            fork(from: item.index)
                        } label: {
                            Text(String(item.text.prefix(200)))
                                .font(Theme.small)
                                .foregroundStyle(Theme.textBase)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .backgroundHover
                    }
                }
                .padding(8)
            }
            HStack {
                Spacer()
                Button("Cancel") { store.showForkDialog = false }
                    .buttonStyle(DockButtonStyle(variant: .ghost))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 480, height: 400)
        .background(Theme.bgBase)
    }

    private func fork(from index: Int) {
        store.showForkDialog = false
        Task {
            guard let (newID, prompt) = await store.fork(beforeUserMessageAt: index) else { return }
            appState.openChat(newID)
            appState.activeChat?.restoredDraft = prompt
        }
    }
}

/// opencode SessionRetry indicator.
struct RetryRow: View {
    let attempt: Int
    let delay: Int

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Retrying (attempt \(attempt + 1), next in \(delay)s)…")
                .font(Theme.small)
                .foregroundStyle(Theme.warning)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// opencode turn-end summary: "N Changed files +A −D" header + bordered card
/// with per-file rows that expand to an inline line diff.
struct ChangedFilesSection: View {
    let files: [ChangedFile]

    private var totalAdds: Int { files.reduce(0) { $0 + $1.additions } }
    private var totalDels: Int { files.reduce(0) { $0 + $1.deletions } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("\(files.count) Changed file\(files.count == 1 ? "" : "s")")
                    .font(Theme.sansMedium)
                    .foregroundStyle(Theme.textBase)
                DiffChangesText(adds: totalAdds, deletes: totalDels)
            }
            VStack(spacing: 0) {
                ForEach(Array(files.enumerated()), id: \.element.path) { index, file in
                    if index > 0 {
                        Divider().overlay(Theme.borderMuted)
                    }
                    ChangedFileRow(file: file)
                }
            }
            .background(Theme.layer02, in: .rect(cornerRadius: Theme.radiusMedium))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusMedium).stroke(Theme.borderBase, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMedium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One file row in the changed-files card; expands to the inline diff.
private struct ChangedFileRow: View {
    let file: ChangedFile
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text(file.path)
                        .font(Theme.smallMedium)
                        .foregroundStyle(Theme.textBase)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    DiffChangesText(adds: file.additions, deletes: file.deletions)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textFaint)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Divider().overlay(Theme.borderMuted)
                InlineDiffView(lines: file.lines)
            }
        }
    }
}



/// opencode usage hover card: Cost / Usage / Tokens rows.
private struct UsageCard: View {
    let store: ChatStore

    private var usageFraction: Double {
        guard store.contextWindow > 0 else { return 0 }
        return min(1, Double(store.lastInputTokens) / Double(store.contextWindow))
    }

    var body: some View {
        VStack(spacing: 6) {
            row("Cost", "$0.00")
            row("Usage", "\(Int(usageFraction * 100))%")
            row("Tokens", (store.lastUsage?.total ?? store.lastInputTokens).formatted())
        }
        .padding(12)
        .frame(width: 190)
        .background(Theme.bgBase)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(Theme.caption)
                .foregroundStyle(Theme.textMuted)
            Spacer()
            Text(value)
                .font(Theme.captionMedium)
                .foregroundStyle(Theme.textBase)
        }
    }
}

/// opencode v2 session header: editable title + context usage + overflow menu.
struct SessionHeader: View {
    let store: ChatStore
    @Environment(AppState.self) private var appState
    @State private var editing = false
    @State private var draftTitle = ""

    private var title: String {
        let stored = appState.sessions.first { $0.id == store.sessionID }?.title
        return stored?.isEmpty == false ? stored! : "New session"
    }

    private var contextFraction: Double {
        guard store.contextWindow > 0 else { return 0 }
        return min(1, Double(store.lastInputTokens) / Double(store.contextWindow))
    }

    var body: some View {
        HStack(spacing: 10) {
            if editing {
                TextField("Session title", text: $draftTitle, onCommit: commitRename)
                    .textFieldStyle(.plain)
                    .font(Theme.sansMedium)
                    .foregroundStyle(Theme.textBase)
                    .onExitCommand { editing = false }
            } else {
                Text(title)
                    .font(Theme.sansMedium)
                    .foregroundStyle(Theme.textBase)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(titleHovered ? Theme.overlayHover : .clear, in: .rect(cornerRadius: Theme.radiusSmall))
                    .onHover { titleHovered = $0 }
                    .onTapGesture(count: 2) { startRename() }
            }

            Spacer()

            // Context usage meter (opencode SessionContextUsage) — always
            // visible; defaults to 0% before any usage data exists.
            HStack(spacing: 5) {
                    Circle()
                        .trim(from: 0, to: contextFraction)
                        .stroke(contextColor, lineWidth: 2)
                        .rotationEffect(.degrees(-90))
                        .frame(width: 10, height: 10)
                        .background(Circle().stroke(Theme.borderMuted, lineWidth: 2))
                    Text("\(Int(contextFraction * 100))%")
                        .font(Theme.tiny)
                        .foregroundStyle(Theme.textFaint)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(usageHovered ? Theme.overlayHover : .clear, in: .rect(cornerRadius: Theme.radiusSmall))
                .contentShape(Rectangle())
                .onHover { hovering in
                    usageHovered = hovering
                    usagePopover = hovering
                }
                .popover(isPresented: $usagePopover, arrowEdge: .bottom) {
                    UsageCard(store: store)
                }
                .help("\(store.lastInputTokens.formatted()) / \(store.contextWindow.formatted()) tokens")

            Menu {
                Button("Rename…") { startRename() }
                Button("Fork…") { store.showForkDialog = true }
                Button("Compact") { store.compact() }
                Divider()
                Button("Close tab") {
                    if let chat = appState.activeChat { appState.closeTab(chat) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textFaint)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            // Right side panel toggle (⇧⌘R) — lives in the chat card header
            // now that the detail toolbar is empty.
            Button {
                appState.showSidePanel.toggle()
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textFaint)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .help("Toggle side panel (⇧⌘R)")
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(
            // Gradient fade into timeline (opencode sticky header).
            LinearGradient(
                colors: [Theme.bgBase, Theme.bgBase.opacity(0)],
                startPoint: .top, endPoint: .bottom
            )
        )
    }

    @State private var titleHovered = false
    @State private var usageHovered = false
    @State private var usagePopover = false

    private func startRename() {
        draftTitle = title
        editing = true
    }

    private func commitRename() {
        editing = false
        let trimmed = draftTitle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != title else { return }
        store.rename(trimmed)
        appState.reloadSessions()
    }

    private var contextColor: Color {
        if contextFraction > 0.9 { return Theme.danger }
        if contextFraction > 0.7 { return Theme.warning }
        return Theme.textAccent
    }
}

struct PulsingDot: View {
    let color: Color
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .scaleEffect(pulsing ? 1.4 : 1)
            .opacity(pulsing ? 0.5 : 1)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}
