// swift-tools-version: 6.0
import Foundation
import PackageDescription

// LocalLMLabSDKComponents — the open-source, Apache 2.0-licensed companion package: prebuilt
// SwiftUI pieces (MCP server picker, OAuth waiting view, resource/prompt browsing, model
// picker, AI Models settings panel) built on LocalLMLabSDKCore's public API only.
//
// Depends on Core as a BINARY (LocalLMLabSDKCore.xcframework via a GitHub Release asset), same as
// examples/plate-today/Package.swift — copied verbatim from that file's
// SDKRelease/knownSDKReleases/failManifest pattern rather than reinvented, per that file's own
// comment pointing here.

// MARK: - Which SDK version to build against

struct SDKRelease {
    let url: String
    let checksum: String
}

// `defaultSDKVersion` is what this builds against with no setup — "clone, open in Xcode, Run".
// `knownSDKReleases` carries it plus the previous release. Build against another published
// version: set LOCALLM_SDK_VERSION in your shell (works for `swift build` / CI, NOT inside Xcode),
// or edit `defaultSDKVersion`. For a release not listed, add its entry (URL follows the pattern
// below; checksum is the `.sha256` next to the zip on that GitHub release). Keep this in step
// with `examples/model-switch/Package.swift`, which consumes Core through this package.
let defaultSDKVersion = "1.0.0-RC.1"

let knownSDKReleases: [String: SDKRelease] = [
    "1.0.0-beta.4": SDKRelease(
        url: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-beta.4/LocalLMLabSDKCore-1.0.0-beta.4.xcframework.zip",
        checksum: "3ed0e79b6914e6b48b7ae27f3fdda139f71e3d60f603daf54901716c8c972cb3"
    ),
    "1.0.0-RC.1": SDKRelease(
        url: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-RC.1/LocalLMLabSDKCore-1.0.0-RC.1.xcframework.zip",
        checksum: "5c6b8067b3b68143909b1083c40b131d85bc1ea8b7af037d09f1066eb4f6a080"
    ),
]

func failManifest(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let requestedSDKVersion = ProcessInfo.processInfo.environment["LOCALLM_SDK_VERSION"] ?? defaultSDKVersion

guard let sdkRelease = knownSDKReleases[requestedSDKVersion] else {
    failManifest("""
    error: Unknown LOCALLM_SDK_VERSION "\(requestedSDKVersion)".
    Known versions: \(knownSDKReleases.keys.sorted().joined(separator: ", "))
    """)
}

let package = Package(
    name: "LocalLMLabSDKComponents",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "LocalLMLabSDKComponents", targets: ["LocalLMLabSDKComponents"]),
        // Re-vend the Core binary so a downstream package that consumes Components can also
        // `import LocalLMLabSDKCore` without declaring its own (colliding) LocalLMLabSDKCore
        // binaryTarget. Used by examples/model-switch.
        .library(name: "LocalLMLabSDKCore", targets: ["LocalLMLabSDKCore"])
    ],
    targets: [
        .binaryTarget(
            name: "LocalLMLabSDKCore",
            url: sdkRelease.url,
            checksum: sdkRelease.checksum
        ),
        .target(name: "LocalLMLabSDKComponents", dependencies: ["LocalLMLabSDKCore"])
    ]
)
