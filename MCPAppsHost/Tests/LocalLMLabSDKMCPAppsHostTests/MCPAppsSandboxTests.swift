import Foundation
import Testing

import LocalLMLabSDKMCPAppsHost

@Suite struct MCPAppsSandboxTests {
    // MARK: origin validation (server-supplied strings go into a CSP header)

    @Test func acceptsPlainHTTPSAndWSSOrigins() {
        for ok in ["https://api.example.com", "https://a.b.example.co.uk:8443", "wss://ws.example.com", "https://*.example.com", "HTTPS://API.Example.COM"] {
            #expect(MCPAppsSandbox.isSafeOrigin(ok), "\(ok)")
        }
    }

    @Test func rejectsAnythingThatCouldInjectOrWeaken() {
        let bad = [
            "http://example.com",                       // no cleartext
            "https://example.com/path",                 // not an origin
            "https://example.com; script-src *",        // directive injection
            "https://example.com script-src *",
            "https://example.com,https://evil.com",
            "'unsafe-eval'", "*", "data:", "blob:", "self", "https://*", "https://*.com.",
            "https://localhost", "https://com", "https://-bad.example.com", "https://ex ample.com",
            "https://example.com:0", "https://example.com:99999", "https://example.com:",
            "https://exämple.com", "", "https://", "https://.example.com", "https://example..com",
            "https://example.com\r\nX-Evil: 1", "https://exa\"mple.com",
        ]
        for origin in bad { #expect(!MCPAppsSandbox.isSafeOrigin(origin), "should reject \(origin.debugDescription)") }
    }

    // MARK: intersection

    @Test func closedPolicyGrantsNothingWhateverTheServerAsks() {
        let declared = MCPAppCSP(
            connectDomains: ["https://api.example.com"], resourceDomains: ["https://cdn.example.com"],
            frameDomains: ["https://embed.example.com"], baseUriDomains: ["https://base.example.com"])
        let effective = MCPAppsSandbox.effectiveCSP(declared: declared, policy: .closed)
        #expect(effective.isEmpty)
    }

    @Test func exactAllowlistEntriesGrantOnlyMatchingDeclaredOrigins() {
        let policy = MCPAppsSandboxPolicy(allowedConnectOrigins: ["https://api.example.com"])
        let declared = MCPAppCSP(connectDomains: ["https://api.example.com", "https://evil.example.net", "https://API.example.com:8443"])
        #expect(MCPAppsSandbox.effectiveCSP(declared: declared, policy: policy).connectDomains == ["https://api.example.com"])
    }

    @Test func eachDirectiveUsesItsOwnAllowlist() {
        let policy = MCPAppsSandboxPolicy(allowedConnectOrigins: ["https://api.example.com"])
        let declared = MCPAppCSP(connectDomains: ["https://api.example.com"], resourceDomains: ["https://api.example.com"])
        let effective = MCPAppsSandbox.effectiveCSP(declared: declared, policy: policy)
        #expect(effective.connectDomains == ["https://api.example.com"])
        #expect(effective.resourceDomains.isEmpty)  // connect allowance doesn't leak into resources
    }

    @Test func wildcardAllowlistCoversSubdomainsButNotTheApexOrLookalikes() {
        let policy = MCPAppsSandboxPolicy(allowedResourceOrigins: ["https://*.example.com"])
        let declared = MCPAppCSP(resourceDomains: [
            "https://cdn.example.com", "https://a.b.example.com", "https://example.com",
            "https://evilexample.com", "https://cdn.example.com.evil.net", "wss://cdn.example.com", "https://cdn.example.com:8443",
        ])
        #expect(MCPAppsSandbox.effectiveCSP(declared: declared, policy: policy).resourceDomains
                == ["https://cdn.example.com", "https://a.b.example.com"])
    }

    @Test func aDeclaredWildcardNeedsAnIdenticalWildcardInPolicy() {
        let declared = MCPAppCSP(connectDomains: ["https://*.example.com"])
        let exactOnly = MCPAppsSandboxPolicy(allowedConnectOrigins: ["https://api.example.com"])
        #expect(MCPAppsSandbox.effectiveCSP(declared: declared, policy: exactOnly).connectDomains.isEmpty)
        let wildcard = MCPAppsSandboxPolicy(allowedConnectOrigins: ["https://*.example.com"])
        #expect(MCPAppsSandbox.effectiveCSP(declared: declared, policy: wildcard).connectDomains == ["https://*.example.com"])
    }

    @Test func baseURIIsNeverGranted() {
        let policy = MCPAppsSandboxPolicy(allowedConnectOrigins: ["https://a.example.com"], allowedResourceOrigins: ["https://a.example.com"])
        let declared = MCPAppCSP(baseUriDomains: ["https://a.example.com"])
        #expect(MCPAppsSandbox.effectiveCSP(declared: declared, policy: policy).baseUriDomains.isEmpty)
    }

    @Test func intersectionDeduplicatesAndNormalizes() {
        let policy = MCPAppsSandboxPolicy(allowedConnectOrigins: ["https://api.example.com"])
        let declared = MCPAppCSP(connectDomains: ["https://API.example.com", "https://api.example.com"])
        #expect(MCPAppsSandbox.effectiveCSP(declared: declared, policy: policy).connectDomains == ["https://api.example.com"])
    }

    // MARK: header

    @Test func emptyCSPHeaderIsFullyClosed() {
        let header = MCPAppsSandbox.headerValue(for: MCPAppCSP())
        #expect(header.contains("default-src 'none'"))
        #expect(header.contains("connect-src 'none'"))
        #expect(header.contains("frame-src 'none'"))
        #expect(header.contains("base-uri 'none'"))
        #expect(header.contains("form-action 'none'"))
        #expect(header.contains("object-src 'none'"))
        #expect(!header.contains("http"))
        #expect(!header.contains("'unsafe-eval'"))
    }

    @Test func headerListsGrantedOriginsInTheRightDirectives() {
        let csp = MCPAppCSP(
            connectDomains: ["https://api.example.com"], resourceDomains: ["https://cdn.example.com"],
            frameDomains: ["https://embed.example.com"])
        let header = MCPAppsSandbox.headerValue(for: csp)
        #expect(header.contains("connect-src https://api.example.com;"))
        #expect(header.contains("script-src 'self' 'unsafe-inline' https://cdn.example.com;"))
        #expect(header.contains("img-src 'self' data: blob: https://cdn.example.com;"))
        #expect(header.contains("frame-src https://embed.example.com;"))
        #expect(!header.contains("connect-src https://api.example.com https://cdn"))
    }

    @Test func headerRefusesToEmitAnUnsafeOriginEvenIfHandedOne() {
        let hostile = MCPAppCSP(
            connectDomains: ["https://ok.example.com", "https://x.com; script-src *"],
            resourceDomains: ["https://y.com 'unsafe-eval'"], frameDomains: ["*"])
        let header = MCPAppsSandbox.headerValue(for: hostile)
        #expect(header.contains("https://ok.example.com"))
        #expect(!header.contains("script-src *"))
        #expect(!header.contains("unsafe-eval"))
        #expect(!header.contains("x.com"))
        #expect(header.contains("frame-src 'none'"))
    }

    // MARK: WebKit block list

    private func rules(_ csp: MCPAppCSP) -> [[String: [String: String]]] {
        let data = Data(MCPAppsSandbox.contentRuleListJSON(for: csp).utf8)
        return (try! JSONSerialization.jsonObject(with: data)) as! [[String: [String: String]]]
    }

    @Test func blockListBlocksAllNetworkSchemesFirst() {
        let r = rules(MCPAppCSP())
        #expect(r.count == 3)
        #expect(r.allSatisfy { $0["action"]?["type"] == "block" })
        let filters = r.compactMap { $0["trigger"]?["url-filter"] }
        #expect(filters.contains("^https?://"))
        #expect(filters.contains("^wss?://"))
        #expect(filters.contains("^ftp://"))
    }

    @Test func blockListExemptsOnlyEffectiveOriginsAfterTheBlocks() {
        let r = rules(MCPAppCSP(connectDomains: ["https://api.example.com"], resourceDomains: ["https://*.cdn.example.com", "https://x.example.org:8443"]))
        #expect(r.prefix(3).allSatisfy { $0["action"]?["type"] == "block" })
        let allows = r.dropFirst(3)
        #expect(allows.allSatisfy { $0["action"]?["type"] == "ignore-previous-rules" })
        let filters = Set(allows.compactMap { $0["trigger"]?["url-filter"] })
        #expect(filters.contains("^https://api\\.example\\.com/"))
        #expect(filters.contains("^https://[a-z0-9.-]+\\.cdn\\.example\\.com/"))
        #expect(filters.contains("^https://x\\.example\\.org:8443/"))
        #expect(filters.count == 3)
    }

    @Test func blockListNeverExemptsAnUnsafeOrigin() {
        let r = rules(MCPAppCSP(connectDomains: ["https://*", "http://example.com", "https://a.com/x"]))
        #expect(r.count == 3)  // only the three blocks
    }
}
