import AppKit
import SwiftUI
import NintyCore

/// Tab strip: tabs + new-tab button in a capsule glass bar, hosted as the
/// toolbar's `.principal` item. Width comes from the caller: the detail
/// column width measured via onGeometryChange (always real, never 0)
/// minus a clearance constant covering the toggle zone, separator and
/// window insets. Fixed fill — the capsule always matches the middle
/// band, so it can never eject to the overflow chevron. Tabs scroll
/// inside past the band width.
struct TabStripView: View {
    @Environment(AppState.self) private var appState
    var bandWidth: CGFloat = 600

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
                        tabRow
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
        .frame(height: 36)
        .frame(width: bandWidth)
        .glassEffect(.regular, in: .capsule)
    }

    private var tabRow: some View {
        HStack(spacing: 4) {
            ForEach(appState.openTabs, id: \.sessionID) { chat in
                TabItem(chat: chat)
                    .id(chat.sessionID)
            }
        }
        .padding(.horizontal, 2)
    }
}

/// New session button (⌘T).
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
            // Workspace initial badge — always shown (mixed-workspace strip);
            // dimmed for foreign workspaces, spinner overlays while streaming.
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.accent.opacity(chat.workspaceID == appState.workspace?.id ? 1 : 0.45))
                    .frame(width: 18, height: 18)
                    .overlay {
                        Text(chat.workspaceName.prefix(1).uppercased())
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(.white)
                    }
                if chat.streaming {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.5)
                        .frame(width: 18, height: 18)
                }
            }
            .help(chat.workspaceName)
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
        .padding(.horizontal, 10)
        .frame(height: 30)
        .frame(maxWidth: 220)
        // Toolbar items propose compact sizes — without this the ScrollView
        // compresses pills and titles truncate mid-word.
        .fixedSize()
        .background(isActive ? Theme.overlayPressed : (hovered ? Theme.overlayHover : .clear),
                    in: .rect(cornerRadius: Theme.radiusMedium))
        .contentShape(Rectangle())
        .onTapGesture { appState.activateTab(chat) }
        .onHover { hovered = $0 }
    }
}
