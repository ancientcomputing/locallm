"""
run_localai_mcp.py — call localai-cli with an MCP server tool, from Python

WHAT THIS SCRIPT DOES
    Same pattern as run_localai.py (spawn localai-cli, JSON on stdin/stdout,
    no LocalLM Lab server involved), but requests an MCP-server tool instead
    of (or alongside) a built-in connector, via the "mcp_tools" field:

        "mcp_tools": [{"server": "<mcp server URL>", "tool": "<tool name>"}]

    Each entry is validated the same "requested must already be enabled"
    way connectors are:
        - The server must be configured (connected at least once from
          LocalLM Lab's MCP Servers screen) AND enabled there.
        - The named tool must exist on that server AND be enabled there.
        - Omitting "mcp_tools" entirely means NO MCP tools are active for
          that call — same least-privilege default as "connectors".
    localai-cli rejects the request with {"error": "..."} before ever
    invoking the model if any of that isn't true.

REQUIREMENTS
    - Everything run_localai.py requires (see that script's docstring).
    - At least one MCP server connected and enabled via LocalLM Lab's MCP
      Servers screen, with the specific tool below enabled on it. Open MCP
      Servers in LocalLM Lab to see the exact server URL and tool names —
      both must match exactly what's in localai-config.json's "mcp_servers"
      array.

EXPECTED BEHAVIOR (if everything is working)
    - Prints the resolved localai-cli/config paths and the MCP tool being
      requested.
    - Prints the model's reply, which should reflect it having called the
      MCP tool (e.g. answering with data pulled from that server).
    - Ends with "PASS — localai-cli run with MCP tool succeeded."

WHAT FAILURE LOOKS LIKE
    - {"error": "MCP server \"...\" is not configured"} — the URL in
      MCP_SERVER below doesn't match any server in localai-config.json;
      double check it against LocalLM Lab's MCP Servers screen.
    - {"error": "MCP server \"...\" is not enabled"} — the server is
      configured but its toggle is off in MCP Servers.
    - {"error": "MCP tool \"...\" is not known on server \"...\""} — the
      tool name doesn't match; tool names are case-sensitive and come
      directly from the MCP server itself.
    - {"error": "MCP tool \"...\" on server \"...\" is not enabled"} — the
      server is on but this specific tool's toggle is off.
    - Anything from run_localai.py's own failure list also applies here.
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
    os.path.expanduser("~/Library/Application Support/LocalLM Lab/localai-config.json"),
)
# Must match a server's "url" and one of its tools' "name" exactly, as they
# appear in localai-config.json's "mcp_servers" array (see MCP Servers in
# LocalLM Lab). Both server and tool must already be enabled there.
MCP_SERVER = os.environ.get("LOCALAI_MCP_SERVER", "https://example-mcp-server.com/mcp")
MCP_TOOL = os.environ.get("LOCALAI_MCP_TOOL", "example_tool")
# ------------------------------------------------------------------------


def run_localai_with_mcp_tool(system_prompt: str, user_input: str, server: str, tool: str) -> dict:
    """Invoke localai-cli --run with one MCP tool selected, return its parsed JSON response.

    Raises RuntimeError if localai-cli itself couldn't be executed (e.g.
    missing binary) — a rejection or model error is NOT raised, it comes
    back as a normal dict with an "error" key, same as localai-cli's own
    stdout contract.
    """
    if not os.path.isfile(LOCALAI_CLI_PATH):
        raise RuntimeError(
            f"localai-cli not found at {LOCALAI_CLI_PATH} — set LOCALAI_CLI_PATH "
            "or place the binary next to this script."
        )

    request = {
        "system_prompt": system_prompt,
        "user_input": user_input,
        "mcp_tools": [{"server": server, "tool": tool}],
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
    print(f"mcp server       : {MCP_SERVER}")
    print(f"mcp tool         : {MCP_TOOL}")
    print("Expecting: a reply that used the MCP tool above, printed below.\n")

    try:
        response = run_localai_with_mcp_tool(
            system_prompt="You are a concise assistant. Use the available tool if it helps answer the question.",
            user_input="Use your tool to help answer, then summarize what you found in one sentence.",
            server=MCP_SERVER,
            tool=MCP_TOOL,
        )
    except RuntimeError as e:
        print(f"FAIL — {e}")
        sys.exit(1)

    if response.get("error"):
        print(f"FAIL — localai-cli rejected the request or the model errored:")
        print(f"  {response['error']}")
        sys.exit(1)

    print("Model replied:")
    print(f"  {response.get('answer', '')}\n")
    print("PASS — localai-cli run with MCP tool succeeded.")


if __name__ == "__main__":
    main()
