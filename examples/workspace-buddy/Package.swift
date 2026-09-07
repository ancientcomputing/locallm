// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Workspace Buddy — the public copy of the SDK's fourth reference app (this source is maintained
// privately and copied here, same as the other examples). Depends on Core as a BINARY
// (LocalLMLabSDKCore.xcframework via a GitHub Release asset) — see plate-today's Package.swift
// for the fuller explanation of that one real difference the copy process accounts for.
//
// Same as plate-today-tools/repo-qa, same reason: this app's whole point is
// WorkspaceAccess/WorkspaceTools (docs/sdk-guide.md §8a), which shipped starting with 0.8.0.
// Building against 0.7.0/0.7.1 fails to compile (`cannot find 'ListWorkspaceFilesTool' in
// scope`), not run with reduced functionality.

struct SDKRelease {
    let url: String
    let checksum: String
}

// The SDK release these examples build against with no setup — what "clone, open in
// Xcode, Run" uses. `knownSDKReleases` carries this plus the previous release. Build
// against another published version: set LOCALLM_SDK_VERSION in your shell (works for
// `swift build` / CI, NOT inside Xcode), or edit `defaultSDKVersion` here. For a
// release not listed, add its entry (URL + the `.sha256` next to the zip on the
// GitHub release) or just replace the strings in place.
let defaultSDKVersion = "1.0.0-beta.3"

let knownSDKReleases: [String: SDKRelease] = [
    "1.0.0-beta.2": SDKRelease(
        url: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-beta.2/LocalLMLabSDKCore-1.0.0-beta.2.xcframework.zip",
        checksum: "e3e687e503d3c563e6548b472dc8eb415475f0402845e9b4a56c58c15105c974"
    ),
    "1.0.0-beta.3": SDKRelease(
        url: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-beta.3/LocalLMLabSDKCore-1.0.0-beta.3.xcframework.zip",
        checksum: "a49b8bfcde340d8b86bf106d2af2cb9d84f3839a3bc1695016f3952a3fcdfb92"
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
    name: "WorkspaceBuddy",
    platforms: [.macOS("26.0")],
    products: [
        // Vend the Core binary as a library product so the XcodeGen .xcodeproj variant
        // (project.yml) can depend on it by name. `swift build` doesn't need this.
        .library(name: "LocalLMLabSDKCore", targets: ["LocalLMLabSDKCore"])
    ],
    targets: [
        .binaryTarget(
            name: "LocalLMLabSDKCore",
            url: sdkRelease.url,
            checksum: sdkRelease.checksum
        ),
        .executableTarget(
            name: "WorkspaceBuddy",
            dependencies: ["LocalLMLabSDKCore"],
            linkerSettings: [
                // SwiftPM's Swift Build system (default in the Xcode 27 toolchain) gives a bare
                // executable target no LC_RPATH, so `@rpath/LocalLMLabSDKCore.framework/...`
                // resolves to nothing and the app aborts at launch ("no LC_RPATH's found").
                // The Core framework sits next to the executable — in `swift build` output and,
                // once packaged, in Contents/MacOS — so point rpath at @executable_path. Same
                // fix as code-buddy.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path"])
            ]
        )
    ]
)
