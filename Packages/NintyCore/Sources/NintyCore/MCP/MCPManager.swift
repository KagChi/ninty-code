import Foundation
import MCP
import System

/// An AgentTool bridged to a remote MCP server tool. Name is namespaced: `server:tool`.
struct MCPBridgedTool: AgentTool {
    let serverName: String
    let remoteName: String
    let toolDescription: String
    let schema: JSONSchema
    let call: @Sendable (JSONValue) async throws -> ToolResult

    var name: String { "\(serverName):\(remoteName)" }
    var description: String { toolDescription }
    var parameters: JSONSchema { schema }

    func execute(_ args: JSONValue, ctx: ToolContext) async throws -> ToolResult {
        try await call(args)
    }
}

public enum MCPError: Error, Sendable, Equatable {
    case serverNotRunning(String)
    case launchFailed(String, String)
}

public enum MCPServerStatus: Sendable, Equatable {
    case starting
    case running(toolCount: Int)
    case failed(String)
}

/// Manages MCP servers from config — stdio (spawn) and HTTP (remote) — and bridges their tools into the registry.
public actor MCPManager {
    private var configs: [String: MCPServerConfig]
    private var clients: [String: Client] = [:]
    private var processes: [String: Process] = [:]
    private var statuses: [String: MCPServerStatus] = [:]

    public init(configs: [String: MCPServerConfig]) {
        self.configs = configs
    }

    public func status(for server: String) -> MCPServerStatus? {
        statuses[server]
    }

    public var serverNames: [String] {
        configs.keys.sorted()
    }

    /// Start all configured servers. Failures are recorded, not thrown.
    public func startAll() async {
        for (name, config) in configs {
            await start(name: name, config: config)
        }
    }

    /// Start (or restart) one server.
    public func start(name: String, config: MCPServerConfig? = nil) async {
        let config = config ?? configs[name]
        guard let config else { return }
        statuses[name] = .starting
        do {
            if let urlString = config.url {
                // HTTP transport: connect to a remote streamable-HTTP server.
                guard let url = URL(string: urlString) else {
                    throw MCPError.launchFailed(name, "invalid url: \(urlString)")
                }
                let client = Client(name: "ninty-code", version: "0.1.0")
                let headers = config.headers ?? [:]
                let transport = HTTPClientTransport(endpoint: url) { request in
                    var request = request
                    for (key, value) in headers {
                        request.setValue(value, forHTTPHeaderField: key)
                    }
                    return request
                }
                _ = try await client.connect(transport: transport)
                clients[name] = client
                let (tools, _) = try await client.listTools()
                statuses[name] = .running(toolCount: tools.count)
            } else if let command = config.command {
                // Stdio transport: spawn a local server process.
                let (client, process) = try Self.spawn(name: name, command: command, args: config.args, env: config.env)
                _ = try await client.connect(transport: Self.transport(for: process.pipes))
                clients[name] = client
                processes[name] = process.process
                // Watch for crash.
                let pid = process.process
                pid.terminationHandler = { [weak self] _ in
                    Task { await self?.serverDied(name) }
                }
                let (tools, _) = try await client.listTools()
                statuses[name] = .running(toolCount: tools.count)
            } else {
                throw MCPError.launchFailed(name, "config has neither command nor url")
            }
        } catch {
            statuses[name] = .failed(error.localizedDescription)
        }
    }

    private func serverDied(_ name: String) {
        clients.removeValue(forKey: name)
        processes.removeValue(forKey: name)
        if case .running = statuses[name] {
            statuses[name] = .failed("process exited")
        }
    }

    /// Discover + bridge tools from all running servers.
    public func bridgedTools() async -> [any AgentTool] {
        var result: [any AgentTool] = []
        for (name, client) in clients.sorted(by: { $0.key < $1.key }) {
            guard let (tools, _) = try? await client.listTools() else { continue }
            for tool in tools {
                let schema = Self.convertSchema(tool.inputSchema)
                let description = tool.description ?? "MCP tool \(tool.name) from \(name)"
                result.append(MCPBridgedTool(
                    serverName: name,
                    remoteName: tool.name,
                    toolDescription: description,
                    schema: schema
                ) { args in
                    let mcpArgs = try Self.toMCPArguments(args)
                    let (content, isError) = try await client.callTool(name: tool.name, arguments: mcpArgs)
                    let text = content.compactMap { item -> String? in
                        if case .text(let value, _, _) = item { return value }
                        return nil
                    }.joined(separator: "\n")
                    return ToolResult(output: text.isEmpty ? "(no text output)" : text, isError: isError ?? false)
                })
            }
        }
        return result
    }

    /// Shut down all servers.
    public func stopAll() async {
        for (_, client) in clients {
            await client.disconnect()
        }
        for (_, process) in processes {
            if process.isRunning { process.terminate() }
        }
        clients.removeAll()
        processes.removeAll()
    }

    // MARK: - Spawn helpers

    private struct SpawnedProcess {
        var process: Process
        var pipes: (stdin: Pipe, stdout: Pipe)
    }

    private static func transport(for pipes: (stdin: Pipe, stdout: Pipe)) -> StdioTransport {
        StdioTransport(
            input: FileDescriptor(rawValue: pipes.stdout.fileHandleForReading.fileDescriptor),
            output: FileDescriptor(rawValue: pipes.stdin.fileHandleForWriting.fileDescriptor)
        )
    }

    private static func spawn(name: String, command: String, args: [String], env: [String: String]) throws -> (Client, SpawnedProcess) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + args
        var environment = ProcessInfo.processInfo.environment
        environment.merge(env) { _, new in new }
        process.environment = environment
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        // Server log noise must not pollute stdout; send our stderr to /dev/null passthrough.
        do {
            try process.run()
        } catch {
            throw MCPError.launchFailed(name, error.localizedDescription)
        }
        return (Client(name: "ninty-code", version: "0.1.0"), SpawnedProcess(process: process, pipes: (stdinPipe, stdoutPipe)))
    }

    // MARK: - Value conversion

    static func toMCPArguments(_ args: JSONValue) throws -> [String: Value]? {
        guard case .object(let object) = args else { return nil }
        let data = try JSONEncoder().encode(object)
        return try JSONDecoder().decode([String: Value].self, from: data)
    }

    static func convertSchema(_ value: Value) -> JSONSchema {
        if let data = try? JSONEncoder().encode(value),
           let schema = try? JSONDecoder().decode(JSONSchema.self, from: data) {
            return schema
        }
        return .object(properties: [:])
    }
}
