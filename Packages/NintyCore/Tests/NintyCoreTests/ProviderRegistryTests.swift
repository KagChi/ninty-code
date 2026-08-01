import Foundation
import Testing
@testable import NintyCore

@Suite("ProviderRegistry")
struct ProviderRegistryTests {
    @Test("bundled presets load")
    func loadPresets() throws {
        let registry = try ProviderRegistry.load()
        let ids = registry.presets.map(\.id)
        #expect(ids.contains("openai"))
        #expect(ids.contains("anthropic"))
        #expect(ids.contains("google"))
        #expect(ids.contains("ollama"))
        #expect(ids.contains("lmstudio"))
        #expect(ids.contains("custom"))
    }

    @Test("anthropic preset carries version header")
    func anthropicHeader() throws {
        let registry = try ProviderRegistry.load()
        let preset = try #require(registry.preset(id: "anthropic"))
        #expect(preset.headers["anthropic-version"] == "2023-06-01")
    }

    @Test("api key resolution: explicit > env > nil")
    func keyResolution() throws {
        let registry = try ProviderRegistry.load()
        let explicit = try registry.makeProvider(id: "openai", apiKey: "sk-explicit", environment: ["OPENAI_API_KEY": "sk-env"])
        #expect(explicit.apiKey == "sk-explicit")
        let fromEnv = try registry.makeProvider(id: "openai", environment: ["OPENAI_API_KEY": "sk-env"])
        #expect(fromEnv.apiKey == "sk-env")
        let none = try registry.makeProvider(id: "openai", environment: [:])
        #expect(none.apiKey == nil)
        let local = try registry.makeProvider(id: "ollama", environment: [:])
        #expect(local.apiKey == nil)
        #expect(local.baseURL.absoluteString == "http://localhost:11434/v1")
    }

    @Test("baseURL override wins over preset")
    func baseURLOverride() throws {
        let registry = try ProviderRegistry.load()
        let provider = try registry.makeProvider(id: "custom", baseURLOverride: "http://192.168.1.10:8080/v1")
        #expect(provider.baseURL.absoluteString == "http://192.168.1.10:8080/v1")
    }

    @Test("unknown provider throws")
    func unknownProvider() throws {
        let registry = try ProviderRegistry.load()
        #expect(throws: ProviderRegistryError.self) {
            _ = try registry.makeProvider(id: "does-not-exist")
        }
    }

    @Test("model reference splitting")
    func split() throws {
        let anthropic = try #require(ProviderRegistry.split("anthropic/claude-sonnet-4-5"))
        #expect(anthropic.provider == "anthropic")
        #expect(anthropic.model == "claude-sonnet-4-5")
        let ollama = try #require(ProviderRegistry.split("ollama/qwen3:32b"))
        #expect(ollama.provider == "ollama")
        #expect(ollama.model == "qwen3:32b")
        #expect(ProviderRegistry.split("no-slash") == nil)
        #expect(ProviderRegistry.split("/empty") == nil)
        #expect(ProviderRegistry.split("empty/") == nil)
    }
}
