import NintyCore
import SwiftUI

/// Long-term memory browser fed by ltm-mcp. Search (hybrid), scope filter
/// (workspace / global / all), detail view, store quick notes, delete.
/// This is the user's window into the agent's self-improving memory loop.
struct LtmTabView: View {
    @Environment(AppState.self) private var appState

    @State private var status: LoadStatus = .loading
    @State private var memories: [MemoryUI] = []
    @State private var selected: MemoryUI?
    @State private var query = ""
    @State private var scope: ScopeFilter = .all
    @State private var showStore = false
    @State private var searchTask: Task<Void, Never>?
    @State private var confirmingDelete = false
    @State private var searching = false

    enum LoadStatus {
        case loading, ready, unavailable, empty
        case error(String)
    }

    enum ScopeFilter: String, CaseIterable {
        case workspace = "Workspace"
        case global = "Global"
        case all = "All"
    }

    var body: some View {
        VStack(spacing: 0) {
            switch status {
            case .loading:
                Spacer()
                ProgressView().controlSize(.small)
                Text("Loading memories…").font(Theme.caption).foregroundStyle(Theme.textMuted)
                Spacer()
            case .unavailable:
                emptyState(
                    icon: "brain",
                    title: "No memory server",
                    message: "Add ltm-mcp to the `mcp` section of ninty.json, e.g.\n\"ltm\": { \"url\": \"https://host/mcp\" }"
                )
            case .empty:
                toolbar
                Divider().overlay(Theme.borderBase)
                emptyState(
                    icon: "brain",
                    title: "No memories yet",
                    message: "The agent stores durable learnings here as it works — or add one with +."
                )
            case .error(let message):
                emptyState(icon: "exclamationmark.triangle", title: "Memory query failed", message: message)
            case .ready:
                toolbar
                Divider().overlay(Theme.borderBase)
                list
                if let selected {
                    Divider().overlay(Theme.borderBase)
                    detailBar(selected)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: appState.workspace?.id) { await load() }
        .onChange(of: query) { _, _ in scheduleSearch() }
        .onChange(of: scope) { _, _ in scheduleSearch() }
        .sheet(isPresented: $showStore) { storeSheet }
        .confirmationDialog(
            "Delete this memory permanently?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let selected {
                    Task { await delete(selected) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textFaint)
            TextField("Search memories…", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.caption)
                .foregroundStyle(Theme.textBase)

            Picker("", selection: $scope) {
                ForEach(ScopeFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 170)
            .labelsHidden()

            if searching {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 22, height: 22)
            }

            Button { showStore = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Store a memory (workspace scope)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(memories) { memory in
                    row(memory)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
        .frame(maxHeight: .infinity)
    }

    private func row(_ memory: MemoryUI) -> some View {
        let isSelected = selected?.id == memory.id
        return VStack(alignment: .leading, spacing: 3) {
            Text(memory.content)
                .font(Theme.caption)
                .foregroundStyle(isSelected ? Theme.textBase : Theme.textMuted)
                .lineLimit(2)
            HStack(spacing: 6) {
                if let scope = memory.scope {
                    Text(scope == "global" ? "global" : "workspace")
                        .font(Theme.tiny)
                        .foregroundStyle(Theme.textFaint)
                }
                if let collection = memory.collection {
                    Text(collection)
                        .font(Theme.tiny)
                        .foregroundStyle(Theme.textFaint)
                }
                if !memory.tags.isEmpty {
                    Text(memory.tags.map { "#\($0)" }.joined(separator: " "))
                        .font(Theme.tiny)
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(1)
                }
                Spacer()
                if let updated = memory.updated {
                    Text(updated.formatted(.relative(presentation: .named)))
                        .font(Theme.tiny)
                        .foregroundStyle(Theme.textFaint)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Theme.overlayPressed : .clear, in: .rect(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { selected = isSelected ? nil : memory }
    }

    // MARK: - Detail

    private func detailBar(_ memory: MemoryUI) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(memory.scope ?? "no scope")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.textAccent)
                Text("seen \(memory.accessCount)×")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textFaint)
                Spacer()
                Button {
                    confirmingDelete = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.diffDelete)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete memory")
            }
            Text(memory.content)
                .font(Theme.caption)
                .foregroundStyle(Theme.textBase)
                .textSelection(.enabled)
            if let context = memory.context, !context.isEmpty {
                Text(context)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(3)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.layer01)
    }

    // MARK: - Store sheet

    @State private var newContent = ""
    @State private var newTags = ""

    private var storeSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Store memory").font(Theme.sansMedium).foregroundStyle(Theme.textBase)
            Text("Scope: \(scope == .global ? "global" : (appState.workspace?.id ?? "workspace"))")
                .font(Theme.caption)
                .foregroundStyle(Theme.textMuted)
            TextEditor(text: $newContent)
                .font(Theme.caption)
                .frame(minHeight: 90)
                .border(Theme.borderBase)
            TextField("Tags (comma separated, optional)", text: $newTags)
                .textFieldStyle(.roundedBorder)
                .font(Theme.caption)
            HStack {
                Spacer()
                Button("Cancel") { showStore = false }
                Button("Store") {
                    let content = newContent.trimmingCharacters(in: .whitespacesAndNewlines)
                    let tags = newTags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    showStore = false
                    newContent = ""
                    newTags = ""
                    if !content.isEmpty {
                        Task { await store(content: content, tags: tags) }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    // MARK: - Data

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    private var scopeParam: String? {
        switch scope {
        case .workspace: appState.workspace?.id
        case .global: "global"
        case .all: nil
        }
    }

    private func load() async {
        // Full-screen loading only when there is nothing to show yet;
        // during searches the existing list stays visible under the spinner.
        if memories.isEmpty { status = .loading }
        searching = true
        defer { searching = false }
        guard await appState.waitForMCPTool("list_memories") else {
            status = .unavailable
            return
        }
        var args: [String: JSONValue] = ["limit": .int(100)]
        if let scopeParam { args["scope"] = .string(scopeParam) }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let result: Result<JSONValue, MCPToolError>
        if trimmed.count >= 2 {
            args["query"] = .string(trimmed)
            args["search_mode"] = .string("hybrid")
            result = await appState.callMCPTool("search_memories", args)
        } else {
            result = await appState.callMCPTool("list_memories", args)
        }
        switch result {
        case .success(let value):
            memories = MemoryUI.parse(value)
            status = memories.isEmpty ? .empty : .ready
            if let current = selected, !memories.contains(where: { $0.id == current.id }) {
                selected = nil
            }
        case .failure(let error):
            status = .error(error.localizedDescription)
        }
    }

    private func store(content: String, tags: [String]) async {
        var args: [String: JSONValue] = ["content": .string(content)]
        args["scope"] = .string(scope == .global ? "global" : (appState.workspace?.id ?? "global"))
        if !tags.isEmpty { args["tags"] = .array(tags.map { .string($0) }) }
        _ = await appState.callMCPTool("store_memory", args)
        await load()
    }

    private func delete(_ memory: MemoryUI) async {
        _ = await appState.callMCPTool("delete_memory", ["id": .string(memory.id)])
        if selected?.id == memory.id { selected = nil }
        await load()
    }

    private func emptyState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: icon).font(.system(size: 28)).foregroundStyle(Theme.textMuted)
            Text(title).font(Theme.sansMedium).foregroundStyle(Theme.textBase)
            Text(message)
                .font(Theme.caption)
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - UI model

struct MemoryUI: Identifiable, Equatable {
    let id: String
    let content: String
    let context: String?
    let tags: [String]
    let collection: String?
    let scope: String?
    let updated: Date?
    let accessCount: Int

    static func parse(_ value: JSONValue) -> [MemoryUI] {
        guard case .array(let items) = value else { return [] }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        return items.compactMap { item in
            guard case .object(let object) = item,
                  let id = object["id"]?.stringValue,
                  let content = object["content"]?.stringValue else { return nil }
            let updatedString = object["updated_at"]?.stringValue
            return MemoryUI(
                id: id,
                content: content,
                context: object["context"]?.stringValue,
                tags: object["tags"]?.stringArray ?? [],
                collection: object["collection"]?.stringValue,
                scope: object["scope"]?.stringValue,
                updated: updatedString.flatMap { formatter.date(from: $0) ?? plain.date(from: $0) },
                accessCount: object["access_count"]?.intValue ?? 0
            )
        }
    }
}
