import Foundation
import FoundationModels
import LocalLMLabSDKCore

// Re-creating a widget from a stored tool call:
// show the cached version at once, then check the server in the background and decide what to do
// if its widget changed in between. The decision is a pure function, so it is tested without
// WebKit or a server.

/// What a host should show for a re-created widget.
public enum MCPAppRecreationDecision: Sendable, Equatable {
    /// Show `MCPAppRecreation.Revalidation.resource` with the stored result. `viewOnly`: the server
    /// could not be reached, so the widget's tool calls would fail — present it as view-only.
    case render(viewOnly: Bool)
    /// The tool's output changed shape since the call: the stored result may not fit the current
    /// widget. Show the snapshot (or a placeholder) with a refresh action that re-runs the call.
    /// `mayRefreshAutomatically`: the tool is annotated read-only, so re-running it is safe without
    /// asking; otherwise ask first.
    case needsRefresh(mayRefreshAutomatically: Bool)
    /// A deployment's hash pin does not approve the widget version that would be shown.
    case notApproved
    /// Nothing cached and the server could not be reached.
    case unavailable
}

public enum MCPAppRecreation {
    /// The result of checking a stored call against its server.
    public struct Revalidation: Sendable {
        public var decision: MCPAppRecreationDecision
        /// The widget version to show for `.render`; `nil` otherwise.
        public var resource: MCPAppResource?
        /// True when the server serves a different widget version than the call was rendered
        /// with.
        public var widgetChanged: Bool
    }

    /// Decides what to show. Rules:
    /// - server reachable, same version → the current widget;
    /// - server reachable, newer version, tool output schema unchanged → the current widget (it
    ///   carries the vendor's fixes) with the stored result;
    /// - server reachable, newer (or unknown) version, output schema changed → refresh;
    /// - server unreachable → the cached version, view-only (or `.unavailable` if none);
    /// - a pin (`approvedSHA256`) that does not include the version to show → `.notApproved`.
    public static func decide(cachedSHA256: String?, currentSHA256: String?, outputSchemaUnchanged: Bool,
                              toolIsReadOnly: Bool, approvedSHA256: Set<String>? = nil) -> MCPAppRecreationDecision {
        func approved(_ sha: String) -> Bool { approvedSHA256.map { $0.contains(sha) } ?? true }
        guard let current = currentSHA256 else {
            guard let cached = cachedSHA256 else { return .unavailable }
            return approved(cached) ? .render(viewOnly: true) : .notApproved
        }
        // A version we cannot vouch for (changed, or unknown because it was never cached or was
        // evicted) only gets the stored result if the result's shape still fits.
        if current != cachedSHA256, !outputSchemaUnchanged {
            return .needsRefresh(mayRefreshAutomatically: toolIsReadOnly)
        }
        return approved(current) ? .render(viewOnly: false) : .notApproved
    }

    /// The cached widget a stored call was rendered with, for showing at once (before
    /// `revalidate`). `nil` if it was never cached or has been evicted.
    @MainActor
    public static func cachedResource(recordID: String, cache: MCPAppWidgetCache) -> MCPAppResource? {
        cache.sha256(forRecord: recordID).flatMap { cache.resource(sha256: $0) }
    }

    /// Checks the server's current widget and tool against a stored call and decides what to
    /// show. Fetches and caches the current widget when the server is reachable.
    ///
    /// - Parameters:
    ///   - callDescriptor: the tool's descriptor when the call was made
    ///     (`ToolCallRecord.toolDescriptor`), for the output-schema comparison.
    @MainActor
    public static func revalidate(recordID: String, resourceURI: String, callDescriptor: MCPToolDescriptor?,
                                  source: any MCPAppWidgetSource, cache: MCPAppWidgetCache,
                                  approvedSHA256: Set<String>? = nil) async -> Revalidation {
        let cachedSHA = cache.sha256(forRecord: recordID)
        let current: MCPAppResource?
        if let content = try? await source.currentResource(uri: resourceURI).get() {
            current = try? cache.store(content, requestedURI: resourceURI)
        } else {
            current = nil
        }
        let currentDescriptor = callDescriptor.flatMap { source.currentDescriptor(tool: $0.name) }
        let schemaUnchanged = sameJSON(callDescriptor?.outputSchema, currentDescriptor?.outputSchema)
        let readOnly = (currentDescriptor ?? callDescriptor)?.annotations?.isReadOnly ?? false
        let decision = decide(cachedSHA256: cachedSHA, currentSHA256: current?.sha256,
                              outputSchemaUnchanged: schemaUnchanged, toolIsReadOnly: readOnly,
                              approvedSHA256: approvedSHA256)
        var resource: MCPAppResource?
        if case .render(let viewOnly) = decision {
            resource = viewOnly ? cachedSHA.flatMap { cache.resource(sha256: $0) } : current
            if let current, !viewOnly { cache.bind(recordID: recordID, sha256: current.sha256) }
        }
        return Revalidation(decision: decision, resource: resource,
                            widgetChanged: current != nil && cachedSHA != nil && current?.sha256 != cachedSHA)
    }

    /// `ToolCallRecord` conveniences: a record has a widget to re-create when it has an MCP App
    /// link and a stored result.
    @MainActor
    public static func revalidate(_ record: ToolCallRecord, source: any MCPAppWidgetSource, cache: MCPAppWidgetCache,
                                  approvedSHA256: Set<String>? = nil) async -> Revalidation? {
        guard let uri = record.app?.resourceURI, record.mcpResult != nil else { return nil }
        return await revalidate(recordID: record.id, resourceURI: uri, callDescriptor: record.toolDescriptor,
                                source: source, cache: cache, approvedSHA256: approvedSHA256)
    }

    /// Hands a stored call to a (re-created) widget: its arguments as `tool-input` and its result as
    /// `tool-result` — what the widget got the first time, with no call to the server. The bridge
    /// holds them until the widget is ready.
    @MainActor
    public static func deliver(arguments: GeneratedContent?, result: MCPToolResult, to controller: MCPAppViewController) {
        controller.bridge.deliverToolInput(arguments: toolInput(from: arguments))
        controller.bridge.deliverToolResult(result)
    }

    /// `deliver(arguments:result:to:)` for a `ToolCallRecord`. Returns `false` (and delivers
    /// nothing) when the record has no stored result.
    @MainActor
    @discardableResult
    public static func deliver(_ record: ToolCallRecord, to controller: MCPAppViewController) -> Bool {
        guard let result = record.mcpResult else { return false }
        deliver(arguments: record.arguments, result: result, to: controller)
        return true
    }

    /// A tool call's arguments in the form a widget receives them (`ui/notifications/tool-input`).
    public static func toolInput(from arguments: GeneratedContent?) -> [String: MCPValue] {
        guard let json = arguments?.jsonString, let data = json.data(using: .utf8),
              case .object(let object)? = try? JSONDecoder().decode(MCPValue.self, from: data) else { return [:] }
        return object
    }

    static func sameJSON(_ a: Data?, _ b: Data?) -> Bool {
        func parse(_ d: Data?) -> NSObject? { d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? NSObject } }
        let x = parse(a), y = parse(b)
        if x == nil, y == nil { return a == b }
        return x?.isEqual(y) ?? false
    }
}

/// Where re-creation reads the server's current widget and tool.
@MainActor
public protocol MCPAppWidgetSource {
    func currentResource(uri: String) async -> Result<MCPResourceContent, MCPServerError>
    func currentDescriptor(tool: String) -> MCPToolDescriptor?
}

/// The standard source: one server of an `MCPServerManager`.
@MainActor
public struct MCPServerManagerWidgetSource: MCPAppWidgetSource {
    let manager: MCPServerManager
    let server: MCPServerID

    public init(manager: MCPServerManager, server: MCPServerID) {
        self.manager = manager
        self.server = server
    }

    public func currentResource(uri: String) async -> Result<MCPResourceContent, MCPServerError> {
        guard manager.servers[server]?.connectionStatus == .connected else { return .failure(.notConnected) }
        return await manager.readResource(server: server, uri: uri)
    }

    public func currentDescriptor(tool: String) -> MCPToolDescriptor? {
        manager.servers[server]?.tools.first { $0.name == tool }
    }
}
