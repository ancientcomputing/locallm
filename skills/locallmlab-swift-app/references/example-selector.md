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
- `examples/security-demo`: a Security panel driving both levers — which tools are in the session (`limited(toMaxImpact:)`) and whether a call asks first (`ConfirmingToolAuthorizer`, per-server approval) — against Calendar and a Todoist MCP server.
- `examples/mcp-chat`: a chat with a local model where an MCP server's own interactive view shows under the tool call (`MCPAppsHost`), with per-server trust and approval and the confirmation sheet.
- `examples/mlx-control-room`: every MLX setting with a gauge, and the model supply chain: validate, download, pin, update, roll back, clean up.
- `examples/components-updates-demo`: the Components model onboarding, update and versions views.
- `examples/vistanova`: a local search engine — web search through a Tavily MCP server with a hand-written `Tool` and a policy authorizer that allows only that tool, summaries from a pinned MLX model. VistaNova's releases are in its own project, https://github.com/ancientcomputing/vistanova.
- JevDK and jev-serve (their own project, https://github.com/ancientcomputing/jevdk; `examples/jevdk` and `examples/jev-serve` here only point there): JevDK is a SwiftUI playground for decision models (`lab.decide` across local `OpenJevDecisionProvider` (Inference) and hosted `JevDecisionProvider` (Remote), batch scoring against marked answers, `DecisionCalibration`, `DecisionQuestionSet` / `DecisionAnswerSet` export); jev-serve answers hosted Jev's API with OpenJev on this Mac and is the reference for `JevWire` on the server side. Use the JevDK repo for any decision-model integration; its guide is https://thisbrain.ai/locallm/jdk-guide.html.

Every example whose tools write or call an MCP server passes an authorizer; `docs/annotated-examples.md` ("Who decides whether a tool call runs") lists which one and why. Copy that line along with the rest of the shape.

## Toolkit Examples

- `examples/localai-cli`: Python subprocess examples using the toolkit rather than linking the SDK.
- `examples/localai-cli-swift`: Swift subprocess examples using the toolkit rather than linking the SDK.

Use the toolkit path when the app should depend on the LocalLM Lab helper process and avoid owning TCC, entitlements, MCP tokens, or SDK linking. Toolkit calls follow LocalLM Lab's Security panel (API Lab tool access); at Reads only every MCP call is refused. Use the SDK path when the app should be standalone and own its own permissions, MCP connections, Keychain state, and distribution path.

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
