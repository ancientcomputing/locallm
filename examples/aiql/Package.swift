// swift-tools-version: 6.4
import Foundation
import PackageDescription

// AIQL — "ask your data". A SwiftUI app for someone who is NOT a CLI engineer: type a local
// model, an MCP data source, and a plain-English request; press Go. The app connects to the
// server (public or OAuth sign-in), downloads the model on first run, and runs a data pipeline
// that writes a CSV into a folder you chose — pull the dataset (FileBackedTool, so the raw
// payload never enters the model's context), then project / filter / sort with the Core data
// verbs (docs/sdk-guide.md §8b). The row data never passes through the model, so it can't be
// fabricated.
//
// Combines three existing examples: workspace-buddy-local (SwiftUI + App Sandbox + MLX model +
// folder picker), plate-today (MCP client + OAuth redirect wiring), repo-qa (MCPTool from a live
// schema). Like code-buddy / workspace-buddy-local it links BOTH SDK binaries:
// LocalLMLabSDKCore.xcframework AND LocalLMLabSDKInference.xcframework (the MLX runtime).
//
// Requires macOS 27 + Xcode 27 (the model layer is built on FoundationModels' `LanguageModel`
// protocol) and, to build the xcframework, the Metal Toolchain — as a binaryTarget consumer you
// likely do not (the prebuilt Inference slice bundles default.metallib).

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
let defaultSDKVersion = "1.0.0-beta.3"

let knownSDKReleases: [String: SDKRelease] = [
    "1.0.0-beta.2": SDKRelease(
        coreURL: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-beta.2/LocalLMLabSDKCore-1.0.0-beta.2.xcframework.zip",
        coreChecksum: "e3e687e503d3c563e6548b472dc8eb415475f0402845e9b4a56c58c15105c974",
        inferenceURL: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-beta.2/LocalLMLabSDKInference-1.0.0-beta.2.xcframework.zip",
        inferenceChecksum: "728bc399a96a851f1e46c6f709684133f40dc09b067a0717e1898ab11156e8a8"
    ),
    "1.0.0-beta.3": SDKRelease(
        coreURL: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-beta.3/LocalLMLabSDKCore-1.0.0-beta.3.xcframework.zip",
        coreChecksum: "a49b8bfcde340d8b86bf106d2af2cb9d84f3839a3bc1695016f3952a3fcdfb92",
        inferenceURL: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-beta.3/LocalLMLabSDKInference-1.0.0-beta.3.xcframework.zip",
        inferenceChecksum: "0e2b3cc522291dd6c0afdede6ee4516d272ed20b5c22adad68b80893c266800d"
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
