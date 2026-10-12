import Foundation
import LocalLMLabSDKCore
import Testing

import LocalLMLabSDKMCPAppsHost

// Drives the bridge exactly as a web-view layer would: raw JSON-RPC bytes in, serialized
// messages out. Public API only.

@MainActor
private final class Recorder {
    var sent: [[String: Any]] = []
    var audit: [MCPAppsAuditEvent] = []
    var toolCalls: [(name: String, arguments: [String: MCPValue])] = []
    var resourceReads: [String] = []
    var sizes: [(Double?, Double?)] = []
}

@MainActor
private struct FakeBackend: MCPAppsBackend {
    let recorder: Recorder
    var toolResult: Result<MCPToolResult, MCPServerError> = .success(
        MCPToolResult(text: "ok", structuredContent: .object(["tasks": .array([])]), meta: .object(["k": .string("v")])))

    func callTool(name: String, arguments: [String: MCPValue]) async -> Result<MCPToolResult, MCPServerError> {
        recorder.toolCalls.append((name, arguments))
        return toolResult
    }

    func readResource(uri: String) async -> Result<MCPResourceContent, MCPServerError> {
        recorder.resourceReads.append(uri)
        return .success(MCPResourceContent(uri: uri, mimeType: "text/html;profile=mcp-app", text: "<html/>"))
    }
}

@MainActor
private struct OpenPolicy: MCPAppsBridgePolicy {
    func authorizeOpenLink(_ url: URL) async -> MCPAppsDecision { .allow }
    func authorizeMessage(text: String) async -> MCPAppsDecision { .allow }
    func authorizeModelContextUpdate() async -> MCPAppsDecision { .allow }
}

private func tool(_ name: String, visibility: [String]? = nil) -> MCPToolDescriptor {
    let meta: MCPValue? = visibility.map { .object(["ui": .object(["visibility": .array($0.map { .string($0) })])]) }
    return MCPToolDescriptor(
        serverID: MCPServerID(rawValue: "https://example.invalid/mcp"), name: name, description: "",
        rawSchema: Data("{}".utf8), estimatedTokens: 0, meta: meta)
}

@MainActor
private struct Harness {
    let recorder = Recorder()
    let bridge: MCPAppsBridge

    init(
        tools: [MCPToolDescriptor] = [tool("find-tasks"), tool("complete-tasks"), tool("model-only", visibility: ["model"])],
        policy: (any MCPAppsBridgePolicy)? = nil,
        backend: ((Recorder) -> FakeBackend)? = nil,
        configuration: MCPAppsBridgeConfiguration = MCPAppsBridgeConfiguration(hostName: "TestHost", hostVersion: "1.0"),
        actions: MCPAppsHostActions = MCPAppsHostActions()
    ) {
        let recorder = self.recorder
        bridge = MCPAppsBridge(
            configuration: configuration, tools: tools,
            backend: backend?(recorder) ?? FakeBackend(recorder: recorder),
            policy: policy ?? MCPAppsDefaultPolicy(),
            send: { data in
                if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { recorder.sent.append(object) }
            },
            audit: { recorder.audit.append($0) },
            onSizeChanged: { recorder.sizes.append(($0, $1)) },
            actions: actions)
    }

    func post(_ object: [String: Any]) async {
        await bridge.receive(try! JSONSerialization.data(withJSONObject: object))
    }

    func request(_ id: Any, _ method: String, _ params: [String: Any] = [:]) async {
        await post(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    func notify(_ method: String, _ params: [String: Any] = [:]) async {
        await post(["jsonrpc": "2.0", "method": method, "params": params])
    }

    /// The standard opening handshake.
    func initialize() async {
        await request(1, "ui/initialize", ["protocolVersion": "2026-01-26", "clientInfo": ["name": "w", "version": "1"], "appCapabilities": [:]])
        await notify("ui/notifications/initialized")
    }

    func reply(to id: Int) -> [String: Any]? {
        recorder.sent.first { ($0["id"] as? Int) == id && ($0["result"] != nil || $0["error"] != nil) }
    }

    func errorCode(for id: Int) -> Int? { (reply(to: id)?["error"] as? [String: Any])?["code"] as? Int }
    func result(for id: Int) -> [String: Any]? { reply(to: id)?["result"] as? [String: Any] }
}

@MainActor
@Suite struct MCPAppsBridgeTests {
    // MARK: lifecycle

    @Test func initializeAnswersWithHostInfoAndClosedCapabilities() async throws {
        let h = Harness()
        await h.request(1, "ui/initialize", ["protocolVersion": "2026-01-26"])
        let result = try #require(h.result(for: 1))
        #expect(result["protocolVersion"] as? String == "2026-01-26")
        #expect((result["hostInfo"] as? [String: Any])?["name"] as? String == "TestHost")
        let caps = try #require(result["hostCapabilities"] as? [String: Any])
        #expect(caps["serverTools"] != nil)
        #expect(caps["openLinks"] == nil)  // we deny links by default: don't advertise it
        let csp = try #require((caps["sandbox"] as? [String: Any])?["csp"] as? [String: Any])
        #expect((csp["connectDomains"] as? [String])?.isEmpty == true)
        let context = try #require(result["hostContext"] as? [String: Any])
        #expect(context["displayMode"] as? String == "inline")
        #expect(h.bridge.state == .awaitingInitialized)
        await h.notify("ui/notifications/initialized")
        #expect(h.bridge.state == .ready)
    }

    @Test func initializeRequiresProtocolVersion() async {
        let h = Harness()
        await h.request(1, "ui/initialize", [:])
        #expect(h.errorCode(for: 1) == -32602)
        #expect(h.bridge.state == .awaitingInitialize)
    }

    @Test func secondInitializeIsRefused() async {
        let h = Harness()
        await h.initialize()
        await h.request(2, "ui/initialize", ["protocolVersion": "2026-01-26"])
        #expect(h.errorCode(for: 2) == -32600)
    }

    @Test func requestsBeforeInitializedAreRefusedAndNeverReachTheBackend() async {
        let h = Harness()
        await h.request(1, "tools/call", ["name": "find-tasks"])
        #expect(h.errorCode(for: 1) == -32600)
        await h.request(2, "ui/initialize", ["protocolVersion": "2026-01-26"])
        await h.request(3, "tools/call", ["name": "find-tasks"])  // initialized notification not yet sent
        #expect(h.errorCode(for: 3) == -32600)
        #expect(h.recorder.toolCalls.isEmpty)
    }

    @Test func hostNotificationsAreQueuedUntilInitializedThenFlushedInOrder() async {
        let h = Harness()
        h.bridge.deliverToolInput(arguments: ["startDate": .string("today")])
        h.bridge.deliverToolResult(MCPToolResult(text: "t", structuredContent: .object(["n": .number(1)])))
        #expect(h.recorder.sent.isEmpty)
        await h.request(1, "ui/initialize", ["protocolVersion": "2026-01-26"])
        let afterInit = h.recorder.sent.count  // just the initialize reply
        #expect(afterInit == 1)
        await h.notify("ui/notifications/initialized")
        let methods = h.recorder.sent.dropFirst(afterInit).compactMap { $0["method"] as? String }
        #expect(methods == ["ui/notifications/tool-input", "ui/notifications/tool-result"])
    }

    @Test func toolResultNotificationCarriesStructuredContentAndMeta() async throws {
        let h = Harness()
        await h.initialize()
        h.bridge.deliverToolResult(MCPToolResult(text: "hi", structuredContent: .object(["totalCount": .number(2)]), isError: false, meta: .object(["a": .string("b")])))
        let params = try #require(h.recorder.sent.last?["params"] as? [String: Any])
        #expect((params["structuredContent"] as? [String: Any])?["totalCount"] as? Int == 2)
        #expect((params["_meta"] as? [String: Any])?["a"] as? String == "b")
        #expect(((params["content"] as? [[String: Any]])?.first)?["text"] as? String == "hi")
    }

    // MARK: tools/call

    @Test func toolCallReachesTheBackendAndReturnsTheResult() async throws {
        let h = Harness()
        await h.initialize()
        await h.request(2, "tools/call", ["name": "complete-tasks", "arguments": ["ids": ["a", "b"], "n": 3]])
        #expect(h.recorder.toolCalls.count == 1)
        #expect(h.recorder.toolCalls[0].name == "complete-tasks")
        #expect(h.recorder.toolCalls[0].arguments["ids"] == .array([.string("a"), .string("b")]))
        let result = try #require(h.result(for: 2))
        #expect((result["structuredContent"] as? [String: Any])?["tasks"] != nil)
        #expect((result["_meta"] as? [String: Any])?["k"] as? String == "v")
    }

    @Test func unknownToolIsRefused() async {
        let h = Harness()
        await h.initialize()
        await h.request(2, "tools/call", ["name": "delete-everything"])
        #expect(h.errorCode(for: 2) == -32000)
        #expect(h.recorder.toolCalls.isEmpty)
    }

    @Test func modelOnlyToolIsNotCallableByTheView() async {
        let h = Harness()
        await h.initialize()
        await h.request(2, "tools/call", ["name": "model-only"])
        #expect(h.errorCode(for: 2) == -32000)
        #expect(h.recorder.toolCalls.isEmpty)
    }

    @Test func policyAllowlistBlocksUnapprovedTools() async {
        let h = Harness(policy: MCPAppsDefaultPolicy(allowedTools: ["find-tasks"]))
        await h.initialize()
        await h.request(2, "tools/call", ["name": "complete-tasks"])
        await h.request(3, "tools/call", ["name": "find-tasks"])
        #expect(h.errorCode(for: 2) == -32000)
        #expect(h.reply(to: 3)?["result"] != nil)
        #expect(h.recorder.toolCalls.map(\.name) == ["find-tasks"])
    }

    @Test func toolCallValidatesParams() async {
        let h = Harness()
        await h.initialize()
        await h.request(2, "tools/call", [:])
        await h.request(3, "tools/call", ["name": "find-tasks", "arguments": "not an object"])
        #expect(h.errorCode(for: 2) == -32602)
        #expect(h.errorCode(for: 3) == -32602)
        #expect(h.recorder.toolCalls.isEmpty)
    }

    @Test func backendFailureBecomesAnErrorWithoutLeakingDetail() async throws {
        let h = Harness(backend: { FakeBackend(recorder: $0, toolResult: .failure(.serverError("secret token abc123"))) })
        await h.initialize()
        await h.request(2, "tools/call", ["name": "find-tasks"])
        let error = try #require(h.reply(to: 2)?["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32000)
        #expect(!(error["message"] as? String ?? "").contains("abc123"))
    }

    // MARK: things a view must not do by default

    @Test func messageContextAndLinksAreDeniedByDefault() async {
        let h = Harness()
        await h.initialize()
        await h.request(2, "ui/message", ["role": "user", "content": ["type": "text", "text": "hi model"]])
        await h.request(3, "ui/update-model-context", ["content": [["type": "text", "text": "x"]]])
        await h.request(4, "ui/open-link", ["url": "https://example.com"])
        #expect(h.errorCode(for: 2) == -32000)
        #expect(h.errorCode(for: 3) == -32000)
        #expect(h.errorCode(for: 4) == -32000)
    }

    @Test func aPolicyCanOptIn() async {
        let h = Harness(policy: OpenPolicy())
        await h.initialize()
        await h.request(2, "ui/message", ["role": "user", "content": ["type": "text", "text": "hi"]])
        await h.request(3, "ui/update-model-context", ["content": []])
        await h.request(4, "ui/open-link", ["url": "https://example.com"])
        #expect(h.reply(to: 2)?["result"] != nil)
        #expect(h.reply(to: 3)?["result"] != nil)
        #expect(h.reply(to: 4)?["result"] != nil)
    }

    @Test func openLinkRejectsNonWebSchemesEvenWhenThePolicyAllows() async {
        let h = Harness(policy: OpenPolicy())
        await h.initialize()
        await h.request(2, "ui/open-link", ["url": "file:///etc/passwd"])
        await h.request(3, "ui/open-link", ["url": "javascript:alert(1)"])
        await h.request(4, "ui/open-link", ["url": "x-apple.systempreferences:"])
        #expect(h.errorCode(for: 2) == -32000)
        #expect(h.errorCode(for: 3) == -32000)
        #expect(h.errorCode(for: 4) == -32000)
    }

    @Test func nonUIResourceReadsAreDeniedByDefault() async {
        let h = Harness()
        await h.initialize()
        await h.request(2, "resources/read", ["uri": "file:///etc/passwd"])
        await h.request(3, "resources/read", ["uri": "ui://todoist/task-list@abc"])
        #expect(h.errorCode(for: 2) == -32000)
        #expect(h.result(for: 3)?["contents"] != nil)
        #expect(h.recorder.resourceReads == ["ui://todoist/task-list@abc"])
    }

    @Test func displayModeRequestsKeepTheCurrentMode() async {
        let h = Harness()
        await h.initialize()
        await h.request(2, "ui/request-display-mode", ["mode": "fullscreen"])
        #expect(h.result(for: 2)?["mode"] as? String == "inline")
    }

    // MARK: display modes + host context

    @Test func fullscreenIsOnlyAdvertisedWhenTheHostProvidesIt() async throws {
        let plain = Harness()
        await plain.request(1, "ui/initialize", ["protocolVersion": "2026-01-26"])
        let modes = (plain.result(for: 1)?["hostContext"] as? [String: Any])?["availableDisplayModes"] as? [String]
        #expect(modes == ["inline"])
        let rich = Harness(configuration: MCPAppsBridgeConfiguration(hostName: "H", hostVersion: "1", availableDisplayModes: ["inline", "fullscreen"]))
        await rich.request(1, "ui/initialize", ["protocolVersion": "2026-01-26"])
        #expect(((rich.result(for: 1)?["hostContext"] as? [String: Any])?["availableDisplayModes"] as? [String]) == ["inline", "fullscreen"])
    }

    @Test func aGrantedDisplayModeRequestSwitchesModeAndNotifiesTheView() async {
        var requested: [String] = []
        let h = Harness(configuration: MCPAppsBridgeConfiguration(hostName: "H", hostVersion: "1", availableDisplayModes: ["inline", "fullscreen"]),
                        actions: MCPAppsHostActions(requestDisplayMode: { requested.append($0); return true }))
        await h.initialize()
        await h.request(2, "ui/request-display-mode", ["mode": "fullscreen"])
        #expect(h.result(for: 2)?["mode"] as? String == "fullscreen")
        #expect(requested == ["fullscreen"])
        #expect(h.bridge.displayMode == "fullscreen")
        let change = h.recorder.sent.last { $0["method"] as? String == "ui/notifications/host-context-changed" }
        #expect((change?["params"] as? [String: Any])?["displayMode"] as? String == "fullscreen")
    }

    @Test func aDeclinedOrUnadvertisedDisplayModeKeepsTheCurrentMode() async {
        var asked = 0
        let h = Harness(configuration: MCPAppsBridgeConfiguration(hostName: "H", hostVersion: "1", availableDisplayModes: ["inline", "fullscreen"]),
                        actions: MCPAppsHostActions(requestDisplayMode: { _ in asked += 1; return false }))
        await h.initialize()
        await h.request(2, "ui/request-display-mode", ["mode": "fullscreen"])  // host declines
        await h.request(3, "ui/request-display-mode", ["mode": "pip"])         // never advertised
        await h.request(4, "ui/request-display-mode", ["mode": 7])             // malformed
        for id in 2...4 { #expect(h.result(for: id)?["mode"] as? String == "inline") }
        #expect(asked == 1)  // only the advertised mode reached the host
        #expect(!h.recorder.sent.contains { $0["method"] as? String == "ui/notifications/host-context-changed" })
    }

    @Test func theHostCanChangeTheModeItself() async {
        let h = Harness(configuration: MCPAppsBridgeConfiguration(hostName: "H", hostVersion: "1", availableDisplayModes: ["inline", "fullscreen"]))
        await h.initialize()
        h.bridge.setDisplayMode("fullscreen")
        h.bridge.setDisplayMode("fullscreen")  // no-op the second time
        h.bridge.setDisplayMode("pip")         // not advertised: ignored
        let changes = h.recorder.sent.filter { $0["method"] as? String == "ui/notifications/host-context-changed" }
        #expect(changes.count == 1)
        #expect(h.bridge.displayMode == "fullscreen")
    }

    @Test func hostContextChangesBeforeReadyAreMergedIntoOneNotification() async throws {
        let h = Harness()
        h.bridge.deliverHostContextChange(["theme": .string("light"), "containerDimensions": .object(["width": .number(100)])])
        h.bridge.deliverHostContextChange(["containerDimensions": .object(["width": .number(640)])])  // later wins
        h.bridge.deliverHostContextChange(["theme": .string("dark")])
        #expect(h.recorder.sent.isEmpty)
        await h.initialize()
        let changes = h.recorder.sent.filter { $0["method"] as? String == "ui/notifications/host-context-changed" }
        #expect(changes.count == 1)
        let params = try #require(changes.first?["params"] as? [String: Any])
        #expect(params["theme"] as? String == "dark")
        #expect((params["containerDimensions"] as? [String: Any])?["width"] as? Int == 640)
    }

    @Test func hostContextChangesAfterReadyGoStraightOut() async {
        let h = Harness()
        await h.initialize()
        h.bridge.deliverHostContextChange(["theme": .string("dark")])
        #expect(h.recorder.sent.contains { $0["method"] as? String == "ui/notifications/host-context-changed" })
    }

    // MARK: hostile / malformed input

    @Test func unknownMethodsGetMethodNotFound() async {
        let h = Harness()
        await h.initialize()
        await h.request(2, "sampling/createMessage", [:])
        #expect(h.errorCode(for: 2) == -32601)
    }

    @Test func malformedAndOversizedInputIsDroppedNotFatal() async {
        let config = MCPAppsBridgeConfiguration(hostName: "H", hostVersion: "1", maxMessageBytes: 200)
        let h = Harness(configuration: config)
        await h.bridge.receive(Data("not json".utf8))
        await h.bridge.receive(Data(#"{"method":"ping","id":1}"#.utf8))  // missing jsonrpc
        await h.bridge.receive(Data(String(repeating: " ", count: 500).utf8))
        await h.post(["jsonrpc": "2.0", "id": ["nested": true], "method": "ping"])  // invalid id type
        #expect(h.recorder.sent.isEmpty)
        #expect(h.recorder.audit.filter { $0.outcome == .dropped }.count == 4)
        await h.request(1, "ping")  // still works afterwards
        #expect(h.reply(to: 1) != nil)
    }

    @Test func booleanIDsAreNotAcceptedAsNumbers() async {
        let h = Harness()
        await h.post(["jsonrpc": "2.0", "id": true, "method": "ping"])
        #expect(h.recorder.sent.isEmpty)
    }

    @Test func sizeChangesAreReported() async {
        let h = Harness()
        await h.initialize()
        await h.notify("ui/notifications/size-changed", ["width": 400, "height": 320])
        #expect(h.recorder.sizes.count == 1)
        #expect(h.recorder.sizes[0].0 == 400)
        #expect(h.recorder.sizes[0].1 == 320)
    }

    // MARK: teardown

    @Test func teardownWaitsForTheViewsAnswerThenClosesTheBridge() async {
        let h = Harness()
        await h.initialize()
        let task = Task { await h.bridge.teardown(reason: "closing") }
        while !h.recorder.sent.contains(where: { $0["method"] as? String == "ui/resource-teardown" }) { await Task.yield() }
        let request = h.recorder.sent.first { $0["method"] as? String == "ui/resource-teardown" }!
        await h.post(["jsonrpc": "2.0", "id": request["id"]!, "result": [:]])
        await task.value
        #expect(h.bridge.state == .tornDown)
    }

    @Test func teardownTimesOutIfTheViewIsSilent() async {
        let config = MCPAppsBridgeConfiguration(hostName: "H", hostVersion: "1", teardownTimeout: .milliseconds(50))
        let h = Harness(configuration: config)
        await h.initialize()
        await h.bridge.teardown()
        #expect(h.bridge.state == .tornDown)
    }

    @Test func nothingIsAcceptedOrSentAfterTeardown() async {
        let config = MCPAppsBridgeConfiguration(hostName: "H", hostVersion: "1", teardownTimeout: .milliseconds(20))
        let h = Harness(configuration: config)
        await h.initialize()
        await h.bridge.teardown()
        let sentBefore = h.recorder.sent.count
        await h.request(9, "tools/call", ["name": "find-tasks"])
        h.bridge.deliverToolInput(arguments: [:])
        #expect(h.recorder.sent.count == sentBefore)
        #expect(h.recorder.toolCalls.isEmpty)
    }

    // MARK: audit

    @Test func auditNeverRecordsArgumentValuesOrOutput() async {
        let h = Harness()
        await h.initialize()
        await h.request(2, "tools/call", ["name": "complete-tasks", "arguments": ["secret": "hunter2-do-not-log"]])
        let dump = h.recorder.audit.map { "\($0.method)|\($0.outcome)|\($0.detail ?? "")" }.joined(separator: "\n")
        #expect(!dump.contains("hunter2"))
        #expect(dump.contains("complete-tasks"))  // the tool NAME is recorded
    }

    @Test func deniedCallsAreAuditedAsDenied() async {
        let h = Harness()
        await h.initialize()
        await h.request(2, "ui/message", ["role": "user", "content": ["type": "text", "text": "x"]])
        #expect(h.recorder.audit.contains { $0.method == "ui/message" && $0.outcome == .denied })
    }
}
