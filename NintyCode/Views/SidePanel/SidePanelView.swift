import SwiftUI
import NintyCore

/// opencode v2 side panel: "Files Changed" review tab + "Context" tab.
/// "Changes" mode = working tree vs HEAD (git subprocess via GitReview).
struct SidePanelView: View {
    @Environment(AppState.self) private var appState
    let chat: ChatStore?

    enum PanelTab { case files, context, graph, memory }

    @State private var tab: PanelTab = .files
    /// Per-root git state — multi-root workspaces show one section per repo folder.
    @State private var sections: [FolderSection] = []
    @State private var selection: (root: URL, path: String)?
    @State private var diffText = ""
    @State private var filter = ""
    @State private var loading = true
    @State private var anyRepo = true
    @State private var refreshTask: Task<Void, Never>?

    /// One workspace root's git state (skipped from UI when not a repo).
    struct FolderSection {
        let root: URL
        let review: GitReview
        var changes: [FileChange]
    }

    /// List row: change disambiguated by its root (paths can repeat across repos).
    struct Row: Identifiable {
        let root: URL
        let review: GitReview
        let change: FileChange
        var id: String { root.path + "|" + change.path }
    }

    private var allRows: [Row] {
        sections.flatMap { section in
            section.changes.map { Row(root: section.root, review: section.review, change: $0) }
        }
    }

    private var filtered: [Row] {
        guard !filter.isEmpty else { return allRows }
        let needle = filter.lowercased()
        return allRows.filter { $0.change.path.lowercased().contains(needle) }
    }

    private var changeCount: Int { sections.reduce(0) { $0 + $1.changes.count } }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().overlay(Theme.borderBase)
            switch tab {
            case .files:
                filesContent
            case .graph:
                GraphTabView()
            case .memory:
                LtmTabView()
            case .context:
                if let chat {
                    ContextTabView(chat: chat)
                } else {
                    emptyState(icon: "bubble.left", text: "No active session")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await reload() }
        .onChange(of: chat?.streaming) { _, streaming in
            // Refresh when a turn finishes — agent edits land on disk during the turn.
            if streaming == false {
                refreshTask?.cancel()
                refreshTask = Task { await reload() }
            }
        }
    }

    // MARK: - Tab bar (opencode panel strip: "Files Changed N" | "Context")

    private var tabBar: some View {
        HStack(spacing: 6) {
            tabPill(title: changeCount == 0 ? "Files Changed" : "Files Changed \(changeCount)",
                    icon: "doc.on.doc", active: tab == .files) { tab = .files }
            tabPill(title: "Context", icon: "circle.lefthalf.filled", active: tab == .context) { tab = .context }
            tabPill(title: "Graph", icon: "point.3.connected.trianglepath.dotted", active: tab == .graph) { tab = .graph }
            tabPill(title: "Memory", icon: "brain", active: tab == .memory) { tab = .memory }
            Spacer()
            if tab == .files {
                Button {
                    refreshTask?.cancel()
                    refreshTask = Task { await reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Refresh")
            }
            Button {
                appState.showSidePanel = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close (⇧⌘R)")
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
    }

    private func tabPill(title: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(active ? Theme.textBase : Theme.textFaint)
                Text(title)
                    .font(Theme.smallMedium)
                    .foregroundStyle(active ? Theme.textBase : Theme.textMuted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(active ? Theme.overlayPressed : .clear, in: .rect(cornerRadius: Theme.radiusSmall))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Files tab

    @ViewBuilder
    private var filesContent: some View {
        if !anyRepo {
            emptyState(icon: "folder.badge.questionmark", text: "Not a git repository")
        } else if loading && sections.isEmpty {
            Spacer()
            ProgressView().controlSize(.small)
            Spacer()
        } else if changeCount == 0 {
            emptyState(icon: "checkmark.circle", text: "No changes")
        } else {
            HSplitView {
                fileList
                    .frame(minWidth: 140, idealWidth: 180, maxWidth: 240)
                diffPreview
                    .frame(minWidth: 180)
            }
        }
    }

    // MARK: - File list

    private var fileList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textFaint)
                TextField("Filter files", text: $filter)
                    .textFieldStyle(.plain)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textBase)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Theme.layer02, in: .rect(cornerRadius: Theme.radiusSmall))
            .padding(8)

            ScrollView {
                LazyVStack(spacing: 1) {
                    // Multi-root: group rows under a folder header per repo.
                    ForEach(sections, id: \.root) { section in
                        let rows = filtered.filter { $0.root == section.root }
                        if !rows.isEmpty {
                            if sections.count > 1 {
                                Text(section.root.lastPathComponent)
                                    .font(Theme.tiny.weight(.semibold))
                                    .foregroundStyle(Theme.textFaint)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 6)
                                    .padding(.top, 6)
                                    .padding(.bottom, 2)
                            }
                            ForEach(rows) { row in
                                fileRow(row)
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func fileRow(_ row: Row) -> some View {
        let change = row.change
        let selected = selection?.root == row.root && selection?.path == change.path
        return HStack(spacing: 6) {
            Text(change.status.rawValue)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(statusColor(change.status))
                .frame(width: 12)
            FileTypeIcon(path: change.path)
            Text(change.path)
                .font(Theme.caption)
                .foregroundStyle(selected ? Theme.textBase : Theme.textMuted)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if change.additions > 0 || change.deletions > 0 {
                DiffChangesText(adds: change.additions, deletes: change.deletions)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(selected ? Theme.overlayPressed : .clear, in: .rect(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { select(row) }
    }

    private func statusColor(_ status: FileChange.Status) -> Color {
        switch status {
        case .added, .untracked: return Theme.diffAdd
        case .deleted: return Theme.diffDelete
        case .modified: return Theme.warning
        }
    }

    // MARK: - Diff preview

    @ViewBuilder
    private var diffPreview: some View {
        if selection == nil {
            emptyState(icon: "doc.text.magnifyingglass", text: "Select a file")
        } else if diffText.isEmpty {
            emptyState(icon: "doc.plaintext", text: "No diff available")
        } else {
            UnifiedDiffView(diff: diffText)
        }
    }

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(Theme.textFaint)
            Text(text)
                .font(Theme.caption)
                .foregroundStyle(Theme.textFaint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data

    private func select(_ row: Row) {
        selection = (row.root, row.change.path)
        diffText = ""
        Task {
            let text = await row.review.diff(for: row.change)
            if selection?.root == row.root, selection?.path == row.change.path { diffText = text }
        }
    }

    private func reload() async {
        guard let workspace = appState.workspace else {
            anyRepo = false
            loading = false
            return
        }
        loading = true
        var loaded: [FolderSection] = []
        for root in workspace.folders {
            let review = GitReview(projectRoot: root)
            guard await review.isGitRepo() else { continue } // non-repo folders skipped
            loaded.append(FolderSection(root: root, review: review, changes: await review.changes()))
        }
        anyRepo = !loaded.isEmpty
        sections = loaded
        loading = false
        if let current = selection,
           let row = allRows.first(where: { $0.root == current.root && $0.change.path == current.path }) {
            select(row)
        } else if let first = allRows.first {
            select(first)
        } else {
            selection = nil
            diffText = ""
        }
    }
}

/// Unified diff renderer: header dimmed, +/- lines colored with bg, context plain.
struct UnifiedDiffView: View {
    let diff: String

    private var lines: [String] {
        diff.components(separatedBy: .newlines)
    }

    var body: some View {
        ScrollView([.vertical, .horizontal], showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    lineView(line)
                }
            }
            .font(Theme.mono)
            .padding(.vertical, 8)
        }
        .background(Theme.layer02)
    }

    @ViewBuilder
    private func lineView(_ line: String) -> some View {
        if line.hasPrefix("+++") || line.hasPrefix("---") {
            text(line, color: Theme.textFaint, bold: true)
        } else if line.hasPrefix("@@") {
            text(line, color: Theme.textAccent)
        } else if line.hasPrefix("diff ") || line.hasPrefix("index ") ||
                    line.hasPrefix("new file") || line.hasPrefix("deleted file") {
            text(line, color: Theme.textFaint)
        } else if line.hasPrefix("+") {
            text(line, color: Theme.diffAdd, bg: Theme.diffAddBg)
        } else if line.hasPrefix("-") {
            text(line, color: Theme.diffDelete, bg: Theme.diffDeleteBg)
        } else {
            text(line.isEmpty ? " " : line, color: Theme.textMuted)
        }
    }

    private func text(_ s: String, color: Color, bg: Color = .clear, bold: Bool = false) -> some View {
        Text(s)
            .font(bold ? Theme.mono.weight(.semibold) : Theme.mono)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .background(bg)
    }
}
