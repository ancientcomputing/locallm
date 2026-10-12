import CryptoKit
import Foundation
import LocalLMLabSDKCore

// `_meta.ui` parsing for MCP Apps (SEP-1865). Everything here reads the verbatim `_meta`
// `MCPValue` Core surfaces on tool descriptors and resource contents; nothing is trusted — a
// malformed or hostile `_meta` degrades to "no UI" / "no permissions", never to a wider grant.

// Tool-side MCP Apps parsing (`MCPToolDescriptor.app`, `.appVisibility`, `.isModelVisible`,
// `MCPAppVisibility`, `MCPAppLink`) lives in LocalLMLabSDKCore, so every host applies the same
// visibility rules. This file keeps the resource side: what a fetched `ui://` widget declares.

/// The CSP origins a `ui://` resource asks for (`_meta.ui.csp`).
public struct MCPAppCSP: Sendable, Equatable {
    public var connectDomains: [String] = []
    public var resourceDomains: [String] = []
    public var frameDomains: [String] = []
    public var baseUriDomains: [String] = []

    public init(connectDomains: [String] = [], resourceDomains: [String] = [], frameDomains: [String] = [], baseUriDomains: [String] = []) {
        self.connectDomains = connectDomains
        self.resourceDomains = resourceDomains
        self.frameDomains = frameDomains
        self.baseUriDomains = baseUriDomains
    }

    /// True when the resource asks for no origins at all (Todoist's widget declares exactly this).
    public var isEmpty: Bool {
        connectDomains.isEmpty && resourceDomains.isEmpty && frameDomains.isEmpty && baseUriDomains.isEmpty
    }
}

/// Device permissions a `ui://` resource asks for (`_meta.ui.permissions`).
public struct MCPAppPermissions: Sendable, Equatable {
    public var camera = false
    public var microphone = false
    public var geolocation = false
    public var clipboardWrite = false

    public init(camera: Bool = false, microphone: Bool = false, geolocation: Bool = false, clipboardWrite: Bool = false) {
        self.camera = camera
        self.microphone = microphone
        self.geolocation = geolocation
        self.clipboardWrite = clipboardWrite
    }

    public var isEmpty: Bool { !(camera || microphone || geolocation || clipboardWrite) }
}

/// What a `ui://` resource declares about itself in `_meta.ui`. These are a server's *requests*;
/// the host decides what to grant (intersect with policy, never widen).
public struct MCPAppResourceInfo: Sendable, Equatable {
    public var csp: MCPAppCSP
    public var permissions: MCPAppPermissions
    public var domain: String?
    public var prefersBorder: Bool?

    public init(csp: MCPAppCSP = MCPAppCSP(), permissions: MCPAppPermissions = MCPAppPermissions(), domain: String? = nil, prefersBorder: Bool? = nil) {
        self.csp = csp
        self.permissions = permissions
        self.domain = domain
        self.prefersBorder = prefersBorder
    }

    /// Parses a resource's `_meta`. `nil` or malformed input yields the empty (most restrictive)
    /// declaration.
    public init(meta: MCPValue?) {
        self.init()
        guard case .object(let top)? = meta, case .object(let ui)? = top["ui"] else { return }
        func strings(_ value: MCPValue?) -> [String] {
            guard case .array(let items)? = value else { return [] }
            return items.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
        }
        if case .object(let csp)? = ui["csp"] {
            self.csp = MCPAppCSP(
                connectDomains: strings(csp["connectDomains"]),
                resourceDomains: strings(csp["resourceDomains"]),
                frameDomains: strings(csp["frameDomains"]),
                baseUriDomains: strings(csp["baseUriDomains"]))
        }
        if case .object(let perms)? = ui["permissions"] {
            func has(_ key: String) -> Bool { perms[key] != nil && perms[key] != .bool(false) && perms[key] != .null }
            permissions = MCPAppPermissions(
                camera: has("camera"), microphone: has("microphone"),
                geolocation: has("geolocation"), clipboardWrite: has("clipboardWrite"))
        }
        if case .string(let d)? = ui["domain"] { domain = d }
        if case .bool(let b)? = ui["prefersBorder"] { prefersBorder = b }
    }
}

public enum MCPAppResourceError: Error, Equatable, CustomStringConvertible {
    case notAUIResource(String)
    case wrongMimeType(String?)
    case noBody
    case invalidBase64

    public var description: String {
        switch self {
        case .notAUIResource(let uri): return "\(uri) is not a ui:// resource"
        case .wrongMimeType(let m): return "expected text/html;profile=mcp-app, got \(m ?? "no mimeType")"
        case .noBody: return "resource has neither text nor blob"
        case .invalidBase64: return "resource blob is not valid base64"
        }
    }
}

/// A fetched `ui://` widget: its HTML, what it declared, and the SHA-256 of the exact bytes — the
/// value an IT allowlist pins.
public struct MCPAppResource: Sendable, Equatable {
    public static let mimeType = "text/html;profile=mcp-app"

    public let uri: String
    public let html: String
    public let info: MCPAppResourceInfo
    /// Lowercase hex SHA-256 of the UTF-8 HTML.
    public let sha256: String

    /// Validates and wraps a `resources/read` result. `listedMeta` is the `_meta` from
    /// `resources/list`; the content entry's own `_meta` wins when both exist (spec: the read
    /// result is authoritative).
    public init(content: MCPResourceContent, requestedURI: String, listedMeta: MCPValue? = nil) throws {
        guard requestedURI.hasPrefix("ui://") else { throw MCPAppResourceError.notAUIResource(requestedURI) }
        let normalizedMime = content.mimeType?.lowercased().filter { !$0.isWhitespace }
        guard normalizedMime == Self.mimeType else { throw MCPAppResourceError.wrongMimeType(content.mimeType) }
        let html: String
        if let text = content.text {
            html = text
        } else if let blob = content.blob {
            guard let data = Data(base64Encoded: blob), let decoded = String(data: data, encoding: .utf8) else {
                throw MCPAppResourceError.invalidBase64
            }
            html = decoded
        } else {
            throw MCPAppResourceError.noBody
        }
        self.uri = requestedURI  // never the server-echoed URI
        self.html = html
        self.info = MCPAppResourceInfo(meta: content.meta ?? listedMeta)
        self.sha256 = SHA256.hash(data: Data(html.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension MCPClientHandlers {
    /// The client capability key under which a host declares MCP Apps support at `initialize`.
    public static let mcpAppsExtensionKey = "io.modelcontextprotocol/ui"

    /// These handlers, declaring MCP Apps support (`text/html;profile=mcp-app` widgets). Servers
    /// that gate their widgets on it (`_meta.ui` on tools) only offer them to a client that says so.
    ///
    /// ```swift
    /// let lab = LocalLMLab(configuration: .init(
    ///     providers: [...], mcp: MCPSettings(handlers: MCPClientHandlers().advertisingMCPApps())))
    /// ```
    public func advertisingMCPApps() -> MCPClientHandlers {
        var handlers = self
        handlers.extensions[Self.mcpAppsExtensionKey] = .object(["mimeTypes": .array([.string(MCPAppResource.mimeType)])])
        return handlers
    }
}
