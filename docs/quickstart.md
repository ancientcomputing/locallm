# Quickstart: a working chat in your Mac app

This page takes you from nothing to a SwiftUI chat that talks to Apple's on-device model, in about 50 lines of code.
You do not need to know anything about AI. The ideas you need are explained as they come up. When it works, three
short sections show how to give the chat a tool, a bigger model and an outside server.

**You need:** a Mac with Apple Silicon running macOS 27 with Apple Intelligence turned on, and Xcode 27 to build. Everything
in the SDK works on macOS 27: Apple's on-device model, open-weight models, hosted models and Private Cloud Compute.
Nothing is downloaded and no account or key is needed for this page.

*Supporting macOS 26 as well?* The first chat below works there unchanged, because Apple's on-device model runs on
macOS 26. The other providers need macOS 27, so register them behind `#available(macOS 27, *)` and set your
deployment target to 26. [Targeting macOS 26 and 27](sdk-guide.md#targeting-macos-26-and-macos-27-from-one-build) shows how.

## 1. Add the SDK

The SDK's core ships as a prebuilt framework on [GitHub Releases](https://github.com/ancientcomputing/locallm/releases).
In your `Package.swift`, add it as a binary target. Use the release you want (these examples use `3.0.0-GA`) and copy its `checksum` from the matching `.sha256` file
next to the `.xcframework.zip` on that release:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "YourApp",
    platforms: [.macOS("27.0")],
    targets: [
        .binaryTarget(
            name: "LocalLMLabSDKCore",
            url: "https://github.com/ancientcomputing/locallm/releases/download/v3.0.0-GA/LocalLMLabSDKCore-3.0.0-GA.xcframework.zip",
            checksum: "..."   // the contents of the .sha256 file on that release
        ),
        .executableTarget(name: "YourApp", dependencies: ["LocalLMLabSDKCore"]),
    ]
)
```

Easiest start: a Swift package with an app or executable target, as above, which you can build from Xcode.

**Using an Xcode app project instead?** Xcode apps link the SDK through a small local package that only vends the framework. Several examples are set up this way, for instance [`vistanova`](../examples/vistanova/), whose `Package.swift` and `.xcodeproj` you can copy from.

1. Next to your `.xcodeproj`, make a folder (call it `SDK`) with a `Package.swift` like the one above, but with no app target. Add a `products:` line that exposes the framework:

   ```swift
   products: [.library(name: "LocalLMLabSDKCore", targets: ["LocalLMLabSDKCore"])],
   ```

2. In Xcode, choose **File → Add Package Dependencies…**, click **Add Local…**, and pick the `SDK` folder.
3. When Xcode asks which target gets the package product, choose your app and select `LocalLMLabSDKCore`. Xcode then builds and embeds the framework with your app.
4. Set the app target's deployment target to macOS 27 (or 26, if you support both), then `import LocalLMLabSDKCore` in your code.

The other frameworks
(`Inference` for open-weight models, which are models you can download and run yourself, `Remote` for hosted models, `Claude`, and the source packages `Components` and
`MCPAppsHost`) are added the same way when you want them. You don't need them yet.

## 2. Four words

- A **model** is the program that reads text and writes a reply. Here it is Apple's, built into macOS.
- A **provider** is how the SDK reaches a model. `SystemModelProvider` reaches Apple's on-device model.
- A **session** is one conversation with a model. It remembers what was said, so you can ask follow-up questions.
- A **route** is a name your app uses for "the model I want for this job", such as `.chat` (you declare it, as in the code below). You point the route at a
  model once, and the rest of your code only says "chat". That is how you swap models later without rewriting.

## 3. The chat

```swift
import SwiftUI
import LocalLMLabSDKCore

extension RouteName {                       // a route is just a name; the SDK ships a few (.heavy, .light, .local) and you declare your own
    static let chat: RouteName = "chat"
}

@MainActor
@Observable
final class Chat {
    let lab = LocalLMLab(configuration: .init(providers: [SystemModelProvider()]))
    let session: LocalLMLabSession

    init() throws {
        lab.models.route(.chat, to: .system)                      // "chat" means Apple's on-device model
        session = try lab.makeSession(route: .chat,
                                      instructions: "You are a helpful assistant.")
    }

    func send(_ text: String) async {
        // Sending a message streams the reply into session.hostTranscript, which the view below reads and
        // redraws as it changes, so there is nothing to collect here.
        do { for try await _ in session.streamResponse(to: text) {} }
        catch { print("turn failed: \(error)") }
    }
}

struct ChatView: View {
    @State private var chat = try! Chat()   // fine for a first try; handle the error in a real app
    @State private var draft = ""

    var body: some View {
        VStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(chat.session.hostTranscript.entries) { entry in
                        switch entry.content {
                        case .user(let text):      Text(text).bold()
                        case .assistant(let text): Text(text)
                        default:                   EmptyView()
                        }
                    }
                    if let reply = chat.session.hostTranscript.replyInProgress {
                        Text(reply.text).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            TextField("Ask something", text: $draft)
                .onSubmit { let text = draft; draft = ""; Task { await chat.send(text) } }
                .padding()
        }
    }
}
```

Run it and ask a question. What the code does:

- `LocalLMLab` is the one object that holds the models, routes and, later, tools and servers.
- `makeSession` builds a conversation from the route. `instructions` tell the model how to behave.
- `streamResponse` sends your message and fills in the reply as it is written.
- `session.hostTranscript` is the conversation as your screen should show it: your messages, the answers, and later
  the tool calls. It is `@Observable`, so a SwiftUI view that reads it redraws as it changes.

If the reply never starts, check that Apple Intelligence is on in System Settings. You can also ask the SDK:
`lab.models.availability(for: .system)` says whether the model is ready and, if not, why.

## 4. What next

Pick what you need. Each is a short step.

**Give the chat a tool.** A *tool* is a small ability you give the model. The model cannot run code. It can only write
text, so when it wants something done (look up the time, read a file) it writes a *tool call*, your app runs the
tool, and the result goes back to the model. Pass tools to `makeSession`:

```swift
session = try lab.makeSession(route: .chat, tools: [ClockTool()],
                              instructions: "You are a helpful assistant.")
```

`ClockTool` only reads, so it runs. A tool that changes something (writes a file, sends a message) needs an
*authorizer*, the code that decides whether a call may run. In 3.0 a session without one refuses those calls, so
nothing changes until you decide who may approve. To ask the user first, link the `Components` package and pass an
authorizer:

```swift
let confirmations = ToolConfirmationPresenter()          // from LocalLMLabSDKComponents
let authorizer = ConfirmingToolAuthorizer(channel: confirmations,
                                          hostTools: .ask(atOrAbove: .mutate, by: .user))
session = try lab.makeSession(route: .chat, tools: tools, authorizer: authorizer)
// and in your root view: .toolConfirmationSheet(confirmations)
```

[The tool authorizer](tool-authorizer.md) explains the rest, including what changed from 2.x.

**Use a bigger model.** Apple's on-device model is small. To run open-weight models (Qwen, Gemma, Llama and more)
on the Mac, link `LocalLMLabSDKInference`, add `MLXModelProvider()` to the providers, and point the route at one.
The same code can also reach hosted models through `LocalLMLabSDKRemote`. A model that isn't downloaded yet fails with
`.modelUnavailable` until your app downloads it: loading never downloads on its own.

**Connect an outside server.** MCP, the Model Context Protocol, is a standard way for an app to find tools on a server
someone else runs. `lab.mcp` holds your servers, and the session offers their tools to the model. Start with
[MCP in your app](https://thisbrain.ai/locallm/mcp-sdk.html), which has a safe first setup.

**Start from a complete app.** `examples/mcp-chat` is a full SwiftUI chat with servers, tool-call rows and saved
conversations. `examples/repo-qa` is the smallest example, a command-line tool. [answersearch-oss](https://github.com/ancientcomputing/answersearch-oss) is a separate open-source app that uses a hosted provider's web search.

## 5. Where to read more

- [The SDK guide](sdk-guide.md): the full reference.
- [Migrating to 3.0](migrating-to-3.0.md): if you used an earlier version.
- [The tool authorizer](tool-authorizer.md): who decides whether a tool call may run, and what changed in 3.0.
- [The security guide](security-guide-for-hosts.md): what your app must do before it ships.
- [The glossary](glossary.md): every term used in these docs.
