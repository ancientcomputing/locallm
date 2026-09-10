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
// The SDK release these examples build against with no setup — what "clone, open in
// Xcode, Run" uses. `knownSDKReleases` carries this plus the previous release. Build
// against another published version: set LOCALLM_SDK_VERSION in your shell (works for
// `swift build` / CI, NOT inside Xcode), or edit `defaultSDKVersion` here. For a
// release not listed, add its entry (URL + the `.sha256` next to the zip on the
// GitHub release) or just replace the strings in place.
let defaultSDKVersion = "1.0.0-beta.4"

let knownSDKReleases: [String: SDKRelease] = [
    "1.0.0-beta.3": SDKRelease(
        remoteURL: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-beta.3/LocalLMLabSDKRemote-1.0.0-beta.3.xcframework.zip",
        remoteChecksum: "2b1e401a606c2c34d3e086cf9a2edad9d2c9ca730a3c3840b964f88d9e2e446b"
    ),
    "1.0.0-beta.4": SDKRelease(
        remoteURL: "https://github.com/ancientcomputing/locallm/releases/download/v1.0.0-beta.4/LocalLMLabSDKRemote-1.0.0-beta.4.xcframework.zip",
        remoteChecksum: "05537423397429592402638a82b118a11e963b325c0ab5a8c48c17484a14ab9e"
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
    name: "ModelSwitch",
    platforms: [.macOS("27.0")],          // RemoteModelProvider is @available(macOS 27)
    products: [
        // Vend the Remote binary as a library product so the XcodeGen .xcodeproj variant
        // (packaging/project.yml) can depend on it by name. `swift build` doesn't need this.
        .library(name: "LocalLMLabSDKRemote", targets: ["LocalLMLabSDKRemote"])
    ],
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
