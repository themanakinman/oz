import AppKit

/// A document window can use the palette surface without inheriting its dismiss-on-blur policy.
final class PaletteAppWindow: NSWindow {
    var usesPaletteCursor = false
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
        guard usesPaletteCursor,
            [.mouseMoved, .mouseEntered, .mouseExited, .cursorUpdate,
             .leftMouseDown, .leftMouseUp, .leftMouseDragged].contains(event.type),
            let contentView
        else { return }
        let point = contentView.convert(convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        guard contentView.bounds.insetBy(dx: 4, dy: 4).contains(point) else { return }
        var hit = contentView.hitTest(point)
        var editsText = false
        while let view = hit {
            if let text = view as? NSTextView, text.isEditable { editsText = true; break }
            if let field = view as? NSTextField, field.isEditable { editsText = true; break }
            hit = view.superview
        }
        let cursor: NSCursor = editsText ? .iBeam : .arrow
        if NSCursor.current !== cursor { cursor.set() }
    }
}
