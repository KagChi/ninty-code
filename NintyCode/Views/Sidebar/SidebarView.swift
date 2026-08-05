import SwiftUI
import NintyCore

/// Left sidebar: native NavigationSplitView column — system traffic lights,
/// native `.searchable` field, list material and hover all come from macOS.
/// Only custom pieces: the "New session" capsule and the settings footer.
/// Projects sorted by name (stable order — no row jumping); clicking a
/// project expands/collapses its sessions, the hover arrow button switches
/// the active project.
struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @State private var query = ""

    /// Stable alphabetical order — recents reorder on project switch, which
    /// used to make the clicked row jump to the top.
    private var projects: [URL] {
        var list = appState.recentProjects
        if let root = appState.projectRoot, !list.contains(root) { list.append(root) }
        return list.sorted {
            $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    private func sessions(for project: URL) -> [SessionMeta] {
        let all = appState.sessionsByProject[project] ?? []
        guard !query.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private func isVisible(_ project: URL) -> Bool {
        query.isEmpty || !sessions(for: project).isEmpty
            || project.lastPathComponent.localizedCaseInsensitiveContains(query)
    }

    private func expansionBinding(for project: URL) -> Binding<Bool> {
        Binding(
            get: { appState.expandedProjects.contains(project) },
            set: { expanded in
                if expanded {
                    appState.expandedProjects.insert(project)
                } else {
                    appState.expandedProjects.remove(project)
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
                ForEach(projects.filter(isVisible), id: \.self) { url in
                    Section(isExpanded: expansionBinding(for: url)) {
                        let projectSessions = sessions(for: url)
                        if projectSessions.isEmpty {
                            Text("No sessions yet")
                                .font(Theme.tiny)
                                .foregroundStyle(Theme.textFaint)
                        } else {
                            ForEach(projectSessions) { session in
                                SidebarSessionRow(
                                    session: session,
                                    project: url,
                                    projectIsActive: url == appState.projectRoot
                                )
                            }
                        }
                    } header: {
                        SidebarProjectHeader(
                            project: url,
                            isActive: url == appState.projectRoot
                        )
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .overlay {
                if projects.isEmpty {
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
            Button { appState.pickProject() } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Add project")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Section header: avatar + name. Whole-row tap expands/collapses; hover
/// reveals the switch-project arrow for non-active projects.
private struct SidebarProjectHeader: View {
    @Environment(AppState.self) private var appState
    let project: URL
    let isActive: Bool
    @State private var hovered = false
    @State private var showDeleteConfirm = false

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Theme.accent.opacity(isActive ? 1 : 0.4))
                .frame(width: 16, height: 16)
                .overlay {
                    Text(project.lastPathComponent.prefix(1).uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                }
            Text(project.lastPathComponent)
                .font(Theme.smallMedium)
                .foregroundStyle(isActive ? Theme.textBase : Theme.textMuted)
                .lineLimit(1)
            Spacer()
            if hovered && !isActive {
                Button {
                    appState.openProject(project)
                } label: {
                    Image(systemName: "arrow.right.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Switch to project")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if appState.expandedProjects.contains(project) {
                appState.expandedProjects.remove(project)
            } else {
                appState.expandedProjects.insert(project)
            }
        }
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Delete Project…", role: .destructive) { showDeleteConfirm = true }
        }
        .confirmationDialog(
            "Delete \(project.lastPathComponent)?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Project", role: .destructive) {
                appState.removeProject(project)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let count = appState.sessionsByProject[project]?.count ?? 0
            Text("Removes the project from the sidebar and permanently deletes \(count == 0 ? "all its sessions" : "\(count) session\(count == 1 ? "" : "s")") from disk.")
        }
    }
}

/// Session row: status indicator + title, opens as tab.
private struct SidebarSessionRow: View {
    @Environment(AppState.self) private var appState
    let session: SessionMeta
    let project: URL
    let projectIsActive: Bool

    private var openTab: ChatStore? {
        guard projectIsActive else { return nil }
        return appState.openTabs.first { $0.sessionID == session.id }
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
        .contentShape(Rectangle())
        .onTapGesture { openSession() }
        .contextMenu {
            Button("Open") { openSession() }
            if projectIsActive {
                Divider()
                Button("Delete", role: .destructive) { appState.deleteSession(session.id) }
            }
        }
    }

    private func openSession() {
        if projectIsActive {
            appState.openChat(session.id)
        } else {
            appState.openSession(session.id, in: project)
        }
    }
}
