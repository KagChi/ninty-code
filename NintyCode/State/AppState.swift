import Foundation
import AppKit
import Observation
import NintyCore

@Observable
@MainActor
final class AppState {
    // Workspace (multi-root project — VS Code style). folders[0] = primary.
    var workspace: Workspace?
    var workspaces: [Workspace] = []
    /// Primary root of the active workspace (compat convenience for single-root UI).
    var projectRoot: URL? { workspace?.primaryRoot }

    // Config
    var resolved: ResolvedConfig?
    var registry: ProviderRegistry?

    // Sessions
    var sessions: [SessionMeta] = []
    var activeChat: ChatStore?
    /// v2 tabs: open chats kept alive in memory (background streams continue).
    var openTabs: [ChatStore] = []
    /// Sidebar session cache, keyed by workspace id (all workspaces preloaded).
    var sessionsByWorkspace: [String: [SessionMeta]] = [:]
    /// Sidebar workspaces showing their session list.
    var expandedWorkspaces: Set<String> = []

    // Cached workspace file paths (for @ mentions) — loaded once per workspace.
    // Multi-root: paths carry the root folder-name prefix ("api/app/main.py").
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
    /// Workspace create/edit dialog. editingWorkspace nil = creating new.
    var showWorkspaceDialog = false
    var editingWorkspace: Workspace?

    /// Recent model references, newest first, max 5 (opencode recent-ring).
    var recentModels: [String] = []

    private let configLoader = ConfigLoader()
    private let workspaceStore = WorkspaceStore()
    private var baseRegistry: ProviderRegistry?
    private var mcpManager: MCPManager?
    /// Keep-alive MCP managers keyed by workspace id (mixed-workspace tabs).
    private var mcpManagers: [String: MCPManager] = [:]

    var selectedAgent: Agent {
        agents.first { $0.id == selectedAgentID } ?? .build
    }

    func bootstrap() {
        baseRegistry = try? ProviderRegistry.load()
        registry = baseRegistry
        recentModels = UserDefaults.standard.stringArray(forKey: "recentModels") ?? []
        Task { [weak self] in
            guard let self else { return }
            await migrateLegacyRecentsIfNeeded()
            let loaded = await workspaceStore.load()
            workspaces = loaded
            if let lastID = UserDefaults.standard.string(forKey: "lastWorkspaceID"),
               let last = loaded.first(where: { $0.id == lastID }) {
                openWorkspace(last)
            }
            preloadAllWorkspaceSessions()
        }
    }

    // MARK: - Workspace

    /// NSOpenPanel folder picker (async, non-blocking). Picked folder becomes
    /// a single-folder workspace — or focuses the workspace already holding it.
    func pickProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Project"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.addOrOpenWorkspace(folder: url) }
        }
    }

    /// NSOpenPanel picker for "Add Folder to Workspace".
    func pickFolderToAdd(to target: Workspace) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Folder"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.addFolder(url, to: target) }
        }
    }

    func addOrOpenWorkspace(folder: URL) {
        if let existing = workspaces.first(where: { $0.folders.contains(folder) }) {
            openWorkspace(existing)
        } else {
            openWorkspace(Workspace(name: folder.lastPathComponent, folders: [folder]))
        }
    }

    // MARK: - Workspace dialog (create/edit: name, folders, system context)

    func showNewWorkspaceDialog() {
        editingWorkspace = nil
        showWorkspaceDialog = true
    }

    func showEditWorkspaceDialog(_ target: Workspace) {
        editingWorkspace = target
        showWorkspaceDialog = true
    }

    /// Dialog save: upsert. New workspaces open immediately; edits to the
    /// active workspace reload config/instructions + mention files.
    /// Live chats keep their original root set + system context.
    func saveWorkspace(_ saved: Workspace, isNew: Bool) {
        if let index = workspaces.firstIndex(where: { $0.id == saved.id }) {
            workspaces[index] = saved
        } else {
            workspaces.insert(saved, at: 0)
        }
        persistWorkspaces()
        if isNew {
            openWorkspace(saved)
        } else if workspace?.id == saved.id {
            workspace = saved
            reloadAfterFolderChange()
        }
        preloadAllWorkspaceSessions()
    }

    /// Append a folder to a workspace (primary stays first). Active workspace
    /// reloads files + instructions; live chats keep their original roots.
    func addFolder(_ url: URL, to target: Workspace) {
        guard let index = workspaces.firstIndex(where: { $0.id == target.id }),
              !workspaces[index].folders.contains(url) else { return }
        workspaces[index].folders.append(url)
        persistWorkspaces()
        if workspace?.id == target.id {
            workspace = workspaces[index]
            reloadAfterFolderChange()
        }
        preloadAllWorkspaceSessions()
    }

    /// Remove a folder from a workspace. Removing the last remaining folder
    /// deletes the workspace (with its sessions) — same as removeWorkspace.
    func removeFolder(_ url: URL, from target: Workspace) {
        guard let index = workspaces.firstIndex(where: { $0.id == target.id }) else { return }
        guard workspaces[index].folders.count > 1 else {
            removeWorkspace(target)
            return
        }
        workspaces[index].folders.removeAll { $0 == url }
        persistWorkspaces()
        if workspace?.id == target.id {
            workspace = workspaces[index]
            reloadAfterFolderChange()
        }
    }

    func openWorkspace(_ next: Workspace) {
        workspace = next
        UserDefaults.standard.set(next.id, forKey: "lastWorkspaceID")
        // MRU ordering (max 8, most-recent first).
        workspaces.removeAll { $0.id == next.id }
        workspaces.insert(next, at: 0)
        if workspaces.count > 8 { workspaces.removeLast(workspaces.count - 8) }
        persistWorkspaces()
        do {
            resolved = try configLoader.load(roots: next.folders)
        } catch {
            lastError = error.localizedDescription
            resolved = ResolvedConfig(config: NintyConfig(), projectInstructions: nil, projectRoot: next.primaryRoot)
        }
        agents = Agent.all(custom: resolved?.config.agents ?? [:])
        registry = baseRegistry?.merging(config: resolved?.config ?? NintyConfig())
        if selectedModel.isEmpty {
            selectedModel = resolved?.config.model ?? defaultModelReference()
        }
        startMCP()
        reloadSessions()
        loadProjectFiles()
        startFileWatcher(for: next)
        // Tabs survive workspace switches (mixed tab strip) — each ChatStore
        // carries its own roots/provider/MCP references.
        expandedWorkspaces.insert(next.id)
        preloadAllWorkspaceSessions()
    }

    /// Re-read config + rebuild merged registry (after settings edits). Keeps active chat.
    func reloadConfig() {
        guard let workspace else { return }
        resolved = (try? configLoader.load(roots: workspace.folders))
            ?? ResolvedConfig(config: NintyConfig(), projectInstructions: nil, projectRoot: workspace.primaryRoot)
        agents = Agent.all(custom: resolved?.config.agents ?? [:])
        registry = baseRegistry?.merging(config: resolved?.config ?? NintyConfig())
        // Config may change MCP servers — rebuild this workspace's manager.
        if let old = mcpManagers.removeValue(forKey: workspace.id) {
            Task { await old.stopAll() }
        }
        startMCP()
    }

    /// Folder set changed on the active workspace: config/instructions (merged
    /// from all roots) + @-mention cache refresh + live chats adopt the roots.
    private func reloadAfterFolderChange() {
        guard let workspace else { return }
        resolved = (try? configLoader.load(roots: workspace.folders))
            ?? ResolvedConfig(config: NintyConfig(), projectInstructions: nil, projectRoot: workspace.primaryRoot)
        loadProjectFiles()
        startFileWatcher(for: workspace)
        for chat in openTabs where chat.workspaceID == workspace.id {
            chat.updateRoots(workspace.folders)
        }
    }

    private func persistWorkspaces() {
        let snapshot = workspaces
        Task { try? await workspaceStore.save(snapshot) }
    }

    /// First launch after the workspace upgrade: wrap legacy recents into
    /// single-folder workspaces. Legacy ids keep the SessionStore path-hash,
    /// so existing sessions remain readable. Old UserDefaults keys removed.
    private func migrateLegacyRecentsIfNeeded() async {
        let existing = await workspaceStore.load()
        guard existing.isEmpty else { return }
        let recents = (UserDefaults.standard.stringArray(forKey: "recentProjects") ?? [])
            .map { URL(fileURLWithPath: $0) }
        guard !recents.isEmpty else { return }
        var migrated = recents.map(Workspace.legacy(folder:))
        if let last = UserDefaults.standard.url(forKey: "lastProject"),
           let index = migrated.firstIndex(where: { $0.primaryRoot == last }) {
            let ws = migrated.remove(at: index)
            migrated.insert(ws, at: 0)
            UserDefaults.standard.set(ws.id, forKey: "lastWorkspaceID")
        }
        try? await workspaceStore.save(migrated)
        UserDefaults.standard.removeObject(forKey: "recentProjects")
        UserDefaults.standard.removeObject(forKey: "lastProject")
    }

    /// Cache workspace files for @ mention filtering. Detached + bounded walk — must
    /// never run on MainActor. Multi-root: paths prefixed with the root folder name
    /// (ToolContext.mentionPath format); directories keep trailing "/".
    private func loadProjectFiles() {
        guard let workspace else { return }
        projectFiles = []
        let roots = workspace.folders
        Task.detached(priority: .utility) { [weak self] in
            let context = ToolContext(projectRoots: roots, sessionID: "mentions")
            var files: [String] = []
            for root in roots {
                guard files.count < 2_000 else { break }
                let urls = GlobTool.collectFiles(base: root, keys: [.isDirectoryKey], limit: 2_000, includeDirectories: true) ?? []
                for url in urls {
                    let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    var path = context.mentionPath(for: url)
                    if isDir { path += "/" }
                    files.append(path)
                    if files.count >= 2_000 { break }
                }
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

    /// Display label for a "provider/model" reference: the catalog's
    /// ModelInfo.name, falling back to the raw model id for unknown entries.
    func modelLabel(_ reference: String) -> String {
        guard let (providerID, modelID) = ProviderRegistry.split(reference) else { return reference }
        return registry?.preset(id: providerID)?.models.first { $0.id == modelID }?.name ?? modelID
    }

    // MARK: - Sessions

    func reloadSessions() {
        if let workspace { reloadSessions(for: workspace) }
    }

    /// Refresh one workspace's session cache; also updates `sessions` when it
    /// is the active workspace.
    func reloadSessions(for target: Workspace) {
        let store = SessionStore(workspace: target)
        Task { [weak self] in
            let metas = (try? await store.list()) ?? []
            guard let self else { return }
            self.sessionsByWorkspace[target.id] = metas
            if target.id == self.workspace?.id { self.sessions = metas }
        }
    }

    /// Sidebar: load sessions for every known workspace into `sessionsByWorkspace`.
    /// Detached — SessionStore IO must not block the main actor.
    func preloadAllWorkspaceSessions() {
        var targets = workspaces
        if let workspace, !targets.contains(workspace) { targets.insert(workspace, at: 0) }
        Task.detached(priority: .utility) { [weak self] in
            var cache: [String: [SessionMeta]] = [:]
            for target in targets {
                cache[target.id] = (try? await SessionStore(workspace: target).list()) ?? []
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.sessionsByWorkspace = cache
                if let workspace, let metas = cache[workspace.id] {
                    self.sessions = metas
                }
            }
        }
    }

    func deleteSession(_ id: String) {
        guard let workspace else { return }
        let store = SessionStore(workspace: workspace)
        Task { [weak self] in
            try? await store.delete(id: id)
            self?.reloadSessions()
        }
    }

    /// Delete a workspace entirely (sidebar context menu, confirmed): close
    /// its tabs, stop its MCP manager, forget it, wipe its sessions from disk.
    /// Active workspace → fall back to the next one, or the empty state.
    func removeWorkspace(_ target: Workspace) {
        for chat in openTabs.filter({ $0.workspaceID == target.id }) {
            closeTab(chat)
        }
        if let manager = mcpManagers.removeValue(forKey: target.id) {
            Task { await manager.stopAll() }
        }
        workspaces.removeAll { $0.id == target.id }
        persistWorkspaces()
        sessionsByWorkspace[target.id] = nil
        expandedWorkspaces.remove(target.id)
        if workspace?.id == target.id {
            if let next = workspaces.first {
                openWorkspace(next)
            } else {
                workspace = nil
                fileWatcher.stop()
                UserDefaults.standard.removeObject(forKey: "lastWorkspaceID")
                sessions = []
            }
        }
        Task { try? await SessionStore(workspace: target).deleteAll() }
    }

    func newChat() {
        let chat = makeChat(sessionID: UUID().uuidString)
        pushTab(chat)
    }

    /// Sidebar context menu: new session inside a specific workspace
    /// (switches to it first when foreign).
    func newChat(in target: Workspace) {
        if workspace?.id != target.id { openWorkspace(target) }
        newChat()
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

    /// Sidebar: open a session from any workspace. An existing tab for the
    /// session wins (activate, never duplicate — tabs are mixed). Otherwise:
    /// same workspace → openChat; foreign → switch workspace first. Agent/model
    /// restored from the sidebar cache (`reloadSessions` is async, so
    /// `sessions` would miss on a fresh workspace switch).
    func openSession(_ id: String, in target: Workspace) {
        if let existing = openTabs.first(where: { $0.sessionID == id }) {
            activateTab(existing)
            return
        }
        guard target.id != workspace?.id else {
            openChat(id)
            return
        }
        let meta = sessionsByWorkspace[target.id]?.first { $0.id == id }
        openWorkspace(target)
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
        // Foreign tab: switch workspace context on the fly, tab stays alive.
        if chat.workspaceID != workspace?.id,
           let target = workspaces.first(where: { $0.id == chat.workspaceID }) {
            openWorkspace(target)
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
        guard let workspace, let registry, let resolved else { return nil }
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
            // AGENTS.md (all roots, via ConfigLoader) + per-workspace system context.
            let instructions = [resolved.projectInstructions, workspace.systemContext]
                .compactMap { value -> String? in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                }
                .joined(separator: "\n\n")
            let chat = ChatStore(
                sessionID: sessionID,
                agent: selectedAgent,
                provider: provider,
                model: modelID,
                modelReference: selectedModel,
                contextWindow: contextWindow,
                maxOutput: maxOutput,
                workspaceID: workspace.id,
                workspaceName: workspace.name,
                projectRoots: workspace.folders,
                projectInstructions: instructions.isEmpty ? nil : instructions,
                mcpManager: mcpManager,
                onChange: { [weak self] in self?.reloadSessions(for: workspace) }
            )
            chat.onChangedFiles = { [weak self] paths in
                guard let self, let workspace = self.workspace else { return }
                Task {
                    await self.ensureGraphSync().scheduleIncremental(
                        workspace: workspace.id,
                        roots: workspace.folders,
                        changedPaths: paths
                    )
                }
            }
            return chat
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    // MARK: - MCP

    private func startMCP() {        guard let workspace else { return }
        let configs = (resolved?.config.mcp ?? [:]).filter(\.value.enabled)
        guard !configs.isEmpty else {
            mcpManager = nil
            mcpStatuses = [:]
            return
        }
        // Keep-alive: managers are cached per workspace so foreign tabs never
        // lose their MCP servers on a workspace switch. Processes die with app.
        let manager: MCPManager
        let isNew: Bool
        if let cached = mcpManagers[workspace.id] {
            manager = cached
            isNew = false
        } else {
            manager = MCPManager(configs: configs)
            mcpManagers[workspace.id] = manager
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
            // Graph sync kicks once MCP tools are bridged (no-op without a
            // graph server in config).
            if let self, let workspace = self.workspace {
                _ = await self.ensureGraphSync().syncFull(workspace: workspace.id, roots: workspace.folders)
            }
        }
    }

    // MARK: - Graph sync

    /// Live sync status for the Graph tab ("Upserting 120/385 files · loader.rs").
    /// Nil when idle.
    private(set) var graphSyncStatus: String?
    /// Determinate sync fraction (0...1) for the progress bar; nil =
    /// indeterminate phase (extracting) or idle.
    private(set) var graphSyncProgress: Double?
    /// Last completed sync attempt (toolbar "synced Xs ago").
    private(set) var graphLastSynced: Date?

    private var graphSync: GraphSyncService?

    /// Keeps the graph index fresh when files change outside the app
    /// (editor edits, git pulls) — debounced full sync (stamp-skip makes
    /// it cheap: only touched files re-extract).
    private let fileWatcher = WorkspaceFileWatcher()

    private func startFileWatcher(for target: Workspace) {
        let targetID = target.id
        fileWatcher.start(roots: target.folders) { [weak self] in
            guard let self, self.workspace?.id == targetID,
                  let workspace = self.workspace else { return }
            await self.ensureGraphSync().syncFull(workspace: workspace.id, roots: workspace.folders)
        }
    }

    private func ensureGraphSync() -> GraphSyncService {
        if let graphSync { return graphSync }
        let service = GraphSyncService(upsert: { [weak self] payload in
            await self?.callGraphUpsert(payload) ?? false
        }, progress: { [weak self] phase in
            let label: String?
            let progress: Double?
            switch phase {
            case .none:
                label = nil
                progress = nil
            case .extracting:
                label = "Extracting symbols…"
                progress = nil // indeterminate
            case .upserting(let done, let total, let lastFile):
                let file = lastFile.map { " · \($0)" } ?? ""
                label = total > 0 ? "Upserting \(done)/\(total) files\(file)" : "Upserting…"
                progress = total > 0 ? Double(done) / Double(total) : nil
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.graphSyncStatus = label
                self.graphSyncProgress = progress
                // A nil phase means the sync attempt finished (success is
                // tracked separately by callers); stamp for "synced Xs ago".
                if phase == nil { self.graphLastSynced = Date() }
            }
        })
        graphSync = service
        return service
    }

    /// Execute the bridged `graph:graph_upsert` MCP tool for a workspace.
    /// Returns false when no graph server is configured/bridged.
    private func callGraphUpsert(_ payload: GraphUpsertPayload) async -> Bool {
        guard let manager = mcpManagers[payload.workspace] else { return false }
        let tools = await manager.bridgedTools()
        guard let tool = tools.first(where: { $0.name == "graph:graph_upsert" }) else { return false }
        do {
            let data = try JSONEncoder().encode(payload)
            let args = try JSONDecoder().decode(JSONValue.self, from: data)
            let roots = workspaces.first { $0.id == payload.workspace }?.folders ?? []
            let result = try await tool.execute(args, ctx: ToolContext(projectRoots: roots, sessionID: "graph-sync"))
            return !result.isError
        } catch {
            return false
        }
    }

    /// Execute any bridged MCP tool for the active workspace and parse its
    /// JSON output. `tool` is the bare tool name (e.g. "graph_subgraph",
    /// "search_memories") matched by `":<tool>"` suffix, so the server's
    /// config key is free. Graph tools get the `workspace` param they all
    /// require injected automatically; caller args win on conflict.
    func callMCPTool(_ tool: String, _ args: [String: JSONValue] = [:]) async -> Result<JSONValue, MCPToolError> {
        guard let workspace, let manager = mcpManagers[workspace.id] else {
            return .failure(.serverUnavailable)
        }
        guard let bridged = await manager.bridgedTools().first(where: { $0.name.hasSuffix(":\(tool)") }) else {
            return .failure(.toolNotBridged(tool))
        }
        var merged = args
        if tool.hasPrefix("graph_"), merged["workspace"] == nil {
            merged["workspace"] = .string(workspace.id)
        }
        do {
            let result = try await bridged.execute(
                .object(merged),
                ctx: ToolContext(projectRoots: workspace.folders, sessionID: "mcp-ui")
            )
            guard !result.isError else { return .failure(.toolFailed(result.output)) }
            guard let data = result.output.data(using: .utf8) else {
                return .failure(.invalidOutput("Invalid UTF-8 in tool output"))
            }
            do {
                return .success(try JSONDecoder().decode(JSONValue.self, from: data))
            } catch {
                return .failure(.invalidOutput("JSON decode failed: \(error.localizedDescription)"))
            }
        } catch {
            return .failure(.toolFailed(error.localizedDescription))
        }
    }

    /// Whether a tool with this bare name is bridged for the active workspace.
    func mcpToolAvailable(_ tool: String) async -> Bool {
        guard let workspace, let manager = mcpManagers[workspace.id] else { return false }
        return await manager.bridgedTools().contains { $0.name.hasSuffix(":\(tool)") }
    }

    /// `callMCPTool` raced against a deadline — nil = timed out. Slow remote
    /// servers must not hang the Graph tab forever (lazy-load stages use this).
    func callMCPTool(_ tool: String, _ args: [String: JSONValue], timeout seconds: Double) async -> Result<JSONValue, MCPToolError>? {
        let worker = Task { @MainActor [weak self] in
            await self?.callMCPTool(tool, args)
        }
        let deadline = Task {
            try? await Task.sleep(for: .seconds(seconds))
            worker.cancel() // URLSession-backed transports honor cancellation
        }
        let result = await worker.value
        deadline.cancel()
        return worker.isCancelled ? nil : result
    }

    /// Poll until a bridged tool appears (MCP connect is async at app start)
    /// or give up after ~10s. Tabs call this before showing "unavailable".
    func waitForMCPTool(_ tool: String) async -> Bool {
        for _ in 0..<20 {
            if await mcpToolAvailable(tool) { return true }
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return false }
        }
        return await mcpToolAvailable(tool)
    }

    /// Manual resync: force re-extract + re-upsert every source file.
    /// Returns false when no graph server is bridged or an upsert failed.
    @discardableResult
    func resyncGraph() async -> Bool {
        guard let workspace else { return false }
        return await ensureGraphSync().syncFull(workspace: workspace.id, roots: workspace.folders, force: true) != nil
    }

    /// Enable/disable an MCP server: persists the flag to the global config,
    /// then restarts the active workspace's manager (disabled servers drop
    /// their connections; enabled ones reconnect).
    func setMCPServerEnabled(_ name: String, _ enabled: Bool) {
        do {
            var config = GlobalConfigWriter().load()
            guard var server = config.mcp[name] else { return }
            server.enabled = enabled
            config.mcp[name] = server
            try GlobalConfigWriter().save(config)
            reloadConfig()
            guard let workspace else { return }
            if let manager = mcpManagers.removeValue(forKey: workspace.id) {
                Task { await manager.stopAll() }
            }
            mcpStatuses = [:]
            startMCP()
        } catch {
            lastError = error.localizedDescription
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

/// Failure of a bridged MCP tool call, surfaced in side-panel tabs.
enum MCPToolError: Error, LocalizedError {
    case serverUnavailable
    case toolNotBridged(String)
    case toolFailed(String)
    case invalidOutput(String)

    var errorDescription: String? {
        switch self {
        case .serverUnavailable:
            "No graph server connected for this workspace"
        case .toolNotBridged(let name):
            "Tool \(name) is not bridged"
        case .toolFailed(let message), .invalidOutput(let message):
            message
        }
    }
}
