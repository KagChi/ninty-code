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
}

public struct PermissionRequest: Sendable, Identifiable, Equatable {
    public var id: String
    public var tool: String
    /// Human-readable preview: command for bash, path+diff for edit, etc.
    public var preview: String
    public var arguments: JSONValue

    public init(id: String, tool: String, preview: String, arguments: JSONValue) {
        self.id = id
        self.tool = tool
        self.preview = preview
        self.arguments = arguments
    }
}

public enum PermissionEngineError: Error, Sendable {
    case rejected(tool: String)
}

/// Evaluates rules + manages the ask flow (suspend until UI replies).
public actor PermissionEngine {
    private var allowlist: Set<String> = [] // tools approved "always" this session
    private var pending: [String: CheckedContinuation<PermissionReply, Never>] = [:]

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
            if allowlist.contains(tool) { return }
            let request = PermissionRequest(id: UUID().uuidString, tool: tool, preview: preview, arguments: arguments)
            let reply = await withCheckedContinuation { (continuation: CheckedContinuation<PermissionReply, Never>) in
                pending[request.id] = continuation
                onAsk(request)
            }
            pending.removeValue(forKey: request.id)
            switch reply {
            case .once:
                return
            case .always:
                allowlist.insert(tool)
                return
            case .reject:
                throw PermissionEngineError.rejected(tool: tool)
            }
        }
    }

    /// UI entry point: answer a pending permission request.
    public func reply(_ id: String, _ reply: PermissionReply) {
        pending.removeValue(forKey: id)?.resume(returning: reply)
    }

    /// Reject everything pending (e.g. on abort).
    public func rejectAll() {
        for (_, continuation) in pending {
            continuation.resume(returning: .reject)
        }
        pending.removeAll()
    }
}
