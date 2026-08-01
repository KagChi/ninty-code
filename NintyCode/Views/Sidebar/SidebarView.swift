import SwiftUI
import AppKit
import NintyCore

struct SidebarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            projectSection
            sessionsSection
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            appState.pickProjectHandler = pickProject
        }
    }

    private var projectSection: some View {
        GlassEffectContainer {
            VStack(alignment: .leading, spacing: 8) {
                if let root = appState.projectRoot {
                    Label(root.lastPathComponent, systemImage: "folder.fill")
                        .font(.headline)
                    Text(root.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button {
                    pickProject()
                } label: {
                    Label(appState.projectRoot == nil ? "Open Project…" : "Change Project…", systemImage: "folder.badge.plus")
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
        }
    }

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sessions")
                    .font(.headline)
                Spacer()
                Button {
                    appState.newChat()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(appState.projectRoot == nil)
            }
            List(selection: .constant(nil as String?)) {
                ForEach(appState.sessions) { session in
                    SessionRow(session: session)
                        .tag(session.id)
                        .onTapGesture { appState.openChat(session.id) }
                        .contextMenu {
                            Button("Open") { appState.openChat(session.id) }
                            Divider()
                            Button("Delete", role: .destructive) { appState.deleteSession(session.id) }
                        }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func pickProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Project"
        if panel.runModal() == .OK, let url = panel.url {
            appState.openProject(url)
        }
    }
}

struct SessionRow: View {
    let session: SessionMeta

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.title)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(session.agentID)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: .capsule)
                Text(session.updated, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
