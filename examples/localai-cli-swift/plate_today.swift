#!/usr/bin/env swift
//
// plate_today.swift — "what's on my plate today", via localai-cli
//
// WHAT THIS SCRIPT DOES
//     A Swift port of examples/localai-cli/plate_today.py, itself a
//     localai-cli port of the SDK's examples/plate-today reference app
//     (locallmlab-sdk): checks Calendar, Reminders, and Todoist for what's
//     due today and asks the on-device model to summarize the day. Like
//     that Python version (and unlike the SDK's Swift app), this is a plain
//     script — no EventKit calls of its own, no TCC prompts triggered by
//     this process. It relies entirely on connectors/MCP tools LocalLM Lab
//     already has permission for:
//         - Calendar and Reminders come in as the "calendar"/"reminders"
//           connectors (same as run_localai.swift's "clock", just two more
//           built-ins — see Local AI Settings).
//         - Todoist comes in as an MCP tool call (same pattern as
//           run_localai.swift's --mcp mode) against Todoist's hosted MCP
//           server, find-tasks-by-date.
//
//     The model has no reliable notion of "today" on its own (FoundationModels
//     has no live wall-clock awareness), so this also requests the "clock"
//     connector (getCurrentTime) and instructs the model to look up the
//     actual current date first, then match "today" against calendar/
//     reminders/Todoist using that date — rather than guessing or using a
//     stale/training notion of "today".
//
//     Before ever calling localai-cli, this script reads localai-config.json
//     itself and checks all four sources are actually usable: the three
//     connectors enabled, and the Todoist server connected + enabled with
//     find-tasks-by-date enabled on it. This is a deliberate preflight, not
//     something localai-cli does for you — localai-cli validates one --run
//     request's fields against the config, but only reports the *first*
//     problem it hits, and won't tell you "connected but not enabled" apart
//     from "not connected at all". Checking all four up front means one
//     run tells you a full checklist of anything still missing, before
//     burning a model call that was always going to fail.
//
// REQUIREMENTS
//     - Everything run_localai.swift requires: localai-cli +
//       localai-playground-run next to this script (or LOCALAI_CLI_PATH
//       set), LocalLM Lab running (connector/MCP calls relay through its
//       chooser process over a local socket).
//     - In LocalLM Lab's Local AI Settings: "System Clock", "Calendar", and
//       "Reminders" connectors enabled (Calendar/Reminders each prompt for
//       their own TCC grant the first time; System Clock has no permission
//       dialog).
//     - In LocalLM Lab's MCP Servers panel: Todoist added and connected
//       (https://ai.todoist.net/mcp by default — override with
//       LOCALAI_MCP_SERVER), with the find-tasks-by-date tool's checkbox on
//       (override the tool name with LOCALAI_MCP_TOOL).
//
// RUN
//     swift plate_today.swift
//
// EXPECTED BEHAVIOR (if everything is working)
//     - Prints the resolved localai-cli/config paths.
//     - Prints a checklist confirming all four sources are ready.
//     - Prints the model's summary of the day.
//     - Ends with "PASS - plate_today run succeeded."
//
// WHAT FAILURE LOOKS LIKE
//     - "localai-cli not found at ..." - same fix as run_localai.swift.
//     - {"error": "config file not found: ..."} at the very first check - no
//       localai-config.json exists yet; run LocalLM Lab at least once and
//       open Local AI Settings/MCP Servers so it gets created.
//     - A preflight checklist with one or more "MISSING" lines and no model
//       call at all - this is the expected, helpful-message path when
//       something isn't set up yet. Each line names the exact panel/toggle
//       to fix. The script exits(1) without ever invoking localai-cli in
//       this case, so nothing about the failure comes from the model or
//       localai-cli itself.
//     - Everything else - a connector/MCP rejection from localai-cli
//       itself, a transient FoundationModels generation error, etc. -
//       behaves the same as run_localai.swift's --mcp mode.

import Foundation

// --- CONFIG: edit these, or set the equivalent environment variables ---
let env = ProcessInfo.processInfo.environment

let localaiCLIPath = env["LOCALAI_CLI_PATH"]
    ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("localai-cli").path

let localaiConfigPath = env["LOCALAI_CONFIG_PATH"]
    ?? NSHomeDirectory() + "/Library/Application Support/LocalLM Lab/localai-config.json"

// Same default Todoist hosted MCP server + tool the Python version and the
// SDK's Plate Today example use. Override if you connected Todoist at a
// different URL, or want a different tool (both need to match what's in
// localai-config.json's "mcp_servers" array exactly — see MCP Servers in
// LocalLM Lab).
let todoistMCPURL = env["LOCALAI_MCP_SERVER"] ?? "https://ai.todoist.net/mcp"
let todoistMCPTool = env["LOCALAI_MCP_TOOL"] ?? "find-tasks-by-date"
// ------------------------------------------------------------------------

// Panel labels for the message printed when a connector isn't enabled —
// "clock" shows up in Local AI Settings as "System Clock", not "Clock".
let connectorLabels = ["clock": "System Clock", "calendar": "Calendar", "reminders": "Reminders"]
let requiredConnectors = ["clock", "calendar", "reminders"]

struct LocalAIError: Error, CustomStringConvertible {
    let description: String
}

struct PreflightCheck {
    let source: String
    let ok: Bool
    let detail: String
}

/// Loads localai-config.json as a loose JSON dictionary. Throws if the file
/// doesn't exist or isn't valid JSON — every downstream read from the
/// result is a defensive optional-cast, never a force-cast, so an
/// unexpected shape reads as "missing/not enabled" rather than crashing.
func loadConfig(path: String) throws -> [String: Any] {
    guard FileManager.default.fileExists(atPath: path) else {
        throw LocalAIError(description:
            "config file not found: \(path)\n" +
            "Run LocalLM Lab at least once and open Local AI Settings/MCP " +
            "Servers so it gets created.")
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw LocalAIError(description: "config file at \(path) is not a JSON object.")
    }
    return json
}

/// Checks the clock, Calendar, Reminders, and Todoist are all usable.
///
/// Returns one PreflightCheck per source checked — used both to print a
/// full checklist and to decide whether to proceed.
func preflight(config: [String: Any]) -> [PreflightCheck] {
    var results: [PreflightCheck] = []

    let enabledConnectors = Set((config["connectors_enabled"] as? [String]) ?? [])
    for connector in requiredConnectors {
        if enabledConnectors.contains(connector) {
            results.append(PreflightCheck(source: connector, ok: true, detail: "enabled"))
        } else {
            let label = connectorLabels[connector] ?? connector
            results.append(PreflightCheck(
                source: connector, ok: false,
                detail: "not enabled — turn on \"\(label)\" in Local AI Settings"
            ))
        }
    }

    let mcpServers = (config["mcp_servers"] as? [[String: Any]]) ?? []
    let server = mcpServers.first { ($0["url"] as? String) == todoistMCPURL }

    if server == nil {
        results.append(PreflightCheck(
            source: "todoist", ok: false,
            detail: "not configured — add \(todoistMCPURL) in MCP Servers"
        ))
    } else if (server?["enabled"] as? Bool) != true {
        results.append(PreflightCheck(
            source: "todoist", ok: false,
            detail: "server added but disabled — enable it in MCP Servers"
        ))
    } else if (server?["connection_status"] as? String) != "connected" {
        let status = (server?["connection_status"] as? String) ?? "unknown"
        results.append(PreflightCheck(
            source: "todoist", ok: false,
            detail: "not connected (status: \"\(status)\") — click Reconnect in MCP Servers"
        ))
    } else {
        let tools = (server?["tools"] as? [[String: Any]]) ?? []
        let tool = tools.first { ($0["name"] as? String) == todoistMCPTool }
        if tool == nil {
            let available = tools.compactMap { $0["name"] as? String }.joined(separator: ", ")
            results.append(PreflightCheck(
                source: "todoist", ok: false,
                detail: "tool \"\(todoistMCPTool)\" not found on server (available: \(available))"
            ))
        } else if (tool?["enabled"] as? Bool) != true {
            results.append(PreflightCheck(
                source: "todoist", ok: false,
                detail: "tool \"\(todoistMCPTool)\" is disabled — enable its checkbox in MCP Servers"
            ))
        } else {
            results.append(PreflightCheck(
                source: "todoist", ok: true,
                detail: "connected, \"\(todoistMCPTool)\" enabled"
            ))
        }
    }

    return results
}

/// Invokes `localai-cli --run` with clock/calendar/reminders/Todoist and
/// returns its parsed JSON response as a dictionary. Throws only if
/// localai-cli itself couldn't be executed (e.g. missing binary) - a
/// rejection or model error is NOT thrown, it comes back as a normal
/// dictionary with an "error" key, same as localai-cli's own stdout
/// contract.
func runLocalAIPlateToday() throws -> [String: Any] {
    guard FileManager.default.isExecutableFile(atPath: localaiCLIPath) else {
        throw LocalAIError(description:
            "localai-cli not found at \(localaiCLIPath) - set LOCALAI_CLI_PATH " +
            "or place the binary next to this script.")
    }

    let request: [String: Any] = [
        "system_prompt": """
            You are a friendly, concise personal assistant. Always start by \
            calling getCurrentTime to find out today's actual date — never \
            assume or guess it. Then use the available tools to check the \
            user's calendar, reminders, and Todoist tasks for that date, and \
            summarize their day.
            """,
        "user_input": """
            What's on my plate today? First check the current date with your \
            clock tool, then check my calendar events, my reminders due \
            today, and my Todoist tasks due today (exclude overdue tasks — \
            only today's, matched against the date you just looked up), then \
            give me a friendly, concise summary of my day.
            """,
        "connectors": requiredConnectors,
        "mcp_tools": [["server": todoistMCPURL, "tool": todoistMCPTool]],
    ]
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
    print("localai-cli path : \(localaiCLIPath)")
    print("config path      : \(localaiConfigPath)")
    print("todoist server   : \(todoistMCPURL)")
    print("todoist tool     : \(todoistMCPTool)\n")

    let config: [String: Any]
    do {
        config = try loadConfig(path: localaiConfigPath)
    } catch {
        print("FAIL - \(error)")
        exit(1)
    }

    print("Checking sources are set up in LocalLM Lab...")
    let checks = preflight(config: config)
    for check in checks {
        let status = check.ok ? "OK     " : "MISSING"
        print("  [\(status)] \(check.source): \(check.detail)")
    }
    print()

    if checks.contains(where: { !$0.ok }) {
        print(
            "FAIL - not all sources are set up yet. Fix the MISSING item(s) " +
            "above in LocalLM Lab, then run this again."
        )
        exit(1)
    }

    print("All sources ready. Asking the model to summarize your day...\n")

    let response: [String: Any]
    do {
        response = try runLocalAIPlateToday()
    } catch {
        print("FAIL - \(error)")
        exit(1)
    }

    if let errorMessage = response["error"] as? String, !errorMessage.isEmpty {
        print("FAIL - localai-cli rejected the request or the model errored:")
        print("  \(errorMessage)")
        exit(1)
    }

    print("What's on your plate today:")
    print("  \(response["answer"] as? String ?? "")\n")
    print("PASS - plate_today run succeeded.")
}

main()
