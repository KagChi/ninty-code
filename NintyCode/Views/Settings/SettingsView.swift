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
    @State private var savedBaseURLs: [String: String] = [:]
    @State private var customProviders: [CustomProviderDraft] = []
    @State private var testResults: [String: TestState] = [:]
    @State private var expandedTests: Set<String> = []

    enum TestState: Equatable {
        case testing, ok([String]), failed(String)
    }

    private var bundledIDs: Set<String> {
        Set(((try? ProviderRegistry.load())?.presets ?? []).map(\.id))
    }

    var body: some View {
        PaneHeader(title: "Built-in Providers")
        if let registry = appState.registry {
            ForEach(registry.presets.filter { bundledIDs.contains($0.id) && $0.id != "custom" }, id: \.id) { preset in
                BuiltinProviderCard(
                    preset: preset,
                    keyText: binding(for: preset.id),
                    urlText: urlBinding(for: preset.id),
                    urlDirty: (baseURLs[preset.id] ?? "") != (savedBaseURLs[preset.id] ?? ""),
                    urlError: urlError(baseURLs[preset.id] ?? ""),
                    testState: testResults[preset.id],
                    expanded: expandedTests.contains(preset.id),
                    onSaveKey: { save(preset.id) },
                    onSaveURL: { saveBaseURL(preset.id) },
                    onTest: { testProvider(preset.id) },
                    onToggleExpand: { toggleExpand(preset.id) }
                )
            }
        }

        PaneHeader(title: "Custom Providers")
        ForEach($customProviders) { $draft in
            CustomProviderCard(
                draft: $draft,
                existingIDs: Set(customProviders.map(\.id)).subtracting([draft.id]).union(bundledIDs),
                testState: testResults[draft.id],
                expanded: expandedTests.contains(draft.id),
                onSave: { saveCustom(draft) },
                onTest: { testProvider(draft.id) },
                onDelete: { deleteCustom(draft.id) },
                onToggleExpand: { toggleExpand(draft.id) }
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

    private func toggleExpand(_ id: String) {
        if expandedTests.contains(id) { expandedTests.remove(id) } else { expandedTests.insert(id) }
    }

    /// http(s) URL check shared by built-in and custom cards. Empty = use default (valid).
    private func urlError(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard let url = URL(string: trimmed), let scheme = url.scheme,
              ["http", "https"].contains(scheme), url.host != nil else {
            return "Must be a valid http(s) URL"
        }
        return nil
    }

    private func testProvider(_ id: String) {
        testResults[id] = .testing
        expandedTests.remove(id)
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
                testResults[id] = .ok(models.map(\.id).sorted())
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
            let saved = appState.resolved?.config.providers[preset.id]?.baseURL ?? ""
            baseURLs[preset.id] = saved
            savedBaseURLs[preset.id] = saved
        }
        customProviders = (appState.resolved?.config.providers ?? [:])
            .filter { !bundled.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { id, config in CustomProviderDraft(id: id, config: config) }
    }

    private func save(_ provider: String) {
        appState.saveAPIKey(keys[provider] ?? "", for: provider)
    }

    private func saveBaseURL(_ provider: String) {
        guard urlError(baseURLs[provider] ?? "") == nil else { return }
        do {
            var config = GlobalConfigWriter().load()
            var providerConfig = config.providers[provider] ?? ProviderConfig()
            let value = baseURLs[provider]?.trimmingCharacters(in: .whitespaces) ?? ""
            providerConfig.baseURL = value.isEmpty ? nil : value
            config.providers[provider] = providerConfig
            try GlobalConfigWriter().save(config)
            appState.reloadConfig()
            savedBaseURLs[provider] = value
        } catch {
            appState.lastError = error.localizedDescription
        }
    }

    private func addCustom() {
        var n = customProviders.count + 1
        while customProviders.contains(where: { $0.id == "custom-\(n)" }) { n += 1 }
        customProviders.append(CustomProviderDraft(id: "custom-\(n)", isNew: true))
    }

    private func saveCustom(_ draft: CustomProviderDraft) {
        guard draft.validationError(existingIDs: bundledIDs.union(Set(customProviders.map(\.id)).subtracting([draft.id]))) == nil else { return }
        do {
            var config = GlobalConfigWriter().load()
            config.providers[draft.id] = draft.toConfig()
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

// MARK: - Provider drafts

struct ModelDraft: Equatable {
    /// Row identity for ForEach (model id can repeat while editing).
    var rowID = UUID().uuidString
    var id = ""           // model id sent to the API
    var name = ""         // display name (falls back to id)
    var contextWindow = "128000"
    var maxOutput = "8192"
    var supportsTools = true
}

struct CustomProviderDraft: Identifiable, Equatable {
    var id: String        // config key; editable while isNew
    var isNew = false
    var name = ""
    var baseURL = ""
    var models: [ModelDraft] = [ModelDraft()]
    var dirty = false

    init(id: String, isNew: Bool) {
        self.id = id
        self.isNew = isNew
    }

    init(id: String, config: ProviderConfig) {
        self.id = id
        name = config.name ?? id
        baseURL = config.baseURL ?? ""
        models = (config.models ?? []).map { info in
            ModelDraft(
                id: info.id,
                name: info.name,
                contextWindow: String(info.contextWindow),
                maxOutput: String(info.maxOutput),
                supportsTools: info.supportsTools
            )
        }
        if models.isEmpty { models = [ModelDraft()] }
    }

    /// First validation problem, nil when saveable.
    func validationError(existingIDs: Set<String>) -> String? {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        if trimmedName.isEmpty { return "Name is required" }
        let trimmedID = id.trimmingCharacters(in: .whitespaces)
        if trimmedID.isEmpty { return "ID is required" }
        if trimmedID.range(of: #"^[a-z0-9][a-z0-9-]*$"#, options: .regularExpression) == nil {
            return "ID must be lowercase slug (a-z, 0-9, -)"
        }
        if existingIDs.contains(trimmedID) { return "ID \"\(trimmedID)\" is already taken" }
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmedURL), let scheme = url.scheme,
              ["http", "https"].contains(scheme), url.host != nil else {
            return "Base URL must be a valid http(s) URL"
        }
        if models.isEmpty { return "Add at least one model" }
        var seen: Set<String> = []
        for model in models {
            let modelID = model.id.trimmingCharacters(in: .whitespaces)
            if modelID.isEmpty { return "Every model needs an id" }
            if !seen.insert(modelID).inserted { return "Duplicate model id \"\(modelID)\"" }
            guard let context = Int(model.contextWindow), context > 0 else {
                return "Context window of \"\(modelID)\" must be a positive number"
            }
            guard let output = Int(model.maxOutput), output > 0 else {
                return "Max output of \"\(modelID)\" must be a positive number"
            }
        }
        return nil
    }

    func toConfig() -> ProviderConfig {
        ProviderConfig(
            baseURL: baseURL.trimmingCharacters(in: .whitespaces).nilIfEmpty,
            name: name.trimmingCharacters(in: .whitespaces).nilIfEmpty,
            models: models.map { draft in
                let modelID = draft.id.trimmingCharacters(in: .whitespaces)
                let displayName = draft.name.trimmingCharacters(in: .whitespaces)
                return ModelInfo(
                    id: modelID,
                    name: displayName.isEmpty ? modelID : displayName,
                    contextWindow: Int(draft.contextWindow) ?? 128_000,
                    maxOutput: Int(draft.maxOutput) ?? 8_192,
                    supportsTools: draft.supportsTools
                )
            }
        )
    }
}

// MARK: - Provider cards

private struct BuiltinProviderCard: View {
    let preset: ProviderPreset
    @Binding var keyText: String
    @Binding var urlText: String
    let urlDirty: Bool
    let urlError: String?
    let testState: ProvidersPane.TestState?
    let expanded: Bool
    let onSaveKey: () -> Void
    let onSaveURL: () -> Void
    let onTest: () -> Void
    let onToggleExpand: () -> Void

    var body: some View {
        PaneCard {
            HStack {
                Text(preset.name)
                    .font(Theme.smallMedium)
                    .foregroundStyle(Theme.textBase)
                if !keyText.isEmpty {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.success)
                }
                Spacer()
                TestResultView(state: testState, expanded: expanded, onToggleExpand: onToggleExpand)
                Button("Test", action: onTest)
                    .buttonStyle(DockButtonStyle(variant: .ghost))
                    .controlSize(.small)
                    .disabled(testState == .testing)
            }
            if let keyEnv = preset.keyEnv {
                PaneField(
                    label: "API Key (env: \(keyEnv))",
                    text: $keyText,
                    placeholder: "sk-…",
                    secure: true,
                    onSubmit: onSaveKey
                )
            }
            HStack(alignment: .bottom, spacing: 8) {
                PaneField(
                    label: "Base URL",
                    text: $urlText,
                    placeholder: preset.baseURL,
                    onSubmit: onSaveURL
                )
                Button("Save", action: onSaveURL)
                    .buttonStyle(DockButtonStyle(variant: .secondary))
                    .controlSize(.small)
                    .disabled(!urlDirty || urlError != nil)
                    .padding(.bottom, 1)
            }
            if let urlError {
                Text(urlError).font(Theme.caption).foregroundStyle(Theme.danger)
            }
            TestModelList(state: testState, expanded: expanded)
        }
    }
}

private struct CustomProviderCard: View {
    @Environment(AppState.self) private var appState
    @Binding var draft: CustomProviderDraft
    let existingIDs: Set<String>
    let testState: ProvidersPane.TestState?
    let expanded: Bool
    let onSave: () -> Void
    let onTest: () -> Void
    let onDelete: () -> Void
    let onToggleExpand: () -> Void

    private var error: String? {
        draft.validationError(existingIDs: existingIDs.subtracting([draft.id]))
    }

    var body: some View {
        PaneCard {
            HStack {
                Text(draft.isNew ? "New provider" : draft.id)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textFaint)
                if draft.dirty {
                    Text("unsaved").font(Theme.tiny).foregroundStyle(Theme.warning)
                }
                Spacer()
                TestResultView(state: testState, expanded: expanded, onToggleExpand: onToggleExpand)
                Button("Test", action: onTest)
                    .buttonStyle(DockButtonStyle(variant: .ghost))
                    .controlSize(.small)
                    .disabled(testState == .testing || draft.dirty)
                    .help(draft.dirty ? "Save before testing" : "Fetch model list")
                Button("Save", action: onSave)
                    .buttonStyle(DockButtonStyle(variant: .secondary))
                    .controlSize(.small)
                    .disabled(!draft.dirty || error != nil)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.danger)
                }
                .buttonStyle(.plain)
            }

            if draft.isNew {
                PaneField(label: "ID (locked after save)", text: binding(\.id), placeholder: "my-provider")
            }
            PaneField(label: "Name", text: binding(\.name), placeholder: "My Provider")
            PaneField(label: "Base URL", text: binding(\.baseURL), placeholder: "https://host/v1")
            PaneField(
                label: "API Key (optional)",
                text: Binding(
                    get: { appState.storedAPIKey(for: draft.id) },
                    set: { appState.saveAPIKey($0, for: draft.id) }
                ),
                placeholder: "sk-…",
                secure: true
            )

            HStack {
                Text("MODELS")
                    .font(Theme.tiny)
                    .foregroundStyle(Theme.textFaint)
                Spacer()
                Button {
                    draft.models.append(ModelDraft())
                    draft.dirty = true
                } label: {
                    Label("Add Model", systemImage: "plus")
                        .font(Theme.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textAccent)
            }
            ForEach($draft.models, id: \.rowID) { $model in
                ModelRow(model: $model, onDirty: { draft.dirty = true }, canDelete: draft.models.count > 1) {
                    draft.models.removeAll { $0.rowID == model.rowID }
                    draft.dirty = true
                }
            }

            if let error {
                Text(error).font(Theme.caption).foregroundStyle(Theme.danger)
            }
            TestModelList(state: testState, expanded: expanded)
        }
    }

    private func binding<T: Equatable>(_ keyPath: WritableKeyPath<CustomProviderDraft, T>) -> Binding<T> {
        Binding(
            get: { draft[keyPath: keyPath] },
            set: { draft[keyPath: keyPath] = $0; draft.dirty = true }
        )
    }
}

private struct ModelRow: View {
    @Binding var model: ModelDraft
    let onDirty: () -> Void
    let canDelete: Bool
    let onDelete: () -> Void

    private func field(_ placeholder: String, _ keyPath: WritableKeyPath<ModelDraft, String>, width: CGFloat? = nil) -> some View {
        TextField(placeholder, text: Binding(
            get: { model[keyPath: keyPath] },
            set: { model[keyPath: keyPath] = $0; onDirty() }
        ))
        .textFieldStyle(.plain)
        .font(Theme.caption)
        .foregroundStyle(Theme.textBase)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(width: width)
        .background(Theme.layer01, in: .rect(cornerRadius: Theme.radiusSmall))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).stroke(Theme.borderMuted, lineWidth: 0.5))
    }

    var body: some View {
        HStack(spacing: 6) {
            field("model-id", \.id)
            field("Display name", \.name)
            field("Ctx", \.contextWindow, width: 64)
            field("Out", \.maxOutput, width: 56)
            Toggle("", isOn: Binding(
                get: { model.supportsTools },
                set: { model.supportsTools = $0; onDirty() }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .help("Supports tools")
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "minus.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(canDelete ? Theme.danger : Theme.textFaint)
            }
            .buttonStyle(.plain)
            .disabled(!canDelete)
        }
    }
}

private struct TestResultView: View {
    let state: ProvidersPane.TestState?
    let expanded: Bool
    let onToggleExpand: () -> Void

    var body: some View {
        switch state {
        case .testing:
            ProgressView().controlSize(.mini)
        case .ok(let models):
            Button(action: onToggleExpand) {
                HStack(spacing: 3) {
                    Text("OK — \(models.count) models")
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8))
                }
                .font(Theme.caption)
                .foregroundStyle(Theme.success)
            }
            .buttonStyle(.plain)
        case .failed(let error):
            Text(error).font(Theme.caption).foregroundStyle(Theme.danger).lineLimit(1)
        case nil:
            EmptyView()
        }
    }
}

private struct TestModelList: View {
    let state: ProvidersPane.TestState?
    let expanded: Bool

    var body: some View {
        if expanded, case .ok(let models) = state {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(models.prefix(20), id: \.self) { model in
                    Text(model).font(Theme.caption).foregroundStyle(Theme.textMuted)
                }
                if models.count > 20 {
                    Text("… \(models.count - 20) more").font(Theme.caption).foregroundStyle(Theme.textFaint)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.layer01, in: .rect(cornerRadius: Theme.radiusSmall))
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
                let enabled = servers[name]?.enabled ?? true
                PaneCard {
                    HStack {
                        statusIcon(for: name, enabled: enabled)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name)
                                .font(Theme.smallMedium)
                                .foregroundStyle(enabled ? Theme.textBase : Theme.textFaint)
                            Text(commandLine(for: name))
                                .font(Theme.caption)
                                .foregroundStyle(Theme.textFaint)
                        }
                        Spacer()
                        Text(enabled ? statusText(for: name) : "disabled")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textMuted)
                        Toggle("", isOn: Binding(
                            get: { enabled },
                            set: { appState.setMCPServerEnabled(name, $0) }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
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
    private func statusIcon(for name: String, enabled: Bool) -> some View {
        if !enabled {
            Image(systemName: "circle").font(.system(size: 8)).foregroundStyle(Theme.textFaint)
        } else {
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
