import AppKit
import SwiftUI

/// Native editing with the palette's caret, including selections, marked text and wrapped lines.
struct PaletteTextInput: View {
    @Environment(\.metrics) private var metrics
    @Binding var text: String
    var prompt = ""
    var label = "Message"
    var focusKey: UUID?
    var multiline = false
    var usesSearchFont = false
    var maximumHeight: CGFloat = .greatestFiniteMagnitude
    var onSubmit: () -> Void = {}
    @State private var caret = PaletteInputCaretState()

    var body: some View {
        PaletteInputRepresentable(
            text: $text, font: font, focusKey: focusKey, multiline: multiline,
            label: label, maximumHeight: maximumHeight, caret: caret, onSubmit: onSubmit)
            .background(alignment: .topLeading) {
                if text.isEmpty, !caret.isComposing {
                    Text(prompt)
                        .font(Font(font))
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topLeading) {
                if let frame = caret.frame {
                    SmoothPaletteCaret(frame: frame, typing: caret.typing)
                }
            }
    }

    private var font: NSFont {
        usesSearchFont ? metrics.typography.searchFieldNSFont : metrics.typography.textNSFont(.body)
    }
}

@MainActor
@Observable
private final class PaletteInputCaretState {
    var frame: CGRect?
    var typing = false
    var isComposing = false
    @ObservationIgnored private var settle: Task<Void, Never>?

    func update(_ frame: CGRect?, composing: Bool) {
        self.frame = frame
        isComposing = composing
        settle?.cancel()
        typing = frame != nil
        guard frame != nil else { return }
        settle = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            self?.typing = false
        }
    }
}

private struct PaletteInputRepresentable: NSViewRepresentable {
    @Environment(\.metrics) private var metrics
    @Binding var text: String
    let font: NSFont
    let focusKey: UUID?
    let multiline: Bool
    let label: String
    let maximumHeight: CGFloat
    let caret: PaletteInputCaretState
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = multiline
        scroll.autohidesScrollers = true
        let view = PaletteInputTextView()
        view.frame = CGRect(x: 0, y: 0, width: 100, height: 30)
        view.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.delegate = context.coordinator
        view.drawsBackground = false
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.lineFragmentPadding = 0
        view.textContainerInset = .zero
        view.insertionPointColor = .clear
        view.writingToolsBehavior = .none
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.string = text
        view.onCaretChanged = { [weak coordinator = context.coordinator] in coordinator?.reportCaret() }
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? PaletteInputTextView else { return }
        let changed = view.font != font || view.string != text
        if view.font != font { view.font = font }
        view.textColor = NSColor(Theme.Colors.textPrimary)
        view.setAccessibilityLabel(label)
        if view.string != text, !view.hasMarkedText() { view.string = text }
        if let focusKey, context.coordinator.focusedKey != focusKey {
            context.coordinator.focusedKey = focusKey
            view.requestFocus()
        }
        if changed { context.coordinator.reportCaret() }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: NSScrollView, context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let lineHeight = (font.ascender - font.descender + font.leading).rounded(.up)
        let content = (text.hasSuffix("\n") ? text + " " : text) as NSString
        let height = multiline
            ? content.boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]
            ).height.rounded(.up) : lineHeight
        return CGSize(
            width: width,
            height: min(max(lineHeight, height), maximumHeight))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PaletteInputRepresentable
        var focusedKey: UUID?
        private var caretUpdate: Task<Void, Never>?

        init(parent: PaletteInputRepresentable) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            reportCaret()
        }

        func textViewDidChangeSelection(_ notification: Notification) { reportCaret() }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if parent.multiline, let flags = NSApp.currentEvent?.modifierFlags,
                !flags.isDisjoint(with: [.shift, .option])
            {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                parent.onSubmit()
            }
            return true
        }

        func reportCaret() {
            caretUpdate?.cancel()
            caretUpdate = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled else { return }
                guard let self,
                    let view = NSApp.keyWindow?.firstResponder as? PaletteInputTextView,
                    view.delegate === self, let scroll = view.enclosingScrollView,
                    let window = view.window
                else {
                    self?.parent.caret.update(nil, composing: false)
                    return
                }
                let composing = view.hasMarkedText()
                guard !composing, view.selectedRange().length == 0 else {
                    view.insertionPointColor = NSColor(Theme.Colors.textPrimary)
                    parent.caret.update(nil, composing: composing)
                    return
                }
                view.insertionPointColor = .clear
                var actual = NSRange()
                let rect = view.firstRect(
                    forCharacterRange: NSRange(location: view.selectedRange().location, length: 0),
                    actualRange: &actual)
                let local = scroll.convert(window.convertFromScreen(rect), from: nil)
                let height = max(local.height, parent.font.pointSize)
                let frame = CGRect(
                    x: local.minX, y: scroll.isFlipped ? local.minY : scroll.bounds.maxY - local.maxY,
                    width: max(local.width, 1), height: height)
                let visible = CGRect(origin: .zero, size: scroll.bounds.size).intersects(frame)
                parent.caret.update(visible ? frame : nil, composing: false)
            }
        }
    }
}

private final class PaletteInputTextView: NSTextView {
    var onCaretChanged: (() -> Void)?
    private var windowTokens: [NotificationToken] = []
    private var scrollToken: NotificationToken?
    private var needsFocus = false

    func requestFocus() {
        needsFocus = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, needsFocus, let window else { return }
            if window.makeFirstResponder(self) { needsFocus = false }
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        onCaretChanged?()
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        onCaretChanged?()
        return accepted
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { onCaretChanged?() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowTokens = []
        scrollToken = nil
        guard let window else { return }
        if needsFocus { requestFocus() }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            let token = center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.onCaretChanged?() }
            }
            windowTokens.append(NotificationToken(token, center: center))
        }
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            let token = center.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.onCaretChanged?() }
            }
            scrollToken = NotificationToken(token, center: center)
        }
        onCaretChanged?()
    }
}
