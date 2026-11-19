import Testing
import Foundation
import FoundationModels
import LocalLMLabSDKCore
import LocalLMLabSDKComponents

// The SwiftUI presenter as a ToolConfirmationChannel.

private func call(_ name: String = "writeThing", impact: ToolImpact = .mutate) -> PendingToolCall {
    PendingToolCall(
        toolName: name, arguments: GeneratedContent(kind: .string("x")),
        argumentsDescription: "x", origin: .host, impact: impact)
}

@available(macOS 26.0, *)
@MainActor
@Test func belowThresholdAllowsWithoutQueuing() async {
    let presenter = ToolConfirmationPresenter()
    let auth = ConfirmingToolAuthorizer(channel: presenter)
    guard case .allow = await auth.authorize(call(impact: .read)) else {
        Issue.record("read should allow without confirmation"); return
    }
    #expect(presenter.pending.isEmpty)
}

@available(macOS 26.0, *)
@MainActor
@Test func mutateQueuesAndResolves() async {
    let presenter = ToolConfirmationPresenter()
    let auth = ConfirmingToolAuthorizer(channel: presenter)

    async let decision = auth.authorize(call(impact: .mutate))

    var tries = 0
    while presenter.pending.isEmpty && tries < 100 {
        try? await Task.sleep(for: .milliseconds(10)); tries += 1
    }
    #expect(presenter.pending.count == 1)
    presenter.resolve(presenter.pending[0].id, allow: true)

    guard case .allow = await decision else { Issue.record("approved → allow"); return }
    #expect(presenter.pending.isEmpty)
}

@available(macOS 26.0, *)
@MainActor
@Test func declineDenies() async {
    let presenter = ToolConfirmationPresenter()
    let auth = ConfirmingToolAuthorizer(channel: presenter)

    async let decision = auth.authorize(call(impact: .destructive))
    var tries = 0
    while presenter.pending.isEmpty && tries < 100 {
        try? await Task.sleep(for: .milliseconds(10)); tries += 1
    }
    presenter.resolve(presenter.pending[0].id, allow: false)

    guard case .deny = await decision else { Issue.record("declined → deny"); return }
}

@available(macOS 26.0, *)
@MainActor
@Test func timeoutDenies() async {
    let presenter = ToolConfirmationPresenter()
    let auth = ConfirmingToolAuthorizer(channel: presenter, timeout: .milliseconds(50))

    guard case .deny = await auth.authorize(call(impact: .mutate)) else {
        Issue.record("an unanswered sheet should deny on timeout"); return
    }
}

/// The standard MCP note follows the call's impact, and a forced check offers neither Always Allow nor Trust.
@available(macOS 26.0, *)
@MainActor
@Test func standardMCPExtrasMatchTheCall() {
    let lab = LocalLMLab(configuration: .init(providers: []))
    func server(_ name: String, trust: MCPServerTrust) -> MCPServerID {
        let url = URL(string: "https://\(name.lowercased()).example/mcp")!
        let id = MCPServerID(rawValue: url.absoluteString)
        lab.mcp.restore(from: lab.mcp.snapshot() + [MCPServerSnapshot(
            id: id, url: url, displayName: name, authType: .none, manualClientID: nil, enabled: true, tools: [],
            trust: trust, toolApproval: nil, toolApprovals: [:], excludedTools: [])])
        return id
    }
    let trusted = server("HuggingFace", trust: .trusted)
    let untrusted = server("Orders", trust: .untrusted)
    let presenter = ToolConfirmationPresenter()
    presenter.useStandardMCPExtras(manager: lab.mcp, appName: "Test Chat")
    func extras(_ id: MCPServerID, _ name: String, impact: ToolImpact, requiresUser: Bool = false) -> ToolConfirmationExtras {
        presenter.extras!(PendingToolCall(toolName: "hf_fs", arguments: nil, argumentsDescription: "", origin: .mcp(server: id, displayName: name),
                                          impact: impact, impactReason: requiresUser ? "Copied from a page." : nil, requiresUser: requiresUser))
    }
    // The screenshot's case: a read asked on a trusted server no longer says it "changes data".
    #expect(extras(trusted, "HuggingFace", impact: .read).note == nil)
    #expect(extras(trusted, "HuggingFace", impact: .mutate).note == "HuggingFace is trusted; its labels say hf_fs changes data.")
    #expect(extras(trusted, "HuggingFace", impact: .destructive).note == "HuggingFace is trusted; its labels say hf_fs can delete.")
    #expect(extras(trusted, "HuggingFace", impact: .read).alwaysAllow != nil)
    for (id, name) in [(trusted, "HuggingFace"), (untrusted, "Orders")] {
        let forced = extras(id, name, impact: .read, requiresUser: true)
        #expect(forced.note == "This check asks every time, whatever \(name)'s trust or Always Allow says.")
        #expect(forced.alwaysAllow == nil && forced.trust == nil)
    }
    #expect(extras(untrusted, "Orders", impact: .mutate).trust != nil)
}
