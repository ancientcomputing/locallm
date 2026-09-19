import SwiftUI

@available(macOS 27, *)
struct TavilySetupView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""
    @State private var isConnecting = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect Tavily").font(AppFont.title2).bold()
            Text("VistaNova uses Tavily's search API to find pages about your topic. Get a key at \(Text("app.tavily.com").underline())")
                .font(AppFont.body)
            SecureField("tvly-…", text: $apiKey)
                .font(AppFont.body)
                .textFieldStyle(.roundedBorder)
                .onSubmit(connect)
            if let error {
                Text(error).font(AppFont.caption).foregroundStyle(.red)
            }
            HStack {
                // Skippable — search just stays disabled (see ChatView's composer) until the
                // user connects Tavily, whether that's right now or later via Settings. Nothing
                // should ever force this dialog open with no way out.
                Button("Cancel") { dismiss() }
                Spacer()
                if isConnecting {
                    ProgressView().controlSize(.small)
                }
                Button("Connect", action: connect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isConnecting)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func connect() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        isConnecting = true
        error = nil
        Task {
            let failure = await model.connectTavily(apiKey: key)
            isConnecting = false
            error = failure
        }
    }
}
