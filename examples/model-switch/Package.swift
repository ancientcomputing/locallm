// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Model Switch — reference app for the online / remote AI providers (SDK
// docs/12-remote-model-providers.md). The user adds a provider + API key, ticks web search, and
// switches between every configured model — Apple on-device, PCC, Claude-4-FM, GPT, Claude
// online, any OpenRouter model — from one chat window, one `lab.makeSession` call site.
//
// Remote ships as a binaryTarget (a GitHub Release asset). Core + Components come from the
// Components package (../../Components) — this manifest must NOT declare its own
// LocalLMLabSDKCore binaryTarget: Components already declares that target, and two packages
// declaring a target of the same name is a hard SwiftPM error. Components re-vends Core as a
// `.library` product for exactly this. Same SDKRelease/knownSDKReleases/failManifest version
// gate as every other example here.

struct SDKRelease {
    let remoteURL: String
    let remoteChecksum: String
}

// Add an entry whenever a new Remote.xcframework release is published. The matching Core comes
// from Components' own knownSDKReleases table for the same LOCALLM_SDK_VERSION — keep the two
// in step.
let knownSDKReleases: [String: SDKRelease] = [
    "1.0.0-beta.3": SDKRelease(
        remoteURL: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-beta.3/LocalLMLabSDKRemote-1.0.0-beta.3.xcframework.zip",
        remoteChecksum: "TODO"
    ),
]

func failManifest(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard let requested = ProcessInfo.processInfo.environment["LOCALLM_SDK_VERSION"] else {
    failManifest("""
    error: LOCALLM_SDK_VERSION is not set.
    Set it to the LocalLM Lab SDK version to build against, e.g.:
        LOCALLM_SDK_VERSION=1.0.0-beta.3 swift run ModelSwitch
    Known versions: \(knownSDKReleases.keys.sorted().joined(separator: ", "))
    """)
}
guard let sdk = knownSDKReleases[requested] else {
    failManifest("""
    error: Unknown LOCALLM_SDK_VERSION "\(requested)".
    Known versions: \(knownSDKReleases.keys.sorted().joined(separator: ", "))
    """)
}

let package = Package(
    name: "ModelSwitch",
    platforms: [.macOS("27.0")],          // RemoteModelProvider is @available(macOS 27)
    dependencies: [
        .package(path: "../../Components")
    ],
    targets: [
        .binaryTarget(
            name: "LocalLMLabSDKRemote",
            url: sdk.remoteURL,
            checksum: sdk.remoteChecksum
        ),
        .executableTarget(
            name: "ModelSwitch",
            dependencies: [
                .product(name: "LocalLMLabSDKCore", package: "Components"),
                .product(name: "LocalLMLabSDKComponents", package: "Components"),
                "LocalLMLabSDKRemote",
            ],
            linkerSettings: [
                // Bare SwiftPM executables get no LC_RPATH; SwiftPM extracts the xcframework
                // slices next to the built binary. Same fix as code-buddy / components-demo.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path"])
            ]
        )
    ]
)
