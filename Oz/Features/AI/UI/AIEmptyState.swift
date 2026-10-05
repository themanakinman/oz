import SwiftUI

/// What an empty chat shows on either surface, and why it cannot answer when it cannot.
struct AIEmptyState: View {

    @Environment(\.metrics) private var metrics
    private static let prompt = "What would you like to do?"
    let message: String?
    let canConfigure: Bool
    let onConfigure: () -> Void

    var body: some View {
        VStack(spacing: metrics.spacing.md) {
            Image(systemName: "sparkles")
                .font(.largeTitle)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tertiary)
            Text(Self.prompt)
                .foregroundStyle(.secondary)
            if let message {
                Text(message)
                    .font(metrics.typography.rowTrailing)
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .multilineTextAlignment(.center)
                if canConfigure { Button("Configure AI", action: onConfigure) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, metrics.spacing.xxl)
    }
}
