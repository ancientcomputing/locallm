// swift-tools-version: 6.0
import Foundation
import PackageDescription

// "What's on my plate today" — the SDK's reference app. Depends on Core as a BINARY
// (LocalLMLabSDKCore.xcframework via a GitHub Release asset), since Core itself never ships as
// source.

// MARK: - Which SDK version to build against

struct SDKRelease {
    let url: String
    let checksum: String
}

// `defaultSDKVersion` is the release this branch's examples build against with no setup — what
// "clone, open in Xcode, Run" uses. `knownSDKReleases` carries it plus the previous release.
// To build against a different published version: set LOCALLM_SDK_VERSION in your shell (works
// for `swift build` / CI, NOT inside Xcode — its package resolution ignores shell env vars), or
// edit `defaultSDKVersion` here. For a release not listed, add its entry — the URL follows the
// pattern below and the checksum is the `.sha256` file next to the zip on that GitHub release —
// or just replace the two strings in place.
let defaultSDKVersion = "2.0.0-dev"

let knownSDKReleases: [String: SDKRelease] = [
    "1.0.0-GA": SDKRelease(
        url: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-GA/LocalLMLabSDKCore-1.0.0-GA.xcframework.zip",
        checksum: "7d77a9c2e37dfb2f7925f01ed011262ee5a2aebc561a3ae7a93524acc0285b3e"
    ),
    "2.0.0-dev": SDKRelease(
        url: "https://github.com/ancientcomputing/locallm/releases/download/v2.0.0-dev/LocalLMLabSDKCore-2.0.0-dev.xcframework.zip",
        checksum: "532bc89ab6d877e565d93f87ec9a4058a484910a195b5436372d5ce12b55e74e"
    ),
]

func failManifest(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let requestedSDKVersion = ProcessInfo.processInfo.environment["LOCALLM_SDK_VERSION"] ?? defaultSDKVersion

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
    products: [
        // Vend the Core binary as a library product so the XcodeGen .xcodeproj variant
        // (project.yml) can depend on it by name. `swift build` doesn't need this.
        .library(name: "LocalLMLabSDKCore", targets: ["LocalLMLabSDKCore"])
    ],
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
