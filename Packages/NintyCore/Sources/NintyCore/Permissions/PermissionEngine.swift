import Foundation

public enum PermissionAction: String, Codable, Sendable {
    case allow, deny, ask
}

public enum PermissionReply: String, Sendable {
    case once, always, reject
}

/// Rule set for one agent. Patterns: exact ("bash"), prefix wildcard ("mcp:*"), global ("*").
public struct PermissionSet: Sendable, Equatable {
    public var rules: [String: PermissionAction]

    public init(rules: [String: PermissionAction]) {
        self.rules = rules
    }

    /// Evaluate: exact match wins; otherwise deny > ask > allow among wildcard matches; default allow.
    public func action(for tool: String) -> PermissionAction {
        if let exact = rules[tool] { return exact }
        var matched: [PermissionAction] = []
        for (pattern, action) in rules {
            if pattern == "*" {
                matched.append(action)
            } else if pattern.hasSuffix(":*") {
                let prefix = String(pattern.dropLast(1)) // keep trailing ":"
                if tool.hasPrefix(prefix) { matched.append(action) }
            }
        }
        if matched.contains(.deny) { return .deny }
        if matched.contains(.ask) { return .ask }
        return .allow
    }

    /// Tools that must never reach the model.
    public var deniedTools: Set<String> {
        Set(rules.filter { $0.value == .deny }.keys)
    }

    /// Argument-aware eval (opencode plan agent: write/edit denied EXCEPT plans dir).
    /// `isPlan` enables the plans-file exception for write/edit.
    public func action(for tool: String, arguments: JSONValue, isPlan: Bool) -> PermissionAction {
        if isPlan, tool == "write" || tool == "edit",
           let path = arguments["path"]?.stringValue,
           Self.isPlansPath(path) {
            return .allow
        }
        return action(for: tool)
    }

    /// opencode: `.opencode/plans/*.md` (project) or global plans dir — matched loosely by suffix.
    static func isPlansPath(_ path: String) -> Bool {
        path.hasSuffix(".md")
            && (path.contains(".opencode/plans/") || path.contains(".config/ninty/plans/") || path.contains(".local/share/ninty/plans/"))
    }
}

public struct PermissionRequest: Sendable, Identifiable, Equatable {
    public var id: String
    public var tool: String
    /// Human-readable preview: command for bash, path+diff for edit, etc.
    public var preview: String
    public var arguments: JSONValue
    /// Pattern keys used by "Allow always" (opencode request.always[]): the exact
    /// argument forms future calls may match to be auto-approved.
    public var alwaysPatterns: [String]

    public init(id: String, tool: String, preview: String, arguments: JSONValue, alwaysPatterns: [String] = []) {
        self.id = id
        self.tool = tool
        self.preview = preview
        self.arguments = arguments
        self.alwaysPatterns = alwaysPatterns
    }

    /// Derive the pattern key for this call: bash → exact command, file tools → path, else tool name.
    public static func pattern(tool: String, arguments: JSONValue) -> String {
        switch tool {
        case "bash":
            if let command = arguments["command"]?.stringValue { return command }
        case "read", "write", "edit":
            if let path = arguments["path"]?.stringValue { return path }
        default:
            break
        }
        return tool
    }
}

public enum PermissionEngineError: Error, Sendable {
    case rejected(tool: String)
}

/// Evaluates rules + manages the ask flow (suspend until UI replies).
/// opencode parity: "always" stores tool+argument patterns and auto-approves
/// matching pending requests; "reject" cascades to every pending request.
public actor PermissionEngine {
    /// tool → approved argument patterns (glob: trailing * = prefix).
    private var allowlist: [String: [String]] = [:]
    private var pending: [String: (request: PermissionRequest, continuation: CheckedContinuation<PermissionReply, Never>)] = [:]

    public init() {}

    /// Resolve a tool call against the agent's rule set.
    /// Returns when execution may proceed; throws when rejected.
    public func authorize(
        tool: String,
        arguments: JSONValue,
        preview: String,
        rules: PermissionSet,
        onAsk: @Sendable (PermissionRequest) -> Void
    ) async throws {
        switch rules.action(for: tool) {
        case .allow:
            return
        case .deny:
            throw PermissionEngineError.rejected(tool: tool)
        case .ask:
            if autoAccept { return } // ⇧⌘A mode: reply "once" to everything
            let pattern = PermissionRequest.pattern(tool: tool, arguments: arguments)
            if isAllowed(tool: tool, pattern: pattern) { return }
            let request = PermissionRequest(
                id: UUID().uuidString, tool: tool, preview: preview,
                arguments: arguments, alwaysPatterns: [pattern]
            )
            let reply = await withCheckedContinuation { (continuation: CheckedContinuation<PermissionReply, Never>) in
                pending[request.id] = (request, continuation)
                onAsk(request)
            }
            pending.removeValue(forKey: request.id)
            switch reply {
            case .once:
                return
            case .always:
                addAlways(tool: tool, patterns: request.alwaysPatterns)
                // opencode: auto-approve other pending requests whose patterns now match.
                let nowApproved = pending.filter { _, entry in
                    entry.request.alwaysPatterns.contains { isAllowed(tool: entry.request.tool, pattern: $0) }
                }.map(\.key)
                for id in nowApproved {
                    pending.removeValue(forKey: id)?.continuation.resume(returning: .once)
                }
                return
            case .reject:
                throw PermissionEngineError.rejected(tool: tool)
            }
        }
    }

    /// UI entry point: answer a pending permission request.
    /// opencode: "reject" rejects this request AND all other pending requests in the session.
    public func reply(_ id: String, _ reply: PermissionReply) {
        if reply == .reject {
            rejectAll()
            return
        }
        pending.removeValue(forKey: id)?.continuation.resume(returning: reply)
    }

    /// Reject everything pending (e.g. on abort).
    public func rejectAll() {
        for (_, entry) in pending {
            entry.continuation.resume(returning: .reject)
        }
        pending.removeAll()
    }

    /// Auto-accept mode: approve every ask with "once" without surfacing it.
    public private(set) var autoAccept = false

    public func setAutoAccept(_ enabled: Bool) {
        autoAccept = enabled
    }

    private func addAlways(tool: String, patterns: [String]) {
        var existing = allowlist[tool] ?? []
        for pattern in patterns where !existing.contains(pattern) {
            existing.append(pattern)
        }
        allowlist[tool] = existing
    }

    private func isAllowed(tool: String, pattern: String) -> Bool {
        guard let patterns = allowlist[tool] else { return false }
        return patterns.contains { matches(pattern, pattern: $0) }
    }

    /// Exact match, or approved pattern ending in "*" = prefix match.
    private func matches(_ value: String, pattern approved: String) -> Bool {
        if approved.hasSuffix("*") {
            return value.hasPrefix(String(approved.dropLast()))
        }
        return value == approved
    }
}
