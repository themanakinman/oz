import SwiftUI

struct LauncherList: View {

    @Environment(\.metrics) private var metrics
    @Environment(PaletteState.self) private var palette
    let results: [AppEntry]
    /// The home search's file matches; the dedicated File Search screen remains the full browser.
    let files: [FileSearchResult]
    /// The flat row id the screen has selected, not an entry id: a fallback can repeat a result.
    let selectedRowID: String?
    let favoriteCount: Int
    let showSections: Bool
    /// Changes only when the list should scroll, so mouse selection never yanks it.
    let scroll: ScrollIntent
    /// The card at flat index 0, when one leads. At most one ever does.
    var card: LeadCard?
    var cardSelected = false
    var onActivateCard: () -> Void = {}
    var onCopyCard: () -> Void = {}
    var onCardActions: () -> Void = {}
    let onActivate: (AppEntry) -> Void
    let onActions: (AppEntry) -> Void
    let onActivateFile: (FileSearchResult) -> Void
    let onFileActions: (FileSearchResult) -> Void
    /// The `Use "…" with` section, always last; nil when nothing is typed.
    var fallbacks: FallbackSection?
    @Environment(RunningAppsMonitor.self) private var runningApps

    /// What the fallback section draws and where its rows go, addressed by position.
    struct FallbackSection {
        let title: String
        let entries: [AppEntry]
        let onActivate: (Int) -> Void
        let onActions: (Int) -> Void
        let onConfigure: () -> Void
    }

    /// Calc answers a typed query and the card an empty one, so only one ever leads.
    enum LeadCard: Equatable {
        case calc(CalcResult)
        case meeting(MeetingEvent, now: Date)
        case color(ColorValue)

        var sectionTitle: String {
            switch self {
            case .calc: return "Calculator"
            case .meeting: return "Meeting"
            case .color: return "Color"
            }
        }

        var rowID: String {
            switch self {
            case .calc: return "calc-card"
            case .meeting: return "meeting-card"
            case .color: return "color-card"
            }
        }
    }

    private enum Row: Identifiable {
        case header(String)
        /// Its own case, because only this header carries a gear.
        case fallbackHeader(String)
        case card(LeadCard)
        case app(AppEntry, resultIndex: Int?)
        case file(FileSearchResult, resultIndex: Int?)
        case fallback(AppEntry, index: Int)
        var id: String {
            switch self {
            case .header(let title): return "header-" + title
            case .fallbackHeader: return "fallback-header"
            case .card(let card): return card.rowID
            case .app(let app, _): return app.id
            case .file(let result, _): return "file-" + result.id
            case .fallback(let app, _): return "fallback-" + app.id
            }
        }
    }

    /// Whether the selection sits on flat index 0: the card, else the first result.
    private var firstRowSelected: Bool {
        if card != nil { return cardSelected }
        let firstID =
            results.first?.id
            ?? files.first.map { "file-" + $0.id }
            ?? fallbacks?.entries.first.map { "fallback-" + $0.id }
        return selectedRowID != nil && selectedRowID == firstID
    }

    /// Every row the fallback section contributes, always after the results.
    private var fallbackRows: [Row] {
        guard let fallbacks else { return [] }
        return [.fallbackHeader(fallbacks.title)]
            + fallbacks.entries.enumerated().map { Row.fallback($1, index: $0) }
    }

    /// Headers are presentation only; scrolling is unnecessary for a single selectable item.
    private var selectableRecordCount: Int {
        results.count + files.count + (card == nil ? 0 : 1) + (fallbacks?.entries.count ?? 0)
    }

    /// Files follow launcher entries as a distinct section, with their shortcut positions continuing
    /// the flat result order rather than restarting at ⌘1.
    private var fileRows: [Row] {
        guard !files.isEmpty else { return [] }
        return [.header("Files & Folders")]
            + files.enumerated().map {
                .file($1, resultIndex: resultOffset + results.count + $0)
            }
    }

    private var rows: [Row] {
        var cardRows: [Row] = []
        if let card { cardRows = [.header(card.sectionTitle), .card(card)] }
        guard showSections else {
            let resultRows: [Row]
            if results.isEmpty {
                resultRows = []
            } else {
                resultRows =
                    [.header("Results")]
                    + results.enumerated().map { .app($1, resultIndex: resultOffset + $0) }
            }
            return cardRows + resultRows + fileRows + fallbackRows
        }
        var rows: [Row] = cardRows
        let favorites = results.enumerated().prefix(favoriteCount)
        let rest = results.enumerated().dropFirst(favoriteCount)
        var grouped: [AppEntry.Kind: [(Int, AppEntry)]] = [:]
        for (index, app) in rest { grouped[app.kind, default: []].append((index, app)) }
        if !favorites.isEmpty {
            rows.append(.header("Favorites"))
            rows.append(
                contentsOf: favorites.map { .app($1, resultIndex: resultOffset + $0) })
        }
        // Publication order, so rows match the flat index.
        let kinds: [AppEntry.Kind] = [
            .meeting, .application, .systemSettings, .extensionCommand, .quicklink, .appleShortcut,
            .snippet, .systemAction, .windowLayout, .windowCommand, .customCommand, .quickAction,
            .command
        ]
        for kind in kinds {
            guard let group = grouped[kind], !group.isEmpty else { continue }
            rows.append(.header(kind.descriptor.sectionTitle))
            rows.append(contentsOf: group.map { .app($0.1, resultIndex: resultOffset + $0.0) })
        }
        // A missing kind would make every later row activate its neighbour: assert instead.
        assert(
            grouped.keys.allSatisfy(kinds.contains),
            "kind missing from the launcher's section order: "
                + grouped.keys.filter { !kinds.contains($0) }.map(\.rawValue).joined(separator: ", "))
        return rows + fileRows + fallbackRows
    }

    /// Lead cards occupy the first selectable screen row, while section headers do not.
    private var resultOffset: Int { card == nil ? 0 : 1 }

    var body: some View {
        let rows = rows
        let fallbackBuffer =
            fallbacks == nil
            ? 0 : (metrics.size.rowIcon + metrics.spacing.sm * 2) / 2
        return Group {
            if results.isEmpty && files.isEmpty && card == nil && fallbacks == nil {
                EmptyResults(text: "No apps found")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { row in
                                switch row {
                                case .header(let title):
                                    SectionHeader(title: title, isFirst: row.id == rows.first?.id)
                                case .fallbackHeader(let title):
                                    SectionHeader(
                                        title: title, isFirst: row.id == rows.first?.id,
                                        configure: fallbacks?.onConfigure,
                                        configureHelp: "Configure Fallbacks…")
                                case .card(let card):
                                    LeadCardView(
                                        card: card, selected: cardSelected,
                                        onActivate: onActivateCard, onCopy: onCopyCard)
                                        .contentShape(Rectangle())
                                        .onRightClick(perform: onCardActions)
                                        .padding(.bottom, metrics.spacing.xs)
                                        .selectionFrame(cardSelected)
                                case .app(let app, let resultIndex):
                                    AppRow(
                                        app: app,
                                        selected: app.id == selectedRowID,
                                        running: runningApps.isRunning(app), resultIndex: resultIndex,
                                        selectionIndex: resultIndex ?? 0
                                    )
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        palette.selection = resultIndex ?? 0
                                        onActivate(app)
                                    }
                                    .onRightClick { onActions(app) }
                                    .selectionFrame(app.id == selectedRowID)
                                case .file(let result, let resultIndex):
                                    FileSearchRow(
                                        result: result, selected: row.id == selectedRowID,
                                        resultIndex: resultIndex,
                                        dimWhenUnselected: true,
                                        onActivateFromDragHandle: {
                                            if let resultIndex { palette.selection = resultIndex }
                                            onActivateFile(result)
                                        }
                                    )
                                    .contentShape(Rectangle())
                                    .onRightClick { onFileActions(result) }
                                    .selectionFrame(row.id == selectedRowID)
                                case .fallback(let app, let index):
                                    let resultIndex =
                                        resultOffset + results.count + files.count + index
                                    AppRow(
                                        app: app, selected: row.id == selectedRowID, running: false,
                                        resultIndex: resultIndex,
                                        selectionIndex: resultIndex
                                    )
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        palette.selection = resultIndex
                                        fallbacks?.onActivate(index)
                                    }
                                    .onRightClick { fallbacks?.onActions(index) }
                                    .selectionFrame(row.id == selectedRowID)
                                }
                            }
                        }
                        .padding(.horizontal, metrics.spacing.md)
                        .padding(.top, metrics.spacing.xl)
                        .padding(.bottom, metrics.spacing.xxl + fallbackBuffer)
                        .hideNativeScrollers()
                        .scrollOriginAnchor()
                    }
                    .scrollDisabled(selectableRecordCount <= 1)
                    .launcherEdgeDissolve()
                    .thinScrollbar()
                    // Snap to the origin on the first row so its header shows too.
                    .scrollFollowsSelection(
                        scroll, row: selectedRowID, atOrigin: firstRowSelected, proxy: proxy)
                }
            }
        }
    }
}

/// Draws whichever card leads; each feature still owns how its own card looks.
private struct LeadCardView: View {
    let card: LauncherList.LeadCard
    let selected: Bool
    let onActivate: () -> Void
    let onCopy: () -> Void

    var body: some View {
        switch card {
        case .calc(let result):
            CalculatorCard(result: result, onCopy: onCopy)
        case .meeting(let meeting, let now):
            MeetingCard(meeting: meeting, now: now, selected: selected)
                .onTapGesture(perform: onActivate)
        case .color(let color):
            ColorCard(color: color, selected: selected)
                .onTapGesture(perform: onActivate)
        }
    }
}

private struct AppRow: View {

    @Environment(\.metrics) private var metrics
    let app: AppEntry
    let selected: Bool
    let running: Bool
    let resultIndex: Int?
    let selectionIndex: Int
    /// Observed so a hotkey set/cleared in Settings re-renders the row's keycaps immediately.
    @Environment(HotKeyManager.self) private var hotKeys
    /// Observed for the same reason: an alias edit re-renders the row's badge at once.
    @Environment(AliasStore.self) private var aliases
    @Environment(PaletteState.self) private var palette
    @State private var hovered = false

    /// Keycaps for this entry's hotkey, or `nil` if none is bound.
    private var shortcutCaps: [String]? {
        guard let action = app.hotKeyAction else { return nil }
        return hotKeys.binding(for: action)?.keycaps
    }

    var body: some View {
        HStack(spacing: metrics.spacing.lg) {
            AppIconView(app: app, pointSize: metrics.size.rowIcon)
                .frame(width: metrics.size.rowIcon, height: metrics.size.rowIcon)
                .overlay(alignment: .bottom) {
                    if running {
                        Circle()
                            .fill(.secondary)
                            .frame(width: 3, height: 3)
                            .offset(y: 3)
                    }
                }
            if app.kind == .meeting {
                MeetingEntryContent(entryID: app.id) { meeting, _ in
                    CalendarBar(color: meeting.calendarColor)
                }
            }
            Text(app.name)
                .font(metrics.typography.rowTitle)
                .lineLimit(1)
                .paletteResultText(isActive: selected || hovered)
            if let subtitle = app.subtitle {
                Text(subtitle)
                    .font(metrics.typography.rowTrailing)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let alias = aliases.alias(for: app.preferenceKey) {
                Text(alias)
                    .font(metrics.typography.rowTrailing)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, metrics.spacing.sm)
                    .padding(.vertical, metrics.spacing.xxs)
                    .background(
                        RoundedRectangle(cornerRadius: metrics.radius.menu, style: .continuous)
                            .fill(Theme.Colors.controlSurface))
            }
            if let caps = shortcutCaps {
                HStack(spacing: metrics.spacing.xxs) {
                    ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in
                        KeyCapChip(text: cap, style: .plain)
                    }
                }
            }
            Spacer()
            if let refresh = app.backgroundRefresh {
                ExtensionRefreshIndicator(state: refresh)
                    .font(metrics.typography.rowTrailing)
            }
            if app.kind == .meeting {
                MeetingEntryContent(entryID: app.id) { MeetingTiming(meeting: $0, now: $1) }
            } else {
                Text(app.kindLabel)
                    .font(metrics.typography.rowTrailing)
                    .foregroundStyle(.secondary)
            }
            if palette.commandHeld, let resultIndex,
                let shortcut = PaletteState.resultShortcut(at: resultIndex)
            {
                Text(shortcut)
                    .font(metrics.typography.rowTrailing)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: palette.commandHeld)
        .padding(.horizontal, metrics.spacing.md)
        .padding(.vertical, metrics.spacing.sm)
        .armedHover($hovered)
    }
}

private struct LauncherEdgeDissolve: ViewModifier {
    @Environment(\.metrics) private var metrics
    @State private var canScroll = false
    @State private var topDistance: CGFloat = 0

    private struct ScrollState: Equatable {
        var topDistance: CGFloat
        var canScroll: Bool
    }

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: ScrollState.self) { geometry in
                let visible =
                    geometry.containerSize.height - geometry.contentInsets.top
                    - geometry.contentInsets.bottom
                return ScrollState(
                    topDistance: max(0, geometry.contentOffset.y + geometry.contentInsets.top),
                    canScroll: geometry.contentSize.height > visible
                )
            } action: { _, state in
                topDistance = state.topDistance
                canScroll = state.canScroll
            }
            .mask {
                GeometryReader { geometry in
                    if geometry.size.height == 0 {
                        Color.black
                    } else {
                        let topBand = min(
                            metrics.size.headerHeight + metrics.size.headerPadding
                                + metrics.scaled(32),
                            geometry.size.height * 0.32
                        )
                        let topMidpoint = topBand / 2 / geometry.size.height
                        let topEnd = topBand / geometry.size.height
                        let buffer = metrics.spacing.xl
                        let fadeStrength =
                            canScroll
                            ? min(max((topDistance - buffer) / metrics.scaled(32), 0), 1) * 0.7
                            : 0
                        if fadeStrength == 0 {
                            LinearGradient(
                                colors: [.black, .black],
                                startPoint: .top, endPoint: .bottom
                            )
                        } else {
                            let topAlpha = 1 - 0.85 * fadeStrength
                            let bottomAlpha = 1 - 0.75 * fadeStrength
                            let bottomBand = min(
                                metrics.size.bottomBarHeight + metrics.scaled(28),
                                geometry.size.height * 0.32
                            )
                            let bottomStart = 1 - bottomBand / geometry.size.height
                            let bottomMidpoint = 1 - bottomBand / 2 / geometry.size.height
                            LinearGradient(
                                stops: [
                                    .init(color: .black.opacity(0), location: 0),
                                    .init(color: .black.opacity(topAlpha), location: topMidpoint),
                                    .init(color: .black, location: topEnd),
                                    .init(color: .black, location: bottomStart),
                                    .init(color: .black.opacity(bottomAlpha), location: bottomMidpoint),
                                    .init(color: .black.opacity(0), location: 1)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                    }
                }
            }
    }
}

extension View {
    fileprivate func launcherEdgeDissolve() -> some View {
        modifier(LauncherEdgeDissolve())
    }
}
