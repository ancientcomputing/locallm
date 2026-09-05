# Plate Today (Tools)

**Plate Today (Tools)** is [`plate-today`](../plate-today) built a second way. Same app — it reads
your Calendar, Reminders, and Todoist and asks the on-device model for a summary of your day — but
it connects those data sources to the model differently. The two versions exist to be compared.

## Giving a model tools — Path A vs Path B

When you let an on-device model use the SDK, you can hand it **tools**: small pieces of code the
model is allowed to call to fetch data or take an action — read the calendar, query an online
service, and so on. Each tool carries a short text **description**; the model reads those
descriptions and decides for itself when to call a tool. Your app runs the call and passes the
result back to the model.

Before the model can use a data source, that source has to be wrapped in a tool. There are two
ways to do it, and this pair of examples is the same app built each way:

- **Path A — use the tools the SDK already ships.** For the common connectors, Core provides
  ready-made tools: `GetUpcomingEventsTool()`, `GetUpcomingRemindersTool()`, `MCPTool(...)` for
  any MCP server, and more — one line each. The SDK wrote both the code and the descriptions the
  model reads, and those descriptions are tuned from watching real on-device models get tool use
  wrong. Least code, least to get wrong. **← this app.**
- **Path B — write each tool yourself.** A small `Tool` struct per source, where you set the
  name, the arguments the model is allowed to pass, and the description. More code, but full
  control — for example, you can fix an argument's value so the model can't change it.
  **← [`plate-today`](../plate-today).**

Neither is the "real" one — Core ships both and an app can mix them. Because the two apps are
otherwise identical, you can diff
[`Sources/PlateTodayTools/PlateTodayToolsApp.swift`](Sources/PlateTodayTools/PlateTodayToolsApp.swift)
against [`plate-today`'s `PlateTodayApp.swift`](../plate-today/Sources/PlateToday/PlateTodayApp.swift)
and see exactly what Path A saves and what it costs — every difference is marked with a
`DIFF FROM plate-today:` comment. The longer prose version is
[`docs/sdk-guide.md` §7a](../../docs/sdk-guide.md#7a-two-paths-to-tool-calling-ready-made-tools-or-write-your-own);
[`docs/annotated-examples.md`](../../docs/annotated-examples.md) walks both apps' full source.

## What you'll see

Identical to `plate-today` (see [that README's "What you'll see"](../plate-today/README.md#what-youll-see)
for the same list). Running a signed build (`packaging/build-and-sign.sh`, below — a plain
`swift run` can't get real Calendar/Reminders/OAuth access):

1. **Launch.** macOS asks for **Calendar** then **Reminders** access — allow both. (If built with
   `PLATETODAYTOOLS_INCLUDE_CONTACTS=1`, it also asks for **Contacts** here — see below.)
2. **A browser window opens** for Todoist sign-in and consent (first run only; the token is
   reused until you press Done).
3. **The model works for a few seconds**, then a plain-language paragraph appears: today's
   meetings, what's due, what's overdue — from all sources at once, not one at a time.
4. **Done** clears the screen and signs out of Todoist.

Requires macOS 27+ on Apple Silicon with Apple Intelligence enabled (currently the macOS 27 beta; Xcode 27 beta to build).

## Requires macOS 27 + the Xcode 27 beta

This branch tracks `1.0.0-beta.3`. `Package.swift` is
`platforms: [.macOS("27.0")]`. Build with the **Xcode 27 beta**
(`DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`); a stable Xcode fails with
`'v27' is unavailable`. (The ready-made connector `Tool`s this example depends on first shipped
in `0.8.0`, but on macOS 27 you use `1.0.0-beta.3+`.)

## Getting the SDK

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
LOCALLM_SDK_VERSION=1.0.0-beta.3 swift build
```

Same `LOCALLM_SDK_VERSION` mechanism as `plate-today` — see that example's README for the general
shape. Omitting it, or requesting a version this file doesn't know about, fails fast with a clear
error rather than resolving to some default.

## Real build: `packaging/build-and-sign.sh`

Same script shape as `plate-today`'s — Calendar/Reminders TCC prompts and the Todoist OAuth flow
both require a properly signed `.app`, not a bare `swift build` binary.

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
LOCALLM_SDK_VERSION=1.0.0-beta.3 \
APP_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARIZE_APP=0 \
./packaging/build-and-sign.sh
```

Same environment variables as `plate-today`'s `build-and-sign.sh` (see that README's table), with
the `PLATETODAY_*` prefix replaced by `PLATETODAYTOOLS_*` (`PLATETODAYTOOLS_INCLUDE_LOCATION_WEATHER`,
`PLATETODAYTOOLS_INCLUDE_CONTACTS`, `PLATETODAYTOOLS_INCLUDE_TODOIST`, `PLATETODAYTOOLS_APP_SANDBOX`)
so both apps can be installed and configured side by side without their build-time flags colliding.

## Trying the Contacts enrichment (opt-in)

Like [`plate-today`](../plate-today/README.md#trying-the-contacts-enrichment-opt-in), this app has
an opt-in Contacts tool the model calls *on its own* when a calendar event or reminder names a
specific person — it's registered but never named in the prompt. Here it's Core's ready-made
`SearchContactsTool()` (Path A), not a hand-written one.

**The one behavioral difference from `plate-today`:** this app requests Contacts access **up
front**, alongside Calendar and Reminders, before it builds the tools array — so the Contacts
permission prompt appears **at launch**, not mid-run. (That's the Path A pattern in general —
`plate-today`'s hand-written tools each call `requestAccess()` lazily inside their own `call()`.)

**Build it in** — pass `PLATETODAYTOOLS_INCLUDE_CONTACTS=1` to `build-and-sign.sh`; it adds the
`NSContactsUsageDescription` string and the `com.apple.security.personal-information.addressbook`
entitlement for you:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
LOCALLM_SDK_VERSION=1.0.0-beta.3 \
APP_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARIZE_APP=0 PLATETODAYTOOLS_INCLUDE_CONTACTS=1 \
./packaging/build-and-sign.sh
```

**Set up a run that will actually trigger it:**

1. In **Contacts.app**, make sure there's a person you'll recognize in a summary — add one if
   needed, with a name plus an email, phone, or organization.
2. In **Calendar.app**, create an event **for today** whose title names that person —
   e.g. *"Coffee with Jane Smith"* — or add them as an invitee.
3. Launch the signed build. macOS asks for **Calendar**, **Reminders**, **and Contacts** at
   launch — allow all three.
4. When the summary comes back it's enriched: *"…your 10am coffee with Jane Smith (jane@acme.com)…"*
   instead of just *"coffee with Jane Smith"* — *if* the model chose to look Jane up. Nothing on
   today's calendar naming a contact means the tool goes uncalled and the summary is unchanged;
   that's expected.

**Reset the grant between runs** with
`tccutil reset AddressBook lab.locallm.sdk.reference.platetodaytools`.

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
