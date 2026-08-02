import Foundation

/// Single provider implementation for all OpenAI-compatible chat-completions endpoints:
/// OpenAI, Anthropic (compat mode), Google Gemini (compat mode), Ollama, LM Studio, llama.cpp, custom.
public struct OpenAICompatibleProvider: ModelProvider, Sendable {
    public let id: String
    public let baseURL: URL
    public let apiKey: String?
    public let extraHeaders: [String: String]
    public let catalogModels: [ModelInfo]

    private let http: ProviderHTTP

    public init(
        id: String,
        baseURL: URL,
        apiKey: String? = nil,
        extraHeaders: [String: String] = [:],
        catalogModels: [ModelInfo] = [],
        http: ProviderHTTP = ProviderHTTP()
    ) {
        self.id = id
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.extraHeaders = extraHeaders
        self.catalogModels = catalogModels
        self.http = http
    }

    private var headers: [String: String] {
        var headers = extraHeaders
        if let apiKey, !apiKey.isEmpty {
            headers["Authorization"] = "Bearer \(apiKey)"
        }
        return headers
    }

    // MARK: - Model listing

    public func models() async throws -> [ModelInfo] {
        let url = baseURL.appendingPathComponent("models")
        do {
            let data = try await http.getJSON(url: url, headers: headers)
            struct ModelsResponse: Decodable {
                struct Entry: Decodable { var id: String }
                var data: [Entry]
            }
            let response = try JSONDecoder().decode(ModelsResponse.self, from: data)
            let catalogByID = Dictionary(uniqueKeysWithValues: catalogModels.map { ($0.id, $0) })
            return response.data.map { entry in
                catalogByID[entry.id] ?? ModelInfo(
                    id: entry.id, name: entry.id, contextWindow: 128_000, maxOutput: 8_192
                )
            }
        } catch {
            // Endpoint unsupported (e.g. llama.cpp) — fall back to static catalog.
            if catalogModels.isEmpty { throw error }
            return catalogModels
        }
    }

    // MARK: - Streaming

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        let url = baseURL.appendingPathComponent("chat/completions")
        let headers = self.headers
        let body = Self.encodeRequest(request)
        let http = self.http
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, _) = try await http.postStreaming(
                        url: url, headers: headers, body: body,
                        onRetry: { attempt, delay in
                            continuation.yield(.retrying(attempt: attempt, delay: delay))
                        }
                    )
                    var sse = SSEParser()
                    var chunks = ChatCompletionStreamParser()
                    var lineBuffer = ""
                    for try await byte in bytes {
                        if Task.isCancelled { break }
                        lineBuffer.append(Character(UnicodeScalar(byte)))
                        guard byte == UInt8(ascii: "\n") else { continue }
                        for event in sse.feed(lineBuffer) {
                            let result = chunks.handle(data: event.data)
                            result.events.forEach { continuation.yield($0) }
                            if result.done {
                                continuation.finish()
                                return
                            }
                        }
                        lineBuffer = ""
                    }
                    for event in sse.finish() {
                        let result = chunks.handle(data: event.data)
                        result.events.forEach { continuation.yield($0) }
                        if result.done {
                            continuation.finish()
                            return
                        }
                    }
                    chunks.endOfStream().forEach { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Request encoding

    static func encodeRequest(_ request: ChatRequest) -> JSONValue {
        var messages: [JSONValue] = []
        if let system = request.system, !system.isEmpty {
            messages.append(["role": "system", "content": .string(system)])
        }
        for message in request.messages {
            switch message.role {
            case .system:
                let text = message.parts.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined(separator: "\n")
                messages.append(["role": "system", "content": .string(text)])
            case .user:
                let text = message.parts.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined(separator: "\n")
                let images = message.parts.compactMap { if case .image(let dataURL) = $0 { dataURL } else { nil } }
                if images.isEmpty {
                    messages.append(["role": "user", "content": .string(text)])
                } else {
                    // Multipart content: text + image_url entries (OpenAI vision format).
                    var content: [JSONValue] = []
                    if !text.isEmpty { content.append(["type": "text", "text": .string(text)]) }
                    for dataURL in images {
                        content.append([
                            "type": "image_url",
                            "image_url": ["url": .string(dataURL)] as JSONValue
                        ])
                    }
                    messages.append(["role": "user", "content": .array(content)])
                }
            case .assistant:
                let text = message.parts.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined(separator: "\n")
                let toolCalls: [JSONValue] = message.parts.compactMap {
                    if case .toolCall(let id, let name, let arguments) = $0 {
                        return [
                            "id": .string(id),
                            "type": "function",
                            "function": [
                                "name": .string(name),
                                "arguments": .string(Self.encodeArguments(arguments))
                            ] as JSONValue
                        ]
                    }
                    return nil
                }
                var entry: [String: JSONValue] = ["role": "assistant"]
                entry["content"] = text.isEmpty ? .null : .string(text)
                if !toolCalls.isEmpty { entry["tool_calls"] = .array(toolCalls) }
                messages.append(.object(entry))
            case .tool:
                for part in message.parts {
                    if case .toolResult(let id, _, let output, _) = part {
                        messages.append([
                            "role": "tool",
                            "tool_call_id": .string(id),
                            "content": .string(output)
                        ])
                    }
                }
            }
        }

        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "messages": .array(messages),
            "stream": true,
            "stream_options": ["include_usage": true] as JSONValue
        ]
        if !request.tools.isEmpty {
            var tools: [JSONValue] = []
            tools.reserveCapacity(request.tools.count)
            for tool in request.tools {
                let parameters = (try? JSONValue.fromEncodable(tool.parameters)) ?? .object([:])
                let function: JSONValue = [
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "parameters": parameters
                ]
                tools.append(["type": "function", "function": function])
            }
            body["tools"] = .array(tools)
        }
        return .object(body)
    }

    static func encodeArguments(_ value: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

extension JSONValue {
    static func fromEncodable(_ value: some Encodable) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

// MARK: - Wire format

/// Incremental parser for chat.completion.chunk SSE payloads. Pure state machine — testable.
struct ChatCompletionStreamParser {
    private var openToolCalls: [Int: String] = [:] // index -> tool call id
    private var finishEmitted = false

    mutating func handle(data: String) -> (events: [StreamEvent], done: Bool) {
        let data = data.trimmingCharacters(in: .whitespacesAndNewlines)
        if data == "[DONE]" { return ([], true) }
        guard let chunk = try? JSONDecoder().decode(ChatCompletionChunk.self, from: Data(data.utf8)) else {
            return ([], false)
        }
        var events: [StreamEvent] = []
        if let usage = chunk.usage, let input = usage.promptTokens, let output = usage.completionTokens {
            events.append(.usage(input: input, output: output))
        }
        guard let choice = chunk.choices?.first else { return (events, false) }
        if let content = choice.delta?.content, !content.isEmpty {
            events.append(.textDelta(content))
        }
        if let toolCalls = choice.delta?.toolCalls {
            for call in toolCalls {
                if let id = call.id, !id.isEmpty {
                    openToolCalls[call.index] = id
                    events.append(.toolCallStart(id: id, name: call.function?.name ?? ""))
                } else if let id = openToolCalls[call.index],
                          let name = call.function?.name, !name.isEmpty {
                    // Name arriving in a later fragment on some servers.
                    events.append(.toolCallStart(id: id, name: name))
                }
                if let fragment = call.function?.arguments, !fragment.isEmpty,
                   let id = openToolCalls[call.index] {
                    events.append(.toolCallDelta(id: id, argumentsFragment: fragment))
                }
            }
        }
        if let finishReason = choice.finishReason, !finishEmitted {
            finishEmitted = true
            for (_, id) in openToolCalls.sorted(by: { $0.key < $1.key }) {
                events.append(.toolCallEnd(id: id))
            }
            openToolCalls.removeAll()
            events.append(.finish(reason: Self.mapFinishReason(finishReason)))
        }
        return (events, false)
    }

    /// Stream ended without [DONE]/finish_reason — close any open tool calls.
    mutating func endOfStream() -> [StreamEvent] {
        var events: [StreamEvent] = openToolCalls.sorted(by: { $0.key < $1.key }).map { .toolCallEnd(id: $0.value) }
        openToolCalls.removeAll()
        if !finishEmitted {
            finishEmitted = true
            events.append(.finish(reason: .stop))
        }
        return events
    }

    private static func mapFinishReason(_ reason: String) -> FinishReason {
        switch reason {
        case "stop": return .stop
        case "tool_calls", "function_call": return .toolCalls
        case "length", "max_tokens": return .length
        case "content_filter": return .contentFilter
        default: return .unknown
        }
    }
}

struct ChatCompletionChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            struct ToolCall: Decodable {
                var index: Int
                var id: String?
                var function: Function?

                struct Function: Decodable {
                    var name: String?
                    var arguments: String?
                }
            }
            var content: String?
            var toolCalls: [ToolCall]?

            enum CodingKeys: String, CodingKey {
                case content
                case toolCalls = "tool_calls"
            }
        }
        var delta: Delta?
        var finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }
    struct Usage: Decodable {
        var promptTokens: Int?
        var completionTokens: Int?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }
    }
    var choices: [Choice]?
    var usage: Usage?
}
