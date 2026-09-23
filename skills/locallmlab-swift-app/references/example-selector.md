# Example Selector

Pick the nearest reference app before inventing a new integration shape.

## SDK Examples

- `examples/repo-qa`: smallest CLI showing Apple's on-device model calling a live no-auth MCP server through `MCPTool`.
- `examples/repo-qa-local`: minimal model-layer plus `LocalLMLabSDKInference` example using an open-weight MLX model.
- `examples/os-matrix`: one macOS 26 deployment-target CLI that gates macOS 27 providers without source-level branching throughout the app.
- `examples/code-buddy`: full local coding-agent shape with model routing, Workspace tools, MCP, and host-owned process tools.
- `examples/plate-today-tools`: SwiftUI app using ready-made Path A tools for Calendar, Reminders, and Todoist MCP OAuth.
- `examples/plate-today`: same product idea as `plate-today-tools`, but with hand-written Path B tool adapters.
- `examples/workspace-buddy`: sandboxed SwiftUI app where the user picks a folder and the on-device model reads, creates, and edits files through Workspace tools.
- `examples/workspace-buddy-local`: sandboxed SwiftUI app combining Workspace tools with a downloadable MLX model.
- `examples/components-demo`: prebuilt Components UI for adding and managing MCP servers.
- `examples/model-switch`: Core plus Remote plus Components for online providers, API keys, model selection, web search, and citations.
- `examples/aiql`: SwiftUI "ask your data" app using MCP, `FileBackedTool`, data verbs, CSV output, sandboxing, and OAuth.

## Toolkit Examples

- `examples/localai-cli`: Python subprocess examples using the toolkit rather than linking the SDK.
- `examples/localai-cli-swift`: Swift subprocess examples using the toolkit rather than linking the SDK.

Use the toolkit path when the app should depend on the LocalLM Lab helper process and avoid owning TCC, entitlements, MCP tokens, or SDK linking. Use the SDK path when the app should be standalone and own its own permissions, MCP connections, Keychain state, and distribution path.

## Path A Vs Path B

Use Path A by default:

- Ready-made connector tools already include descriptions shaped by observed model behavior.
- `MCPTool` builds a `Tool` dynamically from a server's live MCP schema.
- Workspace tools cover the common read/write/edit operations.

Use Path B when the app needs:

- A custom tool name or description.
- A narrowed or transformed schema.
- Custom validation, filtering, or post-processing.
- A connector or MCP tool call that should be wrapped with app-specific semantics.

When comparing the two styles, diff `examples/plate-today-tools` against `examples/plate-today`.
