import SwiftUI

/// The inline argument fields beside the search field; their own `FocusState`, Tab hands over.
struct CommandArgumentsRow: View {
    @Environment(\.metrics) private var metrics
    let arguments: [ExtensionCommandArgument]
    /// The selected command's glyph, drawn as a leading chip so the fields read as belonging to it.
    let icon: EntryIcon?
    /// Binding factory keyed by argument name — the values live in the palette view's state.
    let value: (String) -> Binding<String>
    @FocusState.Binding var focused: String?
    var maxFieldWidth: CGFloat? = nil
    /// ↵ from inside a field runs the command, like ↵ in the search field.
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: metrics.spacing.xs) {
            if let icon {
                EntryIconView(source: icon)
                    .frame(width: Self.height(metrics), height: Self.height(metrics))
            }
            ForEach(arguments, id: \.name) { argument in
                ArgumentField(
                    argument: argument,
                    text: value(argument.name),
                    isFocused: focused == argument.name,
                    onSubmit: onSubmit, maxFieldWidth: maxFieldWidth
                )
                .focused($focused, equals: argument.name)
            }
        }
    }

    static func height(_ metrics: InterfaceMetrics) -> CGFloat { metrics.scaled(26) }

    /// The header shrinks the search field to exactly the room left over.
    static func totalWidth(
        for arguments: [ExtensionCommandArgument], hasIcon: Bool, metrics: InterfaceMetrics,
        values: [String: String] = [:], maxFieldWidth: CGFloat? = nil
    ) -> CGFloat {
        let fields = arguments.reduce(0) {
            $0 + fieldWidth(
                for: $1, metrics: metrics, text: values[$1.name] ?? "",
                maxWidth: maxFieldWidth)
        }
        let gaps = CGFloat(arguments.count + (hasIcon ? 0 : -1)) * metrics.spacing.xs
        let horizontalPadding = CGFloat(arguments.count) * metrics.spacing.sm * 2
        return fields + horizontalPadding + gaps + (hasIcon ? height(metrics) : 0)
    }

    static func fieldWidth(
        for argument: ExtensionCommandArgument, metrics: InterfaceMetrics,
        text: String = "", maxWidth: CGFloat? = nil
    )
        -> CGFloat
    {
        let placeholder = CGFloat(argument.placeholder.count) * metrics.scaled(7)
        let content = CGFloat(text.count) * metrics.scaled(7)
        let minimum = metrics.scaled(text.isEmpty ? 62 : 28)
        let preferred = text.isEmpty
            ? placeholder + metrics.scaled(20)
            : content + metrics.scaled(14)
        return min(
            max(preferred, minimum),
            maxWidth ?? metrics.scaled(150))
    }

    /// The order Tab walks: search field (nil) → each argument → back to the search field.
    static func next(after current: String?, in arguments: [ExtensionCommandArgument]) -> String? {
        guard let current, let index = arguments.firstIndex(where: { $0.name == current }) else {
            return arguments.first?.name
        }
        let following = arguments.index(after: index)
        return following < arguments.endIndex ? arguments[following].name : nil
    }
}

private struct ArgumentField: View {

    @Environment(\.metrics) private var metrics
    let argument: ExtensionCommandArgument
    @Binding var text: String
    let isFocused: Bool
    let onSubmit: () -> Void
    let maxFieldWidth: CGFloat?
    @State private var hovered = false

    var body: some View {
        TextField(
            "", text: $text,
            prompt: Text(argument.placeholder).foregroundStyle(Theme.Colors.textTertiary)
        )
        .textFieldStyle(.plain)
        .font(metrics.typography.rowTrailing)
        .tint(.white)
        .onSubmit(onSubmit)
        .multilineTextAlignment(.center)
        .frame(
            width: CommandArgumentsRow.fieldWidth(
                for: argument, metrics: metrics, text: text, maxWidth: maxFieldWidth))
        .padding(.horizontal, metrics.spacing.sm)
        .frame(height: CommandArgumentsRow.height(metrics))
        .background(
            RoundedRectangle(cornerRadius: metrics.radius.row, style: .continuous).fill(fill)
        )
        .onHover { hovered = $0 }
        .help(argument.required ? "\(argument.placeholder) — required" : argument.placeholder)
    }

    private var fill: Color {
        if isFocused { return Theme.Colors.selection }
        if hovered { return Theme.Colors.rowHover }
        return ExtensionColors.fieldFill
    }
}
