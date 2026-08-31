// swift-tools-version: 6.4
import Foundation
import PackageDescription

// code-buddy — the public copy of the SDK's reference coding agent (source maintained
// privately, copied here). Unlike plate-today, this one links BOTH SDK binaries:
// LocalLMLabSDKCore.xcframework AND LocalLMLabSDKInference.xcframework (the MLX runtime —
// mlx-swift-lm + Metal statically linked, ~49 MB / ~11 MB zipped). Core source never leaves
// the private repo; Inference is a binary for the same reason.
//
// Set LOCALLM_SDK_VERSION explicitly, e.g. `LOCALLM_SDK_VERSION=1.0.0-beta.1 swift run CodeBuddy …`,
// or this manifest fails fast. Requires macOS 27 + Xcode 27 (the SDK's model layer is built on
// FoundationModels' `LanguageModel` protocol).

struct SDKRelease {
    let coreURL: String
    let coreChecksum: String
    let inferenceURL: String
    let inferenceChecksum: String
}

// The two xcframework assets live on ONE GitHub Release per version — always matched.
let knownSDKReleases: [String: SDKRelease] = [
    "1.0.0-beta.1": SDKRelease(
        coreURL: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-beta.1/LocalLMLabSDKCore-1.0.0-beta.1.xcframework.zip",
        coreChecksum: "0b4ab34e474d1acd725161cfb591cf3d862a7529fe7c9dbadf01eece3ad1590f",
        inferenceURL: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-beta.1/LocalLMLabSDKInference-1.0.0-beta.1.xcframework.zip",
        inferenceChecksum: "f68830ca5e342ceaf887200213187b7f62c78436eca3e78d4b078e4dd2e0a317"
    )
]

func failManifest(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard let requested = ProcessInfo.processInfo.environment["LOCALLM_SDK_VERSION"] else {
    failManifest("""
    error: LOCALLM_SDK_VERSION is not set.
    Set it to the LocalLM Lab SDK version to build against, e.g.:
        LOCALLM_SDK_VERSION=1.0.0-beta.1 swift run CodeBuddy <workspace-dir> "add a test"
    Known versions: \(knownSDKReleases.keys.sorted().joined(separator: ", "))
    """)
}
guard let sdk = knownSDKReleases[requested] else {
    failManifest("""
    error: Unknown LOCALLM_SDK_VERSION "\(requested)".
    Known versions: \(knownSDKReleases.keys.sorted().joined(separator: ", "))
    """)
}

let package = Package(
    name: "CodeBuddy",
    platforms: [.macOS("27.0")],
    targets: [
        .binaryTarget(name: "LocalLMLabSDKCore", url: sdk.coreURL, checksum: sdk.coreChecksum),
        .binaryTarget(name: "LocalLMLabSDKInference", url: sdk.inferenceURL, checksum: sdk.inferenceChecksum),
        .executableTarget(
            name: "CodeBuddy",
            dependencies: ["LocalLMLabSDKCore", "LocalLMLabSDKInference"],
            linkerSettings: [
                // A plain SwiftPM CLI executable gets no LC_RPATH; SwiftPM extracts the
                // xcframework slices next to the built binary, so point rpath there. A real
                // host .app has Xcode embed the frameworks and set this automatically.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path"])
            ]
        )
    ]
)
