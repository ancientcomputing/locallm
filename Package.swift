// swift-tools-version: 6.0
import PackageDescription

// The LocalLM SDK as one Swift package, so you can add it from this repository's URL.
//
// In Xcode: File > Add Package Dependencies, paste https://github.com/ancientcomputing/locallm, choose
// "Branch" and type 3.0.0-GA, then pick the libraries your app uses. In a Package.swift:
//
//     .package(url: "https://github.com/ancientcomputing/locallm", branch: "3.0.0-GA")
//     .product(name: "LocalLMLabSDKCore", package: "locallm")
//
// What is in here:
//   - Four SDK libraries that ship prebuilt (Core, Inference, Remote, Claude). They are not stored in this repository.
//     Each is a zip on this release's GitHub release page, and the checksum below is the zip's fingerprint, so SwiftPM
//     refuses a file that is not exactly the one that was released.
//   - Two libraries that ship as source (Components and MCPAppsHost). They are the Swift files in the
//     Components/ and MCPAppsHost/ folders of this repository.
//
// Adding the package downloads all four zips (about 16 MB) even if your app uses only Core; the libraries you
// don't pick are not linked into your app.
//
// A Swift package program (not an Xcode app project) also needs the runtime search path in the quickstart's
// manifest (docs/quickstart.md). An Xcode app project does not.
//
// The examples in examples/ do not use this file: each has its own Package.swift. When a release is re-published,
// its zips change and so do these checksums: update them here, in Components/Package.swift and in the examples
// (scripts/check-root-package.sh checks that this file and Components/Package.swift agree).

let release = "3.0.0-GA"
let releaseURL = "https://github.com/ancientcomputing/locallm/releases/download/v\(release)"

let package = Package(
    name: "LocalLM",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "LocalLMLabSDKCore", targets: ["LocalLMLabSDKCore"]),
        .library(name: "LocalLMLabSDKInference", targets: ["LocalLMLabSDKInference"]),
        .library(name: "LocalLMLabSDKRemote", targets: ["LocalLMLabSDKRemote"]),
        .library(name: "LocalLMLabSDKClaude", targets: ["LocalLMLabSDKClaude"]),
        .library(name: "LocalLMLabSDKComponents", targets: ["LocalLMLabSDKComponents"]),
        .library(name: "LocalLMLabSDKMCPAppsHost", targets: ["LocalLMLabSDKMCPAppsHost"]),
    ],
    targets: [
        .binaryTarget(
            name: "LocalLMLabSDKCore",
            url: "\(releaseURL)/LocalLMLabSDKCore-\(release).xcframework.zip",
            checksum: "2b286cfecae1f6596c64255d72550a30f6f3cfe8323e4aa2a5176a4275699451"
        ),
        .binaryTarget(
            name: "LocalLMLabSDKInference",
            url: "\(releaseURL)/LocalLMLabSDKInference-\(release).xcframework.zip",
            checksum: "e89336700bba35a546967a66eb34e3fb59e44a8150758da44ec95a104047bd54"
        ),
        .binaryTarget(
            name: "LocalLMLabSDKRemote",
            url: "\(releaseURL)/LocalLMLabSDKRemote-\(release).xcframework.zip",
            checksum: "54ca50806e65d96a80ef928b56952bf9b827ba959bcb466c25088b3cb2995507"
        ),
        .binaryTarget(
            name: "LocalLMLabSDKClaude",
            url: "\(releaseURL)/LocalLMLabSDKClaude-\(release).xcframework.zip",
            checksum: "d610c8e5c82402ed2e898eb239ef8af02983c459b73ec531e84781d478a6d159"
        ),
        .target(
            name: "LocalLMLabSDKComponents",
            dependencies: ["LocalLMLabSDKCore"],
            path: "Components/Sources/LocalLMLabSDKComponents"
        ),
        .target(
            name: "LocalLMLabSDKMCPAppsHost",
            dependencies: ["LocalLMLabSDKCore"],
            path: "MCPAppsHost/Sources/LocalLMLabSDKMCPAppsHost"
        ),
    ]
)
