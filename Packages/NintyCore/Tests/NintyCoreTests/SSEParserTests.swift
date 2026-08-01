import Testing
@testable import NintyCore

@Suite("SSEParser")
struct SSEParserTests {
    @Test("parses single-line events")
    func singleLine() {
        var parser = SSEParser()
        let events = parser.feed("data: hello\n\n")
        #expect(events == [SSEEvent(event: nil, data: "hello")])
    }

    @Test("joins multi-line data blocks")
    func multiLine() {
        var parser = SSEParser()
        let events = parser.feed("data: line one\ndata: line two\n\n")
        #expect(events == [SSEEvent(event: nil, data: "line one\nline two")])
    }

    @Test("handles events split across chunks")
    func chunkSplit() {
        var parser = SSEParser()
        #expect(parser.feed("data: hel").isEmpty)
        #expect(parser.feed("lo, wor").isEmpty)
        #expect(parser.feed("ld\n\nda") == [SSEEvent(event: nil, data: "hello, world")])
        #expect(parser.feed("ta: second\n\n") == [SSEEvent(event: nil, data: "second")])
    }

    @Test("ignores comment lines")
    func comments() {
        var parser = SSEParser()
        let events = parser.feed(": keep-alive\ndata: real\n\n")
        #expect(events == [SSEEvent(event: nil, data: "real")])
    }

    @Test("handles CRLF line endings")
    func crlf() {
        var parser = SSEParser()
        let events = parser.feed("data: crlf\r\n\r\n")
        #expect(events == [SSEEvent(event: nil, data: "crlf")])
    }

    @Test("captures event type")
    func eventType() {
        var parser = SSEParser()
        let events = parser.feed("event: message_start\ndata: {}\n\n")
        #expect(events == [SSEEvent(event: "message_start", data: "{}")])
    }

    @Test("flush emits pending event at stream end")
    func flush() {
        var parser = SSEParser()
        _ = parser.feed("data: tail")
        let events = parser.finish()
        #expect(events == [SSEEvent(event: nil, data: "tail")])
    }

    @Test("empty dispatch produces nothing")
    func emptyDispatch() {
        var parser = SSEParser()
        let events = parser.feed("\n\n")
        #expect(events.isEmpty)
    }
}
