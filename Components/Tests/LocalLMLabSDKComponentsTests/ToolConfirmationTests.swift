import Testing
import Foundation
import FoundationModels
import LocalLMLabSDKCore
@testable import LocalLMLabSDKComponents

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
