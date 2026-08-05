import AppKit
import SwiftUI
import NintyCore

/// Settings sections (opencode dialog-settings sidebar).
enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case providers = "Providers"
    case mcp = "MCP"
    case logging = "Logging"
    case about = "About"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .providers: return "key"
        case .mcp: return "server.rack"
        case .logging: return "doc.text"
        case .about: return "info.circle"
        }
    }
}

/// opencode dialog-settings: in-app modal — left section sidebar + content pane,
/// same chrome family as ModelDialog. No native Settings window.
struct SettingsDialog: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Theme.borderMuted)
            content
        }
        .frame(width: 720, height: 480)
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.radiusLarge))
        .onExitCommand { appState.showSettings = false }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Settings")
                .font(Theme.smallMedium)
                .foregroundStyle(Theme.textBase)
                .padding(.horizontal, 10)
                .padding(.top, 12)
                .padding(.bottom, 6)
            ForEach(SettingsSection.allCases) { section in
                sidebarRow(section)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: 170)
        .frame(maxHeight: .infinity)
    }

    private func sidebarRow(_ section: SettingsSection) -> some View {
        let selected = appState.settingsSection == section
        return HStack(spacing: 8) {
            Image(systemName: section.icon)
                .font(.system(size: 12))
                .foregroundStyle(selected ? Theme.textBase : Theme.textFaint)
                .frame(width: 16)
            Text(section.rawValue)
                .font(Theme.smallMedium)
                .foregroundStyle(selected ? Theme.textBase : Theme.textMuted)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(selected ? Theme.overlayPressed : .clear, in: .rect(cornerRadius: Theme.radiusSmall))
        .contentShape(Rectangle())
        .onTapGesture { appState.settingsSection = section }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch appState.settingsSection {
                case .general: GeneralPane()
                case .providers: ProvidersPane()
                case .mcp: MCPPane()
                case .logging: LoggingPane()
                case .about: AboutPane()
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Shared building blocks

/// Uppercase tiny section header (ModelDialog style).
private struct PaneHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(Theme.tiny)
            .foregroundStyle(Theme.textFaint)
    }
}

/// Text field on layer02, rounded — replaces native grouped-Form styling.
private struct PaneField: View {
    let label: String
    @Binding var text: String
    var placeholder = ""
    var secure = false
    var onSubmit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(Theme.caption)
                .foregroundStyle(Theme.textMuted)
            Group {
                if secure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(Theme.small)
            .foregroundStyle(Theme.textBase)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.layer02, in: .rect(cornerRadius: Theme.radiusSmall))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).stroke(Theme.borderMuted, lineWidth: 0.5))
            .onSubmit(onSubmit)
        }
    }
}

private struct PaneCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.layer02.opacity(0.5), in: .rect(cornerRadius: Theme.radiusSmall))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).stroke(Theme.borderMuted, lineWidth: 0.5))
    }
}

// MARK: - General

struct GeneralPane: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        PaneHeader(title: "Session")
        PaneCard {
            HStack {
                Text("Default model")
                    .font(Theme.small)
                    .foregroundStyle(Theme.textBase)
                Spacer()
                Picker("", selection: Binding(
                    get: { appState.selectedModel },
                    set: { appState.selectModel($0) }
                )) {
                    ForEach(modelOptions, id: \.self) { reference in
                        Text(reference).tag(reference)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
            }
            Text("Used for new sessions. Switch any time with ⌘'.")
                .font(Theme.caption)
                .foregroundStyle(Theme.textFaint)
        }

        PaneHeader(title: "Behavior")
        PaneCard {
            Toggle(isOn: Binding(
                get: { appState.activeChat?.autoAccept ?? false },
                set: { appState.activeChat?.autoAccept = $0 }
            )) {
                Text("Auto-accept permissions")
                    .font(Theme.small)
                    .foregroundStyle(Theme.textBase)
            }
            .toggleStyle(.checkbox)
            .disabled(appState.activeChat == nil)
            Text("Applies to the active session's permission prompts (⇧⌘A).")
                .font(Theme.caption)
                .foregroundStyle(Theme.textFaint)
        }
    }

    private var modelOptions: [String] {
        guard let registry = appState.registry else { return [] }
        return registry.presets.flatMap { preset in
            preset.models.map { "\(preset.id)/\($0.id)" }
        }
    }
}

// MARK: - Providers

struct ProvidersPane: View {
    @Environment(AppState.self) private var appState
    @State private var keys: [String: String] = [:]
    @State private var baseURLs: [String: String] = [:]
    @State private var customProviders: [CustomProviderDraft] = []
    @State private var testResults: [String: TestState] = [:]

    enum TestState: Equatable {
        case testing, ok(Int), failed(String)
    }

    private var bundledIDs: Set<String> {
        Set(((try? ProviderRegistry.load())?.presets ?? []).map(\.id))
    }

    var body: some View {
        PaneHeader(title: "Built-in Providers")
        if let registry = appState.registry {
            ForEach(registry.presets.filter { bundledIDs.contains($0.id) && $0.id != "custom" }, id: \.id) { preset in
                PaneCard {
                    HStack {
                        Text(preset.name)
                            .font(Theme.smallMedium)
                            .foregroundStyle(Theme.textBase)
                        if !appState.storedAPIKey(for: preset.id).isEmpty {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.success)
                        }
                        Spacer()
                        testButton(providerID: preset.id)
                        testStatus(providerID: preset.id)
                    }
                    if let keyEnv = preset.keyEnv {
                        PaneField(
                            label: "API Key (env: \(keyEnv))",
                            text: binding(for: preset.id),
                            placeholder: "sk-…",
                            secure: true,
                            onSubmit: { save(preset.id) }
                        )
                    }
                    PaneField(
                        label: "Base URL",
                        text: urlBinding(for: preset.id),
                        placeholder: preset.baseURL,
                        onSubmit: { saveBaseURL(preset.id) }
                    )
                }
            }
        }

        PaneHeader(title: "Custom Providers")
        ForEach($customProviders) { $draft in
            CustomProviderCard(
                draft: $draft,
                testState: testResults[draft.id],
                onSave: { saveCustom(draft) },
                onTest: { testProvider(draft.id) },
                onDelete: { deleteCustom(draft.id) }
            )
        }
        Button {
            addCustom()
        } label: {
            Label("Add Provider", systemImage: "plus")
        }
        .buttonStyle(DockButtonStyle(variant: .secondary))
        .controlSize(.small)

        .onAppear { load() }
    }

    @ViewBuilder
    private func testButton(providerID: String) -> some View {
        Button("Test") { testProvider(providerID) }
            .buttonStyle(DockButtonStyle(variant: .ghost))
            .controlSize(.small)
            .disabled(testResults[providerID] == .testing)
    }

    @ViewBuilder
    private func testStatus(providerID: String) -> some View {
        switch testResults[providerID] {
        case .testing:
            ProgressView().controlSize(.mini)
        case .ok(let count):
            Text("OK — \(count) models").font(Theme.caption).foregroundStyle(Theme.success)
        case .failed(let error):
            Text(error).font(Theme.caption).foregroundStyle(Theme.danger).lineLimit(1)
        case nil:
            EmptyView()
        }
    }

    private func testProvider(_ id: String) {
        testResults[id] = .testing
        Task {
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
        Binding(get: { keys[provider] ?? "" }, set: { keys[provider] = $0 })
    }

    private func urlBinding(for provider: String) -> Binding<String> {
        Binding(get: { baseURLs[provider] ?? "" }, set: { baseURLs[provider] = $0 })
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

private struct CustomProviderCard: View {
    @Environment(AppState.self) private var appState
    @Binding var draft: CustomProviderDraft
    let testState: ProvidersPane.TestState?
    let onSave: () -> Void
    let onTest: () -> Void
    let onDelete: () -> Void

    var body: some View {
        PaneCard {
            HStack {
                Text(draft.id)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textFaint)
                Spacer()
                Button("Save", action: onSave)
                    .buttonStyle(DockButtonStyle(variant: .secondary))
                    .controlSize(.small)
                Button("Test", action: onTest)
                    .buttonStyle(DockButtonStyle(variant: .ghost))
                    .controlSize(.small)
                    .disabled(testState == .testing)
                switch testState {
                case .testing:
                    ProgressView().controlSize(.mini)
                case .ok(let count):
                    Text("OK — \(count) models").font(Theme.caption).foregroundStyle(Theme.success)
                case .failed(let error):
                    Text(error).font(Theme.caption).foregroundStyle(Theme.danger).lineLimit(1)
                case nil:
                    EmptyView()
                }
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.danger)
                }
                .buttonStyle(.plain)
            }
            PaneField(label: "Name", text: $draft.name, placeholder: "My Provider", onSubmit: onSave)
            PaneField(label: "Base URL", text: $draft.baseURL, placeholder: "https://host/v1", onSubmit: onSave)
            PaneField(
                label: "API Key (optional)",
                text: Binding(
                    get: { appState.storedAPIKey(for: draft.id) },
                    set: { appState.saveAPIKey($0, for: draft.id) }
                ),
                placeholder: "sk-…",
                secure: true
            )
            PaneField(label: "Model IDs, comma-separated", text: $draft.modelIDs, placeholder: "model-a, model-b", onSubmit: onSave)
        }
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

struct MCPPane: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        PaneHeader(title: "Configured Servers")
        let servers = appState.resolved?.config.mcp ?? [:]
        if servers.isEmpty {
            Text("No MCP servers. Add them to ~/.config/ninty/ninty.json or your project's ninty.json.")
                .font(Theme.caption)
                .foregroundStyle(Theme.textFaint)
        } else {
            ForEach(servers.keys.sorted(), id: \.self) { name in
                PaneCard {
                    HStack {
                        statusIcon(for: name)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name)
                                .font(Theme.smallMedium)
                                .foregroundStyle(Theme.textBase)
                            Text(commandLine(for: name))
                                .font(Theme.caption)
                                .foregroundStyle(Theme.textFaint)
                        }
                        Spacer()
                        Text(statusText(for: name))
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textMuted)
                    }
                }
            }
        }
    }

    private func commandLine(for name: String) -> String {
        guard let config = appState.resolved?.config.mcp[name] else { return "" }
        return config.displayString
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
            Image(systemName: "circle.fill").font(.system(size: 8)).foregroundStyle(Theme.success)
        case .starting:
            ProgressView().controlSize(.mini)
        case .failed:
            Image(systemName: "circle.fill").font(.system(size: 8)).foregroundStyle(Theme.danger)
        case nil:
            Image(systemName: "circle").font(.system(size: 8)).foregroundStyle(Theme.textFaint)
        }
    }
}

// MARK: - Logging

struct LoggingPane: View {
    @Environment(AppState.self) private var appState
    @State private var requestsEnabled = false
    @State private var logSize = ""

    private var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/ninty/logs/provider.log")
    }

    var body: some View {
        PaneHeader(title: "Provider Requests")
        PaneCard {
            Toggle(isOn: $requestsEnabled) {
                Text("Log requests to provider.log")
                    .font(Theme.small)
                    .foregroundStyle(Theme.textBase)
            }
            .toggleStyle(.checkbox)
            .onChange(of: requestsEnabled) { _, value in save(value) }
            Text("Method, URL, status and truncated bodies. API keys are never written. Env override: NINTY_LOG_REQUESTS=1.")
                .font(Theme.caption)
                .foregroundStyle(Theme.textFaint)
        }

        PaneHeader(title: "Log File")
        PaneCard {
            LabeledContent("Path", value: logURL.path)
                .font(Theme.caption)
                .foregroundStyle(Theme.textMuted)
            LabeledContent("Size", value: logSize)
                .font(Theme.caption)
                .foregroundStyle(Theme.textMuted)
            HStack {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([logURL])
                }
                .buttonStyle(DockButtonStyle(variant: .secondary))
                .controlSize(.small)
                Button("Clear") {
                    try? FileManager.default.removeItem(at: logURL)
                    refreshSize()
                }
                .buttonStyle(DockButtonStyle(variant: .ghost))
                .controlSize(.small)
                .disabled(logSize == "0 KB")
            }
        }

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

struct AboutPane: View {
    var body: some View {
        PaneHeader(title: "ninty-code")
        PaneCard {
            LabeledContent("Version", value: "0.1.0")
            LabeledContent("Build", value: "macOS 26+, arm64")
            LabeledContent("License", value: "MIT")
        }
        .font(Theme.small)
        .foregroundStyle(Theme.textMuted)

        PaneHeader(title: "Paths")
        PaneCard {
            LabeledContent("Config", value: "~/.config/ninty/ninty.json")
            LabeledContent("Sessions", value: "~/.local/share/ninty/")
            LabeledContent("Logs", value: "~/.local/share/ninty/logs/")
        }
        .font(Theme.caption)
        .foregroundStyle(Theme.textMuted)

        PaneHeader(title: "Links")
        PaneCard {
            Link("GitHub Repository", destination: URL(string: "https://github.com/KagChi/ninty-code")!)
                .font(Theme.small)
            Link("Report an Issue", destination: URL(string: "https://github.com/KagChi/ninty-code/issues")!)
                .font(Theme.small)
        }
    }
}
