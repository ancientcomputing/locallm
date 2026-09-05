// swift-tools-version: 6.4
import Foundation
import PackageDescription

// repo-qa-local — repo-qa's exact MCPTool setup, but the answer comes from a locally-run
// open-weight (MLX) model routed through the 1.0 model layer instead of Apple's on-device model.
// Like code-buddy, it links BOTH SDK binaries: LocalLMLabSDKCore.xcframework AND
// LocalLMLabSDKInference.xcframework (the MLX runtime — mlx-swift-lm + Metal statically linked).
//
// Set LOCALLM_SDK_VERSION explicitly, e.g.
//   LOCALLM_SDK_VERSION=1.0.0-beta.1 swift run RepoQALocal anthropics/claude-code "What is the plugin system?"
// Requires macOS 27 + Xcode 27 (the model layer is built on FoundationModels' `LanguageModel`
// protocol) and the Metal Toolchain (mlx-swift compiles Metal shaders).

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
    ),
    "1.0.0-beta.2": SDKRelease(
        coreURL: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-beta.2/LocalLMLabSDKCore-1.0.0-beta.2.xcframework.zip",
        coreChecksum: "e3e687e503d3c563e6548b472dc8eb415475f0402845e9b4a56c58c15105c974",
        inferenceURL: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-beta.2/LocalLMLabSDKInference-1.0.0-beta.2.xcframework.zip",
        inferenceChecksum: "728bc399a96a851f1e46c6f709684133f40dc09b067a0717e1898ab11156e8a8"
    ),
    "1.0.0-beta.3": SDKRelease(
        coreURL: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-beta.3/LocalLMLabSDKCore-1.0.0-beta.3.xcframework.zip",
        coreChecksum: "a276ab7bdbdaa2be64ccfda45e66eabeb22c33be3246a1bea53be8f5c8998592",
        inferenceURL: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-beta.3/LocalLMLabSDKInference-1.0.0-beta.3.xcframework.zip",
        inferenceChecksum: "d99aaa9fd703afe51bf9b6f5636819527ae001c5e07efe4e07159b824681dda2"
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
        LOCALLM_SDK_VERSION=1.0.0-beta.1 swift run RepoQALocal anthropics/claude-code "What is the plugin system?"
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
