"""
quickstart_mcp_deepwiki.py — the fastest possible MCP demo, no auth required

WHAT THIS SCRIPT DOES
    Calls the local AI with one tool from DeepWiki — the MCP server with the
    lowest setup cost of any on web/mcp-servers.html: auth type "None",
    "connects immediately," no OAuth consent screen, no API key. Everything
    below is pre-filled with the exact server/tool/prompt from that page, so
    there's nothing to look up or edit — only the one-time server connection
    to make in LocalLM Lab.

SETUP (about a minute)
    1. Run LocalLM Lab, open the MCP Servers panel (menu bar tray icon).
    2. Add Server → URL: https://mcp.deepwiki.com/mcp, display name:
       "DeepWiki", auth type: None. Click Add — no sign-in required.
    3. In the DeepWiki entry, enable the "read_wiki_structure" tool (every
       newly connected server starts with all tools off, by design — see
       web/mcp-servers.html's context-budget note).
    4. Download localai-toolkit-<version>-arm64.zip, unzip it, and place
       localai-cli + localai-playground-run next to this script (or set
       LOCALAI_CLI_PATH).

RUN
    python quickstart_mcp_deepwiki.py

EXPECTED OUTPUT
    The model's answer listing documentation topics for a real public GitHub
    repo (nickclyde/duckduckgo-mcp-server) — proof the MCP tool call actually
    reached DeepWiki's server and came back, not just model guesswork.
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

    request = {
        "system_prompt": "You are a concise assistant. Use the available tool to answer.",
        "user_input": USER_INPUT,
        "mcp_tools": [{"server": MCP_SERVER, "tool": MCP_TOOL}],
    }

    result = subprocess.run(
        [LOCALAI_CLI_PATH, "--config", LOCALAI_CONFIG_PATH, "--run"],
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
        sys.exit(1)

    print(response.get("answer", ""))


if __name__ == "__main__":
    main()
