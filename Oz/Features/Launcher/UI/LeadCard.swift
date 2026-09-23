import SwiftUI

private struct LeadCardResultActiveKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var leadCardResultActive: Bool {
        get { self[LeadCardResultActiveKey.self] }
        set { self[LeadCardResultActiveKey.self] = newValue }
    }
}

/// Stable card surface and text emphasis for every lead card.
private struct LeadCardChrome: ViewModifier {
    @Environment(\.metrics) private var metrics
    let selected: Bool
    let baseFill: Color
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .environment(\.leadCardResultActive, selected || hovered)
            .background(shape.fill(baseFill))
            .armedHover($hovered)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: metrics.radius.card, style: .continuous)
    }

}

extension View {
    /// Padding stays each card's own: a meeting card is deliberately shorter than an answer.
    func leadCard(selected: Bool, baseFill: Color = Theme.Colors.cardFill) -> some View {
        modifier(LeadCardChrome(selected: selected, baseFill: baseFill))
    }
}

/// One side of a two-column lead card: a value line with an optional word-name badge beneath.
struct LeadCardColumn: View {
    @Environment(\.metrics) private var metrics
    @Environment(\.leadCardResultActive) private var resultActive
    let text: AttributedString
    let badge: String?
    var weight: Font.Weight = .medium
    var badgeHasBackground = true

    var body: some View {
        VStack(spacing: metrics.spacing.md) {
            Text(text)
                .font(metrics.typography.calcResult.weight(weight))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .paletteResultText(isActive: resultActive)
            if let badge { LeadCardBadge(text: badge, hasBackground: badgeHasBackground) }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, metrics.spacing.md)
    }
}

/// The pill a lead card states its kind in — the calculator's unit, a colour's notation.
private struct LeadCardBadge: View {
    @Environment(\.metrics) private var metrics
    let text: String
    let hasBackground: Bool

    var body: some View {
        Text(text)
            .font(metrics.typography.keyCap)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .foregroundStyle(.secondary)
            .padding(.horizontal, hasBackground ? metrics.spacing.sm : 0)
            .padding(.vertical, hasBackground ? metrics.spacing.xxs : 0)
            .background {
                if hasBackground {
                    RoundedRectangle(cornerRadius: metrics.radius.keyCap, style: .continuous)
                        .fill(Theme.Colors.controlSurface)
                }
            }
    }
}
