// swift-tools-version: 6.4
import Foundation
import PackageDescription

// os-matrix — the SDK's 26/27 reference example. ONE .macOS("26.0") build that runs on both macOS 26 and 27 — the
// canonical "register fewer providers on 26, one #available block, identical code after"
// pattern. See README.md for the four scenarios and the "Claude → separate 27-only target"
// recipe.
//
// Links Core + Inference as binaryTargets. Builds against `defaultSDKVersion`; LOCALLM_SDK_VERSION overrides from a shell.

struct SDKRelease {
    let coreURL: String
    let coreChecksum: String
    let inferenceURL: String
    let inferenceChecksum: String
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
    failManifest("error: Unknown LOCALLM_SDK_VERSION \"\(requested)\". Known: \(knownSDKReleases.keys.sorted().joined(separator: ", "))")
}

let package = Package(
    name: "OSMatrix",
    platforms: [.macOS("26.0")],
    targets: [
        .binaryTarget(name: "LocalLMLabSDKCore", url: sdk.coreURL, checksum: sdk.coreChecksum),
        .binaryTarget(name: "LocalLMLabSDKInference", url: sdk.inferenceURL, checksum: sdk.inferenceChecksum),
        .executableTarget(
            name: "OSMatrix",
            dependencies: ["LocalLMLabSDKCore", "LocalLMLabSDKInference"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path"])]
        )
    ]
)
