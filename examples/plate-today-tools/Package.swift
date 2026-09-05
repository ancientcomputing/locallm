// swift-tools-version: 6.0
import Foundation
import PackageDescription

// "What's on my plate today" — Tools edition. The public copy of the SDK's Path A reference app
// (this source is maintained privately and copied here, same as plate-today). Depends on Core as
// a BINARY (LocalLMLabSDKCore.xcframework via a GitHub Release asset), unlike the private source,
// which depends on Core directly — see plate-today's Package.swift for the fuller explanation of
// that one real difference the copy process accounts for.
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
        LOCALLM_SDK_VERSION=0.8.0 swift build
    Known versions: \(knownSDKReleases.keys.sorted().joined(separator: ", "))
    NOTE: this example needs 0.8.0 or later — it depends on CalendarTools/RemindersTools/
    ContactsTools/LocationTools/MCPToolAdapter (docs/sdk-guide.md §7a), which 0.7.0/0.7.1 predate.
    """)
}

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
