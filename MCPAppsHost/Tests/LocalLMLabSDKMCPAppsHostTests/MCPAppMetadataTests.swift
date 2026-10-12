import Foundation
import LocalLMLabSDKCore
import Testing

import LocalLMLabSDKMCPAppsHost

// Public API only (no @testable), like Components' tests.

private func tool(_ name: String, meta: MCPValue?) -> MCPToolDescriptor {
    MCPToolDescriptor(
        serverID: MCPServerID(rawValue: "https://example.invalid/mcp"), name: name, description: "",
        rawSchema: Data("{}".utf8), estimatedTokens: 0, meta: meta)
}

@Suite struct MCPAppMetadataTests {
    // Tool-side parsing (resource URI, visibility) is tested in Core: MCPAppLinkTests.

    @Test func resourceInfoParsesTodoistShapedEmptyCSP() {
        let meta: MCPValue = .object([
            "ui": .object([
                "csp": .object(["connectDomains": .array([]), "resourceDomains": .array([])]),
                "prefersBorder": .bool(true),
            ]),
            "openai/widgetDomain": .string("https://ai.todoist.net"),
        ])
        let info = MCPAppResourceInfo(meta: meta)
        #expect(info.csp.isEmpty)
        #expect(info.permissions.isEmpty)
        #expect(info.prefersBorder == true)
    }

    @Test func resourceInfoParsesDomainsAndPermissions() {
        let meta: MCPValue = .object(["ui": .object([
            "csp": .object([
                "connectDomains": .array([.string("https://api.example.com")]),
                "resourceDomains": .array([.string("https://cdn.example.com"), .number(3)]),
            ]),
            "permissions": .object(["camera": .object([:]), "microphone": .bool(false)]),
            "domain": .string("abc.example"),
        ])])
        let info = MCPAppResourceInfo(meta: meta)
        #expect(info.csp.connectDomains == ["https://api.example.com"])
        #expect(info.csp.resourceDomains == ["https://cdn.example.com"])  // non-strings dropped
        #expect(info.permissions == MCPAppPermissions(camera: true))
        #expect(info.domain == "abc.example")
    }

    @Test func malformedMetaYieldsMostRestrictiveInfo() {
        let info = MCPAppResourceInfo(meta: .string("nope"))
        #expect(info == MCPAppResourceInfo())
        #expect(MCPAppResourceInfo(meta: nil) == MCPAppResourceInfo())
    }

    @Test func resourceWrapsHTMLAndHashesIt() throws {
        let content = MCPResourceContent(
            uri: "ui://x/a", mimeType: "text/html;profile=mcp-app", text: "<html>hi</html>",
            meta: .object(["ui": .object(["prefersBorder": .bool(true)])]))
        let resource = try MCPAppResource(content: content, requestedURI: "ui://x/a")
        #expect(resource.html == "<html>hi</html>")
        #expect(resource.info.prefersBorder == true)
        // sha256("<html>hi</html>")
        #expect(resource.sha256.count == 64)
        #expect(resource.sha256 == (try MCPAppResource(content: content, requestedURI: "ui://x/a")).sha256)
        let other = MCPResourceContent(uri: "ui://x/a", mimeType: "text/html;profile=mcp-app", text: "<html>ho</html>")
        #expect(try MCPAppResource(content: other, requestedURI: "ui://x/a").sha256 != resource.sha256)
    }

    @Test func resourceKnownHashVector() throws {
        // SHA-256("abc"), a standard test vector.
        let content = MCPResourceContent(uri: "ui://x/a", mimeType: "text/html;profile=mcp-app", text: "abc")
        #expect(try MCPAppResource(content: content, requestedURI: "ui://x/a").sha256
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func resourceUsesRequestedURINotEchoedOne() throws {
        let content = MCPResourceContent(uri: "ui://other/thing", mimeType: "text/html;profile=mcp-app", text: "x")
        #expect(try MCPAppResource(content: content, requestedURI: "ui://x/a").uri == "ui://x/a")
    }

    @Test func resourceContentMetaWinsOverListedMeta() throws {
        let read: MCPValue = .object(["ui": .object(["prefersBorder": .bool(false)])])
        let listed: MCPValue = .object(["ui": .object(["prefersBorder": .bool(true)])])
        let content = MCPResourceContent(uri: "ui://x/a", mimeType: "text/html;profile=mcp-app", text: "x", meta: read)
        #expect(try MCPAppResource(content: content, requestedURI: "ui://x/a", listedMeta: listed).info.prefersBorder == false)
        let bare = MCPResourceContent(uri: "ui://x/a", mimeType: "text/html;profile=mcp-app", text: "x")
        #expect(try MCPAppResource(content: bare, requestedURI: "ui://x/a", listedMeta: listed).info.prefersBorder == true)
    }

    @Test func resourceRejectsBadInputs() {
        let good = MCPResourceContent(uri: "ui://x/a", mimeType: "text/html;profile=mcp-app", text: "x")
        #expect(throws: MCPAppResourceError.notAUIResource("https://x/a")) {
            try MCPAppResource(content: good, requestedURI: "https://x/a")
        }
        let plainHTML = MCPResourceContent(uri: "ui://x/a", mimeType: "text/html", text: "x")
        #expect(throws: MCPAppResourceError.wrongMimeType("text/html")) {
            try MCPAppResource(content: plainHTML, requestedURI: "ui://x/a")
        }
        let empty = MCPResourceContent(uri: "ui://x/a", mimeType: "text/html;profile=mcp-app")
        #expect(throws: MCPAppResourceError.noBody) { try MCPAppResource(content: empty, requestedURI: "ui://x/a") }
        let badBlob = MCPResourceContent(uri: "ui://x/a", mimeType: "text/html;profile=mcp-app", blob: "!!!not base64!!!")
        #expect(throws: MCPAppResourceError.invalidBase64) { try MCPAppResource(content: badBlob, requestedURI: "ui://x/a") }
    }

    @Test func resourceAcceptsBase64BlobAndMimeWhitespace() throws {
        let blob = Data("<b>hi</b>".utf8).base64EncodedString()
        let content = MCPResourceContent(uri: "ui://x/a", mimeType: "Text/HTML; profile=mcp-app", blob: blob)
        #expect(try MCPAppResource(content: content, requestedURI: "ui://x/a").html == "<b>hi</b>")
    }
}
