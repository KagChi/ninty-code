import Foundation

/// Registry of all tools available to agents: built-ins + MCP-bridged.
/// Reference type: MCP tools can be registered after sessions already hold it.
public final class ToolRegistry: @unchecked Sendable {
    private var tools: [String: any AgentTool] = [:]
    private let lock = NSLock()

    public init(tools: [any AgentTool]) {
        for tool in tools { self.tools[tool.name] = tool }
    }

    /// Built-in tool set. Todo store shared per session.
    public static func builtIns(todoStore: TodoStore) -> ToolRegistry {
        ToolRegistry(tools: [
            ReadTool(),
            WriteTool(),
            EditTool(),
            BashTool(),
            GlobTool(),
            GrepTool(),
            ListTool(),
            TodoWriteTool(store: todoStore)
        ])
    }

    public func tool(named name: String) -> (any AgentTool)? {
        lock.lock()
        defer { lock.unlock() }
        return tools[name]
    }

    public var names: [String] {
        lock.lock()
        defer { lock.unlock() }
        return tools.keys.sorted()
    }

    /// Register an additional tool (MCP bridge). Name collision with built-in is rejected.
    public func register(_ tool: any AgentTool) throws {
        lock.lock()
        defer { lock.unlock() }
        guard tools[tool.name] == nil else {
            throw ToolError.invalidParameter("name", "duplicate tool: \(tool.name)")
        }
        tools[tool.name] = tool
    }

    /// Tool definitions visible to the model, after applying agent deny rules.
    public func definitions(excluding denied: Set<String>) -> [ToolDefinition] {
        lock.lock()
        defer { lock.unlock() }
        return tools.filter { !denied.contains($0.key) }.map(\.value.definition).sorted { $0.name < $1.name }
    }
}
