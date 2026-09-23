# Simple Chat App

A minimal browser-based chatbot UI for experimenting with LocalLM Lab's OpenAI-compatible API.
Each question is answered independently — there's no conversation history
carried from one Q+A to the next, so it's a clean example for people just
getting started with API Lab.

## Setup

1. In LocalLM Lab, open **API Lab** and turn the server **On**.
2. Copy the **Base URL** and **Token** shown there.
3. Install dependencies:

   ```bash
   pip install flask openai
   ```

4. Point the app at your LocalLM Lab server:

   ```bash
   export LOCALLM_BASE_URL="http://localhost:8765/v1"
   export LOCALLM_TOKEN="sk-locallm-xxxxxxxxxxxx"
   ```

   (Port `8765` is a common default — always double-check the actual port
   shown in API Lab, since LocalLM Lab may pick a different one if
   your configured port was busy.)

5. Run it:

   ```bash
   python app.py
   ```

   This app's own web page defaults to port `5099`. If that's also taken,
   override it:

   ```bash
   export CHAT_APP_PORT=5100
   python app.py
   ```

   The app prints the URL it's actually listening on when it starts.

6. Open the printed URL (e.g. **http://127.0.0.1:5099**) in your browser
   and start chatting.

## How it works

- `app.py` — a tiny Flask server with one page (`/`) and one API route
  (`POST /api/ask`). It uses the official `openai` Python SDK pointed at
  your local endpoint, exactly like the scripts in `examples/`.
- `templates/index.html` — a single-page chat UI (vanilla HTML/CSS/JS, no
  build step) that posts each question to `/api/ask` and renders the
  answer.

Because there's no chat history sent back to the model, this is a good
starting point to later extend into a "real" multi-turn chat by keeping a
running `messages` list per session.
