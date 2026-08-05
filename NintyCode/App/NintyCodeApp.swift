import SwiftUI

@main
struct NintyCodeApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .frame(minWidth: 900, minHeight: 600)
                .background(Theme.bgDeep)
                .preferredColorScheme(.dark)
                .onAppear { appState.bootstrap() }
        }
        // Hidden titlebar + native toolbar: system toggle and traffic
        // lights live in the bar; the tab capsule rides as the centered
        // principal item (fitting-size — the toolbar's native model).
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 750)
        .commands {
            // Keep the app-menu Settings item (⌘,) — opens the in-app dialog,
            // not the native Settings window.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { appState.showSettings = true }
                    .keyboardShortcut(",")
            }
        }
    }
}

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var detailWidth: CGFloat = 0
    @State private var appliedBandWidth: CGFloat = 600
    @State private var healGeneration = 0
    @State private var bandTask: Task<Void, Never>?

    /// Toolbar middle band ≈ detail column width minus what the bar
    /// reserves: 72pt for separator/window insets with the sidebar open;
    /// a collapsed sidebar parks its toggle inside the band (+88 → 160).
    private var targetBandWidth: CGFloat {
        max(240, detailWidth - (columnVisibility == .all ? 72 : 160))
    }

    /// Band shrinking must apply NOW (a late shrink leaves the item wider
    /// than the band → ejected to overflow); growing waits out the sidebar
    /// slide animation (an early grow ejects too — AppKit overflow is
    /// sticky, it never pulls items back on its own).
    private func applyBandWidth(_ target: CGFloat) {
        bandTask?.cancel()
        if target < appliedBandWidth {
            appliedBandWidth = target
        }
        bandTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            appliedBandWidth = target
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(260)
        } detail: {
            HStack(spacing: 0) {
                ZStack {
                    if let chat = appState.activeChat {
                        ChatView(store: chat)
                    } else {
                        NewSessionView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .glassEffect(.regular, in: .rect(cornerRadius: 10))
                .raisedElevation(cornerRadius: 10)

                if appState.showSidePanel {
                    SidePanelResizeHandle(width: Binding(
                        get: { appState.sidePanelWidth },
                        set: { appState.sidePanelWidth = $0 }
                    ))
                    SidePanelView(chat: appState.activeChat)
                        .frame(width: appState.sidePanelWidth)
                        .frame(maxHeight: .infinity)
                        .glassEffect(.regular, in: .rect(cornerRadius: 10))
                        .raisedElevation(cornerRadius: 10)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            // Real content-column width — reliable measurement, never 0
            // (unlike toolbar-sibling frames mid-rebuild).
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                detailWidth = $0
            }
            .padding(8)
            .background(Theme.bgDeep)
            .background(WindowStyler())
            // AppKit window-level drop capture: drags anywhere over the
            // window route into the active chat (images → attachments,
            // other files → @mentions). SwiftUI onDrop never fired here.
            .background(WindowDropCapture(
                onTargeted: { appState.activeChat?.dropTargeted = $0 },
                onURLs: { appState.activeChat?.ingestDroppedURLs($0) },
                onImages: { appState.activeChat?.ingestDroppedImages($0) },
                onPromises: { appState.activeChat?.ingestPromises($0) }
            ))
            .toolbar {
                // Tab capsule as the principal item: centered in the
                // toolbar's middle band, width tracking the band via
                // appliedBandWidth. The .id generation is an auto-heal:
                // bumped after each sidebar toggle, it forces SwiftUI to
                // remove + re-insert the item, restoring bar placement if
                // AppKit ever ejects it to the (sticky) overflow.
                ToolbarItem(placement: .principal) {
                    TabStripView(bandWidth: appliedBandWidth)
                        .id(healGeneration)
                }
            }
        }
        .onChange(of: targetBandWidth, initial: true) {
            applyBandWidth(targetBandWidth)
        }
        .onChange(of: columnVisibility) {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                healGeneration += 1
            }
        }
        // Bar background hidden (not painted): the window's bgDeep shows
        // through — uniform with the content, no slab, window chrome and
        // rounded corners untouched. WindowStyler sets bgDeep + darkAqua
        // on the window; this keeps item tinting dark.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbarColorScheme(.dark, for: .windowToolbar)
        .animation(.easeInOut(duration: 0.15), value: appState.showSidePanel)
        .modalOverlay(isPresented: Binding(
            get: { appState.showModelDialog },
            set: { appState.showModelDialog = $0 }
        )) {
            ModelDialog().environment(appState)
        }
        .modalOverlay(isPresented: Binding(
            get: { appState.showCommandPalette },
            set: { appState.showCommandPalette = $0 }
        )) {
            CommandPalette().environment(appState)
        }
        .modalOverlay(isPresented: Binding(
            get: { appState.showSettings },
            set: { appState.showSettings = $0 }
        )) {
            SettingsDialog().environment(appState)
        }
        .modalOverlay(isPresented: Binding(
            get: { appState.showWorkspaceDialog },
            set: { appState.showWorkspaceDialog = $0 }
        )) {
            WorkspaceDialog(editing: appState.editingWorkspace).environment(appState)
        }
        // Click-to-preview for attached images (timeline + composer chips).
        .modalOverlay(isPresented: Binding(
            get: { appState.previewAttachment != nil },
            set: { if !$0 { appState.previewAttachment = nil } }
        )) {
            if let dataURL = appState.previewAttachment,
               let image = AttachmentImage.decode(dataURL) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 1000, maxHeight: 700)
                    .clipShape(.rect(cornerRadius: 10))
            }
        }
        .background(GlobalKeybinds(toggleSidebar: {
            columnVisibility = columnVisibility == .all ? .detailOnly : .all
        }))
    }
}

/// Drag handle on the side panel's leading edge — drag to resize.
private struct SidePanelResizeHandle: View {
    @Binding var width: CGFloat
    @State private var dragStart: CGFloat?

    var body: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: 8)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStart ?? width
                        dragStart = start
                        // Handle sits on the panel's left edge: dragging left widens.
                        // Bypass the showSidePanel implicit animation — animating
                        // per-drag-event makes the handle feel stuck.
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            width = (start - value.translation.width)
                                .clamped(to: AppState.sidePanelWidthRange)
                        }
                    }
                    .onEnded { _ in dragStart = nil }
            )
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// App-wide keybinds (opencode desktop map).
struct GlobalKeybinds: View {
    @Environment(AppState.self) private var appState
    var toggleSidebar: () -> Void = {}

    var body: some View {
        ZStack {
            Button("") { toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.control, .command])
            Button("") { appState.cycleAgent() }
                .keyboardShortcut(".", modifiers: .command)
            Button("") { appState.cycleAgent(reverse: true) }
                .keyboardShortcut(".", modifiers: [.command, .shift])
            Button("") { appState.showModelDialog = true }
                .keyboardShortcut("'", modifiers: .command)
            Button("") { appState.showCommandPalette = true }
                .keyboardShortcut("k", modifiers: .command)
            Button("") { appState.showCommandPalette = true }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("") { appState.showSettings = true }
                .keyboardShortcut(",", modifiers: .command)
            Button("") { appState.newChat() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("") {
                if let active = appState.activeChat { appState.closeTab(active) }
            }
            .keyboardShortcut("w", modifiers: .command)
            ForEach(Array(appState.openTabs.prefix(9).enumerated()), id: \.offset) { index, chat in
                Button("") { appState.activateTab(chat) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
        .frame(width: 0, height: 0)
        .hidden()
    }
}

/// opencode "New session" empty view: centered mark + title + project info.
struct NewSessionView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 32))
                .foregroundStyle(Theme.textFaint)
            Text("New session")
                .font(Theme.title)
                .foregroundStyle(Theme.textBase)
            if let workspace = appState.workspace {
                VStack(spacing: 4) {
                    ForEach(workspace.folders, id: \.self) { folder in
                        Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(Theme.captionMedium)
                            .foregroundStyle(Theme.textFaint)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Button("Start chatting") { appState.newChat() }
                        .buttonStyle(DockButtonStyle(variant: .primary))
                        .padding(.top, 8)
                }
            } else {
                Button("Open project…") { appState.pickProject() }
                    .buttonStyle(DockButtonStyle(variant: .primary))
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
