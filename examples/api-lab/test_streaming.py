"""
test_streaming.py — LocalLM Lab API streaming test

WHAT THIS SCRIPT DOES
    Sends a chat completion request with stream=True and prints each
    chunk of the reply as it arrives, simulating how a real client
    (like a chat UI or coding assistant) would consume streaming output.

EXPECTED BEHAVIOR (if everything is working)
    - Text appears incrementally, word-by-word or chunk-by-chunk, not
      all at once — you should be able to see it "typing out" in your
      terminal.
    - The script ends with "✅ PASS — streaming works end-to-end."

WHAT FAILURE LOOKS LIKE
    - If the whole reply appears instantly as one block with no visible
      streaming, the server may be a) not implementing streaming yet,
      or b) buffering the whole response before sending it — this
      still "works" in the sense that you get a reply, but doesn't
      confirm streaming is functioning correctly.
    - If the script hangs with no output and no error, the connection
      may have opened but the server isn't sending the expected
      "data: ...\\n\\n" formatted chunks — this is the most common
      streaming bug to check for on the server side.
    - Connection/auth errors behave the same as in test_connection.py.
"""

import os
import sys
import time
from openai import OpenAI, APIConnectionError, AuthenticationError, OpenAIError

# --- CONFIG: edit these, or set the equivalent environment variables ---
BASE_URL = os.environ.get("LOCALLM_BASE_URL", "http://localhost:1234/v1")
TOKEN = os.environ.get("LOCALLM_TOKEN", "sk-locallm-REPLACE-ME")
# ------------------------------------------------------------------------

def main():
    print(f"Connecting to {BASE_URL} (streaming) ...")
    print("Expecting: text to appear gradually, not all at once, below.\n")

    client = OpenAI(base_url=BASE_URL, api_key=TOKEN)

    try:
        stream = client.chat.completions.create(
            model="locallm-default",
            messages=[
                {"role": "user", "content": "Count from one to ten, one number per line."}
            ],
            stream=True,
        )
    except APIConnectionError:
        print("❌ FAIL — could not connect.")
        print("   Check that the API server is turned On in LocalLM Lab,")
        print(f"   and that {BASE_URL} matches the Base URL shown in API Lab.")
        sys.exit(1)
    except AuthenticationError:
        print("❌ FAIL — authentication rejected (bad or stale token).")
        sys.exit(1)
    except OpenAIError as e:
        print(f"❌ FAIL — unexpected API error: {e}")
        sys.exit(1)

    chunk_count = 0
    full_reply = ""
    start = time.time()

    try:
        for event in stream:
            delta = event.choices[0].delta.content if event.choices else None
            if delta:
                print(delta, end="", flush=True)
                full_reply += delta
                chunk_count += 1
    except OpenAIError as e:
        print(f"\n❌ FAIL — error mid-stream: {e}")
        sys.exit(1)

    elapsed = time.time() - start
    print("\n")

    if chunk_count > 1:
        print(f"✅ PASS — streaming works end-to-end ({chunk_count} chunks in {elapsed:.1f}s).")
    elif chunk_count == 1:
        print("⚠️  Only received a single chunk — the whole reply may have arrived")
        print("   at once rather than being streamed incrementally. Worth checking")
        print("   the server's streaming implementation.")
    else:
        print("❌ FAIL — no content received.")


if __name__ == "__main__":
    main()
