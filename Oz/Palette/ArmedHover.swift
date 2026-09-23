import SwiftUI

private struct ArmedHover: ViewModifier {
    @Environment(PaletteState.self) private var palette
    @Binding var hovered: Bool
    var enabled: Bool
    var onArm: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active:
                    let isArmed = palette.hoverHighlightArmed
                    hovered = isArmed && enabled
                    if isArmed && enabled { onArm?() }
                case .ended: hovered = false
                }
            }
            // Disarming under a still pointer fires no hover phase, so the drop clears the row.
            .onChange(of: palette.hoverDisarmToken) { hovered = false }
    }
}

extension View {
    /// Row hover, lit only while the pointer moves; independent of the keyboard selection.
    func armedHover(
        _ hovered: Binding<Bool>, enabled: Bool = true, onArm: (() -> Void)? = nil
    ) -> some View {
        modifier(ArmedHover(hovered: hovered, enabled: enabled, onArm: onArm))
    }

    /// Emphasize only the result label; selection and hover never paint a row background.
    func paletteResultText(isActive: Bool) -> some View {
        opacity(isActive ? 1 : 0.38)
    }
}
