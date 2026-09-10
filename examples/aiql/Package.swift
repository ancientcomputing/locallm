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
        coreChecksum: "60439d6b5a145dcb81bd238664ae5567c791de3fe5dad9359b8c42e7d5b4d84d",
        inferenceURL: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-beta.4/LocalLMLabSDKInference-1.0.0-beta.4.xcframework.zip",
        inferenceChecksum: "d132d2c70ff21682c083f4f63e0b46aad9b1b4109f9d6bd8f76814e2d664dc6a"
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
