import SwiftUI

@main
struct NintyCodeApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .frame(minWidth: 900, minHeight: 600)
                .background(Theme.bgDeep)
                .preferredColorScheme(.dark)
                .onAppear { appState.bootstrap() }
        }
        // opencode desktop parity: hidden native titlebar, custom TitlebarView
        // at true window top with traffic lights overlapping (Electron hiddenInset).
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 750)
        .commands {
            // Keep the app-menu Settings item (⌘,) — opens the in-app dialog,
            // not the native Settings window.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { appState.showSettings = true }
                    .keyboardShortcut(",")
            }
        }
    }
}

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        // opencode v2 shell: no left sidebar — titlebar + card on bg-deep,
        // optional review side panel on the right (⇧⌘R).
        VStack(spacing: 0) {
            TitlebarView()
            HStack(spacing: 8) {
                ZStack {
                    if appState.showHome {
                        HomeView()
                    } else if let chat = appState.activeChat {
                        ChatView(store: chat)
                    } else {
                        NewSessionView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.bgBase, in: .rect(cornerRadius: 10))
                .raisedElevation(cornerRadius: 10)

                if appState.showSidePanel {
                    SidePanelResizeHandle(width: Binding(
                        get: { appState.sidePanelWidth },
                        set: { appState.sidePanelWidth = $0 }
                    ))
                    SidePanelView(chat: appState.activeChat)
                        .frame(width: appState.sidePanelWidth)
                        .frame(maxHeight: .infinity)
                        .background(Theme.bgBase, in: .rect(cornerRadius: 10))
                        .raisedElevation(cornerRadius: 10)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.init(top: 0, leading: 8, bottom: 8, trailing: 8))
        }
        .background(Theme.bgDeep)
        .ignoresSafeArea(.all, edges: .top)
        .animation(.easeInOut(duration: 0.15), value: appState.showSidePanel)
        .modalOverlay(isPresented: Binding(
            get: { appState.showModelDialog },
            set: { appState.showModelDialog = $0 }
        )) {
            ModelDialog().environment(appState)
        }
        .modalOverlay(isPresented: Binding(
            get: { appState.showCommandPalette },
            set: { appState.showCommandPalette = $0 }
        )) {
            CommandPalette().environment(appState)
        }
        .modalOverlay(isPresented: Binding(
            get: { appState.showSettings },
            set: { appState.showSettings = $0 }
        )) {
            SettingsDialog().environment(appState)
        }
        .background(GlobalKeybinds())
    }
}

/// Drag handle on the side panel's leading edge — drag to resize.
private struct SidePanelResizeHandle: View {
    @Binding var width: CGFloat
    @State private var dragStart: CGFloat?

    var body: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: 8)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStart ?? width
                        dragStart = start
                        // Handle sits on the panel's left edge: dragging left widens.
                        width = (start - value.translation.width)
                            .clamped(to: AppState.sidePanelWidthRange)
                    }
                    .onEnded { _ in dragStart = nil }
            )
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// App-wide keybinds (opencode desktop map).
struct GlobalKeybinds: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ZStack {
            Button("") { appState.cycleAgent() }
                .keyboardShortcut(".", modifiers: .command)
            Button("") { appState.cycleAgent(reverse: true) }
                .keyboardShortcut(".", modifiers: [.command, .shift])
            Button("") { appState.showModelDialog = true }
                .keyboardShortcut("'", modifiers: .command)
            Button("") { appState.showCommandPalette = true }
                .keyboardShortcut("k", modifiers: .command)
            Button("") { appState.showCommandPalette = true }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("") { appState.showSettings = true }
                .keyboardShortcut(",", modifiers: .command)
            Button("") { appState.newChat() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("") {
                if let active = appState.activeChat { appState.closeTab(active) }
            }
            .keyboardShortcut("w", modifiers: .command)
            ForEach(Array(appState.openTabs.prefix(9).enumerated()), id: \.offset) { index, chat in
                Button("") { appState.activateTab(chat) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
        .frame(width: 0, height: 0)
        .hidden()
    }
}

/// opencode "New session" empty view: centered mark + title + project info.
struct NewSessionView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 32))
                .foregroundStyle(Theme.textFaint)
            Text("New session")
                .font(Theme.title)
                .foregroundStyle(Theme.textBase)
            if let root = appState.projectRoot {
                VStack(spacing: 4) {
                    Text(root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(Theme.captionMedium)
                        .foregroundStyle(Theme.textFaint)
                    Button("Start chatting") { appState.newChat() }
                        .buttonStyle(DockButtonStyle(variant: .primary))
                        .padding(.top, 8)
                }
            } else {
                Button("Open project…") { appState.pickProject() }
                    .buttonStyle(DockButtonStyle(variant: .primary))
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgDeep)
    }
}
