// swift-tools-version: 6.0
import Foundation
import PackageDescription

// VistaNova — a tiny local-first search engine: a SwiftUI .app built via project.yml/xcodegen
// (Apple on-device plus a downloadable MLX open-weight model, all local — no hosted providers).
// Like workspace-buddy-local and mlx-control-room, it links BOTH SDK binaries:
// LocalLMLabSDKCore.xcframework AND LocalLMLabSDKInference.xcframework (the MLX runtime). This
// manifest only vends those binaries as products for the Xcode project; the app's sources are built
// by the .xcodeproj, not by SwiftPM. Requires macOS 27 + Xcode 27.

struct SDKRelease {
    let coreURL: String
    let coreChecksum: String
    let inferenceURL: String
    let inferenceChecksum: String
}

// Both xcframework assets live on ONE GitHub Release per version — always matched.
// The SDK release this example builds against with no setup — what "clone, open in Xcode, Run" uses.
// Build against another published version: set LOCALLM_SDK_VERSION in your shell (works for
// `swift build` / CI, NOT inside Xcode), or edit `defaultSDKVersion` here. For a release not listed,
// add its entry (URL + the `.sha256` next to the zip on the GitHub release) or just replace the
// strings in place. Needs a release that includes `MLXModelProvider(pinnedRevisions:)` and
// `cancelDownload(_:)`: the checksums below are the 1.0.0-RC.1 binaries as re-published on
// 2026-09-19. An RC.1 pulled earlier fails the checksum check — re-resolve packages.
let defaultSDKVersion = "2.3.0-GA"

let knownSDKReleases: [String: SDKRelease] = [
    "2.2.0-GA": SDKRelease(
        coreURL: "https://github.com/ancientcomputing/locallm/releases/download/v2.2.0-GA/LocalLMLabSDKCore-2.2.0-GA.xcframework.zip",
        coreChecksum: "5efc40cae9f8a1bf53bfe03195c5365398bc9501b3e6b0feee3e5c67385537f4",
        inferenceURL: "https://github.com/ancientcomputing/locallm/releases/download/v2.2.0-GA/LocalLMLabSDKInference-2.2.0-GA.xcframework.zip",
        inferenceChecksum: "afd427fb741a820f55bc0a384850ae6404608f5ad73d185a583a89e8f0d61a61"
    ),
    "2.3.0-GA": SDKRelease(
        coreURL: "https://github.com/ancientcomputing/locallm/releases/download/v2.3.0-GA/LocalLMLabSDKCore-2.3.0-GA.xcframework.zip",
        coreChecksum: "7821197d0cf5b4c92e36af5c537295e594afbb55d60d2f98b0773a3625403575",
        inferenceURL: "https://github.com/ancientcomputing/locallm/releases/download/v2.3.0-GA/LocalLMLabSDKInference-2.3.0-GA.xcframework.zip",
        inferenceChecksum: "63dc8bcba5e91e1324809ca412a23ebb0b9e04386361436eacc0be9fe6d4a8e0"
    ),
]

func failManifest(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let requested = ProcessInfo.processInfo.environment["LOCALLM_SDK_VERSION"] ?? defaultSDKVersion
guard let sdk = knownSDKReleases[requested] else {
    failManifest("""
    error: Unknown LOCALLM_SDK_VERSION "\(requested)".
    Known versions: \(knownSDKReleases.keys.sorted().joined(separator: ", "))
    """)
}

let package = Package(
    name: "VistaNova",
    platforms: [.macOS("27.0")],
    products: [
        // Vend the binaries as library products so the XcodeGen .xcodeproj variant (project.yml)
        // can depend on them by name.
        .library(name: "LocalLMLabSDKCore", targets: ["LocalLMLabSDKCore"]),
        .library(name: "LocalLMLabSDKInference", targets: ["LocalLMLabSDKInference"])
    ],
    targets: [
        .binaryTarget(name: "LocalLMLabSDKCore", url: sdk.coreURL, checksum: sdk.coreChecksum),
        .binaryTarget(name: "LocalLMLabSDKInference", url: sdk.inferenceURL, checksum: sdk.inferenceChecksum),
    ]
)
