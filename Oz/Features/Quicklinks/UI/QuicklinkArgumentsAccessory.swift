import SwiftUI

/// The inline argument strip, as a `PaletteHeaderAccessory` the palette renders without reading.
@MainActor
enum QuicklinkArgumentsAccessory {
    /// Nil when the selected quicklink asks for nothing, which is every link without a placeholder.
    static func make(
        quicklink: Quicklink?,
        core: AppCore,
        vm: PaletteState,
        focus: FocusState<String?>.Binding,
        placement: PaletteHeaderAccessory.Placement,
        onOpenOptions: @escaping (String) -> Void,
        onSubmit: @escaping () -> Void
    ) -> PaletteHeaderAccessory? {
        guard let quicklink else { return nil }
        let metrics = core.settings.interfaceSize.metrics
        let arguments = core.quicklinkCoordinator.promptedArguments(for: quicklink).map {
            InlineArgument(
                id: $0.name, title: $0.name, options: $0.options,
                isOptional: !QuicklinkCoordinator.requiresValue($0))
        }
        guard !arguments.isEmpty else { return nil }

        // Its own screen already shows the row the fields belong to, so the glyph would repeat it.
        let showsIcon = placement == .afterQuery
        let symbol: String? = nil
        let inputFontSize = metrics.typography.searchFieldSize * 0.7
        let value = { (name: String) in binding(quicklink: quicklink, name: name, vm: vm) }
        return PaletteHeaderAccessory(
            width: InlineArgumentFields.totalWidth(
                for: arguments, hasIcon: showsIcon, metrics: metrics,
                fontSize: inputFontSize),
            fieldNames: arguments.map(\.id),
            firstIncompleteField: arguments.first {
                !$0.isOptional && value($0.id).wrappedValue.isEmpty
            }?.id,
            optionsMenu: { id in
                guard let argument = arguments.first(where: { $0.id == id }),
                    !argument.options.isEmpty
                else { return nil }
                return menu(for: argument, value: value(id))
            },
            placement: placement,
            // Identity per row, so "which fields were left unanswered" starts clean on the next one.
            view: AnyView(
                InlineArgumentFields(
                    arguments: arguments, symbol: symbol, value: value, focused: focus,
                    openOptions: onOpenOptions, onSubmit: onSubmit,
                    iconLink: showsIcon ? quicklink.link : nil,
                    iconSymbolOverride: quicklink.iconSymbol,
                    font: .system(size: inputFontSize, weight: .regular),
                    fieldHeight: metrics.size.headerHeight * 0.7,
                    fontSize: inputFontSize
                )
                .id(quicklink.entryID)
                .offset(y: metrics.scaled(3))
            )
        )
    }

    /// The typed values for one quicklink, stripped of blanks — what the open funnel is handed.
    static func values(for quicklink: Quicklink, core: AppCore, vm: PaletteState) -> [String: String] {
        var values: [String: String] = [:]
        for argument in core.quicklinkCoordinator.promptedArguments(for: quicklink) {
            let typed =
                vm.commandArguments[
                    PaletteState.argumentKey(quicklink.entryID, argument.name)] ?? ""
            if !typed.isEmpty { values[argument.name] = typed }
        }
        return values
    }

    private static func binding(
        quicklink: Quicklink, name: String, vm: PaletteState
    ) -> Binding<String> {
        let key = PaletteState.argumentKey(quicklink.entryID, name)
        return Binding(get: { vm.commandArguments[key] ?? "" }, set: { vm.commandArguments[key] = $0 })
    }

    private static func menu(
        for argument: InlineArgument, value: Binding<String>
    ) -> PopoverMenuContent {
        PopoverMenuContent(
            header: argument.title,
            items: argument.options.map { option in
                PopoverMenuItem(
                    title: option,
                    icon: value.wrappedValue == option ? .symbol("checkmark") : .blank
                ) {
                    value.wrappedValue = option
                }
            })
    }
}
