import Foundation

/// An agent mode: system prompt + permission rules + optional model override.
public struct Agent: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var systemPrompt: String
    public var permissions: PermissionSet
    public var modelOverride: String?

    public init(id: String, name: String, systemPrompt: String, permissions: PermissionSet, modelOverride: String? = nil) {
        self.id = id
        self.name = name
        self.systemPrompt = systemPrompt
        self.permissions = permissions
        self.modelOverride = modelOverride
    }

    static let basePrompt = """
    You are ninty-code, an AI coding assistant running inside the user's project.
    Rules:
    - Prefer the edit tool over write for existing files. Read before editing.
    - Verify changes: build and run tests when the project has them.
    - Never run git mutations (commit, push, reset, rebase) unless the user explicitly asks.
    - Keep responses concise. Show, don't narrate.
    - Minimal diffs. Match existing code style.
    """

    public static let build = Agent(
        id: "build",
        name: "Build",
        systemPrompt: basePrompt,
        permissions: PermissionSet(rules: ["*": .allow])
    )

    public static let plan = Agent(
        id: "plan",
        name: "Plan",
        systemPrompt: basePrompt + """

        You are in PLAN MODE: read-only analysis.
        - You may read, search, and list files freely.
        - You may NOT create, edit, or delete files — EXCEPT writing the plan
          file itself under .opencode/plans/ (markdown only).
        - Ask before running any shell command.
        - Deliver analysis and a step-by-step plan. Do not implement.
        """,
        permissions: PermissionSet(rules: [
            "write": .deny,
            "edit": .deny,
            "todowrite": .deny,
            "bash": .ask,
            "mcp:*": .ask,
            "*": .allow
        ])
    )

    /// Tools hidden from the model for this agent. Plan keeps write/edit visible
    /// (allowed for plan files only; enforced at permission time, opencode-style).
    public var hiddenTools: Set<String> {
        if id == "plan" { return ["todowrite"] }
        return permissions.deniedTools
    }

    /// Built-ins + custom agents from config. Custom rules default to build's.
    public static func all(custom: [String: AgentConfig]) -> [Agent] {
        var agents = [build, plan]
        for (id, config) in custom.sorted(by: { $0.key < $1.key }) {
            var rules: [String: PermissionAction] = ["*": .allow]
            for (pattern, action) in config.tools ?? [:] {
                if let parsed = PermissionAction(rawValue: action) {
                    rules[pattern] = parsed
                }
            }
            agents.append(Agent(
                id: id,
                name: id.prefix(1).uppercased() + id.dropFirst(),
                systemPrompt: basePrompt + (config.prompt.map { "\n\n\($0)" } ?? ""),
                permissions: PermissionSet(rules: rules),
                modelOverride: config.model
            ))
        }
        return agents
    }
}
