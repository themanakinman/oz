import SwiftUI

struct PaletteBackground: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.metrics) private var metrics
    let window: NSWindow?

    private var usesSystemShadow: Bool {
        colorScheme != .dark || settings.paletteTransparency <= 0
    }

    var body: some View {
        Theme.Colors.panelScrim(transparency: settings.paletteTransparency)
            .background(VisualEffectView())
            .overlay {
                if settings.paletteTransparency != 0 {
                    let edge = RoundedRectangle(cornerRadius: metrics.radius.panel, style: .continuous)
                    if usesSystemShadow {
                        edge.strokeBorder(
                            Theme.Colors.panelEdgeHighlight(transparency: settings.paletteTransparency),
                            lineWidth: Theme.Size.hairline / displayScale
                        )
                        .allowsHitTesting(false)
                    } else {
                        edge.strokeBorder(
                            Theme.Colors.panelEdgeGradient(transparency: settings.paletteTransparency),
                            lineWidth: Theme.Size.hairline
                        )
                        .allowsHitTesting(false)
                    }
                }
            }
            .onChange(of: window, initial: true) { applyShadow() }
            .onChange(of: usesSystemShadow) { applyShadow() }
    }

    private func applyShadow() {
        guard let window, window.hasShadow != usesSystemShadow else { return }
        window.hasShadow = usesSystemShadow
        window.invalidateShadow()
    }
}

/// Applies the palette's live scrim and backdrop material to controls that float over its rows.
private struct PaletteSurface<S: Shape>: ViewModifier {
    @Environment(AppSettings.self) private var settings
    let shape: S
    var backgroundOpacity: CGFloat?
    var blursBackdrop: Bool

    func body(content: Content) -> some View {
        content.background {
            shape.fill(background)
                .background {
                    if blursBackdrop {
                        VisualEffectView(material: .hudWindow, blending: .behindWindow)
                    }
                }
                .overlay {
                    shape.stroke(
                        Theme.Colors.panelEdgeHighlight(transparency: settings.paletteTransparency),
                        lineWidth: Theme.Size.hairline)
                }
                .clipShape(shape)
        }
    }

    private var background: Color {
        if let backgroundOpacity {
            return Theme.Colors.submenuSurface(opacity: backgroundOpacity)
        }
        return Theme.Colors.panelScrim(transparency: settings.paletteTransparency)
    }
}

extension View {
    func paletteSurface(
        in shape: some Shape, backgroundOpacity: CGFloat? = nil, blursBackdrop: Bool = false
    ) -> some View {
        modifier(
            PaletteSurface(
                shape: AnyShape(shape), backgroundOpacity: backgroundOpacity,
                blursBackdrop: blursBackdrop))
    }
}
