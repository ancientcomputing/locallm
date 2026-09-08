# LocalLM Lab SDK Doc Map

Use these local files as the source of truth while working in this repository.

## Primary Docs

- `docs/sdk-guide.md` is the main developer guide. Use it for linking SDK modules, choosing SDK vs toolkit, MCP auth, Keychain storage, connector setup, Path A vs Path B, model providers, Workspace tools, Components, App Sandbox, signing, and the narrative API reference.
- `docs/api-surface.md` is the generated public API inventory. Use it to confirm names, signatures, enum cases, and module boundaries before writing code.
- `docs/annotated-examples.md` contains full annotated source for every reference app with SDK touchpoints marked inline. Use it when the user wants to understand how much SDK-specific code is needed, or when a small source excerpt is easier than opening an example tree.
- `docs/migrating-to-1.0.md` covers `0.8.x` to `1.0` migration, beta caveats, non-frozen enum switches requiring `@unknown default`, and module split details.
- `docs/tested-models.md` is a point-in-time MLX model snapshot. Treat it as a starting point only; `MLXModelProvider.capabilityProbe` is authoritative for a user's chosen model.

## Public Site

The public site is `https://locallmlab.dev`. Prefer local repo docs while editing code. Use the website when the user asks for public-facing wording, external links, or developer-facing copy that should match the published site.

## Common Local Search Terms

- Linking and module boundaries: `binaryTarget`, `LocalLMLabSDKCore`, `LocalLMLabSDKInference`, `LocalLMLabSDKClaude`, `LocalLMLabSDKRemote`, `LocalLMLabSDKComponents`.
- MCP: `MCPServerManager`, `MCPAuthType`, `MCPOAuthFlow.redirectURI`, `MCPOAuthRedirectListener`, `MCPTool`.
- Connectors: `CalendarAccess`, `RemindersAccess`, `ContactsAccess`, `LocationAccess`, `Connectors.requestAccess`.
- Model layer: `LocalLMLab`, `ModelProvider`, `SystemModelProvider`, `PCCModelProvider`, `MLXModelProvider`, `RemoteModelProvider`, `RouteName`, `LocalLMLabSession`.
- Workspace: `WorkspaceAccess`, `WorkspaceTools`, `security-scoped bookmark`, `FileBackedTool`.
- Components: `MCPServerPickerView`, `MCPServerManagerObservable`, `ModelPickerView`, `AIModelsSettingsView`.
