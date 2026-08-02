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

    // Cached project file paths (for @ mentions) — loaded once per project.
    var projectFiles: [String] = []

    // Agents + models
    var agents: [Agent] = []
    var selectedAgentID = "build"
    var selectedModel: String = ""

    // MCP
    var mcpStatuses: [String: MCPServerStatus] = [:]

    // Errors
    var lastError: String?

    private let configLoader = ConfigLoader()
    private var baseRegistry: ProviderRegistry?
    private var mcpManager: MCPManager?

    var selectedAgent: Agent {
        agents.first { $0.id == selectedAgentID } ?? .build
    }

    func bootstrap() {
        baseRegistry = try? ProviderRegistry.load()
        registry = baseRegistry
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
        registry = baseRegistry?.merging(config: resolved?.config ?? NintyConfig())
        if selectedModel.isEmpty {
            selectedModel = resolved?.config.model ?? defaultModelReference()
        }
        startMCP()
        reloadSessions()
        loadProjectFiles()
        activeChat = nil
    }

    /// Re-read config + rebuild merged registry (after settings edits). Keeps active chat.
    func reloadConfig() {
        guard let projectRoot else { return }
        resolved = (try? configLoader.load(projectRoot: projectRoot))
            ?? ResolvedConfig(config: NintyConfig(), projectInstructions: nil, projectRoot: projectRoot)
        agents = Agent.all(custom: resolved?.config.agents ?? [:])
        registry = baseRegistry?.merging(config: resolved?.config ?? NintyConfig())
        startMCP()
    }

    /// Cache project files for @ mention filtering. Detached + bounded walk — must never
    /// run on MainActor (sync enumeration of a large tree freezes the UI).
    private func loadProjectFiles() {
        guard let projectRoot else { return }
        projectFiles = []
        Task.detached(priority: .utility) { [weak self] in
            let urls = GlobTool.collectFiles(base: projectRoot, keys: [.isDirectoryKey], limit: 2_000) ?? []
            let basePath = projectRoot.resolvingSymlinksInPath().path
            let files = urls.map { url -> String in
                let path = url.resolvingSymlinksInPath().path
                return path.hasPrefix(basePath + "/") ? String(path.dropFirst(basePath.count + 1)) : path
            }
            let state = self
            await MainActor.run { state?.projectFiles = files }
        }
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

    /// Recreate the active chat with the currently selected agent (same session id, history restored).
    func reopenChatWithAgent() {
        guard let id = activeChat?.sessionID else { return }
        activeChat = makeChat(sessionID: id)
    }

    private func makeChat(sessionID: String) -> ChatStore? {
        // Tear down previous chat: cancel its stream + turn so nothing retains the old session.
        if let old = activeChat {
            old.teardown()
        }
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
        // Stop previous manager's spawned server processes before replacing.
        if let old = mcpManager {
            Task { await old.stopAll() }
        }
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
