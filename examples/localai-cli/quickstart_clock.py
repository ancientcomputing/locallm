"""
quickstart_clock.py — the fastest possible localai-cli demo, no setup

WHAT THIS SCRIPT DOES
    Calls the local AI with the "clock" connector — the only connector that
    needs zero macOS permission dialogs (see web/connectors.html) — and asks
    it the current time. Nothing to configure below: no server URL, no
    tool name, no OAuth. If the Connectors screen has System Clock turned on,
    running this script just works.

    Unlike run_localai.py (which explains the general pattern), this script
    exists purely so a first-time reader can run one command and immediately
    see the local AI actually do something, before reading anything else.

SETUP (about 30 seconds)
    1. Run LocalLM Lab at least once.
    2. Open the Connectors screen and turn on the "System Clock" connector.
       No permission prompt appears for this one — it's read-only, on-device,
       and doesn't touch Calendar/Reminders/Contacts/Location.
    3. Download localai-toolkit-<version>-arm64.zip, unzip it, and place
       localai-cli + localai-playground-run next to this script (or set
       LOCALAI_CLI_PATH).

RUN
    python quickstart_clock.py

EXPECTED OUTPUT
    The model's answer, which should state the current time — proof the
    "clock" connector's tool call actually happened, not just a guess from
    the model's training data.
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
    os.path.expanduser("~/Library/Application Support/LocalLM Lab/app-config.json"),
)


def main():
    if not os.path.isfile(LOCALAI_CLI_PATH):
        print(f"FAIL — localai-cli not found at {LOCALAI_CLI_PATH}")
        print("Set LOCALAI_CLI_PATH, or place the toolkit binaries next to this script.")
        sys.exit(1)

    request = {
        "system_prompt": "You are a concise assistant.",
        "user_input": "What time is it right now?",
        "connectors": ["clock"],
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
        if "not enabled" in response["error"]:
            print('\nFix: open the Connectors screen in LocalLM Lab and turn on "System Clock".')
        sys.exit(1)

    print(response.get("answer", ""))


if __name__ == "__main__":
    main()
