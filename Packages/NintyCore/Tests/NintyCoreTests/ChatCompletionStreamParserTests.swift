import Foundation
import Testing
@testable import NintyCore

@Suite("ChatCompletionStreamParser")
struct ChatCompletionStreamParserTests {
    /// Feed an entire .sse fixture through SSEParser + ChatCompletionStreamParser.
    func parse(fixture: String) throws -> ([StreamEvent], done: Bool) {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/\(fixture)", withExtension: "sse"))
        let text = try String(contentsOf: url, encoding: .utf8)
        var sse = SSEParser()
        var chunks = ChatCompletionStreamParser()
        var events: [StreamEvent] = []
        var done = false
        for event in sse.feed(text) + sse.finish() {
            let result = chunks.handle(data: event.data)
            events.append(contentsOf: result.events)
            done = done || result.done
        }
        return (events, done)
    }

    @Test("simple text stream")
    func simpleText() throws {
        let (events, done) = try parse(fixture: "simple_text")
        #expect(done)
        #expect(events.contains(.textDelta("Hello")))
        #expect(events.contains(.textDelta(", world")))
        #expect(events.contains(.textDelta("!")))
        #expect(events.contains(.usage(input: 12, output: 5)))
        #expect(events.contains(.finish(reason: .stop)))
    }

    @Test("tool call stream accumulates fragments")
    func toolCall() throws {
        let (events, done) = try parse(fixture: "tool_call")
        #expect(done)
        #expect(events.contains(.toolCallStart(id: "call_abc123", name: "read")))
        #expect(events.contains(.toolCallDelta(id: "call_abc123", argumentsFragment: "{\"path\":")))
        #expect(events.contains(.toolCallDelta(id: "call_abc123", argumentsFragment: " \"README.md\"}")))
        #expect(events.contains(.toolCallEnd(id: "call_abc123")))
        #expect(events.contains(.finish(reason: .toolCalls)))
        #expect(events.contains(.usage(input: 50, output: 17)))
    }

    @Test("parallel tool calls tracked independently")
    func parallelToolCalls() throws {
        let (events, done) = try parse(fixture: "parallel_tool_calls")
        #expect(done)
        #expect(events.contains(.toolCallStart(id: "call_one", name: "glob")))
        #expect(events.contains(.toolCallStart(id: "call_two", name: "grep")))
        #expect(events.contains(.toolCallDelta(id: "call_two", argumentsFragment: "\"TODO\"}")))
        #expect(events.contains(.toolCallEnd(id: "call_one")))
        #expect(events.contains(.toolCallEnd(id: "call_two")))
        // Ends emitted before finish.
        let finishIndex = try #require(events.firstIndex(of: .finish(reason: .toolCalls)))
        let endOne = try #require(events.firstIndex(of: .toolCallEnd(id: "call_one")))
        let endTwo = try #require(events.firstIndex(of: .toolCallEnd(id: "call_two")))
        #expect(endOne < finishIndex && endTwo < finishIndex)
    }

    @Test("end of stream closes open tool calls without finish_reason")
    func endOfStreamCleanup() {
        var parser = ChatCompletionStreamParser()
        let chunk = """
        {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_x","function":{"name":"bash","arguments":"{}"}}]}}]}
        """
        let (events, done) = parser.handle(data: chunk)
        #expect(!done)
        #expect(events.contains(.toolCallStart(id: "call_x", name: "bash")))
        let tail = parser.endOfStream()
        #expect(tail.contains(.toolCallEnd(id: "call_x")))
        #expect(tail.contains(.finish(reason: .stop)))
    }

    @Test("malformed data skipped")
    func malformed() {
        var parser = ChatCompletionStreamParser()
        let (events, done) = parser.handle(data: "not json at all")
        #expect(events.isEmpty && !done)
    }

    @Test("[DONE] terminates")
    func doneMarker() {
        var parser = ChatCompletionStreamParser()
        let (_, done) = parser.handle(data: "[DONE]")
        #expect(done)
    }

    @Test("multi-byte UTF-8 survives line-wise decode (no mojibake)")
    func multiByteUTF8() throws {
        // Em-dash (E2 80 94) + CJK + emoji inside streamed content. Feeding the
        // payload through UTF-8 line decode must reproduce the exact string —
        // the old byte-wise Character(UnicodeScalar(byte)) path mangled these.
        let payload = "empty — no commits: 日本語 🚀"
        let chunk = #"{"choices":[{"index":0,"delta":{"content":"# +
            payload.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\t", with: "\\t")
            + #""}}]}"#
        // Simulate the stream loop: UTF-8 bytes → line decode → SSE → chunk parser.
        let line = "data: \(chunk)\n"
        var sse = SSEParser()
        var chunks = ChatCompletionStreamParser()
        var events: [StreamEvent] = []
        for event in sse.feed(line) + sse.finish() {
            events.append(contentsOf: chunks.handle(data: event.data).events)
        }
        #expect(events.contains(.textDelta(payload)))
    }

    @Test("UTF-8 split across network byte chunks reassembles correctly")
    func splitMultiByte() {
        // URLSession.AsyncBytes.lines guarantees this, but pin the contract:
        // decoding only at line boundaries never produces U+FFFD replacements.
        let text = "a — b"
        let bytes = Array(text.utf8)
        // Split inside the em-dash sequence (after first byte E2).
        let splitPoint = bytes.firstIndex(of: 0xE2)! + 1
        let part1 = bytes[..<splitPoint]
        let part2 = bytes[splitPoint...]
        // Wrong way (old bug): byte-wise scalar append.
        var mangled = ""
        for b in part1 + part2 { mangled.append(Character(UnicodeScalar(b))) }
        #expect(mangled != text)
        // Right way: buffer bytes, decode once.
        var buffer: [UInt8] = []
        buffer.append(contentsOf: part1)
        buffer.append(contentsOf: part2)
        #expect(String(decoding: buffer, as: UTF8.self) == text)
    }
}
