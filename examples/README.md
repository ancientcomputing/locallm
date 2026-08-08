# LocalLM Lab — API Example Scripts

These scripts test a running LocalLM Lab **API** endpoint using the official
`openai` Python SDK. They're meant for two audiences:

- **End users** who just enabled the API feature and want to confirm it's
  actually working, especially if they're new to working with an
  OpenAI-style API.
- **LocalLM Lab developers / Claude Code**, as a lightweight conformance
  check that the local server genuinely behaves like the OpenAI API it's
  imitating — run these after any server-side change.

## Setup

1. In LocalLM Lab, open **API Settings** and turn the server **On**.
2. Copy the **Base URL** and **Token** shown there.
3. Install the OpenAI SDK if you don't have it: `pip install openai`
4. Either set environment variables before running any script:

   ```bash
   export LOCALLM_BASE_URL="http://localhost:1234/v1"
   export LOCALLM_TOKEN="sk-locallm-xxxxxxxxxxxx"
   ```

   ...or edit the `CONFIG` block at the top of each script directly.

## Scripts

| Script | What it checks |
|---|---|
| `test_connection.py` | Most basic smoke test — one chat completion, confirms auth + connectivity work |
| `test_streaming.py` | Streaming (SSE) responses work end-to-end |
| `test_models_list.py` | `/v1/models` responds with the expected model entry |
| `test_error_handling.py` | A bad token correctly produces a 401 + OpenAI-style error, not a crash |
| `test_conformance.py` | Runs all of the above checks together and prints a pass/fail summary |

Run any script directly:

```bash
python test_connection.py
```

Each script prints what it **expects** to happen before running, so if
something fails, it's clear whether the problem is your setup (server off,
wrong port, stale token) or something worth reporting.

If a script can't connect at all, double check:
- The API server is toggled **On** in LocalLM Lab
- The port in `CONFIG`/env vars matches what's shown in API Settings
  (remember: on localhost, LocalLM Lab may auto-pick a different port if
  your configured one was busy — always check the Settings screen for the
  actual port in use)
- The token hasn't been regenerated since you copied it

## `localai-cli` (no server required)

The scripts above all go through LocalLM Lab's Go server/API. If you'd rather
call the local AI directly from a 3rd-party app — no server, no HTTP, just a
subprocess — see [`localai-cli/`](localai-cli/), which shows the pattern
using `localai-cli` + `localai-playground-run` from Python (including a
sample that requests an MCP server tool), and
[`localai-cli-swift/`](localai-cli-swift/) for the same pattern from Swift.

**Fastest way to see it work**: `quickstart_clock.py` / `quickstart_clock.swift`
in those two folders run with zero setup beyond one toggle in Local AI
Settings — no permission dialog, no OAuth, no editing. Their MCP
counterparts, `quickstart_mcp_deepwiki.py` / `quickstart_mcp_deepwiki.swift`,
do the same against a real public MCP server (DeepWiki, auth type `None`) —
the exact server/tool/prompt from [`web/mcp-servers.html`](../web/mcp-servers.html)
already filled in, so the only setup is connecting that one server in
LocalLM Lab's MCP Servers panel.
