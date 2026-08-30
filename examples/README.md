# LocalLM Lab — Examples

Code samples for LocalLM Lab, split by which feature they use.

| Folder | Feature | What it shows |
|---|---|---|
| [api-lab/](api-lab/) | API Lab (OpenAI-compatible HTTP endpoint) | Conformance/smoke test scripts and a simple Python chat app that talk to a running LocalLM Lab server over HTTP. |
| [localai-cli/](localai-cli/) | `localai-cli` toolkit (Python) | Calling the local AI helper binary directly via subprocess — no HTTP server, no LocalLM Lab dependency for the call itself. |
| [localai-cli-swift/](localai-cli-swift/) | `localai-cli` toolkit (Swift) | Same examples as localai-cli/, in Swift. |
| [plate-today/](plate-today/) | LocalLM Lab SDK (Core), Path B | A native SwiftUI app linking `LocalLMLabSDKCore` directly — Calendar/Reminders connectors, a real Todoist MCP OAuth flow, and a signed path to both Developer ID distribution and the Mac App Store. Each connector gets its own hand-written `Tool` adapter. |
| [plate-today-tools/](plate-today-tools/) | LocalLM Lab SDK (Core), Path A | The exact same app as `plate-today/`, rebuilt on Core's ready-made `Tool`s (`GetUpcomingEventsTool`, `MCPTool`, etc.) instead of hand-written adapters — diff the two to see precisely what changes. |
| [repo-qa/](repo-qa/) | LocalLM Lab SDK (Core), Path A | A minimal command-line tool — no signing, no macOS permission needed. Builds a `Tool` for a real MCP server's (Deepwiki's) own tools straight from their live schema, no hand-written `Arguments` struct. Answered by Apple's on-device model. |
| [repo-qa-local/](repo-qa-local/) | LocalLM Lab SDK (Core **+ Inference**) | The exact same tool as `repo-qa/`, but the answer comes from an **open-weight MLX model you download and run locally** (`mlx-community/Qwen3-8B-4bit` by default), routed through the 1.0 model layer. The smallest possible model-layer + MLX example — diff the two `main.swift`s to see what the model layer adds. |
| [workspace-buddy/](workspace-buddy/) | LocalLM Lab SDK (Core), Path A | A local AI-assisted coding example: pick a folder, the on-device model reads/creates/edits files in it via Core's `WorkspaceTools`. |
| [code-buddy/](code-buddy/) | LocalLM Lab SDK (Core **+ Inference**) | The full model layer: a CLI coding agent running **locally-run MLX models** through `LocalLMLab` + `MLXModelProvider` (heavy/light routes, one resident at a time), Core's Workspace tools, a no-auth MCP server, and two **host-owned** `Process` tools (git, run-tests) the SDK deliberately doesn't ship. |
| [components-demo/](components-demo/) | LocalLM Lab SDK (`Components`) | The same SDK, via the prebuilt `LocalLMLabSDKComponents` MCP server picker UI instead of building your own. |

**Path A vs Path B**, for the four Core-based examples above: two ways to turn a connector or MCP
server into something the on-device model can call as a tool. **Path A** drops in a ready-made
`Tool` Core already ships, correctness lessons from real on-device model failures baked into its
description. **Path B** hand-writes a custom adapter directly against the underlying connector
call (`CalendarAccess`, `MCPServerManager`, etc.) for full control over tool names, schemas, and
descriptions. Neither is the "real" one — both ship in Core, and an app can mix them. See
[`../docs/sdk-guide.md` §7a](../docs/sdk-guide.md#7a-two-paths-to-tool-calling-ready-made-tools-or-write-your-own)
for the full framing.

The `localai-cli` examples require the CLI toolkit itself, shipped in
[../toolkit/](../toolkit/). See that folder's README to download and
install it, and [thisbrain.ai/locallm/cli.html](https://thisbrain.ai/locallm/cli.html)
for the full CLI reference.

Download LocalLM Lab from [its product page at https://thisbrain.ai/locallm](https://thisbrain.ai/locallm)
