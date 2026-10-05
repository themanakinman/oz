import SwiftUI

/// Quick AI's surface and controls, with room for a persistent chat sidebar.
struct AIChatWindowView: View {
    @Environment(AIChatCoordinator.self) private var coordinator
    @Environment(AIChatWindowState.self) private var state
    @State private var window: NSWindow?
    private var metrics: InterfaceMetrics { coordinator.metrics }

    var body: some View {
        VStack(spacing: 0) {
            header
            AIChatSplitView(showsSidebar: state.showsSidebar)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowReader { window = $0 })
        .background(PaletteBackground(window: window))
        .overlay {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { state.closeMenu() }
                .allowsHitTesting(state.menu != nil)
        }
        .overlay(alignment: menuAlignment) {
            if state.menu != nil { menu }
        }
        .clipShape(Rectangle())
        .environment(\.metrics, metrics)
        .onChange(of: state.palette.menuQuery) { state.menuSelection = 0 }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard notification.object as? NSWindow === window,
                state.menu == nil, !state.showsFind, state.renaming == nil else { return }
            state.composerFocus = UUID()
        }
        .onChange(of: coordinator.chats.window.session.id) {
            state.closeMenu()
            state.find.query = ""
            state.renaming = nil
        }
    }

    private var header: some View {
        HStack(spacing: metrics.spacing.sm) {
            windowButton("xmark", help: "Close Window  ⌘W") { window?.close() }
            windowButton("minus", help: "Minimize Window  ⌘M") { window?.miniaturize(nil) }
            windowButton("arrow.up.left.and.arrow.down.right", help: "Zoom Window") { window?.zoom(nil) }
            Color.clear
                .frame(width: metrics.spacing.sm)
            windowButton("sidebar.left", help: "Show or Hide Chats  ⌘Y") { state.showsSidebar.toggle() }
            Text(coordinator.title(of: coordinator.chats.window))
                .font(metrics.typography.bar)
                .foregroundStyle(Theme.Colors.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .windowDraggable(true)
        }
        .padding(.horizontal, metrics.spacing.md)
        .frame(height: metrics.size.headerHeight)
    }

    private func windowButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        BarButton(chrome: .rounded, isCompact: true, action: action) {
            Image(systemName: symbol)
                .font(metrics.typography.menuIcon)
                .foregroundStyle(Theme.Colors.textSecondary)
                .frame(width: metrics.size.barBrandIcon)
        }
        .help(help)
        .accessibilityLabel(help)
    }

    private var menuAlignment: Alignment {
        switch state.menu {
        case .conversation: .topLeading
        case .actions, .tools: .bottomTrailing
        default: .topTrailing
        }
    }

    private var menu: some View {
        @Bindable var state = state
        let content = state.content(coordinator: coordinator)
        let bottom = state.menu == .actions || state.menu == .tools
        return PopoverMenu(
            header: content.header, items: state.filteredItems(coordinator: coordinator),
            selection: $state.menuSelection,
            onActivate: { state.activate($0, coordinator: coordinator) },
            search: .init(placeholder: "Search actions", placement: bottom ? .bottom : .top))
            .padding(metrics.spacing.md)
            .padding(
                bottom ? .bottom : .top,
                metrics.size.headerHeight * (bottom ? 1 : 2) + metrics.spacing.md)
            .id(state.menu)
    }
}

private struct AIChatSplitView: NSViewControllerRepresentable {
    @Environment(AIChatCoordinator.self) private var coordinator
    @Environment(AIChatWindowState.self) private var state
    @Environment(AppSettings.self) private var settings
    let showsSidebar: Bool

    func makeNSViewController(context: Context) -> AIChatSplitViewController {
        AIChatSplitViewController(sidebar: sidebar, detail: detail)
    }

    func updateNSViewController(_ view: AIChatSplitViewController, context: Context) {
        view.update(sidebar: sidebar, detail: detail, showsSidebar: showsSidebar)
    }

    private var sidebar: some View {
        AIChatSidebarView().environment(coordinator).environment(state)
            .environment(state.palette).environment(settings).environment(\.metrics, coordinator.metrics)
    }

    private var detail: some View {
        AIChatDetailView().environment(coordinator).environment(state).environment(state.find)
            .environment(state.palette).environment(settings).environment(\.metrics, coordinator.metrics)
    }
}
