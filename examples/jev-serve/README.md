# jev-serve

Hosted Jev's HTTP API, answered on your Mac. `jev-serve` takes the same requests as TypeSafe's Jev
on OpenRouter (`POST /api/alpha/decisions`) and Featherless's Simple Jev (`POST /v1/classifier`)
and answers them with **OpenJev**, the LocalLM Lab SDK's decider, on a local MLX model. Code that
already calls hosted Jev, in any language, switches to private, free, on-device decisions by
changing its base URL.

New to decision models? Start with [Decision models (Jev) in your app](https://thisbrain.ai/locallm/jev.html)
and the [JevDK guide](https://thisbrain.ai/locallm/jdk-guide.html).

```bash
swift build -c release
.build/release/jev-serve --config jev-serve.json
```

Needs an Apple-silicon Mac, macOS 27 and Xcode 27 (Swift 6.4).

## 1. Make a config in JevDK

Design and test your questions in [JevDK](../jevdk/), pick and calibrate a local model, then
**File → Export Server Config…**. That writes `jev-serve.json`: where to listen, an optional
token, and your tested setup (the model, its exact version, the system instructions and the
calibration). Export again from another question set to add a second entry to the same file.

```json
{
  "format": 1,
  "listen": { "host": "127.0.0.1", "port": 8746 },
  "token": "…",
  "defaultModel": "customer-support",
  "maxStateCharacters": 20000,
  "models": [
    { "name": "customer-support",
      "tuning": {
        "model": "openjev:mlx-community/Qwen3-4B-4bit",
        "revision": "4dcb3d101c2a062e5c1d4bb173588c54ea6c4d25",
        "system": "You answer questions about a piece of text. …",
        "inputLabel": "Text",
        "calibration": { "noulTemperature": 9.11, "choiceTemperature": 0.25, "scoreTemperature": 1 } } }
  ]
}
```

No config yet? `jev-serve --model mlx-community/Qwen3-4B-4bit` serves one model with the default
system instructions and no calibration.

## 2. Start it

```
$ jev-serve --config jev-serve.json
jev-serve on http://127.0.0.1:8746  (token required)
  customer-support (default)  mlx-community/Qwen3-4B-4bit @ 4dcb3d1  calibrated
OpenRouter clients:  base URL http://127.0.0.1:8746/api   (POST /alpha/decisions)
Featherless clients: base URL http://127.0.0.1:8746/v1    (POST /classifier)
```

**The model is made ready first.** Each model is pinned to the version in the config (the one you
tested and calibrated). If that version is on this Mac, it's used. If another tool left a copy in
the Hugging Face cache, it's verified and only missing files are fetched. If it isn't here, it's
checked (format, architecture, memory, disk) and downloaded, with progress. Then the default model
is loaded, and only then does jev-serve accept requests. `--no-download` makes a missing model an
error instead.

## 3. Call it

The request and response are hosted Jev's. With `curl`:

```bash
curl -s http://127.0.0.1:8746/v1/classifier \
  -H "Authorization: Bearer $JEV_SERVE_TOKEN" -H "Content-Type: application/json" \
  -d '{
    "model": "customer-support",
    "state": "Nothing loads since this morning, my whole team is stuck.",
    "questions": {
      "team":    {"type": "choice", "instructions": "Which team should handle this message?",
                  "criteria": {"billing": "payments, invoices and refunds",
                               "technical": "bugs, outages and product errors",
                               "account": "profile, login and subscription changes"}},
      "refund":  {"type": "noul", "instructions": "Does the customer explicitly ask for money back?"},
      "urgency": {"type": "score", "instructions": "How urgent is it?", "criteria": ["can wait", "soon", "now"]}
    }
  }'
```

```json
{"model": "mlx-community/Qwen3-4B-4bit",
 "answers": {
   "team":    {"type": "choice", "choice": "technical", "confidence": 0.99, "probabilities": {"billing": 0.0, "technical": 0.99, "account": 0.01}},
   "refund":  {"type": "noul", "noul": 0.03},
   "urgency": {"type": "score", "score": 1.44, "confidence": 0.56, "probabilities": {"0": 0.0, "1": 0.56, "2": 0.44},
               "legend": {"0": "can wait", "1": "soon", "2": "now"}}},
 "usage": {"input_tokens": 56, "output_tokens": 0, "cost": 0},
 "fidelity": "tokenScored", "calibrated": true}
```

- **`model`**: a model's name from the config, or its Hugging Face repo id. Leave it out for the
  config's default.
- **`state`**: text, or any JSON object.
- From an existing hosted-Jev client, change only the base URL (and the token). From Swift, the
  SDK's own `JevDecisionProvider` works too: point a `JevProviderConfig` at
  `http://127.0.0.1:8746/v1/classifier`.

| Route | |
|---|---|
| `POST /api/alpha/decisions` | OpenRouter / TypeSafe Jev's path |
| `POST /v1/classifier` | Featherless's path (same body) |
| `GET /v1/models` | The served models, with version and whether calibrated |
| `GET /health` | `{"status":"ok"}`; needs no token |

Errors use hosted Jev's shape, `{"error": {"message", "type", "code"}}`: 400 for a request that
can't be asked (with what's wrong), 401 without the token, 404 for an unknown model or route, 413
for a body over 1 MB, 503 when too many requests are waiting.

## How it differs from TypeSafe's Jev

| | TypeSafe Jev | jev-serve (OpenJev) |
|---|---|---|
| Probabilities | From a model trained to decide | Read off a language model's next-token probabilities (`"fidelity": "tokenScored"`); honest only once calibrated (`"calibrated": true`) |
| Limits | 255 choice options, 50 score levels | 64 questions, 26 choice options, 10 score levels |
| `confidence` | Reported separately | The top answer's probability |
| `noul` | — | Not clamped (Featherless clamps to 0.01–0.99) |
| `usage` | Tokens and cost | The input's tokens; nothing generated; cost 0 |
| `messages`, images, `options` | Featherless / OpenRouter extras | Ignored |

## Security

- **This Mac only by default** (`127.0.0.1`). Any app of yours can call it; the **token** keeps out
  everything that doesn't have it. The config file is readable only by you.
- **Plain HTTP.** Listening on another address (`"host": "0.0.0.0"`, `--host`) works but logs a
  warning: inputs and the token would cross the network unencrypted.
- **Inputs aren't logged.** One line per request (route, model, number of questions, status, time).
  `--log-bodies` logs the bodies, for debugging only.
- No CORS headers: a web page in a browser can't call it.

## Options

```
jev-serve --config <file> | --model <repo>
          [--host 127.0.0.1] [--port 8746] [--no-download] [--log-bodies] [--self-check]
```

`--self-check` starts on a spare port, asks every served model the same questions over HTTP and
directly, checks the answers match, and exits (0 if they all do). Run it after changing the
config, the model or the SDK.

## Testing

```bash
swift test                                  # routes, token, limits, queue, HTTP, SDK client round trip
.build/release/jev-serve --config jev-serve.json --self-check   # the same, live on your model
```

The unit tests run the real server and routes with a scripted decider (no GPU needed), and call it
with the SDK's own hosted-Jev client, `JevDecisionProvider`, so the wire format is checked both ways.

## How it works

About 500 lines on the SDK's public API, in `JevServeKit` (the server and routes, testable)
and the `jev-serve` command: `JevWire` (Core) reads and writes hosted Jev's JSON (the
same code the SDK's `JevDecisionProvider` uses as a client), `OpenJevDecisionProvider` and
`MLXModelProvider` (Inference) answer and download, and JevDK's `JevServeConfig` reads the config.
The HTTP server is `Network.framework`, no other dependency. Decisions run one at a time (one GPU)
in arrival order, about 80–150 ms each on Qwen3-4B.
