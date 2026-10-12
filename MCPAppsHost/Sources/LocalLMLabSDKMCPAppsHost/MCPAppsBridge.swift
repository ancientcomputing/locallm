import Foundation
import LocalLMLabSDKCore

/// Host settings a bridge reports to its view at `ui/initialize`.
public struct MCPAppsBridgeConfiguration: Sendable {
    public var hostName: String
    public var hostVersion: String
    /// Extra `hostContext` fields (theme, styles, locale, timeZone, containerDimensions,
    /// toolInfo, ...). `displayMode`, `availableDisplayModes`, and `platform` get defaults if absent.
    public var hostContext: [String: MCPValue]
    /// What the host will actually enforce for this view, advertised under
    /// `hostCapabilities.sandbox.csp`. Should be the effective (intersected) CSP, not the
    /// server's request.
    public var effectiveCSP: MCPAppCSP
    public var effectivePermissions: MCPAppPermissions
    /// Display modes the host can actually provide, advertised in `hostContext`. A widget only
    /// offers a fullscreen button if `"fullscreen"` is listed here, so list only what the host UI
    /// implements. `"inline"` is always present.
    public var availableDisplayModes: [String]
    /// Incoming messages larger than this are dropped (and audited), unparsed.
    public var maxMessageBytes: Int
    /// How long `teardown` waits for the view to answer `ui/resource-teardown`.
    public var teardownTimeout: Duration

    public init(
        hostName: String, hostVersion: String,
        hostContext: [String: MCPValue] = [:],
        effectiveCSP: MCPAppCSP = MCPAppCSP(),
        effectivePermissions: MCPAppPermissions = MCPAppPermissions(),
        availableDisplayModes: [String] = ["inline"],
        maxMessageBytes: Int = 4 * 1024 * 1024,
        teardownTimeout: Duration = .seconds(2)
    ) {
        self.hostName = hostName
        self.hostVersion = hostVersion
        self.hostContext = hostContext
        self.effectiveCSP = effectiveCSP
        self.effectivePermissions = effectivePermissions
        self.availableDisplayModes = availableDisplayModes.contains("inline") ? availableDisplayModes : ["inline"] + availableDisplayModes
        self.maxMessageBytes = maxMessageBytes
        self.teardownTimeout = teardownTimeout
    }
}

/// What the host DOES once the policy has allowed a view's request. The bridge decides whether a
/// request may proceed; these closures carry it out. All default to no-ops, so a host that
/// keeps the closed default policy never needs to set them.
public struct MCPAppsHostActions {
    /// Open an http(s) URL (already scheme-checked by the bridge).
    public var openLink: @MainActor (URL) -> Void
    /// A view's `ui/message`: put this user-role text into the conversation.
    public var sendMessage: @MainActor (String) -> Void
    /// A view's `ui/update-model-context`: replace what the model knows about the view's state.
    public var updateModelContext: @MainActor (_ content: [MCPValue], _ structuredContent: MCPValue?) -> Void
    /// A view's `ui/request-display-mode` for a mode the host advertised. Return `true` if the
    /// host UI switched to it (the bridge then tells the view via `host-context-changed`); `false`
    /// leaves the mode unchanged.
    public var requestDisplayMode: @MainActor (_ mode: String) -> Bool

    public init(
        openLink: @escaping @MainActor (URL) -> Void = { _ in },
        sendMessage: @escaping @MainActor (String) -> Void = { _ in },
        updateModelContext: @escaping @MainActor (_ content: [MCPValue], _ structuredContent: MCPValue?) -> Void = { _, _ in },
        requestDisplayMode: @escaping @MainActor (_ mode: String) -> Bool = { _ in false }
    ) {
        self.openLink = openLink
        self.sendMessage = sendMessage
        self.updateModelContext = updateModelContext
        self.requestDisplayMode = requestDisplayMode
    }
}

/// The JSON-RPC state machine between ONE view (a `ui://` widget) and the host — pure Swift, no
/// WebKit. A web-view layer feeds it raw messages via `receive(_:)` and ships whatever it emits
/// through `send`. A host with no model uses it as-is; a host with a model wires the opt-in
/// policy methods.
///
/// Guarantees (each covered by tests):
/// - nothing is sent to the view before it sends `ui/notifications/initialized` (spec); host
///   notifications requested earlier are queued and flushed in order;
/// - a view request before initialization, a second `ui/initialize`, or any request after
///   teardown is refused;
/// - `tools/call` reaches only tools the server declared, whose visibility includes `app`, that
///   the policy approves, on the ONE server the backend is bound to;
/// - `ui/message`, `ui/update-model-context`, `ui/open-link` and non-`ui://` reads go through the
///   policy, which denies them by default;
/// - malformed, oversized, or unknown input is dropped or answered with a JSON-RPC error, never
///   crashes and never widens access;
/// - every message in either direction leaves an audit event without argument values or output.
@MainActor
public final class MCPAppsBridge {
    public enum State: Sendable, Equatable {
        case awaitingInitialize
        case awaitingInitialized
        case ready
        case tornDown
    }

    /// The MCP Apps spec revision this bridge speaks.
    public static let protocolVersion = "2026-01-26"

    public private(set) var state: State = .awaitingInitialize
    /// The display mode currently in effect (`"inline"` or `"fullscreen"`).
    public private(set) var displayMode: String

    private let configuration: MCPAppsBridgeConfiguration
    private let tools: [String: MCPToolDescriptor]
    private let backend: any MCPAppsBackend
    private let policy: any MCPAppsBridgePolicy
    private let send: @MainActor (Data) -> Void
    private let audit: @MainActor (MCPAppsAuditEvent) -> Void
    private let onSizeChanged: @MainActor (_ width: Double?, _ height: Double?) -> Void
    private let actions: MCPAppsHostActions

    private var queued: [[String: Any]] = []
    /// `host-context-changed` fields requested before the view is ready, merged into ONE
    /// notification (later values win) so a burst of resizes doesn't become a burst of messages.
    private var pendingContext: [String: MCPValue] = [:]
    private var teardownContinuation: CheckedContinuation<Void, Never>?
    private static let teardownRequestID = "host-teardown-1"

    /// - Parameters:
    ///   - tools: the bound server's tool list (`MCPServerState.tools`); the bridge only ever
    ///     lets the view call a tool that appears here.
    ///   - send: delivers one serialized JSON-RPC message to the view.
    public init(
        configuration: MCPAppsBridgeConfiguration,
        tools: [MCPToolDescriptor],
        backend: any MCPAppsBackend,
        policy: any MCPAppsBridgePolicy = MCPAppsDefaultPolicy(),
        send: @escaping @MainActor (Data) -> Void,
        audit: @escaping @MainActor (MCPAppsAuditEvent) -> Void = { _ in },
        onSizeChanged: @escaping @MainActor (_ width: Double?, _ height: Double?) -> Void = { _, _ in },
        actions: MCPAppsHostActions = MCPAppsHostActions()
    ) {
        self.configuration = configuration
        self.tools = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        self.backend = backend
        self.policy = policy
        self.send = send
        self.audit = audit
        self.onSizeChanged = onSizeChanged
        self.actions = actions
        if case .string(let mode)? = configuration.hostContext["displayMode"], configuration.availableDisplayModes.contains(mode) {
            self.displayMode = mode
        } else {
            self.displayMode = "inline"
        }
    }

    // MARK: - Host -> view

    /// `ui/notifications/tool-input`: the arguments of the tool call the view is rendering.
    public func deliverToolInput(arguments: [String: MCPValue]) {
        emit(notification: "ui/notifications/tool-input", params: ["arguments": Self.jsonObject(.object(arguments))])
    }

    /// `ui/notifications/tool-result`: the tool's result — `structuredContent` and `_meta` are
    /// what a widget renders from.
    public func deliverToolResult(_ result: MCPToolResult) {
        emit(notification: "ui/notifications/tool-result", params: Self.resultObject(result))
    }

    /// `ui/notifications/tool-cancelled`.
    public func deliverToolCancelled(reason: String? = nil) {
        emit(notification: "ui/notifications/tool-cancelled", params: reason.map { ["reason": $0] } ?? [:])
    }

    /// `ui/notifications/host-context-changed`: only the fields that changed (theme, size, ...).
    public func deliverHostContextChange(_ partial: [String: MCPValue]) {
        guard state != .tornDown, !partial.isEmpty else { return }
        if state != .ready {
            pendingContext.merge(partial) { _, new in new }
            return
        }
        emit(notification: "ui/notifications/host-context-changed", params: Self.jsonObject(.object(partial)) as? [String: Any] ?? [:])
    }

    /// The HOST changed the display mode itself (e.g. the user left fullscreen). Updates the mode
    /// and tells the view. Ignored for a mode the host didn't advertise.
    public func setDisplayMode(_ mode: String) {
        guard configuration.availableDisplayModes.contains(mode), mode != displayMode else { return }
        displayMode = mode
        deliverHostContextChange(["displayMode": .string(mode)])
    }

    /// Asks the view to clean up (`ui/resource-teardown`), waits up to `teardownTimeout` for its
    /// answer, then closes the bridge. Always closes, answered or not.
    public func teardown(reason: String = "host closing") async {
        guard state != .tornDown else { return }
        if state == .ready || state == .awaitingInitialized {
            let message: [String: Any] = [
                "jsonrpc": "2.0", "id": Self.teardownRequestID,
                "method": "ui/resource-teardown", "params": ["reason": reason],
            ]
            transmit(message, method: "ui/resource-teardown")
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                teardownContinuation = continuation
                let timeout = configuration.teardownTimeout
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.finishTeardownWait()
                }
            }
        }
        state = .tornDown
        queued.removeAll()
    }

    private func finishTeardownWait() {
        guard let continuation = teardownContinuation else { return }
        teardownContinuation = nil
        continuation.resume()
    }

    // MARK: - View -> host

    /// Feed one raw message from the view (a JSON-RPC 2.0 object).
    public func receive(_ data: Data) async {
        guard state != .tornDown else {
            audit(.init(direction: .fromView, method: "?", outcome: .dropped, detail: "after teardown"))
            return
        }
        guard data.count <= configuration.maxMessageBytes else {
            audit(.init(direction: .fromView, method: "?", outcome: .dropped, detail: "oversized message"))
            return
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (object["jsonrpc"] as? String) == "2.0" else {
            audit(.init(direction: .fromView, method: "?", outcome: .dropped, detail: "not JSON-RPC 2.0"))
            return
        }
        if let method = object["method"] as? String {
            let params = object["params"] as? [String: Any] ?? [:]
            if let id = object["id"], Self.isValidID(id) {
                await handleRequest(id: id, method: method, params: params)
            } else if object["id"] == nil {
                handleNotification(method: method, params: params)
            } else {
                audit(.init(direction: .fromView, method: method, outcome: .dropped, detail: "invalid id"))
            }
        } else if let id = object["id"] as? String, id == Self.teardownRequestID,
                  object["result"] != nil || object["error"] != nil {
            audit(.init(direction: .fromView, method: "ui/resource-teardown", outcome: .ok))
            finishTeardownWait()
        } else {
            audit(.init(direction: .fromView, method: "?", outcome: .dropped, detail: "unrecognized message"))
        }
    }

    /// JSON-RPC ids are strings or numbers. `id is Bool` is NOT a usable check on a
    /// JSONSerialization result — `NSNumber(1)` bridges to `Bool` — so test the CF type instead.
    private static func isValidID(_ id: Any) -> Bool {
        if id is String { return true }
        guard let number = id as? NSNumber else { return false }
        return CFGetTypeID(number) != CFBooleanGetTypeID()
    }

    private func handleNotification(method: String, params: [String: Any]) {
        switch method {
        case "ui/notifications/initialized":
            guard state == .awaitingInitialized else {
                audit(.init(direction: .fromView, method: method, outcome: .dropped, detail: "unexpected in state \(state)"))
                return
            }
            state = .ready
            audit(.init(direction: .fromView, method: method, outcome: .ok))
            let pending = queued
            queued.removeAll()
            for message in pending { transmit(message, method: (message["method"] as? String) ?? "?") }
            if !pendingContext.isEmpty {
                let merged = pendingContext
                pendingContext.removeAll()
                deliverHostContextChange(merged)
            }
        case "ui/notifications/size-changed":
            onSizeChanged((params["width"] as? NSNumber)?.doubleValue, (params["height"] as? NSNumber)?.doubleValue)
            audit(.init(direction: .fromView, method: method, outcome: .ok))
        case "notifications/message":
            // Logging from the view: recorded as an event only, never its text.
            audit(.init(direction: .fromView, method: method, outcome: .ok))
        default:
            audit(.init(direction: .fromView, method: method, outcome: .dropped, detail: "unknown notification"))
        }
    }

    private func handleRequest(id: Any, method: String, params: [String: Any]) async {
        switch method {
        case "ui/initialize":
            guard state == .awaitingInitialize else {
                return fail(id, method, .invalidRequest("Already initialized"))
            }
            guard params["protocolVersion"] is String else {
                return fail(id, method, .invalidParams("protocolVersion is required"))
            }
            state = .awaitingInitialized
            reply(id, method, result: initializeResult())
        case "ping":
            reply(id, method, result: [:])
        case "tools/call":
            await handleToolCall(id: id, params: params)
        case "resources/read":
            await handleResourceRead(id: id, params: params)
        case "ui/open-link":
            guard state == .ready else { return fail(id, method, .notReady) }
            guard let raw = params["url"] as? String, let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
                return fail(id, method, .server("Invalid URL"))
            }
            switch await policy.authorizeOpenLink(url) {
            case .allow:
                actions.openLink(url)
                reply(id, method, result: [:])
            case .deny(let reason): fail(id, method, .server(reason), outcome: .denied)
            }
        case "ui/message":
            guard state == .ready else { return fail(id, method, .notReady) }
            guard let content = params["content"] as? [String: Any], let text = content["text"] as? String else {
                return fail(id, method, .server("Invalid message format"))
            }
            switch await policy.authorizeMessage(text: text) {
            case .allow:
                actions.sendMessage(text)
                reply(id, method, result: [:])
            case .deny(let reason): fail(id, method, .server(reason), outcome: .denied)
            }
        case "ui/update-model-context":
            guard state == .ready else { return fail(id, method, .notReady) }
            switch await policy.authorizeModelContextUpdate() {
            case .allow:
                let content: [MCPValue] = (params["content"] as? [Any])?.compactMap(Self.mcpValue) ?? []
                actions.updateModelContext(content, (params["structuredContent"]).flatMap(Self.mcpValue))
                reply(id, method, result: [:])
            case .deny(let reason): fail(id, method, .server(reason), outcome: .denied)
            }
        case "ui/request-display-mode":
            guard state == .ready else { return fail(id, method, .notReady) }
            // The host owns layout. A request for an unadvertised mode, or one the host UI
            // declines, is answered with the mode actually in effect (not an error).
            if let requested = params["mode"] as? String, requested != displayMode,
               configuration.availableDisplayModes.contains(requested), actions.requestDisplayMode(requested) {
                displayMode = requested
                deliverHostContextChange(["displayMode": .string(requested)])
            }
            reply(id, method, result: ["mode": displayMode])
        default:
            fail(id, method, .methodNotFound)
        }
    }

    private func handleToolCall(id: Any, params: [String: Any]) async {
        let method = "tools/call"
        guard state == .ready else { return fail(id, method, .notReady) }
        guard let name = params["name"] as? String else { return fail(id, method, .invalidParams("name is required")) }
        var arguments: [String: MCPValue] = [:]
        if let raw = params["arguments"] {
            guard let object = raw as? [String: Any], let decoded = Self.mcpValue(object), case .object(let a) = decoded else {
                return fail(id, method, .invalidParams("arguments must be an object"))
            }
            arguments = a
        }
        guard let descriptor = tools[name] else {
            return fail(id, method, .server("Unknown tool"), detail: name, outcome: .denied)
        }
        guard descriptor.appVisibility.contains(.app) else {
            return fail(id, method, .server("Tool is not callable by apps"), detail: name, outcome: .denied)
        }
        if case .deny(let reason) = await policy.authorizeToolCall(name: name, arguments: arguments) {
            return fail(id, method, .server(reason), detail: name, outcome: .denied)
        }
        switch await backend.callTool(name: name, arguments: arguments) {
        case .success(let result):
            reply(id, method, result: Self.resultObject(result), detail: name)
        case .failure(let error):
            fail(id, method, .server("Tool call failed (\(Self.errorClass(error)))"), detail: name)
        }
    }

    private func handleResourceRead(id: Any, params: [String: Any]) async {
        let method = "resources/read"
        guard state == .ready else { return fail(id, method, .notReady) }
        guard let uri = params["uri"] as? String else { return fail(id, method, .invalidParams("uri is required")) }
        if case .deny(let reason) = await policy.authorizeResourceRead(uri: uri) {
            return fail(id, method, .server(reason), outcome: .denied)
        }
        switch await backend.readResource(uri: uri) {
        case .success(let content):
            var entry: [String: Any] = ["uri": content.uri]
            if let mime = content.mimeType { entry["mimeType"] = mime }
            if let text = content.text { entry["text"] = text }
            if let blob = content.blob { entry["blob"] = blob }
            if let meta = content.meta { entry["_meta"] = Self.jsonObject(meta) }
            reply(id, method, result: ["contents": [entry]])
        case .failure(let error):
            fail(id, method, .server("Resource read failed (\(Self.errorClass(error)))"))
        }
    }

    // MARK: - Building messages

    private func initializeResult() -> [String: Any] {
        var caps: [String: Any] = ["serverTools": [String: Any](), "serverResources": [String: Any]()]
        var sandbox: [String: Any] = [
            "csp": [
                "connectDomains": configuration.effectiveCSP.connectDomains,
                "resourceDomains": configuration.effectiveCSP.resourceDomains,
                "frameDomains": configuration.effectiveCSP.frameDomains,
                "baseUriDomains": configuration.effectiveCSP.baseUriDomains,
            ]
        ]
        var perms: [String: Any] = [:]
        let p = configuration.effectivePermissions
        if p.camera { perms["camera"] = [String: Any]() }
        if p.microphone { perms["microphone"] = [String: Any]() }
        if p.geolocation { perms["geolocation"] = [String: Any]() }
        if p.clipboardWrite { perms["clipboardWrite"] = [String: Any]() }
        sandbox["permissions"] = perms
        caps["sandbox"] = sandbox

        var context = (Self.jsonObject(.object(configuration.hostContext)) as? [String: Any]) ?? [:]
        context["displayMode"] = displayMode
        context["availableDisplayModes"] = configuration.availableDisplayModes
        if context["platform"] == nil { context["platform"] = "desktop" }

        return [
            "protocolVersion": Self.protocolVersion,
            "hostInfo": ["name": configuration.hostName, "version": configuration.hostVersion],
            "hostCapabilities": caps,
            "hostContext": context,
        ]
    }

    private static func resultObject(_ result: MCPToolResult) -> [String: Any] {
        var object: [String: Any] = [:]
        object["content"] = result.text.isEmpty ? [[String: Any]]() : [["type": "text", "text": result.text]]
        if let structured = result.structuredContent { object["structuredContent"] = jsonObject(structured) }
        if result.isError { object["isError"] = true }
        if let meta = result.meta { object["_meta"] = jsonObject(meta) }
        return object
    }

    private enum RPCError {
        case invalidRequest(String), invalidParams(String), methodNotFound, notReady, server(String)

        var code: Int {
            switch self {
            case .invalidRequest: return -32600
            case .methodNotFound: return -32601
            case .invalidParams: return -32602
            case .notReady: return -32600
            case .server: return -32000
            }
        }
        var message: String {
            switch self {
            case .invalidRequest(let m), .invalidParams(let m), .server(let m): return m
            case .methodNotFound: return "Method not found"
            case .notReady: return "Not initialized"
            }
        }
    }

    private func reply(_ id: Any, _ method: String, result: [String: Any], detail: String? = nil) {
        transmit(["jsonrpc": "2.0", "id": id, "result": result], method: method, isReplyTo: method, outcome: .ok, detail: detail)
    }

    private func fail(_ id: Any, _ method: String, _ error: RPCError, detail: String? = nil, outcome: MCPAppsAuditEvent.Outcome = .error) {
        transmit(
            ["jsonrpc": "2.0", "id": id, "error": ["code": error.code, "message": error.message]],
            method: method, isReplyTo: method, outcome: outcome, detail: detail ?? error.message)
    }

    private func emit(notification method: String, params: [String: Any]) {
        guard state != .tornDown else { return }
        let message: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if state == .ready { transmit(message, method: method) } else { queued.append(message) }
    }

    private func transmit(_ message: [String: Any], method: String, isReplyTo: String? = nil, outcome: MCPAppsAuditEvent.Outcome = .ok, detail: String? = nil) {
        guard JSONSerialization.isValidJSONObject(message), let data = try? JSONSerialization.data(withJSONObject: message) else {
            audit(.init(direction: .toView, method: method, outcome: .error, detail: "unserializable"))
            return
        }
        send(data)
        audit(.init(direction: isReplyTo == nil ? .toView : .fromView, method: method, outcome: outcome, detail: detail))
    }

    // MARK: - JSON <-> MCPValue (public Codable only; Core's Any bridges are internal)

    private static func jsonObject(_ value: MCPValue) -> Any {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return NSNull() }
        return object
    }

    private static func mcpValue(_ object: Any) -> MCPValue? {
        guard JSONSerialization.isValidJSONObject(object) || object is String || object is NSNumber,
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]) else { return nil }
        return try? JSONDecoder().decode(MCPValue.self, from: data)
    }

    private static func errorClass(_ error: MCPServerError) -> String {
        switch error {
        case .unreachable: return "unreachable"
        case .notConnected: return "not connected"
        case .authorizationRequired, .credentialRejected: return "not authorized"
        case .toolNotFound: return "unknown tool"
        case .responseTooLarge: return "response too large"
        default: return "server error"
        }
    }
}
