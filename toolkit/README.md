# LocalLM Lab — CLI Toolkit

The `localai-cli` toolkit lets 3rd-party apps and scripts call LocalLM Lab's
local AI helper directly — no HTTP server, just a subprocess call with JSON
on stdin/stdout. It's `localai-cli` plus its helper — `localai-playground-run`
on macOS 27, `localai-playground-run-compat` on macOS 26.

Full CLI reference: [thisbrain.ai/locallm/cli.html](https://thisbrain.ai/locallm/cli.html)

Usage examples: [../examples/localai-cli/](../examples/localai-cli/) (Python)
and [../examples/localai-cli-swift/](../examples/localai-cli-swift/) (Swift).

## Download

Starting with `1.0.0-beta.4`, the toolkit is shipped as
release assets on
**[github.com/ancientcomputing/locallm-releases](https://github.com/ancientcomputing/locallm-releases/releases)**,
alongside the LocalLM Lab app DMG and the SDK xcframeworks.
Latest (`2.0.0-GA`):

```bash
curl -LO https://github.com/ancientcomputing/locallm/releases/download/v2.0.0-GA/localai-toolkit-2.0.0-GA-arm64.zip
curl -LO https://github.com/ancientcomputing/locallm/releases/download/v2.0.0-GA/localai-toolkit-2.0.0-GA-arm64.zip.sha256
```


## Verify

```bash
shasum -a 256 -c localai-toolkit-2.0.0-GA-arm64.zip.sha256
```

## Install

```bash
unzip localai-toolkit-2.0.0-GA-arm64.zip
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
