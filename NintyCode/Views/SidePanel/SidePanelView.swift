import SwiftUI
import NintyCore

/// opencode v2 side panel: "Files Changed" review tab + "Context" tab.
/// "Changes" mode = working tree vs HEAD (git subprocess via GitReview).
struct SidePanelView: View {
    @Environment(AppState.self) private var appState
    let chat: ChatStore?

    enum PanelTab { case files, context }

    @State private var tab: PanelTab = .files
    @State private var changes: [FileChange] = []
    @State private var selectedPath: String?
    @State private var diffText = ""
    @State private var filter = ""
    @State private var loading = true
    @State private var isRepo = true
    @State private var refreshTask: Task<Void, Never>?

    private var review: GitReview? {
        appState.projectRoot.map(GitReview.init(projectRoot:))
    }

    private var filtered: [FileChange] {
        guard !filter.isEmpty else { return changes }
        let needle = filter.lowercased()
        return changes.filter { $0.path.lowercased().contains(needle) }
    }

    private var totalAdds: Int { changes.reduce(0) { $0 + $1.additions } }
    private var totalDels: Int { changes.reduce(0) { $0 + $1.deletions } }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().overlay(Theme.borderBase)
            switch tab {
            case .files:
                filesContent
            case .context:
                if let chat {
                    ContextTabView(chat: chat)
                } else {
                    emptyState(icon: "bubble.left", text: "No active session")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgBase)
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
            tabPill(title: changes.isEmpty ? "Files Changed" : "Files Changed \(changes.count)",
                    icon: "doc.on.doc", active: tab == .files) { tab = .files }
            tabPill(title: "Context", icon: "circle.lefthalf.filled", active: tab == .context) { tab = .context }
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
        if !isRepo {
            emptyState(icon: "folder.badge.questionmark", text: "Not a git repository")
        } else if loading && changes.isEmpty {
            Spacer()
            ProgressView().controlSize(.small)
            Spacer()
        } else if changes.isEmpty {
            emptyState(icon: "checkmark.circle", text: "No changes")
        } else {
            HSplitView {
                fileList
                    .frame(minWidth: 170, idealWidth: 200, maxWidth: 260)
                diffPreview
                    .frame(minWidth: 240)
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
                    ForEach(filtered) { change in
                        fileRow(change)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func fileRow(_ change: FileChange) -> some View {
        let selected = change.path == selectedPath
        return HStack(spacing: 6) {
            Text(change.status.rawValue)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(statusColor(change.status))
                .frame(width: 12)
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
        .onTapGesture { select(change) }
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
        if selectedPath == nil {
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

    private func select(_ change: FileChange) {
        selectedPath = change.path
        diffText = ""
        guard let review else { return }
        Task {
            let text = await review.diff(for: change)
            if selectedPath == change.path { diffText = text }
        }
    }

    private func reload() async {
        guard let review else { isRepo = false; loading = false; return }
        loading = true
        let repo = await review.isGitRepo()
        guard repo else {
            isRepo = false
            loading = false
            return
        }
        isRepo = true
        let list = await review.changes()
        changes = list
        loading = false
        if let selected = selectedPath, let current = list.first(where: { $0.path == selected }) {
            select(current)
        } else if let first = list.first {
            select(first)
        } else {
            selectedPath = nil
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
