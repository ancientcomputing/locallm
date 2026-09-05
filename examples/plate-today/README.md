# Plate Today

**The idea.** Your plans for the day live in several apps at once — some meetings in Calendar, a
few things in Reminders, more tasks in an online to-do list. A local AI model can look at all of
them and write you one short summary, so you don't have to check each app and combine the answers
in your head. And because the model runs on your Mac, none of that personal data is sent anywhere.

**Plate Today** is a small SwiftUI app that does this for one question: *what's on my plate
today?* It reads today's events from **Calendar**, open items from **Reminders**, and tasks from
**Todoist** (via Todoist's MCP server), then asks Apple's on-device model to write the summary.
"Done" clears everything, including the Todoist sign-in — it's a demo, not something that should
keep access to your accounts after you close it.

**What it illustrates for SDK developers.** A native app that links `LocalLMLabSDKCore` directly
and feeds three real data sources into one model call — two Apple connectors (Calendar,
Reminders) and one MCP server with a real OAuth flow (Todoist). Nothing is mocked: real TCC
permission prompts, a real browser OAuth round trip, real on-device inference. This is the
**"Path B"** version, where you hand-write one `Tool` adapter per source;
[`plate-today-tools`](../plate-today-tools/) is the identical app rebuilt on the SDK's ready-made
Tools ("Path A") — diff the two to see what changes. The blow-by-blow of where each permission
prompt and the OAuth flow fire is in
[`docs/sdk-guide.md` §5](../../docs/sdk-guide.md#5-walking-through-a-reference-apps-user-experience-step-by-step).

## What you'll see

Running a signed build (`packaging/build-and-sign.sh`, below — the plain `swift run` can't get
real Calendar/Reminders/OAuth access):

1. **Launch.** macOS asks for **Calendar** then **Reminders** access — allow both.
2. **A browser window opens** for Todoist sign-in and consent (first run only; the token is
   reused after that, until you press Done).
3. **The model works for a few seconds**, then a plain-language paragraph appears: today's
   meetings, what's due, what's overdue — drawn from all three sources at once, not one at a time.
4. **Done** clears the screen and signs out of Todoist.

Requires macOS 27+ on Apple Silicon with Apple Intelligence enabled (currently the macOS 27 beta; Xcode 27 beta to build).

## Getting the SDK

This branch tracks `1.0.0-beta.3` — macOS 27 for everything except the on-device `system` model (macOS 26 floor). Build with the **Xcode 27 beta**
(`DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`) — a stable Xcode fails with
`'v27' is unavailable`. Nothing to download or unzip by hand — `Package.swift` requires an
explicit `LOCALLM_SDK_VERSION` and resolves `LocalLMLabSDKCore` as a binary dependency from there:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
LOCALLM_SDK_VERSION=1.0.0-beta.3 swift build
```

Omitting `LOCALLM_SDK_VERSION`, or setting an unknown version, fails fast with a clear error
listing the versions this copy knows about — see `Package.swift` itself for the current table.

## Quick dev-loop run (no signing, no TCC/OAuth)

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
LOCALLM_SDK_VERSION=1.0.0-beta.3 swift run
```

Fast, but **cannot** get real Calendar/Reminders access (no code signing means TCC denies bare CLI
binaries outright) and the OAuth redirect won't have a registered URL scheme to return to. Useful
for compiler-level iteration only. `TODOIST_MCP_URL` overrides the default `https://ai.todoist.net/mcp`
if you need to point at a different server for testing.

## Real build: `packaging/build-and-sign.sh`

The only way to actually exercise the Calendar/Reminders TCC prompts or the Todoist OAuth flow —
both require a properly signed `.app` with entitlements and Info.plist usage-description keys.

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
LOCALLM_SDK_VERSION=1.0.0-beta.3 \
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
| `DEVELOPER_DIR` | Yes (on macOS 27) | `/Applications/Xcode.app/Contents/Developer` | Must point at the Xcode 27 beta — the script does **not** auto-detect it, and a stable Xcode fails with `'v27' is unavailable`. |
| `PLATETODAY_INCLUDE_LOCATION_WEATHER` | No | `0` | Build-time opt-in for the Location + Weather tools. Off by default — Location Services can be flaky, and unlike Calendar/Reminders/Contacts, its TCC grant can't be cleanly reset with `tccutil reset Location <bundle-id>` (only `tccutil reset All` or a manual System Settings removal works). |
| `PLATETODAY_INCLUDE_CONTACTS` | No | `0` | Build-time opt-in for the Contacts connector (on-demand enrichment, not part of the default daily-summary flow — avoids an extra TCC prompt by default). |
| `PLATETODAY_APP_SANDBOX` | No | `0` | Build-time opt-in for an App Sandbox build (proof-of-concept for Mac App Store compatibility — see `docs/sdk-guide.md` §10 for what's confirmed working under sandbox). |

## Mac App Store build: `packaging/build-and-sign-mas.sh`

A parallel path — Apple Distribution signing + provisioning profile instead of Developer ID,
always-sandboxed, produces a signed `.pkg` via `productbuild` instead of a notarized `.dmg`. This
exact pipeline has been run for real: Transporter accepted the upload and the build cleared for
internal TestFlight testing.

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
LOCALLM_SDK_VERSION=1.0.0-beta.3 VERSION=1.0.0-beta.3 ./packaging/build-and-sign-mas.sh
```

`APP_SIGN_IDENTITY` (an "Apple Distribution" identity), `INSTALLER_SIGN_IDENTITY` (a "3rd Party
Mac Developer Installer"/"Mac Installer Distribution" identity — a genuinely different certificate
type from Apple Distribution), and `PROVISIONING_PROFILE` are all auto-discovered from your
keychain / `~/Library/Developer/Xcode/UserData/Provisioning Profiles/` if not set explicitly. See
`docs/sdk-guide.md` §10d for the one-time Apple Developer Portal setup this assumes (certificate,
App ID, provisioning profile). `PLATETODAY_INCLUDE_LOCATION_WEATHER`/`PLATETODAY_INCLUDE_CONTACTS`
work the same as above; `PLATETODAY_INCLUDE_TODOIST` (default `1`, included) is the build-time
opt-**out** if you want to build without a Todoist account.

## Trying the Contacts enrichment (opt-in)

By default plate-today checks Calendar, Reminders, and Todoist — a fixed set, all listed in the
prompt. The Contacts tool is different: it's registered but **not** in the prompt, so the model
only calls it *on its own* when a calendar event or reminder names a specific person and it
decides looking them up is useful (the tool's own description tells it when). This is the
example's point — a tool the model reaches for conditionally, with a permission it requests only
on first use, rather than up front.

**Build it in** — pass `PLATETODAY_INCLUDE_CONTACTS=1` to `build-and-sign.sh`; the script adds
the `NSContactsUsageDescription` string and the `com.apple.security.personal-information.addressbook`
entitlement for you:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
LOCALLM_SDK_VERSION=1.0.0-beta.3 \
APP_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARIZE_APP=0 PLATETODAY_INCLUDE_CONTACTS=1 \
./packaging/build-and-sign.sh
```

**Set up a run that will actually trigger it:**

1. In **Contacts.app**, make sure there's a person you can recognize in a summary — add one if
   needed, with a name plus an email, phone, or organization (those are what the tool returns).
2. In **Calendar.app**, create an event **for today** whose title names that person —
   e.g. *"Coffee with Jane Smith"* — or add them as an invitee.
3. Launch the signed build. Grant **Calendar** and **Reminders** at launch as usual — still no
   Contacts prompt yet.
4. While the model is working, a **"Plate Today would like to access your contacts"** prompt
   appears — because the model chose to look Jane up. Allow it.
5. The summary comes back enriched: *"…your 10am coffee with Jane Smith (jane@acme.com)…"*
   instead of just *"coffee with Jane Smith."*

If nothing on today's calendar names someone in your Contacts, the model won't call the tool and
you'll see no Contacts prompt — that's the expected on-demand behavior, not a failure.

**Reset the grant between runs** with
`tccutil reset AddressBook lab.locallm.sdk.reference.platetoday`.

## Troubleshooting

- Failure screen showing `FoundationModels.LanguageModelSession.GenerationError Code=-1 "(null)"`
  with an underlying `com.apple.tokengeneration` error (e.g. `Code=10`) — a generic on-device
  generation failure from FoundationModels itself, not a signing/TCC/OAuth problem (confirmed on a
  properly signed build via `build-and-sign.sh`, with Calendar/Reminders/Todoist access already
  granted). Confirmed transient: quitting and relaunching produced a normal summary on the very
  next attempt with no other change. The same generic `error -1` is also documented as transient
  in [`examples/localai-cli/README.md`](../localai-cli/README.md#troubleshooting)'s Troubleshooting
  section. If it persists across several retries, that's no longer this known transient case — as
  of SDK 0.7.1, the failure screen shows Core's `GenerationErrorDescription.describe(_:)` output
  instead of the raw error, so a retry that keeps failing will actually tell you which
  `GenerationError` case fired (guardrail violation, context window overflow, decoding failure,
  etc.) — see `docs/sdk-guide.md` §6's "On reading `GenerationError` failures" for the full list.

## More

- [`docs/sdk-guide.md`](../../docs/sdk-guide.md) — the full SDK guide, including entitlements,
  MCP auth types, Keychain storage, and the full API reference.
- [`docs/annotated-examples.md`](../../docs/annotated-examples.md) — this app's full source with
  every SDK touchpoint marked.
