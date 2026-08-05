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

/// Window-level file-drop receiver. SwiftUI's onDrop never fired anywhere
/// in this view hierarchy (DEBUG logging showed validateDrop was never
/// even called), so the receiver is a plain NSView pinned full-size behind
/// the window's contentView: SwiftUI views don't register for file drags
/// (the composer's TextEditor keeps its native local behavior), so drags
/// over the window resolve to this view.
struct WindowDropCapture: NSViewRepresentable {
    var onTargeted: (Bool) -> Void = { _ in }
    var onURLs: ([URL]) -> Void = { _ in }
    var onImages: ([NSImage]) -> Void = { _ in }
    var onPromises: ([NSFilePromiseReceiver]) -> Void = { _ in }

    func makeNSView(context: Context) -> NSView {
        DropInstallerView(
            onTargeted: onTargeted, onURLs: onURLs,
            onImages: onImages, onPromises: onPromises
        )
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class DropInstallerView: NSView {
    private let capture: DropCaptureView

    init(
        onTargeted: @escaping (Bool) -> Void,
        onURLs: @escaping ([URL]) -> Void,
        onImages: @escaping ([NSImage]) -> Void,
        onPromises: @escaping ([NSFilePromiseReceiver]) -> Void
    ) {
        capture = DropCaptureView(
            onTargeted: onTargeted, onURLs: onURLs,
            onImages: onImages, onPromises: onPromises
        )
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let content = window?.contentView, capture.superview == nil else { return }
        capture.frame = content.bounds
        capture.autoresizingMask = [.width, .height]
        content.addSubview(capture, positioned: .below, relativeTo: nil)
    }
}

final class DropCaptureView: NSView {
    let onTargeted: (Bool) -> Void
    let onURLs: ([URL]) -> Void
    let onImages: ([NSImage]) -> Void
    let onPromises: ([NSFilePromiseReceiver]) -> Void

    init(
        onTargeted: @escaping (Bool) -> Void,
        onURLs: @escaping ([URL]) -> Void,
        onImages: @escaping ([NSImage]) -> Void,
        onPromises: @escaping ([NSFilePromiseReceiver]) -> Void
    ) {
        self.onTargeted = onTargeted
        self.onURLs = onURLs
        self.onImages = onImages
        self.onPromises = onPromises
        super.init(frame: .zero)
        registerForDraggedTypes([
            .fileURL,
            NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
            NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content"),
            .png, .tiff,
            NSPasteboard.PasteboardType("public.jpeg")
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        #if DEBUG
        print("[drop] entered:", sender.draggingPasteboard.types?.map(\.rawValue).joined(separator: ", ") ?? "none")
        #endif
        onTargeted(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargeted(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onTargeted(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onTargeted(false)
        let pasteboard = sender.draggingPasteboard
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            onURLs(urls)
            return true
        }
        if let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver],
           !promises.isEmpty {
            onPromises(promises)
            return true
        }
        if let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           !images.isEmpty {
            onImages(images)
            return true
        }
        return false
    }
}
