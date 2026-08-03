import Foundation

/// One rendered diff line with its new-file line number where applicable.
public enum DiffLine: Sendable, Equatable {
    case context(String, newNo: Int)
    case added(String, newNo: Int)
    case removed(String)
}

/// A file mutated during a turn, with per-line diff against its pre-turn snapshot.
public struct ChangedFile: Sendable, Equatable {
    public let path: String
    public let additions: Int
    public let deletions: Int
    public let lines: [DiffLine]

    public init(path: String, additions: Int, deletions: Int, lines: [DiffLine]) {
        self.path = path
        self.additions = additions
        self.deletions = deletions
        self.lines = lines
    }
}

/// Git-free line diff (opencode snapshot parity).
/// Common prefix/suffix are trimmed, then an LCS DP runs on the differing
/// middle — agent edits are localized, so the middle stays small.
public enum LineDiff {

    /// Safety cap for the DP middle (cells). Beyond this, fall back to
    /// "remove whole middle, add whole middle" — counts stay correct.
    static let maxMiddleCells = 250_000

    public static func changedFile(path: String, old: String?, new: String?) -> ChangedFile {
        let lines = diff(old: old, new: new)
        var additions = 0
        var deletions = 0
        for line in lines {
            switch line {
            case .added: additions += 1
            case .removed: deletions += 1
            case .context: break
            }
        }
        return ChangedFile(path: path, additions: additions, deletions: deletions, lines: lines)
    }

    public static func diff(old: String?, new: String?) -> [DiffLine] {
        let oldLines = old.map(splitLines) ?? []
        let newLines = new.map(splitLines) ?? []

        // Trim common prefix/suffix.
        var prefix = 0
        while prefix < oldLines.count, prefix < newLines.count, oldLines[prefix] == newLines[prefix] {
            prefix += 1
        }
        var oldSuffix = oldLines.count
        var newSuffix = newLines.count
        while oldSuffix > prefix, newSuffix > prefix,
              oldLines[oldSuffix - 1] == newLines[newSuffix - 1] {
            oldSuffix -= 1
            newSuffix -= 1
        }

        let oldMiddle = Array(oldLines[prefix..<oldSuffix])
        let newMiddle = Array(newLines[prefix..<newSuffix])

        var result: [DiffLine] = []
        result.reserveCapacity(newLines.count)

        // Line numbers track the NEW file.
        for (index, line) in oldLines[..<prefix].enumerated() {
            result.append(.context(line, newNo: index + 1))
        }

        if oldMiddle.count * newMiddle.count > maxMiddleCells {
            for line in oldMiddle { result.append(.removed(line)) }
            var newNo = prefix + 1
            for line in newMiddle {
                result.append(.added(line, newNo: newNo))
                newNo += 1
            }
        } else {
            let middle = diffMiddle(old: oldMiddle, new: newMiddle, newNoStart: prefix + 1)
            result.append(contentsOf: middle)
        }

        for (index, line) in newLines[newSuffix...].enumerated() {
            result.append(.context(line, newNo: newSuffix + index + 1))
        }
        return result
    }

    /// LCS DP over the differing middle. Emits removed/added/context in order.
    private static func diffMiddle(old: [String], new: [String], newNoStart: Int) -> [DiffLine] {
        let n = old.count
        let m = new.count
        guard n > 0, m > 0 else {
            var result: [DiffLine] = []
            for line in old { result.append(.removed(line)) }
            var newNo = newNoStart
            for line in new {
                result.append(.added(line, newNo: newNo))
                newNo += 1
            }
            return result
        }

        // lengths[i][j] = LCS length of old[i...] and new[j...]
        var lengths = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                if old[i] == new[j] {
                    lengths[i][j] = lengths[i + 1][j + 1] + 1
                } else {
                    lengths[i][j] = max(lengths[i + 1][j], lengths[i][j + 1])
                }
            }
        }

        var result: [DiffLine] = []
        var i = 0
        var j = 0
        var newNo = newNoStart
        while i < n, j < m {
            if old[i] == new[j] {
                result.append(.context(new[j], newNo: newNo))
                i += 1
                j += 1
                newNo += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                result.append(.removed(old[i]))
                i += 1
            } else {
                result.append(.added(new[j], newNo: newNo))
                j += 1
                newNo += 1
            }
        }
        while i < n {
            result.append(.removed(old[i]))
            i += 1
        }
        while j < m {
            result.append(.added(new[j], newNo: newNo))
            j += 1
            newNo += 1
        }
        return result
    }

    /// Split preserving a trailing empty segment only when content is non-empty
    /// (a file ending in "\n" has that many real lines, not one more).
    private static func splitLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}
