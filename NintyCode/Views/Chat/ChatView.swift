import SwiftUI
import NintyCore

struct ChatView: View {
    let store: ChatStore
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
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(store.messages) { message in
                        MessageView(message: message)
                            .id(message.id)
                    }
                    if store.streaming {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Working…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .id("streaming-indicator")
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Track scroll position via bottom anchor visibility.
                Color.clear
                    .frame(height: 1)
                    .id("bottom")
                    .onAppear { userScrolledUp = false }
                    .onDisappear { userScrolledUp = true }
            }
            .onChange(of: store.messages.last?.text.count ?? 0) {
                guard !userScrolledUp else { return }
                withAnimation(.linear(duration: 0.05)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: store.messages.count) {
                userScrolledUp = false
                proxy.scrollTo("bottom", anchor: .bottom)
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
            .padding(.horizontal, 20)
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
