import Foundation

/// One changed file in the review panel.
public struct FileChange: Sendable, Equatable, Identifiable {
    public enum Status: String, Sendable {
        case added = "A"
        case modified = "M"
        case deleted = "D"
        case untracked = "?"
    }
    public var path: String
    public var status: Status
    public var additions: Int
    public var deletions: Int

    public var id: String { path }

    public init(path: String, status: Status, additions: Int = 0, deletions: Int = 0) {
        self.path = path
        self.status = status
        self.additions = additions
        self.deletions = deletions
    }
}

/// Git-backed review data (opencode "Changes" mode) via git subprocesses — no dependency.
public struct GitReview: Sendable {
    public let projectRoot: URL

    public init(projectRoot: URL) {
        self.projectRoot = projectRoot
    }

    /// Whether the project is inside a git work tree.
    public func isGitRepo() async -> Bool {
        let result = await run(["rev-parse", "--is-inside-work-tree"])
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// Working-tree changes (staged + unstaged + untracked), porcelain-parsed.
    public func changes() async -> [FileChange] {
        let status = await run(["status", "--porcelain=v1", "-uall"])
        var files: [(path: String, status: FileChange.Status)] = []
        for line in status.output.components(separatedBy: .newlines) where line.count > 3 {
            let code = String(line.prefix(2))
            let path = String(line.dropFirst(3))
                .trimmingCharacters(in: .init(charactersIn: "\""))
            let statusLetter: FileChange.Status
            if code.contains("?") { statusLetter = .untracked }
            else if code.contains("A") { statusLetter = .added }
            else if code.contains("D") { statusLetter = .deleted }
            else { statusLetter = .modified }
            files.append((path, statusLetter))
        }
        // Stats per file (numstat covers tracked; untracked counted as full additions).
        let numstat = await run(["diff", "--numstat", "HEAD", "--"])
        var stats: [String: (Int, Int)] = [:]
        for line in numstat.output.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 3, let add = Int(parts[0]), let del = Int(parts[1]) else { continue }
            stats[parts[2]] = (add, del)
        }
        return files.map { file in
            if let (add, del) = stats[file.path] {
                return FileChange(path: file.path, status: file.status, additions: add, deletions: del)
            }
            if file.status == .untracked {
                let fullPath = projectRoot.appendingPathComponent(file.path).path
                let lines = (try? String(contentsOfFile: fullPath))?
                    .components(separatedBy: .newlines).count ?? 0
                return FileChange(path: file.path, status: file.status, additions: max(0, lines - 1), deletions: 0)
            }
            return FileChange(path: file.path, status: file.status)
        }.sorted { $0.path < $1.path }
    }

    /// Unified diff for one file (HEAD vs working tree; untracked → whole file as additions).
    public func diff(for change: FileChange) async -> String {
        if change.status == .untracked || change.status == .added && change.deletions == 0 {
            let fullPath = projectRoot.appendingPathComponent(change.path).path
            guard let data = FileManager.default.contents(atPath: fullPath) else { return "" }
            return await Self.wholeFileDiff(path: change.path, newData: data, additionsOnly: true)
        }
        let result = await run(["diff", "HEAD", "--", change.path])
        return result.output
    }

    /// Diff original (pre-turn) data against the current file on disk — "Last turn" mode.
    public static func noIndexDiff(path: String, original: Data?, current: Data?) async -> String {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ninty-diff-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let oldFile = temp.appendingPathComponent("old")
        let newFile = temp.appendingPathComponent("new")
        try? (original ?? Data()).write(to: oldFile)
        try? (current ?? Data()).write(to: newFile)
        let result = await runProcess(
            launchPath: "/usr/bin/git",
            arguments: ["diff", "--no-index", "--src-prefix=a/\(path)", "--dst-prefix=b/\(path)",
                        oldFile.path, newFile.path],
            directory: nil
        )
        // Rewrite temp paths to the real path for display.
        return result.output
            .replacingOccurrences(of: oldFile.path, with: "a/\(path)")
            .replacingOccurrences(of: newFile.path, with: "b/\(path)")
    }

    /// Whole new file rendered as an all-additions unified diff.
    public static func wholeFileDiff(path: String, newData: Data, additionsOnly: Bool) async -> String {
        await noIndexDiff(path: path, original: additionsOnly ? Data() : newData, current: newData)
    }

    private func run(_ arguments: [String]) async -> (output: String, exitCode: Int32) {
        await Self.runProcess(launchPath: "/usr/bin/git", arguments: arguments, directory: projectRoot)
    }

    static func runProcess(
        launchPath: String, arguments: [String], directory: URL?
    ) async -> (output: String, exitCode: Int32) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: launchPath)
            process.arguments = arguments
            if let directory { process.currentDirectoryURL = directory }
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                continuation.resume(returning: ("", -1))
                return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            continuation.resume(returning: (
                String(data: data, encoding: .utf8) ?? "",
                process.terminationStatus
            ))
        }
    }
}
