// swift-tools-version: 6.0
import Foundation
import PackageDescription

// "What's on my plate today" — Tools edition. The SDK's Path A reference app.
// Depends on Core as a BINARY (LocalLMLabSDKCore.xcframework via a GitHub Release asset) — see
// plate-today's Package.swift.
//
// Requires an SDK release that includes CalendarTools.swift/RemindersTools.swift/
// ContactsTools.swift/LocationTools.swift/MCPToolAdapter.swift (the ready-made FoundationModels
// Tools — see docs/sdk-guide.md §7a) — that's 0.8.0 and later. Building against 0.7.0/0.7.1 fails
// to compile (`cannot find 'GetUpcomingEventsTool' in scope`, etc.), not run with reduced
// functionality, since those versions predate the files this app depends on.

struct SDKRelease {
    let url: String
    let checksum: String
}

// The SDK release these examples build against with no setup — what "clone, open in
// Xcode, Run" uses. `knownSDKReleases` carries this plus the previous release. Build
// against another published version: set LOCALLM_SDK_VERSION in your shell (works for
// `swift build` / CI, NOT inside Xcode), or edit `defaultSDKVersion` here. For a
// release not listed, add its entry (URL + the `.sha256` next to the zip on the
// GitHub release) or just replace the strings in place.
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

let includeLocationWeather = ProcessInfo.processInfo.environment["PLATETODAYTOOLS_INCLUDE_LOCATION_WEATHER"] == "1"
let includeTodoist = ProcessInfo.processInfo.environment["PLATETODAYTOOLS_INCLUDE_TODOIST"] != "0"
let includeContacts = ProcessInfo.processInfo.environment["PLATETODAYTOOLS_INCLUDE_CONTACTS"] == "1"

var swiftSettings: [SwiftSetting] = []
if includeLocationWeather { swiftSettings.append(.define("PLATETODAYTOOLS_INCLUDE_LOCATION_WEATHER")) }
if includeTodoist { swiftSettings.append(.define("PLATETODAYTOOLS_INCLUDE_TODOIST")) }
if includeContacts { swiftSettings.append(.define("PLATETODAYTOOLS_INCLUDE_CONTACTS")) }

let package = Package(
    name: "PlateTodayTools",
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
            name: "PlateTodayTools",
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
