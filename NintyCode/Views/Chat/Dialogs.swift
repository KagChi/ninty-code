import SwiftUI
import NintyCore

/// opencode model dialog (⌘'): search autofocused, grouped by provider,
/// recent-5 section, arrows+Enter, Esc closes.
struct ModelDialog: View {
    @Environment(AppState.self) private var appState
    @State private var query = ""
    @State private var selection: String?

    private var filtered: [(preset: ProviderPreset, models: [ModelInfo])] {
        guard let registry = appState.registry else { return [] }
        return registry.presets.compactMap { preset in
            let models = preset.models.filter {
                query.isEmpty
                    || $0.name.localizedCaseInsensitiveContains(query)
                    || $0.id.localizedCaseInsensitiveContains(query)
                    || preset.name.localizedCaseInsensitiveContains(query)
            }
            return models.isEmpty ? nil : (preset, models)
        }
    }

    private var recentFiltered: [String] {
        appState.recentModels.filter {
            query.isEmpty || $0.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textFaint)
                TextField("Search models…", text: $query)
                    .textFieldStyle(.plain)
                    .font(Theme.sans)
                    .foregroundStyle(Theme.textBase)
            }
            .padding(12)
            Divider().overlay(Theme.borderMuted)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !recentFiltered.isEmpty {
                        sectionHeader("Recent")
                        ForEach(recentFiltered, id: \.self) { reference in
                            modelRow(reference: reference, label: shortName(reference), group: "Recent")
                        }
                    }
                    ForEach(filtered, id: \.preset.id) { section in
                        sectionHeader(section.preset.name)
                        ForEach(section.models, id: \.id) { model in
                            modelRow(
                                reference: "\(section.preset.id)/\(model.id)",
                                label: model.name,
                                group: section.preset.name
                            )
                        }
                    }
                }
                .padding(8)
            }
            Divider().overlay(Theme.borderMuted)
            HStack {
                Text("↑↓ navigate · ↵ select · esc close")
                    .font(Theme.tiny)
                    .foregroundStyle(Theme.textFaint)
                Spacer()
                Button("Manage providers…") {
                    appState.showModelDialog = false
                    appState.settingsSection = .providers
                    appState.showSettings = true
                }
                .buttonStyle(DockButtonStyle(variant: .ghost))
                .controlSize(.small)
            }
            .padding(10)
        }
        .frame(width: 440, height: 420)
        .background(Theme.bgBase)
        .onExitCommand { appState.showModelDialog = false }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(Theme.tiny)
            .foregroundStyle(Theme.textFaint)
            .padding(.horizontal, 8)
            .padding(.top, 8)
    }

    private func modelRow(reference: String, label: String, group: String) -> some View {
        Button {
            appState.selectModel(reference)
            appState.showModelDialog = false
        } label: {
            HStack {
                Text(label)
                    .font(Theme.small)
                    .foregroundStyle(Theme.textBase)
                    .lineLimit(1)
                Spacer()
                if reference == appState.selectedModel {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textAccent)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .backgroundHover
    }

    private func shortName(_ reference: String) -> String {
        appState.modelLabel(reference)
    }
}

/// opencode command palette (⌘K): session commands with fuzzy filter.
struct CommandPalette: View {
    @Environment(AppState.self) private var appState
    @State private var query = ""

    private struct Item: Identifiable {
        let id: String
        let title: String
        let action: (AppState) -> Void
    }

    private var items: [Item] {
        [
            Item(id: "new", title: "New session") { $0.newChat() },
            Item(id: "undo", title: "Undo last turn") { $0.activeChat?.undo() },
            Item(id: "redo", title: "Redo reverted turn") { $0.activeChat?.redo() },
            Item(id: "compact", title: "Compact session") { $0.activeChat?.compact() },
            Item(id: "fork", title: "Fork session") { $0.activeChat?.showForkDialog = true },
            Item(id: "agent", title: "Cycle agent") { $0.cycleAgent() },
            Item(id: "model", title: "Choose model") { $0.showModelDialog = true },
            Item(id: "autoaccept", title: "Toggle auto-accept permissions") { $0.activeChat?.autoAccept.toggle() },
            Item(id: "open", title: "Open project…") { $0.pickProject() },
            Item(id: "settings", title: "Settings") { $0.showSettings = true },
        ]
    }

    private var filtered: [Item] {
        items.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "command")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textFaint)
                TextField("Type a command…", text: $query)
                    .textFieldStyle(.plain)
                    .font(Theme.sans)
                    .foregroundStyle(Theme.textBase)
                    .onSubmit { run(filtered.first) }
            }
            .padding(12)
            Divider().overlay(Theme.borderMuted)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filtered) { item in
                        Button {
                            run(item)
                        } label: {
                            Text(item.title)
                                .font(Theme.small)
                                .foregroundStyle(Theme.textBase)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .backgroundHover
                    }
                }
                .padding(8)
            }
        }
        .frame(width: 400, height: 320)
        .background(Theme.bgBase)
        .onExitCommand { appState.showCommandPalette = false }
    }

    private func run(_ item: Item?) {
        guard let item else { return }
        appState.showCommandPalette = false
        item.action(appState)
    }
}

/// opencode-style modal: dimmed backdrop, click-outside + Esc dismiss.
/// Sheets on macOS don't dismiss on outside click, so dialogs render as overlays.
private struct ModalOverlay<Content: View>: ViewModifier {
    @Binding var isPresented: Bool
    @ViewBuilder let content: Content

    func body(content base: Self.Content) -> some View {
        ZStack {
            base
            if isPresented {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { isPresented = false }
                    .transition(.opacity)
                content
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLarge))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radiusLarge)
                            .stroke(Theme.borderBase, lineWidth: 0.5)
                    )
                    .shadow(color: Theme.raisedShadow, radius: 24, y: 8)
                    .transition(.opacity)
                    .background(
                        // Esc still closes, like the sheets did.
                        Button("") { isPresented = false }
                            .keyboardShortcut(.cancelAction)
                            .hidden()
                    )
            }
        }
        .animation(.easeInOut(duration: 0.12), value: isPresented)
    }
}

extension View {
    func modalOverlay<Content: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        modifier(ModalOverlay(isPresented: isPresented, content: content))
    }
}
