# Plate Today

A minimal SwiftUI reference app built on the LocalLM Lab SDK: launch → request Calendar/Reminders
access → connect to Todoist's real hosted MCP server (OAuth) → ask Apple's on-device model for a
"what's on my plate today" summary → Done (which also clears the Todoist OAuth token, since this
is a dev/demo app that shouldn't accumulate standing access across runs).

It exercises the SDK's Calendar and Reminders connectors plus its MCP client — real OAuth, real
tool calls, real on-device inference, no mocking. For the full step-by-step walkthrough of what
happens at each stage (including where each TCC prompt and the OAuth browser flow actually fire),
see [`docs/sdk-guide.md` §5](../../docs/sdk-guide.md#5-walking-through-a-reference-apps-user-experience-step-by-step).

Requires macOS 26+ on Apple Silicon with Apple Intelligence enabled.

## Getting the SDK

Nothing to download or unzip by hand — `Package.swift` requires an explicit `LOCALLM_SDK_VERSION`
and resolves `LocalLMLabSDKCore` as a binary dependency from there:

```bash
LOCALLM_SDK_VERSION=0.7.0 swift build
```

Omitting it, or setting an unknown version, fails fast with a clear error listing the versions
this copy knows about — see `Package.swift` itself for the current table.

## Quick dev-loop run (no signing, no TCC/OAuth)

```bash
LOCALLM_SDK_VERSION=0.7.0 swift run
```

Fast, but **cannot** get real Calendar/Reminders access (no code signing means TCC denies bare CLI
binaries outright) and the OAuth redirect won't have a registered URL scheme to return to. Useful
for compiler-level iteration only. `TODOIST_MCP_URL` overrides the default `https://ai.todoist.net/mcp`
if you need to point at a different server for testing.

## Real build: `packaging/build-and-sign.sh`

The only way to actually exercise the Calendar/Reminders TCC prompts or the Todoist OAuth flow —
both require a properly signed `.app` with entitlements and Info.plist usage-description keys.

```bash
LOCALLM_SDK_VERSION=0.7.0 \
APP_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARIZE_APP=0 \
./packaging/build-and-sign.sh
```

### Environment variables

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `LOCALLM_SDK_VERSION` | Yes | — | Read by `Package.swift`, not the script itself — but `swift build` (which the script calls) fails without it. |
| `APP_IDENTITY` | Yes | — | Must match a valid codesigning identity in your keychain (`security find-identity -v -p codesigning`). `SIGN_IDENTITY` also works as a fallback name. |
| `VERSION` | No | `0.1.0` | Stamped into `CFBundleShortVersionString`/`CFBundleVersion`. |
| `NOTARIZE_APP` | No | `1` | Set to `0` to skip Apple notarization for fast local sign-and-test iteration. **The output isn't Gatekeeper-approved without notarization** (`spctl` rejects it) — fine for direct-launch testing, not for distribution. |
| `KEYCHAIN_PROFILE` | Only if `NOTARIZE_APP=1` | — | Created once via `xcrun notarytool store-credentials <profile-name>`. `NOTARY_PROFILE` also works as a fallback name. |
| `TEAM_ID` | No | — | Passed to `notarytool submit` if set; usually unneeded if your `KEYCHAIN_PROFILE` already implies one team. |
| `DEVELOPER_DIR` | No | `/Applications/Xcode.app/Contents/Developer` | Only needed with multiple Xcode installs. |
| `PLATETODAY_INCLUDE_LOCATION_WEATHER` | No | `0` | Build-time opt-in for the Location + Weather tools. Off by default — Location Services can be flaky, and unlike Calendar/Reminders/Contacts, its TCC grant can't be cleanly reset with `tccutil reset Location <bundle-id>` (only `tccutil reset All` or a manual System Settings removal works). |
| `PLATETODAY_INCLUDE_CONTACTS` | No | `0` | Build-time opt-in for the Contacts connector (on-demand enrichment, not part of the default daily-summary flow — avoids an extra TCC prompt by default). |
| `PLATETODAY_APP_SANDBOX` | No | `0` | Build-time opt-in for an App Sandbox build (proof-of-concept for Mac App Store compatibility — see `docs/sdk-guide.md` §10 for what's confirmed working under sandbox). |

## Mac App Store build: `packaging/build-and-sign-mas.sh`

A parallel path — Apple Distribution signing + provisioning profile instead of Developer ID,
always-sandboxed, produces a signed `.pkg` via `productbuild` instead of a notarized `.dmg`. This
exact pipeline has been run for real: Transporter accepted the upload and the build cleared for
internal TestFlight testing.

```bash
LOCALLM_SDK_VERSION=0.7.0 VERSION=0.7.0 ./packaging/build-and-sign-mas.sh
```

`APP_SIGN_IDENTITY` (an "Apple Distribution" identity), `INSTALLER_SIGN_IDENTITY` (a "3rd Party
Mac Developer Installer"/"Mac Installer Distribution" identity — a genuinely different certificate
type from Apple Distribution), and `PROVISIONING_PROFILE` are all auto-discovered from your
keychain / `~/Library/Developer/Xcode/UserData/Provisioning Profiles/` if not set explicitly. See
`docs/sdk-guide.md` §10d for the one-time Apple Developer Portal setup this assumes (certificate,
App ID, provisioning profile). `PLATETODAY_INCLUDE_LOCATION_WEATHER`/`PLATETODAY_INCLUDE_CONTACTS`
work the same as above; `PLATETODAY_INCLUDE_TODOIST` (default `1`, included) is the build-time
opt-**out** if you want to build without a Todoist account.

## More

- [`docs/sdk-guide.md`](../../docs/sdk-guide.md) — the full SDK guide, including entitlements,
  MCP auth types, Keychain storage, and the full API reference.
- [`docs/annotated-examples.md`](../../docs/annotated-examples.md) — this app's full source with
  every SDK touchpoint marked.
