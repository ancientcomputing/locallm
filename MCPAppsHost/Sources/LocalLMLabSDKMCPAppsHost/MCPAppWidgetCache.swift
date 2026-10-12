import Foundation
import LocalLMLabSDKCore

/// Widget HTML kept on disk by content hash, so a widget can be shown again — after scrolling back
/// past the live-widget limit, after a relaunch, or offline — without fetching it, and so a host can
/// tell when a server's widget changed.
///
/// One file per widget **version** (SHA-256 of its HTML), not per call: a widget is 1.6–3.2 MB
/// (measured), and many calls render the same version. The cache also remembers which version each tool
/// call was rendered with (`bind(recordID:sha256:)`), because a record alone does not say. Least
/// recently used versions are evicted past `maxBytes`.
@MainActor
public final class MCPAppWidgetCache {
    public let directory: URL
    /// Upper bound on the HTML kept on disk. Default 64 MB (about 20–40 widget versions).
    public var maxBytes: Int {
        didSet { evict() }
    }

    private struct Stored: Codable {
        var requestedURI: String
        var content: MCPResourceContent
    }

    private struct Index: Codable {
        var recordVersion: [String: String] = [:]
        var lastUsed: [String: Date] = [:]
        var size: [String: Int] = [:]
    }

    private var index: Index

    /// - Parameter directory: where to keep the cache. Default: `Caches/LocalLMLab/MCPAppWidgets`
    ///   in the app's container.
    public init(directory: URL? = nil, maxBytes: Int = 64 * 1024 * 1024) {
        let base = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalLMLab/MCPAppWidgets", isDirectory: true)
        self.directory = base
        self.maxBytes = maxBytes
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        index = (try? Data(contentsOf: base.appendingPathComponent("index.json")))
            .flatMap { try? JSONDecoder().decode(Index.self, from: $0) } ?? Index()
    }

    /// Validates `content` as an MCP App (`MCPAppResource`), keeps it, and returns it.
    @discardableResult
    public func store(_ content: MCPResourceContent, requestedURI: String) throws -> MCPAppResource {
        let resource = try MCPAppResource(content: content, requestedURI: requestedURI)
        let data = try JSONEncoder().encode(Stored(requestedURI: requestedURI, content: content))
        try data.write(to: file(resource.sha256), options: .atomic)
        index.size[resource.sha256] = data.count
        index.lastUsed[resource.sha256] = Date()
        evict()
        save()
        return resource
    }

    /// The cached widget version with this hash, or `nil`.
    public func resource(sha256: String) -> MCPAppResource? {
        guard let data = try? Data(contentsOf: file(sha256)),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              let resource = try? MCPAppResource(content: stored.content, requestedURI: stored.requestedURI),
              resource.sha256 == sha256 else { return nil }  // a damaged or swapped file is not served
        index.lastUsed[sha256] = Date()
        save()
        return resource
    }

    /// Remembers that tool call `recordID` was rendered with widget version `sha256`.
    public func bind(recordID: String, sha256: String) {
        index.recordVersion[recordID] = sha256
        save()
    }

    /// The widget version tool call `recordID` was rendered with, if known.
    public func sha256(forRecord recordID: String) -> String? { index.recordVersion[recordID] }

    public var storedBytes: Int { index.size.values.reduce(0, +) }
    public var storedVersions: Set<String> { Set(index.size.keys) }

    /// Fetches the widget a tool links to from its server, keeps it, and binds it to the call.
    public func fetch(resourceURI: String, server: MCPServerID, manager: MCPServerManager,
                      recordID: String? = nil) async throws -> MCPAppResource {
        let content = try await manager.readResource(server: server, uri: resourceURI).get()
        let listed = manager.servers[server]?.resources.first { $0.uri == resourceURI }?.meta
        let merged = content.meta == nil && listed != nil
            ? MCPResourceContent(uri: content.uri, mimeType: content.mimeType, text: content.text, blob: content.blob, meta: listed)
            : content
        let resource = try store(merged, requestedURI: resourceURI)
        if let recordID { bind(recordID: recordID, sha256: resource.sha256) }
        return resource
    }

    // MARK: private

    private func file(_ sha256: String) -> URL {
        let safe = sha256.filter { $0.isHexDigit }
        return directory.appendingPathComponent("\(safe).json")
    }

    private func evict() {
        while storedBytes > maxBytes, index.size.count > 1,
              let oldest = index.size.keys.min(by: { (index.lastUsed[$0] ?? .distantPast) < (index.lastUsed[$1] ?? .distantPast) }) {
            try? FileManager.default.removeItem(at: file(oldest))
            index.size.removeValue(forKey: oldest)
            index.lastUsed.removeValue(forKey: oldest)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(index) {
            try? data.write(to: directory.appendingPathComponent("index.json"), options: .atomic)
        }
    }
}
