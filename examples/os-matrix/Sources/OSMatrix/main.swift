import Foundation
import FoundationModels
import LocalLMLabSDKCore
import LocalLMLabSDKInference

// See Package.swift / README.md for the four scenarios. Run on macOS 26 and macOS 27 — same
// binary, no source `#if`, one `#available` check at provider registration.
//
//   swift run OSMatrix
//   swift run OSMatrix --download mlx-community/Qwen3-4B-4bit   # macOS 27 only; ~2–5 GB

@MainActor
func run() async throws {
    let args = CommandLine.arguments
    let downloadRepo: String? = args.firstIndex(of: "--download").flatMap { i in
        i + 1 < args.count ? args[i + 1] : nil
    }

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
    let v = ProcessInfo.processInfo.operatingSystemVersion
    print("Running on macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)\n")
    print("Model families:")
    for id in [ModelID.system, .pcc, ModelID("claude:sonnet5")!,
               ModelID(scheme: "mlx", rest: "mlx-community/Qwen3-4B-4bit")!] {
        let name = id.rawValue.padding(toLength: 42, withPad: " ", startingAt: 0)
        print("  \(name) \(describe(lab.models.availability(for: id)))")
    }
    if !lab.models.schemesRequiringNewerOS.isEmpty {
        print("\n  (\(lab.models.schemesRequiringNewerOS.joined(separator: ", ")) need macOS 27 — a picker shows these as disabled rows)")
    }

    // ── Scenario 2: `--download` — a feature that only exists on macOS 27 ──────────────────
    if let repo = downloadRepo {
        guard #available(macOS 27, *), !lab.models.downloadableProviders.isEmpty else {
            print("\n--download needs macOS 27 (open-weight models run via MLX, which is macOS 27+).")
            return
        }
        print("\nDownloading \(repo) from Hugging Face — fetches the weights (typically 2–5 GB)…")
        let installed = try await lab.models.startDownload(repo)   // resolves once the weights are on disk
        let size = installed.sizeBytes.map { " (\($0 / 1_000_000) MB)" } ?? ""
        print("Done: \(installed.id.rawValue)\(size). It's now .available — route a session to it:")
        print("  lab.models.route(\"chat\", to: ModelID(\"\(installed.id.rawValue)\")!)")
        print("  let session = try lab.makeSession(route: \"chat\")")
        return
    }

    // ── Scenario 3: connector tools that work on both OSes ─────────────────────────────────
    let tools: [any Tool] = [ClockTool(), WeatherTool()]

    // ── Scenario 1: the same call, identical on 26 and 27 ──────────────────────────────────
    let session = try lab.makeSession(route: "chat", tools: tools,
        instructions: "You have getCurrentTime and getWeather tools. Use them; be concise.")
    print("\nAsking the on-device model (with tools)…")
    let answer = try await session.respond(to: "What time is it, and what's the weather in Tokyo?")
    print("→ \(answer)")

    // ── Scenario 2 again: the hint, when --download wasn't passed ──────────────────────────
    if #available(macOS 27, *), !lab.models.downloadableProviders.isEmpty {
        print("""

        Open-weight (MLX) models are available on macOS 27. Download and run one with:
          swift run OSMatrix --download mlx-community/Qwen3-4B-4bit
        In code that's `try await lab.models.startDownload("<hugging-face-repo-id>")` — an
        async call your app makes (e.g. from a "Download" button). There is no CLI for it in
        the SDK; `lab.models.downloads` is the observable a picker binds to for a progress bar.
        """)
    } else {
        print("\nOpen-weight (MLX) models need macOS 27 — unavailable here.")
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

do {
    try await run()
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
