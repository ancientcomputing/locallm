#!/usr/bin/env swift
//
// quickstart_clock.swift — the fastest possible localai-cli demo, no setup
//
// Calls the local AI with the "clock" connector - the only connector that
// needs zero macOS permission dialogs (see web/connectors.html) - and asks
// it the current time. Nothing to configure below.
//
// SETUP (about 30 seconds)
//     1. Run LocalLM Lab at least once.
//     2. Open the Connectors screen and turn on the "System Clock" connector.
//        No permission prompt appears for this one.
//     3. Download localai-toolkit-<version>-arm64.zip, unzip it, and place
//        localai-cli + localai-playground-run next to this script (or set
//        LOCALAI_CLI_PATH).
//
// RUN
//     swift quickstart_clock.swift
//
// EXPECTED OUTPUT
//     The model's answer, which should state the current time - proof the
//     "clock" connector's tool call actually happened.
//
// NOTE FOR INTEGRATING INTO YOUR OWN APP
//     This file is a standalone script, run with `swift quickstart_clock.swift`
//     - it is NOT meant to be pasted into an Xcode project. Top-level
//     executable statements like the ones below only compile in a script
//     file like this one; a regular .swift file inside an app target can't
//     have them. If you're building a real app, copy the `runLocalAI(...)`
//     function from run_localai.swift instead - same subprocess call, but
//     packaged as an ordinary throwing function you can call from anywhere.

import Foundation

let env = ProcessInfo.processInfo.environment
let localaiCLIPath = env["LOCALAI_CLI_PATH"]
    ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("localai-cli").path
let localaiConfigPath = env["LOCALAI_CONFIG_PATH"]
    ?? NSHomeDirectory() + "/Library/Application Support/LocalLM Lab/app-config.json"

func main() throws {
    guard FileManager.default.isExecutableFile(atPath: localaiCLIPath) else {
        print("FAIL - localai-cli not found at \(localaiCLIPath)")
        print("Set LOCALAI_CLI_PATH, or place the toolkit binaries next to this script.")
        exit(1)
    }

    let request: [String: Any] = [
        "system_prompt": "You are a concise assistant.",
        "user_input": "What time is it right now?",
        "connectors": ["clock"],
    ]
    let requestData = try JSONSerialization.data(withJSONObject: request)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: localaiCLIPath)
    process.arguments = ["--config", localaiConfigPath, "--run"]

    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = Pipe()

    try process.run()
    stdinPipe.fileHandleForWriting.write(requestData)
    try stdinPipe.fileHandleForWriting.close()

    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    guard let response = try? JSONSerialization.jsonObject(with: stdoutData) as? [String: Any] else {
        print("FAIL - no parseable JSON (exit \(process.terminationStatus))")
        print(String(data: stdoutData, encoding: .utf8) ?? "")
        exit(1)
    }

    if let errorMessage = response["error"] as? String, !errorMessage.isEmpty {
        print("FAIL - \(errorMessage)")
        if errorMessage.contains("not enabled") {
            print("\nFix: open the Connectors screen in LocalLM Lab and turn on \"System Clock\".")
        }
        exit(1)
    }

    print(response["answer"] as? String ?? "")
}

do {
    try main()
} catch {
    print("FAIL - \(error)")
    exit(1)
}
