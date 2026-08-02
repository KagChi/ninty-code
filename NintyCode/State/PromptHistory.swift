import Foundation

/// opencode prompt history: newest-first, 100-cap, consecutive-dup suppressed,
/// persisted globally (separate store for shell mode).
@Observable
@MainActor
final class PromptHistory {
    private(set) var entries: [String] = []
    private var index = -1 // -1 = editing the live draft
    private var savedDraft = ""

    private let fileURL: URL

    init(shell: Bool = false) {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/ninty")
        self.fileURL = base.appendingPathComponent(shell ? "history-shell.json" : "history.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            entries = decoded
        }
    }

    /// Record a submitted prompt (newest first, dup-suppressed, 100-cap).
    func push(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, entries.first != trimmed else { reset() ; return }
        entries.insert(trimmed, at: 0)
        if entries.count > 100 { entries.removeLast(entries.count - 100) }
        reset()
        persist()
    }

    /// opencode cursor gating handled by caller. Returns recalled text or nil.
    func older(currentDraft: String) -> String? {
        if index == -1 { savedDraft = currentDraft }
        guard index + 1 < entries.count else { return nil }
        index += 1
        return entries[index]
    }

    func newer() -> String? {
        guard index >= 0 else { return nil }
        index -= 1
        return index == -1 ? savedDraft : entries[index]
    }

    /// Any typing resets navigation (opencode behavior).
    func reset() {
        index = -1
        savedDraft = ""
    }

    var isNavigating: Bool { index >= 0 }

    private func persist() {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
    }
}
