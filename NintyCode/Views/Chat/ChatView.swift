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
                if !store.todos.isEmpty {
                    TodoDock(todos: store.todos)
                }
                ComposerView(store: store)
            }
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgBase)
        .alert("Error", isPresented: .constant(store.lastError != nil)) {
            Button("OK") { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
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
