import Foundation
import FoundationModels

// Host-owned tools built on `Process` — the R15 pattern. The SDK does NOT ship these
// (sandbox + MAS incompatibility); a Developer-ID host implements process execution itself,
// scoped to the workspace, with its own safety policy. This file is that worked example.

/// Runs `exe args` in `cwd`, capturing stdout+stderr, with a timeout and a truncation cap.
///
/// Cancellation-aware: if the calling turn is cancelled (Ctrl-C in the interactive loop),
/// the child gets `SIGTERM` rather than being left to run orphaned.
func runProcess(_ exe: String, _ args: [String], cwd: URL, timeout: TimeInterval = 240) async -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: exe)
    process.arguments = args
    process.currentDirectoryURL = cwd
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    do {
        try process.run()
    } catch {
        return "Failed to launch \(exe): \(error.localizedDescription)"
    }

    let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)

    // Read + wait on a background thread so task cancellation can reach us; on cancel,
    // terminate the child, which closes the pipe and unblocks the read.
    let data: Data = await withTaskCancellationHandler {
        await withCheckedContinuation { (cont: CheckedContinuation<Data, Never>) in
            DispatchQueue.global().async {
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                cont.resume(returning: d)
            }
        }
    } onCancel: {
        if process.isRunning { process.terminate() }
    }
    deadline.cancel()

    var output = String(decoding: data, as: UTF8.self)
    let cap = 20_000
    if output.count > cap {
        output = String(output.prefix(cap)) + "\n…[truncated, \(output.count) chars total]"
    }
    let status = process.terminationStatus
    return output.isEmpty
        ? "(no output; exit \(status))"
        : "\(output)\n[exit \(status)]"
}

/// Read-only git. Mutating subcommands are refused — the host's policy, not the SDK's.
struct GitTool: Tool {
    let root: URL

    static let readOnlySubcommands: Set<String> = [
        "status", "diff", "log", "show", "branch", "blame", "ls-files", "ls-tree",
        "rev-parse", "describe", "remote", "tag", "shortlog", "grep", "cat-file", "reflog",
    ]

    @Generable struct Arguments {
        @Guide(description: "A read-only git subcommand with its args, e.g. \"status\", \"diff HEAD~1 -- Sources\", \"log --oneline -10\".")
        var command: String
    }

    let name = "git"
    var description: String {
        "Runs a read-only git command in the workspace. Allowed: \(Self.readOnlySubcommands.sorted().joined(separator: ", ")). Mutating commands (commit, push, reset, checkout, clean, rebase) are refused — make edits with applyPatch instead."
    }

    func call(arguments: Arguments) async throws -> String {
        try Task.checkCancellation()
        let parts = arguments.command
            .split(whereSeparator: { $0 == " " || $0 == "\n" })
            .map(String.init)
        guard let sub = parts.first else { return "No git subcommand given." }
        guard Self.readOnlySubcommands.contains(sub) else {
            return "Refused: '\(sub)' is not an allowed read-only git subcommand."
        }
        return await runProcess("/usr/bin/git", parts, cwd: root)
    }
}

/// Runs the workspace's test command (host-configured — not inferred).
struct RunTestsTool: Tool {
    let root: URL
    /// e.g. `["swift", "test"]` or `["npm", "test", "--silent"]`.
    let command: [String]

    @Generable struct Arguments {
        @Guide(description: "Optional substring to pass to the test runner's filter, to run a subset. Omit to run all tests.")
        var filter: String?
    }

    let name = "run_tests"
    var description: String {
        "Runs the project's test suite (`\(command.joined(separator: " "))`) in the workspace and returns the output. Pass `filter` to run a subset."
    }

    func call(arguments: Arguments) async throws -> String {
        try Task.checkCancellation()
        guard let exe = command.first else { return "No test command configured." }
        var args = Array(command.dropFirst())
        if let filter = arguments.filter, !filter.isEmpty {
            args += ["--filter", filter]  // works for `swift test`; adjust per runner
        }
        let resolved = exe.hasPrefix("/") ? exe : (which(exe) ?? "/usr/bin/env")
        let finalArgs = resolved == "/usr/bin/env" ? [exe] + args : args
        return await runProcess(resolved, finalArgs, cwd: root)
    }

    private func which(_ name: String) -> String? {
        for dir in ["/usr/bin", "/bin", "/usr/local/bin", "/opt/homebrew/bin"] {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}
