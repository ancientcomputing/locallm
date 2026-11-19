# The MCP client guide

The MCP client in depth: connecting to a server, signing in, what a tool call returns, MCP Apps and diagnostics. The short version is in [the SDK guide](sdk-guide.md#mcp-servers); a safe first setup is on the [MCP page](https://thisbrain.ai/locallm/mcp-sdk.html).


> **What changed in 3.0:** resources and prompts in chat, richer tool results, paste-a-setup, per-app sign-in names, a
> 20,000-character cap on what the model sees of a result, and tools reaching the model as `<prefix>_<tool>`. The short
> list is in [the SDK guide](sdk-guide.md#mcp-servers); the sections below cover 3.0.
> Trust and review of servers is in [MCP security in your app](https://thisbrain.ai/locallm/mcp-security.html).

## Connecting to an MCP server: three auth options, and how to pick between them

> **Reach for this when** your app's pitch is "connect your own tools" — Todoist, GitHub,
> Linear, an internal MCP server — rather than you hardcoding every integration one by one.
> `MCPServerManager.addServer` discovers a server's tools at connect time and hands you back
> plain descriptors; *you* decide which become model tools ([The MCP client API](#the-mcp-client-api), [Two paths to tool-calling](sdk-guide.md#two-paths-to-tool-calling-ready-made-tools-or-write-your-own)). The auth handling below
> is the entire reason connecting isn't a one-liner: a server needs no auth, a static token,
> or a browser OAuth round-trip, and you usually can't tell which up front.
>
> **Examples that use it:** [`plate-today`](../examples/plate-today/) /
> [`plate-today-tools`](../examples/plate-today-tools/) (Todoist over OAuth),
> [`repo-qa`](../examples/repo-qa/) (DeepWiki, `.none`),
> [`components-demo`](../examples/components-demo/) (all three auth types, via
> `Components`' `MCPServerPickerView`).

Adding an MCP server involves one of three auth types, exposed as `MCPAuthType`. `Components`'
`MCPServerPickerView` (see [Components](sdk-guide.md#components-prebuilt-swiftui-mcp-servers--the-model-layer)) already builds a UI over all three if you'd rather not build
your own — this section explains what each requires, either way.

| `MCPAuthType` | Real-world example | What your UI must collect |
|---|---|---|
| `.none` | Notion, Todoist, Linear-shaped servers | Nothing up front — just the server URL; if the server uses OAuth with Dynamic Client Registration, the client detects it and runs the sign-in itself |
| `.pat` | Static-bearer-token servers (e.g. GitHub-shaped) | A text field for the user's token |
| `.oauthManual` | Servers with no Dynamic Client Registration (e.g. Slack-shaped) | A text field for a pre-registered OAuth client ID |

### OAuth redirect URI — MUST set this yourself (if your server uses OAuth)

> **Reach for this when** any MCP server you'll connect to might use OAuth — set this before your
> first `connect`/`addServer` call, not after one fails.
>
> **Examples that use it:** [`plate-today`](../examples/plate-today/) /
> [`plate-today-tools`](../examples/plate-today-tools/) (Todoist) and
> [`components-demo`](../examples/components-demo/).

If you connect to any MCP server that uses OAuth (most hosted MCP servers do — e.g. Todoist), you
**must** set `MCPOAuthFlow.redirectURI` to your own app's URL scheme before calling `connect`:

```swift
MCPOAuthFlow.redirectURI = "yourapp://oauth/callback"
```

And register that scheme in your Info.plist:

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLName</key><string>com.yourcompany.yourapp.oauth</string>
    <key>CFBundleURLSchemes</key>
    <array><string>yourapp</string></array>
  </dict>
</array>
```

**Do not skip this or reuse the SDK's own default scheme.** `redirectURI` defaults to a
placeholder value for source compatibility — if you don't override it, your app's OAuth callback
either silently collides with any other app on the same Mac that also failed to override it (macOS
resolves a claimed URL scheme to exactly one app, arbitrarily, when more than one registers it), or
simply won't route back to your app at all.

Set `MCPOAuthFlow.clientMetadataURL` in the same spot if you're using CIMD instead of Dynamic
Client Registration — see [Client ID Metadata Documents](#cimd-skipping-dynamic-client-registration).

### Wire the OAuth callback through your AppDelegate, not SwiftUI's `.onOpenURL` (if your server uses OAuth)

> **Reach for this when** you're wiring the URL-scheme handling for the redirect from
> [the section above](#oauth-redirect-uri--must-set-this-yourself-if-your-server-uses-oauth) —
> needed the moment you register a custom `CFBundleURLSchemes` entry.
>
> **Examples that use it:** [`plate-today`](../examples/plate-today/) /
> [`plate-today-tools`](../examples/plate-today-tools/) and
> [`components-demo`](../examples/components-demo/).

```swift
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "yourapp" {
            MCPOAuthRedirectListener.shared.handleRedirect(url)
        }
    }
}

@main
struct YourApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup { ContentView() }
            // Without this, WindowGroup ALSO opens a new scene for the same open-URL event
            // AppDelegate already handled above — you'll see a second window pop up when the
            // OAuth browser redirects back. Confirmed live, more than once.
            .handlesExternalEvents(matching: [])
    }
}
```

If you use SwiftUI's `.onOpenURL` instead, you will get a second window/scene spawned every time a
user completes an OAuth sign-in — `WindowGroup` treats any open-URL event as a request for a new
scene instance unless told otherwise.

### It's not "figure out which of the three your target server needs and hardcode it"

`.none` is a safe **default first attempt for any server**, not a guess specific to no-auth
servers:

- If the server needs no auth at all, connecting with `.none` just succeeds.
- If the server supports OAuth (with *or* without Dynamic Client Registration), Core detects the
  401's `WWW-Authenticate: Bearer resource_metadata="..."` header itself and drives the entire
  browser-based flow — no prior knowledge required, no different code path from what the API
  reference below already shows.
- If DCR specifically isn't supported, Core doesn't fail generically — it surfaces the distinct
  `MCPServerError.oauthRegistrationNotSupported` case (deliberately not collapsed into a generic
  error), which is your app's cue to prompt for a manual client ID and retry the exact same
  `addServer` call with `authType: .oauthManual, manualClientID: "..."`.

So `.none` → `.oauthRegistrationNotSupported` → retry with `.oauthManual` is one reactive flow,
not two auth types you have to distinguish up front.

**The one case that genuinely can't be auto-detected: PAT.** A server that wants a static bearer
token and doesn't support OAuth at all just returns a bare 401 with no `resource_metadata`
param — which surfaces as the generic `MCPServerError.authorizationRequired`, indistinguishable
from "this server's OAuth is broken" or any other auth failure. There is no signal in the response
that says "I want a PAT." This is real prior knowledge only the target server's own documentation
can supply — your app (or your app's user) has to already know this before adding that particular
server.

**If an OAuth connection fails for a real, unexpected reason** (not one of the cases above),
`MCPServerError.serverError(_:)`'s message includes the real HTTP status code, URL, and response
body from whichever call in the flow actually failed — e.g. a live rate-limit response comes
through as `"HTTP 429 from https://.../oauth/register: {\"error\":\"Too many requests...\"}"`, not
an opaque failure with no way to tell what went wrong. Don't swallow or re-wrap this message in
your own UI; it's already the most specific information available.

### Recommended default strategy for your own "add server" flow

1. Always attempt `addServer(url:displayName:)` with `authType: .none` first, regardless of what
   the server is.
2. On `.failure(.oauthRegistrationNotSupported)`, prompt for a manual OAuth client ID and retry
   with `authType: .oauthManual, manualClientID:`.
3. Only offer a PAT text field as a fallback the user opts into deliberately (e.g. "this server
   needs an access token instead" as a manually-triggered alternative), not as something you try
   automatically — there's no failure signal that tells you to.

### The manual-OAuth-client gotcha: setup instructions must reference *your* redirect URI

If you write user-facing setup instructions for a Slack-shaped (`.oauthManual`) server — registering
an app and setting a redirect URL on the *server's* side — that redirect URL must be **your app's
own scheme** (`yourapp://oauth/callback`, from [the OAuth redirect URI section above](#oauth-redirect-uri--must-set-this-yourself-if-your-server-uses-oauth)). Copying another app's setup
instructions verbatim into your own documentation would silently misconfigure every user who
follows it — their server-side app would try to redirect back into the wrong app (or nowhere)
instead of yours.

### Which MCP revision the client speaks — and why you mostly don't have to care

> **Reach for this when** you're debugging why a field you expect (structured content,
> elicitation, icons) isn't showing up, or you're curious what a specific server can do — most
> integrations never need to read this.
>
> **Examples that use it:** every example that connects to a real server ([`repo-qa`](../examples/repo-qa/),
> [`plate-today-tools`](../examples/plate-today-tools/), [`components-demo`](../examples/components-demo/))
> negotiates a revision automatically; none of them reads `negotiatedProtocolVersion` directly in
> normal use.

MCP is versioned by date-stamped revisions. The client supports `2025-03-26`, `2025-06-18`,
`2025-11-25` and **`2026-07-28`**. You don't pick one. On `addServer` the client
first sends `server/discover`, the `2026-07-28` way of asking a server which revisions it speaks.
A server on the current revision answers, and the connection is **stateless**. Any older server
rejects that unknown method, and the client falls back to the `initialize` handshake, offering
`MCPProtocolVersion.clientPreferred` (`2025-11-25`). The two meet at the newest revision both
support, and your code is the same either way.

`2026-07-28` reworks the wire protocol, and the SDK absorbs all of it:

- **No session and no handshake.** Every request carries the protocol version and client
  capabilities itself, plus `Mcp-Method` / `Mcp-Name` headers that gateways can route on.
- **Server requests become retries (MRTR).** A tool that needs input mid-call no longer pushes
  `elicitation/create` down an open stream. It returns "input required", and the client asks
  your handler and re-sends the call with the answer. Your `MCPElicitationHandler`
  ([Server-initiated requests](#server-initiated-requests-elicitation-and-the-sampling--roots-seams)) is called
  exactly as before, on either revision. Multi-step flows are capped at 8 rounds. Your handler
  is asked once per refusal: after a `.cancel` the call ends without re-sending, and after a
  `.decline` a server that asks again gets "decline" without your handler being called. Either
  way `callTool` returns `.success` with `isError == true` and a sentence the model can read.
- **Live updates.** A stateless server that advertises `listChanged` gets one
  `subscriptions/listen` stream. When its tools, prompts or resources change, the manager
  re-lists them on its own (enabled flags are kept; a new tool stays off until the user accepts it, as [drift review](security-guide-for-hosts.md#4-servers-trust-approval-and-drift) describes) and
  `serverChanges` fires. No Reconnect needed.

What the negotiated revision changes is how much a server *can* hand you:

| Revision the server meets you at | What you get |
|---|---|
| `2025-03-26` | Tools, resources, prompts. Tool results are plain text. |
| `2025-06-18` | + structured tool results (`MCPToolResult.structuredContent`), `resource_link` results, elicitation, tool `title`s |
| `2025-11-25` | + icons, richer elicitation field types, URL-mode elicitation |
| `2026-07-28` | + stateless transport, elicitation via MRTR, live tool/prompt/resource updates |

`MCPServerState.negotiatedProtocolVersion` tells you where a given connection landed (`nil`
until connected; `.isStateless` is true for `2026-07-28`). `MCPServerState.liveUpdates` is
`.active(…)`, `.reconnecting` or `.unavailable(reason)` for a stateless server and `nil`
otherwise. You rarely read either. The point of the table is that newer fields on
`MCPToolResult` and the elicitation seam below are simply empty or never called against an older
server. They are not errors to guard.

**Servers the client refuses.** A `2024-11-05` server, or one on the old two-endpoint HTTP+SSE
transport, fails `addServer` with `.protocolMismatch` (since 2.0; see [Migrating to 2.0](migrating-to-2.0.md)).

**Two knobs on `MCPSettings`, both rarely needed:**

```swift
let mcp = MCPSettings(
    versionNegotiation: .auto,   // default. .legacy = never send server/discover (2025 handshake only);
                                 // .pin(.v2026_07_28) = stateless only, no fallback
    liveUpdates: true            // default. false = no subscriptions/listen streams
)
// pass as LocalLMLab.Configuration(…, mcp: mcp). An app without LocalLMLab passes the same
// two arguments to MCPServerManager(versionNegotiation:liveUpdates:).
```

Use `.legacy` if a server mishandles the `server/discover` probe (for example, it hangs instead
of rejecting it). The client already falls back on a timeout, so this only saves the wait. Use
`liveUpdates: false` when your app shows a fixed tool list and must not change it mid-session.

### What a tool call gives you back: `MCPToolResult`

> **Reach for this when** you're calling `manager.callTool` directly instead of going through
> `MCPTool`/`FileBackedTool` ([Two paths to tool-calling](sdk-guide.md#two-paths-to-tool-calling-ready-made-tools-or-write-your-own),
> which already read this for you) — e.g. inside your own hand-written `Tool` adapter.
>
> **Examples that use it:** [`plate-today`](../examples/plate-today/)'s `TodoistTasksTool` calls
> `manager.callTool` directly and switches on the result.

`manager.callTool(server:tool:arguments:)` returns `Result<MCPToolResult, MCPServerError>`. The
`MCPServerError` side is a transport/protocol failure (unreachable, malformed, auth needed). A
tool that *ran* but reported a problem is **not** an error — it's `.success` with
`isError == true`.

```swift
switch await manager.callTool(server: state.id, tool: "search", arguments: ["q": .string("mcp")]) {
case .success(let result):
    let forTheModel = result.renderedForModel   // compact rendering sized for a model's context —
                                                // folds in structuredContent, resource links, the
                                                // error flag, and a truncation note. The one line
                                                // you need in most cases.
    result.text                // human-readable text block, if any
    result.structuredContent   // MCPValue? — JSON the server marked as structured data
    result.resourceLinks       // [MCPResourceLink] — uri/title/mimeType pointers, not fetched
    result.isError             // tool signalled failure; renderedForModel prefixes "Error: "
    result.truncated           // response hit MCPResponseLimits and was cut
case .failure(let error):
    // transport/protocol only
}
```

`MCPTool` / `FileBackedTool` ([Two paths to tool-calling](sdk-guide.md#two-paths-to-tool-calling-ready-made-tools-or-write-your-own)) already call `renderedForModel` for you — this matters only
when you call `manager.callTool` directly. `structuredContent` is validated against the tool's
declared `outputSchema` first; a mismatch is turned into `isError`.

### Server-initiated requests: elicitation (and the sampling / roots seams)

> **Reach for this when** a server you connect to might need something from the user mid-call —
> a missing field, a confirmation — rather than failing the tool call outright. Skip this if
> every server you use is fully self-contained (no `elicitation/create` calls).
>
> **Examples that use it:** none of the SDK's example apps wire elicitation up yet — see
> [the elicitation UI page](https://thisbrain.ai/locallm/mcp-elicitation.html) for it live in
> LocalLM Lab itself, or `MCPElicitationPresenter`'s doc comment for the Components-side pattern
> below.

Three MCP features let the server send *the client* a request mid-operation:

- **elicitation** — "I need more from the user to finish this tool call" (a missing field, a
  confirmation, which workspace). `2025-06-18`+.
- **sampling** — "run this prompt through your model for me."
- **roots** — "which filesystem roots may I see?"

The SDK implements none of them. Each is a **handler seam**: supply a conforming type or the
capability is never advertised and a well-behaved server never asks.

```swift
let manager = MCPServerManager(
    handlers: MCPClientHandlers(elicitation: elicitation)   // sampling:, roots:, logging: also here
)
```

**Elicitation is the one to wire**, and `LocalLMLabSDKComponents` ships the whole SwiftUI form:

```swift
import LocalLMLabSDKComponents

@StateObject private var elicitation = MCPElicitationPresenter()   // : MCPElicitationHandler

var body: some View {
    MyContent().mcpElicitationSheet(elicitation)                   // attach once, near the root
}

let manager = MCPServerManager(handlers: MCPClientHandlers(elicitation: elicitation))
```

When a server raises `elicitation/create`, a sheet appears naming the server, renders a typed,
validated form from the requested schema, and returns the user's `accept` / `decline` /
`cancel`. See [the elicitation UI page](https://thisbrain.ai/locallm/mcp-elicitation.html).

**Try it live, in under a minute, without writing any code** — LocalLM Lab itself already wires
up this exact form. In the app's MCP Servers panel, Add Server with URL
`https://example-server.modelcontextprotocol.io/mcp`, any name, Auth: None; Add opens a browser
to a generic consent screen — approve it. Once connected, enable only the `elicitInputs` tool
(toggle the other eight off — keeps the context budget clean and the model from wandering off to
call something else instead), then in Prompt Playground ask it to "Call the elicitInputs tool."
The sheet appears with a mix of field types; its header names whatever the server calls itself
(≈ "example-servers/everything is asking for input"). Confirmed live, 2026-09-12.

Your own UI or a headless policy: conform to `MCPElicitationHandler` — one `async` method on an
`MCPElicitationRequest` (parsed `message`, typed `fields`, `serverName` / `serverURL`, optional
URL-mode `url`) → `MCPElicitationResponse`. `callTool` also takes `allowElicitation: Bool = true`
— pass `false` where there's no way to show a prompt (a background job) and the request is
declined cleanly instead of hanging.

On a `2026-07-28` server the same handlers are reached through MRTR rather than an in-stream
request ([MCP revisions](#which-mcp-revision-the-client-speaks--and-why-you-mostly-dont-have-to-care)),
and nothing in your code changes. The one visible difference: with `allowElicitation: false`
the client leaves elicitation out of that request's declared capabilities. A server that
requires it then fails the call outright (`.serverError`), where a `2025-11-25` server would
have received a decline.

**Sampling** has a security edge: a registered `MCPSamplingHandler` lets a server push a prompt
through your model. Your handler owns the human-in-the-loop approval; the SDK gives you the seam,
not the policy. Don't register it if you don't need it.

### CIMD: skipping Dynamic Client Registration

> **Reach for this when** you want a stable, self-described client identity on a server's OAuth
> consent screen instead of a fresh anonymous registration each time — a production-app upgrade,
> not a requirement. DCR (the default, no setup) already works for every `.none`/auto-OAuth
> server; skip this unless you specifically want CIMD's identity guarantee.
>
> **Examples that use it:** none of the SDK's example apps set `clientMetadataURL` — they all run
> on the zero-config DCR default.

The OAuth flow above relies on **Dynamic Client Registration** — the server issues a `client_id`
on the fly. Servers that don't support DCR are the `.oauthManual` path. **Client ID Metadata
Documents (CIMD)** are a newer alternative: your `client_id` *is* an HTTPS URL to a small static
JSON file describing your app — no per-server registration, no manual ID.

```swift
MCPOAuthFlow.clientMetadataURL = URL(string: "https://yourapp.example/mcp/client-metadata.json")
```

Set it once at startup, next to `MCPOAuthFlow.redirectURI`. When it's set *and* the server's
auth metadata advertises CIMD, the client registers with it; otherwise it falls back to DCR,
then `.oauthRegistrationNotSupported`. The document's `client_id` must equal its own URL and its
`redirect_uris` must contain your `redirectURI`. Optional — DCR stays the zero-config default;
CIMD is the upgrade for a production app that wants a stable, self-described identity on the
consent screen.

### Diagnostics when a user reports an MCP problem

> **Reach for this when** a user hits an MCP connection problem you can't reproduce locally and
> need them to send you something actionable — not something to wire up proactively for every app.
>
> **Examples that use it:** none of the SDK's example apps enable the diagnostics buffer; see
> [the MCP diagnostics doc](mcp-diagnostics.md) for the full support-flow writeup this section
> summarizes.

Two logging layers, both strictly off-content (never prompt/response text; bearer tokens and
auth codes redacted):

- **`os.Logger`**, always on, subsystem `ai.thisbrain.locallmlab.sdkcore` — Console.app /
  `log stream`, no code.
- **An opt-in in-memory buffer** you dump as text when someone hits a problem:

```swift
MCPDiagnostics.setEnabled(true)               // ring buffer, default 500 events
MCPDiagnostics.logLevel = .debug              // .debug / .info / .notice / .error / .off
// ... reproduce ...
let report = MCPDiagnostics.exportText()      // hand to support; also .exportJSON()
```

Gate `logLevel` on a hidden preference so a normal user runs at `.info` and you can talk them up
to `.debug` over a support channel; put a "Copy MCP diagnostics" button somewhere unobtrusive.

Full detail — every log category, what `MCPDiagnostics.observer` gives you, the redaction
guarantees, and the end-to-end support flow — is in
[the MCP diagnostics doc](mcp-diagnostics.md).

### MCP Apps: showing a server's interactive views

> **Reach for this when** a server you connect to ships a view with its tools (Todoist's task
> list, a dashboard) and you want it in your app's conversation.
>
> **Examples that use it:** [`mcp-chat`](../examples/mcp-chat/).

An **MCP App** is a small interactive view (HTML, `ui://` resource) a server provides alongside a
tool. The model never asks for a view: it picks a tool as usual, and if that tool's listing names a
view (`MCPToolDescriptor.app`), your app shows it under the call once it finishes, handed the
call's arguments and result. Three pieces:

1. **Say you can show views.** Servers only offer them to a client that declares support:

   ```swift
   let lab = LocalLMLab(configuration: .init(
       providers: [...],
       mcp: MCPSettings(handlers: MCPClientHandlers().advertisingMCPApps())))   // LocalLMLabSDKMCPAppsHost
   let session = try lab.makeSession(route: .chat, mcpAppHints: true, authorizer: authorizer)
   ```

2. **Render the view** for a finished call with `LocalLMLabSDKMCPAppsHost` (open source, a
   separate package built on Core's public API):

   ```swift
   import LocalLMLabSDKMCPAppsHost

   let cache = MCPAppWidgetCache()
   let resource = try await cache.fetch(resourceURI: record.app!.resourceURI, server: server,
                                        manager: lab.mcp, recordID: record.id)   // checked, cached by hash
   let controller = MCPAppViewController(
       resource: resource,
       tools: lab.mcp.servers[server]?.tools ?? [],
       backend: MCPAppsSessionBackend(session: session, manager: lab.mcp, server: server, instance: record.id),
       configuration: MCPAppsBridgeConfiguration(hostName: "My App", hostVersion: "1.0"),
       actions: .session(session, instance: record.id))   // ui/message, ui/update-model-context → the session
   MCPAppRecreation.deliver(record, to: controller)      // the call's arguments and result
   await controller.load()
   // SwiftUI: MCPAppView(controller: controller).frame(height: controller.contentHeight ?? 360)
   ```

3. **Keep many views in one conversation.** Each live view is a WebKit process (~100 MB).
   `MCPAppViewPool` keeps a few live (`limit`, default 3) and snapshots the rest
   (`snapshot(for:)`) until they're needed again. To show an old call again — after a relaunch,
   say — `MCPAppRecreation.revalidate(record, source:cache:)` decides: the current view with the
   stored result when the tool's output still has the same shape, `.needsRefresh` when it changed,
   view-only from the cache when the server can't be reached.

**What a view may do.** It runs in a sandboxed `WKWebView`: no network unless your
`MCPAppsSandboxPolicy` allows the hosts it declares, no camera, microphone or location. Its tool
calls go through the bridge's `MCPAppsBridgePolicy` and then — with `MCPAppsSessionBackend` —
through your session's authorizer as `ToolCallInitiator.app(instance:)`, recorded in
`hostTranscript` like the model's (tools the server marks app-only, such as a dashboard's polling,
are counted per view instead of recorded). Sending a message as the user (`ui/message`), sharing
context with the model (`ui/update-model-context`) and opening links are denied unless your
policy allows them. Shared context reaches the model with the next `respond` / `streamResponse`
turn — a turn run on `languageModelSession` doesn't send it ([Running a turn](sdk-guide.md#running-a-turn-and-when-to-use-languagemodelsession)). `ConfirmingToolAuthorizer` remembers the user's answer per view and tool, so a
polling view asks once (destructive calls ask each time).

**The sandbox, layer by layer.** A view is HTML and script from someone else's server, so
`MCPAppViewController` contains it in layers, each of which holds even if the one above it failed:

1. **CSP, declared ∩ allowed.** A server's `_meta.ui.csp` is a request, not a grant: the CSP
   actually served on the view's document is each declared origin list intersected with your
   `MCPAppsSandboxPolicy` (`allowedConnectOrigins`, `allowedResourceOrigins`,
   `allowedFrameOrigins`), so a server update can never widen what your app lets a view reach.
   With the default `.closed` policy that is `default-src 'none'`, `connect-src 'none'`,
   `frame-src 'none'`, plus `base-uri`, `form-action` and `object-src 'none'`; inline script and
   style run, nothing loads from the network. Server-supplied origins are validated strictly
   (`https://` / `wss://`, a DNS host, optional port) before they go into the header, and
   `baseUriDomains` is never granted. Read `controller.effectiveCSP` for what a view really got.
2. **A network block under the CSP.** A `WKContentRuleList` on the whole web view blocks every
   http(s), ws(s) and ftp load outside the effective origins — so even a mis-served CSP lets
   nothing out.
3. **A sandboxed iframe.** The view runs in an `<iframe sandbox="allow-scripts allow-forms">`
   inside a small relay page — the spec's arrangement: the view sees a normal `window.parent`, but
   runs in an opaque origin with no cookies or storage. `allowsSameOrigin: true` adds
   `allow-same-origin` for a trusted view that needs `localStorage`; it is off by default.
4. **Navigation pinned.** Every navigation — link click, redirect, frame — is cancelled unless it
   is one of this view's own `mcpapp://<token>/` pages. Popups and `target=_blank`, file pickers,
   camera and microphone, and `alert` / `confirm` / `prompt` are refused. A link the view wants
   opened goes through `ui/open-link` and your bridge policy.
5. **One message path.** The native side accepts messages only from the relay page, only
   JSON-RPC, and every request goes through `MCPAppsBridgePolicy` (and, for tool calls, your
   authorizer, as above).

The web view uses a non-persistent data store, so no cookies, cache or storage outlive it.
`isInspectable: true` makes it inspectable in Safari's Develop menu; use it in debug builds only.

## Keychain storage — automatic isolation, native API, sandbox-safe

> **You don't reach for this — you get it for free.** There is no "set up credential storage"
> step: `MCPServerManager` persists OAuth tokens and PATs to the Keychain for you, scoped to
> your bundle ID, through the native Security API (so it works under App Sandbox and on the
> Mac App Store). **Read this section only if** you're auditing what lands in the Keychain,
> shipping an unbundled CLI (isolation degrades — see the last paragraph), or want to confirm
> you really don't need to write this yourself.
>
> **Examples that rely on it:** every MCP example; `plate-today`'s Todoist OAuth is the one
> that exercises the token round-trip end to end.

`MCPOAuthTokenStore`/`MCPPATStore` scope their Keychain storage to `Bundle.main.bundleIdentifier`
automatically — you don't need to do anything for isolation between your app and any other app
linking Core on the same Mac.

Both stores also use the native Keychain Services API (`SecItemAdd`/`SecItemCopyMatching`/etc.)
directly, not a shell-out to a system command-line tool — safe to use from a sandboxed app
(including one distributed through the Mac App Store), where shelling out to system binaries is
unreliable or outright unavailable. Confirmed live under App Sandbox, not just by code review —
see [App Sandbox](sdk-guide.md#app-sandbox--building-for-the-mac-app-store).

The one thing to know: if `Bundle.main.bundleIdentifier` is `nil` (an unbundled CLI/test target,
not a real `.app`), storage falls back to a fixed, non-isolating string — this is expected and fine
for a dev-only CLI, but means a bare unbundled binary shares storage with any other bare binary.
Package as a real signed `.app` before relying on isolation.

## The MCP client API

> **This is the MCP client's mechanics** — connect, list tools, call a tool, observe state
> changes, tear down, plus resources and prompts. Use `MCPServerManager` directly when you're
> building your own server-management UI or a headless/CLI integration; if you want a
> ready-made UI over exactly this, `Components` ([Components](sdk-guide.md#components-prebuilt-swiftui-mcp-servers--the-model-layer)) wraps all of it. The **resources /
> prompts** methods at the end matter only for servers that expose readable content or
> prompt templates, not just tools.
>
> **Examples that use it:** [`repo-qa`](../examples/repo-qa/) is the smallest end-to-end use
> (connect → build tools → run a turn); [`components-demo`](../examples/components-demo/)
> additionally exercises resources and prompts.

An app that uses `LocalLMLab` doesn't make this: it uses `lab.mcp`, set up with
`LocalLMLab.Configuration(…, mcp: MCPSettings(…))` ([The model layer](sdk-guide.md#the-model-layer-models-routing-and-sessions)) —
`makeSession` takes MCP tools from `lab.mcp`, so a second manager would be invisible to it. The
calls below are the same on `lab.mcp`.

```swift
let manager = MCPServerManager()  // NOT a singleton — you own the instance

// Connect (discovery happens as part of this call)
let result = await manager.addServer(url: serverURL, displayName: "My Server")
switch result {
case .success(let state):
    print(state.tools.map(\.name))  // what's actually available
case .failure(let error):
    // .authorizationRequired, .oauthRegistrationNotSupported, .httpError(_), etc. — see
    // MCPServerError for the full set and what each implies about whether retrying makes sense.
}

// Call a tool -> Result<MCPToolResult, MCPServerError> (MCP tool results). A tool that ran but failed is
// .success with isError == true, not .failure.
let callResult = await manager.callTool(
    server: state.id, tool: "find-tasks-by-date",
    arguments: ["startDate": .string("today")]
)
if case .success(let result) = callResult { print(result.renderedForModel) }

// React to state changes (servers dict) without SwiftUI/Combine — Core has no UI-framework
// dependency at all
for await servers in manager.serverChanges {
    // ...
}

// Or, if you're in a SwiftUI app and want @Published-style reactivity, Components already ships
// this wrapper — MCPServerManagerObservable, see Components in the SDK guide — so you don't need to write it
// yourself unless you want to.

// Post-use
manager.disconnect(state.id)   // keep cached tool list, drop the live connection
manager.removeServer(state.id) // forget it entirely, clear its Keychain entries too
```

**On tool selection**: `manager.addServer` returns everything the server exposes; deciding which
tools to actually pass to your AI engine (context-budget management) is up to you in a static
session: the tools you enable are the tools the model sees. With `dynamicTools:` (3.0), a picker
chooses the tools for each message instead (see [Tools: available, not attached](sdk-guide.md#tools-available-not-attached-30)). Real servers can expose 40+ tools; don't naively pass all of them
into a `LanguageModelSession` without picking the ones your prompt actually needs. See
`MCPToolDescriptor.estimatedTokens` if you want to reason about this quantitatively, or use
`Components`' `MCPServerPickerView` ([Components](sdk-guide.md#components-prebuilt-swiftui-mcp-servers--the-model-layer)), which already builds a per-tool enable/disable UI
over exactly this.

**On trust, approval and changed tools** (new in 3.0): a server you add is **untrusted**. Every one of its tools counts as one that
may change data, so a call asks first, and the server's own `readOnlyHint` and `destructiveHint` are ignored until you say otherwise.
A session built with no authorizer fails closed, which refuses those calls (reads still run), so pass one that can ask:
`ConfirmingToolAuthorizer` for an app with a UI, `AllowingToolAuthorizer` only where no one is there to ask and you accept the tools
([the tool authorizer](tool-authorizer.md)). Set trust and approval on the manager, and decide what happens when a server's tools
change after the user accepted them:

```swift
manager.setTrust(.trusted, server: state.id)                        // believe its read-only / destructive labels
manager.setToolApproval(.ask(atOrAbove: .destructive, by: .user), server: state.id)
manager.setToolApproval(.allow, server: state.id, tool: "search")    // "Always allow this tool"

manager.driftPolicy = .standard                                      // .strict, .permissive, or your own
if let drift = manager.servers[state.id]?.pendingDrift {             // a change is waiting for the user
    // show drift.changes, then:
    manager.acceptDrift(server: state.id)                            // keep using it with the changes
    // or manager.rejectDrift(server: state.id)                      // turn the server off until reviewed
}
let saved = manager.snapshot()                                       // store it; manager.restore(from: saved) next launch
```

Drift is measured against the last tool list the user **accepted**, never the last one the SDK saw, so a change nobody accepted
is reported again on every connect. A rewritten description asks the user, a new tool stays off until accepted, a server that
reports a new name is blocked, and a tool relabeled as safer keeps its old rating until accepted (`DriftPolicy.standard`).
Restore the snapshot on launch so a pending change is never accepted by accident. Components' `ToolChangesCardView` and
`MCPServerPickerView` draw the review for you. Every decision goes to the audit stream (`lab.audit.events()`), which is the record
of who allowed what; `MCPDiagnostics` is the log for finding bugs, and its `MCP.drift` lines say when the SDK held something. The full
account, with the table of what each kind of change does, is in
[the security guide](security-guide-for-hosts.md#4-servers-trust-approval-and-drift); the short version for MCP is
[MCP security in your app](https://thisbrain.ai/locallm/mcp-security.html).

**On tool-calling from FoundationModels**: `MCPServerManager` itself hands you plain data
(`MCPToolDescriptor`, `callTool`). To give a tool to a model, either let `makeSession` add the
enabled MCP tools for you (each wrapped as `MCPTool`, a FoundationModels `Tool`), wrap a descriptor
yourself with `MCPTool(descriptor:manager:)`, or write your own thin adapter per tool, as
[the reference-app walkthrough](walkthrough-plate-today.md) does in Step 5. An adapter of your own decides
exactly which MCP tool maps to which FoundationModels `Tool`, with whatever argument-shaping logic
that tool's real schema needs. Either way, always inspect `MCPToolDescriptor.rawSchema` for a tool before
assuming its parameters.

**A real gotcha when writing a `Tool` that takes no meaningful input**: an empty, zero-property
`@Generable struct Arguments {}` is valid and correct — `ClockTool` in Core is a working example.
Don't add a required-but-unused placeholder field as a workaround for "the framework needs some
schema." FoundationModels sometimes calls a no-input tool with genuinely empty generated content,
and a required field with nothing to satisfy it fails to decode — confirmed live: this produced a
`GenerationError.decodingFailure` in a real tool call, not a hypothetical concern.

**On reading `GenerationError` failures**: `LanguageModelSession.GenerationError`'s default
`NSError` bridging is useless — `error.localizedDescription` (and string-interpolating the error
directly) always prints a generic wrapper like `"The operation couldn't be completed.
(...GenerationError error -1.)"` regardless of which case actually fired, and on-device failures
sometimes surface an opaque nested `com.apple.tokengeneration` error with no further detail either.
Core's `GenerationErrorDescription.describe(_:) async -> String` switches on the real case
(`.guardrailViolation`, `.decodingFailure`, `.exceededContextWindowSize`, `.refusal`, etc.) and
returns its `Context.debugDescription` instead, so a guardrail violation reads differently from a
context-window overflow instead of both looking identical:

```swift
do {
    let response = try await session.respond(to: prompt)
} catch {
    state = .failed(await GenerationErrorDescription.describe(error))
}
```

Also worth knowing: this generic `error -1` sometimes fires as a transient, prompt-independent
on-device hiccup — retrying the exact same request can succeed with no other change (see
`examples/plate-today/README.md`'s Troubleshooting section for a confirmed live instance). If it
persists across several retries, that's no longer this known transient case — use the description
above to find out which real `GenerationError` case is actually firing.

**On extracting more than just tools**: a connected server can also expose **resources** (readable
content, e.g. a document or dataset) and **prompts** (server-defined templates). `manager.
resourcesForSession()`/`.promptsForSession()` list what's currently enabled;
`manager.readResource(server:uri:)`/`manager.getPrompt(server:name:arguments:)` fetch the real
content. `Components`' `MCPResourcesView`/`MCPPromptsView` ([Components](sdk-guide.md#components-prebuilt-swiftui-mcp-servers--the-model-layer)) already build a UI over
both if you don't want to write your own.
