# LocalLM Lab — Examples

Code samples for LocalLM Lab, split by which feature they use.

| Folder | Feature | What it shows |
|---|---|---|
| [api-lab/](api-lab/) | API Lab (OpenAI-compatible HTTP endpoint) | Conformance/smoke test scripts and a simple Python chat app that talk to a running LocalLM Lab server over HTTP. |
| [localai-cli/](localai-cli/) | `localai-cli` toolkit (Python) | Calling the local AI helper binary directly via subprocess — no HTTP server, no LocalLM Lab dependency for the call itself. |
| [localai-cli-swift/](localai-cli-swift/) | `localai-cli` toolkit (Swift) | Same examples as localai-cli/, in Swift. |
| [plate-today/](plate-today/) | LocalLM Lab SDK (Core) | A native SwiftUI app linking `LocalLMLabSDKCore` directly — Calendar/Reminders connectors, a real Todoist MCP OAuth flow, and a signed path to both Developer ID distribution and the Mac App Store. |
| [components-demo/](components-demo/) | LocalLM Lab SDK (`Components`) | The same SDK, via the prebuilt `LocalLMLabSDKComponents` MCP server picker UI instead of building your own. |

The `localai-cli` examples require the CLI toolkit itself, shipped in
[../toolkit/](../toolkit/). See that folder's README to download and
install it, and [thisbrain.ai/locallm/cli.html](https://thisbrain.ai/locallm/cli.html)
for the full CLI reference.

Download LocalLM Lab from [its product page at https://thisbrain.ai/locallm](https://thisbrain.ai/locallm)
