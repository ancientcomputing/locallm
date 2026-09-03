# LocalLM Lab — CLI Toolkit

The `localai-cli` toolkit lets 3rd-party apps and scripts call LocalLM Lab's
local AI helper directly — no HTTP server, just a subprocess call with JSON
on stdin/stdout. It's `localai-cli` plus its helper — `localai-playground-run`
on macOS 27, `localai-playground-run-compat` on macOS 26.

Full CLI reference: [thisbrain.ai/locallm/cli.html](https://thisbrain.ai/locallm/cli.html)

Usage examples: [../examples/localai-cli/](../examples/localai-cli/) (Python)
and [../examples/localai-cli-swift/](../examples/localai-cli-swift/) (Swift).

## Download

The zip and its checksum are checked into this folder — one per release. Grab
them by cloning the repo, or download a single file raw, e.g.:

```bash
curl -LO https://raw.githubusercontent.com/ancientcomputing/locallm/1.0.0-beta/toolkit/localai-toolkit-1.0.0-beta.2-arm64.zip
curl -LO https://raw.githubusercontent.com/ancientcomputing/locallm/1.0.0-beta/toolkit/localai-toolkit-1.0.0-beta.2-arm64.zip.sha256
```

Older releases (`0.6`–`0.8`) are alongside it in this folder.

## Verify

```bash
shasum -a 256 -c localai-toolkit-1.0.0-beta.2-arm64.zip.sha256
```

## Install

```bash
unzip localai-toolkit-1.0.0-beta.2-arm64.zip
```

This produces `localai-cli`, `localai-playground-run` (macOS 27) and
`localai-playground-run-compat` (macOS 26), plus the `.dylib`s and resource
bundles they need. Keep everything together — `localai-cli` picks the right
helper next to itself based on the OS — and either put `localai-cli` on your
`PATH` or reference it by full path.

On macOS 26 only the Apple on-device model (`system`) is available; Private
Cloud Compute, Claude, and open-weight (MLX) models need macOS 27.

`localai-cli` reads `~/Library/Application Support/LocalLM Lab/app-config.json`,
which LocalLM Lab writes from its **Connectors**, **MCP Servers**, and
**AI Models** screens. LocalLM Lab must be **running** for `localai-cli` calls
to work — connector and MCP calls execute inside the app's own process, reached
over a local socket. See the examples folders above for setup and sample calls.
