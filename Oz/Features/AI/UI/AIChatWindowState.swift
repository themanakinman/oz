import SwiftUI

/// Presentation state dies with the window; conversations remain on `AIChatSurfacesState`.
@MainActor
@Observable
final class AIChatWindowState {
    enum Menu: Hashable {
        case models, reasoning, tools, actions
        case conversation(UUID)
    }

    let find = ChatFindState()
    let palette = PaletteState()
    var showsSidebar = true
    var showsFind = false
    var composerFocus = UUID()
    var findFocus = UUID()
    var renaming: UUID?
    private(set) var menu: Menu?
    var menuSelection = 0

    func toggleMenu(_ menu: Menu, selection: Int = 0) {
        guard self.menu != menu else { closeMenu(); return }
        self.menu = menu
        menuSelection = selection
        palette.menuQuery = ""
        palette.menuOpen = true
        palette.noteMenuPresentation()
        palette.disarmHoverHighlight(pointerAt: NSEvent.mouseLocation)
    }

    func closeMenu(restoresFocus: Bool = true) {
        menu = nil
        palette.menuOpen = false
        palette.menuQuery = ""
        if restoresFocus { composerFocus = UUID() }
    }

    func openFind() {
        closeMenu(restoresFocus: false)
        showsFind = true
        findFocus = UUID()
    }

    func closeFind() {
        showsFind = false
        find.query = ""
        composerFocus = UUID()
    }

    func filteredItems(coordinator: AIChatCoordinator) -> [PopoverMenuItem] {
        let query = ActionMenuSearchQuery(palette.menuQuery)
        return content(coordinator: coordinator).items.filter { query.score($0.title) != nil }
    }

    func activate(_ index: Int, coordinator: AIChatCoordinator) {
        let items = filteredItems(coordinator: coordinator)
        guard items.indices.contains(index), items[index].isSelectable else { return }
        let item = items[index]
        closeMenu(restoresFocus: false)
        item.action()
        if !showsFind, renaming == nil { composerFocus = UUID() }
    }

    func stepMenu(_ delta: Int, coordinator: AIChatCoordinator) {
        let items = filteredItems(coordinator: coordinator)
        guard !items.isEmpty else { return }
        for step in 1...items.count {
            let index = (menuSelection + delta * step + items.count * step) % items.count
            if items[index].isSelectable { menuSelection = index; return }
        }
    }

    func content(coordinator: AIChatCoordinator) -> PopoverMenuContent {
        let chat = coordinator.chats.window
        switch menu {
        case .models: return AIModelMenu.models(coordinator: coordinator, chat: chat)
        case .reasoning: return AIModelMenu.reasoning(coordinator: coordinator, chat: chat)
        case .tools: return toolMenu(coordinator: coordinator, chat: chat)
        case .actions:
            return AIChatActionsMenu.build(
                chat: chat, coordinator: coordinator, findInChat: openFind)
        case .conversation(let id): return conversationMenu(id: id, coordinator: coordinator)
        case nil: return PopoverMenuContent(items: [])
        }
    }

    private func toolMenu(coordinator: AIChatCoordinator, chat: AIChatState) -> PopoverMenuContent {
        let servers = coordinator.mcpServers
        var items: [PopoverMenuItem] = [
            PopoverMenuItem(
                title: chat.toolScope.isEnabled ? "Disable Tools" : "Enable Tools",
                systemImage: "wrench.and.screwdriver"
            ) {
                coordinator.setToolsEnabled(!chat.toolScope.isEnabled, in: chat)
            },
            PopoverMenuItem(
                title: "Files", icon: .symbol("folder"), isEnabled: chat.toolScope.isEnabled,
                detail: chat.toolScope.allows(AIFileTools.handle) ? "✓" : nil
            ) { coordinator.toggleToolServer(AIFileTools.handle, in: chat) }
        ]
        items += servers.enumerated().map { index, server in
            PopoverMenuItem(
                title: server.name.isEmpty ? server.slug : server.name, icon: .blank,
                isEnabled: chat.toolScope.isEnabled,
                sectionTitle: index == 0 ? "Servers" : nil,
                detail: chat.toolScope.allows(server.slug) ? "✓" : nil
            ) {
                coordinator.toggleToolServer(server.slug, in: chat)
            }
        }
        items.append(PopoverMenuItem(
            title: "MCP Settings", systemImage: "slider.horizontal.3", startsSection: !items.isEmpty
        ) { coordinator.showMCPSettings() })
        return PopoverMenuContent(header: "Tools", items: items)
    }

    private func conversationMenu(id: UUID, coordinator: AIChatCoordinator) -> PopoverMenuContent {
        guard let conversation = coordinator.history.conversation(id: id) else {
            return PopoverMenuContent(items: [])
        }
        return PopoverMenuContent(header: conversation.displayTitle, items: [
            PopoverMenuItem(
                title: conversation.isPinned ? "Unpin Chat" : "Pin Chat", systemImage: "pin"
            ) { coordinator.togglePin(id: id) },
            PopoverMenuItem(title: "Rename Chat", systemImage: "pencil") { self.renaming = id },
            PopoverMenuItem(title: "Copy Chat", systemImage: "doc.on.doc", startsSection: true) {
                coordinator.copyChat(id: id)
            },
            PopoverMenuItem(title: "Export as Markdown", systemImage: "square.and.arrow.up") {
                coordinator.exportChat(id: id)
            },
            PopoverMenuItem(
                title: "Delete Chat", systemImage: "trash", startsSection: true, isDestructive: true
            ) { Task { await coordinator.deleteChat(id: id) } },
            PopoverMenuItem(title: "Delete All Chats", systemImage: "trash.slash", isDestructive: true) {
                Task { await coordinator.deleteAllChats() }
            }
        ])
    }
}
