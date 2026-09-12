// swift-tools-version: 6.4
import Foundation
import PackageDescription

// code-buddy — the public copy of the SDK's reference coding agent (source maintained
// privately, copied here). Unlike plate-today, this one links BOTH SDK binaries:
// LocalLMLabSDKCore.xcframework AND LocalLMLabSDKInference.xcframework (the MLX runtime —
// mlx-swift-lm + Metal statically linked, ~49 MB / ~11 MB zipped). Core source never leaves
// the private repo; Inference is a binary for the same reason.
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
let defaultSDKVersion = "1.0.0-beta.4"

let knownSDKReleases: [String: SDKRelease] = [
    "1.0.0-beta.3": SDKRelease(
        coreURL: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-beta.3/LocalLMLabSDKCore-1.0.0-beta.3.xcframework.zip",
        coreChecksum: "a49b8bfcde340d8b86bf106d2af2cb9d84f3839a3bc1695016f3952a3fcdfb92",
        inferenceURL: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-beta.3/LocalLMLabSDKInference-1.0.0-beta.3.xcframework.zip",
        inferenceChecksum: "0e2b3cc522291dd6c0afdede6ee4516d272ed20b5c22adad68b80893c266800d"
    ),
    "1.0.0-beta.4": SDKRelease(
        coreURL: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-beta.4/LocalLMLabSDKCore-1.0.0-beta.4.xcframework.zip",
        coreChecksum: "3ed0e79b6914e6b48b7ae27f3fdda139f71e3d60f603daf54901716c8c972cb3",
        inferenceURL: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-beta.4/LocalLMLabSDKInference-1.0.0-beta.4.xcframework.zip",
        inferenceChecksum: "fa8feb19883f9a465a69f39d756f1b41b515c8298c891b06fef5da5b81b2a03c"
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
