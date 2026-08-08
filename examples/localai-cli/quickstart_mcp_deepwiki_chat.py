"""
quickstart_mcp_deepwiki_chat.py — the fastest possible MCP demo, --chat mode

WHAT THIS SCRIPT DOES
    Same idea as quickstart_mcp_deepwiki.py, but exercises localai-cli's
    --chat mode instead of --run. --chat and --run take DIFFERENT request
    shapes: --run wants "system_prompt" + "user_input", --chat wants a
    "messages" list of {"role": ..., "content": ...} objects instead (no
    "system_prompt"/"user_input" fields at all). Sending a --run-shaped
    request to --chat (or vice versa) fails with a generic-looking
    "The data couldn't be read because it is missing." error — that's Swift's
    JSONDecoder complaining about a missing required field (here, the
    missing "messages"), not an MCP or model problem.

    Everything else works exactly like quickstart_mcp_deepwiki.py: real
    server/tool/prompt from web/mcp-servers.html's DeepWiki section, nothing
    to fill in.

SETUP (about a minute)
    1. Run LocalLM Lab, open the MCP Servers panel (menu bar tray icon).
    2. Add Server → URL: https://mcp.deepwiki.com/mcp, display name:
       "DeepWiki", auth type: None. Click Add — no sign-in required.
    3. In the DeepWiki entry, enable the "read_wiki_structure" tool (every
       newly connected server starts with all tools off, by design).
    4. Download localai-toolkit-<version>-arm64.zip, unzip it, and place
       localai-cli + localai-playground-run next to this script (or set
       LOCALAI_CLI_PATH).

RUN
    python3 quickstart_mcp_deepwiki_chat.py

EXPECTED OUTPUT
    The model's answer listing documentation topics for a real public GitHub
    repo (nickclyde/duckduckgo-mcp-server) — proof the MCP tool call actually
    reached DeepWiki's server and came back, via --chat mode this time.
"""

import json
import os
import subprocess
import sys

LOCALAI_CLI_PATH = os.environ.get(
    "LOCALAI_CLI_PATH", os.path.join(os.path.dirname(__file__), "localai-cli")
)
LOCALAI_CONFIG_PATH = os.environ.get(
    "LOCALAI_CONFIG_PATH",
    os.path.expanduser("~/Library/Application Support/LocalLM Lab/localai-config.json"),
)

# Exactly the server URL, tool, and example prompt from web/mcp-servers.html's
# DeepWiki section — nothing to fill in yourself.
MCP_SERVER = "https://mcp.deepwiki.com/mcp"
MCP_TOOL = "read_wiki_structure"
USER_INPUT = "What documentation topics are available for the GitHub repo nickclyde/duckduckgo-mcp-server?"


def main():
    if not os.path.isfile(LOCALAI_CLI_PATH):
        print(f"FAIL — localai-cli not found at {LOCALAI_CLI_PATH}")
        print("Set LOCALAI_CLI_PATH, or place the toolkit binaries next to this script.")
        sys.exit(1)

    # --chat's request shape: "messages", not "system_prompt"/"user_input".
    request = {
        "messages": [
            {"role": "system", "content": "You are a concise assistant. Use the available tool to answer."},
            {"role": "user", "content": USER_INPUT},
        ],
        "mcp_tools": [{"server": MCP_SERVER, "tool": MCP_TOOL}],
    }

    result = subprocess.run(
        [LOCALAI_CLI_PATH, "--config", LOCALAI_CONFIG_PATH, "--chat"],
        input=json.dumps(request),
        capture_output=True,
        text=True,
    )

    try:
        response = json.loads(result.stdout)
    except json.JSONDecodeError:
        print(f"FAIL — no parseable JSON (exit {result.returncode})")
        print(f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}")
        sys.exit(1)

    if response.get("error"):
        print(f"FAIL — {response['error']}")
        if "not configured" in response["error"]:
            print(f'\nFix: add the DeepWiki server ({MCP_SERVER}) in the MCP Servers panel.')
        elif "not enabled" in response["error"] and "server" in response["error"]:
            print("\nFix: the DeepWiki server is added but toggled off — enable it in MCP Servers.")
        elif "not enabled" in response["error"]:
            print(f'\nFix: enable the "{MCP_TOOL}" tool on the DeepWiki server in MCP Servers.')
        elif "missing" in response["error"]:
            print(
                "\nThis usually means the request JSON doesn't match --chat's expected shape "
                '("messages", not "system_prompt"/"user_input") — but this script already sends '
                "the right shape, so if you're seeing this, something else changed the request."
            )
        sys.exit(1)

    # --chat's response uses "content", not --run's "answer".
    print(response.get("content", ""))


if __name__ == "__main__":
    main()
