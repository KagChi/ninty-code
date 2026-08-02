import SwiftUI
import AppKit
import NintyCore

/// opencode v2 sidebar: project header, "+ New session" CTA, session rows with status dots.
struct SidebarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            newSessionButton
            sessionsList
            Spacer(minLength: 0)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bgBase)
        .onAppear { appState.pickProjectHandler = pickProject }
    }

    // MARK: - Header: project name + path

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let root = appState.projectRoot {
                Text(root.lastPathComponent)
                    .font(Theme.sansMedium)
                    .foregroundStyle(Theme.textBase)
                Text(root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("ninty-code")
                    .font(Theme.sansMedium)
                    .foregroundStyle(Theme.textBase)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .contentShape(Rectangle())
        .onTapGesture { pickProject() }
    }

    // MARK: - CTA

    private var newSessionButton: some View {
        Button {
            if appState.projectRoot == nil {
                pickProject()
            } else {
                appState.newChat()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                Text(appState.projectRoot == nil ? "Open project" : "New session")
                    .font(Theme.sansMedium)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Theme.accent, in: .rect(cornerRadius: Theme.radiusMedium))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Sessions

    private var sessionsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(appState.sessions) { session in
                    SessionRow(
                        session: session,
                        isActive: appState.activeChat?.sessionID == session.id,
                        hasPermissionPending: appState.activeChat?.sessionID == session.id
                            && appState.activeChat?.pendingPermission != nil,
                        isWorking: appState.activeChat?.sessionID == session.id
                            && appState.activeChat?.streaming == true
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

    // MARK: - Footer: model + agent

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "cpu")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textFaint)
            Text(modelName)
                .font(Theme.caption)
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
            Spacer()
            Circle()
                .fill(Theme.agentColor(appState.selectedAgentID))
                .frame(width: 6, height: 6)
            Text(appState.selectedAgentID)
                .font(Theme.caption)
                .foregroundStyle(Theme.textMuted)
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

/// opencode session row: 6px status dot + title 14 regular, hover/active bg.
struct SessionRow: View {
    let session: SessionMeta
    var isActive: Bool = false
    var hasPermissionPending: Bool = false
    var isWorking: Bool = false
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            statusIndicator
            Text(session.title)
                .font(Theme.sans)
                .foregroundStyle(Theme.textBase)
                .lineLimit(1)
            Spacer()
            Text(session.updated, style: .relative)
                .font(Theme.tiny)
                .foregroundStyle(Theme.textFaint)
                .opacity(hovered ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground, in: .rect(cornerRadius: Theme.radiusSmall))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if isWorking {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 6, height: 6)
        } else if hasPermissionPending {
            Circle().fill(Theme.warning).frame(width: 6, height: 6)
        } else {
            Circle()
                .fill(isActive ? Theme.textAccent : .clear)
                .frame(width: 6, height: 6)
        }
    }

    private var rowBackground: Color {
        if isActive { return Theme.overlayPressed }
        if hovered { return Theme.overlayHover }
        return .clear
    }
}
