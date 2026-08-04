import AppKit
import SwiftUI
import NintyCore

/// Tab strip hosted in the window toolbar (principal placement). Scrollable
/// with auto-scroll to the active tab; capped width so it can't starve the
/// trailing toolbar buttons.
struct TabStripView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(appState.openTabs, id: \.sessionID) { chat in
                        TabItem(chat: chat)
                            .id(chat.sessionID)
                    }
                }
                .padding(.horizontal, 2)
            }
            .onChange(of: appState.activeChat?.sessionID) {
                if let id = appState.activeChat?.sessionID {
                    withAnimation { proxy.scrollTo(id) }
                }
            }
        }
        .frame(minWidth: 160, maxWidth: 520)
    }
}

/// New session button (⌘T) — toolbar primaryAction group.
struct NewTabButton: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Button {
            appState.newChat()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("t", modifiers: .command)
        .help("New session (⌘T)")
    }
}

/// Download/update icon (toolbar trailing). Opens releases page.
struct UpdateButton: View {
    var body: some View {
        Button {
            NSWorkspace.shared.open(URL(string: "https://github.com/KagChi/ninty-code/releases")!)
        } label: {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Download latest release")
    }
}

/// Right side panel toggle (⇧⌘R) — toolbar trailing, rightmost.
struct SidePanelButton: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Button {
            appState.showSidePanel.toggle()
        } label: {
            Image(systemName: "sidebar.right")
                .font(.system(size: 13))
                .foregroundStyle(appState.showSidePanel ? Theme.textBase : Theme.textMuted)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .help("Toggle side panel (⇧⌘R)")
    }
}

/// v2 TabNavItem: 16px avatar + title, hover/active-reveal close, unread dot.
struct TabItem: View {
    @Environment(AppState.self) private var appState
    let chat: ChatStore
    @State private var hovered = false

    private var isActive: Bool {
        appState.activeChat?.sessionID == chat.sessionID
    }

    private var title: String {
        appState.sessions.first { $0.id == chat.sessionID }?.title
            ?? chat.messages.first { $0.role == .user }?.text.prefix(40).description
            ?? "New session"
    }

    var body: some View {
        HStack(spacing: 6) {
            // Agent-colored avatar square (v2 SessionTabAvatar).
            RoundedRectangle(cornerRadius: 3)
                .fill(chat.streaming ? Theme.agentColor(chat.agent.id) : Theme.layer03)
                .frame(width: 12, height: 12)
                .overlay {
                    if chat.streaming {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                    }
                }
            Text(title)
                .font(Theme.smallMedium)
                .foregroundStyle(isActive ? Theme.textBase : Theme.textFaint)
                .lineLimit(1)
            if chat.hasUnread && !isActive {
                Circle()
                    .fill(Theme.textAccent)
                    .frame(width: 6, height: 6)
            }
            if hovered || isActive {
                Button {
                    appState.closeTab(chat)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.textFaint)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close (⌘W)")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .frame(maxWidth: 200)
        .background(isActive ? Theme.overlayPressed : (hovered ? Theme.overlayHover : .clear),
                    in: .rect(cornerRadius: Theme.radiusSmall))
        .contentShape(Rectangle())
        .onTapGesture { appState.activateTab(chat) }
        .onHover { hovered = $0 }
    }
}
