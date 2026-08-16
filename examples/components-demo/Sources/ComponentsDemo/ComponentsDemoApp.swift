// Components Demo — the SDK's second reference app. plate-today shows building a real feature on
// Core's API directly; this shows the other half of the pitch: drop in Components' prebuilt
// MCPServerPickerView and get a working "add/manage MCP servers" screen with a few lines of glue
// code, no UI of your own to write.
//
// Packaged as a real signed .app (packaging/build-and-sign.sh) for the same reason plate-today is:
// the OAuth redirect needs a registered URL scheme, which a bare `swift run` binary doesn't have.

import Combine
import LocalLMLabSDKComponents
import LocalLMLabSDKCore
import SwiftUI

// MARK: - View model

// Thin glue only — everything interesting (add/reconnect/disconnect/remove, all three auth types,
// the in-flight OAuth overlay) already lives inside MCPServerPickerView itself. This model's only
// job is the one thing that view doesn't do: surface what actually becomes available for a
// FoundationModels tool-calling session once servers are connected, so this app demonstrates the
// whole point of Components (pick servers -> get tools), not just that the picker UI paints.
@available(macOS 26.0, *)
@MainActor
final class ComponentsDemoModel: ObservableObject {
    let manager: MCPServerManagerObservable
    @Published private(set) var availableTools: [MCPToolDescriptor] = []
    // What a real host app would do with an attached resource or an expanded prompt is entirely
    // its own business (see MCPResourcesView/MCPPromptsView's doc comment) — this is the simplest
    // possible stand-in for "a text field the model would actually see," just so this app can
    // prove the whole read -> use loop live, the same way the tools panel proves toolsForSession().
    @Published var attachedText = ""
    private var cancellable: AnyCancellable?

    init() {
        let core = MCPServerManager()
        manager = MCPServerManagerObservable(core: core)
        // toolsForSession() itself isn't reactive (it's a plain synchronous query against Core's
        // current state, same shape a real tool-calling call site would use), so re-derive it
        // whenever the picker's own @Published servers dictionary changes, rather than polling.
        // MCPServerState isn't Equatable, so this goes through Combine directly instead of
        // SwiftUI's .onChange (which requires Equatable).
        cancellable = manager.$servers.sink { [weak self] _ in self?.refreshAvailableTools() }
    }

    func refreshAvailableTools() {
        availableTools = manager.core.toolsForSession()
    }

    func attach(_ name: String, _ content: MCPResourceContent) {
        let text = content.text ?? "(binary content — \(content.mimeType ?? "unknown type"), not shown as text)"
        attachedText += "\n\n[Attached: \(name)]\n\(text)"
    }

    func use(_ prompt: MCPPromptDescriptor, _ messages: [MCPPromptMessage]) {
        attachedText += "\n\n[Prompt: \(prompt.name)]\n" + messages.map(\.text).joined(separator: "\n\n")
    }
}

// MARK: - UI

@available(macOS 26.0, *)
struct ContentView: View {
    @ObservedObject var model: ComponentsDemoModel
    @State private var showResources = false
    @State private var showPrompts = false

    var body: some View {
        HSplitView {
            MCPServerPickerView(manager: model.manager)
                .frame(minWidth: 480)

            // What a real tool-calling session would actually see right now — makes the
            // add-a-server flow concretely useful to look at, not just a form that saves
            // somewhere invisible.
            VStack(alignment: .leading, spacing: 12) {
                Text("Tools available this session")
                    .font(.headline)
                Text("What LanguageModelSession(tools:) would see right now, from manager.core.toolsForSession() — updates as you add, enable/disable, or remove servers.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Divider()
                if model.availableTools.isEmpty {
                    Text("No tools available yet — add a server and enable some tools.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(model.availableTools, id: \.name) { tool in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tool.name).font(.system(size: 13, weight: .semibold, design: .monospaced))
                                    Text(tool.description)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 160)
                }

                Divider()
                HStack {
                    Text("Resources & prompts").font(.headline)
                    Spacer()
                    Button("Resources…") { showResources = true }
                    Button("Prompts…") { showPrompts = true }
                }
                Text("Extracting value beyond tool-calling — read an enabled resource's content, or expand an enabled prompt — via MCPResourcesView/MCPPromptsView. What each does with the result is entirely up to this app (below is just a stand-in for \"a text field the model would see\").")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(model.attachedText.isEmpty ? "Nothing attached yet." : model.attachedText)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(model.attachedText.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }

                Spacer()
            }
            .padding(20)
            .frame(minWidth: 280)
        }
        .frame(minWidth: 800, minHeight: 480)
        .sheet(isPresented: $showResources) {
            VStack(spacing: 0) {
                HStack {
                    Text("Resources").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button("Done") { showResources = false }
                }
                .padding(16)
                Divider()
                MCPResourcesView(manager: model.manager, onAttach: { descriptor, content in
                    model.attach(descriptor.name, content)
                })
            }
            .frame(width: 480, height: 480)
        }
        .sheet(isPresented: $showPrompts) {
            VStack(spacing: 0) {
                HStack {
                    Text("Prompts").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button("Done") { showPrompts = false }
                }
                .padding(16)
                Divider()
                MCPPromptsView(manager: model.manager, onUse: { prompt, messages in
                    model.use(prompt, messages)
                })
            }
            .frame(width: 480, height: 480)
        }
    }
}

// Handles componentsdemo://oauth/callback directly, the same way plate-today's AppDelegate does
// and for the same reason: WindowGroup treats an open-URL event as a request for a new scene
// instance and would otherwise spin up a second window instead of returning to this one. Distinct
// scheme from both plate-today ("platetoday") and LocalLM Lab itself ("locallmlab") so none
// collide if all three are installed on the same Mac.
@available(macOS 26.0, *)
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "componentsdemo" {
            MCPOAuthRedirectListener.shared.handleRedirect(url)
        }
    }
}

@available(macOS 26.0, *)
@main
struct ComponentsDemoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = ComponentsDemoModel()

    init() {
        MCPOAuthFlow.redirectURI = "componentsdemo://oauth/callback"
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .windowResizability(.contentMinSize)
        .handlesExternalEvents(matching: [])
    }
}
