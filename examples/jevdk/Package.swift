// swift-tools-version: 6.4
import Foundation
import PackageDescription

// JevDK — a playground for decision questions. Write noul, choice or score questions, run them
// on a local MLX model and on hosted Jev, and see the answer probabilities, the exact prompt or
// request, and a batch grid across many inputs. See README.md and GUIDE.md.
//
// Built entirely on the SDK's decision API: local runs use LocalLMLabSDKInference's
// `OpenJevDecisionProvider`, hosted runs LocalLMLabSDKRemote's `JevDecisionProvider` through
// `lab.decide`, and models are listed, checked and downloaded by `MLXModelProvider`. OpenJevKit
// holds the playground's own editor and display types.
//
// Links three SDK binaries, all from one GitHub Release per version: LocalLMLabSDKCore,
// LocalLMLabSDKRemote and LocalLMLabSDKInference (the MLX runtime). It doesn't use Components,
// so it declares Core itself. Same SDKRelease/knownSDKReleases/failManifest version gate as every
// other example here.
//
// Requires SDK 2.0.0-GA or later (the decision API is new in 2.0), macOS 27 + Xcode 27. No Metal
// Toolchain needed — the prebuilt Inference xcframework bundles the compiled default.metallib.

struct SDKRelease {
    let coreURL: String
    let coreChecksum: String
    let remoteURL: String
    let remoteChecksum: String
    let inferenceURL: String
    let inferenceChecksum: String
}

// The SDK release this example builds against with no setup. Build against another published
// version: set LOCALLM_SDK_VERSION in your shell (works for `swift build` / CI, NOT inside Xcode),
// or edit `defaultSDKVersion` here. For a release not listed, add its entry (URL + the `.sha256`
// next to each zip on the GitHub release) or just replace the strings in place. Only 2.0
// releases: this app does not build against 1.0.
let defaultSDKVersion = "2.0.0-GA"

let knownSDKReleases: [String: SDKRelease] = [
    "2.0.0-GA": SDKRelease(
        coreURL: "https://github.com/ancientcomputing/locallm/releases/download/v2.0.0-GA/LocalLMLabSDKCore-2.0.0-GA.xcframework.zip",
        coreChecksum: "246bad16b8a39dc72e037778d7e7128fe2742ea7cb7b19dd2d456b94bae131b1",
        remoteURL: "https://github.com/ancientcomputing/locallm/releases/download/v2.0.0-GA/LocalLMLabSDKRemote-2.0.0-GA.xcframework.zip",
        remoteChecksum: "901198d2b1080bbb8ef13bdb7aecca5f9374f88af8c5361ad9e61e8052d58489",
        inferenceURL: "https://github.com/ancientcomputing/locallm/releases/download/v2.0.0-GA/LocalLMLabSDKInference-2.0.0-GA.xcframework.zip",
        inferenceChecksum: "60d3f367338adb8093b705b776b68f2ca27fdec75f128b304d280c78f48c069c"
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
    name: "JevDK",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "OpenJevKit", targets: ["OpenJevKit"]),
        // Vend the binaries as library products so the XcodeGen .xcodeproj variant (project.yml)
        // can depend on them by name. `swift build` doesn't need this.
        .library(name: "LocalLMLabSDKCore", targets: ["LocalLMLabSDKCore"]),
        .library(name: "LocalLMLabSDKRemote", targets: ["LocalLMLabSDKRemote"]),
        .library(name: "LocalLMLabSDKInference", targets: ["LocalLMLabSDKInference"]),
    ],
    targets: [
        .binaryTarget(name: "LocalLMLabSDKCore", url: sdk.coreURL, checksum: sdk.coreChecksum),
        .binaryTarget(name: "LocalLMLabSDKRemote", url: sdk.remoteURL, checksum: sdk.remoteChecksum),
        .binaryTarget(name: "LocalLMLabSDKInference", url: sdk.inferenceURL, checksum: sdk.inferenceChecksum),
        .target(
            name: "OpenJevKit",
            dependencies: ["LocalLMLabSDKCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "JevDK",
            dependencies: [
                "OpenJevKit",
                "LocalLMLabSDKCore",
                "LocalLMLabSDKRemote",
                "LocalLMLabSDKInference",
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                // Bare SwiftPM executables get no LC_RPATH; SwiftPM extracts the xcframework
                // slices next to the built binary. Same fix as code-buddy / model-switch.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path"])
            ]
        ),
    ]
)
