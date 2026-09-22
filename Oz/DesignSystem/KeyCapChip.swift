import SwiftUI

/// A single keycap: `.plain` for shortcut hints, `.filled` for emphasized key presses.
struct KeyCapChip: View {
    enum Style {
        case plain
        case filled
    }

    /// Sanctioned cap sizes, so a bigger or smaller one is a named choice, not a stray frame.
    enum Scale {
        case compact
        case standard
        case hero

        func side(_ metrics: InterfaceMetrics) -> CGFloat {
            switch self {
            case .compact: metrics.size.compactKeyCap
            case .standard: metrics.size.keyCap
            case .hero: metrics.size.heroKeyCap
            }
        }

        @MainActor
        func font(_ metrics: InterfaceMetrics) -> Font {
            switch self {
            case .compact: metrics.typography.compactKeyCap
            case .standard: metrics.typography.keyCap
            case .hero: metrics.typography.heroKeyCap
            }
        }
    }

    let text: String
    var style: Style = .filled
    var scale: Scale = .standard
    @Environment(\.metrics) private var metrics

    /// "↵" falls back to another face that seats high, so nudge it render-only.
    private static let returnGlyphDrop: CGFloat = 1.1

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.radius.keyCap, style: .continuous)
        Text(text)
            .font(scale.font(metrics))
            .foregroundStyle(Theme.Colors.textSecondary)
            .offset(y: text == "↵" ? Self.returnGlyphDrop : 0)
            .padding(.horizontal, style == .plain ? 0 : metrics.spacing.xs)
            .frame(
                minWidth: style == .plain ? 0 : scale.side(metrics),
                minHeight: style == .plain ? 0 : scale.side(metrics)
            )
            .background {
                switch style {
                case .filled: shape.fill(Theme.Colors.controlSurface)
                case .plain: Color.clear
                }
            }
    }
}
