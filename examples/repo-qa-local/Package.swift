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
        coreChecksum: "20ac14db027cc3cc2075210a79e393201d95a6b5f8a24b400031e947454da30f",
        inferenceURL: "https://github.com/ancientcomputing/locallm/releases/download/v2.0.0-dev/LocalLMLabSDKInference-2.0.0-dev.xcframework.zip",
        inferenceChecksum: "e9ff0960f3cb2028023e550fc3f0e8621741bc92ae8c7ceac5c0ffd7fcc0fe88"
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
