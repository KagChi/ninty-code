import Foundation

public struct ProviderConfig: Codable, Sendable, Equatable {
    public var apiKey: String?
    public var baseURL: String?
    public var headers: [String: String]?
    /// Display name (custom providers only; presets name themselves).
    public var name: String?
    /// Model catalog (custom providers only; presets ship their own).
    public var models: [ModelInfo]?

    public init(
        apiKey: String? = nil,
        baseURL: String? = nil,
        headers: [String: String]? = nil,
        name: String? = nil,
        models: [ModelInfo]? = nil
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.headers = headers
        self.name = name
        self.models = models
    }
}

public struct MCPServerConfig: Codable, Sendable, Equatable {
    /// Stdio transport: executable to spawn. Either this or `url` must be set.
    public var command: String?
    public var args: [String]
    public var env: [String: String]
    /// HTTP transport: remote server endpoint (streamable HTTP, e.g. "https://host/mcp").
    public var url: String?
    /// HTTP transport: extra request headers (e.g. Authorization Bearer).
    public var headers: [String: String]?

    public init(
        command: String? = nil,
        args: [String] = [],
        env: [String: String] = [:],
        url: String? = nil,
        headers: [String: String]? = nil
    ) {
        self.command = command
        self.args = args
        self.env = env
        self.url = url
        self.headers = headers
    }

    private enum CodingKeys: String, CodingKey {
        case command, args, env, url, headers
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        env = try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        url = try container.decodeIfPresent(String.self, forKey: .url)
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers)
    }

    /// Human-readable one-liner for lists/settings.
    public var displayString: String {
        if let url { return url }
        return ([command ?? "?"] + args).joined(separator: " ")
    }
}

public struct AgentConfig: Codable, Sendable, Equatable {
    /// Extra system prompt appended to the base prompt.
    public var prompt: String?
    /// Permission rules: tool pattern -> "allow" | "deny" | "ask". Defaults inherit build agent.
    public var tools: [String: String]?
    /// Model override ("provider/model").
    public var model: String?

    public init(prompt: String? = nil, tools: [String: String]? = nil, model: String? = nil) {
        self.prompt = prompt
        self.tools = tools
        self.model = model
    }
}

/// Root configuration: global + project layers merged.
public struct LoggingConfig: Codable, Sendable, Equatable {
    /// Log provider HTTP requests/responses to ~/.local/share/ninty/logs/provider.log.
    public var requests: Bool

    public init(requests: Bool = false) {
        self.requests = requests
    }
}

public struct NintyConfig: Codable, Sendable, Equatable {
    /// Default model reference "provider/model".
    public var model: String?
    public var providers: [String: ProviderConfig]
    public var mcp: [String: MCPServerConfig]
    public var agents: [String: AgentConfig]
    public var logging: LoggingConfig?

    public init(
        model: String? = nil,
        providers: [String: ProviderConfig] = [:],
        mcp: [String: MCPServerConfig] = [:],
        agents: [String: AgentConfig] = [:],
        logging: LoggingConfig? = nil
    ) {
        self.model = model
        self.providers = providers
        self.mcp = mcp
        self.agents = agents
        self.logging = logging
    }

    /// Deep merge: `override` wins per-key; maps merge recursively.
    public func merging(_ override: NintyConfig) -> NintyConfig {
        NintyConfig(
            model: override.model ?? model,
            providers: providers.merging(override.providers) { base, over in
                ProviderConfig(
                    apiKey: over.apiKey ?? base.apiKey,
                    baseURL: over.baseURL ?? base.baseURL,
                    headers: (base.headers ?? [:]).merging(over.headers ?? [:]) { _, new in new },
                    name: over.name ?? base.name,
                    models: over.models ?? base.models
                )
            },
            mcp: mcp.merging(override.mcp) { _, new in new },
            agents: agents.merging(override.agents) { base, over in
                AgentConfig(
                    prompt: over.prompt ?? base.prompt,
                    tools: (base.tools ?? [:]).merging(over.tools ?? [:]) { _, new in new },
                    model: over.model ?? base.model
                )
            },
            logging: override.logging ?? logging
        )
    }
}
