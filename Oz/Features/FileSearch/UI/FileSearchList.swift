import AppKit
import SwiftUI

struct FileSearchList: View {

    @Environment(\.metrics) private var metrics
    let title: String
    let results: [FileSearchResult]
    let selectedID: FileSearchResult.ID?
    let scroll: ScrollIntent
    let onSelect: (FileSearchResult) -> Void
    let onActivate: (FileSearchResult) -> Void
    let onActions: (FileSearchResult) -> Void

    private var firstRowSelected: Bool {
        selectedID != nil && selectedID == results.first?.id
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    SectionHeader(title: title, isFirst: true)
                    ForEach(results) { result in
                        FileSearchRow(result: result, selected: result.id == selectedID)
                            .selectionFrame(result.id == selectedID)
                            .contentShape(Rectangle())
                            .onRowClick(
                                select: { onSelect(result) }, activate: { onActivate(result) }
                            )
                            .onRightClick { onActions(result) }
                    }
                }
                .padding(.horizontal, metrics.spacing.md)
                .padding(.top, metrics.spacing.xs)
                .padding(.bottom, metrics.spacing.md)
                .hideNativeScrollers()
                .scrollOriginAnchor()
            }
            .edgeDissolve()
            .thinScrollbar()
            .scrollFollowsSelection(
                scroll, row: selectedID, atOrigin: firstRowSelected, proxy: proxy)
        }
        .onDisappear { IconCache.purgeFitted() }
    }
}

/// Shared by File Search and the launcher's Files & Folders section, so a result reads the same
/// whichever path surfaced it.
struct FileSearchRow: View {

    @Environment(\.metrics) private var metrics
    let result: FileSearchResult
    let selected: Bool
    /// The root search lends its ⌘1…⌘0 hints; the dedicated screen has none to show.
    var resultIndex: Int? = nil
    var onActivateFromDragHandle: (() -> Void)?
    @Environment(PaletteState.self) private var palette
    @State private var image: NSImage?
    @State private var hovered = false

    init(
        result: FileSearchResult, selected: Bool, resultIndex: Int? = nil,
        onActivateFromDragHandle: (() -> Void)? = nil
    ) {
        self.result = result
        self.selected = selected
        self.resultIndex = resultIndex
        self.onActivateFromDragHandle = onActivateFromDragHandle
        _image = State(initialValue: IconCache.cachedFitted(forFile: result.id))
    }

    private var fill: Color {
        if selected { return Theme.Colors.selection }
        if hovered { return Theme.Colors.rowHover }
        return .clear
    }

    /// A folder is named by where it sits: half the hits are some `src` or `Oz`.
    private var label: Text {
        guard result.isDirectory, !result.parentName.isEmpty else { return Text(result.name) }
        let parent = Text("\(result.parentName)/").foregroundStyle(.secondary)
        return Text("\(parent)\(result.name)")
    }

    var body: some View {
        HStack(spacing: metrics.spacing.lg) {
            Group {
                if let image {
                    Image(nsImage: image).resizable()
                } else {
                    RoundedRectangle(cornerRadius: metrics.radius.thumbnail, style: .continuous)
                        .fill(Theme.Colors.iconPlaceholder)
                }
            }
            .frame(width: metrics.size.rowIcon, height: metrics.size.rowIcon)
            // The column is too narrow for a path beside the name; the preview states it instead.
            label
                .font(metrics.typography.rowTitle)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if resultIndex != nil {
                Text(result.isDirectory ? "Folder" : "File")
                    .font(metrics.typography.rowTrailing)
                    .foregroundStyle(.secondary)
            }
            if palette.commandHeld, let resultIndex,
                let shortcut = PaletteState.resultShortcut(at: resultIndex)
            {
                Text(shortcut)
                    .font(metrics.typography.rowTrailing)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, metrics.spacing.md)
        .padding(.vertical, metrics.spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: metrics.radius.row, style: .continuous)
                .fill(fill)
        )
        .armedHover($hovered)
        .overlay {
            if let onActivateFromDragHandle {
                FileSearchDragHandle(
                    url: result.url,
                    onActivate: onActivateFromDragHandle,
                    onHoverChanged: { inside in
                        hovered = inside && palette.hoverHighlightArmed
                    }
                )
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(result.name)
        .accessibilityValue(result.parentPath)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .task(id: IconRequest(result.id)) {
            if let warm = IconCache.cachedFitted(forFile: result.id) {
                image = warm
                return
            }
            image = await IconCache.loadFittedAsync(forFile: result.id)
        }
    }
}

struct FileSearchDragHandle: NSViewRepresentable {
    let url: URL
    let onActivate: () -> Void
    let onHoverChanged: (Bool) -> Void

    func makeNSView(context: Context) -> NSView { FileSearchDragView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? FileSearchDragView)?.bind(
            url: url, onActivate: onActivate, onHoverChanged: onHoverChanged)
    }
}

private final class FileSearchDragView: NSView, NSDraggingSource {
    private static let threshold: CGFloat = 4
    private static let previewSize = NSSize(width: 48, height: 48)

    private var url: URL?
    private var onActivate: (() -> Void)?
    private var onHoverChanged: ((Bool) -> Void)?

    func bind(
        url: URL, onActivate: @escaping () -> Void, onHoverChanged: @escaping (Bool) -> Void
    ) {
        self.url = url
        self.onActivate = onActivate
        self.onHoverChanged = onHoverChanged
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseMoved(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        switch NSApp.currentEvent?.type {
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged: return nil
        default: return super.hitTest(point)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            onActivate?()
            return
        }

        let start = NSEvent.mouseLocation
        var passedThreshold = false
        window.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp], timeout: NSEvent.foreverDuration,
            mode: .eventTracking
        ) { tracked, stop in
            guard let tracked, tracked.type != .leftMouseUp else {
                stop.pointee = true
                return
            }
            let mouse = NSEvent.mouseLocation
            guard hypot(mouse.x - start.x, mouse.y - start.y) > Self.threshold else { return }
            passedThreshold = true
            stop.pointee = true
        }

        guard passedThreshold, let url else {
            onActivate?()
            return
        }
        beginDrag(url, with: event)
    }

    private func beginDrag(_ url: URL, with event: NSEvent) {
        let icon =
            IconCache.cachedFitted(forFile: url.path)
            ?? NSWorkspace.shared.icon(forFile: url.path)
        let preview = NSImage(size: Self.previewSize, flipped: false) { rect in
            icon.draw(in: rect)
            return true
        }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let origin = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(
            NSRect(
                x: origin.x - preview.size.width / 2,
                y: origin.y - preview.size.height / 2,
                width: preview.size.width,
                height: preview.size.height
            ), contents: preview
        )
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }
}
