# LocalLM Lab

LocalLM Lab is a macOS app for running local AI models — it turns your Mac
into a private, offline chatbot with an OpenAI-compatible API, and gives
other apps and scripts a way to call the same local model directly.

Download LocalLM Lab from [its product page at https://thisbrain.ai/locallm](https://thisbrain.ai/locallm)

## What's in this repo

- **[toolkit/](toolkit/)** — The `localai-cli` CLI toolkit release (zip +
  checksum) for LocalLM Lab 0.6.0. Download, verify, and install
  instructions live there. Full CLI reference:
  [thisbrain.ai/locallm/cli.html](https://thisbrain.ai/locallm/cli.html)
- **[examples/](examples/)** — Code samples, split by feature:
  - **api-lab/** — Scripts and a sample chat app for the API Lab feature
    (LocalLM Lab's OpenAI-compatible HTTP endpoint).
  - **localai-cli/** — Python examples calling the `localai-cli` toolkit
    directly (no HTTP server, subprocess + JSON on stdin/stdout).
  - **localai-cli-swift/** — The same examples in Swift.
  - **plate-today/** and **components-demo/** — reference apps for the
    LocalLM Lab SDK, see below.
- **[Components/](Components/)** — `LocalLMLabSDKComponents`, prebuilt SwiftUI for
  managing MCP servers, built on the SDK's public API.

## LocalLM Lab SDK

Building your own native macOS app instead? `LocalLMLabSDKCore` links directly into your app's
binary — Calendar/Reminders/Contacts/Location access plus a full MCP client (tool discovery,
OAuth, Keychain-backed token storage), proven under App Sandbox with a signed path to both
Developer ID distribution and the Mac App Store (cleared for internal TestFlight testing). It's
not a demo dependency — LocalLM Lab itself runs on this SDK.

- **[docs/sdk-guide.md](docs/sdk-guide.md)** — the full developer guide: linking Core,
  entitlements, all three MCP auth types, Keychain storage, App Sandbox/MAS signing, and a full
  function/type reference.
- **[examples/plate-today/](examples/plate-today/)** — a reference app linking Core directly.
- **[examples/components-demo/](examples/components-demo/)** — a reference app built on
  `Components`' prebuilt MCP server picker UI instead.
- **[docs/annotated-examples.md](docs/annotated-examples.md)** — both reference apps' full source,
  every SDK touchpoint marked.

## Roadmap

If you want to see a new feature in LocalLM Lab, please feel free to do a pull request on ROADMAP.md
