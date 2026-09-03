import Foundation
import FoundationModels
import LocalLMLabSDKCore
import LocalLMLabSDKInference

// See Package.swift for the four scenarios. `swift run OSMatrix` on macOS 26 and macOS 27 to
// see the same binary behave differently — no source #if, just #available.

@MainActor
func run() async throws {
    // ── Scenario 4: register what the running OS supports ──────────────────────────────────
    // SystemModelProvider works on macOS 26 and 27. The rest need macOS 27, so they go in one
    // #available block. Everything AFTER this line is identical on both OSes.
    var providers: [any ModelProvider] = [SystemModelProvider()]
    if #available(macOS 27, *) {
        providers.append(PCCModelProvider())
        providers.append(MLXModelProvider())
    }
    let lab = LocalLMLab(configuration: .init(providers: providers))
    lab.models.route("chat", to: .system)

    // ── Model availability table ──────────────────────────────────────────────────────────
    // On macOS 26: system = available; pcc / claude / mlx = .requiresOS("macOS 27").
    // On macOS 27: system + pcc = available; mlx = .notDownloaded; claude = .requiresOS
    //   (still no provider — this package can't link LocalLMLabSDKClaude; see the README).
    let v = ProcessInfo.processInfo.operatingSystemVersion
    print("Running on macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)\n")
    print("Model families:")
    for id in [ModelID.system, .pcc, ModelID("claude:sonnet5")!, ModelID(scheme: "mlx", rest: "mlx-community/Qwen3-4B-4bit")!] {
        let name = id.rawValue.padding(toLength: 42, withPad: " ", startingAt: 0)
        print("  \(name) \(describe(lab.models.availability(for: id)))")
    }
    if !lab.models.schemesRequiringNewerOS.isEmpty {
        print("\n  (\(lab.models.schemesRequiringNewerOS.joined(separator: ", ")) need macOS 27 — a picker shows these as disabled rows)")
    }

    // ── Scenario 3: connector tools that work on both OSes ─────────────────────────────────
    let tools: [any Tool] = [ClockTool(), WeatherTool()]

    // ── Scenario 1: the same call, identical on 26 and 27 ──────────────────────────────────
    let session = try lab.makeSession(route: "chat", tools: tools,
        instructions: "You have getCurrentTime and getWeather tools. Use them; be concise.")
    print("\nAsking the on-device model (with tools) …")
    let answer = try await session.respond(to: "What time is it, and what's the weather in Tokyo?")
    print("→ \(answer)")

    // ── Scenario 2: a feature that only exists on macOS 27 ─────────────────────────────────
    if #available(macOS 27, *), let mlx = lab.models.downloadableProviders.first {
        print("\nmacOS 27: could download an open-weight model via \(type(of: mlx).scheme):")
        print("  try await lab.models.startDownload(\"mlx-community/Qwen3-4B-4bit\")")
    } else {
        print("\nmacOS 26: open-weight (MLX) model download is unavailable — needs macOS 27.")
    }
}

func describe(_ a: ModelAvailability) -> String {
    switch a {
    case .available: return "available"
    case .notDownloaded: return "not downloaded"
    case .needsCredential: return "needs credential"
    case .unavailable(let kind, let detail):
        if case .requiresOS(let os) = kind { return "requires \(os)" }
        return "unavailable — \(detail)"
    @unknown default:
        return "unknown"
    }
}

try await run()
