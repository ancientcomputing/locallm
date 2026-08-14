// swift-tools-version: 6.0
import Foundation
import PackageDescription

// LocalLMLabSDKComponents — the open-source, Apache 2.0-licensed companion package: prebuilt
// SwiftUI pieces (MCP server picker, OAuth waiting view, resource/prompt browsing) built on
// LocalLMLabSDKCore's public API only.
//
// Depends on Core as a BINARY (LocalLMLabSDKCore.xcframework via a GitHub Release asset), same as
// examples/plate-today/Package.swift — copied verbatim from that file's
// SDKRelease/knownSDKReleases/failManifest pattern rather than reinvented, per that file's own
// comment pointing here.

// MARK: - Which SDK version to build against

// Deliberately NOT implicit, and deliberately NOT silently defaulted — same reasoning as
// examples/plate-today/Package.swift. Set LOCALLM_SDK_VERSION explicitly, e.g.
// `LOCALLM_SDK_VERSION=0.7.0 swift build`, or this manifest fails fast with a clear message
// instead of silently resolving to whichever version happened to be hardcoded.
struct SDKRelease {
    let url: String
    let checksum: String
}

// The source of truth for which SDK versions this Package.swift knows how to build against — add
// a new entry here whenever a new Core.xcframework release is published. Keep in sync with
// examples/plate-today/Package.swift's own table.
let knownSDKReleases: [String: SDKRelease] = [
    // TEMPORARY (2026-08-14): this repo's own v0.7.0 GitHub Release is still a draft, and GitHub
    // 404s an anonymous `swift build` download of a draft release's asset — confirmed live. Using
    // ancientcomputing/locallm-staging's real PUBLISHED v0.7.0 asset in the meantime (a separate,
    // public testing repo). Swap `url` below to
    // "https://github.com/ancientcomputing/locallm/releases/download/v0.7.0/LocalLMLabSDKCore-0.7.0.xcframework.zip"
    // once this repo's own v0.7.0 is published non-draft — that repo's draft was built BEFORE
    // Core gained exportSummary()/Contacts (2026-08-14), so `checksum` there is currently stale
    // too; re-derive both `url` and `checksum` from a fresh publish, don't assume this one
    // carries over. Same TEMPORARY state as examples/plate-today/Package.swift; fix both
    // together.
    "0.7.0": SDKRelease(
        url: "https://github.com/ancientcomputing/locallm-staging/releases/download/v0.7.0/LocalLMLabSDKCore-0.7.0.xcframework.zip",
        checksum: "8853f891f782cb052dd49850e6490558ba68b21b6970a0e1b83d393ab50f8289"
    )
]

func failManifest(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard let requestedSDKVersion = ProcessInfo.processInfo.environment["LOCALLM_SDK_VERSION"] else {
    failManifest("""
    error: LOCALLM_SDK_VERSION is not set.
    Set it to the LocalLM Lab SDK version to build against, e.g.:
        LOCALLM_SDK_VERSION=0.7.0 swift build
    Known versions: \(knownSDKReleases.keys.sorted().joined(separator: ", "))
    """)
}

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
        .library(name: "LocalLMLabSDKComponents", targets: ["LocalLMLabSDKComponents"])
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
