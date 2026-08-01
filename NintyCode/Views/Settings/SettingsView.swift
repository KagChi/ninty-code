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

    var body: some View {
        Form {
            if let registry = appState.registry {
                ForEach(registry.presets, id: \.id) { preset in
                    Section(preset.name) {
                        if preset.keyEnv != nil {
                            SecureField("API Key (env: \(preset.keyEnv!))", text: binding(for: preset.id))
                                .textContentType(.password)
                                .onSubmit { save(preset.id) }
                        } else if preset.id == "custom" {
                            SecureField("API Key (optional)", text: binding(for: preset.id))
                                .onSubmit { save(preset.id) }
                        }
                        TextField("Base URL", text: urlBinding(for: preset.id))
                            .onSubmit { saveBaseURL(preset.id) }
                        if preset.id != "custom" {
                            Text("Default: \(preset.baseURL)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
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
        for preset in registry.presets {
            keys[preset.id] = appState.storedAPIKey(for: preset.id)
            baseURLs[preset.id] = appState.resolved?.config.providers[preset.id]?.baseURL ?? ""
        }
    }

    private func save(_ provider: String) {
        appState.saveAPIKey(keys[provider] ?? "", for: provider)
    }

    private func saveBaseURL(_ provider: String) {
        // Base URLs live in global ninty.json — write via config loader.
        do {
            var config = appState.resolved?.config ?? NintyConfig()
            var providerConfig = config.providers[provider] ?? ProviderConfig()
            let value = baseURLs[provider]?.trimmingCharacters(in: .whitespaces) ?? ""
            providerConfig.baseURL = value.isEmpty ? nil : value
            config.providers[provider] = providerConfig
            try GlobalConfigWriter().save(config)
        } catch {
            appState.lastError = error.localizedDescription
        }
    }
}

/// Writes the global config file atomically.
struct GlobalConfigWriter {
    func save(_ config: NintyConfig) throws {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ninty/ninty.json")
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
