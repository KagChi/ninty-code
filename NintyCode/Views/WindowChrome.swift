import AppKit
import SwiftUI

/// Window-level styling for the dark-only app: forces dark appearance
/// (toolbar bar renders dark in fullscreen instead of the light aqua
/// material, items tinted correctly) and paints the window bgDeep so the
/// visibility-hidden toolbar bar shows our dark color through it.
struct WindowStyler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        StylerView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

final class StylerView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(Theme.bgDeep)
    }
}
