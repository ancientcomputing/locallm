// swift-tools-version: 6.0
import Foundation
import PackageDescription

// "What's on my plate today" — the public copy of the SDK's reference app (this source is
// maintained privately and copied here). Depends on Core as a BINARY (LocalLMLabSDKCore.xcframework
// via a GitHub Release asset), unlike the private source, which depends on Core directly — this
// is the one real difference the copy process has to account for, since Core itself never leaves
// the private repo.

// MARK: - Which SDK version to build against

// Deliberately NOT implicit, and deliberately NOT silently defaulted. This manifest previously
// baked in a single hardcoded url/checksum, which is how it ended up pointed at a draft release
// that 404s on an anonymous `swift build` (confirmed live), then at a TEMPORARY stand-in
// (ancientcomputing/locallm-staging) with a comment nobody was forced to actually read before
// building. Neither gave a developer honest, visible control over which SDK release they're
// pulling, or a clear failure when that choice was never made. Now: set LOCALLM_SDK_VERSION
// explicitly, e.g. `LOCALLM_SDK_VERSION=0.7.0 swift build`, or this manifest fails fast with a
// clear message instead of silently resolving to whichever version happened to be hardcoded.
struct SDKRelease {
    let url: String
    let checksum: String
}

// The source of truth for which SDK versions this Package.swift knows how to build against —
// add a new entry here whenever a new Core.xcframework release is published.
let knownSDKReleases: [String: SDKRelease] = [
    // TEMPORARY (2026-08-14): this repo's own v0.7.0 GitHub Release is still a draft, and GitHub
    // 404s an anonymous `swift build` download of a draft release's asset — confirmed live. Using
    // ancientcomputing/locallm-staging's real PUBLISHED v0.7.0 asset in the meantime (a separate,
    // public testing repo). Swap `url` below to
    // "https://github.com/ancientcomputing/locallm/releases/download/v0.7.0/LocalLMLabSDKCore-0.7.0.xcframework.zip"
    // once this repo's own v0.7.0 is published non-draft — that repo's draft was built BEFORE
    // Core gained exportSummary()/Contacts (2026-08-14), so `checksum` there is currently stale
    // too; re-derive both `url` and `checksum` from a fresh publish, don't assume this one
    // carries over.
    "0.7.0": SDKRelease(
        url: "https://github.com/ancientcomputing/locallm-staging/releases/download/v0.7.0/LocalLMLabSDKCore-0.7.0.xcframework.zip",
        checksum: "8853f891f782cb052dd49850e6490558ba68b21b6970a0e1b83d393ab50f8289"
    )
]

func failManifest(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard let requestedSDKVersion = ProcessInfo.processInfo.environment["LOCALLM_SDK_VERSION"] else {
    failManifest("""
    error: LOCALLM_SDK_VERSION is not set.
    Set it to the LocalLM Lab SDK version to build against, e.g.:
        LOCALLM_SDK_VERSION=0.7.0 swift build
    Known versions: \(knownSDKReleases.keys.sorted().joined(separator: ", "))
    """)
}

guard let sdkRelease = knownSDKReleases[requestedSDKVersion] else {
    failManifest("""
    error: Unknown LOCALLM_SDK_VERSION "\(requestedSDKVersion)".
    Known versions: \(knownSDKReleases.keys.sorted().joined(separator: ", "))
    """)
}

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
            url: sdkRelease.url,
            checksum: sdkRelease.checksum
        ),
        .executableTarget(
            name: "PlateToday",
            dependencies: ["LocalLMLabSDKCore"],
            swiftSettings: swiftSettings
        )
    ]
)
