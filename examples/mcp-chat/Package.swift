// swift-tools-version: 6.4
import Foundation
import PackageDescription

// MCP Chat — a chat with a local model where a tool call that has an MCP App shows the server's
// interactive widget inline in the conversation.
//
// Qwen3-8B through MLX by default (Apple's on-device model as an alternative); MCP servers added
// with Components' server picker; widgets rendered by MCPAppsHost, routed back through the
// session so the user approves what a widget does exactly as they approve the model's calls.
//
// Inference ships as a binaryTarget (a GitHub Release asset). Core + Components come from the
// Components package (../../Components) and MCPAppsHost from ../../MCPAppsHost, both as source —
// this manifest must NOT declare its own LocalLMLabSDKCore binaryTarget: Components already
// declares that target, and two packages declaring a target of the same name is a hard SwiftPM
// error. Components re-vends Core as a `.library` product for exactly this. Same
// SDKRelease/knownSDKReleases/failManifest version gate as every other example here.
//
// Requires SDK 2.0.0-GA or later (MCP Apps support, per-server trust and approval are new in 2.0),
// macOS 27 + Xcode 27. No Metal Toolchain needed — the prebuilt Inference xcframework bundles the
// compiled default.metallib.

struct SDKRelease {
    let inferenceURL: String
    let inferenceChecksum: String
}

// Add an entry whenever a new Inference.xcframework release is published. The matching Core comes
// from Components' own knownSDKReleases table for the same LOCALLM_SDK_VERSION — keep the two
// in step. Only 2.0 releases: this app does not build against 1.0.
// The SDK release this example builds against with no setup. Build against another published
// version: set LOCALLM_SDK_VERSION in your shell (works for `swift build` / CI, NOT inside Xcode),
// or edit `defaultSDKVersion` here.
let defaultSDKVersion = "2.0.0-GA"

let knownSDKReleases: [String: SDKRelease] = [
    "2.0.0-GA": SDKRelease(
        inferenceURL: "https://github.com/ancientcomputing/locallm/releases/download/v2.0.0-GA/LocalLMLabSDKInference-2.0.0-GA.xcframework.zip",
        inferenceChecksum: "d2ed4a02686aceab0edf4231ede55c924ea3ab273c7c5cab0bb02f4bda40a185"
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
    name: "MCPChat",
    platforms: [.macOS("27.0")],
    products: [
        // Vend the Inference binary as a library product so the XcodeGen .xcodeproj variant
        // (project.yml) can depend on it by name. `swift build` doesn't need this. Core comes from
        // Components' own product, never re-declared here (see above).
        .library(name: "LocalLMLabSDKInference", targets: ["LocalLMLabSDKInference"])
    ],
    dependencies: [
        .package(path: "../../Components"),
        .package(path: "../../MCPAppsHost"),
    ],
    targets: [
        .binaryTarget(
            name: "LocalLMLabSDKInference",
            url: sdk.inferenceURL,
            checksum: sdk.inferenceChecksum
        ),
        .executableTarget(
            name: "MCPChat",
            dependencies: [
                .product(name: "LocalLMLabSDKCore", package: "Components"),
                .product(name: "LocalLMLabSDKComponents", package: "Components"),
                .product(name: "LocalLMLabSDKMCPAppsHost", package: "MCPAppsHost"),
                "LocalLMLabSDKInference",
            ],
            linkerSettings: [
                // Bare SwiftPM executables get no LC_RPATH; SwiftPM extracts the xcframework
                // slices next to the built binary. Same fix as code-buddy / model-switch.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path"])
            ]
        )
    ]
)
