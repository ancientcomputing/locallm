# MCP client diagnostics

When a user reports that "connecting a server doesn't work" or "sign-in fails," you need to see
what the MCP client actually did. `LocalLMLabSDKCore` gives you two ways to look, both in
`enum MCPDiagnostics`.

- **Layer 1 — Apple's unified log.** Always available. Every connection step and failure is
  written with `os.Logger`; you read it back with `log stream`, `log show`, or Console.app. Good
  for you, on your own machine.
- **Layer 2 — an in-app buffer you can export.** Off by default. Turn it on and the same events
  are also kept in memory; call one method to get them back as text or JSON, already stripped of
  secrets. Good for a user who hits a problem and needs to send you something — no Console.app,
  no sysdiagnose.

One setting controls how much detail both layers record.

## One knob: `MCPDiagnostics.logLevel`

```swift
MCPDiagnostics.logLevel = .off       // nothing at all
MCPDiagnostics.logLevel = .error     // failures only
MCPDiagnostics.logLevel = .notice    // + things that recovered (a 401, a token refresh, a scope step-up)
MCPDiagnostics.logLevel = .info      // + the main milestones: connect, version negotiated, sign-in started   ← default
MCPDiagnostics.logLevel = .debug     // + every request: each JSON-RPC call, the discovery URLs, each SSE frame
```

Default is `.info`. Anything below the current level costs nothing — the message strings aren't
even built, so `.info` is fine to ship (about one line per "add server," nothing per request).
Use `.debug` while developing.

```swift
#if DEBUG
MCPDiagnostics.logLevel = .debug
#else
MCPDiagnostics.logLevel = .info      // or .error / .off if you want it quieter in release
#endif
```

If you want to turn a shipped build up without recompiling, read a preference or launch argument
at startup and set `logLevel` from it. LocalLM Lab does this — it honours a `MCPLogLevel`
user-defaults key:

```bash
defaults write <your.bundle.id> MCPLogLevel debug   # then relaunch
```

## Layer 1: reading Apple's unified log

- **subsystem:** `ai.thisbrain.locallmlab.sdkcore`
- **categories:** `MCP.connection`, `MCP.manager`, `MCP.oauth`, `MCP.stream`

```bash
# live:
log stream --predicate 'subsystem == "ai.thisbrain.locallmlab.sdkcore" AND category BEGINSWITH "MCP"' --level debug

# the last hour:
log show --last 1h --predicate 'subsystem == "ai.thisbrain.locallmlab.sdkcore" AND category BEGINSWITH "MCP"' --info --debug
```

Or in Console.app, filter on `subsystem:ai.thisbrain.locallmlab.sdkcore`. Note that `debug`-level
lines only show up with `--level debug` / `--debug` on the command, or after
`log config --subsystem ai.thisbrain.locallmlab.sdkcore --mode "level:debug"`.

## Layer 2: the exportable buffer

This is what you hand a user who can't get to Console.app. It's a bounded in-memory ring buffer
(about 500 events) that you switch on, and export when something goes wrong.

```swift
import LocalLMLabSDKCore

// at startup — off by default:
MCPDiagnostics.setEnabled(true)
MCPDiagnostics.capacity = 500          // optional

// ... the user reproduces the problem ...

// wire these to a "Copy diagnostics" button, or attach to a support ticket:
let text = MCPDiagnostics.exportText()
let json = MCPDiagnostics.exportJSON()

MCPDiagnostics.clear()                 // optional — start fresh
```

`logLevel` and `setEnabled(_:)` are separate controls: the first is how much detail, the second
is whether the buffer keeps a copy. An event has to pass **both** to land in the buffer, so if
you're chasing a hard bug, set `logLevel = .debug` before asking the user to reproduce it.

You can also watch events as they happen — for your own log file, or a debug panel in your app.
The observer fires whether or not the buffer is enabled:

```swift
MCPDiagnostics.observer = { event in
    myLogger.log("\(event.area): \(event.message)")
}
```

`MCPDiagnosticEvent` is `Codable`, with `timestamp`, `level`, `area`, `message`, and a `fields`
dictionary.

### Secrets are removed before you see them

Access and refresh tokens, authorization codes, `code_verifier`, `client_secret`, and
`Authorization: Bearer` values are never handed to the logger in the first place, and anything
that slips into a message or a URL is scrubbed anyway (`Bearer ‹redacted›`, `code=‹redacted›`).
Where a credential has to be shown so two log lines can be matched up, only its last four
characters appear (`‹redacted:…abcd›`). The export is safe to paste into a ticket — but give it
a glance before sending it on.

## What each category logs

| Category | What you'll find there |
|---|---|
| `MCP.connection` | the protocol version offered and agreed, the server's name and capabilities; every method call (at `debug`); any non-2xx HTTP response with its content type; a 401 and the start of sign-in (with the `WWW-Authenticate` header); a 403 `insufficient_scope` and the scope step-up; a session id being issued; a personal access token being rejected |
| `MCP.manager` | `addServer` and its result (agreed version, tool count); a tool result whose structured data didn't match the tool's declared output schema |
| `MCP.oauth` | the protected-resource metadata fetch; which `.well-known` discovery URL resolved (or that none did); the choice between Dynamic Client Registration, CIMD, and a manual client id — and why CIMD was skipped if it was; the PKCE check; the browser being opened (endpoint, `client_id`, scope); an `iss` mismatch; the code coming back; the token-exchange HTTP status; whether a silent refresh worked; every failure with the server's actual (truncated, redacted) response |
| `MCP.stream` | each server-sent-event frame as it's classified — an inbound request (`elicitation/create` and the like), a notification, a result; a server error result; a stream that broke mid-request; a stream that ended without the result it was waiting for |

## The typical support flow

1. Ship with `logLevel = .info` and `MCPDiagnostics.setEnabled(true)`, plus a "Copy MCP
   diagnostics" button somewhere unobtrusive (it calls `exportText()`).
2. A user reports an MCP problem. If it's intermittent or auth-related, walk them through setting
   `MCPLogLevel` to `debug` (or whatever preference you wired up) and relaunching.
3. They reproduce it, click the button, paste the result into the report.
4. You read the `MCP.oauth` / `MCP.connection` lines and see exactly which call failed and what
   the server said.
