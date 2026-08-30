"""
test_models_list.py — LocalLM Lab API model listing test

WHAT THIS SCRIPT DOES
    Calls GET /v1/models and prints what comes back. Many client tools
    call this endpoint first to populate a model picker, so it's worth
    confirming it works independently of chat completions.

EXPECTED BEHAVIOR (if everything is working)
    - The script prints a list containing at least one model.
    - LocalLM Lab v1 is expected to return a single model with an id
      like "locallm-default".
    - Ends with "✅ PASS — models endpoint responded as expected."

WHAT FAILURE LOOKS LIKE
    - Connection/auth errors behave the same as in test_connection.py.
    - An empty list, or a response missing an "id" field, means the
      endpoint is reachable but not returning data in the shape a
      real OpenAI client expects — worth reporting as a bug.
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
    print("Expecting: a list containing at least one model (e.g. 'locallm-default').\n")

    client = OpenAI(base_url=BASE_URL, api_key=TOKEN)

    try:
        models = client.models.list()
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

    model_ids = [m.id for m in models.data]

    if not model_ids:
        print("❌ FAIL — endpoint responded, but the model list was empty.")
        sys.exit(1)

    print("Models returned:")
    for mid in model_ids:
        print(f"  - {mid}")

    print("\n✅ PASS — models endpoint responded as expected.")


if __name__ == "__main__":
    main()
