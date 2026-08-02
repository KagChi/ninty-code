import Foundation

public struct ToolDefinition: Sendable, Equatable {
    public var name: String
    public var description: String
    public var parameters: JSONSchema

    public init(name: String, description: String, parameters: JSONSchema) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct ModelInfo: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var contextWindow: Int
    public var maxOutput: Int
    public var supportsTools: Bool

    public init(id: String, name: String, contextWindow: Int, maxOutput: Int, supportsTools: Bool = true) {
        self.id = id
        self.name = name
        self.contextWindow = contextWindow
        self.maxOutput = maxOutput
        self.supportsTools = supportsTools
    }
}

public struct ChatRequest: Sendable {
    public var model: String
    public var system: String?
    public var messages: [Message]
    public var tools: [ToolDefinition]

    public init(model: String, system: String? = nil, messages: [Message], tools: [ToolDefinition] = []) {
        self.model = model
        self.system = system
        self.messages = messages
        self.tools = tools
    }
}

public enum FinishReason: String, Sendable {
    case stop, toolCalls, length, contentFilter, unknown
}

public enum StreamEvent: Sendable, Equatable {
    case textDelta(String)
    case toolCallStart(id: String, name: String)
    case toolCallDelta(id: String, argumentsFragment: String)
    case toolCallEnd(id: String)
    case usage(input: Int, output: Int)
    case finish(reason: FinishReason)
    /// HTTP retry in progress (attempt number, seconds until next try).
    case retrying(attempt: Int, delay: Int)
}

public enum ProviderError: Error, Sendable, Equatable {
    case http(status: Int, body: String)
    case invalidResponse(String)
    case missingAPIKey(provider: String)
    case network(String)
}

extension ProviderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .http(let status, let body):
            let trimmed = body.prefix(300)
            return trimmed.isEmpty ? "Provider returned HTTP \(status)" : "Provider returned HTTP \(status): \(trimmed)"
        case .invalidResponse(let detail):
            return "Invalid provider response: \(detail.prefix(300))"
        case .missingAPIKey(let provider):
            return "No API key configured for provider \"\(provider)\""
        case .network(let detail):
            return "Network error: \(detail.prefix(300))"
        }
    }
}

public protocol ModelProvider: Sendable {
    var id: String { get }
    func models() async throws -> [ModelInfo]
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error>
}
