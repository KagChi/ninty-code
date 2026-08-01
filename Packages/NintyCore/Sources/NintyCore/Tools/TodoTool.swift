import Foundation

public struct TodoItem: Codable, Sendable, Equatable {
    public var content: String
    public var status: String   // pending | in_progress | completed | cancelled
    public var priority: String // high | medium | low

    public init(content: String, status: String, priority: String) {
        self.content = content
        self.status = status
        self.priority = priority
    }
}

/// Shared per-session todo state. Actor for safe mutation.
public actor TodoStore {
    public private(set) var items: [TodoItem] = []

    public init() {}

    public func replace(_ items: [TodoItem]) {
        self.items = items
    }
}

public struct TodoWriteTool: AgentTool {
    let store: TodoStore

    public init(store: TodoStore) {
        self.store = store
    }

    public let name = "todowrite"
    public let description = "Update the task list for this session. Tracks multi-step work."
    public let parameters: JSONSchema = .object(
        properties: [
            "todos": .array(
                of: .object(
                    properties: [
                        "content": .string("Task description"),
                        "status": .enumeration(["pending", "in_progress", "completed", "cancelled"]),
                        "priority": .enumeration(["high", "medium", "low"])
                    ],
                    required: ["content", "status", "priority"]
                ),
                description: "Full replacement task list"
            )
        ],
        required: ["todos"]
    )

    public func execute(_ args: JSONValue, ctx: ToolContext) async throws -> ToolResult {
        guard let todos = args["todos"]?.arrayValue else {
            throw ToolError.missingParameter("todos")
        }
        let items = todos.map { value in
            TodoItem(
                content: value["content"]?.stringValue ?? "",
                status: value["status"]?.stringValue ?? "pending",
                priority: value["priority"]?.stringValue ?? "medium"
            )
        }
        await store.replace(items)
        let rendered = items.map { "[\($0.status)] (\($0.priority)) \($0.content)" }.joined(separator: "\n")
        return ToolResult(output: rendered.isEmpty ? "(task list cleared)" : rendered)
    }
}
