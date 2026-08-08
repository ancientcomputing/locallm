# localai-cli Python examples

Shows how a 3rd-party app calls `localai-cli` directly — no LocalLM Lab
server, no HTTP, just a subprocess call with JSON on stdin/stdout. This is
the pattern for apps that want to reach the local AI
without running LocalLM Lab's Go server at all.

`localai-cli` is a small wrapper around the local AI helper binary. It reads
a config file (`localai-config.json`, authored by LocalLM Lab's Local AI
Settings screen — see Setup below) that says which "connectors" (tools the
model can call, e.g. a system clock or read-only filesystem access) and
which MCP server tools the user has granted, and takes a `--config` path
pointing at that file plus a per-call request on stdin. Every request
explicitly lists which of those already-granted connectors/tools it wants
active for that one call, via `connectors` and `mcp_tools` fields:

- Anything named in the request must already be enabled in
  `localai-config.json`, or `localai-cli` rejects the request with a JSON
  `{"error": "..."}` before ever invoking the model — it will not silently
  drop it or run without it.
- Anything enabled in the config but *not* named in a given request simply
  isn't given to that call — no error, just a narrower toolset.
- Omitting a field entirely means **nothing from that category is active for
  that call** — this is a deliberate default (least privilege), not an
  oversight. Every tool a call can use must be listed explicitly in that
  call's own request.

## Setup

1. Run LocalLM Lab at least once, keep it running, and use **Local AI
   Settings** to enable whichever connectors you want to call with (e.g.
   System Clock), and/or **MCP Servers** to connect an MCP server. This
   creates `~/Library/Application Support/LocalLM Lab/localai-config.json`.
   `localai-cli` only ever reads this file — it never creates or edits it.
   It also relays connector/MCP calls through LocalLM Lab's chooser process
   over a local socket, so LocalLM Lab needs to be running, not just
   installed.
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
| `quickstart_clock.py` | `clock` connector | Enable "System Clock" in Local AI Settings (no permission dialog) | `python3 quickstart_clock.py` |
| `quickstart_mcp_deepwiki.py` | DeepWiki's `read_wiki_structure` tool, via `--run` | Connect DeepWiki in MCP Servers, auth `None`, enable that one tool | `python3 quickstart_mcp_deepwiki.py` |
| `quickstart_mcp_deepwiki_chat.py` | Same, via `--chat` instead of `--run` | Same as above | `python3 quickstart_mcp_deepwiki_chat.py` |
| `run_localai.py` | Whatever's in `CONNECTORS` (edit the script) | Enable each connector listed in `CONNECTORS` | `python3 run_localai.py` |
| `run_localai_mcp.py` | Whatever's in `MCP_SERVER`/`MCP_TOOL` (edit the script, or set env vars) | Connect and enable that server/tool | `python3 run_localai_mcp.py` |
| `plate_today.py` | `clock`/`calendar`/`reminders` connectors + Todoist's `find-tasks-by-date` MCP tool | Enable "System Clock", "Calendar", and "Reminders" in Local AI Settings; connect Todoist in MCP Servers with that tool enabled | `python3 plate_today.py` |

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
enabled in `localai-config.json` — check the `{"error": "..."}` message
first, it names exactly what's missing.

Override the CLI/config paths with environment variables instead of editing
a script directly:

```bash
export LOCALAI_CLI_PATH=/path/to/localai-cli
export LOCALAI_CONFIG_PATH=/path/to/localai-config.json
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

Before calling `localai-cli` at all, it reads `localai-config.json` itself
and prints a checklist of all four sources (`clock`/`calendar`/`reminders`
connectors enabled; Todoist server connected, enabled, and its
`find-tasks-by-date` tool enabled) — if anything's missing, it names the
exact panel/toggle to fix and exits without ever invoking the model. It also
reads `LOCALAI_MCP_SERVER`/`LOCALAI_MCP_TOOL` if you connected Todoist under
a different URL or want a different tool name (defaults:
`https://ai.todoist.net/mcp` / `find-tasks-by-date`).

## Troubleshooting

- `{"error": "connector '...' is not enabled in the config"}` — turn it on
  in Local AI Settings.
- `{"error": "MCP server \"...\" is not configured"}` — the URL in the
  script doesn't match any server in `localai-config.json`; check it against
  the MCP Servers panel.
- `{"error": "MCP server \"...\" is not enabled"}` / `"MCP tool \"...\" ...
  is not enabled"` — the server or that specific tool's toggle is off.
- `{"error": "MCP tool \"...\" is not known on server \"...\""}` — tool
  names are case-sensitive and come directly from the server; double-check
  spelling.
- No output / connection-style failure, not a JSON `{"error": ...}` — make
  sure LocalLM Lab is actually **running** (not just installed): connector
  and MCP calls relay through its chooser process, which must be up.
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
