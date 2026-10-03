import AppKit
import Foundation
import LocalLMLabSDKCore
import SwiftUI
import WebKit

/// Owns one widget's `WKWebView` and the `MCPAppsBridge` behind it.
///
/// Layers of containment, outermost first (each holds even if the one above it failed):
/// 1. the effective CSP (declared ∩ host policy), served as a header on the widget document;
/// 2. a WKContentRuleList blocking every http(s)/ws(s)/ftp load outside the effective origins;
/// 3. the widget runs in a sandboxed iframe (opaque origin) inside a relay page;
/// 4. navigation is pinned to this view's own `mcpapp://<token>/` documents; new windows, file
///    pickers and media/geolocation capture are refused;
/// 5. the native message handler accepts only main-frame (relay) messages, and every message
///    goes through `MCPAppsBridge`'s policy.
/// The web view uses a non-persistent data store: no cookies, cache or storage survive it.
@MainActor
public final class MCPAppViewController: NSObject, ObservableObject {
    public enum LoadState: Equatable {
        case idle, loading, loaded
        case failed(String)
    }

    public let webView: WKWebView
    /// The bridge to deliver `tool-input` / `tool-result` through. Available immediately; the
    /// bridge queues notifications until the widget reports it is initialized.
    public private(set) var bridge: MCPAppsBridge!
    /// The CSP actually enforced for this view.
    public let effectiveCSP: MCPAppCSP
    public let resource: MCPAppResource
    @Published public private(set) var loadState: LoadState = .idle
    /// Height the widget last asked for (`ui/notifications/size-changed`), for SwiftUI layout.
    @Published public private(set) var contentHeight: CGFloat?
    /// The display mode in effect: `"inline"` (fills the space the host gives the view) or
    /// `"fullscreen"` (the host UI should expand the view over its chrome). Changes when the widget
    /// asks for a mode listed in `supportedDisplayModes`, or when `exitFullscreen()` is called.
    @Published public private(set) var displayMode: String = "inline"
    /// The modes this controller offers the widget; a widget shows a fullscreen button only if
    /// `"fullscreen"` is here. List it only if the host UI reacts to `displayMode`.
    public let supportedDisplayModes: [String]

    private let pages: MCPAppsPages
    private let sandboxPolicy: MCPAppsSandboxPolicy
    private let ruleListIdentifier: String
    private var ruleList: WKContentRuleList?
    private var closed = false
    /// The widget iframe's frame, captured when its document is navigated to (testing hook only).
    private var widgetFrame: WKFrameInfo?
    private var appearanceObservation: NSKeyValueObservation?
    private var frameObserver: NSObjectProtocol?
    private var resizeTask: Task<Void, Never>?
    private var lastReportedSize: CGSize = .zero

    /// - Parameters:
    ///   - resource: the fetched, validated widget. (Pin/verify `resource.sha256` BEFORE creating
    ///     the controller; the controller renders whatever it is given.)
    ///   - tools: the bound server's tools, for the bridge's tool-call checks.
    public init(
        resource: MCPAppResource,
        tools: [MCPToolDescriptor],
        backend: any MCPAppsBackend,
        configuration: MCPAppsBridgeConfiguration,
        bridgePolicy: any MCPAppsBridgePolicy = MCPAppsDefaultPolicy(),
        sandboxPolicy: MCPAppsSandboxPolicy = .closed,
        actions: MCPAppsHostActions = MCPAppsHostActions(),
        supportedDisplayModes: [String] = ["inline"],
        audit: @escaping @MainActor (MCPAppsAuditEvent) -> Void = { _ in }
    ) {
        let effective = MCPAppsSandbox.effectiveCSP(declared: resource.info.csp, policy: sandboxPolicy)
        self.effectiveCSP = effective
        self.resource = resource
        self.sandboxPolicy = sandboxPolicy
        self.pages = MCPAppsPages(widgetHTML: resource.html, csp: effective, allowsSameOrigin: sandboxPolicy.allowsSameOrigin)
        self.ruleListIdentifier = "mcp-app-" + pages.token

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.mediaTypesRequiringUserActionForPlayback = .all
        let handler = MCPAppsSchemeHandler(pages: pages)
        config.setURLSchemeHandler(handler, forURLScheme: MCPAppsPages.scheme)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isInspectable = sandboxPolicy.isInspectable
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.setValue(false, forKey: "drawsBackground")
        self.webView = webView
        self.supportedDisplayModes = supportedDisplayModes.contains("inline") ? supportedDisplayModes : ["inline"] + supportedDisplayModes

        super.init()

        // Report exactly what this controller enforces, not what the server asked for.
        var configuration = configuration
        configuration.effectiveCSP = effective
        configuration.effectivePermissions = MCPAppPermissions()  // no device permissions are granted
        configuration.availableDisplayModes = self.supportedDisplayModes
        if configuration.hostContext["theme"] == nil { configuration.hostContext["theme"] = .string(Self.theme(of: webView)) }
        var actions = actions
        let userRequestDisplayMode = actions.requestDisplayMode
        actions.requestDisplayMode = { [weak self] mode in
            guard let self, self.supportedDisplayModes.contains(mode) else { return false }
            _ = userRequestDisplayMode(mode)
            self.displayMode = mode
            return true
        }
        self.bridge = MCPAppsBridge(
            configuration: configuration, tools: tools, backend: backend, policy: bridgePolicy,
            send: { [weak webView] data in
                guard let webView, let json = String(data: data, encoding: .utf8) else { return }
                webView.evaluateJavaScript("window.__mcpDeliver(\(Self.jsStringLiteral(json)))", completionHandler: nil)
            },
            audit: audit,
            onSizeChanged: { [weak self] _, height in
                guard let height, height.isFinite, height > 0 else { return }
                self?.contentHeight = min(CGFloat(height), 4000)
            },
            actions: actions)

        // The handler holds the controller weakly: WKUserContentController retains handlers.
        let relay = WeakScriptHandler(owner: self)
        config.userContentController.add(relay, name: "mcpBridge")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observeHostContext()
    }

    /// Leaves fullscreen (e.g. the host's Esc / close button) and tells the widget.
    public func exitFullscreen() {
        guard displayMode != "inline" else { return }
        displayMode = "inline"
        bridge.setDisplayMode("inline")
    }

    // MARK: host context the widget adapts to

    private static func theme(of view: NSView) -> String {
        view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
    }

    /// Keeps the widget's `hostContext` current: light/dark follows the system, and the container
    /// size follows the web view (debounced, and only when it actually changed).
    private func observeHostContext() {
        appearanceObservation = webView.observe(\.effectiveAppearance, options: [.new]) { [weak self] view, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.bridge.deliverHostContextChange(["theme": .string(Self.theme(of: view))])
            }
        }
        webView.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: webView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleSizeReport() }
        }
    }

    private func scheduleSizeReport() {
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self, !self.closed else { return }
            let size = self.webView.bounds.size
            guard size.width > 0, size.height > 0, size != self.lastReportedSize else { return }
            self.lastReportedSize = size
            self.bridge.deliverHostContextChange([
                "containerDimensions": .object(["width": .number(Double(size.width)), "height": .number(Double(size.height))])
            ])
        }
    }

    /// Compiles the network block list, then loads the relay page. Resolves when the load has
    /// been started; `loadState` reports completion.
    public func load() async {
        guard !closed, loadState == .idle else { return }
        loadState = .loading
        do {
            let json = MCPAppsSandbox.contentRuleListJSON(for: effectiveCSP)
            guard let list = try await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: ruleListIdentifier, encodedContentRuleList: json) else {
                loadState = .failed("Could not compile the network block list")
                return  // fail closed: never load a widget without the network block in place
            }
            ruleList = list
            webView.configuration.userContentController.add(list)
        } catch {
            loadState = .failed("Could not compile the network block list: \(error.localizedDescription)")
            return
        }
        webView.load(URLRequest(url: pages.hostURL))
    }

    /// Tears the view down: asks the widget to clean up, closes the bridge, removes the message
    /// handler and the block list. Call when the view goes away.
    ///
    /// Closing a widget means `close()` **and releasing** this controller and its `webView`: the
    /// widget's WebContent process (~100 MB) ends only when the web view is deallocated, not when
    /// `close()` returns (measured). `MCPAppViewPool` does both.
    public func close() async {
        guard !closed else { return }
        closed = true
        resizeTask?.cancel()
        appearanceObservation?.invalidate()
        appearanceObservation = nil
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        frameObserver = nil
        await bridge.teardown()
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "mcpBridge")
        webView.configuration.userContentController.removeAllContentRuleLists()
        try? await WKContentRuleListStore.default().removeContentRuleList(forIdentifier: ruleListIdentifier)
        ruleList = nil
    }

    /// Runs `script` inside the WIDGET's frame with native privilege (it does not need, and is not
    /// subject to, the frame's opaque origin). For automated tests and diagnostics only — e.g.
    /// clicking a control in a widget to prove a click reaches the server through the bridge. Not
    /// public API: import with `@_spi(Testing)`.
    @_spi(Testing)
    public func evaluateInWidget(_ script: String) async throws -> Any? {
        guard let widgetFrame else { throw URLError(.badURL) }
        return try await webView.evaluateJavaScript(script, in: widgetFrame, contentWorld: .page)
    }

    /// A JS string literal for arbitrary text (JSON string encoding is valid JS; U+2028/2029 are
    /// legal in string literals since ES2019).
    static func jsStringLiteral(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text], options: []),
              let array = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(array.dropFirst().dropLast())
    }
}

// MARK: - message handler

private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var owner: MCPAppViewController?

    init(owner: MCPAppViewController) {
        self.owner = owner
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            owner?.handle(message)
        }
    }
}

extension MCPAppViewController {
    fileprivate func handle(_ message: WKScriptMessage) {
        // Only the relay page (main frame) may talk to native code. The widget lives in a
        // subframe; if it reaches `webkit.messageHandlers` directly its message is dropped here.
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.host == pages.token else { return }
        guard let body = message.body as? String else { return }
        let data = Data(body.utf8)
        // One Task per message: MainActor tasks start in FIFO order, and the handshake handlers
        // don't suspend before replying, so ordering of initialize -> initialized is preserved.
        Task { await bridge.receive(data) }
    }
}

// MARK: - navigation + UI containment

extension MCPAppViewController: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        // Pin every navigation (main frame, iframe, link click, redirect) to this view's own
        // documents. A link the widget wants opened goes through `ui/open-link` and the policy.
        guard let url = navigationAction.request.url, url.scheme == MCPAppsPages.scheme, url.host == pages.token,
              url.path == MCPAppsPages.hostPath || url.path == MCPAppsPages.widgetPath else {
            return .cancel
        }
        if url.path == MCPAppsPages.widgetPath { widgetFrame = navigationAction.targetFrame }
        return .allow
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if loadState == .loading { loadState = .loaded }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        loadState = .failed(error.localizedDescription)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        loadState = .failed(error.localizedDescription)
    }
}

extension MCPAppViewController: WKUIDelegate {
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil  // no popups, no target=_blank
    }

    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        completionHandler()  // widgets don't get to put up native dialogs
    }

    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        completionHandler(false)
    }

    public func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        completionHandler(nil)
    }

    public func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
        completionHandler(nil)  // no file access
    }

    public func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)  // camera / microphone: never granted (see `effectivePermissions`)
    }
}

// MARK: - SwiftUI

/// Hosts a controller's web view in SwiftUI. The owner keeps the controller alive and calls
/// `load()` once and `close()` when done.
public struct MCPAppView: NSViewRepresentable {
    private let controller: MCPAppViewController

    public init(controller: MCPAppViewController) {
        self.controller = controller
    }

    public func makeNSView(context: Context) -> WKWebView { controller.webView }
    public func updateNSView(_ nsView: WKWebView, context: Context) {}
}
