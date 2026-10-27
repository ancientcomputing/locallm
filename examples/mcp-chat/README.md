# MCP Chat

A chat with a local model where a tool call that has an MCP App shows the server's interactive
widget inline in the conversation. Ask "What's due today?" with Todoist
connected and the model calls `find-tasks-by-date`; the app sees that the tool links a widget and
shows Todoist's task list under the call.

Qwen3 8B through MLX by default; Apple's on-device model as an alternative (Settings).

`Package.swift` builds against SDK `2.3.0-GA` with no further setup (MCP Apps support is new in
2.0): `LocalLMLabSDKCore` and `LocalLMLabSDKInference` (the MLX runtime) come from that GitHub
Release, `Components` (`../../Components`) and `MCPAppsHost` (`../../MCPAppsHost`) from this repo as
source. Needs macOS 27 and Xcode 27 (Swift 6.4). No Metal Toolchain needed — the prebuilt Inference
xcframework bundles the compiled shaders.

## Open in Xcode and Run

```bash
open -a Xcode MCPChat.xcodeproj
```

Pick the **MCPChat** scheme and Run. The app is App-Sandboxed with outbound network only, like the
packaged build. Signing is *Automatic* with no hard-coded team: add an Apple ID in **Xcode ▸ Settings
▸ Accounts** (free is enough), or switch Signing to **Sign to Run Locally**.

Generated from [`project.yml`](project.yml) with [XcodeGen](https://github.com/yonaskolb/XcodeGen).
Edit `project.yml`, not the `.xcodeproj`, then run `xcodegen generate`.

## Build and run from the command line

```bash
packaging/build-and-sign.sh            # sandboxed release build → dist/MCP Chat.app
open "dist/MCP Chat.app"
```

The first launch offers to download Qwen3 8B (about 4.6 GB, pinned to a reviewed revision) into the
app's sandbox container — see [Where the model is stored](#where-the-model-is-stored).

For development, a build without App Sandbox can use a model you already have instead:

```bash
CONFIG=debug SANDBOX=0 packaging/build-and-sign.sh
open --env MCPCHAT_MODEL_CACHE=/path/to/huggingface/hub "dist/MCP Chat.app"
```

## Where the model is stored

The sandboxed build (Xcode Run, or `packaging/build-and-sign.sh` without `SANDBOX=0`) can't write
outside its container, so swift-huggingface puts the Hugging Face cache there instead of
`~/.cache/huggingface`:

```
~/Library/Containers/lab.locallm.mcpapps.chat/Data/Library/Caches/huggingface/hub/
    models--mlx-community--Qwen3-8B-4bit/
        snapshots/<commit-sha>/        # config.json, *.safetensors, tokenizer…
        blobs/                          # the actual bytes (snapshot files symlink here)
```

- The container is named after the bundle ID, `lab.locallm.mcpapps.chat`. The Xcode Run build and
  `dist/MCP Chat.app` share it, so one download serves both.
- Nothing else shares it. A copy in `~/.cache/huggingface/hub` or in another example's container
  isn't used (unless you point `MCPCHAT_MODEL_CACHE` at it from an unsandboxed build, above).
- To look at it in Finder: **Go ▸ Go to Folder…** (⇧⌘G) and paste the path. If macOS asks whether
  Finder or Terminal may access another app's data, allow it.

### Removing the model

Quit MCP Chat first, then delete the model's folder:

```bash
rm -rf ~/Library/Containers/lab.locallm.mcpapps.chat/Data/Library/Caches/huggingface/hub/models--mlx-community--Qwen3-8B-4bit
```

The next launch offers the download again, at the same pinned revision. If a download was
interrupted, the folder may hold only the small files (config, tokenizer); removing it makes the
next download start from scratch.

To start completely fresh — the model, the saved conversation and the app's settings — quit the app
and remove the whole container. macOS creates a new one on the next launch:

```bash
rm -rf ~/Library/Containers/lab.locallm.mcpapps.chat
```

If `rm` says *Operation not permitted*, macOS is protecting the app's data: allow Terminal when it
asks, or delete the folder in Finder instead.

## Try it

1. Add a server with the server button in the toolbar:
   - System Monitor (`examples/system-monitor-server` in
     [modelcontextprotocol/ext-apps](https://github.com/modelcontextprotocol/ext-apps), run locally):
     `http://localhost:3001/mcp`, auth **None**.
   - Todoist: `https://ai.todoist.net/mcp`, auth **None** (OAuth with dynamic registration: you sign
     in in your browser when you click Add).
2. **Turn tools on.** A new server's tools start off (the SDK's default — a server's tools reach the
   model only when the user opts in). The app shows a banner until at least one is on. For
   Todoist: `find-tasks-by-date` (the one with a widget), `add-tasks`, `complete-tasks`,
   `reschedule-tasks`, `find-projects`. For System Monitor: `get-system-info`.
3. Ask "How is my system doing?" or "What's due tomorrow?".

## What it shows

- **Widgets from tool calls.** The model only chooses tools. A tool whose listing carries
  `_meta.ui.resourceUri` gets its widget drawn under the call when it finishes, fed the call's
  arguments and result. The SDK adds one line to such tools' descriptions
  (`makeSession(…, mcpAppHints: true)`) so a model can prefer them when asked to *see* something.
- **One gate for model and widget.** A widget's own tool calls go through the session
  (`MCPAppsSessionBackend`), so they meet the same approval as the model's and are recorded
  ("by a view"). Each server has a trust level and a tool approval, set on its row in the server
  list (Components' picker): an untrusted server (the default) asks before anything that may
  change data; a trusted one has its read-only / destructive labels believed and asks only before
  destructive tools. `ConfirmingToolAuthorizer` remembers a widget's answer per tool, so a polling
  dashboard asks once, not every two seconds.
- **Live widget limit.** At most 3 widgets stay live (about 100 MB each); older ones become
  snapshots until scrolled back to or clicked, then are re-created from the cache, checked against
  the server (`MCPAppRecreation`): newer compatible version → shown with the stored result; output
  changed shape → a Refresh button; offline → view-only.
- **Streaming.** `session.streamResponse(to:)`: the user's message shows at once, the reply streams
  (`hostTranscript.replyInProgress`). The SDK splits Qwen3's inline `<think>` block into a
  `.reasoning` entry, shown as a collapsed Reasoning section.
- **Date and time.** The current date and time go to the model with every message
  (`session.turnContext`), and the SDK's `ClockTool` is on by default (Settings → Tools), so
  "tomorrow" means tomorrow.
- **Conversations survive relaunch.** What the user saw is saved with `hostTranscript.archive()`.
  With "Remember conversations" on (default), the model's transcript is saved too and the next
  launch continues with it (`makeSession(…, restoring:)`); off, the user still sees the old
  conversation, the model starts fresh, and a divider says so.
- **Tools changing mid-chat.** A session follows `lab.mcp`: a tool turned on, a server added, or a
  trust change reaches the model on its next turn, in the same session. Switching the model (or
  the app's own tools) moves the conversation to a new session, model memory and host transcript
  both carried over.

## Files

| File | |
|---|---|
| `ChatModel.swift` | lab, servers, sessions (new one on a model switch), approvals, save/restore, settings |
| `WidgetSlot.swift` | a call's widget: fetch/cache, re-create, refresh, bridge policy |
| `ChatViews.swift` | conversation, composer, tools badge, approval toggles, settings |
