// swift-tools-version: 6.4
import Foundation
import PackageDescription

// code-buddy — the SDK's reference coding agent. Unlike plate-today, this one links BOTH SDK binaries:
// LocalLMLabSDKCore.xcframework AND LocalLMLabSDKInference.xcframework (the MLX runtime —
// mlx-swift-lm + Metal statically linked, ~49 MB / ~11 MB zipped). Core never ships as
// source, only as a binary; Inference is a binary for the same reason.
//
// Builds against `defaultSDKVersion` below with no setup; LOCALLM_SDK_VERSION overrides from a
// shell (not Xcode). Requires macOS 27 + Xcode 27 (the SDK's model layer is built on
// FoundationModels' `LanguageModel` protocol).

struct SDKRelease {
    let coreURL: String
    let coreChecksum: String
    let inferenceURL: String
    let inferenceChecksum: String
}

// The two xcframework assets live on ONE GitHub Release per version — always matched.
// The SDK release these examples build against with no setup — what "clone, open in
// Xcode, Run" uses. `knownSDKReleases` carries this plus the previous release. Build
// against another published version: set LOCALLM_SDK_VERSION in your shell (works for
// `swift build` / CI, NOT inside Xcode), or edit `defaultSDKVersion` here. For a
// release not listed, add its entry (URL + the `.sha256` next to the zip on the
// GitHub release) or just replace the strings in place.
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
