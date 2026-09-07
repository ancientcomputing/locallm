# AIQL — ask your data

**AIQL** is a small Mac app for someone who lives in a marketing or analytics tool, not a
terminal. You give it three things — a local model, an **MCP data source**, and a plain-English
request — and press **Go**. It pulls the dataset, turns it into the spreadsheet you asked for,
and drops a `.csv` into a folder you chose.

The data is read by a model running **on your Mac** — nothing is sent to an online AI provider.
And the model never actually touches the rows: it decides *which* dataset, *which* columns, and
*how* to sort or filter; SDK primitives do every row-level step. So the model can't miscopy or
invent a single value.

This is the SwiftUI counterpart to the pipeline in
[`docs/sdk-guide.md` §8b](../../docs/sdk-guide.md).

## What Go does

1. **Connect** to the MCP server. A public server connects straight away; an OAuth server opens a
   browser sign-in and comes back on its own (`aiql://oauth/callback`).
2. **Download the model** if it isn't cached yet (first run only — progress bar).
3. **Run the pipeline** in the folder you chose:

   ```
   the data tool  → raw/data.json     (FileBackedTool `saveAs` — the raw payload never enters the model's context)
   describeJson    raw/data.json       (find the records and their real field names)
   jsonToCsv       → all.csv           (the host reads every record — no transcription)
   sortRows / filterRows / selectColumns   (only the steps your request asks for)
   → out.csv
   ```

The progress panel shows each step in plain language as it happens ("Building the spreadsheet…",
"Sorting…"). When it's done, the CSV preview appears with a **Show in Finder** button.

## What it highlights for SDK developers

It's three existing examples stitched together, plus the "AIQL" data verbs:

| from | what it contributes |
|---|---|
| [`workspace-buddy-local`](../workspace-buddy-local) | SwiftUI + App Sandbox + `MLXModelProvider` download + `NSOpenPanel` folder picker + security-scoped bookmark |
| [`plate-today`](../plate-today) | `MCPServerManager` + the OAuth redirect wired through `AppDelegate` (not SwiftUI's `.onOpenURL`) + `CFBundleURLTypes` |
| [`repo-qa`](../repo-qa) | building tools from a live MCP schema — here `FileBackedTool.mcp(descriptor:manager:root:)` |
| SDK §8b | `describeJson` · `jsonToCsv` · `selectColumns` · `filterRows` · `sortRows` · `concatRows` · `csvInfo` |

Other things worth a look in `Sources/AIQL/AIQLApp.swift`:

- **`session.events`** — the pipeline's progress panel is driven by the session's tool-call
  side-channel (`SessionEvent.toolCallStarted` / `.toolCallFinished`), mapped to friendly labels.
- **Tool curation for a small model** — the server's tools are ranked by how "dataset-like" the
  name looks and only the top few are wrapped; `readWorkspaceFile` is deliberately not offered
  (the raw dump is far past the context window, so the model only ever sees the bounded
  `describeJson` / `csvInfo` views).

## Getting the SDK & toolchain

Copy-paste each step. Step 1 is one-time machine setup; step 2 sets up your terminal session.

**1. Install the Xcode 27 beta.** Download it from
[developer.apple.com/xcode](https://developer.apple.com/xcode/) and drag it to `/Applications`
(it installs as `Xcode-beta.app`, alongside any stable Xcode). A stable Xcode fails with
`'v27' is unavailable` because `Package.swift` requires `platforms: [.macOS("27.0")]`.

**2. Point `swift` at the Xcode 27 beta** for the terminal you'll build from:

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
```

Leaves your system default alone; lasts only for the current terminal (re-run it in each new one,
or add it to your `~/.zshrc`). `Package.swift` builds against SDK `1.0.0-beta.3` with no further
setup — it links **two** binaries, `LocalLMLabSDKCore.xcframework` and
`LocalLMLabSDKInference.xcframework` (the MLX runtime, which carries its own Metal shaders), from
that one GitHub Release. `export LOCALLM_SDK_VERSION=<version>` to pin a different published
release. Building the xcframeworks needs the Metal Toolchain — as a *consumer* of the prebuilt
Inference slice you do not.

**3. Compile-check:**

```bash
swift build
```

This just proves it builds. To *actually run* it: open the Xcode project (next), or make a
signed `.app` with `packaging/build-and-sign.sh` (further below).

## Open in Xcode and Run

A committed `AIQL.xcodeproj` is the lowest-friction way to try it. **Open it in `Xcode-beta.app`,
not a stable Xcode** (the target is macOS 27):

```bash
open -a Xcode-beta AIQL.xcodeproj
```

Pick the **AIQL** scheme and Run — a real sandboxed `.app` with the
`files.user-selected.read-write` and `network.client` entitlements (the model download and the
MCP connection both need the latter), the `aiql://` URL scheme registered for the OAuth callback,
and the `LocalLMLabSDKInference` (MLX) framework embedded. **First Go downloads the model**
(~4.3 GB for the default); after that it's local and offline.

**Signing.** Set to **Automatic** with no hard-coded team, so Xcode signs with your **Apple
Development** identity — the security-scoped bookmark for the output folder is bound to the
signing identity and won't survive a rebuild under an ad-hoc one.

| Your Xcode setup | What happens on Run |
|---|---|
| One Apple ID in **Xcode ▸ Settings ▸ Accounts** (**free** is enough) | picked automatically — stable `Apple Development` signing, bookmark persists across rebuilds |
| No Apple ID | Run stops with *"requires a development team"* — add a free Apple ID, **or** target ▸ **Signing & Capabilities** ▸ **Sign to Run Locally** (ad-hoc; runs, but you re-pick the folder each rebuild) |

Only the Xcode Run build is affected. `packaging/build-and-sign.sh` (below) ignores the project
file and signs with whatever `APP_IDENTITY` you pass it.

Generated from [`project.yml`](project.yml) with
[XcodeGen](https://github.com/yonaskolb/XcodeGen) — edit `project.yml`, not the `.xcodeproj`,
then `xcodegen generate`.

## Running it — the distributable build

A bare `swift build` is compile-only (no sandbox, no entitlements, no URL scheme).
`packaging/build-and-sign.sh` makes a `.app` you can hand to another Mac (Developer-ID signed and
notarizable). A **free "Apple Development"** identity is enough for a local run; a Developer ID
for distribution.

```bash
APP_IDENTITY="Apple Development: Your Name (TEAMID)" NOTARIZE_APP=0 \
  ./packaging/build-and-sign.sh          # → dist/AIQL.app
open dist/AIQL.app
```

(`DEVELOPER_DIR` and `LOCALLM_SDK_VERSION` come from step 2.) The model download lands in the
app's sandbox container at
`~/Library/Containers/lab.locallm.sdk.reference.aiql/Data/Library/Caches/huggingface/` (not
`~/.cache`) — swift-huggingface redirects it automatically for a sandboxed app.

## Try it

The **Anthropic Economic Index** publishes a public, no-auth MCP server — a good first data
source because every one of its tools returns a clean table of records:

- **MCP data source:** `https://econ-index.mcp.claude.com/mcp`

Paste any of these into **Request** (leave the model and server at their defaults):

| Request | `out.csv` you get back |
|---|---|
| `every country and its usage index, highest first, top 10` | `country,usage_index` — Australia 6.4, Singapore 5.81, … |
| `the 15 US states with the highest Claude usage index, and their automation percentage` | `state,usage_index,automation_pct` |
| `the top 20 work tasks people use Claude for, with each task's share percentage` | `rank,task,share_pct` |
| `countries where coursework use is above 20 percent, highest usage index first` | `country,usage_index,coursework_pct` |
| `all job categories ranked by their share of global Claude usage` | `category,share_pct` |

The first request is verified end to end from the command line (same server, same
`mlx-community/Qwen3-8B-4bit`): one tool call per step, `out.csv` exact against the published
index. The rest use the same dataset and the same pipeline shape — **one dataset tool, then a
filter and/or a sort, then the columns you named** — which is what the 8B default runs cleanly.
Stacking three or more refinements into one request is where a smaller model starts adding a
step you didn't ask for (see [Model choice](#model-choice)). The app wraps this pipeline in a
UI; its progress panel is fed by `session.events`.

**Writing your own.** Name a dataset ("every country", "US states", "work tasks", "job
categories"), the columns you want, and up to two refinements: "top N" / "highest … first" → a
sort, "where X is above/below N" / "only rows containing …" → a filter. The model picks the tool
and the field names; the data verbs do every row-level step, so `out.csv` can't contain a value
the source didn't have.

## Model choice

`mlx-community/Qwen3-8B-4bit` (the default, ~4.3 GB) runs the pipeline cleanly — the verbs remove
the two things it gets wrong on raw data (transcription, and "top N", which is now a mechanical
`sortRows`). A 4B model usually works but sometimes adds a step you didn't ask for. A 12B+ model
is the most reliable. Any MLX-format Hugging Face repo id works in the field.

The model field and the download progress panel here are hand-built (the panel is fed by
`session.events`). For a settings-screen version of the same thing — a model list with
availability badges, on-disk sizes, and an "Add from Hugging Face" field — use `Components`'
`ModelPickerView`; see
[`docs/sdk-guide.md` §11](../../docs/sdk-guide.md#11-components-prebuilt-swiftui-mcp-servers--the-model-layer).

## More

- [`docs/sdk-guide.md` §8b](../../docs/sdk-guide.md) — the "AIQL" data verbs, in prose.
  §6a — the model layer. §8 — App Sandbox + the folder picker.
- [`workspace-buddy-local`](../workspace-buddy-local) — the sandbox + MLX + folder-picker base
  this builds on.
- [`plate-today`](../plate-today) — the MCP + OAuth-redirect base.
