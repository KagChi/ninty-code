import AppKit
import SwiftUI

/// Window-level styling for the dark-only app: forces dark appearance and
/// paints the window bgDeep. Also removes the toolbar entirely — the dead
/// bar row above the tab strip is irreducible while a toolbar exists
/// (traffic lights + the system sidebar toggle park inside it under
/// NavigationSplitView). With no toolbar, content spans the full window
/// top and the lights float over the sidebar. Custom pieces replacing
/// what the toolbar provided: the sidebar toggle lives in the tab strip,
/// window dragging via WindowDragView.
struct WindowStyler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        StylerView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

final class StylerView: NSView {
    private var toolbarObserver: NSKeyValueObservation?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(Theme.bgDeep)
        window.toolbar = nil
        // NSV may reinstall a toolbar on column visibility changes — nil it
        // again whenever that happens. Setting nil re-triggers KVO with a
        // nil value, which is a no-op, so this terminates.
        toolbarObserver = window.observe(\.toolbar, options: [.new]) { win, _ in
            if win.toolbar != nil { win.toolbar = nil }
        }
    }
}

/// Fills its background area and turns it into a window-drag region. With
/// no toolbar there is no built-in drag zone; this restores dragging from
/// the empty gaps around the tab strip and cards.
struct WindowDragView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DragView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class DragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}
