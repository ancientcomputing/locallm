#!/usr/bin/env swift
//
// quickstart_mcp_deepwiki.swift — the fastest possible MCP demo, no auth
//
// Calls the local AI with one tool from DeepWiki - the MCP server with the
// lowest setup cost of any on web/mcp-servers.html: auth type "None",
// "connects immediately," no OAuth consent screen, no API key. Everything
// below is pre-filled with the exact server/tool/prompt from that page.
//
// SETUP (about a minute)
//     1. Run LocalLM Lab, open the MCP Servers panel.
//     2. Add Server -> URL: https://mcp.deepwiki.com/mcp, display name:
//        "DeepWiki", auth type: None. Click Add - no sign-in required.
//     3. In the DeepWiki entry, enable the "read_wiki_structure" tool
//        (every newly connected server starts with all tools off).
//     4. Download localai-toolkit-<version>-arm64.zip, unzip it, and place
//        localai-cli + localai-playground-run next to this script (or set
//        LOCALAI_CLI_PATH).
//
// RUN
//     swift quickstart_mcp_deepwiki.swift
//
// EXPECTED OUTPUT
//     The model's answer listing documentation topics for a real public
//     GitHub repo - proof the MCP tool call actually reached DeepWiki.
//
// NOTE FOR INTEGRATING INTO YOUR OWN APP
//     This file is a standalone script, run with
//     `swift quickstart_mcp_deepwiki.swift` - it is NOT meant to be pasted
//     into an Xcode project. Top-level executable statements like the ones
//     below only compile in a script file like this one; a regular .swift
//     file inside an app target can't have them. If you're building a real
//     app, copy the `runLocalAI(...)` function from run_localai.swift
//     instead - same subprocess call, but packaged as an ordinary throwing
//     function you can call from anywhere.

import Foundation

let env = ProcessInfo.processInfo.environment
let localaiCLIPath = env["LOCALAI_CLI_PATH"]
    ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("localai-cli").path
let localaiConfigPath = env["LOCALAI_CONFIG_PATH"]
    ?? NSHomeDirectory() + "/Library/Application Support/LocalLM Lab/app-config.json"

// Exactly the server URL, tool, and example prompt from web/mcp-servers.html's
// DeepWiki section - nothing to fill in yourself.
let mcpServer = "https://mcp.deepwiki.com/mcp"
let mcpTool = "read_wiki_structure"
let userInput = "What documentation topics are available for the GitHub repo nickclyde/duckduckgo-mcp-server?"

func main() throws {
    guard FileManager.default.isExecutableFile(atPath: localaiCLIPath) else {
        print("FAIL - localai-cli not found at \(localaiCLIPath)")
        print("Set LOCALAI_CLI_PATH, or place the toolkit binaries next to this script.")
        exit(1)
    }

    let request: [String: Any] = [
        "system_prompt": "You are a concise assistant. Use the available tool to answer.",
        "user_input": userInput,
        "mcp_tools": [["server": mcpServer, "tool": mcpTool]],
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
        if errorMessage.contains("not configured") {
            print("\nFix: add the DeepWiki server (\(mcpServer)) in the MCP Servers panel.")
        } else if errorMessage.contains("not enabled") && errorMessage.contains("server") {
            print("\nFix: the DeepWiki server is added but toggled off - enable it in MCP Servers.")
        } else if errorMessage.contains("not enabled") {
            print("\nFix: enable the \"\(mcpTool)\" tool on the DeepWiki server in MCP Servers.")
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
