import SwiftUI

struct ChatComposerTextView: View {
    @Environment(\.metrics) private var metrics
    @Binding var text: String
    let focusKey: UUID
    let onSubmit: () -> Void

    var body: some View {
        PaletteTextInput(
            text: $text, prompt: "Ask anything…", focusKey: focusKey,
            multiline: true, usesSearchFont: true, selectsTextOnFocus: true,
            maximumHeight: metrics.scaled(Theme.Size.aiChatComposerMaxHeight), onSubmit: onSubmit)
    }
}
