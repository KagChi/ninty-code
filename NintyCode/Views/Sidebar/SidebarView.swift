import SwiftUI
import AppKit
import NintyCore

/// Opencode-style sidebar: wordmark + project, sessions list, model footer.
struct SidebarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.3)
            sessionsList
            Divider().opacity(0.3)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { appState.pickProjectHandler = pickProject }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ninty-code")
                .font(.system(.callout, design: .monospaced, weight: .bold))
                .foregroundStyle(.secondary)
            if let root = appState.projectRoot {
                Button {
                    pickProject()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.secondary)
                        Text(root.lastPathComponent)
                            .fontWeight(.medium)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .help(root.path)
            } else {
                Button {
                    pickProject()
                } label: {
                    Label("Open Project…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
    }

    private var sessionsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Sessions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Button {
                    appState.newChat()
                } label: {
                    Image(systemName: "plus")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(appState.projectRoot == nil)
                .help("New session")
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(appState.sessions) { session in
                        SessionRow(
                            session: session,
                            isActive: appState.activeChat?.sessionID == session.id
                        )
                        .onTapGesture { appState.openChat(session.id) }
                        .contextMenu {
                            Button("Open") { appState.openChat(session.id) }
                            Divider()
                            Button("Delete", role: .destructive) { appState.deleteSession(session.id) }
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "cpu")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(modelName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Text(appState.selectedAgentID.uppercased())
                .font(.system(.caption2, design: .monospaced, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var modelName: String {
        guard let (_, model) = ProviderRegistry.split(appState.selectedModel) else {
            return appState.selectedModel.isEmpty ? "no model" : appState.selectedModel
        }
        return model
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
    var isActive: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.title)
                .lineLimit(1)
                .font(.callout)
            HStack(spacing: 6) {
                Text(session.agentID.uppercased())
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .foregroundStyle(.secondary)
                Text(session.updated, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isActive ? .white.opacity(0.1) : .clear, in: .rect(cornerRadius: 6))
        .contentShape(Rectangle())
    }
}
