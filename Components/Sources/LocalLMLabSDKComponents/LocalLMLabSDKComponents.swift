import LocalLMLabSDKCore

// LocalLMLabSDKComponents — prebuilt SwiftUI pieces on top of LocalLMLabSDKCore's public API,
// consumed as a binary artifact (Core.xcframework), never as source (see Package.swift).
//
// - MCPServerManagerObservable: ObservableObject wrapper around Core's plain MCPServerManager.
// - MCPServerPickerView: add/list/reconnect/disconnect/remove MCP servers, all three auth types,
//   per-tool and per-resource enable/disable, prompts listing, and a "Save As…" text export.
// - MCPOAuthWaitingView: shown while an OAuth sign-in is in flight in the system browser.
// - MCPResourcesView / MCPPromptsView: read an enabled resource / expand an enabled prompt from a
//   connected server — the "extract value, not just plumbing" half of the MCP client, callback-
//   based so the host app decides what "attach"/"use" means for its own UI.
//
// Aggregate context-budget display (LocalLM Lab's own "Context budget" section, beyond the
// per-server counts already shown here) isn't here yet — see
// locallmlab-sdk/docs/07-release-roadmap.md phase 5's capability audit.
