import SwiftUI

@main
struct NintyCodeApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear { appState.bootstrap() }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1100, height: 750)

        Settings {
            SettingsView()
                .environment(appState)
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
                WelcomeView()
            }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
    }
}

struct WelcomeView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            if appState.projectRoot == nil {
                Text("Open a project to start")
                    .font(.title2)
                Button("Open Project…") { appState.pickProject() }
                    .buttonStyle(.borderedProminent)
            } else {
                Text("Start a new session")
                    .font(.title2)
                Button("New Session") { appState.newChat() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
