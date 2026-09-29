import AppKit

/// Window-scoped chords and pointer movement; visible chrome is drawn by the palette views.
@MainActor
final class AIChatWindowChrome: WindowChrome {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("AIChatWindow")
    private let coordinator: AIChatCoordinator
    private let state: AIChatWindowState
    private weak var window: NSWindow?
    private var monitor: Any?
    private var chat: AIChatState { coordinator.chats.window }

    init(coordinator: AIChatCoordinator, state: AIChatWindowState) {
        self.coordinator = coordinator
        self.state = state
    }

    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    func install(in window: NSWindow) {
        self.window = window
        window.identifier = Self.windowIdentifier
        window.isMovableByWindowBackground = false
        observeTitle()
        let events: NSEvent.EventTypeMask = [.keyDown, .mouseMoved, .scrollWheel]
        monitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            guard let self, let window = self.window, event.window === window, window.isKeyWindow
            else { return event }
            if event.type == .mouseMoved {
                state.palette.notePointerMoved(to: NSEvent.mouseLocation)
            } else {
                state.palette.disarmHoverHighlight(pointerAt: NSEvent.mouseLocation)
            }
            guard event.type == .keyDown else { return event }
            return handle(event, in: window) ? nil : event
        }
    }

    private func observeTitle() {
        withObservationTracking {
            window?.title = coordinator.title(of: chat)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeTitle() }
        }
    }

    private func handle(_ event: NSEvent, in window: NSWindow) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = (ASCIIKeyboardLayout.character(for: event) ?? event.charactersIgnoringModifiers)?
            .lowercased()
        if state.menu != nil, modifiers.isDisjoint(with: [.command, .option, .control]) {
            switch event.keyCode {
            case 53: state.closeMenu()
            case 125: state.stepMenu(1, coordinator: coordinator)
            case 126: state.stepMenu(-1, coordinator: coordinator)
            case 36, 76: state.activate(state.menuSelection, coordinator: coordinator)
            default: return false
            }
            return true
        }
        switch (modifiers, key) {
        case ([.command], "f"): state.openFind()
        case ([.command], "g"), ([.command, .shift], "g"):
            state.find.step(modifiers.contains(.shift) ? -1 : 1, in: chat.session.messages)
        case ([.command], "k"): state.toggleMenu(.actions)
        case ([.command], "n"): coordinator.newChat()
        case ([.command], "y"): state.showsSidebar.toggle()
        case ([.command], "w"): window.close()
        case ([.command], "m"): window.miniaturize(nil)
        case ([.command], "r") where AIChatActionsMenu.canRegenerate(chat):
            coordinator.regenerate(in: chat)
        case ([.command, .shift], "c") where chat.lastAssistantText != nil,
             ([.command, .shift], "n") where chat.lastAssistantText != nil:
            coordinator.copyLastResponse(in: chat)
        case ([.command], ".") where chat.isStreaming: coordinator.stopResponse(in: chat)
        case ([.command, .option], ","): coordinator.showSettings()
        case ([.command], "v"):
            guard (window.firstResponder as? NSView)?.accessibilityLabel() == "Message"
            else { return false }
            return coordinator.attachPastedFile(files: PasteboardFiles.urls(on: .general), to: chat)
        default:
            if event.keyCode == 53, state.renaming != nil {
                state.renaming = nil
                state.composerFocus = UUID()
                return true
            }
            if event.keyCode == 53, state.showsFind { state.closeFind(); return true }
            return false
        }
        return true
    }
}

@MainActor
enum AIChatActionsMenu {
    static func canRegenerate(_ chat: AIChatState) -> Bool {
        !chat.isStreaming && chat.session.messages.last?.role == .assistant
    }

    static func build(
        chat: AIChatState, coordinator: AIChatCoordinator, findInChat: @escaping () -> Void
    ) -> PopoverMenuContent {
        var items: [PopoverMenuItem] = []
        if chat.isStreaming {
            items.append(PopoverMenuItem(title: "Stop Response", systemImage: "stop.fill", shortcut: "⌘.") {
                coordinator.stopResponse(in: chat)
            })
        }
        items.append(PopoverMenuItem(title: "New Chat", systemImage: "plus.bubble", shortcut: "⌘N") {
            coordinator.newChat()
        })
        if canRegenerate(chat) {
            items.append(PopoverMenuItem(
                title: "Regenerate Response", systemImage: "arrow.clockwise", shortcut: "⌘R"
            ) { coordinator.regenerate(in: chat) })
        }
        if chat.lastAssistantText != nil {
            items.append(PopoverMenuItem(
                title: "Copy Last Response", systemImage: "doc.on.doc", startsSection: true, shortcut: "⇧⌘C"
            ) { coordinator.copyLastResponse(in: chat) })
        }
        if coordinator.isSaved(chat) {
            items += [
                PopoverMenuItem(title: "Copy Chat", systemImage: "text.bubble") {
                    coordinator.copyChat(id: chat.session.id)
                },
                PopoverMenuItem(title: "Export as Markdown", systemImage: "square.and.arrow.up") {
                    coordinator.exportChat(id: chat.session.id)
                },
                PopoverMenuItem(
                    title: coordinator.isPinned(chat) ? "Unpin Chat" : "Pin Chat", systemImage: "pin"
                ) { coordinator.togglePin(id: chat.session.id) },
                PopoverMenuItem(title: "Delete Chat", systemImage: "trash", isDestructive: true) {
                    Task { await coordinator.deleteChat(id: chat.session.id) }
                }
            ]
        }
        items.append(PopoverMenuItem(title: "Attach Files", systemImage: "paperclip", startsSection: true) {
            coordinator.chooseFiles(for: chat)
        })
        if !chat.pendingAttachments.isEmpty {
            items.append(PopoverMenuItem(title: "Remove Attachments", systemImage: "xmark") {
                coordinator.clearAttachments(in: chat)
            })
        }
        items += [
            PopoverMenuItem(title: "Find in Chat", systemImage: "magnifyingglass", shortcut: "⌘F", action: findInChat),
            PopoverMenuItem(title: "AI Settings", systemImage: "slider.horizontal.3", shortcut: "⌥⌘,") {
                coordinator.showSettings()
            }
        ]
        return PopoverMenuContent(header: coordinator.title(of: chat), items: items)
    }
}
