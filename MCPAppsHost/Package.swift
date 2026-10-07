// swift-tools-version: 6.0
import PackageDescription

// LocalLMLabSDKMCPAppsHost — host-side support for MCP Apps (SEP-1865, spec 2026-01-26): the
// `ui://` widgets an MCP server ships and a host renders in a sandboxed view. Open source
// (Apache 2.0), shipped as SOURCE like Components, and built on LocalLMLabSDKCore's PUBLIC API
// only.
//
// Core comes from Components, which declares the LocalLMLabSDKCore binary target and re-vends it
// (two packages declaring that binary target is a hard SwiftPM error). So this package has no
// SDK version or checksum of its own: it builds against whatever Components' `defaultSDKVersion`
// / LOCALLM_SDK_VERSION selects. Requires SDK 2.0.0-GA or later.
//
// What is here: metadata parsing (`_meta.ui`) and the `ui://` resource loader (mime check, size,
// SHA-256); `MCPAppsBridge`, the JSON-RPC state machine between a widget and the host, with an
// explicit policy and an audit sink; `MCPAppViewController` / `MCPAppView`, the sandboxed
// WKWebView; `MCPAppsSessionBackend`, which routes a widget's calls through a LocalLMLabSession;
// and the widget lifecycle — `MCPAppWidgetCache`, `MCPAppViewPool`, `MCPAppRecreation`.
let package = Package(
    name: "LocalLMLabSDKMCPAppsHost",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "LocalLMLabSDKMCPAppsHost", targets: ["LocalLMLabSDKMCPAppsHost"])
    ],
    dependencies: [
        .package(path: "../Components")
    ],
    targets: [
        .target(
            name: "LocalLMLabSDKMCPAppsHost",
            dependencies: [.product(name: "LocalLMLabSDKCore", package: "Components")]
        ),
        .testTarget(
            name: "LocalLMLabSDKMCPAppsHostTests",
            dependencies: ["LocalLMLabSDKMCPAppsHost"]
        )
    ]
)
