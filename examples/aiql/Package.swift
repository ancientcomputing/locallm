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
let defaultSDKVersion = "1.0.0-RC.1"

let knownSDKReleases: [String: SDKRelease] = [
    "1.0.0-beta.4": SDKRelease(
        coreURL: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-beta.4/LocalLMLabSDKCore-1.0.0-beta.4.xcframework.zip",
        coreChecksum: "3ed0e79b6914e6b48b7ae27f3fdda139f71e3d60f603daf54901716c8c972cb3",
        inferenceURL: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-beta.4/LocalLMLabSDKInference-1.0.0-beta.4.xcframework.zip",
        inferenceChecksum: "fa8feb19883f9a465a69f39d756f1b41b515c8298c891b06fef5da5b81b2a03c"
    ),
    "1.0.0-RC.1": SDKRelease(
        coreURL: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-RC.1/LocalLMLabSDKCore-1.0.0-RC.1.xcframework.zip",
        coreChecksum: "5194ed8a02ca2a4ad85d5bc4f693b861e5554f0f5422e67172b2a5649bbfcdbd",
        inferenceURL: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-RC.1/LocalLMLabSDKInference-1.0.0-RC.1.xcframework.zip",
        inferenceChecksum: "e15b3bfc9be34b7af0daf268d365b3b89cf1e5539169447302eb683b6d707c4c"
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
