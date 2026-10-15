// swift-tools-version: 6.4
import Foundation
import PackageDescription

// repo-qa-local — repo-qa's Deepwiki setup (server in lab.mcp), but the answer comes from a locally-run
// open-weight (MLX) model routed through the 1.0 model layer instead of Apple's on-device model.
// Like code-buddy, it links BOTH SDK binaries: LocalLMLabSDKCore.xcframework AND
// LocalLMLabSDKInference.xcframework (the MLX runtime — mlx-swift-lm + Metal statically linked).
//
// Builds against `defaultSDKVersion` below with no setup; LOCALLM_SDK_VERSION overrides from a shell (not Xcode).
// Requires macOS 27 + Xcode 27 (the model layer is built on FoundationModels' `LanguageModel`
// protocol). No Metal Toolchain needed — the prebuilt Inference xcframework bundles the compiled
// default.metallib; it's only required when building the SDK from source.

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
        coreChecksum: "8ca2eda6e62e605678d6d4cdb5791b9dc8ca7bc4a0845aa09cce3ec39b63ef55",
        inferenceURL: "https://github.com/ancientcomputing/locallm/releases/download/v2.1.0-GA/LocalLMLabSDKInference-2.1.0-GA.xcframework.zip",
        inferenceChecksum: "21ce035b3baca98c6f975110ed21537349d10cb1edcbb4a795677672881ae0c2"
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
    name: "RepoQALocal",
    platforms: [.macOS("27.0")],
    targets: [
        .binaryTarget(name: "LocalLMLabSDKCore", url: sdk.coreURL, checksum: sdk.coreChecksum),
        .binaryTarget(name: "LocalLMLabSDKInference", url: sdk.inferenceURL, checksum: sdk.inferenceChecksum),
        .executableTarget(
            name: "RepoQALocal",
            dependencies: ["LocalLMLabSDKCore", "LocalLMLabSDKInference"],
            linkerSettings: [
                // SwiftPM's Swift Build system (default in the Xcode 27 toolchain) gives a bare
                // executable target no LC_RPATH; SwiftPM extracts the xcframework slices next to
                // the built binary, so point rpath there. Same fix as code-buddy / repo-qa.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path"])
            ]
        )
    ]
)
