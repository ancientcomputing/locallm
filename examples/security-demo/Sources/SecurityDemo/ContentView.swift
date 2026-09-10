import LocalLMLabSDKComponents
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        HSplitView {
            SecurityPane(model: model)
                .frame(minWidth: 360, idealWidth: 380, maxWidth: 460)
            RunPane(model: model)
                .frame(minWidth: 420)
        }
        // The Components-provided sheet — one line, no sheet UI of our own. This is what
        // `ConfirmingToolAuthorizer` drives every time `requirement(for:)` returns `.confirm`.
        .toolConfirmationSheet(model.presenter)
    }
}
