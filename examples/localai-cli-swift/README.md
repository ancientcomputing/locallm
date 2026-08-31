# localai-cli Swift examples

The Swift counterpart of [`examples/localai-cli/`](../localai-cli/) — the same
ideas, called from Swift instead of Python.

`localai-cli` is a small command-line binary, shipped in the LocalLM Lab
toolkit, that lets your own code run a prompt through the AI model LocalLM
Lab is set up to use — locally, with no HTTP server involved. You spawn it
as a subprocess (`Process` / `Pipe`): a JSON request on stdin, the model's
reply on stdout.

**Your Swift app can call `localai-cli` to:**

- send a one-shot prompt (`--run`) or a multi-turn conversation (`--chat`)
  and get the model's answer back;
- have that answer come from tools the user has already granted in LocalLM
  Lab — **connectors** (Calendar, Reminders, Contacts, Location, a system
  clock, read-only filesystem access) and any **MCP server** tools they've
  connected — without your code touching Calendar, Keychain, OAuth, or the
  MCP protocol itself;
- do all of this offline (for the on-device model) and without shipping or
  managing an API key.

This is the *quick* way to reach the local model. If you're building a
native macOS app and want the model layer, connectors, and MCP client linked
directly into your binary, use the **LocalLM Lab SDK** instead (see
[`examples/plate-today`](../plate-today/) and the others).

### Which model answers

Since 1.0, LocalLM Lab can put four kinds of model behind that one call, and
the user picks which in the **AI Models** screen:

| In the app | What it is |
|---|---|
| **Apple on-device** (`system`, the default) | Runs entirely on the Mac, offline, no setup. |
| **Apple Private Cloud Compute** (`pcc`) | Apple's server-side model, still private; no key needed. |
| **Claude** (`claude`) | Anthropic's Claude, once an API key is set in the app. |
| **A local open-weight model** (`mlx:<hf-repo>`) | Any MLX-format Hugging Face model the user adds via **AI Models → Add model**; downloaded once, then run locally. |

`localai-cli` reads that choice from `app-config.json` — there is no
`--model` flag. To change which model your scripts use, change the default
in **AI Models**.

### How connector / MCP access works

`localai-cli` takes a `--config` path pointing at LocalLM Lab's
`app-config.json` (it only ever *reads* this file — the app writes it), plus
the per-call request on stdin. The config lists every connector and MCP tool
the user has granted; each request then names which of those it wants active
for that one call, via `connectors` and `mcp_tools` fields:

- Anything named in the request must already be enabled in `app-config.json`,
  or `localai-cli` rejects the request with a JSON `{"error": "..."}` before
  ever invoking the model.
- Anything enabled but *not* named in a request simply isn't given to that
  call — no error, just a narrower toolset.
- Omitting a field entirely means **nothing from that category is active** —
  a deliberate least-privilege default. Every tool a call can use must be
  listed explicitly in that call's own request.

## The example scripts

These aren't a product. Each `.swift` file is a **worked example of one way
to use `localai-cli`**, meant to be read and copied. They're plain top-level
scripts (`swift <file>.swift`) — see *Copying it into a real app* below for
what actually goes into your project.

- **`quickstart_clock.swift`** — the smallest possible demo. Sends one
  `--run` prompt ("what time is it?") using the `clock` connector, the only
  connector with no macOS permission dialog. **Shows** the whole round trip —
  spawn the binary with `Process`/`Pipe`, JSON in, JSON out — with nothing to
  configure.
  *Setup:* enable **System Clock** in **Connectors**. *Run:* `swift quickstart_clock.swift`
- **`quickstart_mcp_deepwiki.swift`** — the same round trip, but the tool is
  an **MCP server tool** (`read_wiki_structure`, from DeepWiki) instead of a
  built-in connector. **Shows** the `mcp_tools` request field, and that MCP
  tools are requested and validated exactly like connectors. DeepWiki needs
  no auth.
  *Setup:* in **MCP Servers**, add `https://mcp.deepwiki.com/mcp` (auth None),
  enable that one tool. *Run:* `swift quickstart_mcp_deepwiki.swift`
- **`run_localai.swift`** — the general pattern with the prompt, connector,
  and MCP server/tool lifted into variables at the top. **Shows** how you'd
  wire `localai-cli` into a real app (the reusable `runLocalAI(...)`
  function), and what a rejection looks like when a request names something
  that isn't enabled. Defaults to the `clock` connector; pass `--mcp` (with
  `LOCALAI_MCP_SERVER` / `LOCALAI_MCP_TOOL` set) to request an MCP tool
  instead.
  *Setup:* enable the connector(s) you request. *Run:* `swift run_localai.swift`
- **`plate_today.swift`** — a port of the Python
  [`plate_today.py`](../localai-cli/plate_today.py), itself a port of the
  [`plate-today`](../plate-today/) SDK app: pulls in Calendar, Reminders, and
  Todoist and asks the model to summarize your day. **Shows** several
  connectors plus an MCP tool in one request; reading `app-config.json`
  yourself first to give the user a precise "enable X" checklist before
  spending a model call; and why you pass the `clock` connector for anything
  date-sensitive — the on-device model has no idea what today's date is.
  *Setup:* enable **System Clock**, **Calendar**, **Reminders** in
  **Connectors**; connect **Todoist** in **MCP Servers** with
  `find-tasks-by-date` enabled (override the URL/tool with
  `LOCALAI_MCP_SERVER` / `LOCALAI_MCP_TOOL`).
  *Run:* `swift plate_today.swift`

## Never used Terminal before? Start here

You don't need Xcode, and you don't "compile" anything by hand —
`swift <file>.swift` runs a Swift file directly, like a Python script. Step
by step, for `quickstart_clock.swift`:

1. **Open Terminal** — `Cmd+Space`, type `Terminal`, Return.
2. **Check Swift is installed:**
   ```bash
   swift --version
   ```
   If you see "command not found," run `xcode-select --install`, click
   Install in the dialog, wait, then retry.
3. **Go to this folder** (adjust the path to wherever you cloned the repo):
   ```bash
   cd ~/Downloads/localai-playground/examples/localai-cli-swift
   ```
4. **One-time app setup:** run LocalLM Lab, open **Connectors**, turn on
   **System Clock** (no permission prompt for this one).
5. **Get the toolkit binaries into this folder:** download
   `localai-toolkit-<version>-arm64.zip` (see Setup), double-click to unzip,
   drag `localai-cli` and `localai-playground-run` into this folder.
6. **Run it:**
   ```bash
   swift quickstart_clock.swift
   ```
   The first run takes a few seconds longer — Swift compiles the script
   first. Then you should see the model's answer.

If a step fails, the printed message says what to fix — see Troubleshooting.

## Copying it into a real app

All the files here are standalone scripts, not Xcode-project code — they use
top-level executable statements, which only compile in a script file, not in
a `.swift` file inside an app target. What you copy into your project is the
**`runLocalAI(...)` function** in `run_localai.swift` — an ordinary throwing
function with no top-level statements. Everything below `func main()` in each
file is this repo's script-runner boilerplate, not something to copy.

## Setup

1. Run LocalLM Lab at least once and keep it running. Use **Connectors** to
   enable the connectors you want, **MCP Servers** to connect a server, and
   **AI Models** to pick a non-default model. These write
   `~/Library/Application Support/LocalLM Lab/app-config.json` — `localai-cli`
   only reads it. Connector and MCP calls run inside LocalLM Lab's own
   process, so the app must be **running**, not just installed.
2. Get the `localai-toolkit-<version>-arm64.zip` from
   [`../../toolkit/`](../../toolkit/) (checked into the repo — see that folder's
   README) and unzip it — `localai-cli` and `localai-playground-run` are a
   matched pair.
3. Put both binaries in this folder (or set `LOCALAI_CLI_PATH`).

## Run

```bash
swift run_localai.swift                 # requests the `clock` connector
swift run_localai.swift --mcp           # requests an MCP tool (set the env vars first)
```

Override paths / MCP target without editing the script:

```bash
export LOCALAI_CLI_PATH=/path/to/localai-cli
export LOCALAI_CONFIG_PATH=/path/to/app-config.json
export LOCALAI_MCP_SERVER=https://your-mcp-server.example.com/mcp
export LOCALAI_MCP_TOOL=your_tool_name
swift run_localai.swift --mcp
```

## Troubleshooting

- `swift: command not found` — install Xcode's Command Line Tools:
  `xcode-select --install`, then retry.
- `FAIL - localai-cli not found at ...` — the binary isn't in this folder.
  Move it here (next to `localai-playground-run`) or set `LOCALAI_CLI_PATH`.
- `{"error": "connector '...' is not enabled in the config"}` — turn it on in
  the **Connectors** screen.
- `{"error": "MCP server \"...\" is not configured"}` — add the server (URL
  must match exactly) in the **MCP Servers** screen.
- `{"error": "MCP server \"...\" is not enabled"}` / `"MCP tool \"...\" ... is
  not enabled"` — the server or that tool's toggle is off in **MCP Servers**.
- `{"error": "MCP tool \"...\" is not known on server \"...\""}` — tool names
  are case-sensitive and come straight from the server.
- No output, or a connection-style failure that isn't a JSON `{"error": ...}`
  — make sure LocalLM Lab is actually **running** (not just installed):
  connector and MCP calls execute inside it.
- `{"error": "The operation couldn't be completed.
  (FoundationModels.LanguageModelSession.GenerationError error -1.)"}` — a
  generic, occasionally transient on-device generation failure, unrelated to
  your setup. Just retry.
