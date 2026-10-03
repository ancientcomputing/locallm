# Migrating to the LocalLM Lab SDK 2.0

2.0 is a **one-time breaking release**: every 2.x release after it is source compatible with
`2.0.0`, additive changes only until 3.0. It breaks for two reasons. Several APIs had grown a
second way to do the same thing; 2.0 keeps one. And tool authorization moved to where trust
actually lives, the MCP server.

Most apps change little. The usual `makeSession`, `respond`, `LocalLMLab.Configuration` and
`PendingToolCall` call sites compile unchanged. What you edit: tool authorization (§3), and a
`switch` over two MCP enums (§4). What behaves differently is in §5.

## 1. Platform: unchanged

`platforms: [.macOS("26.0")]`, Xcode 27 to build, macOS-27-only providers behind
`if #available(macOS 27, *)` — as in 1.0 ([`sdk-guide.md` §1a](sdk-guide.md)).

## 2. Point your manifest at the new release

Add `2.0.0` to your manifest's `knownSDKReleases` with the checksums from the release's
`.sha256` assets (tag `v2.0.0`), and build with:

```sh
LOCALLM_SDK_VERSION=2.0.0 swift build
```

## 3. Tool authorization: one authorizer, decided per server

In 1.0 an app wrote its policy as a closure (`ConfirmingToolAuthorizer`'s `requirement:`) or a
rule list (`RuleBasedToolAuthorizer`). In 2.0 the **MCP server** is the unit of trust, and you
state who may approve what where the tools come from:

```swift
lab.mcp.setTrust(.trusted, server: companyServer)            // believe its read-only / destructive labels
lab.mcp.setToolApproval(.allow, server: dashboardServer)      // never ask for this one
let authorizer = ConfirmingToolAuthorizer(channel: confirmations)   // the one authorizer
```

| 1.0 | 2.0 |
|---|---|
| `RuleBasedToolAuthorizer` (removed) | `ConfirmingToolAuthorizer` + per-server settings. `.confirm(atOrAbove: x)` → `hostTools: .ask(atOrAbove: x, by: .user)` for your own tools and `lab.mcp.setToolApproval(.ask(atOrAbove: x, by: .user), server:)` per server; `.confirmMCPTools` → nothing (an untrusted server asks by default); `.denyTool` / `.denyMCPTools` / `.deny(atOrAbove:)` / `.allowTool` → a `policy:` returning `.deny` / `.allow`, with those approvals routed `by: .policy`; the `confirm:` closure → a `ToolConfirmationChannel`. |
| `ConfirmingToolAuthorizer(channel:timeout:requirement:)` and `Requirement` (removed) | `ConfirmingToolAuthorizer(channel:policy:hostTools:timeout:)`. Move the closure into `policy:` (now `async`): `.allow` → `ToolPolicyDecision.allow`, `.confirm` → `.askUser`, `.deny(reason:)` → `.deny(reason:)`. To send every call to it: `hostTools: .ask(atOrAbove: .read, by: .policy)` and, per server, `setToolApproval(.ask(atOrAbove: .read, by: .policy), server:)`. Then move what settings can say (per-server "ask" / "don't ask") out of the policy. |
| `setTrustsToolAnnotations(true, server:)` / `trustsToolAnnotations(server:)` (removed) | `setTrust(.trusted, server:)`; `false` → `.untrusted`. Read it back from `MCPServerState.trust`. |
| `ConfirmingToolAuthorizer(channel:)` | Unchanged; the channel may now be `nil` for a host with no one to ask (calls that need a person are denied). |

The defaults match 1.0's default rule (ask before anything that may change data), with one
difference for trusted servers — see §5. Save each server's `trust` and `toolApproval` with your
server list (the manager doesn't persist them) and set them again after `restore(from:)`.
`MCPServerState` gained fields, so a state JSON you encoded yourself under 1.0 won't decode;
restore servers through `restore(from:)` instead. Full walkthrough:
[`sdk-guide.md` §7c](sdk-guide.md).

## 4. New cases on two MCP enums

`MCPProtocolVersion` gained `.v2026_07_28` and `MCPConnectionMode` gained `.stateless(_:)`. Both
are non-frozen; Swift 6 already requires `@unknown default` in a `switch` over them, so this only
affects code that silenced that error another way.

## 5. What behaves differently

- **A session's MCP tools follow `lab.mcp` between turns.** Turn a tool on, add a server, or
  change a server's trust, and the model has it on its next `respond` / `streamResponse` — same
  session, same conversation. 1.0 fixed them at `makeSession`. To keep a session on a fixed set of
  MCP tools, pass them in `tools:` with `includeMCPTools: false`.
- **A trusted server asks only before destructive tools** by default (1.0 asked before every
  change regardless of trust). To keep the 1.0 behavior:
  `lab.mcp.setToolApproval(.ask(atOrAbove: .mutate, by: .user), server:)`.
- **Tools an MCP server marks as only for its interactive view** (`_meta.ui.visibility` without
  `"model"`) are no longer offered to models, and `ui://` resources are left out of model-facing
  resource lists.
- **A widget's tool calls** (an MCP App view, §6) that need the user's answer ask once per view and
  tool; destructive calls and timeouts are asked again. Model calls are unchanged.

### MCP protocol

The client now speaks MCP `2026-07-28` and falls back to the `2025` handshake on its own
([`sdk-guide.md` §3a](sdk-guide.md#3a-which-mcp-revision-the-client-speaks--and-why-you-mostly-dont-have-to-care)).
Code needs no changes. What a user may notice:

- **`2024-11-05` servers are refused.** `addServer` fails with `.protocolMismatch`, where 1.x
  connected. Most servers of that era use the old two-endpoint HTTP+SSE transport, which the
  client never supported; 1.x failed on them with a confusing "HTTP 404". 2.0 detects that
  transport with one `GET` and reports `.protocolMismatch` instead. The oldest supported revision
  is `MCPProtocolVersion.minimumSupported` (`2025-03-26`).
- **`server/discover` is sent first.** With the default `versionNegotiation: .auto`, every
  connect probes for `2026-07-28` before `initialize`. A server on an older revision rejects the
  probe and the client falls back, so this is one extra request per connect. If a server
  mishandles the probe, use `MCPSettings(versionNegotiation: .legacy)` to skip it.
- **Elicitation is declared as `{"form":{},"url":{}}`** from `2025-11-25`, not `{}`. Strict
  servers read `{}` as form-only and refused URL-mode elicitation, so URL mode now works on
  them. Nothing to change unless you inspect the wire.
- **Tool lists can change mid-connection.** A `2026-07-28` server that announces changes gets
  them re-listed automatically, and `serverChanges` fires. A new tool arrives disabled; enabled
  flags on existing tools are kept. If your UI assumes a fixed list after `addServer`, either
  handle the update or set `MCPSettings(liveUpdates: false)`.
- **`allowElicitation: false`** on a `2026-07-28` server leaves elicitation out of the request's
  capabilities, and a server that requires it fails the call (`.serverError`). On a `2025`
  server the same call still gets a decline.

## 6. One way to do each thing

These compile unchanged in their usual form; they are listed so you know which declaration is the
one to use (and what to edit if your code referred to an old overload as a function value, or
passed `restoring:` before `tools:`).

| What | 2.0 |
|---|---|
| Make a session | One `makeSession(route:tools:instructions:restoring:includeMCPTools:mcpAppHints:options:authorizer:)`. Continue a saved conversation with `restoring:` (instead of `instructions:` — passing both traps). |
| Run a turn | `session.respond(to:options:fromAppInstance:)` / `streamResponse(to:options:fromAppInstance:)`. `languageModelSession` is the escape hatch: a turn run on it directly skips the chat history, `turnContext`, widget context, the MCP tool refresh and `retryOnContextOverflow` — table and when to still use it in [`sdk-guide.md` "Running a turn"](sdk-guide.md#running-a-turn-and-when-to-use-languagemodelsession). |
| Set up MCP | `lab.mcp`, configured with `LocalLMLab.Configuration(providers:state:mcp:)` and `MCPSettings` (handlers, response limits, version negotiation, live updates). An app that uses `LocalLMLab` doesn't make its own `MCPServerManager`; making one directly is for apps without `LocalLMLab`. |
| Describe a pending call | One `PendingToolCall` / `PendingToolCallSummary` initializer each; `initiator:` defaults to `.model`, `serverApproval:` to `nil`. |

## 7. What's new (opt in when you want it)

- **Building a chat app.** `session.hostTranscript` is the conversation as your UI shows it: the
  user's message as soon as it's sent, every tool call as a live record with its full result, the
  reply (`replyInProgress` while streaming) and the model's reasoning split from its answer. Plus
  `streamResponse(to:)`, `turnContext` (send the date and time with every message — a model has no
  clock), and saving and reopening a conversation with the model's memory of it
  (`makeSession(…, restoring:)`, `hostTranscript.archive()` / `restore(from:)`). See
  [`sdk-guide.md` "Building a chat app"](sdk-guide.md#building-a-chat-app--hosttranscript-streamresponse-turncontext).
- **MCP Apps.** Some MCP servers ship an interactive view with a tool — Todoist's task list. The
  new, open-source `LocalLMLabSDKMCPAppsHost` package shows it in the conversation when the model
  calls that tool, sandboxed, with the view's own tool calls going through your authorizer.
  Declare support with `MCPSettings(handlers: MCPClientHandlers().advertisingMCPApps())`.
  Reference app: [`examples/mcp-chat`](../examples/mcp-chat/); walkthrough
  [`sdk-guide.md` §3f](sdk-guide.md#3f-mcp-apps-showing-a-servers-interactive-views).
- **Per-server trust and tool approval** (§3), shown on each row of `Components`'
  `MCPServerPickerView`, which now also says when none of a server's tools are on.
- **MCP protocol `2026-07-28`**, the current revision. It is stateless: no session, no
  handshake, and requests that gateways can route by header. A tool that needs the user's input
  mid-call reaches your existing `MCPElicitationHandler` through multi-round-trip requests. A
  server can push tool, prompt and resource list changes, and the client applies them without a
  reconnect (`MCPServerState.liveUpdates` shows the status). All automatic; older servers keep
  working through the `2025` handshake. See
  [`sdk-guide.md` §3a](sdk-guide.md#3a-which-mcp-revision-the-client-speaks--and-why-you-mostly-dont-have-to-care).
