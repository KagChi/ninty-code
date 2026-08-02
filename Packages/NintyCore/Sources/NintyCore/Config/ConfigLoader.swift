import Foundation

public enum ConfigError: Error, Sendable, Equatable {
    case malformedJSON(path: String, detail: String)
}

/// Resolved configuration for a project: merged config + project instructions + key store.
public struct ResolvedConfig: Sendable {
    public var config: NintyConfig
    /// Contents of AGENTS.md at project root, if present.
    public var projectInstructions: String?
    public var projectRoot: URL

    public init(config: NintyConfig, projectInstructions: String?, projectRoot: URL) {
        self.config = config
        self.projectInstructions = projectInstructions
        self.projectRoot = projectRoot
    }
}

public struct ConfigLoader: Sendable {
    public static let configDirName = "ninty"
    public static let configFileName = "ninty.json"
    public static let authFileName = "auth.json"
    public static let instructionsFileName = "AGENTS.md"

    

    public init() {}

    public var globalConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent(Self.configDirName)
            .appendingPathComponent(Self.configFileName)
    }

    public var authURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent(Self.configDirName)
            .appendingPathComponent(Self.authFileName)
    }

    public var dataDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share")
            .appendingPathComponent(Self.configDirName)
    }

    /// Load global + project config, merged. Missing files are fine; malformed JSON throws.
    public func load(projectRoot: URL) throws -> ResolvedConfig {
        var merged = NintyConfig()
        if let global = try loadFile(at: globalConfigURL) {
            merged = merged.merging(global)
        }
        if let projectURL = findProjectConfig(from: projectRoot),
           let project = try loadFile(at: projectURL) {
            merged = merged.merging(project)
        }
        let instructions = try? String(
            contentsOf: projectRoot.appendingPathComponent(Self.instructionsFileName),
            encoding: .utf8
        )
        return ResolvedConfig(config: merged, projectInstructions: instructions, projectRoot: projectRoot)
    }

    /// Walk up from `start` looking for the nearest ninty.json.
    public func findProjectConfig(from start: URL) -> URL? {
        let globalConfigDir = globalConfigURL.deletingLastPathComponent().path
        var dir = start.standardizedFileURL
        // Guard on path length: some URL forms yield "/..", "/../.." past root,
        // so `parent == dir` alone is not a reliable termination check.
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent(Self.configFileName)
            if dir.path != globalConfigDir,
               FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path.count >= dir.path.count { return nil }
            dir = parent
        }
        return nil
    }

    private func loadFile(at url: URL) throws -> NintyConfig? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(NintyConfig.self, from: data)
        } catch {
            throw ConfigError.malformedJSON(path: url.path, detail: error.localizedDescription)
        }
    }

    // MARK: - auth.json (API key store, chmod 600)

    /// Read stored API keys: provider id -> key.
    public func readAuth() -> [String: String] {
        guard let data = try? Data(contentsOf: authURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    /// Write (or remove) an API key atomically with 0600 permissions.
    public func writeAuthKey(_ key: String?, for provider: String) throws {
        var keys = readAuth()
        if let key, !key.isEmpty {
            keys[provider] = key
        } else {
            keys.removeValue(forKey: provider)
        }
        let dir = authURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(keys)
        try data.write(to: authURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
    }

    /// Key resolution chain: auth.json -> environment -> config file value.
    public func resolveAPIKey(
        provider: String,
        config: NintyConfig,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let key = readAuth()[provider], !key.isEmpty { return key }
        if let envName = presetKeyEnv(provider: provider), let key = environment[envName], !key.isEmpty {
            return key
        }
        if let key = config.providers[provider]?.apiKey, !key.isEmpty { return key }
        return nil
    }

    private func presetKeyEnv(provider: String) -> String? {
        guard let registry = try? ProviderRegistry.load(),
              let preset = registry.preset(id: provider) else { return nil }
        return preset.keyEnv
    }
}
