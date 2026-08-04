import AppKit
import SwiftUI
import NintyCore

/// Tab strip: scrollable tabs + new-tab button. Lives in the detail column's
/// native toolbar as the principal item — the system owns sizing, so no
/// fixed height here.
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
        .frame(maxWidth: .infinity)
    }
}

/// Side-panel action. Trailing `ToolbarItemGroup` in the detail toolbar —
/// the system renders it as a native toolbar item. (No custom sidebar
/// toggle: the system's built-in one lives in the sidebar column.)
struct DetailToolbarItems: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            SidePanelButton()
        }
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

/// Right side panel toggle (⇧⌘R) — toolbar trailing, rightmost. No custom
/// styling: AppKit renders toolbar buttons with the same chrome as the
/// system sidebar toggle on the leading side.
struct SidePanelButton: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Button {
            appState.showSidePanel.toggle()
        } label: {
            Image(systemName: "sidebar.right")
        }
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
                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.accent.opacity(chat.projectRoot == appState.projectRoot ? 1 : 0.45))
                    .frame(width: 18, height: 18)
                    .overlay {
                        Text(chat.projectRoot.lastPathComponent.prefix(1).uppercased())
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
