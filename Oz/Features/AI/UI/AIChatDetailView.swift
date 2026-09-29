import SwiftUI

/// The same prompt, transcript and floating footer as Quick AI, on a resizable surface.
struct AIChatDetailView: View {
    @Environment(AIChatCoordinator.self) private var coordinator
    @Environment(AIChatWindowState.self) private var state
    @Environment(ChatFindState.self) private var find
    @Environment(\.metrics) private var metrics
    @State private var isDropTargeted = false
    @State private var showsContext = false
    private var chat: AIChatState { coordinator.chats.window }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .overlay(alignment: .bottom) { footer }
            .overlay(alignment: .bottomTrailing) {
                if showsContext {
                    ContextCard(report: coordinator.contextReport(for: chat))
                        .padding(.trailing, metrics.spacing.md)
                        .padding(.bottom, metrics.size.bottomBarHeight + metrics.spacing.md)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: Theme.Duration.tooltip), value: showsContext)
            .dropDestination(for: URL.self) { files, _ in
                coordinator.attach(files: files, to: chat)
                return true
            } isTargeted: { isDropTargeted = $0 }
            .overlay {
                if isDropTargeted {
                    Rectangle().strokeBorder(
                        Theme.Colors.dropTarget,
                        style: StrokeStyle(
                            lineWidth: metrics.scaled(Theme.Size.dropHintStroke),
                            dash: [metrics.scaled(Theme.Size.dropHintDash)]))
                        .padding(metrics.spacing.md)
                        .allowsHitTesting(false)
                }
            }
    }

    @ViewBuilder private var content: some View {
        if chat.session.messages.isEmpty {
            let unavailable = coordinator.availability(for: chat)
            AIEmptyState(
                message: chat.notice ?? unavailable,
                canConfigure: chat.notice != nil || unavailable != nil,
                onConfigure: coordinator.showSettings)
        } else {
            let occurrences = find.occurrences(in: chat.session.messages)
            ChatTranscriptView(
                messages: chat.session.messages, status: chat.liveStatus, usage: chat.usage,
                surface: .window,
                onRegenerate: chat.isStreaming ? nil : { coordinator.regenerate(in: chat) },
                onChoose: chat.isStreaming ? nil : { coordinator.send($0, in: chat) },
                onRerun: chat.isStreaming ? nil : { coordinator.rerun($0, in: chat) },
                find: find.isSearching ? ChatFindHighlight(
                    query: find.needle, matches: Set(occurrences.map(\.messageID)),
                    current: find.currentOccurrence(in: occurrences)) : nil)
                .id(chat.session.id)
        }
    }

    private var header: some View {
        @Bindable var chat = chat
        return VStack(alignment: .leading, spacing: metrics.spacing.sm) {
            HStack(alignment: .top, spacing: metrics.spacing.sm) {
                ChatComposerTextView(text: $chat.draft, focusKey: state.composerFocus, onSubmit: submit)
                    .frame(minWidth: metrics.size.searchFieldMinWidth)
                    .frame(maxWidth: .infinity)
                AIModelButton(
                    title: coordinator.selectedModelTitle(for: chat),
                    icon: coordinator.selectedModelIcon(for: chat), isOpen: state.menu == .models
                ) {
                    state.toggleMenu(.models, selection: AIModelMenu.modelHighlight(coordinator: coordinator, chat: chat))
                }
                if !coordinator.reasoningEfforts(for: chat).isEmpty {
                    AIReasoningButton(
                        title: coordinator.selectedReasoningTitle(for: chat), isOpen: state.menu == .reasoning
                    ) {
                        state.toggleMenu(
                            .reasoning, selection: AIModelMenu.reasoningHighlight(coordinator: coordinator, chat: chat))
                    }
                }
            }
            .padding(.vertical, metrics.spacing.sm)
            if !chat.pendingAttachments.isEmpty || coordinator.addressedServer(in: chat.draft) != nil {
                attachments
            }
            if let notice = chat.notice, !chat.session.messages.isEmpty {
                Text(notice)
                    .font(metrics.typography.rowTrailing)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            if state.showsFind { findBar }
        }
        .padding(.horizontal, metrics.spacing.xxl)
        .padding(.bottom, metrics.spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var attachments: some View {
        ScrollView(.horizontal) {
            HStack(spacing: metrics.spacing.sm) {
                if let server = coordinator.addressedServer(in: chat.draft) {
                    ComposerChip(symbol: "wrench.and.screwdriver", label: "@\(server.slug)")
                }
                ForEach(chat.pendingAttachments) { attachment in
                    AttachmentChip(attachment: attachment) {
                        coordinator.removeAttachment(attachment.id, in: chat)
                    }
                }
            }
        }
        .scrollIndicators(.never)
    }

    private var findBar: some View {
        @Bindable var find = find
        let occurrences = find.occurrences(in: chat.session.messages)
        return HStack(spacing: metrics.spacing.sm) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.Colors.textTertiary)
            PaletteTextInput(
                text: $find.query, prompt: "Find in Chat", label: "Find in chat", focusKey: state.findFocus
            ) {
                find.step(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? -1 : 1,
                    in: chat.session.messages)
            }
            Text(occurrences.isEmpty ? "No matches" : "\(find.current + 1) of \(occurrences.count)")
                .font(metrics.typography.keyCap)
                .foregroundStyle(Theme.Colors.textTertiary)
            iconButton("chevron.up", help: "Previous Match  ⇧⌘G") { find.step(-1, in: chat.session.messages) }
                .disabled(occurrences.isEmpty)
            iconButton("chevron.down", help: "Next Match  ⌘G") { find.step(1, in: chat.session.messages) }
                .disabled(occurrences.isEmpty)
            iconButton("xmark", help: "Close Find  Esc", action: state.closeFind)
        }
    }

    private var footer: some View {
        HStack(spacing: metrics.spacing.sm) {
            iconButton("paperclip", help: "Attach Files") { coordinator.chooseFiles(for: chat) }
            iconButton("wrench.and.screwdriver", help: "Choose this chat's tools") {
                state.toggleMenu(.tools)
            }
                .disabled(!coordinator.capabilities(for: chat).tools)
            if coordinator.capabilities(for: chat).webSearch {
                BarButton(chrome: .rounded, isCompact: true) {
                    coordinator.aiSettings.webSearchEnabled.toggle()
                } label: {
                    Image(systemName: "globe")
                        .foregroundStyle(coordinator.aiSettings.webSearchEnabled
                            ? Theme.Colors.webSearchEnabled : Theme.Colors.webSearchDisabled)
                }
                .help(coordinator.aiSettings.webSearchEnabled ? "Web search is on" : "Web search is off")
                .accessibilityLabel("Web search")
                .accessibilityValue(coordinator.aiSettings.webSearchEnabled ? "On" : "Off")
            }
            Spacer(minLength: 0)
            Text(coordinator.contextReport(for: chat, detailed: false).fill.formatted(.percent.precision(.fractionLength(0))))
                .font(metrics.typography.keyCap)
                .foregroundStyle(Theme.Colors.textTertiary)
                .onHover { showsContext = $0 }
                .accessibilityLabel(coordinator.contextReport(for: chat, detailed: false).accessibilitySummary)
            HStack(spacing: 2) {
                BarButton(action: submit) {
                    HStack(spacing: metrics.spacing.sm) {
                        Text(chat.isStreaming ? "Stop" : "Send").font(metrics.typography.bar)
                        KeyCapChip(text: "↵", style: .plain)
                    }
                    .foregroundStyle(Theme.Colors.textPrimary)
                }
                BarButton { state.toggleMenu(.actions) } label: {
                    HStack(spacing: metrics.spacing.sm) {
                        Text("Actions").font(metrics.typography.bar)
                        KeyCapChip(text: "⌘", style: .plain)
                        KeyCapChip(text: "K", style: .plain)
                    }
                    .foregroundStyle(Theme.Colors.textSecondary)
                }
            }
            .padding(metrics.spacing.xs)
            .paletteSurface(in: Rectangle())
        }
        .padding(.horizontal, metrics.spacing.md)
        .frame(height: metrics.size.bottomBarHeight)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        BarButton(chrome: .rounded, isCompact: true, action: action) {
            Image(systemName: symbol)
                .font(metrics.typography.menuIcon)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
        .help(help)
        .accessibilityLabel(help)
    }

    private func submit() {
        if chat.isStreaming {
            coordinator.stopResponse(in: chat)
        } else if coordinator.send(chat.draft, in: chat) {
            chat.draft = ""
            state.composerFocus = UUID()
        }
    }
}

/// Oz's own card, never a popover: the tokens the chat holds, then what the next turn sends.
private struct ContextCard: View {
    @Environment(\.metrics) private var metrics
    let report: ChatContextReport

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.radius.menuPanel, style: .continuous)
        VStack(alignment: .leading, spacing: metrics.spacing.md) {
            HStack {
                Text("Context").font(metrics.typography.rowTitle)
                Spacer(minLength: metrics.spacing.xxl)
                Text(report.fill.formatted(.percent.precision(.fractionLength(0))))
                    .font(metrics.typography.rowTitle)
                    .monospacedDigit()
                    .foregroundStyle(report.tint)
            }
            GeometryReader { geometry in
                Rectangle().fill(Theme.Colors.border)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(report.tint)
                            .frame(width: geometry.size.width * min(max(report.fill, 0), 1))
                    }
            }
            .frame(height: metrics.spacing.xs)
            if report.historyBytes > report.budget {
                Text("The oldest messages no longer fit and are left out.")
                    .font(metrics.typography.keyCap)
                    .foregroundStyle(Theme.Colors.destructive)
            }
            Grid(
                alignment: .leading, horizontalSpacing: metrics.spacing.xl,
                verticalSpacing: metrics.spacing.xs
            ) {
                section("Tokens")
                if let usage = report.usage, let context = usage.contextTokens {
                    row("In context", tokens(context, of: usage.contextWindow))
                    row("Input", input(usage))
                    row("Output", output(usage))
                    if let cost = usage.costUSD {
                        row(
                            "Cost",
                            cost.formatted(
                                .currency(code: "USD").precision(.significantDigits(2))))
                    }
                } else {
                    row("Last reply", "Not reported yet")
                }
                section("Next message")
                row("Model", report.modelTitle)
                row("History", "\(bytes(report.historyBytes)) of \(bytes(report.budget))")
                row("Messages", "\(report.sentMessages) of \(report.totalMessages)")
                if report.stagedFiles > 0 {
                    row("Attached", "\(report.stagedFiles) · \(bytes(report.stagedBytes))")
                }
                row("System prompt", report.systemPrompt ? "On" : "Off")
                row("Web search", report.webSearch ? "On" : "Off")
                row(
                    "MCP servers",
                    report.toolServers == 0 ? "None" : "\(report.toolServers) in reach")
            }
            .font(metrics.typography.rowTrailing)
        }
        .padding(metrics.spacing.xl)
        .frame(width: metrics.scaled(Theme.Size.chatContextCard), alignment: .leading)
        .paletteSurface(in: shape, backgroundOpacity: 0.9, blursBackdrop: true)
    }

    private func section(_ title: String) -> some View {
        GridRow {
            Text(title.uppercased())
                .font(metrics.typography.disclosure)
                .foregroundStyle(Theme.Colors.textTertiary)
                .gridCellColumns(2)
                .padding(.top, metrics.spacing.xs)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(Theme.Colors.textSecondary)
            Text(value).monospacedDigit().lineLimit(1).truncationMode(.middle)
        }
    }

    private func bytes(_ count: Int) -> String {
        count.formatted(.byteCount(style: .file))
    }

    private func tokens(_ count: Int, of window: Int?) -> String {
        guard let window else { return count.formatted() }
        return "\(count.formatted()) of \(window.formatted(.number.notation(.compactName)))"
    }

    private func input(_ usage: AIUsage) -> String {
        let prompt = (usage.inputTokens ?? 0) + (usage.cachedInputTokens ?? 0)
        guard let cached = usage.cachedInputTokens, cached > 0 else { return prompt.formatted() }
        return "\(prompt.formatted()) · \(cached.formatted()) cached"
    }

    private func output(_ usage: AIUsage) -> String {
        let output = usage.outputTokens ?? 0
        guard let thinking = usage.reasoningTokens, thinking > 0 else { return output.formatted() }
        return "\(output.formatted()) · \(thinking.formatted()) thinking"
    }
}

extension ChatContextReport {
    fileprivate var tint: Color {
        if fill >= 1 { return Theme.Colors.destructive }
        return fill >= 0.8 ? Theme.Colors.warning : Theme.Colors.textSecondary
    }
}
