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
        inferenceChecksum: "c054137e0605c2e8f514248b2eb55accdf8cf4d74f92a92d120cde9d28322c1b"
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
