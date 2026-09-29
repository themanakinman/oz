import SwiftUI

/// The native editor publishes its insertion point; this view interpolates it between keystrokes.
struct SmoothPaletteCaret: View {
    let frame: CGRect
    let typing: Bool
    @State private var blinkVisible = true

    private var glowReach: CGFloat { Theme.Blur.paletteCaretGlow * 2 }
    private var caretHeight: CGFloat { max(frame.height, 1) }

    var body: some View {
        Rectangle()
            .fill(Theme.Colors.textPrimary)
            .frame(width: Theme.Size.paletteCaretWidth, height: caretHeight)
            .overlay(alignment: .center) {
                Rectangle()
                    .fill(Theme.Colors.paletteCaretGradient)
                    .opacity(Theme.Colors.paletteCaretOpacity)
            }
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Theme.Colors.paletteCaretGradient)
                    .frame(width: Theme.Size.paletteCaretWidth, height: caretHeight)
                    .blur(radius: Theme.Blur.paletteCaretGlow)
                    .frame(
                        width: glowReach + Theme.Size.paletteCaretWidth,
                        height: caretHeight + glowReach * 2,
                        alignment: .trailing)
                    .clipped()
                    .opacity(Theme.Colors.paletteCaretGlowOpacity)
                    .offset(x: -glowReach)
            }
            .offset(x: frame.minX, y: frame.minY)
            .opacity(typing || blinkVisible ? 1 : 0)
            .animation(
                .timingCurve(0.16, 1, 0.3, 1, duration: 0.19), value: frame.origin)
            .allowsHitTesting(false)
            .task(id: typing) {
                guard !typing else {
                    blinkVisible = true
                    return
                }
                blinkVisible = true
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(609))
                    guard !Task.isCancelled else { return }
                    blinkVisible = false
                    try? await Task.sleep(for: .milliseconds(441))
                    guard !Task.isCancelled else { return }
                    blinkVisible = true
                }
            }
    }
}
