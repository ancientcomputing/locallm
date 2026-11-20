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

This repository is a Swift package, so you add it by its URL. The SDK's core libraries are prebuilt frameworks that the package
fetches from [GitHub Releases](https://github.com/ancientcomputing/locallm/releases); each is checked against a fingerprint, so you get
exactly the files that were released.

**In an Xcode app project.** The Add Package Dependencies command only exists while a project or workspace is open. If you don't have
one yet, choose File → New → Project, pick **macOS → App** with SwiftUI, or skip to the Swift package route below. With a project open:

1. Choose **File → Add Package Dependencies…** and paste `https://github.com/ancientcomputing/locallm` into the search box.
2. Xcode starts on **Up to Next Major Version** (it may show `1.0.0`). Change **Dependency Rule** to **Branch** and type `3.0.0-GA`, then click
   **Add Package**. Left on the default, Xcode can't find a matching version, because releases here are branches.
3. In the next dialog, every library starts with **None** under **Add to Target**. Set each library your app uses to your app target. For this page, `LocalLMLabSDKCore` is enough; add
   `LocalLMLabSDKComponents` later for the approval sheet and chat views. Xcode builds and embeds them with your app.
4. Set the app target's deployment target to macOS 27 (or 26, if you support both), then `import LocalLMLabSDKCore` in your code.

**In a Swift package** (a program you build with `swift build`, or open in Xcode):

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "YourApp",
    platforms: [.macOS("27.0")],
    dependencies: [
        .package(url: "https://github.com/ancientcomputing/locallm", branch: "3.0.0-GA"),
    ],
    targets: [
        .executableTarget(
            name: "YourApp",
            dependencies: [.product(name: "LocalLMLabSDKCore", package: "locallm")],
            // A Swift package program has no runtime search path, so without this line it builds but dies at launch
            // with "Library not loaded: @rpath/LocalLMLabSDKCore.framework". This points it at the framework SwiftPM places beside it.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path"])]
        ),
    ]
)
```

To run it from Xcode, open the folder that has `Package.swift` (`open Package.swift`, or File → Open), pick the scheme named after your
program with **My Mac** as the destination, and press ⌘R. From a terminal, `swift run` works too. An Xcode app project doesn't need the
linker line: Xcode embeds the framework for you.

**Why a branch, and what it costs.** Each release of the SDK is its own branch of this repository, named for the release (`3.0.0-GA`),
so you choose **Branch** and type the release you want. A version rule such as "Up to Next Major Version" doesn't apply, because
releases here are branches, not version tags. To move to a later release, change the branch name. Xcode records the exact commit it
fetched, so your build doesn't change until you update the package. Adding the package downloads about 16 MB, because all four
prebuilt libraries (Core, Inference, Remote and Claude) come with it; only the ones you add to your target are linked into your app.

**Prefer to write the manifest yourself?** You can pin the files directly, for a locked-down network or to be sure of the exact
release. Add the framework as a binary target. Use the release you want (this one is `3.0.0-GA`) and copy its `checksum` from the
matching `.sha256` file next to the `.xcframework.zip` on that release:

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
        .executableTarget(
            name: "YourApp",
            dependencies: ["LocalLMLabSDKCore"],
            // A Swift package program has no runtime search path, so without this line it builds but dies at launch
            // with "Library not loaded: @rpath/LocalLMLabSDKCore.framework". This points it at the framework SwiftPM places beside it.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path"])]
        ),
    ]
)
```

To get the checksum, read the `.sha256` file beside the zip on the release:

```bash
curl -sL https://github.com/ancientcomputing/locallm/releases/download/v3.0.0-GA/LocalLMLabSDKCore-3.0.0-GA.xcframework.zip.sha256
```

**In an Xcode app project, with your own manifest?** Xcode apps link the SDK through a small local package that only vends the framework. Several examples are set up this way, for instance [`vistanova`](../examples/vistanova/), whose `Package.swift` and `.xcodeproj` you can copy from.

1. Next to your `.xcodeproj`, make a folder (call it `SDK`) with a `Package.swift` like the one above, but with no app target. Add a `products:` line that exposes the framework:

   ```swift
   products: [.library(name: "LocalLMLabSDKCore", targets: ["LocalLMLabSDKCore"])],
   ```

2. In Xcode, choose **File → Add Package Dependencies…**, click **Add Local…**, and pick the `SDK` folder.
3. When Xcode asks which target gets the package product, choose your app and select `LocalLMLabSDKCore`. Xcode then builds and embeds the framework with your app.
4. Set the app target's deployment target to macOS 27 (or 26, if you support both), then `import LocalLMLabSDKCore` in your code.

The other libraries (`Inference` for open-weight models, which are models you can download and run yourself, `Remote` for hosted
models, `Claude`, and the source libraries `Components` and `MCPAppsHost`) are added the same way when you want them. You don't need them yet.

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

**Show it in your app.** `ChatView` is a SwiftUI view, so put it where your app shows its first window. In a new Xcode project from the
macOS **App** template, open the file with `@main struct MyApp: App` and change `ContentView()` to `ChatView()`. In a Swift package, add a file
like this:

```swift
import SwiftUI

@main
struct YourApp: App {
    var body: some Scene {
        WindowGroup { ChatView() }
    }
}
```

Then run it and ask something that doesn't need current facts, for example "Say hello in three languages." Apple's on-device model is small.

If the reply never starts, check that Apple Intelligence is on in System Settings. You can also ask the SDK:
`lab.models.availability(for: .system)` says whether the model is ready and, if not, why.

**Want to run a finished version first?** [`examples/model-chat`](../examples/model-chat/) in this repo is a complete chat window with a
model picker (Apple's on-device model or an open-weight model on this Mac) and two tools shown as rows. It is about 200 lines. Clone the repo and run
`swift run ModelChat` in that folder, or read its `ModelChatApp.swift` beside the steps above.

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
session = try lab.makeSession(route: .chat, tools: [ClockTool()], authorizer: authorizer)   // plus your tools that change things
// and in your root view: .toolConfirmationSheet(confirmations)
```

**See the approval sheet.** `ClockTool` only reads, so nothing asks. To see the sheet, give the chat a tool that changes something. This one writes a
note to a file:

```swift
import FoundationModels   // Tool, Generable, Guide
import LocalLMLabSDKCore

struct SaveNoteTool: Tool, ImpactRatedTool {
    let name = "saveNote"
    let description = "Saves a short note to a file on this Mac."
    var impact: ToolImpact { .mutate }   // says this tool changes data, so the authorizer asks first

    @Generable
    struct Arguments {
        @Guide(description: "The text of the note")
        var text: String
    }

    func call(arguments: Arguments) async throws -> String {
        try arguments.text.write(toFile: "/tmp/quickstart-note.txt", atomically: true, encoding: .utf8)
        return "Saved the note."
    }
}
```

In `Chat`, keep the presenter in a property (`let confirmations = ToolConfirmationPresenter()`), build the session with
`tools: [ClockTool(), SaveNoteTool()]` and the authorizer above, and add to `instructions`: "When the user asks you to save a note, call the
saveNote tool." In `ChatView`, add `.toolConfirmationSheet(chat.confirmations)` after the `VStack`'s closing brace. Then type "Please save a note that says: buy milk".

A sheet appears that names the tool (`saveNote`), says **Changes data**, shows the text, and offers **Deny** and **Allow**. Nothing is written until you
press Allow.

 After **Allow**, the file `/tmp/quickstart-note.txt` holds the note and the model says it saved it. After **Deny**, the file is untouched and
the model says the note wasn't approved. The `ChatView` above shows only the messages, not the tool call itself; add a `case .toolCall(let record):`
to its `switch` to show each call and whether it ran or was refused.

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
- [Build with an AI coding agent](https://thisbrain.ai/locallm/coding-agents.html): set up Claude Code, Codex or another agent, with starter prompts.
