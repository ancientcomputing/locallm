# LocalLM Lab — CLI Toolkit

The `localai-cli` toolkit lets 3rd-party apps and scripts call LocalLM Lab's
local AI helper directly — no HTTP server, just a subprocess call with JSON
on stdin/stdout. It's the matched pair `localai-cli` and
`localai-playground-run`.

Full CLI reference: [thisbrain.ai/locallm/cli.html](https://thisbrain.ai/locallm/cli.html)

Usage examples: [../examples/localai-cli/](../examples/localai-cli/) (Python)
and [../examples/localai-cli-swift/](../examples/localai-cli-swift/) (Swift).

## Download

- `localai-toolkit-0.6.0-arm64.zip`
- `localai-toolkit-0.6.0-arm64.zip.sha256`

## Verify

```bash
shasum -a 256 -c localai-toolkit-0.6.0-arm64.zip.sha256
```

## Install

```bash
unzip localai-toolkit-0.6.0-arm64.zip
```

This produces `localai-cli` and `localai-playground-run`. Put them
somewhere on your `PATH`, or reference them by full path.

`localai-cli` reads `~/Library/Application Support/LocalLM Lab/localai-config.json`,
which is created and managed by LocalLM Lab's **Local AI Settings** screen.
LocalLM Lab must be running for `localai-cli` calls to work — it relays
connector/MCP calls through LocalLM Lab's chooser process over a local
socket. See the examples folders above for setup details and sample calls.
