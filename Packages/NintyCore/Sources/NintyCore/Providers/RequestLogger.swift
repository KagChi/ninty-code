import Foundation

/// Logs provider HTTP requests/responses to ~/.local/share/ninty/logs/provider.log.
/// Toggle via NintyConfig `logging.requests = true` or env NINTY_LOG_REQUESTS=1.
/// API keys are redacted; bodies truncated to keep the file small.
public actor RequestLogger {
    public static let shared = RequestLogger()

    private let maxBodyChars = 4_096
    private var enabled: Bool?

    private var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/ninty/logs/provider.log")
    }

    private init() {}

    public func setEnabled(_ value: Bool) { enabled = value }

    private func isEnabled() -> Bool {
        if let enabled { return enabled }
        if ProcessInfo.processInfo.environment["NINTY_LOG_REQUESTS"] == "1" { return true }
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ninty/ninty.json")
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(NintyConfig.self, from: data) else { return false }
        return config.logging?.requests ?? false
    }

    /// Log one request line pair. `body`/`responseBody` are raw JSON strings (truncated).
    public func log(
        provider: String,
        method: String,
        url: URL,
        status: Int?,
        requestBody: String?,
        responseBody: String?,
        error: String? = nil
    ) {
        guard isEnabled() else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        var entry = "[\(timestamp)] \(provider) \(method) \(url.absoluteString)"
        if let status { entry += " → \(status)" }
        if let error { entry += " ERROR: \(error)" }
        entry += "\n"
        if let requestBody {
            entry += "  request: \(truncate(requestBody))\n"
        }
        if let responseBody {
            entry += "  response: \(truncate(responseBody))\n"
        }
        write(entry)
    }

    private func truncate(_ s: String) -> String {
        s.count > maxBodyChars ? String(s.prefix(maxBodyChars)) + "…(\(s.count) chars)" : s
    }

    private func write(_ text: String) {
        let url = logURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}
