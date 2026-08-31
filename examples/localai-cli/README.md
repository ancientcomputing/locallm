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
2. Download the `localai-toolkit-<version>-arm64.zip` release asset and
   unzip it — it contains `localai-cli` and `localai-playground-run` as a
   matched pair.
3. Put both binaries in this folder (or point `LOCALAI_CLI_PATH` at wherever
   you put `localai-cli` — it looks for `localai-playground-run` in the same
   directory as itself by default).

All commands below use `python3` — plain `python` isn't guaranteed to exist
on current macOS.

## Scripts

| Script | Requests | Setup needed before running | Run |
|---|---|---|---|
| `quickstart_clock.py` | `clock` connector | Enable "System Clock" in the Connectors screen (no permission dialog) | `python3 quickstart_clock.py` |
| `quickstart_mcp_deepwiki.py` | DeepWiki's `read_wiki_structure` tool, via `--run` | Connect DeepWiki in MCP Servers, auth `None`, enable that one tool | `python3 quickstart_mcp_deepwiki.py` |
| `quickstart_mcp_deepwiki_chat.py` | Same, via `--chat` instead of `--run` | Same as above | `python3 quickstart_mcp_deepwiki_chat.py` |
| `run_localai.py` | Whatever's in `CONNECTORS` (edit the script) | Enable each connector listed in `CONNECTORS` | `python3 run_localai.py` |
| `run_localai_mcp.py` | Whatever's in `MCP_SERVER`/`MCP_TOOL` (edit the script, or set env vars) | Connect and enable that server/tool | `python3 run_localai_mcp.py` |
| `plate_today.py` | `clock`/`calendar`/`reminders` connectors + Todoist's `find-tasks-by-date` MCP tool | Enable "System Clock", "Calendar", and "Reminders" in the Connectors screen; connect Todoist in MCP Servers with that tool enabled | `python3 plate_today.py` |

The `quickstart_*` scripts run as-is — every value is already filled in with
something guaranteed to work with no setup beyond one toggle/connection (see
`web/connectors.html` and `web/mcp-servers.html` for why those two were
picked: `clock` is the only connector with no macOS permission dialog, and
DeepWiki is the only MCP server here with no OAuth). **Start with those if
you just want to see it work.**

`run_localai.py` and `run_localai_mcp.py` are templates: they default to
requesting the same `clock`/DeepWiki setup, but the whole point is editing
`CONNECTORS`, `MCP_SERVER`, `MCP_TOOL`, or the prompt itself for your own use
case, so failures there usually mean *your* edit doesn't match what's
enabled in `app-config.json` — check the `{"error": "..."}` message
first, it names exactly what's missing.

Override the CLI/config paths with environment variables instead of editing
a script directly:

```bash
export LOCALAI_CLI_PATH=/path/to/localai-cli
export LOCALAI_CONFIG_PATH=/path/to/app-config.json
python3 run_localai.py
```

`run_localai_mcp.py` additionally reads `LOCALAI_MCP_SERVER`/`LOCALAI_MCP_TOOL`:

```bash
export LOCALAI_MCP_SERVER=https://your-mcp-server.example.com/mcp
export LOCALAI_MCP_TOOL=your_tool_name
python3 run_localai_mcp.py
```

### `plate_today.py`

Checks Calendar, Reminders and Todoist (www.todoist.com) for what's due today and asks the model to summarize the day.

It also requests the `clock` connector (`getCurrentTime`) and instructs the
model to look up the real current date first, rather than guessing or
relying on a stale/training notion of "today" — FoundationModels has no live
wall-clock awareness on its own, so without this the model can (and did)
get today's date wrong when matching it against calendar/reminders/Todoist.

Before calling `localai-cli` at all, it reads `app-config.json` itself
and prints a checklist of all four sources (`clock`/`calendar`/`reminders`
connectors enabled; Todoist server connected, enabled, and its
`find-tasks-by-date` tool enabled) — if anything's missing, it names the
exact panel/toggle to fix and exits without ever invoking the model. It also
reads `LOCALAI_MCP_SERVER`/`LOCALAI_MCP_TOOL` if you connected Todoist under
a different URL or want a different tool name (defaults:
`https://ai.todoist.net/mcp` / `find-tasks-by-date`).

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
