import Foundation
import Testing
@testable import NintyCore

@Suite("ProviderRequestEncoding")
struct ProviderRequestEncodingTests {
    @Test("system prompt becomes first message")
    func systemPrompt() {
        let request = ChatRequest(model: "m", system: "You are helpful.", messages: [.user("hi")])
        let body = OpenAICompatibleProvider.encodeRequest(request)
        let messages = body["messages"]?.arrayValue
        #expect(messages?.count == 2)
        #expect(messages?[0]["role"]?.stringValue == "system")
        #expect(messages?[0]["content"]?.stringValue == "You are helpful.")
        #expect(messages?[1]["role"]?.stringValue == "user")
    }

    @Test("assistant tool calls encoded with stringified arguments")
    func assistantToolCalls() {
        let message = Message(role: .assistant, parts: [
            .text("Let me check."),
            .toolCall(id: "call_1", name: "read", arguments: ["path": "README.md"])
        ])
        let request = ChatRequest(model: "m", messages: [message])
        let body = OpenAICompatibleProvider.encodeRequest(request)
        let entry = body["messages"]?.arrayValue?.first
        #expect(entry?["role"]?.stringValue == "assistant")
        #expect(entry?["content"]?.stringValue == "Let me check.")
        let toolCalls = entry?["tool_calls"]?.arrayValue
        #expect(toolCalls?.count == 1)
        #expect(toolCalls?[0]["id"]?.stringValue == "call_1")
        #expect(toolCalls?[0]["type"]?.stringValue == "function")
        let function = toolCalls?[0]["function"]
        #expect(function?["name"]?.stringValue == "read")
        let args = function?["arguments"]?.stringValue
        #expect(args != nil)
        let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(args!.utf8))
        #expect(decoded?["path"]?.stringValue == "README.md")
    }

    @Test("assistant message with only tool calls encodes null content")
    func nullContent() {
        let message = Message(role: .assistant, parts: [
            .toolCall(id: "call_1", name: "bash", arguments: ["command": "ls"])
        ])
        let request = ChatRequest(model: "m", messages: [message])
        let body = OpenAICompatibleProvider.encodeRequest(request)
        let entry = body["messages"]?.arrayValue?.first
        #expect(entry?["content"] == .null)
    }

    @Test("tool results become role:tool messages")
    func toolResults() {
        let message = Message(role: .tool, parts: [
            .toolResult(id: "call_1", name: "read", output: "file contents", isError: false)
        ])
        let request = ChatRequest(model: "m", messages: [message])
        let body = OpenAICompatibleProvider.encodeRequest(request)
        let entry = body["messages"]?.arrayValue?.first
        #expect(entry?["role"]?.stringValue == "tool")
        #expect(entry?["tool_call_id"]?.stringValue == "call_1")
        #expect(entry?["content"]?.stringValue == "file contents")
    }

    @Test("tools array encoded as functions")
    func tools() {
        let request = ChatRequest(
            model: "m",
            messages: [.user("hi")],
            tools: [ToolDefinition(
                name: "read",
                description: "Read a file",
                parameters: .object(properties: ["path": .string("File path")], required: ["path"])
            )]
        )
        let body = OpenAICompatibleProvider.encodeRequest(request)
        let tools = body["tools"]?.arrayValue
        #expect(tools?.count == 1)
        #expect(tools?[0]["type"]?.stringValue == "function")
        let function = tools?[0]["function"]
        #expect(function?["name"]?.stringValue == "read")
        #expect(function?["description"]?.stringValue == "Read a file")
        #expect(function?["parameters"]?["type"]?.stringValue == "object")
        #expect(function?["parameters"]?["required"]?.arrayValue?.first?.stringValue == "path")
    }

    @Test("empty tools omits tools key; stream options included")
    func streamShape() {
        let request = ChatRequest(model: "m", messages: [.user("hi")])
        let body = OpenAICompatibleProvider.encodeRequest(request)
        #expect(body["tools"] == nil)
        #expect(body["stream"]?.boolValue == true)
        #expect(body["stream_options"]?["include_usage"]?.boolValue == true)
    }
}
