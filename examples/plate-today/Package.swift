// swift-tools-version: 6.0
import Foundation
import PackageDescription

// "What's on my plate today" — the public copy of the SDK's reference app (this source is
// maintained privately and copied here). Depends on Core as a BINARY (LocalLMLabSDKCore.xcframework
// via a GitHub Release asset), unlike the private source, which depends on Core directly — this
// is the one real difference the copy process has to account for, since Core itself never leaves
// the private repo.

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
let defaultSDKVersion = "1.0.0-beta.3"

let knownSDKReleases: [String: SDKRelease] = [
    "1.0.0-beta.2": SDKRelease(
        url: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-beta.2/LocalLMLabSDKCore-1.0.0-beta.2.xcframework.zip",
        checksum: "e3e687e503d3c563e6548b472dc8eb415475f0402845e9b4a56c58c15105c974"
    ),
    "1.0.0-beta.3": SDKRelease(
        url: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-beta.3/LocalLMLabSDKCore-1.0.0-beta.3.xcframework.zip",
        checksum: "a49b8bfcde340d8b86bf106d2af2cb9d84f3839a3bc1695016f3952a3fcdfb92"
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
