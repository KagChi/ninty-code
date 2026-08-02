import SwiftUI
import AppKit
import NintyCore

/// opencode v2 Home overlay (⌘B): projects column + sessions column w/ search.
/// Replaces the v1 sidebar entirely.
struct HomeView: View {
    @Environment(AppState.self) private var appState
    @State private var query = ""

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            projectsColumn
                .frame(width: 240)
            sessionsColumn
                .frame(maxWidth: 640)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(20)
        .background(Theme.bgBase)
    }

    // MARK: - Projects (left column)

    private var projectsColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Projects")
                    .font(Theme.smallMedium)
                    .foregroundStyle(Theme.textMuted)
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
            .frame(height: 28)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if let root = appState.projectRoot {
                        ProjectRow(path: root, isActive: true) {}
                    }
                    ForEach(appState.recentProjects.filter { $0 != appState.projectRoot }, id: \.self) { url in
                        ProjectRow(path: url, isActive: false) {
                            appState.openProject(url)
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                Button {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .font(Theme.small)
                        .foregroundStyle(Theme.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Sessions (right column)

    private var sessionsColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textFaint)
                    TextField("Search sessions…", text: $query)
                        .textFieldStyle(.plain)
                        .font(Theme.small)
                        .foregroundStyle(Theme.textBase)
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textFaint)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(Theme.layer02.opacity(0.6), in: .rect(cornerRadius: Theme.radiusSmall))

                Button {
                    appState.newChat()
                } label: {
                    Label("New session", systemImage: "square.and.pencil")
                        .font(Theme.smallMedium)
                }
                .buttonStyle(DockButtonStyle(variant: .secondary))
                .keyboardShortcut("n", modifiers: .command)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredGroups, id: \.label) { group in
                        Text(group.label.uppercased())
                            .font(Theme.tiny)
                            .foregroundStyle(Theme.textFaint)
                            .padding(.top, 10)
                            .padding(.bottom, 2)
                        ForEach(group.items) { session in
                            HomeSessionRow(session: session)
                        }
                    }
                    if filteredGroups.isEmpty {
                        Text(appState.projectRoot == nil
                             ? "Open a project to start."
                             : "No sessions yet.")
                            .font(Theme.small)
                            .foregroundStyle(Theme.textFaint)
                            .padding(.top, 24)
                    }
                }
            }
        }
    }

    private var filteredGroups: [(label: String, items: [SessionMeta])] {
        let filtered = query.isEmpty
            ? appState.sessions
            : appState.sessions.filter { $0.title.localizedCaseInsensitiveContains(query) }
        let calendar = Calendar.current
        let today = filtered.filter { calendar.isDateInToday($0.updated) }
        let yesterday = filtered.filter { calendar.isDateInYesterday($0.updated) }
        let older = filtered.filter {
            !calendar.isDateInToday($0.updated) && !calendar.isDateInYesterday($0.updated)
        }
        var groups: [(String, [SessionMeta])] = []
        if !today.isEmpty { groups.append(("Today", today)) }
        if !yesterday.isEmpty { groups.append(("Yesterday", yesterday)) }
        if !older.isEmpty { groups.append((groups.isEmpty ? "Recent sessions" : "Older", older)) }
        return groups
    }

}

/// Project row: avatar + name, active highlighted.
struct ProjectRow: View {
    let path: URL
    let isActive: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Theme.accent.opacity(isActive ? 1 : 0.4))
                .frame(width: 16, height: 16)
                .overlay {
                    Text(path.lastPathComponent.prefix(1).uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                }
            Text(path.lastPathComponent)
                .font(Theme.small)
                .foregroundStyle(isActive ? Theme.textBase : Theme.textMuted)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(
            isActive ? Theme.layer03 : (hovered ? Theme.layer01 : .clear),
            in: .rect(cornerRadius: Theme.radiusSmall)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hovered = $0 }
    }
}

/// v2 HomeSessionRow: status avatar + title, opens as tab.
struct HomeSessionRow: View {
    @Environment(AppState.self) private var appState
    let session: SessionMeta
    @State private var hovered = false

    private var openTab: ChatStore? {
        appState.openTabs.first { $0.sessionID == session.id }
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Theme.borderStrong, lineWidth: 1)
                    .frame(width: 16, height: 16)
                if openTab?.streaming == true {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.6)
                        .frame(width: 16, height: 16)
                } else if openTab?.hasUnread == true {
                    Circle()
                        .fill(Theme.textAccent)
                        .frame(width: 6, height: 6)
                }
            }
            Text(session.title)
                .font(Theme.smallMedium)
                .foregroundStyle(Theme.textBase)
                .lineLimit(1)
            Spacer()
            Text(session.updated, style: .relative)
                .font(Theme.tiny)
                .foregroundStyle(Theme.textFaint)
                .opacity(hovered ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(hovered ? Theme.layer01 : .clear, in: .rect(cornerRadius: Theme.radiusSmall))
        .contentShape(Rectangle())
        .onTapGesture { appState.openChat(session.id) }
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Open") { appState.openChat(session.id) }
            Divider()
            Button("Delete", role: .destructive) { appState.deleteSession(session.id) }
        }
    }
}
