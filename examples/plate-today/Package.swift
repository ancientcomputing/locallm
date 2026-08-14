// swift-tools-version: 6.0
import Foundation
import PackageDescription

// "What's on my plate today" — the public copy of the SDK's reference app (source lives
// privately at locallmlab-sdk's examples/plate-today; see that repo's docs/04-open-source-sync.md
// for the copy process). Depends on Core as a BINARY (LocalLMLabSDKCore.xcframework via a GitHub
// Release asset), unlike the private repo's copy which depends on Core as source — this is the
// one real difference the copy process has to account for, since Core itself never leaves the
// private repo.
//
// url/checksum below point at a DRAFT release (ancientcomputing/locallm's v0.7.0 — aligned with
// locallmlab-main/locallmlab-sdk's shared 0.7.x release train, not a separate SDK version line)
// — GitHub doesn't assign a draft's assets their final tag-based download path until the release
// is actually published; right now they live under a placeholder "untagged-<hash>" path that WILL
// change on publish. The checksum is content-based and stays valid regardless, but the url must
// be updated to the real "releases/download/v0.7.0/..." path once this release actually goes out
// — this file is not yet in its final, publishable state.

// Location (and, since it feeds off Location's result, Weather) is a build-time opt-in, default
// OFF — set PLATETODAY_INCLUDE_LOCATION_WEATHER=1 in the environment before building to include
// it. Location Services on a given Mac can be flaky (a real fix needed a rewritten timeout in
// Core's LocationAccess) and, unlike Calendar/Reminders/Contacts, its TCC grant can't be cleanly
// reset with `tccutil reset Location <bundle-id>` (a real macOS limitation — only
// `tccutil reset All` or manually removing it in System Settings works). Defaulting it off keeps
// the reference app's default QA loop fast and reliable; opt in explicitly when you specifically
// want to exercise Location.
let includeLocationWeather = ProcessInfo.processInfo.environment["PLATETODAY_INCLUDE_LOCATION_WEATHER"] == "1"

// Build-time opt-OUT, default ON (unlike Location/Weather above) — Todoist is core to what this
// app demonstrates (Core's MCP client + OAuth flow), so it stays in by default. The opt-out exists
// because `cleanUpBeforeQuit()` deliberately wipes the Todoist grant on every quit (see that
// method's doc comment — this is a dev/demo app, not meant to accumulate standing access), which
// means *every* launch re-triggers a fresh OAuth sign-in. That's fine for occasional use but hits
// Todoist's own rate limit fast during a rapid rebuild/relaunch QA loop. Set
// PLATETODAY_INCLUDE_TODOIST=0 to exclude it temporarily during that kind of loop.
let includeTodoist = ProcessInfo.processInfo.environment["PLATETODAY_INCLUDE_TODOIST"] != "0"

var swiftSettings: [SwiftSetting] = []
if includeLocationWeather { swiftSettings.append(.define("PLATETODAY_INCLUDE_LOCATION_WEATHER")) }
if includeTodoist { swiftSettings.append(.define("PLATETODAY_INCLUDE_TODOIST")) }

let package = Package(
    name: "PlateToday",
    platforms: [.macOS("26.0")],
    targets: [
        .binaryTarget(
            name: "LocalLMLabSDKCore",
            url: "https://github.com/ancientcomputing/locallm/releases/download/untagged-bf3ddf841dfc9442ae9f/LocalLMLabSDKCore-0.7.0.xcframework.zip",
            checksum: "7469f338d8c764d818b5ce2f0908a937db703522cd27d6255c0490550c44c274"
        ),
        .executableTarget(
            name: "PlateToday",
            dependencies: ["LocalLMLabSDKCore"],
            swiftSettings: swiftSettings
        )
    ]
)
