import SwiftUI
import NintyCore

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        TabView {
            ProvidersSettingsView()
                .tabItem { Label("Providers", systemImage: "key") }
            MCPSettingsView()
                .tabItem { Label("MCP", systemImage: "server.rack") }
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gear") }
        }
        .frame(width: 520, height: 420)
    }
}

// MARK: - Providers

struct ProvidersSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var keys: [String: String] = [:]
    @State private var baseURLs: [String: String] = [:]
    @State private var customProviders: [CustomProviderDraft] = []

    /// Bundled preset ids — everything else in config is a custom provider.
    private var bundledIDs: Set<String> {
        Set(((try? ProviderRegistry.load())?.presets ?? []).map(\.id))
    }

    var body: some View {
        Form {
            if let registry = appState.registry {
                ForEach(registry.presets.filter { bundledIDs.contains($0.id) && $0.id != "custom" }, id: \.id) { preset in
                    Section(preset.name) {
                        if let keyEnv = preset.keyEnv {
                            SecureField("API Key (env: \(keyEnv))", text: binding(for: preset.id))
                                .textContentType(.password)
                                .onSubmit { save(preset.id) }
                        }
                        TextField("Base URL", text: urlBinding(for: preset.id))
                            .onSubmit { saveBaseURL(preset.id) }
                        Text("Default: \(preset.baseURL)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Custom Providers") {
                ForEach($customProviders) { $draft in
                    CustomProviderRow(
                        draft: $draft,
                        onSave: { saveCustom(draft) },
                        onDelete: { deleteCustom(draft.id) }
                    )
                }
                Button("Add Provider") { addCustom() }
            }
        }
        .formStyle(.grouped)
        .onAppear { load() }
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
    let onSave: () -> Void
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
            Button("Save", action: onSave)
                .controlSize(.small)
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

// MARK: - General

struct GeneralSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section("Model") {
                TextField("Default model (provider/model)", text: Binding(
                    get: { appState.selectedModel },
                    set: { appState.selectedModel = $0 }
                ))
                Text("e.g. anthropic/claude-sonnet-4-5, ollama/qwen3")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("About") {
                LabeledContent("Version", value: "0.1.0")
                LabeledContent("Config", value: "~/.config/ninty/ninty.json")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
    }
}
