"""
test_connection.py — LocalLM Lab API smoke test

WHAT THIS SCRIPT DOES
    Sends a single, simple chat completion request to your local
    LocalLM Lab API endpoint and prints the reply.

EXPECTED BEHAVIOR (if everything is working)
    - The script prints "Connecting to <base_url>..."
    - Within a few seconds, it prints a model reply to the prompt
      "Say hello in exactly five words."
    - It ends with "✅ PASS — connection and basic completion work."

WHAT FAILURE LOOKS LIKE
    - A connection error ("Connection refused" / timeout) almost always
      means the API server is turned Off in LocalLM Lab, or the port
      below doesn't match what's shown in API Settings.
    - A 401 error means the token below is wrong or was regenerated
      since you copied it — copy the current token from API Settings.
    - Any other error will be printed with a short explanation.
"""

import os
import sys
from openai import OpenAI, APIConnectionError, AuthenticationError, OpenAIError

# --- CONFIG: edit these, or set the equivalent environment variables ---
BASE_URL = os.environ.get("LOCALLM_BASE_URL", "http://localhost:1234/v1")
TOKEN = os.environ.get("LOCALLM_TOKEN", "sk-locallm-REPLACE-ME")
# ------------------------------------------------------------------------

def main():
    print(f"Connecting to {BASE_URL} ...")
    print("Expecting: a short reply to a simple prompt, printed below.\n")

    client = OpenAI(base_url=BASE_URL, api_key=TOKEN)

    try:
        response = client.chat.completions.create(
            model="locallm-default",  # note: LocalLM Lab ignores this field in v1
            messages=[
                {"role": "user", "content": "Say hello in exactly five words."}
            ],
        )
    except APIConnectionError:
        print("❌ FAIL — could not connect.")
        print("   Check that the API server is turned On in LocalLM Lab,")
        print(f"   and that {BASE_URL} matches the Base URL shown in API Settings.")
        sys.exit(1)
    except AuthenticationError:
        print("❌ FAIL — authentication rejected (bad or stale token).")
        print("   Copy the current token from API Settings and update TOKEN above.")
        sys.exit(1)
    except OpenAIError as e:
        print(f"❌ FAIL — unexpected API error: {e}")
        sys.exit(1)

    reply = response.choices[0].message.content
    print("Model replied:")
    print(f"  {reply}\n")

    if reply and len(reply.strip()) > 0:
        print("✅ PASS — connection and basic completion work.")
    else:
        print("⚠️  Connected, but the reply was empty — worth investigating.")


if __name__ == "__main__":
    main()
