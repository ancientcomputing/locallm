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
let defaultSDKVersion = "1.0.0-RC.1"

let knownSDKReleases: [String: SDKRelease] = [
    "1.0.0-RC.1": SDKRelease(
        coreURL: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-RC.1/LocalLMLabSDKCore-1.0.0-RC.1.xcframework.zip",
        coreChecksum: "397e7b5f7efd1076293a3d5d06c41d75043bffa23cffdb821d71d21ee41e68de",
        inferenceURL: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-RC.1/LocalLMLabSDKInference-1.0.0-RC.1.xcframework.zip",
        inferenceChecksum: "e24cb0581807d37a7b595f0b198b9a9eeecc1c5c36fb59f61429b8a7b42dc169"
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
