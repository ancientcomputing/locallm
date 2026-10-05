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
let defaultSDKVersion = "2.0.0-dev"

let knownSDKReleases: [String: SDKRelease] = [
    "1.0.0-GA": SDKRelease(
        coreURL: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-GA/LocalLMLabSDKCore-1.0.0-GA.xcframework.zip",
        coreChecksum: "7d77a9c2e37dfb2f7925f01ed011262ee5a2aebc561a3ae7a93524acc0285b3e",
        inferenceURL: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-GA/LocalLMLabSDKInference-1.0.0-GA.xcframework.zip",
        inferenceChecksum: "6fcbdd5b04fff709e720b92e8b7eda638014a4d19c0dd925e018b72cb7109430"
    ),
    "2.0.0-dev": SDKRelease(
        coreURL: "https://github.com/ancientcomputing/locallm/releases/download/v2.0.0-dev/LocalLMLabSDKCore-2.0.0-dev.xcframework.zip",
        coreChecksum: "c741066f04adf052c37202b5a857fbae5e68686a82f167b3af9a1fc565bb78eb",
        inferenceURL: "https://github.com/ancientcomputing/locallm/releases/download/v2.0.0-dev/LocalLMLabSDKInference-2.0.0-dev.xcframework.zip",
        inferenceChecksum: "79a393f494a9f865f3c039b1954eedbd7598bf77b3e50a786e83a297f1f6ed9e"
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
