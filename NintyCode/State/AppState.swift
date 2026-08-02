import Foundation
import AppKit
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
    /// v2 tabs: open chats kept alive in memory (background streams continue).
    var openTabs: [ChatStore] = []
    /// Home overlay (⌘B) — v2 replaces the sidebar with this.
    var showHome = false

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

    // Dialogs
    var showModelDialog = false
    var showCommandPalette = false

    /// Recent model references, newest first, max 5 (opencode recent-ring).
    var recentModels: [String] = []

    private let configLoader = ConfigLoader()
    private var baseRegistry: ProviderRegistry?
    private var mcpManager: MCPManager?

    var selectedAgent: Agent {
        agents.first { $0.id == selectedAgentID } ?? .build
    }

    func bootstrap() {
        baseRegistry = try? ProviderRegistry.load()
        registry = baseRegistry
        recentModels = UserDefaults.standard.stringArray(forKey: "recentModels") ?? []
        recentProjects = (UserDefaults.standard.stringArray(forKey: "recentProjects") ?? [])
            .map { URL(fileURLWithPath: $0) }
        if let last = UserDefaults.standard.url(forKey: "lastProject") {
            openProject(last)
        } else {
            showHome = true
        }
    }

    // MARK: - Project

    /// NSOpenPanel folder picker (async, non-blocking).
    func pickProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Project"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.openProject(url) }
        }
    }

    func openProject(_ url: URL) {
        projectRoot = url
        UserDefaults.standard.set(url, forKey: "lastProject")
        // Track recents (max 8, most-recent first).
        recentProjects.removeAll { $0 == url }
        recentProjects.insert(url, at: 0)
        if recentProjects.count > 8 { recentProjects.removeLast(recentProjects.count - 8) }
        UserDefaults.standard.set(recentProjects.map(\.path), forKey: "recentProjects")
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
        // New project: drop all tabs (sessions belong to the old project).
        for tab in openTabs { tab.teardown() }
        openTabs = []
        activeChat = nil
        showHome = true
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
        let chat = makeChat(sessionID: UUID().uuidString)
        pushTab(chat)
    }

    /// Open an existing session: restore its saved agent/model selection (opencode per-session persistence).
    /// Already open in a tab → focus that tab instead of a second instance.
    func openChat(_ id: String) {
        if let existing = openTabs.first(where: { $0.sessionID == id }) {
            activeChat = existing
            showHome = false
            return
        }
        if let meta = sessions.first(where: { $0.id == id }) {
            if let agent = agents.first(where: { $0.id == meta.agentID }) {
                selectedAgentID = agent.id
            }
            if ProviderRegistry.split(meta.model) != nil {
                selectedModel = meta.model
            }
        }
        pushTab(makeChat(sessionID: id))
    }

    private func pushTab(_ chat: ChatStore?) {
        guard let chat else { return }
        openTabs.append(chat)
        activateTab(chat)
        showHome = false
    }

    func activateTab(_ chat: ChatStore) {
        activeChat = chat
        syncActiveFlags()
        chat.hasUnread = false
        // Restore per-session agent/model selection into the pickers.
        selectedAgentID = chat.agent.id
        if let meta = sessions.first(where: { $0.id == chat.sessionID }),
           ProviderRegistry.split(meta.model) != nil {
            selectedModel = meta.model
        }
    }

    func closeTab(_ chat: ChatStore) {
        guard let index = openTabs.firstIndex(where: { $0.sessionID == chat.sessionID }) else { return }
        chat.teardown()
        openTabs.remove(at: index)
        if activeChat?.sessionID == chat.sessionID {
            if let next = openTabs[safe: min(index, openTabs.count - 1)] {
                activateTab(next)
            } else {
                activeChat = nil
                syncActiveFlags()
                showHome = true
            }
        }
    }

    private func syncActiveFlags() {
        for tab in openTabs { tab.isActive = tab.sessionID == activeChat?.sessionID }
    }

    func moveTab(from: Int, to: Int) {
        guard from != to, openTabs.indices.contains(from), to >= 0, to <= openTabs.count else { return }
        let tab = openTabs.remove(at: from)
        openTabs.insert(tab, at: to > from ? to - 1 : to)
    }

    /// Switch agent on the live chat — in place, no history loss.
    func selectAgent(_ agent: Agent) {
        selectedAgentID = agent.id
        activeChat?.setAgent(agent)
    }

    /// Switch model on the live chat — in place. Explicit selects push to recents.
    func selectModel(_ reference: String) {
        selectedModel = reference
        recentModels.removeAll { $0 == reference }
        recentModels.insert(reference, at: 0)
        if recentModels.count > 5 { recentModels.removeLast(recentModels.count - 5) }
        UserDefaults.standard.set(recentModels, forKey: "recentModels")
        guard let (_, modelID) = ProviderRegistry.split(reference) else { return }
        activeChat?.setModel(modelID)
    }

    /// ⌘. / /agent — cycle to next agent (wrap-around, opencode order = list order).
    func cycleAgent(reverse: Bool = false) {
        guard !agents.isEmpty else { return }
        let current = agents.firstIndex { $0.id == selectedAgentID } ?? 0
        let next = reverse
            ? (current - 1 + agents.count) % agents.count
            : (current + 1) % agents.count
        selectAgent(agents[next])
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
            let info = catalog.first { $0.id == modelID }
            let contextWindow = info?.contextWindow ?? 128_000
            let maxOutput = info?.maxOutput ?? 8_192
            return ChatStore(
                sessionID: sessionID,
                agent: selectedAgent,
                provider: provider,
                model: modelID,
                contextWindow: contextWindow,
                maxOutput: maxOutput,
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

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
