"""
plate_today.py — "what's on my plate today", via localai-cli

WHAT THIS SCRIPT DOES
    A localai-cli port of the SDK's examples/plate-today reference app:
    checks Calendar, Reminders, and Todoist for what's due
    today and asks the on-device model to summarize the day. Unlike the SDK
    version, this is a plain script — no Swift app, no EventKit calls of its
    own, no TCC prompts triggered by this process. It relies entirely on
    connectors/MCP tools LocalLM Lab already has permission for:
        - Calendar and Reminders come in as the "calendar"/"reminders"
          connectors (same as run_localai.py's "clock", just two more
          built-ins — see the Connectors screen).
        - Todoist comes in as an MCP tool call (same pattern as
          run_localai_mcp.py) against Todoist's hosted MCP server,
          find-tasks-by-date.

    The model has no reliable notion of "today" on its own (FoundationModels
    has no live wall-clock awareness), so this also requests the "clock"
    connector (getCurrentTime) and instructs the model to look up the actual
    current date first, then match "today" against calendar/reminders/
    Todoist using that date — rather than guessing or using a stale/training
    notion of "today".

    Before ever calling localai-cli, this script reads app-config.json
    itself and checks all four sources are actually usable: the three
    connectors enabled, and the Todoist server connected + enabled with
    find-tasks-by-date enabled on it. This is a deliberate preflight, not
    something localai-cli does for you — localai-cli validates one --run
    request's fields against the config, but only reports the *first*
    problem it hits, and won't tell you "connected but not enabled" apart
    from "not connected at all". Checking all four up front means one
    request tells you a full checklist of anything still missing, before
    burning a model call that was always going to fail.

REQUIREMENTS
    - Everything run_localai_mcp.py requires: localai-cli +
      localai-playground-run next to this script (or LOCALAI_CLI_PATH set),
      LocalLM Lab running (connector/MCP calls relay through its chooser
      process over a local socket).
    - In LocalLM Lab's Connectors screen: "System Clock", "Calendar", and
      "Reminders" connectors enabled (Calendar/Reminders each prompt for
      their own TCC grant the first time; System Clock has no permission
      dialog).
    - In LocalLM Lab's MCP Servers panel: Todoist added and connected
      (https://ai.todoist.net/mcp by default — override with
      LOCALAI_MCP_SERVER), with the find-tasks-by-date tool's checkbox on
      (override the tool name with LOCALAI_MCP_TOOL).

EXPECTED BEHAVIOR (if everything is working)
    - Prints the resolved localai-cli/config paths.
    - Prints a checklist confirming all three sources are ready.
    - Prints the model's summary of the day.
    - Ends with "PASS — plate_today run succeeded."

WHAT FAILURE LOOKS LIKE
    - "localai-cli not found at ..." — same fix as run_localai.py.
    - {"error": "config file not found: ..."} at the very first check — no
      app-config.json exists yet; run LocalLM Lab at least once and open
      the Connectors and MCP Servers screens so it gets created.
    - A preflight checklist with one or more "MISSING" lines and no model
      call at all — this is the expected, helpful-message path when
      something isn't set up yet. Each line names the exact panel/toggle to
      fix. The script exits(1) without ever invoking localai-cli in this
      case, so nothing about the failure comes from the model or localai-cli
      itself.
    - Everything else — a connector/MCP rejection from localai-cli itself, a
      transient FoundationModels generation error, etc. — behaves the same
      as run_localai_mcp.py; see that script's docstring.
"""

import json
import os
import subprocess
import sys

# --- CONFIG: edit these, or set the equivalent environment variables ---
LOCALAI_CLI_PATH = os.environ.get(
    "LOCALAI_CLI_PATH", os.path.join(os.path.dirname(__file__), "localai-cli")
)
LOCALAI_CONFIG_PATH = os.environ.get(
    "LOCALAI_CONFIG_PATH",
    os.path.expanduser("~/Library/Application Support/LocalLM Lab/app-config.json"),
)
# Same default Todoist hosted MCP server + tool the SDK's Plate Today example
# uses. Override if you connected Todoist at a different URL, or want a
# different tool (both need to match what's in app-config.json's
# "mcp_servers" array exactly — see MCP Servers in LocalLM Lab).
TODOIST_MCP_URL = os.environ.get("LOCALAI_MCP_SERVER", "https://ai.todoist.net/mcp")
TODOIST_MCP_TOOL = os.environ.get("LOCALAI_MCP_TOOL", "find-tasks-by-date")
# ------------------------------------------------------------------------

# Panel labels for the message printed when a connector isn't enabled —
# "clock" shows up in the Connectors screen as "System Clock", not "Clock".
CONNECTOR_LABELS = {"clock": "System Clock", "calendar": "Calendar", "reminders": "Reminders"}
REQUIRED_CONNECTORS = ["clock", "calendar", "reminders"]


def load_config(path: str) -> dict:
    if not os.path.isfile(path):
        raise RuntimeError(
            f"config file not found: {path}\n"
            "Run LocalLM Lab at least once and open the Connectors and MCP Servers screens "
            "Servers so it gets created."
        )
    with open(path, "r") as f:
        return json.load(f)


def preflight(config: dict) -> list:
    """Check the clock, Calendar, Reminders, and Todoist are all usable.

    Returns a list of (source, ok, detail) tuples, one per source checked —
    used both to print a full checklist and to decide whether to proceed.
    """
    results = []

    enabled_connectors = set(config.get("connectors_enabled", []))
    for connector in REQUIRED_CONNECTORS:
        if connector in enabled_connectors:
            results.append((connector, True, "enabled"))
        else:
            results.append((
                connector, False,
                f'not enabled — turn on "{CONNECTOR_LABELS[connector]}" in the Connectors screen',
            ))

    server = next(
        (s for s in config.get("mcp_servers", []) if s.get("url") == TODOIST_MCP_URL),
        None,
    )
    if server is None:
        results.append((
            "todoist", False,
            f"not configured — add {TODOIST_MCP_URL} in MCP Servers",
        ))
    elif not server.get("enabled", False):
        results.append((
            "todoist", False,
            "server added but disabled — enable it in MCP Servers",
        ))
    elif server.get("connection_status") != "connected":
        status = server.get("connection_status", "unknown")
        results.append((
            "todoist", False,
            f'not connected (status: "{status}") — click Reconnect in MCP Servers',
        ))
    else:
        tool = next(
            (t for t in server.get("tools", []) if t.get("name") == TODOIST_MCP_TOOL),
            None,
        )
        if tool is None:
            available = ", ".join(t.get("name", "") for t in server.get("tools", []))
            results.append((
                "todoist", False,
                f'tool "{TODOIST_MCP_TOOL}" not found on server (available: {available})',
            ))
        elif not tool.get("enabled", False):
            results.append((
                "todoist", False,
                f'tool "{TODOIST_MCP_TOOL}" is disabled — enable its checkbox in MCP Servers',
            ))
        else:
            results.append(("todoist", True, f'connected, "{TODOIST_MCP_TOOL}" enabled'))

    return results


def run_localai_plate_today() -> dict:
    """Invoke localai-cli --run with calendar/reminders/Todoist, return its parsed JSON response."""
    if not os.path.isfile(LOCALAI_CLI_PATH):
        raise RuntimeError(
            f"localai-cli not found at {LOCALAI_CLI_PATH} — set LOCALAI_CLI_PATH "
            "or place the binary next to this script."
        )

    request = {
        "system_prompt": (
            "You are a friendly, concise personal assistant. Always start by "
            "calling getCurrentTime to find out today's actual date — never "
            "assume or guess it. Then use the available tools to check the "
            "user's calendar, reminders, and Todoist tasks for that date, and "
            "summarize their day."
        ),
        "user_input": (
            "What's on my plate today? First check the current date with your "
            "clock tool, then check my calendar events, my reminders due "
            "today, and my Todoist tasks due today (exclude overdue tasks — "
            "only today's, matched against the date you just looked up), then "
            "give me a friendly, concise summary of my day."
        ),
        "connectors": REQUIRED_CONNECTORS,
        "mcp_tools": [{"server": TODOIST_MCP_URL, "tool": TODOIST_MCP_TOOL}],
    }

    result = subprocess.run(
        [LOCALAI_CLI_PATH, "--config", LOCALAI_CONFIG_PATH, "--run"],
        input=json.dumps(request),
        capture_output=True,
        text=True,
    )

    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        raise RuntimeError(
            f"localai-cli produced no parseable JSON (exit {result.returncode}).\n"
            f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}"
        )


def main():
    print(f"localai-cli path : {LOCALAI_CLI_PATH}")
    print(f"config path      : {LOCALAI_CONFIG_PATH}")
    print(f"todoist server   : {TODOIST_MCP_URL}")
    print(f"todoist tool     : {TODOIST_MCP_TOOL}\n")

    try:
        config = load_config(LOCALAI_CONFIG_PATH)
    except RuntimeError as e:
        print(f"FAIL — {e}")
        sys.exit(1)

    print("Checking sources are set up in LocalLM Lab...")
    checks = preflight(config)
    for source, ok, detail in checks:
        status = "OK     " if ok else "MISSING"
        print(f"  [{status}] {source}: {detail}")
    print()

    missing = [source for source, ok, _ in checks if not ok]
    if missing:
        print(
            "FAIL — not all sources are set up yet. Fix the MISSING item(s) "
            "above in LocalLM Lab, then run this again."
        )
        sys.exit(1)

    print("All sources ready. Asking the model to summarize your day...\n")

    try:
        response = run_localai_plate_today()
    except RuntimeError as e:
        print(f"FAIL — {e}")
        sys.exit(1)

    if response.get("error"):
        print("FAIL — localai-cli rejected the request or the model errored:")
        print(f"  {response['error']}")
        sys.exit(1)

    print("What's on your plate today:")
    print(f"  {response.get('answer', '')}\n")
    print("PASS — plate_today run succeeded.")


if __name__ == "__main__":
    main()
