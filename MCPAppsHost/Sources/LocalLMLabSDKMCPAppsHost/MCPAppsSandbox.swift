import Foundation

/// What the HOST allows a widget to reach, independent of what the widget's `_meta.ui.csp` asks
/// for. A server's CSP declaration is a request: the effective CSP is the declaration
/// INTERSECTED with this policy, so a server update can never widen what an employee's app lets
/// a widget contact. The default allows nothing.
public struct MCPAppsSandboxPolicy: Sendable, Equatable {
    /// Origins a widget may `fetch`/WebSocket to. Exact `https://host[:port]` / `wss://host[:port]`,
    /// or a `https://*.example.com` wildcard. A declared origin is granted only if it matches an
    /// entry here.
    public var allowedConnectOrigins: [String]
    /// Origins a widget may load scripts, styles, images, fonts and media from.
    public var allowedResourceOrigins: [String]
    /// Origins a widget may embed in a frame.
    public var allowedFrameOrigins: [String]
    /// Adds `allow-same-origin` to the widget iframe's sandbox. Off by default: the widget then
    /// runs in an opaque origin with no access to storage or cookies. Turn on only for a widget
    /// that needs `localStorage` and is otherwise trusted.
    public var allowsSameOrigin: Bool
    /// Makes the WKWebView inspectable in Safari's Develop menu. Debug builds only.
    public var isInspectable: Bool

    public init(
        allowedConnectOrigins: [String] = [], allowedResourceOrigins: [String] = [],
        allowedFrameOrigins: [String] = [], allowsSameOrigin: Bool = false, isInspectable: Bool = false
    ) {
        self.allowedConnectOrigins = allowedConnectOrigins
        self.allowedResourceOrigins = allowedResourceOrigins
        self.allowedFrameOrigins = allowedFrameOrigins
        self.allowsSameOrigin = allowsSameOrigin
        self.isInspectable = isInspectable
    }

    /// Allow no network, no frames, no storage.
    public static let closed = MCPAppsSandboxPolicy()
}

/// Pure functions behind the web-view sandbox: origin validation, CSP intersection and header
/// construction, and the WebKit content-rule list that blocks network loads as a second layer
/// beneath the CSP. No WebKit types, so all of it is unit-tested directly.
public enum MCPAppsSandbox {
    // MARK: origins

    /// A server-supplied origin is interpolated into a CSP header, so it is validated strictly
    /// (a `;` or space would let a hostile server inject its own directives). Accepts only
    /// `https://` / `wss://` + a DNS-style host (optionally `*.`-prefixed) + optional port.
    public static func isSafeOrigin(_ origin: String) -> Bool {
        parse(origin) != nil
    }

    struct ParsedOrigin: Equatable {
        var scheme: String
        var host: String  // lowercased; may start with "*."
        var port: Int?
        var isWildcard: Bool { host.hasPrefix("*.") }
    }

    static func parse(_ origin: String) -> ParsedOrigin? {
        guard origin.count <= 253, origin.utf8.allSatisfy({ $0 < 0x80 }) else { return nil }
        let lower = origin.lowercased()
        let schemes = ["https://": "https", "wss://": "wss"]
        guard let (prefix, scheme) = schemes.first(where: { lower.hasPrefix($0.key) }) else { return nil }
        var rest = String(lower.dropFirst(prefix.count))
        var port: Int?
        if let colon = rest.lastIndex(of: ":") {
            let portString = String(rest[rest.index(after: colon)...])
            guard !portString.isEmpty, portString.count <= 5, portString.allSatisfy(\.isNumber),
                  let p = Int(portString), (1...65535).contains(p) else { return nil }
            port = p
            rest = String(rest[..<colon])
        }
        var host = rest
        var wildcard = false
        if host.hasPrefix("*.") { wildcard = true; host = String(host.dropFirst(2)) }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, !host.isEmpty else { return nil }  // no bare TLDs / single labels
        for label in labels {
            guard !label.isEmpty, label.count <= 63, !label.hasPrefix("-"), !label.hasSuffix("-"),
                  label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        }
        return ParsedOrigin(scheme: scheme, host: (wildcard ? "*." : "") + host, port: port)
    }

    /// True when `declared` is granted by `pattern`. Exact origin match, or `pattern` is a
    /// `*.parent` wildcard covering a concrete subdomain of `parent` (same scheme and port).
    /// A declared wildcard is granted only by an identical wildcard entry.
    static func matches(declared: ParsedOrigin, pattern: ParsedOrigin) -> Bool {
        guard declared.scheme == pattern.scheme, declared.port == pattern.port else { return false }
        if declared.host == pattern.host { return true }
        guard pattern.isWildcard, !declared.isWildcard else { return false }
        return declared.host.hasSuffix(String(pattern.host.dropFirst(1)))  // ".example.com"
    }

    private static func intersect(_ declared: [String], _ allowed: [String]) -> [String] {
        let patterns = allowed.compactMap(parse)
        var seen = Set<String>()
        var result: [String] = []
        for origin in declared {
            guard let parsed = parse(origin), patterns.contains(where: { matches(declared: parsed, pattern: $0) }) else { continue }
            let normalized = canonical(parsed)
            if seen.insert(normalized).inserted { result.append(normalized) }
        }
        return result
    }

    private static func canonical(_ o: ParsedOrigin) -> String {
        "\(o.scheme)://\(o.host)" + (o.port.map { ":\($0)" } ?? "")
    }

    // MARK: CSP

    /// The CSP the host will actually enforce: each declared origin list intersected with the
    /// host's allowlist. `baseUriDomains` are never granted (a widget has no business rebasing
    /// URLs).
    public static func effectiveCSP(declared: MCPAppCSP, policy: MCPAppsSandboxPolicy) -> MCPAppCSP {
        MCPAppCSP(
            connectDomains: intersect(declared.connectDomains, policy.allowedConnectOrigins),
            resourceDomains: intersect(declared.resourceDomains, policy.allowedResourceOrigins),
            frameDomains: intersect(declared.frameDomains, policy.allowedFrameOrigins),
            baseUriDomains: [])
    }

    /// The `Content-Security-Policy` header value for a widget document. Every origin in `csp`
    /// must already have passed `effectiveCSP` (each is re-validated here regardless).
    public static func headerValue(for csp: MCPAppCSP) -> String {
        func sources(_ base: [String], _ extra: [String]) -> String {
            (base + extra.filter(isSafeOrigin)).joined(separator: " ")
        }
        let frames = csp.frameDomains.filter(isSafeOrigin)
        return [
            "default-src 'none'",
            "script-src \(sources(["'self'", "'unsafe-inline'"], csp.resourceDomains))",
            "style-src \(sources(["'self'", "'unsafe-inline'"], csp.resourceDomains))",
            "img-src \(sources(["'self'", "data:", "blob:"], csp.resourceDomains))",
            "font-src \(sources(["'self'", "data:"], csp.resourceDomains))",
            "media-src \(sources(["'self'", "data:", "blob:"], csp.resourceDomains))",
            "connect-src \(csp.connectDomains.filter(isSafeOrigin).isEmpty ? "'none'" : csp.connectDomains.filter(isSafeOrigin).joined(separator: " "))",
            "frame-src \(frames.isEmpty ? "'none'" : frames.joined(separator: " "))",
            "base-uri 'none'",
            "form-action 'none'",
            "object-src 'none'",
        ].joined(separator: "; ")
    }

    // MARK: WebKit content rules (second layer under the CSP)

    /// A WKContentRuleList (JSON) that blocks every http(s)/ws(s)/ftp load except the effective
    /// allowed origins. It applies to the whole web view, so it holds even if a CSP were ever
    /// mis-served. WebKit's content-blocker regex has no groups or alternation, hence one rule per
    /// scheme and per allowed origin.
    public static func contentRuleListJSON(for csp: MCPAppCSP) -> String {
        var rules: [[String: Any]] = ["^https?://", "^wss?://", "^ftp://"].map {
            ["trigger": ["url-filter": $0], "action": ["type": "block"]]
        }
        let allowed = Set(csp.connectDomains + csp.resourceDomains + csp.frameDomains).compactMap(parse)
        for origin in allowed.sorted(by: { canonical($0) < canonical($1) }) {
            let host = origin.isWildcard
                ? "[a-z0-9.-]+\\." + escapeForRegex(String(origin.host.dropFirst(2)))
                : escapeForRegex(origin.host)
            // Content-blocker regex has no groups, so an explicit default port (`:443`) in a URL
            // is not matched for a portless origin — WebKit normalizes it away in practice.
            let filter = "^\(origin.scheme)://\(host)" + (origin.port.map { ":\($0)" } ?? "") + "/"
            rules.append(["trigger": ["url-filter": filter], "action": ["type": "ignore-previous-rules"]])
        }
        let data = (try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static func escapeForRegex(_ s: String) -> String {
        s.replacingOccurrences(of: ".", with: "\\.")
    }
}
