import SwiftUI

/// Overflow is a button after the icons, keeping the compact strip independent of result selection.
struct CompactFavoritesRow: View {
    let favorites: [AppEntry]
    let showsOverflow: Bool
    let onLaunch: (AppEntry) -> Void
    let onOverflow: () -> Void
    @Environment(\.metrics) private var metrics

    var body: some View {
        HStack(spacing: metrics.spacing.xs) {
            // Identified by the app, so a reorder moves an icon with its app, not by position.
            ForEach(favorites, id: \.id) { app in
                CompactFavoriteButton(help: app.name) {
                    onLaunch(app)
                } content: {
                    AppIconView(app: app, pointSize: metrics.size.rowIcon)
                        .frame(width: metrics.size.rowIcon, height: metrics.size.rowIcon)
                }
            }
            if showsOverflow {
                CompactFavoriteButton(help: "Show all  ↓", action: onOverflow) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .frame(width: metrics.size.rowIcon, height: metrics.size.rowIcon)
                        .background(
                            RoundedRectangle(cornerRadius: metrics.radius.custom(6), style: .continuous)
                                .fill(Theme.Colors.controlSurface)
                                .padding(metrics.spacing.xxs)
                        )
                }
            }
        }
    }

}

/// One compact favorite: bare icon, tooltip, action; no hover chrome, so it reads tight.
private struct CompactFavoriteButton<Content: View>: View {
    let help: String
    let action: () -> Void
    @ViewBuilder let content: Content
    @Environment(\.metrics) private var metrics

    var body: some View {
        Button(action: action) {
            content
                .contentShape(RoundedRectangle(cornerRadius: metrics.radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
