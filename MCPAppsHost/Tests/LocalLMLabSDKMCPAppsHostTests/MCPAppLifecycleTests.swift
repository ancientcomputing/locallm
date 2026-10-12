import AppKit
import Foundation
import FoundationModels
import LocalLMLabSDKCore
import Testing

import LocalLMLabSDKMCPAppsHost

// Widget lifecycle: content-addressed cache, re-creation decisions, revalidation, and the
// live-widget limit. Public API only.

private let server = MCPServerID(rawValue: "https://example.invalid/mcp")
private let uri = "ui://example/list"

private func widget(_ marker: String) -> MCPResourceContent {
    MCPResourceContent(uri: uri, mimeType: "text/html;profile=mcp-app",
                       text: "<!doctype html><html><body><p>\(marker)</p></body></html>",
                       meta: .object(["ui": .object(["prefersBorder": .bool(true)])]))
}

private func tool(outputSchema: String = #"{"type":"object","properties":{"tasks":{"type":"array"}}}"#,
                  readOnly: Bool? = nil) -> MCPToolDescriptor {
    MCPToolDescriptor(serverID: server, name: "find", description: "", rawSchema: Data("{}".utf8), estimatedTokens: 1,
                      outputSchema: Data(outputSchema.utf8),
                      meta: .object(["ui": .object(["resourceUri": .string(uri)])]),
                      annotations: readOnly.map { MCPToolAnnotations(readOnlyHint: $0) })
}

@MainActor
private struct FakeSource: MCPAppWidgetSource {
    var current: MCPResourceContent?
    var descriptor: MCPToolDescriptor?
    func currentResource(uri: String) async -> Result<MCPResourceContent, MCPServerError> {
        current.map { .success($0) } ?? .failure(.unreachable)
    }
    func currentDescriptor(tool: String) -> MCPToolDescriptor? { descriptor }
}

@MainActor
private func freshCache(maxBytes: Int = 64 * 1024 * 1024) -> MCPAppWidgetCache {
    MCPAppWidgetCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("MCPAppWidgetCacheTests-\(UUID().uuidString)"),
                      maxBytes: maxBytes)
}

@MainActor
@Suite(.serialized)
struct MCPAppLifecycleTests {
    // MARK: decision table

    @Test func decisions() {
        typealias R = MCPAppRecreation
        // reachable, same version
        #expect(R.decide(cachedSHA256: "a", currentSHA256: "a", outputSchemaUnchanged: true, toolIsReadOnly: false) == .render(viewOnly: false))
        // same version, schema changed: the cached widget matches the stored result
        #expect(R.decide(cachedSHA256: "a", currentSHA256: "a", outputSchemaUnchanged: false, toolIsReadOnly: false) == .render(viewOnly: false))
        // newer version, same schema: current widget with stored result
        #expect(R.decide(cachedSHA256: "a", currentSHA256: "b", outputSchemaUnchanged: true, toolIsReadOnly: false) == .render(viewOnly: false))
        // newer version, schema changed: refresh, automatic only for read-only tools
        #expect(R.decide(cachedSHA256: "a", currentSHA256: "b", outputSchemaUnchanged: false, toolIsReadOnly: true) == .needsRefresh(mayRefreshAutomatically: true))
        #expect(R.decide(cachedSHA256: "a", currentSHA256: "b", outputSchemaUnchanged: false, toolIsReadOnly: false) == .needsRefresh(mayRefreshAutomatically: false))
        // unknown cached version counts as changed
        #expect(R.decide(cachedSHA256: nil, currentSHA256: "b", outputSchemaUnchanged: false, toolIsReadOnly: false) == .needsRefresh(mayRefreshAutomatically: false))
        #expect(R.decide(cachedSHA256: nil, currentSHA256: "b", outputSchemaUnchanged: true, toolIsReadOnly: false) == .render(viewOnly: false))
        // offline
        #expect(R.decide(cachedSHA256: "a", currentSHA256: nil, outputSchemaUnchanged: true, toolIsReadOnly: false) == .render(viewOnly: true))
        #expect(R.decide(cachedSHA256: nil, currentSHA256: nil, outputSchemaUnchanged: true, toolIsReadOnly: false) == .unavailable)
        // pins
        #expect(R.decide(cachedSHA256: "a", currentSHA256: "b", outputSchemaUnchanged: true, toolIsReadOnly: false, approvedSHA256: ["a"]) == .notApproved)
        #expect(R.decide(cachedSHA256: "a", currentSHA256: "b", outputSchemaUnchanged: true, toolIsReadOnly: false, approvedSHA256: ["b"]) == .render(viewOnly: false))
        #expect(R.decide(cachedSHA256: "a", currentSHA256: nil, outputSchemaUnchanged: true, toolIsReadOnly: false, approvedSHA256: ["b"]) == .notApproved)
    }

    // MARK: cache

    @Test func theCacheKeepsVersionsAndRemembersWhichCallUsedWhich() throws {
        let cache = freshCache()
        let stored = try cache.store(widget("v1"), requestedURI: uri)
        cache.bind(recordID: "call-1", sha256: stored.sha256)
        let back = try #require(cache.resource(sha256: stored.sha256))
        #expect(back == stored)
        #expect(back.info.prefersBorder == true)
        #expect(cache.sha256(forRecord: "call-1") == stored.sha256)

        // A second instance on the same directory sees the same versions and bindings.
        let reopened = MCPAppWidgetCache(directory: cache.directory)
        #expect(reopened.sha256(forRecord: "call-1") == stored.sha256)
        #expect(reopened.resource(sha256: stored.sha256) == stored)
        #expect(MCPAppRecreation.cachedResource(recordID: "call-1", cache: reopened) == stored)
    }

    @Test func theCacheEvictsTheLeastRecentlyUsedVersion() throws {
        let cache = freshCache()
        let v1 = try cache.store(widget("v1"), requestedURI: uri)
        cache.maxBytes = cache.storedBytes * 2 + cache.storedBytes / 2  // room for two versions
        let v2 = try cache.store(widget("v2"), requestedURI: uri)
        _ = cache.resource(sha256: v1.sha256)  // v1 is now the most recently used
        let v3 = try cache.store(widget("v3"), requestedURI: uri)
        #expect(cache.storedVersions == [v1.sha256, v3.sha256])
        #expect(cache.resource(sha256: v2.sha256) == nil)
    }

    @Test func aTamperedCacheFileIsNotServed() throws {
        let cache = freshCache()
        let v1 = try cache.store(widget("v1"), requestedURI: uri)
        let other = try JSONEncoder().encode(["requestedURI": uri])
        try other.write(to: cache.directory.appendingPathComponent("\(v1.sha256).json"))
        #expect(cache.resource(sha256: v1.sha256) == nil)
    }

    // MARK: revalidation

    @Test func revalidateRendersTheCurrentWidgetWhenItIsTheSame() async throws {
        let cache = freshCache()
        let v1 = try cache.store(widget("v1"), requestedURI: uri)
        cache.bind(recordID: "c", sha256: v1.sha256)
        let r = await MCPAppRecreation.revalidate(recordID: "c", resourceURI: uri, callDescriptor: tool(),
                                                  source: FakeSource(current: widget("v1"), descriptor: tool()), cache: cache)
        #expect(r.decision == .render(viewOnly: false))
        #expect(r.resource == v1)
        #expect(!r.widgetChanged)
    }

    @Test func revalidateMovesACallToANewerCompatibleWidget() async throws {
        let cache = freshCache()
        let v1 = try cache.store(widget("v1"), requestedURI: uri)
        cache.bind(recordID: "c", sha256: v1.sha256)
        let r = await MCPAppRecreation.revalidate(recordID: "c", resourceURI: uri, callDescriptor: tool(),
                                                  source: FakeSource(current: widget("v2"), descriptor: tool()), cache: cache)
        #expect(r.decision == .render(viewOnly: false))
        #expect(r.widgetChanged)
        let v2 = try #require(r.resource)
        #expect(v2.sha256 != v1.sha256)
        #expect(cache.sha256(forRecord: "c") == v2.sha256)  // re-bound to the version now shown
    }

    @Test func revalidateAsksForARefreshWhenTheOutputChangedShape() async throws {
        let cache = freshCache()
        let v1 = try cache.store(widget("v1"), requestedURI: uri)
        cache.bind(recordID: "c", sha256: v1.sha256)
        let newShape = tool(outputSchema: #"{"type":"object","properties":{"items":{"type":"array"}}}"#, readOnly: true)
        let r = await MCPAppRecreation.revalidate(recordID: "c", resourceURI: uri, callDescriptor: tool(),
                                                  source: FakeSource(current: widget("v2"), descriptor: newShape), cache: cache)
        #expect(r.decision == .needsRefresh(mayRefreshAutomatically: true))
        #expect(r.resource == nil)
        #expect(cache.sha256(forRecord: "c") == v1.sha256)  // not re-bound
    }

    @Test func revalidateOfflineShowsTheCachedVersionViewOnly() async throws {
        let cache = freshCache()
        let v1 = try cache.store(widget("v1"), requestedURI: uri)
        cache.bind(recordID: "c", sha256: v1.sha256)
        let offline = await MCPAppRecreation.revalidate(recordID: "c", resourceURI: uri, callDescriptor: tool(),
                                                        source: FakeSource(current: nil, descriptor: nil), cache: cache)
        #expect(offline.decision == .render(viewOnly: true))
        #expect(offline.resource == v1)
        let nothing = await MCPAppRecreation.revalidate(recordID: "unknown", resourceURI: uri, callDescriptor: tool(),
                                                        source: FakeSource(current: nil, descriptor: nil), cache: cache)
        #expect(nothing.decision == .unavailable)
    }

    @Test func revalidateHonorsAPin() async throws {
        let cache = freshCache()
        let v1 = try cache.store(widget("v1"), requestedURI: uri)
        cache.bind(recordID: "c", sha256: v1.sha256)
        let r = await MCPAppRecreation.revalidate(recordID: "c", resourceURI: uri, callDescriptor: tool(),
                                                  source: FakeSource(current: widget("v2"), descriptor: tool()), cache: cache,
                                                  approvedSHA256: [v1.sha256])
        #expect(r.decision == .notApproved)
        #expect(r.resource == nil)
    }

    @Test func toolInputComesFromTheCallsArguments() throws {
        let args = try GeneratedContent(json: #"{"startDate":"today","limit":5}"#)
        #expect(MCPAppRecreation.toolInput(from: args) == ["startDate": .string("today"), "limit": .number(5)])
        #expect(MCPAppRecreation.toolInput(from: nil).isEmpty)
    }

    // MARK: live-widget limit

    private func controller() throws -> MCPAppViewController {
        let resource = try MCPAppResource(content: widget("pool"), requestedURI: uri)
        return MCPAppViewController(resource: resource, tools: [], backend: NoBackend(),
                                    configuration: MCPAppsBridgeConfiguration(hostName: "T", hostVersion: "1",
                                                                              teardownTimeout: .milliseconds(50)))
    }

    @Test func thePoolKeepsTheLimitAndSnapshotsWhatItReleases() async throws {
        _ = NSApplication.shared
        let pool = MCPAppViewPool(limit: 2)
        var made = 0
        var windows: [NSWindow] = []
        func open(_ key: String) async throws -> MCPAppViewController {
            let c = try pool.controller(for: key) { made += 1; return try controller() }
            if c.webView.window == nil {
                let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
                w.contentView = c.webView
                w.orderFrontRegardless()
                windows.append(w)
                await c.load()
                try await Task.sleep(for: .milliseconds(400))
            }
            return c
        }
        let first = try await open("k1")
        _ = try await open("k2")
        _ = try await open("k3")
        #expect(pool.liveKeys == ["k2", "k3"])
        #expect(!pool.isLive("k1"))

        // The released widget is closed and pictured.
        let deadline = ContinuousClock.now + .seconds(5)
        while pool.snapshot(for: "k1") == nil || first.bridge.state != .tornDown, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(pool.snapshot(for: "k1") != nil)
        #expect(first.bridge.state == .tornDown)

        // Asking again re-creates it (and releases the least recent of the others).
        _ = try await open("k1")
        #expect(made == 4)
        #expect(pool.liveKeys == ["k3", "k1"])

        pool.limit = 1
        #expect(pool.liveKeys == ["k1"])
        await pool.releaseAll()
        #expect(pool.liveKeys.isEmpty)
        for w in windows { w.contentView = nil; w.orderOut(nil) }
    }
}

@MainActor
private struct NoBackend: MCPAppsBackend {
    func callTool(name: String, arguments: [String: MCPValue]) async -> Result<MCPToolResult, MCPServerError> { .failure(.unreachable) }
    func readResource(uri: String) async -> Result<MCPResourceContent, MCPServerError> { .failure(.unreachable) }
}
