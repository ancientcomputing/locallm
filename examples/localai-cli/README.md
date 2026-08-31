# localai-cli Python examples

`localai-cli` is a small command-line binary, shipped in the LocalLM Lab
toolkit, that lets your own code run a prompt through the AI model LocalLM
Lab is set up to use — locally, with no HTTP server involved. You call it as
a subprocess: a JSON request on stdin, the model's reply on stdout.

**Your Python scripts or apps can call `localai-cli` to:**

- send a one-shot prompt (`--run`) or a multi-turn conversation (`--chat`)
  and get the model's answer back;
- have that answer come from tools the user has already granted in LocalLM
  Lab — **connectors** (Calendar, Reminders, Contacts, Location, a system
  clock, read-only filesystem access) and any **MCP server** tools they've
  connected — without your code touching Calendar, Keychain, OAuth, or the
  MCP protocol itself;
- do all of this offline (for the on-device model) and without shipping or
  managing an API key.

### Which model answers

Since 1.0, LocalLM Lab can put four kinds of model behind that one call, and
the user picks which in the **AI Models** screen:

| In the app | What it is |
|---|---|
| **Apple on-device** (`system`, the default) | Runs entirely on the Mac, offline, no setup. |
| **Apple Private Cloud Compute** (`pcc`) | Apple's server-side model, still private; no key needed. |
| **Claude** (`claude`) | Anthropic's Claude, once an API key is set in the app. |
| **A local open-weight model** (`mlx:<hf-repo>`) | Any MLX-format Hugging Face model the user adds via **AI Models → Add model**; downloaded once, then run locally. |

`localai-cli` reads that choice from the config file (below) — there is no
`--model` flag. To change which model your scripts use, change the default
in **AI Models**; the next `localai-cli` call picks it up.

### How connector / MCP access works

`localai-cli` takes a `--config` path pointing at LocalLM Lab's
`app-config.json` (it only ever *reads* this file — the app writes it), plus
the per-call request on stdin. The config lists every connector and MCP tool
the user has granted; each request then names which of those it wants active
for that one call, via `connectors` and `mcp_tools` fields:

- Anything named in the request must already be enabled in `app-config.json`,
  or `localai-cli` rejects the request with a JSON `{"error": "..."}` before
  ever invoking the model — it will not silently drop it or run without it.
- Anything enabled in the config but *not* named in a given request simply
  isn't given to that call — no error, just a narrower toolset.
- Omitting a field entirely means **nothing from that category is active for
  that call** — a deliberate least-privilege default, not an oversight. Every
  tool a call can use must be listed explicitly in that call's own request.

## Setup

1. Run LocalLM Lab at least once and keep it running. Use the **Connectors**
   screen to enable whichever connectors you want to call with (e.g. System
   Clock), the **MCP Servers** screen to connect an MCP server, and the
   **AI Models** screen if you want something other than the default
   on-device model. These write
   `~/Library/Application Support/LocalLM Lab/app-config.json` —
   `localai-cli` only ever reads this file, never creates or edits it.
   Connector and MCP calls also run inside LocalLM Lab's own process (reached
   over a local socket), so the app must be **running**, not just installed.
2. Get the `localai-toolkit-<version>-arm64.zip` from
   [`../../toolkit/`](../../toolkit/) (it's checked into the repo — see that
   folder's README) and unzip it — `localai-cli` and `localai-playground-run`
   are a matched pair.
3. Put both binaries in this folder (or point `LOCALAI_CLI_PATH` at wherever
   you put `localai-cli` — it looks for `localai-playground-run` in the same
   directory as itself by default).

All commands below use `python3` — plain `python` isn't guaranteed to exist
on current macOS.

## The example scripts

These scripts aren't a product. Each one is a **worked example of one way to use
`localai-cli`**, written to be read and copied into your own code — together they cover the
request shapes, the connector and MCP fields, and the least-privilege validation.

### Start here — copy-paste, one toggle each

- **`quickstart_clock.py`** — the smallest possible demo. Sends one `--run` prompt ("what time
  is it?") using the `clock` connector, the only connector with no macOS permission dialog.
  **Shows** the whole round trip — spawn the binary, JSON in on stdin, JSON out on stdout — with
  nothing to configure.
  *Setup:* enable **System Clock** in **Connectors**. *Run:* `python3 quickstart_clock.py`
- **`quickstart_mcp_deepwiki.py`** — the same round trip, but the tool is an **MCP server tool**
  (`read_wiki_structure`, from DeepWiki) instead of a built-in connector. **Shows** the
  `mcp_tools` request field, and that MCP tools are requested and validated exactly like
  connectors. DeepWiki needs no auth.
  *Setup:* in **MCP Servers**, add `https://mcp.deepwiki.com/mcp` (auth None), enable that one
  tool. *Run:* `python3 quickstart_mcp_deepwiki.py`
- **`quickstart_mcp_deepwiki_chat.py`** — identical to the one above except it uses **`--chat`**
  (a `messages` list) instead of **`--run`** (`system_prompt` + `user_input`). **Shows** the two
  request shapes side by side — mixing them up is the most common cause of the generic-looking
  "The data couldn't be read because it is missing." error.
  *Setup:* same as above. *Run:* `python3 quickstart_mcp_deepwiki_chat.py`

### Templates to adapt

- **`run_localai.py`** — the general connector pattern with the connector list and prompt lifted
  into constants at the top. **Shows** how you'd wire `localai-cli` into a real app, and what a
  rejection looks like when a request names a connector that isn't enabled (a JSON `{"error":
  …}`, before the model ever runs). Defaults to the `clock` setup, so it works unchanged.
  *Setup:* enable each connector in `CONNECTORS`. *Run:* `python3 run_localai.py`
- **`run_localai_mcp.py`** — the same, for MCP tools: `MCP_SERVER` / `MCP_TOOL` constants (also
  read from `LOCALAI_MCP_SERVER` / `LOCALAI_MCP_TOOL`). **Shows** the `mcp_tools` entry shape
  (`{"server": …, "tool": …}`) and its "must already be connected *and* enabled" validation.
  *Setup:* connect + enable that server/tool. *Run:* `python3 run_localai_mcp.py`

### A fuller example

- **`plate_today.py`** — a `localai-cli` port of the [`plate-today`](../plate-today/) SDK
  reference app: it pulls in Calendar, Reminders, and Todoist and asks the model to summarize
  your day. **Shows** several connectors plus an MCP tool in one request; the pattern of reading
  `app-config.json` yourself first, to hand the user a precise "enable X" checklist before
  spending a model call; and why you pass the `clock` connector for anything date-sensitive —
  the on-device model has no idea what today's date is. It reads `LOCALAI_MCP_SERVER` /
  `LOCALAI_MCP_TOOL` too, if your Todoist server URL or tool name differ from the defaults
  (`https://ai.todoist.net/mcp` / `find-tasks-by-date`).
  *Setup:* enable **System Clock**, **Calendar**, **Reminders** in **Connectors**; connect
  **Todoist** in **MCP Servers** with `find-tasks-by-date` enabled. *Run:* `python3 plate_today.py`

### Overriding paths without editing a script

Every script reads these:

```bash
export LOCALAI_CLI_PATH=/path/to/localai-cli
export LOCALAI_CONFIG_PATH=/path/to/app-config.json
python3 run_localai.py
```

`run_localai_mcp.py` and `plate_today.py` also read the MCP server/tool from the environment:

```bash
export LOCALAI_MCP_SERVER=https://your-mcp-server.example.com/mcp
export LOCALAI_MCP_TOOL=your_tool_name
python3 run_localai_mcp.py
```

## Troubleshooting

- `{"error": "connector '...' is not enabled in the config"}` — turn it on
  in the Connectors screen.
- `{"error": "MCP server \"...\" is not configured"}` — the URL in the
  script doesn't match any server in `app-config.json`; check it against
  the MCP Servers panel.
- `{"error": "MCP server \"...\" is not enabled"}` / `"MCP tool \"...\" ...
  is not enabled"` — the server or that specific tool's toggle is off.
- `{"error": "MCP tool \"...\" is not known on server \"...\""}` — tool
  names are case-sensitive and come directly from the server; double-check
  spelling.
- No output / connection-style failure, not a JSON `{"error": ...}` — make
  sure LocalLM Lab is actually **running** (not just installed): connector
  and MCP calls run inside the app's own process, which must be up.
- `{"error": "The operation couldn't be completed.
  (FoundationModels.LanguageModelSession.GenerationError error -1.)"}` — a
  generic on-device generation failure from FoundationModels itself, not a
  config/connector rejection (the request already passed validation by the
  time this happens), and not tied to any particular prompt — confirmed by
  re-running the exact same request and getting a normal reply. Treat it as
  transient: just retry.
- A reply that doesn't look like it used any tool at all — check whether
  your prompt actually needs the connector/tool you requested. A prompt like
  "Say hello in exactly five words" has no reason to call the `clock`
  connector even if it's enabled and requested; that's expected, not a bug.
- `{"error": "The data couldn't be read because it is missing."}` — a
  request-shape mismatch, not an MCP/config problem: `--run` wants
  `system_prompt`/`user_input`, `--chat` wants a `messages` list instead
  (no `system_prompt`/`user_input` at all). Sending a `--run`-shaped request
  to `--chat` (e.g. by hand-editing `quickstart_mcp_deepwiki.py` to use
  `--chat`) produces exactly this error. Use `quickstart_mcp_deepwiki_chat.py`
  for a working `--chat` example instead.
