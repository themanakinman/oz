import AppKit
import SwiftUI

/// Built on first show, torn down on close so its SwiftUI tree deallocates. Never quits the app.
@MainActor
final class AppWindowController: NSObject, NSWindowDelegate {
    enum Surface { case standard, palette }

    private let title: String
    private let contentSize: CGSize
    private let minimumSize: CGSize
    private let isResizable: Bool
    private let autosaveName: String?
    private let activation: ActivationPolicy
    private let surface: Surface
    private var window: NSWindow?
    /// Rebuilt with the window, so a chrome's state never outlives the window it decorated.
    private var chrome: WindowChrome?

    /// The opening size is also the resize floor unless a smaller `minimumSize` is named.
    init(
        title: String, contentSize: CGSize, minimumSize: CGSize? = nil, resizable: Bool = false,
        autosaveName: String? = nil, surface: Surface = .standard, activation: ActivationPolicy
    ) {
        self.title = title
        self.contentSize = contentSize
        self.minimumSize = minimumSize ?? contentSize
        self.isResizable = resizable
        self.autosaveName = autosaveName
        self.activation = activation
        self.surface = surface
    }

    /// Returns `true` when a window was built, `false` when an already-open one was re-raised.
    @discardableResult
    func show<Content: View>(
        chrome: WindowChrome? = nil, @ViewBuilder content: () -> Content
    ) -> Bool {
        let root = content().frame(
            minWidth: surface == .palette ? minimumSize.width : nil,
            minHeight: surface == .palette ? minimumSize.height : nil)
        return show(chrome: chrome) {
            let hosting = NSHostingController(rootView: root)
            hosting.sizingOptions = surface == .palette ? [.minSize] : []
            return hosting
        }
    }

    /// AppKit-built content; Settings needs it for a real `NSSplitViewController`.
    @discardableResult
    func show(chrome: WindowChrome? = nil, contentViewController: () -> NSViewController) -> Bool {
        if let window {
            raise(window)
            return false
        }
        self.chrome = chrome
        let window = makeWindow(content: contentViewController(), chrome: chrome)
        self.window = window
        raise(window)
        return true
    }

    /// Re-raise an open window without rebuilding it; `false` when none is open.
    @discardableResult
    func focus() -> Bool {
        guard let window else { return false }
        raise(window)
        return true
    }

    func close() {
        window?.close()
    }

    @discardableResult
    func hideIfVisible() -> Bool {
        guard let window, window.isVisible, !window.isMiniaturized else { return false }
        window.orderOut(nil)
        activation.windowDidClose(window)
        return true
    }

    /// The title bar sits inside the frame but outside the layout area, so it is added back.
    func fitContent(width: CGFloat, height: CGFloat) {
        guard let window else { return }
        let titlebar = window.frame.height - window.contentLayoutRect.height
        let size = CGSize(width: width, height: height + titlebar)
        guard window.contentMinSize != size else { return }
        let top = window.frame.maxY
        window.contentMinSize = size
        window.setContentSize(size)
        var frame = window.frame
        frame.origin.y = top - frame.height
        window.setFrame(frame, display: true, animate: false)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window else { return }
        self.window = nil
        self.chrome = nil
        activation.windowDidClose(window)
    }

    // MARK: - Private

    private func makeWindow(content: NSViewController, chrome: WindowChrome?) -> NSWindow {
        var style: NSWindow.StyleMask = surface == .palette
            ? [.borderless, .closable, .miniaturizable, .fullSizeContentView]
            : [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if isResizable { style.insert(.resizable) }
        let window = PaletteAppWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        window.title = title
        if surface == .palette {
            window.isOpaque = false
            window.backgroundColor = .clear
            window.acceptsMouseMovedEvents = true
            window.usesPaletteCursor = true
        }
        // Edge-to-edge under a transparent titlebar, so it reads as one surface.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = surface != .palette
        window.isReleasedWhenClosed = false
        // AppKit would otherwise resurrect the window at launch, before anything is wired up.
        window.isRestorable = false
        window.delegate = self

        chrome?.install(in: window)
        window.contentViewController = content
        // `contentViewController` resets the frame to the controller's fitting size.
        window.setContentSize(contentSize)

        if let autosaveName {
            window.setFrameAutosaveName(autosaveName)
            if !window.setFrameUsingName(autosaveName) { window.center() }
        } else {
            window.center()
        }
        window.contentMinSize = minimumSize
        let restoredSize = window.contentRect(forFrameRect: window.frame).size
        if restoredSize.width < minimumSize.width || restoredSize.height < minimumSize.height {
            window.setContentSize(CGSize(
                width: max(restoredSize.width, minimumSize.width),
                height: max(restoredSize.height, minimumSize.height)))
        }
        return window
    }

    private func raise(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        activation.windowDidOpen(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // `NSApp.activate` is async, so re-assert next turn — never onto a window closed since.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let window, self?.window === window, window.isVisible else { return }
            window.makeKeyAndOrderFront(nil)
        }
    }
}
