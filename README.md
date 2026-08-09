# LocalLM Lab

LocalLM Lab is a macOS app for running local AI models — it turns your Mac
into a private, offline chatbot with an OpenAI-compatible API, and gives
other apps and scripts a way to call the same local model directly.

Download LocalLM Lab from [its product page at https://thisbrain.ai/locallm](https://thisbrain.ai/locallm)

## What's in this repo

- **[toolkit/](toolkit/)** — The `localai-cli` CLI toolkit release (zip +
  checksum) for LocalLM Lab 0.6.0. Download, verify, and install
  instructions live there. Full CLI reference:
  [thisbrain.ai/locallm/cli.html](https://thisbrain.ai/locallm/cli.html)
- **[examples/](examples/)** — Code samples, split by feature:
  - **api-lab/** — Scripts and a sample chat app for the API Lab feature
    (LocalLM Lab's OpenAI-compatible HTTP endpoint).
  - **localai-cli/** — Python examples calling the `localai-cli` toolkit
    directly (no HTTP server, subprocess + JSON on stdin/stdout).
  - **localai-cli-swift/** — The same examples in Swift.

## Roadmap

If you want to see a new feature in LocalLM Lab, please feel free to do a pull request on ROADMAP.md
