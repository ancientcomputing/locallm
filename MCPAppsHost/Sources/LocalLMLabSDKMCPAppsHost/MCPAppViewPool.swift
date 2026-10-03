import AppKit
import Foundation
import WebKit

/// Keeps at most `limit` widgets live.
///
/// Each live widget is a `WKWebView` with its own WebContent process — about 105 MB each, as
/// measured in a chat host. Past the limit the least recently used widget is snapshotted, closed and
/// **released** (`close()` alone does not end its process; dropping the view does), and the host
/// shows `snapshot(for:)` in its place until the user scrolls back or taps it, when the host asks
/// for the view again and it is re-created.
@MainActor
public final class MCPAppViewPool: ObservableObject {
    /// How many widgets stay live. Default 3. Lowering it releases widgets right away.
    public var limit: Int {
        didSet { trim() }
    }

    @Published public private(set) var liveKeys: [String] = []
    @Published private var snapshots: [String: NSImage] = [:]
    private var controllers: [String: MCPAppViewController] = [:]

    public init(limit: Int = 3) {
        self.limit = max(1, limit)
    }

    /// The live controller for `key` (e.g. the tool-call record id), creating it with `make` if it
    /// is not live, and marking it most recently used. `make` is not called for a live key.
    public func controller(for key: String, make: () throws -> MCPAppViewController) rethrows -> MCPAppViewController {
        if let live = controllers[key] {
            touch(key)
            return live
        }
        let controller = try make()
        controllers[key] = controller
        touch(key)
        trim()
        return controller
    }

    /// Marks `key` as most recently used (e.g. it scrolled into view).
    public func touch(_ key: String) {
        guard controllers[key] != nil else { return }
        liveKeys.removeAll { $0 == key }
        liveKeys.append(key)
    }

    public func isLive(_ key: String) -> Bool { controllers[key] != nil }

    /// The picture of a released widget, shown in its place. `nil` while it is live or if it was
    /// released before it could be captured.
    public func snapshot(for key: String) -> NSImage? { snapshots[key] }

    /// Closes and releases `key`'s widget, keeping a snapshot.
    public func release(_ key: String) async {
        guard let controller = detach(key) else { return }
        await finish(key, controller)
    }

    /// Stops treating `key` as live, at once.
    private func detach(_ key: String) -> MCPAppViewController? {
        guard let controller = controllers.removeValue(forKey: key) else { return nil }
        liveKeys.removeAll { $0 == key }
        return controller
    }

    private func finish(_ key: String, _ controller: MCPAppViewController) async {
        if let image = await Self.snapshot(controller.webView) { snapshots[key] = image }
        await controller.close()
        controller.webView.removeFromSuperview()
    }

    /// Releases every widget (e.g. the conversation closed).
    public func releaseAll() async {
        for key in liveKeys { await release(key) }
    }

    /// Forgets a snapshot (e.g. its entry was deleted).
    public func discardSnapshot(for key: String) { snapshots.removeValue(forKey: key) }

    private func trim() {
        let excess = liveKeys.count - limit
        guard excess > 0 else { return }
        // Detach now so the pool never reports an evicted widget as live; snapshot and close
        // finish asynchronously.
        for key in Array(liveKeys.prefix(excess)) {
            guard let controller = detach(key) else { continue }
            Task { await finish(key, controller) }
        }
    }

    private static func snapshot(_ webView: WKWebView) async -> NSImage? {
        guard webView.bounds.width > 0, webView.bounds.height > 0 else { return nil }
        return await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: nil) { image, _ in continuation.resume(returning: image) }
        }
    }
}
