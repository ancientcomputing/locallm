// swift-tools-version: 6.4
import Foundation
import PackageDescription

// AIQL — "ask your data". A SwiftUI app for someone who is NOT a CLI engineer: type a local
// model, an MCP data source, and a plain-English request; press Go. The app connects to the
// server (public or OAuth sign-in), downloads the model on first run, and runs a data pipeline
// that writes a CSV into a folder you chose — pull the dataset (FileBackedTool, so the raw
// payload never enters the model's context), then project / filter / sort with the Core data
// verbs (docs/sdk-guide.md §8b). The row data never passes through the model, so it can't be
// fabricated. The data tools come from lab.mcp, file-backed (`setFileBackedOutput`, new in
// 2.0.0) — so this example needs SDK 2.0.0-GA or later.
//
// Combines three existing examples: workspace-buddy-local (SwiftUI + App Sandbox + MLX model +
// folder picker), plate-today (MCP client + OAuth redirect wiring), repo-qa (tools from a live
// MCP schema). Like code-buddy / workspace-buddy-local it links BOTH SDK binaries:
// LocalLMLabSDKCore.xcframework AND LocalLMLabSDKInference.xcframework (the MLX runtime).
//
// Requires macOS 27 + Xcode 27 (the model layer is built on FoundationModels' `LanguageModel`
// protocol). No Metal Toolchain needed — the prebuilt Inference xcframework bundles the compiled
// default.metallib; it's only required when building the SDK from source.

struct SDKRelease {
    let coreURL: String
    let coreChecksum: String
    let inferenceURL: String
    let inferenceChecksum: String
}

// The SDK release these examples build against with no setup — what "clone, open in Xcode, Run"
// uses. `knownSDKReleases` carries this plus the previous release. Build against another
// published version: set LOCALLM_SDK_VERSION in your shell (works for `swift build` / CI, NOT
// inside Xcode), or edit `defaultSDKVersion` here.
let defaultSDKVersion = "2.0.0-GA"

let knownSDKReleases: [String: SDKRelease] = [
    "1.0.0-GA": SDKRelease(
        coreURL: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-GA/LocalLMLabSDKCore-1.0.0-GA.xcframework.zip",
        coreChecksum: "7d77a9c2e37dfb2f7925f01ed011262ee5a2aebc561a3ae7a93524acc0285b3e",
        inferenceURL: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-GA/LocalLMLabSDKInference-1.0.0-GA.xcframework.zip",
        inferenceChecksum: "6fcbdd5b04fff709e720b92e8b7eda638014a4d19c0dd925e018b72cb7109430"
    ),
    "2.0.0-GA": SDKRelease(
        coreURL: "https://github.com/ancientcomputing/locallm/releases/download/v2.0.0-GA/LocalLMLabSDKCore-2.0.0-GA.xcframework.zip",
        coreChecksum: "faa92a02bc7e5b0c2de284507e730798042bc7154a51d361535a7ba801d54029",
        inferenceURL: "https://github.com/ancientcomputing/locallm/releases/download/v2.0.0-GA/LocalLMLabSDKInference-2.0.0-GA.xcframework.zip",
        inferenceChecksum: "fde8babbb0a8512b3d26e3d3bcc8139d02eb00375b2fbd6ed1e9157dfec55db8"
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
    name: "AIQL",
    platforms: [.macOS("27.0")],
    products: [
        // Vend the binaries as library products so the XcodeGen .xcodeproj variant (project.yml)
        // can depend on them by name. `swift build` doesn't need this.
        .library(name: "LocalLMLabSDKCore", targets: ["LocalLMLabSDKCore"]),
        .library(name: "LocalLMLabSDKInference", targets: ["LocalLMLabSDKInference"])
    ],
    targets: [
        .binaryTarget(name: "LocalLMLabSDKCore", url: sdk.coreURL, checksum: sdk.coreChecksum),
        .binaryTarget(name: "LocalLMLabSDKInference", url: sdk.inferenceURL, checksum: sdk.inferenceChecksum),
        .executableTarget(
            name: "AIQL",
            dependencies: ["LocalLMLabSDKCore", "LocalLMLabSDKInference"],
            linkerSettings: [
                // SwiftPM's Swift Build system (Xcode 27 toolchain default) gives a bare
                // executable target no LC_RPATH; SwiftPM extracts the xcframework slices next to
                // the built binary, so point rpath there. Same fix as code-buddy.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path"])
            ]
        )
    ]
)
