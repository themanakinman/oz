import SwiftUI

/// File-scoped so a row and the cap that counts rows read one number.
private struct Metrics {
    /// Owned here rather than in `DesignSystem`: an extension never moves a launcher surface.
    let interface: InterfaceMetrics

    var width: CGFloat { interface.scaled(320) }
    /// The glyph slot plus its breathing room — the tallest thing a row contains.
    var rowHeight: CGFloat { interface.size.menuIcon + interface.spacing.md * 2 }
    var rowSpacing: CGFloat { 1 }
    var separatorSpacing: CGFloat { interface.spacing.sm }
    var listInset: CGFloat { interface.spacing.md }
    /// Five rows and half of the sixth, so a long panel reads as scrollable rather than clipped.
    var visibleRows: CGFloat { 5.5 }
    /// Rounded: a fractional height lands the glass edge on a half pixel.
    var rowsMaxHeight: CGFloat { (visibleRows * (rowHeight + rowSpacing)).rounded() }
    var headerHeight: CGFloat {
        interface.size.menuSectionHeader + interface.spacing.xs * 1.5 + rowSpacing
    }
    /// Exact, because every row is one known height: no measuring pass, and no greedy scroll view.
    func contentHeight(items: [ExtensionActionItem], hasHeader: Bool) -> CGFloat {
        let rows = CGFloat(items.count)
        let separators = CGFloat(items.dropFirst().filter(\.startsSection).count)
        let regularGaps = max(rows - 1 - separators, 0)
        let separatorHeight = separatorSpacing * 2 + Theme.Size.hairline
        let header = hasHeader ? headerHeight : 0
        return header + rows * rowHeight + regularGaps * rowSpacing
            + separators * separatorHeight
    }

    func maximumHeight(hasHeader: Bool) -> CGFloat {
        rowsMaxHeight + (hasHeader ? headerHeight : 0)
    }
}

/// Its own type, not `PopoverMenuItem`: an extension names any icon and tints it.
struct ExtensionActionItem {
    let title: String
    let icon: ExtensionImage.Resolved
    var shortcut: String?
    var isDestructive = false
    var startsSection = false
}

/// The ⌘K panel of a running command; extension artwork and tints stay feature-owned.
struct ExtensionActionsPanel: View {
    @Environment(\.metrics) private var metrics
    var header: String?
    let items: [ExtensionActionItem]
    @Binding var selection: Int
    let onActivate: (Int) -> Void

    private var panel: Metrics { Metrics(interface: metrics) }

    var body: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: metrics.radius.menuPanel,
            bottomLeadingRadius: metrics.radius.menuPanel,
            bottomTrailingRadius: metrics.radius.menuAttachment,
            topTrailingRadius: metrics.radius.menuPanel,
            style: .continuous)
        return VStack(spacing: 0) {
            listContent
            Rectangle()
                .fill(Theme.Colors.separator)
                .frame(height: Theme.Size.hairline)
                .accessibilityHidden(true)
            ExtensionMenuSearchField(
                placeholder: "Search for actions…", height: panel.rowHeight,
                verticalOffset: -metrics.spacing.xxs / 2)
        }
        .frame(width: panel.width)
        .paletteSurface(in: shape, backgroundOpacity: 0.9)
    }

    @ViewBuilder
    private var listContent: some View {
        if items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                headerLabel
                Text("No Results")
                    .font(metrics.typography.menuRow)
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .frame(maxWidth: .infinity)
                    .frame(height: panel.rowHeight)
            }
            .padding(panel.listInset)
        } else {
            actionRows
        }
    }

    private var actionRows: some View {
        let hasHeader = header != nil
        let contentHeight = panel.contentHeight(items: items, hasHeader: hasHeader)
        let maximumHeight = panel.maximumHeight(hasHeader: hasHeader)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    headerLabel
                    // Index-as-id is stable: a panel's rows never reorder while it is open.
                    ForEach(items.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 0) {
                            rowBoundary(before: index)
                            ExtensionActionRow(
                                item: items[index],
                                selected: index == selection,
                                onActivate: { onActivate(index) }
                            )
                        }
                        .id(index)
                    }
                }
                .padding(panel.listInset)
            }
            .frame(height: min(contentHeight, maximumHeight) + panel.listInset * 2)
            .scrollBounceBehavior(contentHeight > maximumHeight ? .always : .basedOnSize)
            // `never`, not `hidden`: hidden still lets AppKit claim the scroller's gutter.
            .scrollIndicators(.never)
            .onChange(of: selection) {
                // No anchor: reveal the row, never re-centre the list around it.
                proxy.scrollTo(selection)
            }
        }
    }

    @ViewBuilder
    private var headerLabel: some View {
        if let header {
            Text(header)
                .font(metrics.typography.sectionHeader)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(height: metrics.size.menuSectionHeader, alignment: .leading)
                .padding(.horizontal, metrics.spacing.lg)
                .padding(.top, metrics.spacing.xs)
                .padding(.bottom, metrics.spacing.xs / 2)
            Color.clear.frame(height: panel.rowSpacing)
        }
    }

    @ViewBuilder
    private func rowBoundary(before index: Int) -> some View {
        if index > 0, items[index].startsSection {
            Rectangle()
                .fill(Theme.Colors.separator)
                .frame(height: Theme.Size.hairline)
                .padding(.horizontal, metrics.spacing.md)
                .padding(.vertical, panel.separatorSpacing)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else if index > 0 {
            Color.clear.frame(height: panel.rowSpacing)
        }
    }
}

/// Its own row, not the palette's: that one is file-private.
private struct ExtensionActionRow: View {
    @Environment(\.metrics) private var metrics
    let item: ExtensionActionItem
    let selected: Bool
    let onActivate: () -> Void
    @State private var hovered = false

    private var panel: Metrics { Metrics(interface: metrics) }

    var body: some View {
        Button(action: onActivate) {
            HStack(spacing: metrics.spacing.md) {
                ExtensionIconView(
                    resolved: item.icon, size: metrics.size.menuIcon, usesMenuSymbolStyle: true)
                Text(item.title)
                    .font(metrics.typography.menuRow)
                    .foregroundStyle(item.isDestructive ? Color.red : Color.primary)
                    .lineLimit(1)
                    .paletteResultText(isActive: selected || hovered)
                Spacer(minLength: metrics.spacing.sm)
                if let shortcut = item.shortcut {
                    HStack(spacing: metrics.spacing.xxs) {
                        ForEach(Array(shortcut.enumerated()), id: \.offset) { _, glyph in
                            KeyCapChip(text: String(glyph), style: .plain)
                        }
                    }
                }
            }
            .padding(.horizontal, metrics.spacing.md)
            // Fixed, not padded: the height maths above counts rows, so a row is one exact height.
            .frame(
                maxWidth: .infinity, minHeight: panel.rowHeight, maxHeight: panel.rowHeight,
                alignment: .leading
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .armedHover($hovered)
    }
}
