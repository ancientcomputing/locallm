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
    platforms: [.macOS("27.0")],
    dependencies: [
        .package(path: "../../Components")
    ],
    targets: [
        .executableTarget(
            name: "ComponentsDemo",
            dependencies: [
                .product(name: "LocalLMLabSDKComponents", package: "Components")
            ],
            linkerSettings: [
                // SwiftPM's Swift Build system (default in the Xcode 27 toolchain) gives a bare
                // executable target no LC_RPATH, so `@rpath/LocalLMLabSDKCore.framework/...`
                // (Core reaches here transitively through Components) resolves to nothing and the
                // app aborts at launch ("no LC_RPATH's found"). The Core framework sits next to
                // the executable — in `swift build` output and, once packaged, in Contents/MacOS
                // — so point rpath at @executable_path. Same fix as code-buddy.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path"])
            ]
        )
    ]
)
