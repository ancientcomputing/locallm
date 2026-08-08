#!/usr/bin/env swift
//
// run_localai.swift — call localai-cli from Swift, no LocalLM Lab server running
//
// WHAT THIS SCRIPT DOES
//     Same pattern as examples/localai-cli/run_localai.py: spawn `localai-cli`
//     as a subprocess, write a JSON request to its stdin, read its JSON
//     response from stdout. This does NOT talk to LocalLM Lab's Go server or
//     its HTTP API at all — localai-cli and localai-playground-run are
//     self-contained binaries.
//
//     localai-cli reads a config file (localai-config.json, authored by
//     LocalLM Lab's Local AI Settings screen) that lists which connectors
//     and MCP server tools the user has granted/enabled. Every request to
//     localai-cli explicitly lists which of those it wants active for that
//     one call, via "connectors" and "mcp_tools" fields:
//         - Anything requested must already be enabled in
//           localai-config.json, or localai-cli rejects the request with a
//           JSON {"error": "..."} before ever invoking the model.
//         - Enabled-but-not-requested connectors/tools simply aren't given
//           to that call — no error, just a narrower toolset.
//         - Omitting a field entirely means nothing from that category is
//           active for the call — a deliberate least-privilege default.
//
// REQUIREMENTS
//     - macOS 26+ on Apple Silicon with Apple Intelligence enabled.
//     - localai-cli and localai-playground-run, downloaded together as the
//       localai-toolkit-<version>-arm64.zip release asset and unzipped
//       somewhere. Both must sit in the same directory (localai-cli's
//       default --helper-path assumes "next to me"), or pass a
//       LOCALAI_CLI_PATH pointing elsewhere.
//     - A localai-config.json produced by running LocalLM Lab at least once
//       and enabling whichever connectors/MCP tools you plan to request
//       below — see Local AI Settings / MCP Servers in the app. localai-cli
//       only reads this file, it never creates or edits it.
//
// RUN
//     swift run_localai.swift
//     LOCALAI_MCP_SERVER=... LOCALAI_MCP_TOOL=... swift run_localai.swift --mcp
//
// EXPECTED BEHAVIOR (if everything is working)
//     - Prints the resolved localai-cli/config paths being used.
//     - Prints the model's reply to a simple prompt.
//     - Ends with "PASS - localai-cli run succeeded."
//
// WHAT FAILURE LOOKS LIKE
//     - "localai-cli not found at ..." - fix LOCALAI_CLI_PATH below, or place
//       the binary where this script expects it.
//     - {"error": "config file not found: ..."} - fix LOCALAI_CONFIG_PATH.
//     - {"error": "connector '...' is not enabled in the config"} - the
//       connector requested below isn't turned on in Local AI Settings.
//     - {"error": "MCP server \"...\" is not configured"} /
//       "... is not enabled" / "MCP tool \"...\" is not known on server ..."
//       / "... is not enabled" - the --mcp request's server/tool doesn't
//       match what's configured/enabled in MCP Servers; see that screen in
//       LocalLM Lab for the exact server URL and tool names.
//     - Any other non-zero exit usually means localai-playground-run itself
//       failed (e.g. unsupported hardware/OS) - the printed JSON's "error"
//       field has the detail.

import Foundation

// --- CONFIG: edit these, or set the equivalent environment variables ---
let env = ProcessInfo.processInfo.environment

let localaiCLIPath = env["LOCALAI_CLI_PATH"]
    ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("localai-cli").path

let localaiConfigPath = env["LOCALAI_CONFIG_PATH"]
    ?? NSHomeDirectory() + "/Library/Application Support/LocalLM Lab/localai-config.json"

// Which connectors this particular call wants active - must already be
// enabled in localai-config.json, or localai-cli rejects the request before
// ever invoking the model. Empty means no connectors are made available.
let connectors = ["clock"]

// Used only when this script is run with `--mcp` - must match a server's
// "url" and one of its tools' "name" exactly, as they appear in
// localai-config.json's "mcp_servers" array (see MCP Servers in LocalLM
// Lab). Both server and tool must already be enabled there.
let mcpServer = env["LOCALAI_MCP_SERVER"] ?? "https://example-mcp-server.com/mcp"
let mcpTool = env["LOCALAI_MCP_TOOL"] ?? "example_tool"
// ------------------------------------------------------------------------

struct LocalAIError: Error, CustomStringConvertible {
    let description: String
}

/// Invokes `localai-cli --run` and returns its parsed JSON response as a
/// dictionary. Throws only if localai-cli itself couldn't be executed (e.g.
/// missing binary) - a rejection or model error is NOT thrown, it comes
/// back as a normal dictionary with an "error" key, same as localai-cli's
/// own stdout contract.
func runLocalAI(systemPrompt: String, userInput: String, connectors: [String] = [], mcpTools: [[String: String]] = []) throws -> [String: Any] {
    guard FileManager.default.isExecutableFile(atPath: localaiCLIPath) else {
        throw LocalAIError(description:
            "localai-cli not found at \(localaiCLIPath) - set LOCALAI_CLI_PATH " +
            "or place the binary next to this script.")
    }

    var request: [String: Any] = [
        "system_prompt": systemPrompt,
        "user_input": userInput,
        "connectors": connectors,
    ]
    if !mcpTools.isEmpty {
        request["mcp_tools"] = mcpTools
    }
    let requestData = try JSONSerialization.data(withJSONObject: request)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: localaiCLIPath)
    process.arguments = ["--config", localaiConfigPath, "--run"]

    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()
    stdinPipe.fileHandleForWriting.write(requestData)
    try stdinPipe.fileHandleForWriting.close()

    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    guard
        let json = try? JSONSerialization.jsonObject(with: stdoutData) as? [String: Any]
    else {
        let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
        throw LocalAIError(description:
            "localai-cli produced no parseable JSON (exit \(process.terminationStatus)).\n" +
            "stdout: \(stdoutText)\nstderr: \(stderrText)")
    }
    return json
}

func main() {
    let useMCP = CommandLine.arguments.contains("--mcp")

    print("localai-cli path : \(localaiCLIPath)")
    print("config path      : \(localaiConfigPath)")
    if useMCP {
        print("mcp server       : \(mcpServer)")
        print("mcp tool         : \(mcpTool)")
    } else {
        print("connectors       : \(connectors)")
    }
    print("Expecting: a short reply to a simple prompt, printed below.\n")

    let response: [String: Any]
    do {
        if useMCP {
            response = try runLocalAI(
                systemPrompt: "You are a concise assistant. Use the available tool if it helps answer the question.",
                userInput: "Use your tool to help answer, then summarize what you found in one sentence.",
                mcpTools: [["server": mcpServer, "tool": mcpTool]]
            )
        } else {
            response = try runLocalAI(
                systemPrompt: "You are a concise assistant.",
                userInput: "Say hello in exactly five words.",
                connectors: connectors
            )
        }
    } catch {
        print("FAIL - \(error)")
        exit(1)
    }

    if let errorMessage = response["error"] as? String, !errorMessage.isEmpty {
        print("FAIL - localai-cli rejected the request or the model errored:")
        print("  \(errorMessage)")
        exit(1)
    }

    print("Model replied:")
    print("  \(response["answer"] as? String ?? "")\n")
    print("PASS - localai-cli run\(useMCP ? " with MCP tool" : "") succeeded.")
}

main()
