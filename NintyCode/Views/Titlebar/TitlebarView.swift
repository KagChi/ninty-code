import AppKit
import SwiftUI
import NintyCore

/// opencode v2 titlebar: 36px, bg-deep, home toggle + tab strip + new-tab + review toggle.
struct TitlebarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 6) {
            // Inset for traffic lights (hidden titlebar style — they overlay content).
            Spacer().frame(width: 70)
            homeButton
            tabStrip
            newTabButton
            Spacer(minLength: 8)
            updateButton
            sidePanelButton
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(Theme.bgDeep)
        .background(WindowDragView())
    }

    /// Download/update icon (v2 titlebar trailing). Opens releases page.
    private var updateButton: some View {
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

    /// Right side panel toggle (⇧⌘R) — review/files panel.
    private var sidePanelButton: some View {
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

    /// Grid-plus home toggle (⌘B).
    private var homeButton: some View {
        Button {
            appState.showHome.toggle()
        } label: {
            Image(systemName: appState.showHome ? "square.grid.2x2.fill" : "square.grid.2x2")
                .font(.system(size: 13))
                .foregroundStyle(appState.showHome ? Theme.textBase : Theme.textMuted)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("b", modifiers: .command)
        .help("Home (⌘B)")
    }

    /// Scrollable tab strip with edge fades (v2 TitlebarTabStrip).
    private var tabStrip: some View {
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

    private var newTabButton: some View {
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
        appState.activeChat?.sessionID == chat.sessionID && !appState.showHome
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
        .onTapGesture { appState.activateTab(chat); appState.showHome = false }
        .onHover { hovered = $0 }
    }
}

/// Invisible view that makes its area draggable as window chrome.
struct WindowDragView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = DraggableNSView()
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

final class DraggableNSView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
    override var acceptsFirstResponder: Bool { false }
}
