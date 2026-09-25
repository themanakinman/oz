import SwiftUI

/// One inline field. `id` keys its focus and value, so two fields may share a title.
struct InlineArgument: Equatable {
    let id: String
    let title: String
    /// Non-empty makes the field chosen from the palette's menu rather than typed.
    var options: [String] = []
    /// Never marked as owed: leaving it empty is an answer.
    var isOptional = false
}

/// The inline argument fields beside the search field, one per argument the row declares.
struct InlineArgumentFields: View {
    @Environment(\.metrics) private var metrics
    let arguments: [InlineArgument]
    /// The row's glyph, anchoring the strip to it; nil where that row is already listed.
    let symbol: String?
    /// Binding factory keyed by argument id — the values live in `PaletteState.commandArguments`.
    let value: (String) -> Binding<String>
    @FocusState.Binding var focused: String?
    /// A field with options is chosen, not typed, so it hands the palette its menu instead.
    let openOptions: (String) -> Void
    /// ↵ from inside a field acts like ↵ on the row itself.
    let onSubmit: () -> Void
    var iconLink: String? = nil
    var iconSymbolOverride: String? = nil
    var maxFieldWidth: CGFloat? = nil
    var font: Font? = nil
    var fieldHeight: CGFloat? = nil
    var fontSize: CGFloat? = nil
    /// Fields the caret has left behind. Nothing is owed until one was visited and not answered.
    @State private var visited: Set<String> = []

    var body: some View {
        HStack(spacing: metrics.spacing.xs) {
            if let iconLink {
                QuicklinkIconView(
                    link: iconLink, symbolOverride: iconSymbolOverride, size: Self.height(metrics))
            } else if let symbol {
                Image(nsImage: IconCache.symbolIcon(named: symbol))
                    .resizable()
                    .frame(width: Self.height(metrics), height: Self.height(metrics))
            }
            ForEach(arguments, id: \.id) { argument in
                let isOwed = !argument.isOptional && visited.contains(argument.id)
                if argument.options.isEmpty {
                    ArgumentField(
                        argument: argument, text: value(argument.id),
                        isFocused: focused == argument.id, isOwed: isOwed, onSubmit: onSubmit,
                        font: font, fieldHeight: fieldHeight, fontSize: fontSize,
                        maxFieldWidth: maxFieldWidth
                    )
                    .focused($focused, equals: argument.id)
                } else {
                    ArgumentChoiceField(
                        argument: argument, text: value(argument.id),
                        isFocused: focused == argument.id, isOwed: isOwed,
                        onOpen: { openOptions(argument.id) }, font: font,
                        fieldHeight: fieldHeight, fontSize: fontSize, maxFieldWidth: maxFieldWidth
                    )
                    .focused($focused, equals: argument.id)
                }
            }
        }
        // Only a field the caret has been in and left may say it is still owed a value.
        .onChange(of: focused) { previous, _ in
            if let previous, arguments.contains(where: { $0.id == previous }) {
                visited.insert(previous)
            }
        }
    }

    static func height(_ metrics: InterfaceMetrics) -> CGFloat { metrics.scaled(26) }

    /// The header shrinks the search field to exactly the room left over.
    static func totalWidth(
        for arguments: [InlineArgument], hasIcon: Bool, metrics: InterfaceMetrics,
        fontSize: CGFloat? = nil, values: [String: String] = [:],
        maxFieldWidth: CGFloat? = nil
    ) -> CGFloat {
        let fields = arguments.reduce(0) {
            $0 + fieldWidth(
                for: $1, metrics: metrics, fontSize: fontSize,
                text: values[$1.id] ?? "", maxWidth: maxFieldWidth)
        }
        let gaps = CGFloat(arguments.count + (hasIcon ? 0 : -1)) * metrics.spacing.xs
        let horizontalPadding = CGFloat(arguments.count) * metrics.spacing.sm * 2
        return fields + horizontalPadding + gaps + (hasIcon ? height(metrics) : 0)
    }

    /// Each field can grow until the header must retain room for the search caret.
    static func maximumFieldWidth(
        fieldCount: Int, hasIcon: Bool, metrics: InterfaceMetrics
    ) -> CGFloat {
        guard fieldCount > 0 else { return 0 }
        let accessoryBudget = max(
            metrics.size.panelWidth - metrics.size.headerIconSlot - metrics.spacing.md * 4
                - metrics.scaled(60),
            0)
        let gaps = CGFloat(fieldCount + (hasIcon ? 0 : -1)) * metrics.spacing.xs
        let horizontalPadding = CGFloat(fieldCount) * metrics.spacing.sm * 2
        let leadingIcon = hasIcon ? height(metrics) : 0
        return max(
            metrics.scaled(72),
            (accessoryBudget - gaps - horizontalPadding - leadingIcon) / CGFloat(fieldCount))
    }

    static func fieldWidth(
        for argument: InlineArgument, metrics: InterfaceMetrics, fontSize: CGFloat? = nil,
        text: String = "", maxWidth: CGFloat? = nil
    ) -> CGFloat {
        if let fontSize {
            let title = CGFloat(argument.title.count) * fontSize * 0.56
            let content = CGFloat(text.count) * fontSize * 0.56
            let scale = fontSize / metrics.typography.searchFieldSize
            let minimum = metrics.scaled(text.isEmpty ? 108 : 28) * scale
            let preferred = text.isEmpty
                ? title + metrics.scaled(28) * scale
                : content + metrics.scaled(16) * scale
            return min(max(preferred, minimum), maxWidth ?? metrics.scaled(220) * scale)
        }
        let title = CGFloat(argument.title.count) * metrics.scaled(7)
        let content = CGFloat(text.count) * metrics.scaled(7)
        let minimum = metrics.scaled(text.isEmpty ? 72 : 28)
        let preferred = text.isEmpty ? title + metrics.scaled(34) : content + metrics.scaled(14)
        return min(
            max(preferred, minimum),
            maxWidth ?? metrics.scaled(160))
    }
}

/// Shared chrome, so a typed field and a chosen one read as the same control.
private struct ArgumentFieldChrome: ViewModifier {
    @Environment(\.metrics) private var metrics
    let argument: InlineArgument
    let isFocused: Bool
    /// Visited, left, and still empty — the only state that earns a warning edge.
    let isOwed: Bool
    @Binding var hovered: Bool
    let fieldHeight: CGFloat?
    let fontSize: CGFloat?
    let text: String
    let maxFieldWidth: CGFloat?

    func body(content: Content) -> some View {
        content
            .frame(
                width: InlineArgumentFields.fieldWidth(
                    for: argument, metrics: metrics, fontSize: fontSize,
                    text: text, maxWidth: maxFieldWidth))
            .padding(.horizontal, metrics.spacing.sm)
            .frame(height: fieldHeight ?? InlineArgumentFields.height(metrics))
            .background(
                RoundedRectangle(cornerRadius: metrics.radius.row, style: .continuous).fill(fill)
            )
            .onHover { hovered = $0 }
            .help(help)
    }

    private var help: String {
        if isOwed { return "\(argument.title) — required" }
        return argument.isOptional ? "\(argument.title) — optional" : argument.title
    }

    private var fill: Color {
        if isFocused { return Theme.Colors.selection }
        if hovered { return Theme.Colors.rowHover }
        return Theme.Colors.cardFill
    }

}

private struct ArgumentField: View {

    @Environment(\.metrics) private var metrics
    let argument: InlineArgument
    @Binding var text: String
    let isFocused: Bool
    let isOwed: Bool
    let onSubmit: () -> Void
    let font: Font?
    let fieldHeight: CGFloat?
    let fontSize: CGFloat?
    let maxFieldWidth: CGFloat?
    @State private var hovered = false

    var body: some View {
        TextField(
            "", text: $text,
            prompt: Text(argument.title).foregroundStyle(Theme.Colors.textTertiary)
        )
        .textFieldStyle(.plain)
        .font(font ?? metrics.typography.rowTrailing)
        .tint(Theme.Colors.textPrimary)
        .onSubmit(onSubmit)
        .multilineTextAlignment(.center)
        .modifier(
            ArgumentFieldChrome(
                argument: argument, isFocused: isFocused, isOwed: isOwed && text.isEmpty,
                hovered: $hovered, fieldHeight: fieldHeight, fontSize: fontSize,
                text: text, maxFieldWidth: maxFieldWidth))
    }
}

/// A field with options: the value is picked from the palette's own menu, never typed.
private struct ArgumentChoiceField: View {
    @Environment(\.metrics) private var metrics
    let argument: InlineArgument
    @Binding var text: String
    let isFocused: Bool
    let isOwed: Bool
    let onOpen: () -> Void
    let font: Font?
    let fieldHeight: CGFloat?
    let fontSize: CGFloat?
    let maxFieldWidth: CGFloat?
    @State private var hovered = false

    var body: some View {
        HStack(spacing: metrics.spacing.xxs) {
            Text(text.isEmpty ? argument.title : text)
                .font(font ?? metrics.typography.rowTrailing)
                .foregroundStyle(
                    text.isEmpty ? Theme.Colors.textTertiary : Theme.Colors.textPrimary
                )
                .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Theme.Colors.textTertiary)
        }
        .modifier(
            ArgumentFieldChrome(
                argument: argument, isFocused: isFocused, isOwed: isOwed && text.isEmpty,
                hovered: $hovered, fieldHeight: fieldHeight, fontSize: fontSize,
                text: text, maxFieldWidth: maxFieldWidth)
        )
        .contentShape(Rectangle())
        .focusable()
        // Keep AppKit's blue ring out of the borderless argument bubble.
        .focusEffectDisabled()
        .onTapGesture(perform: onOpen)
        .onKeyPress(keys: [.return, KeyEquivalent("\u{3}")]) { _ in
            onOpen()
            return .handled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(argument.title))
        .accessibilityValue(Text(text.isEmpty ? "No value" : text))
        .accessibilityHint(Text("Opens a list of choices"))
        .accessibilityAddTraits(.isButton)
    }
}
