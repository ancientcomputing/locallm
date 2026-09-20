import Testing
import SwiftUI
import LocalLMLabSDKCore
@testable import LocalLMLabSDKComponents

@Test func draftFactoryPrefillsSchemeAndWebSearchSupport() {
    #expect(RemoteProviderDraft.new(.anthropic).scheme == "anthropic")
    #expect(RemoteProviderDraft.new(.anthropic).webSearchSupported)
    #expect(RemoteProviderDraft.new(.openRouter).webSearchSupported)
    #expect(!RemoteProviderDraft.new(.openAIChat).webSearchSupported)   // plain chat/completions
    #expect(RemoteProviderDraft.new(.openAICompatible).baseURL.contains("localhost"))
    #expect(RemoteProviderKind.allCases.count == 5)
}

@Test func draftIsIdentifiedByScheme() {
    let a = RemoteProviderDraft.new(.openAIChat)
    #expect(a.id == a.scheme)
}

@available(macOS 26.0, *)
@MainActor
@Test func viewsInstantiateAgainstALiveRegistry() throws {
    let registry = ModelRegistry()
    try registry.register(SystemModelProvider())

    var drafts = [RemoteProviderDraft.new(.anthropic)]
    _ = AIModelsSettingsView(
        registry: registry,
        providers: .constant(drafts),
        onSave: { _ in }, onRemove: { _ in })
    _ = ProviderSettingsSection(
        draft: .constant(drafts[0]), onSave: { _ in }, onRemove: {})
    drafts.removeAll()
}
