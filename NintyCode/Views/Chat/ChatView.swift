import SwiftUI
import NintyCore

/// opencode v2 session view: centered timeline (max 800px), docks above composer, jump-to-latest.
struct ChatView: View {
    let store: ChatStore
    @Environment(AppState.self) private var appState
    @State private var userScrolledUp = false

    var body: some View {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgBase)
        .background(
            // ⇧⌘A auto-accept toggle (opencode per-session).
            Button("") { store.autoAccept.toggle() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .hidden()
        )
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
                        ThinkingRow()
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
        .glassEffect(.regular.tint(Theme.layer01.opacity(0.5)), in: .rect(cornerRadius: Theme.radiusXL))
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
        .glassEffect(.regular.tint(Theme.layer01.opacity(0.5)), in: .rect(cornerRadius: Theme.radiusXL))
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
        .glassEffect(.regular.tint(Theme.layer01.opacity(0.5)), in: .rect(cornerRadius: Theme.radiusXL))
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
