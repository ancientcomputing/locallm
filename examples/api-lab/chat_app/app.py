"""Minimal single-turn chat app for LocalLM Lab's API.

Each question is sent independently — no conversation history is kept
between turns, matching the "no context from one Q+A to the next" brief.

Setup:
    pip install flask openai
    export LOCALLM_BASE_URL="http://localhost:8765/v1"
    export LOCALLM_TOKEN="sk-locallm-xxxxxxxxxxxx"
    python app.py

Then open http://127.0.0.1:<port> (printed on startup; default 5099,
override with CHAT_APP_PORT if that's also taken).
"""

import os

from flask import Flask, jsonify, render_template, request
from openai import OpenAI, OpenAIError

BASE_URL = os.environ.get("LOCALLM_BASE_URL", "http://localhost:8765/v1")
TOKEN = os.environ.get("LOCALLM_TOKEN", "")
PORT = int(os.environ.get("CHAT_APP_PORT", "5099"))

app = Flask(__name__)
client = OpenAI(base_url=BASE_URL, api_key=TOKEN or "not-set")


@app.route("/")
def index():
    return render_template("index.html", base_url=BASE_URL)


@app.route("/api/ask", methods=["POST"])
def ask():
    data = request.get_json(silent=True) or {}
    question = (data.get("question") or "").strip()
    if not question:
        return jsonify({"error": "Question is empty."}), 400

    try:
        completion = client.chat.completions.create(
            model=data.get("model", "local-model"),
            messages=[{"role": "user", "content": question}],
        )
    except OpenAIError as exc:
        return jsonify({"error": str(exc)}), 502

    answer = completion.choices[0].message.content
    return jsonify({"answer": answer})


if __name__ == "__main__":
    print(f"Open http://127.0.0.1:{PORT}")
    app.run(port=PORT, debug=True)
