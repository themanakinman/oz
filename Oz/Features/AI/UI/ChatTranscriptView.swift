import AppKit
import SwiftUI

struct ChatTranscriptView: View {

    @Environment(\.metrics) private var metrics
    let messages: [ChatMessage]
    let status: AIThinkingStatus?
    let usage: AIUsage?
    /// Whether replies should keep the transcript pinned to its end.
    @State private var followsTail = true
    /// Holds a newly sent prompt near the top until the reader scrolls elsewhere.
    @State private var turnAnchorID: UUID?

    /// Below this a backward move is momentum settling, not the reader asking for the wheel.
    private static let deliberateScroll: CGFloat = 2

    /// Where the reader sits and whether that is the end; a growing reply moves the end on its own.
    private struct ScrollMark: Equatable {
        var offset: CGFloat
        var atEnd: Bool
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Not lazy: every anchored jump and the end test measure an estimated height
                VStack(spacing: metrics.spacing.xl) {
                    ForEach(messages) { message in
                        ChatMessageView(
                            message: message,
                            status: message.id == messages.last?.id ? status : nil
                        )
                        .id(message.id)
                    }
                    if let total = usage?.totalTokens {
                        Text("\(total.formatted()) tokens")
                            .font(metrics.typography.rowTrailing)
                            .foregroundStyle(Theme.Colors.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .padding(.horizontal, metrics.spacing.xxl)
                .padding(.top, metrics.spacing.xl)
                .padding(.bottom, metrics.spacing.chatTranscriptBottom)
                // Put the tail target after the clearance so Jump to Latest reaches the real end.
                .id("ai-transcript-tail")
            }
            .edgeDissolve()
            .thinScrollbar()
            // Reopened chats start at the latest message; other anchor roles fight the reader.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onScrollGeometryChange(for: ScrollMark.self) { geometry in
                ScrollMark(
                    offset: geometry.contentOffset.y,
                    // The offset rests at `-insetTop`, so the end is that far past offset plus band
                    atEnd: geometry.contentOffset.y + geometry.containerSize.height
                        + geometry.contentInsets.top
                        >= geometry.contentSize.height - metrics.spacing.chatFollowTailSlack)
            } action: { old, new in
                // Reaching the end while content is too short to scroll does not undo the turn
                // anchor; explicit reader scrolling down into the end resumes tail following.
                if new.atEnd, new.offset > old.offset + Self.deliberateScroll {
                    if turnAnchorID == nil { followsTail = true }
                } else if new.offset < old.offset - Self.deliberateScroll {
                    followsTail = false
                }
            }
            .onScrollPhaseChange { _, phase in
                if phase == .tracking || phase == .interacting || phase == .decelerating {
                    turnAnchorID = nil
                }
            }
            .onChange(of: messages) { oldMessages, newMessages in
                if let sentMessage = newlyAppendedUserMessage(from: oldMessages, to: newMessages) {
                    followsTail = false
                    turnAnchorID = sentMessage.id
                    scroll(proxy, to: sentMessage.id, anchor: .top, animated: true)
                } else if let turnAnchorID,
                    newMessages.contains(where: { $0.id == turnAnchorID })
                {
                    scroll(proxy, to: turnAnchorID, anchor: .top)
                } else {
                    turnAnchorID = nil
                    follow(proxy)
                }
            }
            .onChange(of: usage) { follow(proxy) }
            .overlay(alignment: .bottom) {
                ResumeFollowingButton {
                    followsTail = true
                    turnAnchorID = nil
                    scroll(proxy, to: "ai-transcript-tail", anchor: .bottom, animated: true)
                }
                .padding(.bottom, metrics.spacing.lg)
                .opacity(followsTail ? 0 : 1)
                .allowsHitTesting(!followsTail)
                .animation(.easeOut(duration: Theme.Duration.chatFooter), value: followsTail)
            }
        }
    }

    /// A growing reply follows the tail only while the reader has chosen to stay there.
    private func follow(_ proxy: ScrollViewProxy) {
        guard followsTail else { return }
        proxy.scrollTo("ai-transcript-tail", anchor: .bottom)
    }

    private func scroll<ID: Hashable>(
        _ proxy: ScrollViewProxy, to id: ID, anchor: UnitPoint, animated: Bool = false
    ) {
        if animated {
            withAnimation(.easeOut(duration: Theme.Duration.chatFooter)) {
                proxy.scrollTo(id, anchor: anchor)
            }
        } else {
            proxy.scrollTo(id, anchor: anchor)
        }
    }

    /// A send appends the user prompt and its streaming assistant placeholder as one turn.
    private func newlyAppendedUserMessage(
        from oldMessages: [ChatMessage], to newMessages: [ChatMessage]
    ) -> ChatMessage? {
        guard newMessages.count == oldMessages.count + 2,
            newMessages.prefix(oldMessages.count).elementsEqual(oldMessages),
            newMessages[oldMessages.count].role == .user,
            newMessages[oldMessages.count + 1].role == .assistant
        else { return nil }
        return newMessages[oldMessages.count]
    }
}

/// A fast reply outruns a reader scrolling toward it, so this asks for the tail, not chases it.
private struct ResumeFollowingButton: View {
    @Environment(\.metrics) private var metrics
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Jump to Latest", systemImage: "arrow.down")
                .font(metrics.typography.rowTrailing)
                .foregroundStyle(Theme.Colors.textSecondary)
                .padding(.horizontal, metrics.spacing.lg)
                .padding(.vertical, metrics.spacing.sm)
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: metrics.radius.barControl, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: metrics.radius.barControl, style: .continuous)
                        .strokeBorder(Theme.Colors.border))
        }
        .buttonStyle(.plain)
    }
}

private struct ChatMessageView: View {

    @Environment(\.metrics) private var metrics
    let message: ChatMessage
    let status: AIThinkingStatus?

    @State private var hovered = false

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: metrics.spacing.xxl) }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: metrics.spacing.xxs) {
                content
                if message.state != .streaming { footer }
            }
            .contentShape(Rectangle())
            .onHover { isHovered in
                if isHovered {
                    withAnimation(.easeOut(duration: Theme.Duration.chatFooter)) {
                        hovered = true
                    }
                } else {
                    hovered = false
                }
            }
            if message.role == .assistant { Spacer(minLength: metrics.spacing.xxl) }
        }
    }

    /// Laid out at rest and only faded in, so a hover cannot reflow the transcript
    private var footer: some View {
        HStack(spacing: metrics.spacing.sm) {
            if message.role == .user { timestamp }
            ChatCopyButton(text: message.text)
            if message.role == .assistant { timestamp }
        }
        .opacity(hovered ? 1 : 0)
        // A reply's footer hugs the same `sm` edge as its text.
        .padding(.horizontal, message.role == .user ? metrics.spacing.md : metrics.spacing.sm)
    }

    private var timestamp: some View {
        Text(message.sentAt.formatted(date: .omitted, time: .shortened))
            .font(metrics.typography.keyCap)
            .foregroundStyle(Theme.Colors.textTertiary)
    }

    @ViewBuilder private var content: some View {
        if message.text.isEmpty, message.searches.isEmpty, message.toolUses.isEmpty,
            message.state == .streaming
        {
            ThinkingIndicator(status: status ?? AIThinkingStatus(phrase: "Thinking", opacity: 1))
                .padding(metrics.spacing.md)
        } else {
            bubbleContent
                .font(metrics.typography.rowTitle)
                .foregroundStyle(message.state == .failed ? Theme.Colors.destructive : .primary)
                .textSelection(.enabled)
                // The user bubble is inset because it carries a fill; a reply clears the chevron
                .padding(.horizontal, message.role == .user ? metrics.spacing.xl : metrics.spacing.sm)
                .padding(.vertical, metrics.spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: metrics.radius.row, style: .continuous)
                        .fill(message.role == .user ? Theme.Colors.controlSurface : Color.clear)
                )
        }
    }

    private var bubbleContent: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: metrics.spacing.sm) {
            if !message.images.isEmpty {
                // Wider than the stack's own rhythm: two 96pt tiles at `sm` read as one blob.
                HStack(spacing: metrics.spacing.xl) {
                    ForEach(message.images, id: \.self) { image in
                        ChatImageThumbnail(image: image, edge: metrics.size.chatImageThumb)
                    }
                }
            }
            if !message.documents.isEmpty {
                HStack(spacing: metrics.spacing.md) {
                    ForEach(message.documents, id: \.self) { document in
                        ChatDocumentChip(document: document)
                    }
                }
            }
            if !message.text.isEmpty || !message.searches.isEmpty || !message.toolUses.isEmpty {
                rendered
            }
        }
    }

    /// Only a reply is markdown — what the user typed is shown back exactly as they typed it.
    @ViewBuilder private var rendered: some View {
        if message.role == .assistant {
            VStack(alignment: .leading, spacing: metrics.spacing.lg) {
                ForEach(Array(message.segments.enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .text(let text):
                        MarkdownView(blocks: MarkdownBlock.parse(text))
                    case .search(let search):
                        ChatSearchRow(search: search)
                    case .tool(let use):
                        ChatToolRow(use: use)
                    }
                }
            }
        } else {
            Text(message.text)
        }
    }
}

private struct ThinkingIndicator: View {
    @Environment(\.metrics) private var metrics
    let status: AIThinkingStatus

    @State private var isVisible = false
    var body: some View {
        HStack(spacing: 6) {
            reasoningWord
            HStack(spacing: 0) {
                ForEach(0..<3) { index in
                    ThinkingDot(index: index)
                }
            }
            .padding(.leading, -5)
        }
        .opacity(isVisible ? 1 : 0)
        .offset(y: isVisible ? 0 : 3)
        .animation(.easeOut(duration: 0.18), value: isVisible)
        .onAppear {
            isVisible = true
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(status.phrase)…")
    }

    private var reasoningWord: some View {
        Text(status.phrase)
            .font(metrics.typography.rowTitle)
            .tracking(0.9)
            .foregroundStyle(Theme.Colors.textPrimary.opacity(status.opacity))
    }
}

private struct ThinkingDot: View {
    let index: Int

    var body: some View {
        Text(".")
            .phaseAnimator([CGFloat(0), -2, 0, 2, 0]) { dot, offset in
                dot.offset(y: offset)
            } animation: { _ in
                .easeInOut(duration: 0.18).delay(Double(index) * 0.1)
            }
            .accessibilityHidden(true)
    }
}

/// A sent document names itself: its bytes went to the model, not into the transcript's prose.
private struct ChatDocumentChip: View {
    @Environment(\.metrics) private var metrics
    let document: AIDocument

    private var isPDF: Bool { document.mimeType == AIAttachmentPolicy.pdfMIMEType }

    var body: some View {
        HStack(spacing: metrics.spacing.xs) {
            Image(systemName: isPDF ? "doc.richtext" : "doc.plaintext")
                .font(metrics.typography.chip)
                .symbolRenderingMode(.hierarchical)
            Text(document.name)
                .font(metrics.typography.chip)
                .lineLimit(1)
        }
        .foregroundStyle(Theme.Colors.textSecondary)
        .padding(.horizontal, metrics.spacing.sm)
        .padding(.vertical, metrics.spacing.xxs)
        .background(
            RoundedRectangle(cornerRadius: metrics.radius.attachmentChip, style: .continuous)
                .fill(Theme.Colors.controlSurface)
        )
        .accessibilityLabel("Attached file \(document.name)")
    }
}

/// Decoded once per image off the render path; a streaming transcript re-renders every flush.
struct ChatImageThumbnail: View {
    @Environment(\.metrics) private var metrics
    let image: AIImage
    let edge: CGFloat
    @State private var decoded: NSImage?

    var body: some View {
        Group {
            if let decoded {
                Image(nsImage: decoded)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.clear
            }
        }
        .frame(width: edge, height: edge)
        .clipShape(RoundedRectangle(cornerRadius: metrics.radius.row, style: .continuous))
        .task(id: image) { decoded = NSImage(data: image.data) }
    }
}

/// A tool call inside a reply; the same row grammar the search one uses, with its own glyph.
private struct ChatToolRow: View {
    @Environment(\.metrics) private var metrics
    let use: ChatToolUse

    var body: some View {
        HStack(spacing: metrics.spacing.sm) {
            switch use.state {
            case .running:
                ProgressView().controlSize(.small)
            case .completed:
                glyph("wrench.and.screwdriver")
            case .failed:
                glyph("exclamationmark.triangle")
                    .foregroundStyle(Theme.Colors.destructive)
            }
            Text(use.label)
                .font(metrics.typography.rowTrailing)
                .lineLimit(1)
        }
        .foregroundStyle(Theme.Colors.textSecondary)
        .animation(.easeOut(duration: Theme.Duration.chatFooter), value: use.state)
    }

    /// Sized by the row's own font, like the search row beside it, not by a symbol point size.
    private func glyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(metrics.typography.rowTrailing)
            .symbolRenderingMode(.hierarchical)
    }
}

/// A web search inside a reply: live while it runs, a record of what it looked up once done.
private struct ChatSearchRow: View {
    @Environment(\.metrics) private var metrics
    let search: ChatSearch

    var body: some View {
        HStack(spacing: metrics.spacing.sm) {
            if search.isComplete {
                Image(systemName: "globe")
                    .font(metrics.typography.rowTrailing)
                    .symbolRenderingMode(.hierarchical)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(search.isComplete ? "Searched web" : "Searching web")
                .font(metrics.typography.rowTrailing)
            if let query = search.query, !query.isEmpty {
                Text("· \(query)")
                    .font(metrics.typography.rowTrailing)
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(Theme.Colors.textSecondary)
        .animation(.easeOut(duration: Theme.Duration.chatFooter), value: search.isComplete)
    }
}
