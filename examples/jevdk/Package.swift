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
// Requires SDK 2.3.0-GA or later (the OpenAI backend needs 2.3), macOS 27 + Xcode 27. No Metal
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
// next to each zip on the GitHub release) or just replace the strings in place. Only 2.3 and
// later: the OpenAI backend doesn't build against 2.2 or earlier.
let defaultSDKVersion = "2.3.1-GA"

let knownSDKReleases: [String: SDKRelease] = [
    // 2.3.0-GA: OpenAI's Decisions API (JevProviderConfig.openAI) and Decision.refusals, which
    // JevDK's OpenAI backend needs.
    "2.3.0-GA": SDKRelease(
        coreURL: "https://github.com/ancientcomputing/locallm/releases/download/v2.3.0-GA/LocalLMLabSDKCore-2.3.0-GA.xcframework.zip",
        coreChecksum: "7821197d0cf5b4c92e36af5c537295e594afbb55d60d2f98b0773a3625403575",
        remoteURL: "https://github.com/ancientcomputing/locallm/releases/download/v2.3.0-GA/LocalLMLabSDKRemote-2.3.0-GA.xcframework.zip",
        remoteChecksum: "dae65d45bea196f6cd2538328fad1a0e33eceae5fac5ee965183706ac942daaf",
        inferenceURL: "https://github.com/ancientcomputing/locallm/releases/download/v2.3.0-GA/LocalLMLabSDKInference-2.3.0-GA.xcframework.zip",
        inferenceChecksum: "63dc8bcba5e91e1324809ca412a23ebb0b9e04386361436eacc0be9fe6d4a8e0"
    ),
    "2.3.1-GA": SDKRelease(
        coreURL: "https://github.com/ancientcomputing/locallm/releases/download/v2.3.1-GA/LocalLMLabSDKCore-2.3.1-GA.xcframework.zip",
        coreChecksum: "0dc1e30235607fa2991e13fc97ca1f5c87b1b60b33999570d09ac31ae0c7990c",
        remoteURL: "https://github.com/ancientcomputing/locallm/releases/download/v2.3.1-GA/LocalLMLabSDKRemote-2.3.1-GA.xcframework.zip",
        remoteChecksum: "79247d567ad5dddecd14b0cc7662ab1ac61a322c3507029abd9fd4fb093d9ab6",
        inferenceURL: "https://github.com/ancientcomputing/locallm/releases/download/v2.3.1-GA/LocalLMLabSDKInference-2.3.1-GA.xcframework.zip",
        inferenceChecksum: "7663074fc31919ba2970c99d7835fbad93415370b29ad828a32def0db73c7e8e"
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
