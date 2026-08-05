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
    /// Sidebar session cache, keyed by project root (all recents preloaded).
    var sessionsByProject: [URL: [SessionMeta]] = [:]
    /// Sidebar projects showing their session list.
    var expandedProjects: Set<URL> = []

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
    /// Attached image shown in the click-to-preview overlay (data URL).
    var previewAttachment: String?
    /// Right side panel (review/files) — ⇧⌘R, opencode v2 titlebar toggle.
    var showSidePanel = false
    /// Draggable side panel width (persisted).
    var sidePanelWidth: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "sidePanelWidth")
        return saved > 0 ? saved : 480
    }() {
        didSet { UserDefaults.standard.set(Double(sidePanelWidth), forKey: "sidePanelWidth") }
    }
    static let sidePanelWidthRange: ClosedRange<CGFloat> = 320...960
    /// In-app settings dialog (opencode dialog-settings — no native Settings window).
    var showSettings = false
    var settingsSection: SettingsSection = .general

    /// Recent model references, newest first, max 5 (opencode recent-ring).
    var recentModels: [String] = []

    private let configLoader = ConfigLoader()
    private var baseRegistry: ProviderRegistry?
    private var mcpManager: MCPManager?
    /// Keep-alive MCP managers keyed by project root (mixed-project tabs).
    private var mcpManagers: [URL: MCPManager] = [:]

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
        }
        preloadAllProjectSessions()
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
        // Tabs survive project switches (mixed-project tab strip) — each
        // ChatStore carries its own project/provider/MCP references.
        expandedProjects.insert(url)
        preloadAllProjectSessions()
    }

    /// Re-read config + rebuild merged registry (after settings edits). Keeps active chat.
    func reloadConfig() {
        guard let projectRoot else { return }
        resolved = (try? configLoader.load(projectRoot: projectRoot))
            ?? ResolvedConfig(config: NintyConfig(), projectInstructions: nil, projectRoot: projectRoot)
        agents = Agent.all(custom: resolved?.config.agents ?? [:])
        registry = baseRegistry?.merging(config: resolved?.config ?? NintyConfig())
        // Config may change MCP servers — rebuild this project's manager.
        if let old = mcpManagers.removeValue(forKey: projectRoot) {
            Task { await old.stopAll() }
        }
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
        if let projectRoot { reloadSessions(for: projectRoot) }
    }

    /// Refresh one project's session cache; also updates `sessions` when it
    /// is the active project.
    func reloadSessions(for project: URL) {
        let store = SessionStore(projectRoot: project)
        Task { [weak self] in
            let metas = (try? await store.list()) ?? []
            guard let self else { return }
            self.sessionsByProject[project] = metas
            if project == self.projectRoot { self.sessions = metas }
        }
    }

    /// Sidebar: load sessions for every known project into `sessionsByProject`.
    /// Detached — SessionStore IO must not block the main actor.
    func preloadAllProjectSessions() {
        var projects = recentProjects
        if let projectRoot, !projects.contains(projectRoot) { projects.insert(projectRoot, at: 0) }
        Task.detached(priority: .utility) { [weak self] in
            var cache: [URL: [SessionMeta]] = [:]
            for project in projects {
                cache[project] = (try? await SessionStore(projectRoot: project).list()) ?? []
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.sessionsByProject = cache
                if let projectRoot, let metas = cache[projectRoot] {
                    self.sessions = metas
                }
            }
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

    /// Delete a project entirely (sidebar context menu, confirmed): close
    /// its tabs, stop its MCP manager, forget recents/last-project, wipe
    /// its sessions from disk. Active project → fall back to the next
    /// recent, or the no-project state when none remain.
    func removeProject(_ url: URL) {
        for chat in openTabs.filter({ $0.projectRoot == url }) {
            closeTab(chat)
        }
        if let manager = mcpManagers.removeValue(forKey: url) {
            Task { await manager.stopAll() }
        }
        recentProjects.removeAll { $0 == url }
        UserDefaults.standard.set(recentProjects.map(\.path), forKey: "recentProjects")
        sessionsByProject[url] = nil
        expandedProjects.remove(url)
        if projectRoot == url {
            if let next = recentProjects.first {
                openProject(next)
            } else {
                projectRoot = nil
                UserDefaults.standard.removeObject(forKey: "lastProject")
                sessions = []
            }
        }
        Task { try? await SessionStore(projectRoot: url).deleteAll() }
    }

    func newChat() {
        let chat = makeChat(sessionID: UUID().uuidString)
        pushTab(chat)
    }

    /// Open an existing session: restore its saved agent/model selection (opencode per-session persistence).
    /// Already open in a tab → focus that tab instead of a second instance.
    func openChat(_ id: String) {
        if let existing = openTabs.first(where: { $0.sessionID == id }) {
            activateTab(existing)
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

    /// Sidebar: open a session from any project. An existing tab for the
    /// session wins (activate, never duplicate — tabs are mixed). Otherwise:
    /// same project → openChat; foreign → switch project first. Agent/model
    /// restored from the sidebar cache (`reloadSessions` is async, so
    /// `sessions` would miss on a fresh project switch).
    func openSession(_ id: String, in project: URL) {
        if let existing = openTabs.first(where: { $0.sessionID == id }) {
            activateTab(existing)
            return
        }
        guard project != projectRoot else {
            openChat(id)
            return
        }
        let meta = sessionsByProject[project]?.first { $0.id == id }
        openProject(project)
        if let meta {
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
        if let existing = openTabs.first(where: { $0.sessionID == chat.sessionID }) {
            activateTab(existing)
            return
        }
        openTabs.append(chat)
        activateTab(chat)
    }

    func activateTab(_ chat: ChatStore) {
        // Foreign tab: switch project context on the fly, tab stays alive.
        if chat.projectRoot != projectRoot {
            openProject(chat.projectRoot)
        }
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
    /// Provider is rebuilt and swapped too: model id alone would keep streaming
    /// from the old vendor's endpoint.
    func selectModel(_ reference: String) {
        selectedModel = reference
        recentModels.removeAll { $0 == reference }
        recentModels.insert(reference, at: 0)
        if recentModels.count > 5 { recentModels.removeLast(recentModels.count - 5) }
        UserDefaults.standard.set(recentModels, forKey: "recentModels")
        guard let chat = activeChat,
              let registry, let resolved,
              let (providerID, modelID) = ProviderRegistry.split(reference) else { return }
        do {
            let apiKey = configLoader.resolveAPIKey(provider: providerID, config: resolved.config)
            let baseURLOverride = resolved.config.providers[providerID]?.baseURL
            let provider = try registry.makeProvider(
                id: providerID, apiKey: apiKey, baseURLOverride: baseURLOverride
            )
            let catalog = registry.preset(id: providerID)?.models ?? []
            let info = catalog.first { $0.id == modelID }
            chat.setModel(
                provider: provider,
                reference: reference,
                contextWindow: info?.contextWindow ?? 128_000,
                maxOutput: info?.maxOutput ?? 8_192
            )
        } catch {
            lastError = error.localizedDescription
        }
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
                modelReference: selectedModel,
                contextWindow: contextWindow,
                maxOutput: maxOutput,
                projectRoot: projectRoot,
                projectInstructions: resolved.projectInstructions,
                mcpManager: mcpManager,
                onChange: { [weak self] in self?.reloadSessions(for: projectRoot) }
            )
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    // MARK: - MCP

    private func startMCP() {
        guard let projectRoot else { return }
        let configs = resolved?.config.mcp ?? [:]
        guard !configs.isEmpty else {
            mcpManager = nil
            mcpStatuses = [:]
            return
        }
        // Keep-alive: managers are cached per project so foreign tabs never
        // lose their MCP servers on a project switch. Processes die with app.
        let manager: MCPManager
        let isNew: Bool
        if let cached = mcpManagers[projectRoot] {
            manager = cached
            isNew = false
        } else {
            manager = MCPManager(configs: configs)
            mcpManagers[projectRoot] = manager
            isNew = true
        }
        mcpManager = manager
        Task { [weak self] in
            if isNew { await manager.startAll() }
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
