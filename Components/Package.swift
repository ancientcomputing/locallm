// swift-tools-version: 6.0
import PackageDescription

// LocalLMLabSDKComponents — the open-source, Apache 2.0-licensed companion package: prebuilt
// SwiftUI pieces (MCP server picker, OAuth waiting view, resource/prompt browsing) built on
// LocalLMLabSDKCore's public API only.
//
// NOT YET BUILDABLE STANDALONE FROM THIS REPO: the binaryTarget below still uses the local path
// this package was developed against privately (locallmlab-sdk's own Core.xcframework, gitignored
// there and never committed to any repo) — it does not resolve here. This is source lives here as
// read-reference for now, same as `examples/plate-today/Package.swift` briefly was before its own
// binaryTarget rewrite. Needs the same treatment before it builds: a remote binaryTarget URL +
// checksum, gated behind an explicit LOCALLM_SDK_VERSION (see that file's `SDKRelease`/
// `knownSDKReleases`/`failManifest` pattern, and locallmlab-sdk's docs/04-open-source-sync.md
// "the gotcha" section, which documents this exact pattern as what to copy verbatim here rather
// than reinventing).
let package = Package(
    name: "LocalLMLabSDKComponents",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "LocalLMLabSDKComponents", targets: ["LocalLMLabSDKComponents"])
    ],
    targets: [
        .binaryTarget(name: "LocalLMLabSDKCore", path: "../Core.xcframework"),
        .target(name: "LocalLMLabSDKComponents", dependencies: ["LocalLMLabSDKCore"])
    ]
)
