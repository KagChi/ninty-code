import AppKit
import SwiftUI
import NintyCore

/// Tab strip capsule: full-width glass pill at the top of the detail area.
/// Kept out of the window toolbar — NSToolbar principal items can't be
/// full-bleed and expelled the trailing buttons into a floating overlay.
struct TabStripView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 6) {
            if appState.openTabs.isEmpty {
                Text("No open tabs")
                    .font(Theme.small)
                    .foregroundStyle(Theme.textFaint)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
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
            }
            NewTabButton()
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 36)
        .glassEffect(.regular, in: .capsule)
    }
}

/// Right-end capsule next to the tab strip: sidebar toggle + update +
/// side panel. Lives outside the window toolbar so it can share the tab
/// strip's row and glass style.
struct DetailToolbarCapsule: View {
    @Environment(AppState.self) private var appState
    @Binding var columnVisibility: NavigationSplitViewVisibility

    var body: some View {
        HStack(spacing: 2) {
            Button {
                columnVisibility = columnVisibility == .all ? .detailOnly : .all
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13))
                    .foregroundStyle(columnVisibility == .all ? Theme.textBase : Theme.textMuted)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Toggle sidebar (⌃⌘S)")
            UpdateButton()
            SidePanelButton()
        }
        .padding(.horizontal, 6)
        .frame(height: 36)
        .glassEffect(.regular, in: .capsule)
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
            // Project initial badge — always shown (mixed-project strip);
            // dimmed for foreign projects, spinner overlays while streaming.
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Theme.accent.opacity(chat.projectRoot == appState.projectRoot ? 1 : 0.45))
                    .frame(width: 12, height: 12)
                    .overlay {
                        Text(chat.projectRoot.lastPathComponent.prefix(1).uppercased())
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.white)
                    }
                if chat.streaming {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                }
            }
            .help(chat.projectRoot.lastPathComponent)
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
