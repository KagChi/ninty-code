import SwiftUI

@main
struct NintyCodeApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .frame(minWidth: 900, minHeight: 600)
                .background(Theme.bgBase)
                .preferredColorScheme(.dark)
                .onAppear { appState.bootstrap() }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1100, height: 750)

        Settings {
            SettingsView()
                .environment(appState)
                .preferredColorScheme(.dark)
        }
    }
}

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            if let chat = appState.activeChat {
                ChatView(store: chat)
            } else {
                NewSessionView()
            }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .sheet(isPresented: Binding(
            get: { appState.showModelDialog },
            set: { appState.showModelDialog = $0 }
        )) {
            ModelDialog().environment(appState)
        }
        .sheet(isPresented: Binding(
            get: { appState.showCommandPalette },
            set: { appState.showCommandPalette = $0 }
        )) {
            CommandPalette().environment(appState)
        }
        .background(GlobalKeybinds())
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
            Button("") { appState.newChat() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
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
        .background(Theme.bgBase)
    }
}
