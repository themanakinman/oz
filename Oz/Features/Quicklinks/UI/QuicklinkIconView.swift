import SwiftUI

struct QuicklinkIconView: View {
    let link: String
    let symbolOverride: String?
    let size: CGFloat
    @State private var loaded: Loaded?

    private var requestKey: String { "\(link)|\(symbolOverride ?? "automatic")" }

    private struct Loaded {
        let link: String
        let image: NSImage?
    }

    var body: some View {
        Group {
            if let symbolOverride {
                SymbolImage(name: symbolOverride, size: size)
            } else if let image = loaded?.link == link ? loaded?.image : nil {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                SymbolImage(
                    name: QuicklinkDestination.detect(link)?.defaultSymbol ?? Quicklink.sfSymbol,
                    size: size)
            }
        }
        .frame(width: size, height: size)
        .task(id: requestKey) {
            guard symbolOverride == nil else { return }
            let image = await QuicklinkIconCache.icon(for: link)
            guard !Task.isCancelled else { return }
            loaded = Loaded(link: link, image: image)
        }
    }
}
