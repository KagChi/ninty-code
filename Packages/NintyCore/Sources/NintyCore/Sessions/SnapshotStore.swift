import Foundation

/// Per-turn file snapshots for undo/redo (opencode revert semantics, git-free).
///
/// Before the first mutation of a file within a user turn, its original content
/// is captured into the current segment. `revert()` restores the last segment's
/// originals (stashing current contents for `redo()`); `redo()` writes the stash back.
public actor SnapshotStore {
    /// path → original content before the turn (`nil` = file did not exist).
    public typealias Segment = [String: Data?]

    private var applied: [Segment] = []
    private var reverted: [(originals: Segment, stash: Segment)] = []
    private var current: Segment = [:]
    private let fileManager = FileManager.default

    public init() {}

    /// Number of segments that can currently be undone.
    public var undoDepth: Int { applied.count + (current.isEmpty ? 0 : 1) }
    public var redoDepth: Int { reverted.count }

    /// Close the open segment at the start of each user turn.
    public func beginTurn() {
        guard !current.isEmpty else { return }
        applied.append(current)
        current = [:]
    }

    /// Capture a file's pre-mutation content into the open segment (first touch per turn wins).
    public func recordOriginal(path: String) {
        guard current[path] == nil else { return }
        current[path] = fileManager.contents(atPath: path)
    }

    /// Pre-mutation content for a path recorded this turn (`nil` content = file did not exist).
    /// Outer `nil` = path was never recorded.
    public func originalContent(path: String) -> Data?? {
        if let entry = current[path] { return entry }
        return applied.last?[path] ?? nil
    }

    /// Restore the most recent segment's originals. Returns restored paths.
    @discardableResult
    public func revert() -> [String] {
        var segment = current
        current = [:]
        if segment.isEmpty, let last = applied.popLast() {
            segment = last
        }
        guard !segment.isEmpty else { return [] }
        var stash: Segment = [:]
        for (path, _) in segment {
            stash[path] = fileManager.contents(atPath: path)
        }
        for (path, original) in segment {
            write(original, to: path)
        }
        reverted.append((originals: segment, stash: stash))
        return Array(segment.keys)
    }

    /// Re-apply the most recently reverted segment. Returns restored paths.
    @discardableResult
    public func redo() -> [String] {
        guard let entry = reverted.popLast() else { return [] }
        for (path, stashed) in entry.stash {
            write(stashed, to: path)
        }
        applied.append(entry.originals)
        return Array(entry.stash.keys)
    }

    /// Drop redo history (opencode: sending a new prompt while reverted is permanent).
    public func clearReverted() {
        reverted.removeAll()
    }

    private func write(_ data: Data?, to path: String) {
        if let data {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } else {
            try? fileManager.removeItem(atPath: path)
        }
    }
}
