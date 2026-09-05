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
    "0.7.0": SDKRelease(
        url: "https://github.com/ancientcomputing/locallm/releases/download/v0.7.0/LocalLMLabSDKCore-0.7.0.xcframework.zip",
        checksum: "8853f891f782cb052dd49850e6490558ba68b21b6970a0e1b83d393ab50f8289"
    ),
    "0.7.1": SDKRelease(
        url: "https://github.com/ancientcomputing/locallm/releases/download/v0.7.1/LocalLMLabSDKCore-0.7.1.xcframework.zip",
        checksum: "d165bc1fbed790ac2264502c0cfa16336b68d2d7d9d282964742bd8b73f08e21"
    ),
    "0.8.0": SDKRelease(
        url: "https://github.com/ancientcomputing/locallm/releases/download/v0.8.0/LocalLMLabSDKCore-0.8.0.xcframework.zip",
        checksum: "3a7369e3fbd88de0bcf5cbe2e0a4202b2b919b67c20f364fb8bb2572fd1b9703"
    ),
    "1.0.0-beta.1": SDKRelease(
        url: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-beta.1/LocalLMLabSDKCore-1.0.0-beta.1.xcframework.zip",
        checksum: "0b4ab34e474d1acd725161cfb591cf3d862a7529fe7c9dbadf01eece3ad1590f"
    ),
    "1.0.0-beta.2": SDKRelease(
        url: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-beta.2/LocalLMLabSDKCore-1.0.0-beta.2.xcframework.zip",
        checksum: "e3e687e503d3c563e6548b472dc8eb415475f0402845e9b4a56c58c15105c974"
    ),
    "1.0.0-beta.3": SDKRelease(
        url: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-beta.3/LocalLMLabSDKCore-1.0.0-beta.3.xcframework.zip",
        checksum: "a276ab7bdbdaa2be64ccfda45e66eabeb22c33be3246a1bea53be8f5c8998592"
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

// Build-time opt-in, default OFF — same shape as Location/Weather above, for the same kind of
// reason: Contacts isn't part of plate-today's daily-summary narrative (see SearchContactsTool's
// own comment), so it's an on-demand enrichment tool the model reaches for only if relevant, not
// a fourth thing checked every run — and defaulting it off avoids an extra TCC prompt for anyone
// just trying the default build. Set PLATETODAY_INCLUDE_CONTACTS=1 to include it.
let includeContacts = ProcessInfo.processInfo.environment["PLATETODAY_INCLUDE_CONTACTS"] == "1"

var swiftSettings: [SwiftSetting] = []
if includeLocationWeather { swiftSettings.append(.define("PLATETODAY_INCLUDE_LOCATION_WEATHER")) }
if includeTodoist { swiftSettings.append(.define("PLATETODAY_INCLUDE_TODOIST")) }
if includeContacts { swiftSettings.append(.define("PLATETODAY_INCLUDE_CONTACTS")) }

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
            swiftSettings: swiftSettings,
            linkerSettings: [
                // SwiftPM's Swift Build system (default in the Xcode 27 toolchain) gives a bare
                // executable target no LC_RPATH, so `@rpath/LocalLMLabSDKCore.framework/...`
                // resolves to nothing and the app aborts at launch ("no LC_RPATH's found").
                // The Core framework sits next to the executable — in `swift build` output and,
                // once packaged, in Contents/MacOS — so point rpath at @executable_path. Same
                // fix as code-buddy.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path"])
            ]
        )
    ]
)
