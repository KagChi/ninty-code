import Foundation

/// Shared HTTP layer for providers: JSON POST + streaming bytes with retry.
public struct ProviderHTTP: Sendable {
    public var session: URLSession
    private static let maxAttempts = 3
    private static let backoffSeconds: [UInt64] = [1, 2, 4]

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// POST JSON, expecting a streamed response body. Retries on 429/5xx/network errors.
    public func postStreaming(
        url: URL,
        headers: [String: String],
        body: some Encodable & Sendable
    ) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await perform(url: url, headers: headers, body: body)
            } catch let error as ProviderError {
                if attempt >= Self.maxAttempts || !error.isRetryable { throw error }
                try await Task.sleep(nanoseconds: Self.backoffSeconds[min(attempt - 1, 2)] * 1_000_000_000)
            } catch {
                if attempt >= Self.maxAttempts { throw ProviderError.network(error.localizedDescription) }
                try await Task.sleep(nanoseconds: Self.backoffSeconds[min(attempt - 1, 2)] * 1_000_000_000)
            }
        }
    }

    /// GET JSON (e.g. model listing). Single attempt, no retry.
    public func getJSON(url: URL, headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private func perform(
        url: URL,
        headers: [String: String],
        body: some Encodable & Sendable
    ) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = try JSONEncoder().encode(body)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
                if errorBody.count > 4096 { break }
            }
            throw ProviderError.http(status: http.statusCode, body: errorBody)
        }
        return (bytes, http)
    }
}

extension ProviderError {
    var isRetryable: Bool {
        switch self {
        case .http(let status, _): return status == 429 || (500..<600).contains(status)
        case .network: return true
        default: return false
        }
    }
}
