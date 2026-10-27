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
