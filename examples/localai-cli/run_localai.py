"""
run_localai.py — call localai-cli from Python, no LocalLM Lab server running

WHAT THIS SCRIPT DOES
    Shows the pattern a 3rd-party app (e.g. OrbAI RPG) would use to reach the
    local AI directly: spawn `localai-cli` as a subprocess, pipe a JSON
    request on stdin, read its JSON response from stdout. This does NOT talk
    to LocalLM Lab's Go server or its HTTP API at all — localai-cli and
    localai-playground-run are self-contained binaries.

    localai-cli reads a config file (localai-config.json, authored by
    LocalLM Lab's Local AI Settings screen) that lists which connectors
    (tools the model can call, e.g. a system clock or read-only filesystem
    access) the user has granted. Every request to localai-cli then
    explicitly lists which of those already-granted connectors it wants
    active for that one call, via a "connectors" field:
        - A connector named in the request must already be enabled in
          localai-config.json, or localai-cli rejects the request with a
          JSON {"error": "..."} before ever invoking the model.
        - Connectors enabled in the config but not named in a given request
          simply aren't given to that call — no error, just a narrower
          toolset for that request.
        - Omitting "connectors" entirely means NO connectors are active for
          that call — a deliberate least-privilege default, not an
          oversight. Every tool a call can use must be listed explicitly.

REQUIREMENTS
    - macOS 26+ on Apple Silicon with Apple Intelligence enabled.
    - localai-cli and localai-playground-run, downloaded together as the
      localai-toolkit-<version>-arm64.zip release asset and unzipped
      somewhere. Both must sit in the same directory (localai-cli's default
      --helper-path assumes "next to me"), or pass --helper-path explicitly.
    - A localai-config.json produced by running LocalLM Lab at least once
      and enabling whichever connectors you plan to request below — see
      Local AI Settings in the app. localai-cli only reads this file, it
      never creates or edits it.

EXPECTED BEHAVIOR (if everything is working)
    - Prints the resolved localai-cli/config paths being used.
    - Prints the model's reply to a simple prompt.
    - Ends with "PASS — localai-cli run succeeded."

WHAT FAILURE LOOKS LIKE
    - "localai-cli not found at ..." — fix LOCALAI_CLI_PATH below, or place
      the binary where this script expects it.
    - {"error": "config file not found: ..."} — fix LOCALAI_CONFIG_PATH.
    - {"error": "connector '...' is not enabled in the config"} — the
      connector requested below isn't turned on in Local AI Settings; either
      enable it there, or remove it from CONNECTORS below.
    - {"error": "The operation couldn't be completed.
      (FoundationModels.LanguageModelSession.GenerationError error -1.)"} — a
      generic on-device generation failure, thrown by FoundationModels
      itself after localai-cli already accepted the request (not a config
      problem, and not this script's prompt — confirmed by re-running the
      exact same request and getting a normal reply). Treat it as
      transient: just retry the same request.
    - Any other non-zero exit usually means localai-playground-run itself
      failed (e.g. unsupported hardware/OS) — the printed JSON's "error"
      field has the detail.
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
# Which connectors this particular call wants active — must already be
# enabled in localai-config.json, or localai-cli rejects the request before
# ever invoking the model. Omitting this list entirely means NO connectors
# are made available to the call, by design (see requirements doc).
CONNECTORS = ["clock"]
# ------------------------------------------------------------------------


def run_localai(system_prompt: str, user_input: str, connectors=None) -> dict:
    """Invoke localai-cli --run and return its parsed JSON response.

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
        "connectors": connectors or [],
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
    print(f"connectors       : {CONNECTORS}")
    print("Expecting: a short reply to a simple prompt, printed below.\n")

    try:
        response = run_localai(
            system_prompt="You are a concise assistant.",
            user_input="What time is it right now?",
            connectors=CONNECTORS,
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
    print("PASS — localai-cli run succeeded.")


if __name__ == "__main__":
    main()
