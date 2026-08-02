import SwiftUI
import NintyCore

/// opencode dialog-settings: left sidebar of sections + content pane.
struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var section: SettingsSection = .general

    enum SettingsSection: String, CaseIterable, Identifiable {
        case general = "General"
        case providers = "Providers"
        case mcp = "MCP"
        case logging = "Logging"
        case about = "About"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: return "gear"
            case .providers: return "key"
            case .mcp: return "server.rack"
            case .logging: return "doc.text"
            case .about: return "info.circle"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $section) { item in
                Label(item.rawValue, systemImage: item.icon)
                    .tag(item)
            }
            .listStyle(.sidebar)
            .frame(minWidth: 160)
        } detail: {
            Group {
                switch section {
                case .general: GeneralSettingsView()
                case .providers: ProvidersSettingsView()
                case .mcp: MCPSettingsView()
                case .logging: LoggingSettingsView()
                case .about: AboutSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 680, height: 480)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section("Session") {
                Picker("Default model", selection: Binding(
                    get: { appState.selectedModel },
                    set: { appState.selectModel($0) }
                )) {
                    ForEach(modelOptions, id: \.self) { reference in
                        Text(reference).tag(reference)
                    }
                }
                Text("Used for new sessions. Switch any time with ⌘'.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Behavior") {
                Toggle("Auto-accept permissions (⇧⌘A in session)", isOn: Binding(
                    get: { appState.activeChat?.autoAccept ?? false },
                    set: { appState.activeChat?.autoAccept = $0 }
                ))
                .disabled(appState.activeChat == nil)
                Text("Applies to the active session's permission prompts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var modelOptions: [String] {
        guard let registry = appState.registry else { return [] }
        return registry.presets.flatMap { preset in
            preset.models.map { "\(preset.id)/\($0.id)" }
        }
    }
}

// MARK: - Providers

struct ProvidersSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var keys: [String: String] = [:]
    @State private var baseURLs: [String: String] = [:]
    @State private var customProviders: [CustomProviderDraft] = []
    @State private var testResults: [String: TestState] = [:]

    enum TestState: Equatable {
        case testing, ok(Int), failed(String)
    }

    /// Bundled preset ids — everything else in config is a custom provider.
    private var bundledIDs: Set<String> {
        Set(((try? ProviderRegistry.load())?.presets ?? []).map(\.id))
    }

    var body: some View {
        Form {
            if let registry = appState.registry {
                ForEach(registry.presets.filter { bundledIDs.contains($0.id) && $0.id != "custom" }, id: \.id) { preset in
                    Section {
                        if let keyEnv = preset.keyEnv {
                            LabeledContent {
                                SecureField("API Key (env: \(keyEnv))", text: binding(for: preset.id))
                                    .textContentType(.password)
                                    .onSubmit { save(preset.id) }
                            } label: {
                                Text("API Key")
                            }
                        }
                        LabeledContent("Base URL") {
                            TextField(preset.baseURL, text: urlBinding(for: preset.id))
                                .onSubmit { saveBaseURL(preset.id) }
                        }
                        HStack {
                            testButton(providerID: preset.id)
                            Spacer()
                            testStatus(providerID: preset.id)
                        }
                    } header: {
                        HStack {
                            Text(preset.name)
                            if appState.storedAPIKey(for: preset.id).isEmpty == false {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.caption)
                            }
                        }
                    }
                }
            }

            Section("Custom Providers") {
                ForEach($customProviders) { $draft in
                    CustomProviderRow(
                        draft: $draft,
                        testState: testResults[draft.id],
                        onSave: { saveCustom(draft) },
                        onTest: { testProvider(draft.id) },
                        onDelete: { deleteCustom(draft.id) }
                    )
                }
                Button("Add Provider") { addCustom() }
            }
        }
        .formStyle(.grouped)
        .onAppear { load() }
    }

    @ViewBuilder
    private func testButton(providerID: String) -> some View {
        Button("Test Connection") { testProvider(providerID) }
            .controlSize(.small)
            .disabled(testResults[providerID] == .testing)
    }

    @ViewBuilder
    private func testStatus(providerID: String) -> some View {
        switch testResults[providerID] {
        case .testing:
            ProgressView().controlSize(.mini)
        case .ok(let count):
            Text("OK — \(count) models").font(.caption).foregroundStyle(.green)
        case .failed(let error):
            Text(error).font(.caption).foregroundStyle(.red).lineLimit(1)
        case nil:
            EmptyView()
        }
    }

    private func testProvider(_ id: String) {
        testResults[id] = .testing
        Task {
            defer { if testResults[id] == .testing { testResults[id] = nil } }
            guard let registry = appState.registry, let resolved = appState.resolved else {
                testResults[id] = .failed("not configured")
                return
            }
            do {
                let apiKey = ConfigLoader().resolveAPIKey(provider: id, config: resolved.config)
                let provider = try registry.makeProvider(
                    id: id,
                    apiKey: apiKey,
                    baseURLOverride: resolved.config.providers[id]?.baseURL
                )
                let models = try await provider.models()
                testResults[id] = .ok(models.count)
            } catch {
                testResults[id] = .failed(error.localizedDescription)
            }
        }
    }

    private func binding(for provider: String) -> Binding<String> {
        Binding(
            get: { keys[provider] ?? "" },
            set: { keys[provider] = $0 }
        )
    }

    private func urlBinding(for provider: String) -> Binding<String> {
        Binding(
            get: { baseURLs[provider] ?? "" },
            set: { baseURLs[provider] = $0 }
        )
    }

    private func load() {
        guard let registry = appState.registry else { return }
        let bundled = Set((try? ProviderRegistry.load().presets.map(\.id)) ?? [])
        for preset in registry.presets where bundled.contains(preset.id) {
            keys[preset.id] = appState.storedAPIKey(for: preset.id)
            baseURLs[preset.id] = appState.resolved?.config.providers[preset.id]?.baseURL ?? ""
        }
        customProviders = (appState.resolved?.config.providers ?? [:])
            .filter { !bundled.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { id, config in
                CustomProviderDraft(
                    id: id,
                    name: config.name ?? id,
                    baseURL: config.baseURL ?? "",
                    modelIDs: (config.models ?? []).map(\.id).joined(separator: ", ")
                )
            }
    }

    private func save(_ provider: String) {
        appState.saveAPIKey(keys[provider] ?? "", for: provider)
    }

    private func saveBaseURL(_ provider: String) {
        do {
            var config = GlobalConfigWriter().load()
            var providerConfig = config.providers[provider] ?? ProviderConfig()
            let value = baseURLs[provider]?.trimmingCharacters(in: .whitespaces) ?? ""
            providerConfig.baseURL = value.isEmpty ? nil : value
            config.providers[provider] = providerConfig
            try GlobalConfigWriter().save(config)
            appState.reloadConfig()
        } catch {
            appState.lastError = error.localizedDescription
        }
    }

    private func addCustom() {
        var n = customProviders.count + 1
        while customProviders.contains(where: { $0.id == "custom-\(n)" }) { n += 1 }
        customProviders.append(CustomProviderDraft(id: "custom-\(n)", name: "", baseURL: "", modelIDs: ""))
    }

    private func saveCustom(_ draft: CustomProviderDraft) {
        do {
            var config = GlobalConfigWriter().load()
            let models = draft.modelIDs
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { ModelInfo(id: $0, name: $0, contextWindow: 128_000, maxOutput: 8_192) }
            config.providers[draft.id] = ProviderConfig(
                baseURL: draft.baseURL.trimmingCharacters(in: .whitespaces).nilIfEmpty,
                name: draft.name.trimmingCharacters(in: .whitespaces).nilIfEmpty,
                models: models.isEmpty ? nil : models
            )
            try GlobalConfigWriter().save(config)
            appState.reloadConfig()
            load()
        } catch {
            appState.lastError = error.localizedDescription
        }
    }

    private func deleteCustom(_ id: String) {
        do {
            var config = GlobalConfigWriter().load()
            config.providers.removeValue(forKey: id)
            try GlobalConfigWriter().save(config)
            appState.saveAPIKey("", for: id)
            appState.reloadConfig()
            load()
        } catch {
            appState.lastError = error.localizedDescription
        }
    }
}

struct CustomProviderDraft: Identifiable, Equatable {
    var id: String
    var name: String
    var baseURL: String
    var modelIDs: String
}

struct CustomProviderRow: View {
    @Environment(AppState.self) private var appState
    @Binding var draft: CustomProviderDraft
    let testState: ProvidersSettingsView.TestState?
    let onSave: () -> Void
    let onTest: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(draft.id).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
            TextField("Name", text: $draft.name)
                .onSubmit(onSave)
            TextField("Base URL (e.g. https://host/v1)", text: $draft.baseURL)
                .onSubmit(onSave)
            SecureField("API Key (optional)", text: Binding(
                get: { appState.storedAPIKey(for: draft.id) },
                set: { appState.saveAPIKey($0, for: draft.id) }
            ))
            TextField("Model IDs, comma-separated", text: $draft.modelIDs)
                .onSubmit(onSave)
            HStack {
                Button("Save", action: onSave)
                    .controlSize(.small)
                Button("Test Connection", action: onTest)
                    .controlSize(.small)
                    .disabled(testState == .testing)
                Spacer()
                switch testState {
                case .testing:
                    ProgressView().controlSize(.mini)
                case .ok(let count):
                    Text("OK — \(count) models").font(.caption).foregroundStyle(.green)
                case .failed(let error):
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(1)
                case nil:
                    EmptyView()
                }
            }
        }
        .padding(.vertical, 4)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Reads/writes the global config file atomically.
struct GlobalConfigWriter {
    private var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ninty/ninty.json")
    }

    func load() -> NintyConfig {
        guard let data = try? Data(contentsOf: url) else { return NintyConfig() }
        return (try? JSONDecoder().decode(NintyConfig.self, from: data)) ?? NintyConfig()
    }

    func save(_ config: NintyConfig) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: url, options: .atomic)
    }
}

// MARK: - MCP

struct MCPSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section("Configured Servers") {
                let servers = appState.resolved?.config.mcp ?? [:]
                if servers.isEmpty {
                    Text("No MCP servers. Add them to ~/.config/ninty/ninty.json or your project's ninty.json.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(servers.keys.sorted(), id: \.self) { name in
                        HStack {
                            statusIcon(for: name)
                            VStack(alignment: .leading) {
                                Text(name).fontWeight(.medium)
                                Text(commandLine(for: name))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(statusText(for: name))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func commandLine(for name: String) -> String {
        guard let config = appState.resolved?.config.mcp[name] else { return "" }
        return ([config.command] + config.args).joined(separator: " ")
    }

    private func statusText(for name: String) -> String {
        switch appState.mcpStatuses[name] {
        case .running(let count): return "\(count) tools"
        case .starting: return "starting…"
        case .failed(let error): return "failed: \(error)"
        case nil: return "not started"
        }
    }

    @ViewBuilder
    private func statusIcon(for name: String) -> some View {
        switch appState.mcpStatuses[name] {
        case .running:
            Image(systemName: "circle.fill").foregroundStyle(.green)
        case .starting:
            ProgressView().controlSize(.mini)
        case .failed:
            Image(systemName: "circle.fill").foregroundStyle(.red)
        case nil:
            Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Logging

struct LoggingSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var requestsEnabled = false
    @State private var logSize = ""

    private var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/ninty/logs/provider.log")
    }

    var body: some View {
        Form {
            Section("Provider Requests") {
                Toggle("Log requests to provider.log", isOn: $requestsEnabled)
                    .onChange(of: requestsEnabled) { _, value in
                        save(value)
                    }
                Text("Method, URL, status and truncated bodies. API keys are never written. Env override: NINTY_LOG_REQUESTS=1.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Log File") {
                LabeledContent("Path", value: logURL.path)
                    .font(.caption)
                LabeledContent("Size", value: logSize)
                HStack {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([logURL])
                    }
                    Button("Clear") {
                        try? FileManager.default.removeItem(at: logURL)
                        refreshSize()
                    }
                    .disabled(logSize == "0 KB")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            requestsEnabled = appState.resolved?.config.logging?.requests ?? false
            refreshSize()
        }
    }

    private func save(_ value: Bool) {
        do {
            var config = GlobalConfigWriter().load()
            config.logging = LoggingConfig(requests: value)
            try GlobalConfigWriter().save(config)
            appState.reloadConfig()
        } catch {
            appState.lastError = error.localizedDescription
        }
    }

    private func refreshSize() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = attrs[.size] as? Int else {
            logSize = "0 KB"
            return
        }
        logSize = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

// MARK: - About

struct AboutSettingsView: View {
    var body: some View {
        Form {
            Section("ninty-code") {
                LabeledContent("Version", value: "0.1.0")
                LabeledContent("Build", value: "macOS 26+, arm64")
                LabeledContent("License", value: "MIT")
            }
            Section("Paths") {
                LabeledContent("Config", value: "~/.config/ninty/ninty.json")
                    .font(.caption)
                LabeledContent("Sessions", value: "~/.local/share/ninty/")
                    .font(.caption)
                LabeledContent("Logs", value: "~/.local/share/ninty/logs/")
                    .font(.caption)
            }
            Section {
                Link("GitHub Repository", destination: URL(string: "https://github.com/KagChi/ninty-code")!)
                Link("Report an Issue", destination: URL(string: "https://github.com/KagChi/ninty-code/issues")!)
            }
        }
        .formStyle(.grouped)
    }
}
