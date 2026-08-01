import Foundation

public struct BashTool: AgentTool {
    public init() {}
    public let name = "bash"
    public let description = "Run a shell command in the project directory. Output capped at 50KB."
    public let parameters: JSONSchema = .object(
        properties: [
            "command": .string("Shell command to execute"),
            "timeout": .integer("Timeout in seconds (default 120, max 600)")
        ],
        required: ["command"]
    )

    static let defaultTimeout: TimeInterval = 120
    static let maxTimeout: TimeInterval = 600
    static let maxOutputBytes = 50 * 1024

    public func execute(_ args: JSONValue, ctx: ToolContext) async throws -> ToolResult {
        let command = try args.requireString("command")
        let requested = TimeInterval(args.optionalInt("timeout") ?? Int(Self.defaultTimeout))
        let timeout = min(max(requested, 1), Self.maxTimeout)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = ctx.projectRoot
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return .error("Failed to launch: \(error.localizedDescription)")
        }

        // Read output concurrently to avoid pipe-buffer deadlock.
        let outputTask = Task { pipe.fileHandleForReading.readDataToEndOfFile() }
        let deadline = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
            if process.isRunning { process.terminate() }
        }
        let data = await outputTask.value
        deadline.cancel()
        process.waitUntilExit()

        var output = String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
        var truncated = false
        if output.utf8.count > Self.maxOutputBytes {
            output = String(String(decoding: output.utf8.prefix(Self.maxOutputBytes), as: UTF8.self))
            truncated = true
        }
        let exitCode = process.terminationStatus
        var result = output.trimmingCharacters(in: .newlines)
        if truncated { result += "\n(output truncated at 50KB)" }
        if exitCode != 0 { result += "\n(exit code \(exitCode))" }
        if result.isEmpty { result = "(no output, exit code \(exitCode))" }
        return ToolResult(output: result, isError: exitCode != 0)
    }
}
