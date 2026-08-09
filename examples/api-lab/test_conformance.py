"""
test_conformance.py — LocalLM Lab API conformance suite

WHAT THIS SCRIPT DOES
    Runs several checks against your LocalLM Lab API endpoint in one go
    and prints a pass/fail summary at the end. Useful as a single command
    to run after any change to confirm nothing broke, without needing to
    run each test_*.py script individually.

CHECKS INCLUDED
    1. Models list      — GET /v1/models returns at least one model
    2. Basic completion — a non-streaming chat completion succeeds
    3. Streaming        — a streaming chat completion delivers content via SSE
    4. Bad token         — an invalid token is correctly rejected (401)
    5. Missing field     — an empty "messages" list is handled with a clear
                            error rather than a crash

EXPECTED BEHAVIOR (if everything is working)
    All five checks print "✅ PASS", and the script exits with code 0.

WHAT FAILURE LOOKS LIKE
    Any check that fails prints "❌ FAIL" with a short explanation, and
    the script exits with a non-zero code at the end (useful if you want
    to wire this into a script or CI-style check later). A failing check
    does not stop the others from running — you get the full picture in
    one pass.
"""

import os
import sys
from openai import OpenAI, APIConnectionError, AuthenticationError, BadRequestError, OpenAIError

# --- CONFIG: edit these, or set the equivalent environment variables ---
BASE_URL = os.environ.get("LOCALLM_BASE_URL", "http://localhost:1234/v1")
TOKEN = os.environ.get("LOCALLM_TOKEN", "sk-locallm-REPLACE-ME")
# ------------------------------------------------------------------------

results = []  # list of (name, passed: bool, detail: str)


def record(name, passed, detail=""):
    results.append((name, passed, detail))
    status = "✅ PASS" if passed else "❌ FAIL"
    print(f"{status} — {name}" + (f" ({detail})" if detail else ""))


def check_models_list(client):
    print("\n[1/5] Models list — expecting at least one model returned")
    try:
        models = client.models.list()
        ids = [m.id for m in models.data]
        if ids:
            record("Models list", True, f"got {ids}")
        else:
            record("Models list", False, "empty list returned")
    except OpenAIError as e:
        record("Models list", False, str(e))


def check_basic_completion(client):
    print("\n[2/5] Basic completion — expecting a non-empty reply")
    try:
        resp = client.chat.completions.create(
            model="locallm-default",
            messages=[{"role": "user", "content": "Reply with the single word: OK"}],
        )
        content = resp.choices[0].message.content
        record("Basic completion", bool(content and content.strip()), f"reply: {content!r}")
    except OpenAIError as e:
        record("Basic completion", False, str(e))


def check_streaming(client):
    # Note: we only require at least one chunk with content, not multiple.
    # Foundation Models' own streaming granularity is coarser for short
    # replies and can legitimately deliver the whole answer in a single
    # snapshot before "done" — that's real model behavior, not a broken
    # relay (see docs/requirements.md §1's "interface-compatible, not
    # behavior-identical" framing). What actually matters here is that the
    # stream=True code path works end-to-end via SSE, not the chunk count.
    print("\n[3/5] Streaming — expecting content delivered via SSE (chunk count may vary)")
    try:
        stream = client.chat.completions.create(
            model="locallm-default",
            messages=[{"role": "user", "content": "Write two sentences describing the ocean."}],
            stream=True,
        )
        chunk_count = 0
        received_text = ""
        for event in stream:
            if event.choices and event.choices[0].delta.content:
                chunk_count += 1
                received_text += event.choices[0].delta.content
        record("Streaming", bool(received_text.strip()), f"{chunk_count} chunk(s), {len(received_text)} chars received")
    except OpenAIError as e:
        record("Streaming", False, str(e))


def check_bad_token():
    print("\n[4/5] Bad token — expecting the request to be rejected")
    bad_client = OpenAI(base_url=BASE_URL, api_key="sk-locallm-this-is-not-real")
    try:
        bad_client.chat.completions.create(
            model="locallm-default",
            messages=[{"role": "user", "content": "This should fail."}],
        )
        record("Bad token rejected", False, "request succeeded with an invalid token!")
    except AuthenticationError:
        record("Bad token rejected", True, "correctly returned an authentication error")
    except OpenAIError as e:
        record("Bad token rejected", False, f"wrong error type: {e}")


def check_missing_field(client):
    print("\n[5/5] Missing field — expecting a clear error, not a crash")
    try:
        client.chat.completions.create(model="locallm-default", messages=[])
        record("Missing field handling", False, "empty messages list was accepted silently")
    except BadRequestError:
        record("Missing field handling", True, "correctly returned a bad request error")
    except OpenAIError as e:
        record("Missing field handling", False, f"unexpected error type: {e}")


def main():
    print(f"Running conformance suite against {BASE_URL}\n")

    client = OpenAI(base_url=BASE_URL, api_key=TOKEN)

    # Fail fast with a clear message if we can't connect at all.
    try:
        client.models.list()
    except APIConnectionError:
        print("❌ Could not connect at all.")
        print("   Check that the API server is turned On in LocalLM Lab,")
        print(f"   and that {BASE_URL} matches the Base URL shown in API Settings.")
        sys.exit(1)
    except AuthenticationError:
        print("❌ Authentication rejected on the very first request.")
        print("   Copy the current token from API Settings and update TOKEN above.")
        sys.exit(1)
    except OpenAIError:
        pass  # let individual checks below handle/report other errors

    check_models_list(client)
    check_basic_completion(client)
    check_streaming(client)
    check_bad_token()
    check_missing_field(client)

    passed = sum(1 for _, ok, _ in results if ok)
    total = len(results)

    print(f"\n{'-'*50}")
    print(f"Summary: {passed}/{total} checks passed")

    if passed == total:
        print("✅ All checks passed — the endpoint looks OpenAI-compatible.")
        sys.exit(0)
    else:
        print("❌ Some checks failed — see details above.")
        sys.exit(1)


if __name__ == "__main__":
    main()
