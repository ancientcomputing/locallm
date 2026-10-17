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
let defaultSDKVersion = "2.1.0-GA"

let knownSDKReleases: [String: SDKRelease] = [
    "2.0.0-GA": SDKRelease(
        coreURL: "https://github.com/ancientcomputing/locallm/releases/download/v2.0.0-GA/LocalLMLabSDKCore-2.0.0-GA.xcframework.zip",
        coreChecksum: "5f9418a6879b22227afdf867cf474d426b93ae36d783d5a958efaae1e347681b",
        inferenceURL: "https://github.com/ancientcomputing/locallm/releases/download/v2.0.0-GA/LocalLMLabSDKInference-2.0.0-GA.xcframework.zip",
        inferenceChecksum: "d2ed4a02686aceab0edf4231ede55c924ea3ab273c7c5cab0bb02f4bda40a185"
    ),
    "2.1.0-GA": SDKRelease(
        coreURL: "https://github.com/ancientcomputing/locallm/releases/download/v2.1.0-GA/LocalLMLabSDKCore-2.1.0-GA.xcframework.zip",
        coreChecksum: "8d541e06f81d1586c959d6159a259c759853c88b2c68385ab28de493af6c5776",
        inferenceURL: "https://github.com/ancientcomputing/locallm/releases/download/v2.1.0-GA/LocalLMLabSDKInference-2.1.0-GA.xcframework.zip",
        inferenceChecksum: "77d3d1a1bae9df6de5955dfa945242c177cb129b4896c95befb81db6c923656f"
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
