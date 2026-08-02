import SwiftUI
import NintyCore

struct ChatView: View {
    let store: ChatStore
    @Environment(AppState.self) private var appState
    @State private var userScrolledUp = false

    var body: some View {
        VStack(spacing: 0) {
            messageList
            if !store.todos.isEmpty {
                TodoBar(todos: store.todos)
            }
            if let request = store.pendingPermission {
                PermissionPromptView(request: request) { reply in
                    store.replyPermission(reply)
                }
            }
            ComposerView(store: store)
            statusBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Error", isPresented: .constant(store.lastError != nil)) {
            Button("OK") { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(store.messages) { message in
                        MessageView(message: message)
                            .id(message.id)
                    }
                    if store.streaming {
                        StreamingIndicator()
                            .id("streaming-indicator")
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
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
        }
    }

    /// Opencode-style bottom status bar: path left, model + agent right.
    private var statusBar: some View {
        HStack(spacing: 8) {
            if let root = appState.projectRoot {
                Text(root.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if store.compacted {
                Text("compacted")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Text(shortModel)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(store.agent.id.uppercased())
                .font(.system(.caption2, design: .monospaced, weight: .bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 6)
        .background(.white.opacity(0.03))
    }

    private var shortModel: String {
        ProviderRegistry.split(store.model)?.model ?? store.model
    }
}

struct StreamingIndicator: View {
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(.secondary)
                    .frame(width: 5, height: 5)
                    .opacity(phase == index ? 1 : 0.3)
            }
        }
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
                phase = (phase + 1) % 3
            }
        }
    }
}

struct TodoBar: View {
    let todos: [TodoItem]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(todos.enumerated()), id: \.offset) { _, todo in
                    HStack(spacing: 4) {
                        Image(systemName: icon(for: todo.status))
                            .foregroundStyle(color(for: todo.status))
                        Text(todo.content)
                            .lineLimit(1)
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .glassEffect(.regular, in: .capsule)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
        }
    }

    private func icon(for status: String) -> String {
        switch status {
        case "completed": return "checkmark.circle.fill"
        case "in_progress": return "circle.lefthalf.filled"
        case "cancelled": return "xmark.circle"
        default: return "circle"
        }
    }

    private func color(for status: String) -> Color {
        switch status {
        case "completed": return .green
        case "in_progress": return .blue
        case "cancelled": return .red
        default: return .secondary
        }
    }
}
