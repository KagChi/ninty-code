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
        body: some Encodable & Sendable,
        onRetry: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await perform(url: url, headers: headers, body: body)
            } catch let error as ProviderError {
                if attempt >= Self.maxAttempts || !error.isRetryable { throw error }
                let delay = Int(Self.backoffSeconds[min(attempt - 1, 2)])
                onRetry?(attempt, delay)
                try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            } catch {
                if attempt >= Self.maxAttempts {
                    await RequestLogger.shared.log(
                        provider: url.host ?? "provider", method: "POST", url: url,
                        status: nil, requestBody: nil, responseBody: nil,
                        error: error.localizedDescription
                    )
                    throw ProviderError.network(error.localizedDescription)
                }
                let delay = Int(Self.backoffSeconds[min(attempt - 1, 2)])
                onRetry?(attempt, delay)
                try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
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
        let bodyData = try JSONEncoder().encode(body)
        request.httpBody = bodyData

        let requestBody = String(data: bodyData, encoding: .utf8)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            await RequestLogger.shared.log(
                provider: providerName(from: url), method: "POST", url: url,
                status: nil, requestBody: requestBody, responseBody: nil,
                error: "non-HTTP response"
            )
            throw ProviderError.invalidResponse("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
                if errorBody.count > 4096 { break }
            }
            await RequestLogger.shared.log(
                provider: providerName(from: url), method: "POST", url: url,
                status: http.statusCode, requestBody: requestBody, responseBody: errorBody
            )
            throw ProviderError.http(status: http.statusCode, body: errorBody)
        }
        await RequestLogger.shared.log(
            provider: providerName(from: url), method: "POST", url: url,
            status: http.statusCode, requestBody: requestBody, responseBody: nil
        )
        return (bytes, http)
    }

    /// Host name doubles as the log's provider tag — presets hit distinct hosts.
    private func providerName(from url: URL) -> String {
        url.host ?? "provider"
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
