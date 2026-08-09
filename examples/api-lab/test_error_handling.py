"""
test_error_handling.py — LocalLM Lab API error handling test

WHAT THIS SCRIPT DOES
    Deliberately sends a request with an intentionally WRONG token, to
    confirm the server correctly rejects it with a proper error rather
    than crashing or hanging. This helps you recognize what a real auth
    failure looks like versus a broken connection.

EXPECTED BEHAVIOR (if everything is working)
    - The request is rejected quickly with a 401-style authentication
      error, and the SDK raises AuthenticationError.
    - The script prints "✅ PASS — bad token was correctly rejected."

WHAT FAILURE LOOKS LIKE
    - If the request SUCCEEDS with a bad token, that's a real problem —
      it means the server isn't checking auth properly. The script will
      flag this clearly as a FAIL.
    - If the script raises some other unexpected error (not an auth
      error), the server's error handling may not match the expected
      OpenAI-style error shape.
    - A connection error here just means the server is off — same as
      the other scripts.
"""

import os
import sys
from openai import OpenAI, APIConnectionError, AuthenticationError, OpenAIError

# --- CONFIG: edit these, or set the equivalent environment variables ---
BASE_URL = os.environ.get("LOCALLM_BASE_URL", "http://localhost:1234/v1")
# Intentionally NOT using a real token here — that's the point of this test.
BAD_TOKEN = "sk-locallm-this-is-not-a-real-token"
# ------------------------------------------------------------------------

def main():
    print(f"Connecting to {BASE_URL} with a deliberately invalid token ...")
    print("Expecting: the request to be REJECTED with an authentication error.\n")

    client = OpenAI(base_url=BASE_URL, api_key=BAD_TOKEN)

    try:
        client.chat.completions.create(
            model="locallm-default",
            messages=[{"role": "user", "content": "This should not succeed."}],
        )
    except AuthenticationError as e:
        print(f"Server correctly rejected the request: {e}\n")
        print("✅ PASS — bad token was correctly rejected.")
        return
    except APIConnectionError:
        print("❌ Could not connect at all — this test needs the server to be On.")
        print("   Check that the API server is turned On in LocalLM Lab.")
        sys.exit(1)
    except OpenAIError as e:
        print(f"⚠️  Request failed, but not with the expected auth error type: {e}")
        print("   The server may not be returning OpenAI-style 401 errors correctly.")
        sys.exit(1)

    # If we get here, no exception was raised — the bad token was accepted.
    print("❌ FAIL — the request SUCCEEDED with an invalid token.")
    print("   This means authentication is not being enforced correctly.")
    sys.exit(1)


if __name__ == "__main__":
    main()
