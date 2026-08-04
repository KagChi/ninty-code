import AppKit
import SwiftUI

/// AppKit helper to make SwiftUI toolbar items flexible-width.
/// SwiftUI doesn't expose NSToolbarItem.minSize/maxSize/autoresizingMask,
/// so we reach in and set them manually. Three pieces are required:
///  1. minSize/maxSize on the item (width range it may occupy)
///  2. LOW content-hugging on the hosting view — SwiftUI hosting views hug
///     their fitting size, which silently blocks growth even with huge maxSize
///  3. autoresizingMask [.width] so the view follows the item's frame
/// SwiftUI may rebuild toolbar items on state changes, so configuration is
/// re-applied on staggered delays + window resize/key notifications.
struct ToolbarItemStretcher: NSViewRepresentable {
    let itemID: String

    func makeNSView(context: Context) -> NSView {
        StretcherView(itemID: itemID)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class StretcherView: NSView {
    let itemID: String
    private var observers: [Any] = []
    #if DEBUG
    private var didLogItems = false
    #endif

    init(itemID: String) {
        self.itemID = itemID
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }

        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()

        // Staggered attempts — toolbar construction finishes asynchronously,
        // and SwiftUI may rebuild the item shortly after first layout.
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

    private func stretchItem() {
        guard let toolbar = window?.toolbar else { return }

        #if DEBUG
        if !didLogItems {
            didLogItems = true
            let ids = toolbar.items.map(\.itemIdentifier.rawValue).joined(separator: ", ")
            print("[ToolbarItemStretcher] looking for '\(itemID)' in: \(ids)")
        }
        #endif

        // Match by identifier (SwiftUI passes the id through, possibly prefixed).
        if let item = toolbar.items.first(where: { $0.itemIdentifier.rawValue.contains(itemID) }) {
            configureItem(item)
            return
        }

        // Fallback: widest middle item (principal position).
        if toolbar.items.count >= 3 {
            let candidates = Array(toolbar.items.dropFirst().dropLast())
            if let item = candidates.max(by: { ($0.view?.frame.width ?? 0) < ($1.view?.frame.width ?? 0) }) {
                configureItem(item)
            }
        }
    }

    private func configureItem(_ item: NSToolbarItem) {
        let height = item.minSize.height
        item.minSize = NSSize(width: 240, height: height)
        item.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: height)

        guard let view = item.view else { return }
        // The critical piece: without low hugging, the hosting view refuses
        // to grow past its fitting size no matter what maxSize says.
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        view.autoresizingMask = [.width]
    }

    @MainActor
    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
}
