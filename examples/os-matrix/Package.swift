// swift-tools-version: 6.4
import Foundation
import PackageDescription

// os-matrix — the public copy of the SDK's 26/27 reference example (source maintained
// privately, copied here). ONE .macOS("26.0") build that runs on both macOS 26 and 27 — the
// canonical "register fewer providers on 26, one #available block, identical code after"
// pattern. See README.md for the four scenarios and the "Claude → separate 27-only target"
// recipe.
//
// Links Core + Inference as binaryTargets. Builds against `defaultSDKVersion`; LOCALLM_SDK_VERSION overrides from a shell.

struct SDKRelease {
    let coreURL: String
    let coreChecksum: String
    let inferenceURL: String
    let inferenceChecksum: String
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
        coreURL: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-beta.2/LocalLMLabSDKCore-1.0.0-beta.2.xcframework.zip",
        coreChecksum: "e3e687e503d3c563e6548b472dc8eb415475f0402845e9b4a56c58c15105c974",
        inferenceURL: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-beta.2/LocalLMLabSDKInference-1.0.0-beta.2.xcframework.zip",
        inferenceChecksum: "728bc399a96a851f1e46c6f709684133f40dc09b067a0717e1898ab11156e8a8"
    ),
    "1.0.0-beta.3": SDKRelease(
        coreURL: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-beta.3/LocalLMLabSDKCore-1.0.0-beta.3.xcframework.zip",
        coreChecksum: "2600da14b13e3bfcf8d33491a5f4a8fb7406fc5d314a20ba491348a029898d8c",
        inferenceURL: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-beta.3/LocalLMLabSDKInference-1.0.0-beta.3.xcframework.zip",
        inferenceChecksum: "5ce9b4481f6509fffb460d45cf230d3e2711a01082ca779525363141c2e2646b"
    ),
]

func failManifest(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
let requested = ProcessInfo.processInfo.environment["LOCALLM_SDK_VERSION"] ?? defaultSDKVersion
guard let sdk = knownSDKReleases[requested] else {
    failManifest("error: Unknown LOCALLM_SDK_VERSION \"\(requested)\". Known: \(knownSDKReleases.keys.sorted().joined(separator: ", "))")
}

let package = Package(
    name: "OSMatrix",
    platforms: [.macOS("26.0")],
    targets: [
        .binaryTarget(name: "LocalLMLabSDKCore", url: sdk.coreURL, checksum: sdk.coreChecksum),
        .binaryTarget(name: "LocalLMLabSDKInference", url: sdk.inferenceURL, checksum: sdk.inferenceChecksum),
        .executableTarget(
            name: "OSMatrix",
            dependencies: ["LocalLMLabSDKCore", "LocalLMLabSDKInference"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path"])]
        )
    ]
)
