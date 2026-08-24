# Plate Today (Tools)

The same app as [`plate-today`](../plate-today), rebuilt on the SDK's ready-made FoundationModels
Tools (`GetUpcomingEventsTool`, `GetUpcomingRemindersTool`, `MCPTool`, etc. — see
[`docs/sdk-guide.md` §7a](../../docs/sdk-guide.md#7a-two-paths-to-tool-calling-ready-made-tools-or-write-your-own))
instead of hand-writing a `Tool` struct per connector. Same UI, same prompt, same connectors —
diff [`Sources/PlateTodayTools/PlateTodayToolsApp.swift`](Sources/PlateTodayTools/PlateTodayToolsApp.swift)
against [`plate-today`'s `PlateTodayApp.swift`](../plate-today/Sources/PlateToday/PlateTodayApp.swift)
to see exactly what changes between "Path A" (this app) and "Path B" (plate-today) in real code,
not just prose. Every divergence is marked inline with a `DIFF FROM plate-today:` comment,
including the annotated walkthrough in
[`docs/annotated-examples.md`](../../docs/annotated-examples.md).

Requires macOS 26+ on Apple Silicon with Apple Intelligence enabled.

## Requires SDK 0.8.0+

`GetUpcomingEventsTool`/`RemindersTools`/`ContactsTools`/`LocationTools`/`MCPToolAdapter` shipped
in Core starting with `0.8.0` — building this example against `0.7.0`/`0.7.1` fails to compile
(`cannot find 'GetUpcomingEventsTool' in scope`), not "runs with less functionality." `0.8.0` and
later are fine.

## Getting the SDK

```bash
LOCALLM_SDK_VERSION=0.8.0 swift build
```

Same `LOCALLM_SDK_VERSION` mechanism as `plate-today` — see that example's README for the general
shape. Omitting it, or requesting a version this file doesn't know about, fails fast with a clear
error rather than resolving to some default.

## Real build: `packaging/build-and-sign.sh`

Same script shape as `plate-today`'s — Calendar/Reminders TCC prompts and the Todoist OAuth flow
both require a properly signed `.app`, not a bare `swift build` binary.

```bash
LOCALLM_SDK_VERSION=0.8.0 \
APP_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARIZE_APP=0 \
./packaging/build-and-sign.sh
```

Same environment variables as `plate-today`'s `build-and-sign.sh` (see that README's table), with
the `PLATETODAY_*` prefix replaced by `PLATETODAYTOOLS_*` (`PLATETODAYTOOLS_INCLUDE_LOCATION_WEATHER`,
`PLATETODAYTOOLS_INCLUDE_CONTACTS`, `PLATETODAYTOOLS_INCLUDE_TODOIST`, `PLATETODAYTOOLS_APP_SANDBOX`)
so both apps can be installed and configured side by side without their build-time flags colliding.

## Mac App Store build: `packaging/build-and-sign-mas.sh`

Same Apple Distribution + provisioning profile path as `plate-today`'s — see that example's README
and `docs/sdk-guide.md` §10d for the one-time Apple Developer Portal setup this assumes.

## What actually changes between this app and plate-today

Read the `DIFF FROM plate-today:` comments in `PlateTodayToolsApp.swift` for the full detail,
but in short:

- **No `TodaysEventsTool`/`TodaysRemindersTool`/`TodaysLocationTool`/`SearchContactsTool` structs.**
  Core's `GetUpcomingEventsTool()`/`GetUpcomingRemindersTool()`/`GetCurrentLocationTool()`/
  `SearchContactsTool()` are used directly — ~130 fewer lines, and the tool descriptions/argument
  names are the same ones LocalLM Lab's own app ships.
- **Connector access is requested up front, not lazily.** Path A's ready-made Tools don't call
  `requestAccess()` inside their own `call()` the way plate-today's hand-written ones do — this
  app requests Calendar/Reminders (and Location/Contacts, if built in) before ever building the
  tools array.
- **`MCPTool` replaces the hand-written `TodoistTasksTool`.** The tradeoff isn't just less code:
  plate-today's version pinned specific arguments (`overdueOption: "exclude-overdue"`) regardless
  of what the model asked for; `MCPTool` exposes Todoist's `find-tasks-by-date` tool exactly as the
  server defines it, so the prompt has to ask for "excluding anything overdue" explicitly instead.

## More

- [`docs/sdk-guide.md` §7a](../../docs/sdk-guide.md#7a-two-paths-to-tool-calling-ready-made-tools-or-write-your-own) —
  the prose version of the Path A vs Path B framing this pair of examples demonstrates.
- [`docs/annotated-examples.md`](../../docs/annotated-examples.md) — this app's full source with
  every SDK touchpoint marked, alongside plate-today's.
- [`plate-today`](../plate-today) — the Path B original this app is a twin of.
