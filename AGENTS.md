# Working with the LocalLM SDK (for coding agents)

This is the public home of the LocalLM Lab SDK (release `3.0.0-GA`): its documentation, examples, the source of
`Components` and `MCPAppsHost`, and links to the prebuilt frameworks on the GitHub releases. The rest of the SDK's source
is closed, so you build apps that use it. You do not edit the SDK.

If you are helping a developer build, debug or change a macOS app that uses the SDK, read the skill first:
[`skills/locallm-swift-app/SKILL.md`](skills/locallm-swift-app/SKILL.md). Claude Code finds it in
`.claude/skills/`. Other agents can read the file directly. Its `references/doc-map.md` says which doc answers which question.

## Where facts come from

Use these in order, and do not write SDK code from memory:

1. [`docs/api-surface.md`](docs/api-surface.md): the generated list of public names, signatures and enum cases. Confirm a
   name here before you use it.
2. [`docs/sdk-guide.md`](docs/sdk-guide.md) and the topic guides it links to.
3. [`examples/`](examples/README.md): complete apps. Copy the one closest to the task; `examples/mcp-chat` is the chat UI.

## Rules that are easy to get wrong in 3.0

1. **Give every `makeSession` that has tools an `authorizer:`.** With none, the session refuses anything that may change
   data or send it out, and the model reads `DENIED: ...`. Nothing throws, so the bug is silent. An app with a window passes
   `ConfirmingToolAuthorizer` with Components' `ToolConfirmationPresenter`; a command-line tool or batch job with no one to
   ask passes `AllowingToolAuthorizer()` and says why. See [`docs/tool-authorizer.md`](docs/tool-authorizer.md).
2. **Loading a model never downloads it.** For an open-weight (MLX) model, check `availability`, call `validate` (its
   `PreflightResult.weightBytes` is the size to show the user), then `download(_:)`, before the first session. A session on a model that isn't on disk fails with
   `.modelUnavailable`.
3. **Platform:** macOS 27 and Xcode 27 to build. Providers that need macOS 27 go behind `if #available(macOS 27, *)`. Link
   only the modules the app uses.
4. **MCP tools reach the model as `<prefix>_<tool>`** (`github_list_issues`). A server starts untrusted, and a server that
   changes its tools is held for review. See [`docs/mcp-guide.md`](docs/mcp-guide.md).
5. **Do not assume a model can call tools.** Probe it with `MLXModelProvider.capabilityProbe`.
6. **Enums in the SDK's API are not frozen.** A `switch` over one (`ModelAvailability`, `ToolCallRecord.State`, ...) needs an
   `@unknown default`, or it fails to compile.
7. **Tools you hand directly to Apple's `LanguageModelSession(tools:)` bypass the authorizer.** Give them to the SDK's
   `makeSession` instead. The built-in Calendar, Reminders and Contacts write tools are rated `.mutate` or `.destructive`, so a
   session with no authorizer refuses them; your own tools need `ImpactRatedTool` so a read isn't treated as a change.

## Verify before you say it works

- Build with `swift build`, or Xcode for an `.app`.
- Run a turn that calls a tool that **writes**, and check its result is not `DENIED: ...`. A refused call does not throw.
- Anything that depends on Calendar, Reminders, Contacts, Location, OAuth, Keychain or App Sandbox needs a real signed
  `.app` to test. A bare `swift run` can pass or fail for the wrong reason.

## Linking the SDK

This repo is a Swift package. Add it by URL with the rule **Branch** `3.0.0-GA` (each release is its own branch, so a
version rule such as "Up to Next Major" does not apply): in an Xcode project, File → Add Package Dependencies (the command needs an open project; with no project, use a Swift package); in a `Package.swift`,
`.package(url: "https://github.com/ancientcomputing/locallm", branch: "3.0.0-GA")` and
`.product(name: "LocalLMLabSDKCore", package: "locallm")`. The products are `LocalLMLabSDKCore`, `LocalLMLabSDKInference`,
`LocalLMLabSDKRemote`, `LocalLMLabSDKClaude`, `LocalLMLabSDKComponents` and `LocalLMLabSDKMCPAppsHost`; add only what the app uses.
To pin the exact files instead, the four frameworks are binary targets: the release's `.xcframework.zip` URL and the checksum from
the `.sha256` file beside it. A Swift package *executable* (not an Xcode app project) also needs `linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path"])]`, or it builds but fails at launch with `Library not loaded: @rpath/...`; an Xcode app project doesn't. `Components` and `MCPAppsHost` are source in this repo. The
[quickstart](docs/quickstart.md) has the steps and a manifest, and the examples' `Package.swift` files have working ones.

## If you do not have this repo on disk

The same files are on the `3.0.0-GA` branch. Read them from
`https://raw.githubusercontent.com/ancientcomputing/locallm/3.0.0-GA/<path>`, for example `.../docs/api-surface.md`.
