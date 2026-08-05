import SwiftUI
import NintyCore

/// Left sidebar: native NavigationSplitView column — system traffic lights,
/// native `.searchable` field, list material and hover all come from macOS.
/// Only custom pieces: the "New session" capsule and the settings footer.
/// Workspaces sorted by name (stable order — no row jumping); clicking a
/// workspace expands/collapses its sessions, the hover arrow button switches
/// the active workspace. Multi-root: header shows a folder-count badge and
/// Add/Remove Folder context actions.
struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @State private var query = ""

    /// Stable alphabetical order — MRU reorders on workspace switch, which
    /// used to make the clicked row jump to the top.
    private var workspaces: [Workspace] {
        var list = appState.workspaces
        if let active = appState.workspace, !list.contains(active) { list.append(active) }
        return list.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func sessions(for workspace: Workspace) -> [SessionMeta] {
        let all = appState.sessionsByWorkspace[workspace.id] ?? []
        guard !query.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private func isVisible(_ workspace: Workspace) -> Bool {
        query.isEmpty || !sessions(for: workspace).isEmpty
            || workspace.name.localizedCaseInsensitiveContains(query)
    }

    private func expansionBinding(for workspace: Workspace) -> Binding<Bool> {
        Binding(
            get: { appState.expandedWorkspaces.contains(workspace.id) },
            set: { expanded in
                if expanded {
                    appState.expandedWorkspaces.insert(workspace.id)
                } else {
                    appState.expandedWorkspaces.remove(workspace.id)
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 8) {
            newSessionButton
                .padding(.horizontal, 12)
                .padding(.top, 8)

            List {
                ForEach(workspaces.filter(isVisible)) { workspace in
                    Section(isExpanded: expansionBinding(for: workspace)) {
                        let workspaceSessions = sessions(for: workspace)
                        if workspaceSessions.isEmpty {
                            Text("No sessions yet")
                                .font(Theme.tiny)
                                .foregroundStyle(Theme.textFaint)
                        } else {
                            ForEach(workspaceSessions) { session in
                                SidebarSessionRow(
                                    session: session,
                                    workspace: workspace,
                                    workspaceIsActive: workspace.id == appState.workspace?.id
                                )
                            }
                        }
                    } header: {
                        SidebarWorkspaceHeader(
                            workspace: workspace,
                            isActive: workspace.id == appState.workspace?.id
                        )
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .overlay {
                if workspaces.isEmpty {
                    Text("Open a project to start.")
                        .font(Theme.small)
                        .foregroundStyle(Theme.textFaint)
                }
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search sessions…")
        .safeAreaInset(edge: .bottom) { footer }
    }

    /// Capsule matching the native search field above it.
    private var newSessionButton: some View {
        Button { appState.newChat() } label: {
            Label("New session", systemImage: "plus")
                .font(Theme.tiny.weight(.medium))
                .foregroundStyle(Theme.textBase)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background(Theme.accent.opacity(0.2), in: .capsule)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Button {
                appState.showSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .font(Theme.small)
                    .foregroundStyle(Theme.textMuted)
            }
            .buttonStyle(.plain)
            Spacer()
            Button { appState.showNewWorkspaceDialog() } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New workspace")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Section header: avatar + name (+ folder-count badge for multi-root).
/// Whole-row tap expands/collapses; hover reveals the switch arrow for
/// non-active workspaces. Context menu: add/remove folders, delete workspace.
private struct SidebarWorkspaceHeader: View {
    @Environment(AppState.self) private var appState
    let workspace: Workspace
    let isActive: Bool
    @State private var hovered = false
    @State private var showDeleteConfirm = false

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Theme.accent.opacity(isActive ? 1 : 0.4))
                .frame(width: 16, height: 16)
                .overlay {
                    Text(workspace.name.prefix(1).uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                }
            Text(workspace.name)
                .font(Theme.smallMedium)
                .foregroundStyle(isActive ? Theme.textBase : Theme.textMuted)
                .lineLimit(1)
            if workspace.folders.count > 1 {
                Text("\(workspace.folders.count) folders")
                    .font(Theme.tiny)
                    .foregroundStyle(Theme.textFaint)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Theme.textFaint.opacity(0.12), in: .capsule)
            }
            Spacer()
            if hovered && !isActive {
                Button {
                    appState.openWorkspace(workspace)
                } label: {
                    Image(systemName: "arrow.right.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Switch to workspace")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        // Active workspace keeps a visible accent tint; others highlight on hover.
        .background(
            isActive ? Theme.accent.opacity(0.18) : (hovered ? Theme.overlayHover : .clear),
            in: .rect(cornerRadius: Theme.radiusSmall)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if appState.expandedWorkspaces.contains(workspace.id) {
                appState.expandedWorkspaces.remove(workspace.id)
            } else {
                appState.expandedWorkspaces.insert(workspace.id)
            }
        }
        .onHover { hovered = $0 }
        .animation(.easeInOut(duration: 0.1), value: hovered)
        .contextMenu {
            Button("New Session") { appState.newChat(in: workspace) }
            Divider()
            Button("Edit Workspace…") { appState.showEditWorkspaceDialog(workspace) }
            Button("Add Folder…") { appState.pickFolderToAdd(to: workspace) }
            if workspace.folders.count > 1 {
                Menu("Remove Folder") {
                    ForEach(workspace.folders, id: \.self) { folder in
                        Button(folder.lastPathComponent) {
                            appState.removeFolder(folder, from: workspace)
                        }
                    }
                }
            }
            Divider()
            Button("Delete Workspace…", role: .destructive) { showDeleteConfirm = true }
        }
        .confirmationDialog(
            "Delete \(workspace.name)?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Workspace", role: .destructive) {
                appState.removeWorkspace(workspace)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let count = appState.sessionsByWorkspace[workspace.id]?.count ?? 0
            Text("Removes the workspace from the sidebar and permanently deletes \(count == 0 ? "all its sessions" : "\(count) session\(count == 1 ? "" : "s")") from disk. Folders on disk are not touched.")
        }
    }
}

/// Session row: status indicator + title, opens as tab.
private struct SidebarSessionRow: View {
    @Environment(AppState.self) private var appState
    let session: SessionMeta
    let workspace: Workspace
    let workspaceIsActive: Bool
    @State private var hovered = false

    private var openTab: ChatStore? {
        guard workspaceIsActive else { return nil }
        return appState.openTabs.first { $0.sessionID == session.id }
    }

    /// The session currently on screen (its tab is active).
    private var isCurrent: Bool {
        appState.activeChat?.sessionID == session.id
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                if openTab?.streaming == true {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.6)
                        .frame(width: 10, height: 10)
                } else if openTab?.hasUnread == true {
                    Circle()
                        .fill(Theme.textAccent)
                        .frame(width: 6, height: 6)
                }
            }
            .frame(width: 10, height: 10)
            Text(session.title)
                .font(Theme.smallMedium)
                .foregroundStyle(Theme.textBase)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        // Current session keeps a visible tint; others highlight on hover.
        .background(
            isCurrent ? Theme.accent.opacity(0.14) : (hovered ? Theme.overlayHover : .clear),
            in: .rect(cornerRadius: Theme.radiusSmall)
        )
        .contentShape(Rectangle())
        .onTapGesture { openSession() }
        .onHover { hovered = $0 }
        .animation(.easeInOut(duration: 0.1), value: hovered)
        .contextMenu {
            Button("Open") { openSession() }
            if workspaceIsActive {
                Divider()
                Button("Delete", role: .destructive) { appState.deleteSession(session.id) }
            }
        }
    }

    private func openSession() {
        if workspaceIsActive {
            appState.openChat(session.id)
        } else {
            appState.openSession(session.id, in: workspace)
        }
    }
}
