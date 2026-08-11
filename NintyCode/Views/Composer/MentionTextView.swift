import AppKit
import SwiftUI

/// Matches inserted @mention tokens: `@` + path-ish run (segments, dots, slashes).
let mentionPattern = try! NSRegularExpression(pattern: #"@[A-Za-z0-9_./\-]+"#)

/// Whether an @mention token refers to a real workspace file/dir.
/// `files` entries carry a trailing "/" for directories (mention corpus format).
func isKnownMention(_ token: String, files: Set<String>) -> Bool {
    let path = String(token.dropFirst()) // strip "@"
    guard !path.isEmpty else { return false }
    return files.contains(path) || files.contains(path + "/")
}

/// NSTextView-backed editor for the composer: same behavior as the old
/// TextEditor (grow 60→180pt then scroll) plus per-token styling — valid
/// @file mentions glow (accent color + accent shadow halo + soft bg).
struct MentionTextView: NSViewRepresentable {
    @Binding var text: String
    /// Mention validation corpus (workspace files).
    var files: [String]
    /// Shell mode → monospaced.
    var isMono: Bool
    /// Increment to focus the editor; increment to blur (edge-triggered).
    var focusSignal: Int
    var blurSignal: Int

    /// Plain Return. (Shift-Return inserts a newline inside the view.)
    var onReturn: () -> Void
    /// Tab: true = handled (mention completed), false = insert a tab.
    var onTab: () -> Bool
    /// Arrows: true = handled (mention nav / history), false = caret move.
    var onArrowUp: () -> Bool
    var onArrowDown: () -> Bool
    var onEscape: () -> Void
    /// ⌘V fallback: true = handled (image/file), false = default text paste.
    var onPaste: () -> Bool
    /// Leading "!" on an empty editor: true = consumed (shell mode entered).
    var onBang: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> GrowingScrollView {
        let coordinator = context.coordinator

        let textView = MentionNSTextView()
        textView.delegate = coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.insertionPointColor = NSColor(Theme.textBase)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = CGSize(width: 5, height: 2)
        textView.textContainer?.widthTracksTextView = true
        // Coding prompts: no smart substitutions.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = Self.baseFont(mono: isMono)

        let scrollView = GrowingScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none

        coordinator.textView = textView
        coordinator.scrollView = scrollView
        scrollView.onLayout = { @MainActor [weak coordinator] in coordinator?.recomputeHeight() }
        textView.string = text
        coordinator.restyle()
        coordinator.recomputeHeight()
        return scrollView
    }

    func updateNSView(_ scrollView: GrowingScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let textView = coordinator.textView else { return }
        coordinator.representable = self

        // Fresh closures every update (they capture live SwiftUI state).
        textView.onReturn = onReturn
        textView.onTab = onTab
        textView.onArrowUp = onArrowUp
        textView.onArrowDown = onArrowDown
        textView.onEscape = onEscape
        textView.onPaste = onPaste
        textView.onBang = onBang

        // Programmatic text changes (draft restore, mention insertion, drops).
        if textView.string != text, !coordinator.isEditing {
            coordinator.programmatic = true
            textView.string = text
            coordinator.programmatic = false
            // All current insertion flows append at the end.
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            coordinator.restyle()
            coordinator.recomputeHeight()
        }

        coordinator.restyleIfCorpusChanged(files: files, mono: isMono)

        if focusSignal != coordinator.lastFocusSignal {
            coordinator.lastFocusSignal = focusSignal
            textView.window?.makeFirstResponder(textView)
        }
        if blurSignal != coordinator.lastBlurSignal {
            coordinator.lastBlurSignal = blurSignal
            textView.window?.makeFirstResponder(nil)
        }
    }

    static func baseFont(mono: Bool) -> NSFont {
        mono
            ? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            : NSFont.systemFont(ofSize: 13)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var representable: MentionTextView
        weak var textView: MentionNSTextView?
        weak var scrollView: GrowingScrollView?
        var programmatic = false
        var isEditing = false
        var lastFocusSignal = 0
        var lastBlurSignal = 0
        private var lastFilesHash = 0
        private var lastMono = false
        private var lastHeight: CGFloat = 0

        init(_ representable: MentionTextView) {
            self.representable = representable
            self.lastMono = representable.isMono
        }

        // MARK: Binding sync

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            if !programmatic, textView.string != representable.text {
                representable.text = textView.string
            }
            guard !textView.hasMarkedText() else { return }
            restyle()
            recomputeHeight()
            // Keep typing plain even right after a styled mention run.
            textView.typingAttributes = baseAttributes()
        }

        func textDidBeginEditing(_ notification: Notification) { isEditing = true }
        func textDidEndEditing(_ notification: Notification) { isEditing = false }

        // MARK: Styling

        private var fileSet: Set<String> { Set(representable.files) }

        private func baseAttributes() -> [NSAttributedString.Key: Any] {
            [
                .font: MentionTextView.baseFont(mono: representable.isMono),
                .foregroundColor: NSColor(Theme.textBase)
            ]
        }

        /// Full-range restyle: base look + glow on valid @mentions.
        func restyle() {
            guard let textView, let storage = textView.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes(baseAttributes(), range: full)

            let files = fileSet
            guard !files.isEmpty, storage.length > 1 else {
                storage.endEditing()
                return
            }
            let nsString = storage.string as NSString
            for match in mentionPattern.matches(in: storage.string, range: full) {
                let token = nsString.substring(with: match.range)
                guard isKnownMention(token, files: files) else { continue }
                let glow = NSShadow()
                glow.shadowColor = NSColor(Theme.textAccent).withAlphaComponent(0.85)
                glow.shadowBlurRadius = 6
                glow.shadowOffset = .zero
                storage.addAttributes([
                    .foregroundColor: NSColor(Theme.textAccent),
                    .backgroundColor: NSColor(Theme.textAccent).withAlphaComponent(0.12),
                    .shadow: glow
                ], range: match.range)
            }
            storage.endEditing()
        }

        func restyleIfCorpusChanged(files: [String], mono: Bool) {
            let hash = files.count &* 31 &+ (files.last?.hashValue ?? 0)
            if hash != lastFilesHash || mono != lastMono {
                lastFilesHash = hash
                lastMono = mono
                restyle()
            }
        }

        // MARK: Growing height (60...180 like the old TextEditor)

        func recomputeHeight() {
            guard let textView, let scrollView, let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            let content = layoutManager.usedRect(for: container).height
            let height = min(max(content + textView.textContainerInset.height * 2 + 4, 60), 180)
            guard abs(height - lastHeight) > 0.5 else { return }
            lastHeight = height
            scrollView.desiredHeight = height
            scrollView.invalidateIntrinsicContentSize()
        }
    }

    // MARK: - Key handling text view

    final class MentionNSTextView: NSTextView {
        /// Wired by the coordinator on every SwiftUI update.
        var onReturn: (() -> Void)?
        var onTab: (() -> Bool)?
        var onArrowUp: (() -> Bool)?
        var onArrowDown: (() -> Bool)?
        var onEscape: (() -> Void)?
        var onPaste: (() -> Bool)?
        var onBang: (() -> Bool)?

        override func keyDown(with event: NSEvent) {
            let shift = event.modifierFlags.contains(.shift)
            switch event.keyCode {
            case 36, 76: // Return / numpad Enter
                if shift {
                    insertText("\n", replacementRange: selectedRange())
                } else {
                    onReturn?()
                }
                return
            case 48: // Tab
                if onTab?() == true { return }
                super.keyDown(with: event)
                return
            case 126: // Up
                if onArrowUp?() == true { return }
                super.keyDown(with: event)
                return
            case 125: // Down
                if onArrowDown?() == true { return }
                super.keyDown(with: event)
                return
            case 53: // Escape
                onEscape?()
                return
            default:
                break
            }
            // ⌘V fallback (image/file paste; plain text falls through).
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "v" {
                if onPaste?() == true { return }
                super.keyDown(with: event)
                return
            }
            // Leading "!" on an empty editor enters shell mode (eats the char).
            if string.isEmpty, event.charactersIgnoringModifiers == "!", !shift,
               onBang?() == true {
                return
            }
            super.keyDown(with: event)
        }
    }

    // MARK: - Growing scroll view

    final class GrowingScrollView: NSScrollView {
        var desiredHeight: CGFloat = 60
        /// Width changes reflow text → height may change; coordinator
        /// recomputes on layout (converges: only invalidates on >0.5pt).
        var onLayout: (@MainActor () -> Void)?
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: desiredHeight)
        }
        override func layout() {
            super.layout()
            onLayout?()
        }
    }
}

/// Sent-bubble renderer: plain text with @mentions tinted + glowing.
/// Glow = a duplicate layer where only the mention runs are visible, blurred
/// with an accent shadow, drawn under the base text (Text concatenation
/// can't carry a per-run shadow attribute).
struct MentionText: View {
    let text: String
    let files: [String]

    var body: some View {
        ZStack(alignment: .topLeading) {
            styled(plain: .clear, mention: Theme.textAccent)
                .shadow(color: Theme.textAccent.opacity(0.75), radius: 5)
            styled(plain: Theme.textBase, mention: Theme.textAccent)
        }
    }

    private func styled(plain: Color, mention: Color) -> Text {
        let files = Set(files)
        let nsText = text as NSString
        var result = Text(verbatim: "")
        var cursor = 0
        for match in mentionPattern.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            if match.range.location > cursor {
                result = result
                    + Text(verbatim: nsText.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
                        .foregroundStyle(plain)
            }
            let token = nsText.substring(with: match.range)
            let color = files.isEmpty || isKnownMention(token, files: files) ? mention : plain
            result = result + Text(verbatim: token).foregroundStyle(color)
            cursor = match.range.location + match.range.length
        }
        if cursor < nsText.length {
            result = result + Text(verbatim: nsText.substring(from: cursor)).foregroundStyle(plain)
        }
        return result
    }
}
