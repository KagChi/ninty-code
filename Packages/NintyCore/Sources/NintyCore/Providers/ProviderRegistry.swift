import Foundation

/// A preset describing how to reach a provider's OpenAI-compatible endpoint.
public struct ProviderPreset: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var baseURL: String
    public var keyEnv: String?
    public var headers: [String: String]
    public var models: [ModelInfo]

    enum CodingKeys: String, CodingKey {
        case id, name, baseURL, keyEnv, headers, models
    }
}

public enum ProviderRegistryError: Error, Sendable, Equatable {
    case unknownProvider(String)
    case invalidBaseURL(String)
}

/// Resolves `provider/model` strings into configured provider instances.
public struct ProviderRegistry: Sendable {
    public let presets: [ProviderPreset]

    public init(presets: [ProviderPreset]) {
        self.presets = presets
    }

    /// Load presets from bundled models.json.
    public static func load() throws -> ProviderRegistry {
        try load(bundle: .module)
    }

    public static func load(bundle: Bundle) throws -> ProviderRegistry {
        guard let url = bundle.url(forResource: "models", withExtension: "json") else {
            throw ProviderRegistryError.unknownProvider("models.json missing from bundle")
        }
        let data = try Data(contentsOf: url)
        struct Root: Decodable { var presets: [ProviderPreset] }
        let root = try JSONDecoder().decode(Root.self, from: data)
        return ProviderRegistry(presets: root.presets)
    }

    public func preset(id: String) -> ProviderPreset? {
        presets.first { $0.id == id }
    }

    /// Apply config: overrides for bundled presets + config-defined custom providers
    /// (any id not in the bundled list, requires baseURL). Enables multiple customs.
    public func merging(config: NintyConfig) -> ProviderRegistry {
        var result: [ProviderPreset] = presets.map { preset in
            guard let override = config.providers[preset.id] else { return preset }
            var merged = preset
            if let baseURL = override.baseURL, !baseURL.isEmpty { merged.baseURL = baseURL }
            if let headers = override.headers {
                merged.headers = preset.headers.merging(headers) { _, new in new }
            }
            if let models = override.models, !models.isEmpty { merged.models = models }
            return merged
        }
        for (id, providerConfig) in config.providers.sorted(by: { $0.key < $1.key })
        where !presets.contains(where: { $0.id == id }) {
            guard let baseURL = providerConfig.baseURL, !baseURL.isEmpty else { continue }
            result.append(ProviderPreset(
                id: id,
                name: providerConfig.name ?? id.capitalized,
                baseURL: baseURL,
                keyEnv: nil,
                headers: providerConfig.headers ?? [:],
                models: providerConfig.models ?? []
            ))
        }
        return ProviderRegistry(presets: result)
    }

    /// Build a provider instance. Key resolution order: explicit key → env var → nil.
    public func makeProvider(
        id: String,
        apiKey: String? = nil,
        baseURLOverride: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> OpenAICompatibleProvider {
        guard let preset = preset(id: id) else {
            throw ProviderRegistryError.unknownProvider(id)
        }
        let urlString = baseURLOverride ?? preset.baseURL
        guard let url = URL(string: urlString) else {
            throw ProviderRegistryError.invalidBaseURL(urlString)
        }
        let resolvedKey = apiKey ?? preset.keyEnv.flatMap { environment[$0] }
        return OpenAICompatibleProvider(
            id: id,
            baseURL: url,
            apiKey: resolvedKey,
            extraHeaders: preset.headers,
            catalogModels: preset.models
        )
    }

    /// Split "provider/model" reference. Provider defaults handled by caller when no slash present.
    public static func split(_ reference: String) -> (provider: String, model: String)? {
        guard let slash = reference.firstIndex(of: "/") else { return nil }
        let provider = String(reference[..<slash])
        let model = String(reference[reference.index(after: slash)...])
        guard !provider.isEmpty, !model.isEmpty else { return nil }
        return (provider, model)
    }
}
