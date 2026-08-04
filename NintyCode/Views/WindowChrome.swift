import AppKit
import SwiftUI

/// AppKit helper to size a SwiftUI toolbar item to the full available width.
/// Why this exists: SwiftUI wraps the principal item in flexible spaces that
/// absorb ALL free space, and exposes no API for item sizing. The only
/// reliable lever is forcing the NSToolbarItem's min/max size directly.
/// Width math: window width − leading reserve (sidebar column, passed in by
/// the caller who knows columnVisibility) − sibling items (toggle, separator,
/// trailing buttons; flexible spaces skipped) − insets. Recomputed on window
/// resize, key-window events, and when the caller updates `leadingReserve`.
struct ToolbarItemStretcher: NSViewRepresentable {
    let itemID: String
    /// Width reserved at the toolbar's leading edge (sidebar column when
    /// visible, 0 when collapsed — the toggle then joins the detail items).
    let leadingReserve: CGFloat

    func makeNSView(context: Context) -> StretcherView {
        StretcherView(itemID: itemID, leadingReserve: leadingReserve)
    }

    func updateNSView(_ nsView: StretcherView, context: Context) {
        nsView.leadingReserve = leadingReserve
        nsView.stretchItem()
    }
}

final class StretcherView: NSView {
    let itemID: String
    var leadingReserve: CGFloat
    private var observers: [Any] = []

    init(itemID: String, leadingReserve: CGFloat) {
        self.itemID = itemID
        self.leadingReserve = leadingReserve
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }

        // Dark-only app: force the window's appearance so the fullscreen
        // toolbar bar renders dark instead of the light aqua material.
        window.appearance = NSAppearance(named: .darkAqua)

        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()

        // Staggered attempts — toolbar construction finishes asynchronously.
        for delay in [0.05, 0.3, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.stretchItem()
            }
        }

        for name in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification] {
            let observer = NotificationCenter.default.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.stretchItem()
            }
            observers.append(observer)
        }
    }

    func stretchItem() {
        guard let window, let toolbar = window.toolbar else { return }
        guard let item = toolbar.items.first(where: {
            $0.itemIdentifier.rawValue.contains(itemID)
        }) else { return }

        // Siblings that consume width in the detail region: sidebar toggle
        // (when sidebar collapsed), split-view separator, trailing buttons.
        // Flexible spaces are skipped — they shrink to zero on their own.
        var consumed = leadingReserve
        for other in toolbar.items where other !== item {
            if other.itemIdentifier == .flexibleSpace { continue }
            consumed += other.view?.frame.width ?? 0
        }

        let width = max(window.frame.width - consumed - 24, 240)
        item.minSize = NSSize(width: width, height: item.minSize.height)
        item.maxSize = NSSize(width: width, height: item.maxSize.height)
        item.view?.setContentHuggingPriority(.init(1), for: .horizontal)
        item.view?.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        item.view?.autoresizingMask = [.width]
    }

    @MainActor
    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
}
