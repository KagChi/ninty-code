import Testing
@testable import NintyCore

@Suite("LineDiff")
struct LineDiffTests {

    @Test func newFileAllAdded() {
        let file = LineDiff.changedFile(path: "a.json", old: nil, new: "{\n  \"a\": 1\n}")
        #expect(file.additions == 3)
        #expect(file.deletions == 0)
        #expect(file.lines.allSatisfy { if case .added = $0 { true } else { false } })
    }

    @Test func deletedFileAllRemoved() {
        let file = LineDiff.changedFile(path: "a.json", old: "one\ntwo", new: nil)
        #expect(file.additions == 0)
        #expect(file.deletions == 2)
        #expect(file.lines.allSatisfy { if case .removed = $0 { true } else { false } })
    }

    @Test func localizedEditKeepsContext() {
        let old = (1...20).map { "line \($0)" }.joined(separator: "\n")
        var newLines = (1...20).map { "line \($0)" }
        newLines[9] = "line 10 edited"
        let file = LineDiff.changedFile(path: "f.txt", old: old, new: newLines.joined(separator: "\n"))
        #expect(file.additions == 1)
        #expect(file.deletions == 1)
        let contexts = file.lines.filter { if case .context = $0 { true } else { false } }
        #expect(contexts.count == 19)
    }

    @Test func insertionOnly() {
        let file = LineDiff.changedFile(path: "f.txt", old: "a\nc", new: "a\nb\nc")
        #expect(file.additions == 1)
        #expect(file.deletions == 0)
    }

    @Test func trailingNewlineNotExtraLine() {
        let file = LineDiff.changedFile(path: "f.txt", old: nil, new: "a\nb\n")
        #expect(file.additions == 2)
    }

    @Test func lineNumbersTrackNewFile() {
        let file = LineDiff.changedFile(path: "f.txt", old: "a\nx\nc", new: "a\nb\nc")
        // "x" removed, "b" added as new line 2, "c" context at new line 3.
        guard case .removed = file.lines[1] else {
            Issue.record("expected removed at index 1")
            return
        }
        guard case .added(_, let addedNo) = file.lines[2] else {
            Issue.record("expected added at index 2")
            return
        }
        #expect(addedNo == 2)
        guard case .context(_, let contextNo) = file.lines[3] else {
            Issue.record("expected context at index 3")
            return
        }
        #expect(contextNo == 3)
    }

    @Test func unchangedFileAllContext() {
        let file = LineDiff.changedFile(path: "f.txt", old: "a\nb", new: "a\nb")
        #expect(file.additions == 0)
        #expect(file.deletions == 0)
        #expect(file.lines.count == 2)
    }

    @Test func hugeMiddleFallsBack() {
        let old = (0..<600).map { "old \($0)" }.joined(separator: "\n")
        let new = (0..<600).map { "new \($0)" }.joined(separator: "\n")
        // 600×600 = 360k cells > cap → fallback: all removed then all added.
        let file = LineDiff.changedFile(path: "f.txt", old: old, new: new)
        #expect(file.additions == 600)
        #expect(file.deletions == 600)
    }
}
