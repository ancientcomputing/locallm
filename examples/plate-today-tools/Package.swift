// swift-tools-version: 6.0
import Foundation
import PackageDescription

// "What's on my plate today" — Tools edition. The public copy of the SDK's Path A reference app
// (this source is maintained privately and copied here, same as plate-today). Depends on Core as
// a BINARY (LocalLMLabSDKCore.xcframework via a GitHub Release asset), unlike the private source,
// which depends on Core directly — see plate-today's Package.swift for the fuller explanation of
// that one real difference the copy process accounts for.
//
// IMPORTANT: this example needs an SDK release that includes CalendarTools.swift/
// RemindersTools.swift/ContactsTools.swift/LocationTools.swift/MCPToolAdapter.swift (the
// ready-made FoundationModels Tools — see docs/sdk-guide.md §7a). As of this writing the latest
// published release is 0.7.1, which predates those files — building against 0.7.0 or 0.7.1 will
// fail to compile (`cannot find 'GetUpcomingEventsTool' in scope`, etc.), not run with reduced
// functionality. This file is published now, ahead of a release that actually contains the new
// Tools, so the source is available to read and diff against plate-today immediately; add the new
// version's entry to knownSDKReleases below once it ships, and this will build like any other
// example.

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
    NOTE: this example needs a release that includes CalendarTools/RemindersTools/ContactsTools/
    LocationTools/MCPToolAdapter (docs/sdk-guide.md §7a) — none of the versions above have those
    yet. It will fail to compile until a newer release is added to this file's knownSDKReleases.
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
            swiftSettings: swiftSettings
        )
    ]
)
