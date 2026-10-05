// swift-tools-version: 6.4
import PackageDescription

// jev-serve — answers hosted Jev's HTTP API (OpenRouter's /api/alpha/decisions, Featherless's
// /v1/classifier) with OpenJev on a local MLX model. Code that calls hosted Jev switches to
// private, on-device decisions by changing its base URL. See README.md.
//
// Built on the SDK: OpenJevDecisionProvider and MLXModelProvider (Inference) for decisions and
// model downloads, JevWire (Core) for the wire format. The config file is JevDK's (File → Export
// Server Config…), read with OpenJevKit's JevServeConfig. JevServeKit (the server and routes) is a
// library so it can be tested without a GPU; the tests call it with the SDK's own hosted-Jev
// client (JevDecisionProvider, Remote).
//
// The SDK binaries (LocalLMLabSDKCore, LocalLMLabSDKInference, LocalLMLabSDKRemote) come from
// ../jevdk, which declares them as binaryTargets on a GitHub Release and vends them as products.
// This manifest must NOT declare its own: two packages declaring a binary target of the same name
// is a hard SwiftPM error. So jev-serve builds against whichever SDK version JevDK's
// `defaultSDKVersion` / LOCALLM_SDK_VERSION selects (2.0 releases only).
//
// Requires SDK 2.0.0 or later, macOS 27 + Xcode 27. No Metal Toolchain needed — the prebuilt
// Inference xcframework bundles the compiled shaders.
let package = Package(
    name: "JevServe",
    platforms: [.macOS("27.0")],
    dependencies: [
        .package(path: "../jevdk"),
    ],
    targets: [
        .target(
            name: "JevServeKit",
            dependencies: [
                .product(name: "LocalLMLabSDKCore", package: "jevdk"),
                .product(name: "LocalLMLabSDKInference", package: "jevdk"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "jev-serve",
            dependencies: [
                "JevServeKit",
                .product(name: "LocalLMLabSDKCore", package: "jevdk"),
                .product(name: "LocalLMLabSDKInference", package: "jevdk"),
                .product(name: "OpenJevKit", package: "jevdk"),
            ],
            path: "Sources/JevServe",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                // Bare SwiftPM executables get no LC_RPATH; SwiftPM extracts the xcframework
                // slices next to the built binary. Same fix as jevdk / code-buddy.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path"])
            ]
        ),
        .testTarget(
            name: "JevServeKitTests",
            dependencies: [
                "JevServeKit",
                .product(name: "LocalLMLabSDKCore", package: "jevdk"),
                .product(name: "LocalLMLabSDKRemote", package: "jevdk"),
            ]
        ),
    ]
)
