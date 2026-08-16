// swift-tools-version: 6.0
import PackageDescription

// The SDK's second reference app: demonstrates Components, not Core directly. plate-today shows
// "build a real feature on top of Core's API"; this shows "drop in Components' prebuilt MCP
// server picker UI with a few lines of glue code" — the two things a third-party developer
// evaluating the SDK actually wants to see done separately, not mixed into one app.
//
// Depends on Components as SOURCE (a local path dependency) — this file itself needs no
// binaryTarget rewrite either way, since it never touches Core directly, only ever seeing it
// through Components' binary boundary. NOT YET BUILDABLE STANDALONE FROM THIS REPO, though:
// ../../Components (sibling Components/) still needs its own binaryTarget rewrite before *it*
// resolves here — see that package's own Package.swift for the current state. This app will
// build cleanly the moment that lands, with no changes needed here.

let package = Package(
    name: "ComponentsDemo",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(path: "../../Components")
    ],
    targets: [
        .executableTarget(
            name: "ComponentsDemo",
            dependencies: [
                .product(name: "LocalLMLabSDKComponents", package: "Components")
            ]
        )
    ]
)
