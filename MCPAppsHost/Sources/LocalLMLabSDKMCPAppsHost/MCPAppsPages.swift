import Foundation
import WebKit

/// The two documents a widget view serves from the private `mcpapp://<token>/` scheme:
///
/// - `host.html`: a tiny relay page (main frame) that embeds the widget in a sandboxed iframe and
///   shuttles JSON-RPC messages between that iframe and native code. This is the spec's native
///   arrangement: the widget sees a normal `window.parent`, but it runs in an opaque origin and
///   cannot reach the native message handler (which the controller accepts from the main frame
///   only).
/// - `widget.html`: the server's HTML, served with the effective CSP as a response header.
///
/// Anything else 404s. The token is unguessable per view, so another view (or page) cannot
/// address this one's documents.
struct MCPAppsPages {
    static let scheme = "mcpapp"
    static let hostPath = "/host.html"
    static let widgetPath = "/widget.html"

    let token: String
    let nonce: String
    let widgetHTML: String
    let csp: MCPAppCSP
    let allowsSameOrigin: Bool

    init(widgetHTML: String, csp: MCPAppCSP, allowsSameOrigin: Bool) {
        // 128 bits of randomness each, hex: safe as a hostname label and as a CSP nonce.
        func random() -> String { (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined() }
        self.token = random()
        self.nonce = random()
        self.widgetHTML = widgetHTML
        self.csp = csp
        self.allowsSameOrigin = allowsSameOrigin
    }

    var hostURL: URL { URL(string: "\(Self.scheme)://\(token)\(Self.hostPath)")! }
    var widgetURL: URL { URL(string: "\(Self.scheme)://\(token)\(Self.widgetPath)")! }

    struct Page {
        var body: Data
        var headers: [String: String]
    }

    /// The document for `url`, or `nil` (404) for a wrong scheme, host token, or path.
    func page(for url: URL) -> Page? {
        guard url.scheme == Self.scheme, url.host == token else { return nil }
        let common = [
            "Content-Type": "text/html; charset=utf-8",
            "X-Content-Type-Options": "nosniff",
            "Referrer-Policy": "no-referrer",
            "Cache-Control": "no-store",
        ]
        switch url.path {
        case Self.hostPath:
            var headers = common
            headers["Content-Security-Policy"] = hostCSP
            return Page(body: Data(hostHTML.utf8), headers: headers)
        case Self.widgetPath:
            var headers = common
            headers["Content-Security-Policy"] = MCPAppsSandbox.headerValue(for: csp)
            return Page(body: Data(widgetHTML.utf8), headers: headers)
        default:
            return nil
        }
    }

    /// The relay page can only run its own nonce'd script and frame the widget document.
    var hostCSP: String {
        "default-src 'none'; script-src 'nonce-\(nonce)'; style-src 'nonce-\(nonce)'; "
            + "frame-src \(Self.scheme)://\(token); base-uri 'none'; form-action 'none'; object-src 'none'"
    }

    var hostHTML: String {
        let sandbox = allowsSameOrigin ? "allow-scripts allow-forms allow-same-origin" : "allow-scripts allow-forms"
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <style nonce="\(nonce)">html,body{margin:0;height:100%;background:transparent;overflow:hidden}iframe{border:0;width:100%;height:100%;display:block}</style>
        </head><body>
        <iframe id="view" sandbox="\(sandbox)" src="\(widgetURL.absoluteString)"></iframe>
        <script nonce="\(nonce)">
        (function () {
          var frame = document.getElementById('view');
          // view -> native: only messages from the widget iframe itself, only JSON-RPC objects.
          window.addEventListener('message', function (event) {
            if (event.source !== frame.contentWindow) return;
            var data = event.data;
            if (!data || typeof data !== 'object' || data.jsonrpc !== '2.0') return;
            window.webkit.messageHandlers.mcpBridge.postMessage(JSON.stringify(data));
          });
          // native -> view
          window.__mcpDeliver = function (json) {
            frame.contentWindow.postMessage(JSON.parse(json), '*');
          };
        })();
        </script>
        </body></html>
        """
    }
}

/// Serves `MCPAppsPages` to WebKit. Requests for anything but this view's two documents fail.
@MainActor
final class MCPAppsSchemeHandler: NSObject, WKURLSchemeHandler {
    private let pages: MCPAppsPages

    init(pages: MCPAppsPages) {
        self.pages = pages
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let url = urlSchemeTask.request.url
        guard let url, urlSchemeTask.request.httpMethod == "GET" || urlSchemeTask.request.httpMethod == nil,
              let page = pages.page(for: url),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: page.headers) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(page.body)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
