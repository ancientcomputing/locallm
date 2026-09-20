import Testing
import Foundation
import LocalLMLabSDKCore
import LocalLMLabSDKComponents

// The SwiftUI presenter as an MCPElicitationHandler: queues a request, resolves when the sheet
// decides, auto-cancels on timeout.

@available(macOS 26.0, *)
private func request(_ message: String = "hi", url: URL? = nil) -> MCPElicitationRequest {
    MCPElicitationRequest(
        message: message,
        rawSchema: Data("{}".utf8),
        fields: [MCPElicitationField(name: "name", title: nil, description: nil, required: true, defaultValue: nil, kind: .string(format: nil))],
        url: url)
}

@available(macOS 26.0, *)
@MainActor
@Test func queuesRequestAndResolvesWithTheSheetsDecision() async {
    let presenter = MCPElicitationPresenter()

    async let answer = presenter.handleElicitation(request())
    // Give the continuation a tick to enqueue.
    try? await Task.sleep(for: .milliseconds(20))
    #expect(presenter.pending.count == 1)

    let id = presenter.pending[0].id
    presenter.resolve(id, .accept(["name": .string("Ada")]))

    #expect(await answer == .accept(["name": .string("Ada")]))
    #expect(presenter.pending.isEmpty)
}

@available(macOS 26.0, *)
@MainActor
@Test func autoCancelsAfterTheFallbackTimeout() async {
    let presenter = MCPElicitationPresenter(fallbackTimeout: .milliseconds(50))
    let answer = await presenter.handleElicitation(request())
    #expect(answer == .cancel)
    #expect(presenter.pending.isEmpty)
}

@available(macOS 26.0, *)
@MainActor
@Test func resolveIsANoOpForAnUnknownID() {
    let presenter = MCPElicitationPresenter()
    presenter.resolve(UUID(), .decline)   // must not crash
    #expect(presenter.pending.isEmpty)
}
