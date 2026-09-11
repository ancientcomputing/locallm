# LocalLM Lab — CLI Toolkit

The `localai-cli` toolkit lets 3rd-party apps and scripts call LocalLM Lab's
local AI helper directly — no HTTP server, just a subprocess call with JSON
on stdin/stdout. It's `localai-cli` plus its helper — `localai-playground-run`
on macOS 27, `localai-playground-run-compat` on macOS 26.

Full CLI reference: [thisbrain.ai/locallm/cli.html](https://thisbrain.ai/locallm/cli.html)

Usage examples: [../examples/localai-cli/](../examples/localai-cli/) (Python)
and [../examples/localai-cli-swift/](../examples/localai-cli-swift/) (Swift).

## Download

From `1.0.0-beta.4` on, the toolkit zip and its checksum ship as release assets
on **[github.com/ancientcomputing/locallm-releases](https://github.com/ancientcomputing/locallm-releases/releases)**,
alongside the LocalLM Lab app DMG — one release per version:

```bash
curl -LO https://github.com/ancientcomputing/locallm-releases/releases/download/1.0.0-beta.4/localai-toolkit-1.0.0-beta.4-arm64.zip
curl -LO https://github.com/ancientcomputing/locallm-releases/releases/download/1.0.0-beta.4/localai-toolkit-1.0.0-beta.4-arm64.zip.sha256
```

Earlier releases (`0.6`–`1.0.0-beta.3`) stay checked into this folder — grab
them by cloning the repo or downloading a single file raw, e.g.:

```bash
curl -LO https://raw.githubusercontent.com/ancientcomputing/locallm/1.0.0-beta/toolkit/localai-toolkit-1.0.0-beta.3-arm64.zip
curl -LO https://raw.githubusercontent.com/ancientcomputing/locallm/1.0.0-beta/toolkit/localai-toolkit-1.0.0-beta.3-arm64.zip.sha256
```

## Verify

```bash
shasum -a 256 -c localai-toolkit-1.0.0-beta.4-arm64.zip.sha256
```

## Install

```bash
unzip localai-toolkit-1.0.0-beta.4-arm64.zip
```

This produces `localai-cli`, `localai-playground-run` (macOS 27),
`localai-playground-run-compat` (macOS 26), and a `runtime/` folder holding
the libraries and resources they load. Keep `runtime/` next to the
executables — the folder moves as a unit — and `localai-cli` picks the right
helper next to itself based on the OS. Put `localai-cli` on your `PATH` (or
reference it by full path); the folder itself has to stay together.

On macOS 26 only the Apple on-device model (`system`) is available; Private
Cloud Compute, Claude, and open-weight (MLX) models need macOS 27.

`localai-cli` reads `~/Library/Application Support/LocalLM Lab/app-config.json`,
which LocalLM Lab writes from its **Connectors**, **MCP Servers**, and
**AI Models** screens. LocalLM Lab must be **running** for `localai-cli` calls
to work — connector and MCP calls execute inside the app's own process, reached
over a local socket. See the examples folders above for setup and sample calls.
