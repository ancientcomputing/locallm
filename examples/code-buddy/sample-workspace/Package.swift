// swift-tools-version: 5.9
import PackageDescription

// A minimal SwiftPM package used as the throwaway workspace for the code-buddy walkthrough
// (see ../README.md). Pure logic, no dependencies — `swift test` runs in a couple of seconds.
// As shipped, all four tests pass; the walkthrough's setup step introduces one regression so
// you can watch code-buddy find and fix it with the `run_tests` and `git` tools.
let package = Package(
    name: "Geometry",
    products: [
        .library(name: "Geometry", targets: ["Geometry"]),
    ],
    targets: [
        .target(name: "Geometry"),
        .testTarget(name: "GeometryTests", dependencies: ["Geometry"]),
    ]
)
