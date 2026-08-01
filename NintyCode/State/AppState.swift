import Foundation
import Observation
import NintyCore

@Observable
@MainActor
final class AppState {
    // Project
    var projectRoot: URL?
    var recentProjects: [URL] = []

    // Config
    var resolved: ResolvedConfig?
    var registry: ProviderRegistry?

    // Sessions
    var sessions: [SessionMeta] = []
    var activeChat: ChatStore?

    // Agents + models
    var agents: [Agent] = []
    var selectedAgentID = "build"
    var selectedModel: String = ""

    // MCP
    var mcpStatuses: [String: MCPServerStatus] = [:]

    // Errors
    var lastError: String?

    private let configLoader = ConfigLoader()
    private var mcpManager: MCPManager?

    var selectedAgent: Agent {
        agents.first { $0.id == selectedAgentID } ?? .build
    }

    func bootstrap() {
        registry = try? ProviderRegistry.load()
        if let last = UserDefaults.standard.url(forKey: "lastProject") {
            openProject(last)
        }
    }

    // MARK: - Project

    /// NSOpenPanel lives in the UI layer; App calls this via a closure set by the view.
    var pickProjectHandler: () -> Void = {}
    func pickProject() { pickProjectHandler() }

    func openProject(_ url: URL) {
        projectRoot = url
        UserDefaults.standard.set(url, forKey: "lastProject")
        do {
            resolved = try configLoader.load(projectRoot: url)
        } catch {
            lastError = error.localizedDescription
            resolved = ResolvedConfig(config: NintyConfig(), projectInstructions: nil, projectRoot: url)
        }
        agents = Agent.all(custom: resolved?.config.agents ?? [:])
        if selectedModel.isEmpty {
            selectedModel = resolved?.config.model ?? defaultModelReference()
        }
        startMCP()
        reloadSessions()
        activeChat = nil
    }

    func defaultModelReference() -> String {
        guard let registry else { return "anthropic/claude-sonnet-4-5" }
        for preset in registry.presets where !preset.models.isEmpty {
            return "\(preset.id)/\(preset.models[0].id)"
        }
        return "anthropic/claude-sonnet-4-5"
    }

    // MARK: - Sessions

    func reloadSessions() {
        guard let projectRoot else { return }
        let store = SessionStore(projectRoot: projectRoot)
        Task { [weak self] in
            let metas = (try? await store.list()) ?? []
            self?.sessions = metas
        }
    }

    func deleteSession(_ id: String) {
        guard let projectRoot else { return }
        let store = SessionStore(projectRoot: projectRoot)
        Task { [weak self] in
            try? await store.delete(id: id)
            self?.reloadSessions()
        }
    }

    func newChat() {
        activeChat = makeChat(sessionID: UUID().uuidString)
    }

    func openChat(_ id: String) {
        activeChat = makeChat(sessionID: id)
    }

    private func makeChat(sessionID: String) -> ChatStore? {
        guard let projectRoot, let registry, let resolved else { return nil }
        guard let (providerID, modelID) = ProviderRegistry.split(selectedModel) else {
            lastError = "Invalid model reference: \(selectedModel)"
            return nil
        }
        do {
            let apiKey = configLoader.resolveAPIKey(provider: providerID, config: resolved.config)
            let baseURLOverride = resolved.config.providers[providerID]?.baseURL
            let provider = try registry.makeProvider(
                id: providerID, apiKey: apiKey, baseURLOverride: baseURLOverride
            )
            let catalog = registry.preset(id: providerID)?.models ?? []
            let contextWindow = catalog.first { $0.id == modelID }?.contextWindow ?? 128_000
            return ChatStore(
                sessionID: sessionID,
                agent: selectedAgent,
                provider: provider,
                model: modelID,
                contextWindow: contextWindow,
                projectRoot: projectRoot,
                projectInstructions: resolved.projectInstructions,
                mcpManager: mcpManager,
                onChange: { [weak self] in self?.reloadSessions() }
            )
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    // MARK: - MCP

    private func startMCP() {
        let configs = resolved?.config.mcp ?? [:]
        guard !configs.isEmpty else {
            mcpManager = nil
            mcpStatuses = [:]
            return
        }
        let manager = MCPManager(configs: configs)
        mcpManager = manager
        Task { [weak self] in
            await manager.startAll()
            var statuses: [String: MCPServerStatus] = [:]
            for name in await manager.serverNames {
                statuses[name] = await manager.status(for: name)
            }
            self?.mcpStatuses = statuses
        }
    }

    // MARK: - Settings

    func saveAPIKey(_ key: String, for provider: String) {
        do {
            try configLoader.writeAuthKey(key.isEmpty ? nil : key, for: provider)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func storedAPIKey(for provider: String) -> String {
        configLoader.readAuth()[provider] ?? ""
    }
}
