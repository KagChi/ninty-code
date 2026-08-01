import Foundation
import Testing
@testable import NintyCore

@Suite("NintyConfig")
struct NintyConfigTests {
    @Test("deep merge: project overrides global scalars, maps merge per-key")
    func deepMerge() {
        let global = NintyConfig(
            model: "openai/gpt-5",
            providers: [
                "openai": ProviderConfig(apiKey: "sk-global", baseURL: "https://api.openai.com/v1"),
                "ollama": ProviderConfig(baseURL: "http://localhost:11434/v1")
            ],
            mcp: ["a": MCPServerConfig(command: "a-cmd")],
            agents: ["reviewer": AgentConfig(prompt: "Be thorough.", tools: ["bash": "ask"])]
        )
        let project = NintyConfig(
            model: "anthropic/claude-sonnet-4-5",
            providers: ["openai": ProviderConfig(baseURL: "https://proxy.example.com/v1")],
            mcp: ["b": MCPServerConfig(command: "b-cmd")],
            agents: ["reviewer": AgentConfig(tools: ["bash": "deny", "edit": "ask"])]
        )
        let merged = global.merging(project)
        #expect(merged.model == "anthropic/claude-sonnet-4-5")
        // Provider: baseURL overridden, apiKey inherited.
        let openai = merged.providers["openai"]
        #expect(openai?.baseURL == "https://proxy.example.com/v1")
        #expect(openai?.apiKey == "sk-global")
        // Untouched provider survives.
        #expect(merged.providers["ollama"]?.baseURL == "http://localhost:11434/v1")
        // MCP maps union.
        #expect(Set(merged.mcp.keys) == ["a", "b"])
        // Agent tools merge, prompt inherited.
        let reviewer = merged.agents["reviewer"]
        #expect(reviewer?.prompt == "Be thorough.")
        #expect(reviewer?.tools == ["bash": "deny", "edit": "ask"])
    }

    @Test("Codable roundtrip")
    func codable() throws {
        let config = NintyConfig(
            model: "ollama/qwen3",
            providers: ["ollama": ProviderConfig(baseURL: "http://localhost:11434/v1")],
            mcp: ["fs": MCPServerConfig(command: "npx", args: ["-y", "fs-mcp"], env: ["A": "1"])],
            agents: ["plan": AgentConfig(prompt: "p", tools: ["bash": "ask"], model: "openai/gpt-5")]
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(NintyConfig.self, from: data)
        #expect(decoded == config)
    }
}

@Suite("ConfigLoader")
struct ConfigLoaderTests {
    func withTempDir(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ninty-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    @Test("findProjectConfig walks up to nearest ninty.json")
    func walkUp() throws {
        try withTempDir { root in
            let nested = root.appendingPathComponent("a/b/c")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let configURL = root.appendingPathComponent("a").appendingPathComponent("ninty.json")
            try "{}".write(to: configURL, atomically: true, encoding: .utf8)
            let loader = ConfigLoader()
            #expect(loader.findProjectConfig(from: nested) == configURL)
        }
    }

    @Test("findProjectConfig returns nil when absent")
    func walkUpMissing() throws {
        try withTempDir { root in
            let loader = ConfigLoader()
            #expect(loader.findProjectConfig(from: root) == nil)
        }
    }

    @Test("load picks up AGENTS.md instructions")
    func instructions() throws {
        try withTempDir { root in
            try "# Rules\nDo the thing.".write(
                to: root.appendingPathComponent("AGENTS.md"),
                atomically: true, encoding: .utf8
            )
            let resolved = try ConfigLoader().load(projectRoot: root)
            #expect(resolved.projectInstructions == "# Rules\nDo the thing.")
        }
    }

    @Test("malformed project config throws")
    func malformed() throws {
        try withTempDir { root in
            try "{ not json".write(
                to: root.appendingPathComponent("ninty.json"),
                atomically: true, encoding: .utf8
            )
            #expect(throws: ConfigError.self) {
                _ = try ConfigLoader().load(projectRoot: root)
            }
        }
    }
}
