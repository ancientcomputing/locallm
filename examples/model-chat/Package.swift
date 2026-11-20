// swift-tools-version: 6.4
import Foundation
import PackageDescription

// Model Chat — one chat window where you pick the model (Apple's on-device model or an open-weight
// model running on this Mac) and the model can call tools. The smallest app that shows the SDK's
// headline: choosing the model is one line, and the rest of the code does not change.
//
// Inference ships as a binaryTarget (a GitHub Release asset). Core comes from the Components
// package (../../Components) as source — this manifest must NOT declare its own LocalLMLabSDKCore
// binaryTarget: Components already declares that target, and two packages declaring a target of the
// same name is a hard SwiftPM error. Same SDKRelease/knownSDKReleases/failManifest version gate as
// every other example here.
//
// Requires macOS 27 + Xcode 27 (open-weight models need macOS 27).

struct SDKRelease {
    let inferenceURL: String
    let inferenceChecksum: String
}

// Add an entry whenever a new Inference.xcframework release is published. Build against another
// published version: set LOCALLM_SDK_VERSION in your shell (works for `swift build` / CI, NOT inside
// Xcode), or edit `defaultSDKVersion` here.
let defaultSDKVersion = "3.0.0-GA"

let knownSDKReleases: [String: SDKRelease] = [
    "3.0.0-GA": SDKRelease(
        inferenceURL: "https://github.com/ancientcomputing/locallm/releases/download/v3.0.0-GA/LocalLMLabSDKInference-3.0.0-GA.xcframework.zip",
        inferenceChecksum: "e89336700bba35a546967a66eb34e3fb59e44a8150758da44ec95a104047bd54"
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
    name: "ModelChat",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "LocalLMLabSDKInference", targets: ["LocalLMLabSDKInference"])
    ],
    dependencies: [
        .package(path: "../../Components"),
    ],
    targets: [
        .binaryTarget(
            name: "LocalLMLabSDKInference",
            url: sdk.inferenceURL,
            checksum: sdk.inferenceChecksum
        ),
        .executableTarget(
            name: "ModelChat",
            dependencies: [
                .product(name: "LocalLMLabSDKCore", package: "Components"),
                "LocalLMLabSDKInference",
            ],
            linkerSettings: [
                // Bare SwiftPM executables get no LC_RPATH; SwiftPM extracts the xcframework
                // slices next to the built binary. Same fix as mcp-chat / model-switch.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path"])
            ]
        )
    ]
)
