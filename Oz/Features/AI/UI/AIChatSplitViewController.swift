import AppKit
import SwiftUI

/// Saves the sidebar's width without installing AppKit's opaque sidebar material.
final class AIChatSplitViewController: NSSplitViewController {
    private let sidebar: NSHostingController<AnyView>
    private let detail: NSHostingController<AnyView>

    init(sidebar: some View, detail: some View) {
        self.sidebar = NSHostingController(rootView: AnyView(sidebar))
        self.detail = NSHostingController(rootView: AnyView(detail))
        super.init(nibName: nil, bundle: nil)
        splitView = ChatSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        let sidebarItem = NSSplitViewItem(viewController: self.sidebar)
        sidebarItem.minimumThickness = Theme.Size.aiChatSidebarMinimum
        sidebarItem.maximumThickness = Theme.Size.aiChatSidebarMaximum
        sidebarItem.canCollapse = true

        let detailItem = NSSplitViewItem(viewController: self.detail)
        detailItem.minimumThickness = Theme.Size.aiChatDetailMinimum

        addSplitViewItem(sidebarItem)
        addSplitViewItem(detailItem)
        splitView.autosaveName = "AIChatSplitView"
    }

    func update(sidebar: some View, detail: some View, showsSidebar: Bool) {
        self.sidebar.rootView = AnyView(sidebar)
        self.detail.rootView = AnyView(detail)
        splitViewItems[0].isCollapsed = !showsSidebar
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

private final class ChatSplitView: NSSplitView {
    override var dividerColor: NSColor { NSColor(Theme.Colors.border) }
    override func draw(_ dirtyRect: NSRect) {}
}
