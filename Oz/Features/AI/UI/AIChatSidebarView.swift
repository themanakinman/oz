import SwiftUI

/// Palette history rows grouped by day, with saved-chat actions in the shared menu.
struct AIChatSidebarView: View {
    @Environment(AIChatCoordinator.self) private var coordinator
    @Environment(AIChatWindowState.self) private var state
    @Environment(\.metrics) private var metrics
    @State private var query = ""
    @State private var renameText = ""
    @State private var renameFocus = UUID()
    private var history: ChatHistoryStore { coordinator.history }

    private struct Section: Identifiable {
        let title: String
        var chats: [ChatConversation]
        var id: String { title }
    }

    private var sections: [Section] {
        let results = history.search(query)
        var sections: [Section] = []
        let pinned = results.filter(\.isPinned)
        if !pinned.isEmpty { sections.append(Section(title: "Pinned", chats: pinned)) }
        for chat in results where !chat.isPinned {
            let title = DateBucket(for: chat.updatedAt).title
            if sections.last?.title == title {
                sections[sections.count - 1].chats.append(chat)
            } else {
                sections.append(Section(title: title, chats: [chat]))
            }
        }
        return sections
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: metrics.spacing.sm) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.Colors.textTertiary)
                PaletteTextInput(text: $query, prompt: "Search chats", label: "Search chats")
                if !query.isEmpty {
                    BarButton(chrome: .rounded, isCompact: true) { query = "" } label: {
                        Image(systemName: "xmark").foregroundStyle(Theme.Colors.textTertiary)
                    }
                    .accessibilityLabel("Clear search")
                }
                BarButton(chrome: .rounded, isCompact: true, action: coordinator.newChat) {
                    Image(systemName: "square.and.pencil")
                        .font(metrics.typography.menuIcon)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                .help("New Chat  ⌘N")
                .accessibilityLabel("New Chat")
            }
            .padding(.horizontal, metrics.spacing.xl)
            .frame(height: metrics.size.headerHeight)
            if sections.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sections) { section in
                            Text(section.title)
                                .font(metrics.typography.sectionHeader)
                                .foregroundStyle(Theme.Colors.textPrimary)
                                .padding(.horizontal, metrics.spacing.xl)
                                .padding(.top, metrics.spacing.lg)
                                .padding(.bottom, metrics.spacing.sm)
                            ForEach(section.chats) { conversation in row(conversation) }
                        }
                    }
                    .padding(.bottom, metrics.spacing.xl)
                }
                .overflowFade(includingTop: true)
                .thinScrollbar()
            }
        }
        .onChange(of: state.renaming) { _, id in
            guard let id, let conversation = history.conversation(id: id) else { return }
            renameText = conversation.customTitle ?? ""
            renameFocus = UUID()
        }
    }

    private var emptyState: some View {
        VStack(spacing: metrics.spacing.sm) {
            Image(systemName: history.isAvailable ? "bubble.left.and.bubble.right" : "exclamationmark.triangle")
                .font(metrics.typography.headerIcon)
            Text(!history.isAvailable ? "History unavailable" : query.isEmpty ? "No chats yet" : "No results")
                .font(metrics.typography.rowTrailing)
        }
        .foregroundStyle(Theme.Colors.textTertiary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func row(_ conversation: ChatConversation) -> some View {
        if state.renaming == conversation.id {
            PaletteTextInput(
                text: $renameText, prompt: conversation.title, label: "Chat name", focusKey: renameFocus
            ) {
                coordinator.rename(id: conversation.id, to: renameText)
                state.renaming = nil
                state.composerFocus = UUID()
            }
            .padding(.horizontal, metrics.spacing.xl)
            .frame(height: metrics.size.menuRowHeight)
        } else {
            ChatSidebarRow(
                conversation: conversation,
                isAnswering: coordinator.chats.answeringIDs.contains(conversation.id),
                isSelected: coordinator.chats.window.session.id == conversation.id,
                onOpen: { coordinator.openChat(id: conversation.id) },
                onActions: { state.toggleMenu(.conversation(conversation.id)) })
        }
    }
}

private struct ChatSidebarRow: View {
    @Environment(\.metrics) private var metrics
    let conversation: ChatConversation
    let isAnswering: Bool
    let isSelected: Bool
    let onOpen: () -> Void
    let onActions: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: metrics.spacing.sm) {
            Text(conversation.displayTitle)
                .font(metrics.typography.rowTitle)
                .foregroundStyle(Theme.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .paletteResultText(isActive: isSelected || hovered)
            Spacer(minLength: 0)
            if isAnswering {
                ProgressView().controlSize(.mini).accessibilityLabel("Answering")
            } else if conversation.isPinned {
                Image(systemName: "pin.fill")
                    .font(metrics.typography.keyCap)
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .accessibilityLabel("Pinned")
            }
            Button(action: onActions) {
                Image(systemName: "ellipsis")
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .frame(width: metrics.size.barBrandIcon, height: metrics.size.menuRowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovered || isSelected ? 1 : 0)
            .accessibilityLabel("Actions for \(conversation.displayTitle)")
        }
        .padding(.horizontal, metrics.spacing.xl)
        .frame(height: metrics.size.menuRowHeight)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onRightClick(perform: onActions)
        .armedHover($hovered)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open Chat", onOpen)
        .help(conversation.displayTitle)
    }
}
