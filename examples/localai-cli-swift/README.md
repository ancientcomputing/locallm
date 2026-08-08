# localai-cli Swift examples

## Never compiled anything or used Terminal before? Start here.

You don't need Xcode, and you don't need to "compile" anything by hand —
`swift <file>.swift` runs a Swift file directly, the same way you'd run a
Python script. Step by step, for `quickstart_mcp_deepwiki.swift`:

1. **Open Terminal.** It's already on your Mac — press `Cmd+Space`, type
   `Terminal`, hit Return. A window with a text prompt opens.
2. **Check Swift is installed.** Type this and press Return:
   ```bash
   swift --version
   ```
   If you see a version number, you're set. If you see "command not found,"
   install Xcode's Command Line Tools first:
   ```bash
   xcode-select --install
   ```
   A dialog will pop up — click Install, wait for it to finish, then retry
   `swift --version`.
3. **Navigate to this folder.** If you downloaded/cloned this repo to, say,
   your Downloads folder, type (adjusting the path to wherever you put it):
   ```bash
   cd ~/Downloads/localai-playground/examples/localai-cli-swift
   ```
   `cd` means "change directory" — it moves Terminal into that folder so the
   next command can find the script.
4. **Do the one-time MCP setup** in LocalLM Lab described under Setup below
   (connect DeepWiki, enable its `read_wiki_structure` tool) — this is a
   couple of clicks in the app, not in Terminal.
5. **Get the toolkit binaries into this folder.** Download
   `localai-toolkit-<version>-arm64.zip` (see Setup below), double-click it
   to unzip, then drag the two files it contains — `localai-cli` and
   `localai-playground-run` — into this same `localai-cli-swift` folder in
   Finder.
6. **Run it:**
   ```bash
   swift quickstart_mcp_deepwiki.swift
   ```
   The first run may take a few seconds longer than usual — Swift is
   compiling the script in the background before running it, you don't have
   to do anything for that. After that, you should see the model's answer
   printed in Terminal.

If a step fails, the printed message says what to fix (e.g. "localai-cli
not found" means step 5 didn't happen, or the files ended up in the wrong
folder) — see Troubleshooting further down for what each message means.

`quickstart_clock.swift` works exactly the same way, minus step 4 (it needs
no MCP setup, just turning on "System Clock" in Local AI Settings).

---

**Building a real app, not just trying this out?** All three files here are
standalone scripts (`swift <file>.swift`), not Xcode-project code — they use
top-level executable statements, which only compile in a script file like
these, not in a regular `.swift` file inside an app target. What you
actually want to copy into your project is the `runLocalAI(...)` function
defined in `run_localai.swift` — an ordinary throwing function with no
top-level statements, safe to paste into any Swift file. Everything below
`func main()` in `run_localai.swift` (and in the `quickstart_*.swift` files)
is just this repo's own script-runner boilerplate, not something to copy.

**New here? Start with `quickstart_clock.swift`** — zero setup beyond one
toggle in Local AI Settings, no permission dialog, no OAuth, prints a real
answer in one command:

```bash
swift quickstart_clock.swift
```

For an MCP version of the same instant-gratification idea (a real, public
MCP server, zero auth required), see `quickstart_mcp_deepwiki.swift`.

---

Shows the Swift-side equivalent of `examples/localai-cli/run_localai.py`:
spawn `localai-cli` as a subprocess (`Process`/`Pipe`), write a JSON request
to its stdin, read its JSON response from stdout. No LocalLM Lab server, no
HTTP — just the two toolkit binaries.

Kept as a plain top-level Swift script (`swift run_localai.swift`), not a
SwiftPM package, so it's a minimal copy-paste starting point rather than a
project to set up.

## Setup

Same as the Python example (see `examples/localai-cli/README.md`):

1. Run LocalLM Lab at least once and use **Local AI Settings** to enable
   whichever connectors you want to call with, and/or **MCP Servers** to
   connect and enable an MCP server + tool.
2. Download the `localai-toolkit-<version>-arm64.zip` release asset and
   unzip it — it contains `localai-cli` and `localai-playground-run` as a
   matched pair.
3. Put both binaries in this folder (or set `LOCALAI_CLI_PATH`).

## Run

```bash
swift run_localai.swift
```

Requests a built-in connector (`clock` by default). To request an MCP
server tool instead:

```bash
export LOCALAI_MCP_SERVER=https://your-mcp-server.example.com/mcp
export LOCALAI_MCP_TOOL=your_tool_name
swift run_localai.swift --mcp
```

Or override the config/CLI paths the same way as the Python example:

```bash
export LOCALAI_CLI_PATH=/path/to/localai-cli
export LOCALAI_CONFIG_PATH=/path/to/localai-config.json
swift run_localai.swift
```

## What it checks

Sends one `--run` request and prints the model's reply. Both the
`connectors` and `mcp_tools` request fields follow the same
"requested ⊆ enabled" rejection contract `localai-cli` enforces for
Python callers — see `run_localai.swift`'s header comment for the full list
of possible `{"error": "..."}` messages.

## `quickstart_clock.swift` / `quickstart_mcp_deepwiki.swift` — nothing to fill in

`run_localai.swift` above is a template — you're expected to edit
`connectors`/`mcpServer`/`mcpTool` for your own use case. The two
`quickstart_*.swift` scripts instead run as-is: `quickstart_clock.swift`
uses the "clock" connector (the one connector with no macOS permission
dialog at all — see `web/connectors.html`), and
`quickstart_mcp_deepwiki.swift` uses DeepWiki (auth type `None`, "connects
immediately" — see `web/mcp-servers.html`), with the exact server URL,
tool, and prompt from that page already filled in. The only setup either
needs is the one-time toggle/connection in LocalLM Lab described in each
script's own header comment — no OAuth, no API key, no editing.

## `plate_today.swift`

The Swift port of `examples/localai-cli/plate_today.py` — checks Calendar,
Reminders, and Todoist (www.todoist.com) for what's due today and asks the model to summarize
the day:

```bash
swift plate_today.swift
```

Also requests the `clock` connector (`getCurrentTime`) and instructs the
model to look up the real current date first, rather than guessing or
relying on a stale/training notion of "today" — FoundationModels has no live
wall-clock awareness on its own.

Before calling `localai-cli` at all, it reads `localai-config.json` itself
and prints a checklist of all four sources (`clock`/`calendar`/`reminders`
connectors enabled; Todoist server connected, enabled, and its
`find-tasks-by-date` tool enabled) — if anything's missing, it names the
exact panel/toggle to fix and exits without ever invoking the model.

Setup: enable "System Clock", "Calendar", and "Reminders" in Local AI
Settings, and connect Todoist in MCP Servers with `find-tasks-by-date`
enabled (defaults to `https://ai.todoist.net/mcp` — override with
`LOCALAI_MCP_SERVER`/`LOCALAI_MCP_TOOL` if you connected it differently).

## Troubleshooting

- `swift: command not found` — install Xcode's Command Line Tools:
  `xcode-select --install`, then retry.
- `FAIL - localai-cli not found at ...` — the `localai-cli` binary isn't in
  this folder. Either move it here (alongside `localai-playground-run`), or
  set `LOCALAI_CLI_PATH` to wherever it actually is.
- `permission denied` when running `swift <file>.swift` — this shouldn't
  happen (the `swift` command reads and runs the file, it doesn't need the
  file itself to be executable), but if it does, run
  `chmod +x quickstart_mcp_deepwiki.swift` first.
- `{"error": "connector '...' is not enabled in the config"}` — turn it on
  in Local AI Settings.
- `{"error": "MCP server \"...\" is not configured"}` — add the server (URL
  must match exactly) in the MCP Servers panel.
- `{"error": "MCP server \"...\" is not enabled"}` / `"MCP tool \"...\" ...
  is not enabled"` — the server or that specific tool's toggle is off in the
  MCP Servers panel.
- `{"error": "MCP tool \"...\" is not known on server \"...\""}` — tool
  names are case-sensitive and come directly from the server.
- No output, or a connection-style failure that isn't a JSON
  `{"error": ...}` — make sure LocalLM Lab is actually **running** (not
  just installed): these scripts relay through its chooser process, which
  must be up.
- `{"error": "The operation couldn't be completed.
  (FoundationModels.LanguageModelSession.GenerationError error -1.)"}` — a
  generic, occasionally transient on-device generation failure, unrelated
  to your setup. Just retry.
