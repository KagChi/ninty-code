import Foundation

/// Parsed Server-Sent Events block.
public struct SSEEvent: Sendable, Equatable {
    public var event: String?
    public var data: String
}

/// Incremental SSE parser. Feed raw string chunks; emits complete events.
/// Handles multi-line data, comment lines, CRLF, and chunk-split input.
public struct SSEParser: Sendable {
    private var buffer = ""
    private var dataLines: [String] = []
    private var eventType: String?

    public init() {}

    /// Feed a chunk of text. Returns any events completed by this chunk.
    public mutating func feed(_ chunk: String) -> [SSEEvent] {
        buffer += chunk
        var events: [SSEEvent] = []
        while let line = nextLine() {
            if let event = processLine(line) {
                events.append(event)
            }
        }
        return events
    }

    /// Flush any pending event at stream end.
    public mutating func finish() -> [SSEEvent] {
        var events: [SSEEvent] = []
        if !buffer.isEmpty {
            if let event = processLine(buffer) { events.append(event) }
            buffer = ""
        }
        if let event = dispatch() { events.append(event) }
        return events
    }

    private mutating func nextLine() -> String? {
        // Support both \n and \r\n terminators.
        guard let range = buffer.rangeOfCharacter(from: .newlines) else { return nil }
        var line = String(buffer[..<range.lowerBound])
        if line.hasSuffix("\r") { line.removeLast() }
        buffer = String(buffer[range.upperBound...])
        return line
    }

    private mutating func processLine(_ line: String) -> SSEEvent? {
        if line.isEmpty {
            return dispatch()
        }
        if line.hasPrefix(":") { return nil } // comment / keep-alive
        if line.hasPrefix("event:") {
            eventType = line.dropFirst(6).trimmingCharacters(in: .init(charactersIn: " "))
        } else if line.hasPrefix("data:") {
            var value = line.dropFirst(5)
            if value.hasPrefix(" ") { value = value.dropFirst() }
            dataLines.append(String(value))
        }
        // id:, retry: ignored
        return nil
    }

    private mutating func dispatch() -> SSEEvent? {
        guard !dataLines.isEmpty else {
            eventType = nil
            return nil
        }
        let event = SSEEvent(event: eventType, data: dataLines.joined(separator: "\n"))
        dataLines = []
        eventType = nil
        return event
    }
}
