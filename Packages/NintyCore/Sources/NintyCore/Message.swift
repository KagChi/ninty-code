import Foundation

public enum Role: String, Codable, Sendable {
    case system, user, assistant, tool
}

public struct Message: Codable, Sendable, Equatable {
    public var role: Role
    public var parts: [Part]
    /// Turn token usage — stamped on the turn's final assistant message.
    /// Optional: older session files simply lack the key.
    public var usage: TokenUsage?
    /// Turn wall-clock duration — stamped alongside usage.
    public var durationMs: Int?

    public enum Part: Codable, Sendable, Equatable {
        case text(String)
        /// Inline image as a data URL (data:<mime>;base64,...).
        case image(dataURL: String)
        case toolCall(id: String, name: String, arguments: JSONValue)
        case toolResult(id: String, name: String, output: String, isError: Bool)

        enum CodingKeys: String, CodingKey { case type, text, dataURL, id, name, arguments, output, isError }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "text":
                self = .text(try container.decode(String.self, forKey: .text))
            case "image":
                self = .image(dataURL: try container.decode(String.self, forKey: .dataURL))
            case "toolCall":
                self = .toolCall(
                    id: try container.decode(String.self, forKey: .id),
                    name: try container.decode(String.self, forKey: .name),
                    arguments: try container.decode(JSONValue.self, forKey: .arguments)
                )
            case "toolResult":
                self = .toolResult(
                    id: try container.decode(String.self, forKey: .id),
                    name: try container.decode(String.self, forKey: .name),
                    output: try container.decode(String.self, forKey: .output),
                    isError: try container.decode(Bool.self, forKey: .isError)
                )
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown part type: \(type)")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let text):
                try container.encode("text", forKey: .type)
                try container.encode(text, forKey: .text)
            case .image(let dataURL):
                try container.encode("image", forKey: .type)
                try container.encode(dataURL, forKey: .dataURL)
            case .toolCall(let id, let name, let arguments):
                try container.encode("toolCall", forKey: .type)
                try container.encode(id, forKey: .id)
                try container.encode(name, forKey: .name)
                try container.encode(arguments, forKey: .arguments)
            case .toolResult(let id, let name, let output, let isError):
                try container.encode("toolResult", forKey: .type)
                try container.encode(id, forKey: .id)
                try container.encode(name, forKey: .name)
                try container.encode(output, forKey: .output)
                try container.encode(isError, forKey: .isError)
            }
        }
    }

    public init(role: Role, parts: [Part], usage: TokenUsage? = nil, durationMs: Int? = nil) {
        self.role = role
        self.parts = parts
        self.usage = usage
        self.durationMs = durationMs
    }

    public static func user(_ text: String) -> Message {
        Message(role: .user, parts: [.text(text)])
    }

    public static func user(_ text: String, images: [String]) -> Message {
        Message(role: .user, parts: [.text(text)] + images.map { .image(dataURL: $0) })
    }

    public static func assistant(_ text: String) -> Message {
        Message(role: .assistant, parts: [.text(text)])
    }
}
