# LocalLM SDK Doc Map

Use these local files as the source of truth while working in this repository.

## Primary Docs

- `docs/quickstart.md`: a working SwiftUI chat in about 50 lines, and linking the SDK from an Xcode app project.
- `docs/sdk-guide.md` is the main developer guide: linking SDK modules, choosing SDK vs toolkit, the model layer
  (routes, sessions), connectors, Path A vs Path B, tool authorization, Workspace tools, `FileBackedTool`, MCP servers
  in a session, Components, App Sandbox and signing. It links out to the topic guides below.
- `docs/tool-authorizer.md`: who decides whether a tool call runs; the three ready-made authorizers; upgrading from 2.x.
- `docs/mcp-guide.md`: the MCP client — auth options, OAuth redirect wiring, tool results, elicitation, diagnostics.
- `docs/local-models-mlx.md`: open-weight models through `LocalLMLabSDKInference` — download, validate, pin, prompt cache.
- `docs/remote-providers.md`: online providers through `LocalLMLabSDKRemote` — GPT, Claude online, OpenRouter.
- `docs/decision-models.md`: decision models (Jev) and `lab.decide`.
- `docs/reference.md` is the narrative function and type reference. `docs/api-surface.md` is the generated public API
  inventory: use it to confirm names, signatures, enum cases and module boundaries before writing code.
- `docs/annotated-examples.md` contains annotated source for every reference app with SDK touchpoints marked inline,
  and which authorizer each one passes. Use it when the user wants to see how much SDK-specific code is needed, or when
  a source excerpt is easier than opening an example tree.
- Security: `docs/security-overview.md` (the short version), `docs/security-guide-for-hosts.md` (what the SDK does and
  what the app must do), `docs/security-model.md` (the assurance case).
- `docs/glossary.md`: every term in plain words.
- Migration: `docs/migrating-to-3.0.md` (2.x to 3.0: fail-closed sessions, loading never downloads, prefixed MCP tool
  names), `docs/migrating-to-2.0.md` (1.x to 2.0), `docs/migrating-to-1.0.md` (`0.8.x` to 1.0, non-frozen enum switches
  needing `@unknown default`).
- `docs/tested-models.md` is a point-in-time MLX model snapshot. Treat it as a starting point only;
  `MLXModelProvider.capabilityProbe` is authoritative for a user's chosen model.

## When the repo is not on disk

These paths are relative to the SDK repo. If the developer's project does not have it (or does not add it as an extra
directory), read the same files from the `3.0.0-GA` branch instead:
`https://raw.githubusercontent.com/ancientcomputing/locallm/3.0.0-GA/<path>`, for example `.../docs/api-surface.md`,
`.../docs/tool-authorizer.md` and `.../examples/mcp-chat/Sources/...`. `AGENTS.md` at the repo root lists the rules that are
easy to get wrong in 3.0.

## Public Site

The public site is `https://thisbrain.ai/locallm/`. Prefer local repo docs while editing code. Use the website when the user asks for public-facing wording, external links, or developer-facing copy that should match the published site. For decision models, `jev.html` is the plain-English introduction (with links to TypeSafe's, OpenRouter's and Featherless's own docs) and `jdk-guide.html` is the JevDK workflow.

## Common Local Search Terms

- Linking and module boundaries: `binaryTarget`, `LocalLMLabSDKCore`, `LocalLMLabSDKInference`, `LocalLMLabSDKClaude`, `LocalLMLabSDKRemote`, `LocalLMLabSDKComponents`, `LocalLMLabSDKMCPAppsHost`.
- Tool authorization: `ToolCallAuthorizer`, `ConfirmingToolAuthorizer`, `AllowingToolAuthorizer`, `FailClosedToolAuthorizer`, `ToolConfirmationPresenter`, `toolConfirmationSheet`, `ToolApproval`, `ImpactRatedTool`, `ToolImpact`, `setTrust`, `setToolApproval`.
- MCP: `MCPServerManager`, `lab.mcp`, `MCPAuthType`, `MCPOAuthFlow.redirectURI`, `MCPOAuthRedirectListener`, `MCPTool`, `MCPServerSnapshot`, `setToolEnabled`.
- Connectors: `CalendarAccess`, `RemindersAccess`, `ContactsAccess`, `LocationAccess`, `Connectors.requestAccess`.
- Model layer: `LocalLMLab`, `ModelProvider`, `SystemModelProvider`, `PCCModelProvider`, `MLXModelProvider`, `RemoteModelProvider`, `RouteName`, `LocalLMLabSession`, `makeSession`, `download`, `validate`, `pinnedRevisions`.
- Dynamic tools: `DynamicTools`, `ToolMatcher`, `ToolCatalog`, `ToolPlugin`, `ChatSetup`.
- Workspace: `WorkspaceAccess`, `WorkspaceTools`, `security-scoped bookmark`, `FileBackedTool`.
- Components: `MCPServerPickerView`, `MCPServerManagerObservable`, `ModelPickerView`, `AIModelsSettingsView`, `ToolConfirmationPresenter`.
- Decision models: `lab.decide`, `DecisionQuestion`, `DecisionProvider`, `OpenJevDecisionProvider`, `JevDecisionProvider`, `JevProviderConfig`, `pair(decision:generator:)`, `DecisionQuestionSet`, `DecisionAnswerSet`, `DecisionCalibration`, `evaluate(route:`.
