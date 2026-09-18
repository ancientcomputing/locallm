// swift-tools-version: 6.0
import PackageDescription

// components-updates-demo — the model onboarding stepper and the update / versions views from
// LocalLMLabSDKComponents, driven by SIMULATED sources (no network, no MLX), so you can see every
// state: a failed preflight, a hash mismatch, a download, an update with the pause point, a rollback,
// and cleaning up old versions. A real host wires the same views to MLXModelProvider — see
// Components/README.md, "Adapting MLXModelProvider".
//
// Consumes Components (which brings Core) by path, the same way examples/model-switch does.
let package = Package(
    name: "UpdatesDemo",
    platforms: [.macOS("27.0")],
    dependencies: [
        .package(path: "../../Components")
    ],
    targets: [
        .executableTarget(
            name: "UpdatesDemo",
            dependencies: [
                .product(name: "LocalLMLabSDKCore", package: "Components"),
                .product(name: "LocalLMLabSDKComponents", package: "Components"),
            ],
            linkerSettings: [
                // Bare SwiftPM executables get no LC_RPATH; SwiftPM extracts the xcframework slices next to
                // the built binary. Same fix as code-buddy / components-demo / model-switch.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path"])
            ]
        )
    ]
)
