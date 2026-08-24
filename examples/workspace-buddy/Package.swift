// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Workspace Buddy — the public copy of the SDK's fourth reference app (this source is maintained
// privately and copied here, same as the other examples). Depends on Core as a BINARY
// (LocalLMLabSDKCore.xcframework via a GitHub Release asset) — see plate-today's Package.swift
// for the fuller explanation of that one real difference the copy process accounts for.
//
// Same version gap as plate-today-tools/repo-qa, same reason: this app's whole point is
// WorkspaceAccess/WorkspaceTools (docs/sdk-guide.md §8a), which postdates the latest published
// release (0.7.1). Building against a version below fails to compile
// (`cannot find 'ListWorkspaceFilesTool' in scope`), not run with reduced functionality.
// Published now so the source is readable immediately; add a newer release's entry to
// knownSDKReleases below once one exists and this builds like any other example.

struct SDKRelease {
    let url: String
    let checksum: String
}

let knownSDKReleases: [String: SDKRelease] = [
    "0.7.0": SDKRelease(
        url: "https://github.com/ancientcomputing/locallm/releases/download/v0.7.0/LocalLMLabSDKCore-0.7.0.xcframework.zip",
        checksum: "8853f891f782cb052dd49850e6490558ba68b21b6970a0e1b83d393ab50f8289"
    ),
    "0.7.1": SDKRelease(
        url: "https://github.com/ancientcomputing/locallm/releases/download/v0.7.1/LocalLMLabSDKCore-0.7.1.xcframework.zip",
        checksum: "d165bc1fbed790ac2264502c0cfa16336b68d2d7d9d282964742bd8b73f08e21"
    ),
    "0.8.0": SDKRelease(
        url: "https://github.com/ancientcomputing/locallm/releases/download/v0.8.0/LocalLMLabSDKCore-0.8.0.xcframework.zip",
        checksum: "3a7369e3fbd88de0bcf5cbe2e0a4202b2b919b67c20f364fb8bb2572fd1b9703"
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
        LOCALLM_SDK_VERSION=0.7.1 swift build
    Known versions: \(knownSDKReleases.keys.sorted().joined(separator: ", "))
    NOTE: this example needs a release that includes WorkspaceAccess/WorkspaceTools
    (docs/sdk-guide.md §8a) — none of the versions above have them yet. It will fail to compile
    until a newer release is added to this file's knownSDKReleases.
    """)
}

guard let sdkRelease = knownSDKReleases[requestedSDKVersion] else {
    failManifest("""
    error: Unknown LOCALLM_SDK_VERSION "\(requestedSDKVersion)".
    Known versions: \(knownSDKReleases.keys.sorted().joined(separator: ", "))
    """)
}

let package = Package(
    name: "WorkspaceBuddy",
    platforms: [.macOS("26.0")],
    targets: [
        .binaryTarget(
            name: "LocalLMLabSDKCore",
            url: sdkRelease.url,
            checksum: sdkRelease.checksum
        ),
        .executableTarget(
            name: "WorkspaceBuddy",
            dependencies: ["LocalLMLabSDKCore"]
        )
    ]
)
