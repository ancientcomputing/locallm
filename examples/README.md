# LocalLM Lab — Examples

Code samples for LocalLM Lab, split by which feature they use.

| Folder | Feature | What it shows |
|---|---|---|
| [api-lab/](api-lab/) | API Lab (OpenAI-compatible HTTP endpoint) | Conformance/smoke test scripts and a simple Python chat app that talk to a running LocalLM Lab server over HTTP. |
| [localai-cli/](localai-cli/) | `localai-cli` toolkit (Python) | Calling the local AI helper binary directly via subprocess — no HTTP server, no LocalLM Lab dependency for the call itself. |
| [localai-cli-swift/](localai-cli-swift/) | `localai-cli` toolkit (Swift) | Same examples as localai-cli/, in Swift. |
| [plate-today/](plate-today/) | LocalLM Lab SDK (Core), Path B | A native SwiftUI app linking `LocalLMLabSDKCore` directly — Calendar/Reminders connectors, a real Todoist MCP OAuth flow, and a signed path to both Developer ID distribution and the Mac App Store. Each connector gets its own hand-written `Tool` adapter. |
| [plate-today-tools/](plate-today-tools/) | LocalLM Lab SDK (Core), Path A | The exact same app as `plate-today/`, rebuilt on Core's ready-made `Tool`s (`GetUpcomingEventsTool`, `MCPTool`, etc.) instead of hand-written adapters — diff the two to see precisely what changes. |
| [repo-qa/](repo-qa/) | LocalLM Lab SDK (Core), Path A | A minimal command-line tool — no signing, no macOS permission needed. Builds a `Tool` for a real MCP server's (Deepwiki's) own tools straight from their live schema, no hand-written `Arguments` struct. Answered by Apple's on-device model. |
| [repo-qa-local/](repo-qa-local/) | LocalLM Lab SDK (Core **+ Inference**) | The exact same tool as `repo-qa/`, but the answer comes from an **open-weight MLX model you download and run locally** (`mlx-community/Qwen3-8B-4bit` by default), routed through the 1.0 model layer. The smallest possible model-layer + MLX example — diff the two `main.swift`s to see what the model layer adds. |
| [workspace-buddy/](workspace-buddy/) | LocalLM Lab SDK (Core), Path A | A local AI-assisted coding example: pick a folder, the on-device model reads/creates/edits files in it via Core's `WorkspaceTools`. Sandboxed — the security-scoped bookmark demo. |
| [workspace-buddy-local/](workspace-buddy-local/) | LocalLM Lab SDK (Core **+ Inference**) | The same sandboxed `.app` as `workspace-buddy/`, but with a downloadable **open-weight MLX model** routed through the model layer. The one example running the model layer inside **App Sandbox** (adds the `network.client` entitlement for the model download). |
| [code-buddy/](code-buddy/) | LocalLM Lab SDK (Core **+ Inference**) | The full model layer: a CLI coding agent running **locally-run MLX models** through `LocalLMLab` + `MLXModelProvider` (heavy/light routes, one resident at a time), Core's Workspace tools, a no-auth MCP server, and two **host-owned** `Process` tools (git, run-tests) the SDK deliberately doesn't ship. |
| [os-matrix/](os-matrix/) | LocalLM Lab SDK (Core **+ Inference**) | One `.macOS("26.0")` CLI that runs on both macOS 26 and 27 with no source `#if` — shows `ModelAvailability.requiresOS` gating the 27-only providers. |
| [components-demo/](components-demo/) | LocalLM Lab SDK (`Components`) | The same SDK, via the prebuilt `LocalLMLabSDKComponents` MCP server picker UI instead of building your own. |
| [model-switch/](model-switch/) | LocalLM Lab SDK (Core **+ Remote** + `Components`) | The online / remote providers: add a provider + API key, tick web search, switch between every configured model (on-device, PCC, Claude-4-FM, GPT, Claude online, OpenRouter) from one chat window. |

**Path A vs Path B**, for the four Core-based examples above: two ways to turn a connector or MCP
server into something the on-device model can call as a tool. **Path A** drops in a ready-made
`Tool` Core already ships, correctness lessons from real on-device model failures baked into its
description. **Path B** hand-writes a custom adapter directly against the underlying connector
call (`CalendarAccess`, `MCPServerManager`, etc.) for full control over tool names, schemas, and
descriptions. Neither is the "real" one — both ship in Core, and an app can mix them. See
[`../docs/sdk-guide.md` §7a](../docs/sdk-guide.md#7a-two-paths-to-tool-calling-ready-made-tools-or-write-your-own)
for the full framing.

The `localai-cli` examples require the CLI toolkit itself, shipped in
[../toolkit/](../toolkit/). See that folder's README to download and
install it, and [thisbrain.ai/locallm/cli.html](https://thisbrain.ai/locallm/cli.html)
for the full CLI reference.

Download LocalLM Lab from [its product page at https://thisbrain.ai/locallm](https://thisbrain.ai/locallm)

---

## Building & running an SDK example

Each SDK example (everything except the `api-lab/` and `localai-cli*/` folders) is a standalone
SwiftPM package. It resolves `LocalLMLabSDKCore` (and, where used, `LocalLMLabSDKInference` /
`LocalLMLabSDKRemote`) as a **binary** dependency from a GitHub Release on this repo — nothing to
download or unzip by hand. Requires **macOS 27** on Apple Silicon and the **Xcode 27 beta** (a
stable Xcode fails with `'v27' is unavailable`).

The examples on this `1.0.0-beta` branch build against SDK **`1.0.0-beta.3`**; the ones on `main`
build against the latest stable release. No environment variable is needed for either.

### What each example needs

| Example | Kind | `swift run` (or Xcode ▸ Run) | To get a real `.app` (`packaging/build-and-sign.sh`) |
|---|---|---|---|
| `repo-qa`, `code-buddy`, `os-matrix` | CLI | ✅ the whole example | — (no `packaging/`) |
| `components-demo`, `model-switch` | SwiftUI, no system permissions | ✅ — real `.app` via the committed `.xcodeproj` (ad-hoc, no account needed); bundle-less via `Package.swift` / `swift run` | **any** identity, or **none** — see the table below |
| `plate-today`, `plate-today-tools` | SwiftUI + Calendar / Reminders / Contacts | ✅ via the committed `.xcodeproj` — **Automatic** signing: Xcode uses your Apple ID's Apple Development identity (a **free** one works), needed for reliable prompts. No Apple ID → add one or pick *Sign to Run Locally*. Bare `swift run` is denied the prompts. | **a signing identity is required** — a **free** "Apple Development" one works |
| `workspace-buddy`, `workspace-buddy-local` | SwiftUI + App Sandbox | ✅ via the committed `.xcodeproj` — **Automatic** signing (as above); a stable team identity is what lets the security-scoped bookmark survive a rebuild. Bare `swift run` is compile-only. | same as `plate-today` |

"Apple Development" = the free identity Xcode creates once you add any Apple ID under
**Xcode ▸ Settings ▸ Accounts**. No paid Apple Developer account, no Developer ID certificate.

### In Xcode

1. Get the code — either `git clone https://github.com/ancientcomputing/locallm`, or open the
   repo's page on **github.com**, click the green **`<> Code`** button, choose **Download ZIP**,
   and unzip. (That button is on the GitHub website, not in Xcode.)
2. Open the project:
   - **The six SwiftUI examples** (`components-demo`, `model-switch`, `plate-today`,
     `plate-today-tools`, `workspace-buddy`, `workspace-buddy-local`) ship a committed
     `.xcodeproj` — **File ▸ Open** → `examples/<name>/<Name>.xcodeproj`. Run gives a *real*
     `.app` (Dock icon, menu bar, `⌘,`, URL scheme, entitlements). The project is generated from
     `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen) — edit `project.yml`
     and `xcodegen generate`, not the `.xcodeproj` directly.
   - **Every example** also opens as a package: **File ▸ Open** → `examples/<name>/Package.swift`.
     Run works, but a SwiftUI app runs bundle-less (no Dock icon, `⌘,` may not register).
   Either way Xcode resolves the SDK binary automatically — no `LOCALLM_SDK_VERSION`.
3. Choose the scheme (named after the example) and press **Run**.

   **Signing of the `.xcodeproj` Run build:**
   - `components-demo`, `model-switch` — **ad-hoc**, no account needed. They only make outbound
     HTTPS calls, so ad-hoc is fine.
   - `plate-today`, `plate-today-tools`, `workspace-buddy`, `workspace-buddy-local` —
     **Automatic**, no hard-coded team. Xcode signs with your **Apple Development** identity: add
     any Apple ID under **Xcode ▸ Settings ▸ Accounts** (a **free** one is enough) and Xcode
     picks it up. With no Apple ID, Run stops with *"requires a development team"* — add one, or
     open the target ▸ **Signing & Capabilities** and choose **Sign to Run Locally** (ad-hoc; the
     app runs, but Calendar/Reminders prompts are unreliable and the workspace bookmark won't
     survive a rebuild). None of this touches `packaging/build-and-sign.sh`, which signs with
     `APP_IDENTITY` (below).

   CLI examples take arguments — **Product ▸ Scheme ▸ Edit Scheme… ▸ Run ▸ Arguments**.

### Signing a `.app` — `APP_IDENTITY`

`packaging/build-and-sign.sh` reads `APP_IDENTITY`. What each value does:

| `APP_IDENTITY` | Paid account? | Where the `.app` runs | Notarize? |
|---|---|---|---|
| unset (or `-`) | no | **this Mac only** — ad-hoc signature; Gatekeeper rejects it elsewhere, and Calendar / Reminders / Contacts / Sandbox grants are unreliable | no (`NOTARIZE_APP` forced to `0`) |
| `Apple Development: NAME (TEAMID)` | no (free) | **this Mac only** — but with working system-permission prompts. `spctl` still flags it "not notarized"; harmless for your own machine | no |
| `Developer ID Application: NAME (TEAMID)` | **yes** ($99/yr) | **anywhere**, once notarized — add `NOTARIZE_APP=1` and `KEYCHAIN_PROFILE` | yes |

`security find-identity -v -p codesigning` lists the identities installed on your Mac — use one
of those strings verbatim.

```bash
cd examples/model-switch
# no account — local ad-hoc build:
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer ./packaging/build-and-sign.sh
# free Apple ID:
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  APP_IDENTITY="Apple Development: Your Name (TEAMID)" NOTARIZE_APP=0 ./packaging/build-and-sign.sh
```

### From the command line

```bash
cd examples/repo-qa
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  swift run RepoQA facebook/react "how does the reconciler work?"
```

```bash
cd examples/model-switch          # a SwiftUI app — opens a window, takes no arguments
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  swift run ModelSwitch
```

Set `LOCALLM_SDK_VERSION` to build against a specific published release instead of the package
default. This works from a shell and in CI — **but not from inside Xcode**, whose package
resolution doesn't inherit shell environment variables.

```bash
cd examples/repo-qa
LOCALLM_SDK_VERSION=1.0.0-beta.2 \
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  swift run RepoQA facebook/react
```

### Building against a different SDK version

Every `examples/*/Package.swift` (and `Components/Package.swift`) has a `defaultSDKVersion` line
and a small `knownSDKReleases` table — the current release plus the previous one:

```swift
let defaultSDKVersion = "1.0.0-beta.3"

let knownSDKReleases: [String: SDKRelease] = [
    "1.0.0-beta.2": SDKRelease(url: "…/v1.0.0-beta.2/LocalLMLabSDKCore-1.0.0-beta.2.xcframework.zip",
                               checksum: "e3e687e5…"),
    "1.0.0-beta.3": SDKRelease(url: "…/v1.0.0-beta.3/LocalLMLabSDKCore-1.0.0-beta.3.xcframework.zip",
                               checksum: "a276ab7b…"),
]
```

To use a release that isn't listed, add an entry. The URL always follows
`https://github.com/ancientcomputing/locallm/releases/download/v<version>/LocalLMLabSDK<Module>-<version>.xcframework.zip`,
and the checksum is the `.sha256` file published next to each `.xcframework.zip` on that release:

```bash
curl -sL https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-beta.1/LocalLMLabSDKCore-1.0.0-beta.1.xcframework.zip.sha256
# → 0b4ab34e474d1acd725161cfb591cf3d862a7529fe7c9dbadf01eece3ad1590f
```

Then point `defaultSDKVersion` at it (works everywhere, Xcode included) or pass
`LOCALLM_SDK_VERSION=<version>` from a shell. Simplest of all for a one-off: just replace the URL
and checksum strings in place.
