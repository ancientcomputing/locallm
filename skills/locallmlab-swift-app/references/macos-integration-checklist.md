# macOS Integration Checklist

Use this checklist for native `.app` work involving LocalLM Lab SDK permissions, MCP OAuth, sandboxing, or distribution.

## Permissions And TCC

- Add every required Info.plist usage-description key for the connectors the app uses.
- Add the matching entitlements to the final signed app bundle.
- Calendar and Reminders both use the Calendar personal-information entitlement; do not invent a separate Reminders entitlement.
- Bare `swift run` is not a reliable test for permission-gated SwiftUI apps. Use a real signed `.app` path when testing TCC prompts.
- If changing sandbox status or permission setup after earlier local runs, consider whether stale TCC grants are hiding a missing prompt or entitlement issue.

## MCP OAuth

- Set `MCPOAuthFlow.redirectURI` to the app's own URL scheme before any MCP connection can start.
- Register that URL scheme in Info.plist.
- Route callbacks through `NSApplicationDelegate.application(_:open:)` and `MCPOAuthRedirectListener.shared.handleRedirect`.
- In SwiftUI apps, pair the AppDelegate callback path with `.handlesExternalEvents(matching: [])` on the `WindowGroup` to avoid extra windows opening on OAuth redirect.
- For manual OAuth-client setup instructions, make sure the external service is configured with this app's redirect URI, not a copied example scheme.

## App Sandbox

- Add `com.apple.security.app-sandbox` for Mac App Store style sandboxing.
- Add `com.apple.security.network.client` for MCP servers, online providers, model downloads, or anything else that reaches the network.
- For user-selected folders, use security-scoped bookmarks in the app layer; `WorkspaceAccess` and `WorkspaceTools` operate once the app has a valid URL.
- Test sandboxed bookmark persistence with a stable signing identity when possible.

## Signing

- The final outer `.app` bundle signing pass must include the required entitlements. Signing only the inner executable is not enough.
- Use the example packaging scripts as the baseline for Developer ID, Apple Development, ad-hoc local builds, and Mac App Store variants.
- Xcode project runs for permission-gated examples generally need a signing identity; a free Apple Development identity is enough for local testing.
- Use Xcode 27 beta / the expected `DEVELOPER_DIR` while the SDK depends on beta macOS SDK symbols.
