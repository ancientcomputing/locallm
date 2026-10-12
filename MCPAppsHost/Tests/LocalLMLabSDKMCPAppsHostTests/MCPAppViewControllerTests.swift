import AppKit
import Foundation
import LocalLMLabSDKCore
import Testing
import WebKit

import LocalLMLabSDKMCPAppsHost

// Loads a REAL WKWebView with a hostile probe widget and checks, from the host side, what the
// containment layers let through. The widget reports over the normal bridge (tools/call
// "report") so the test needs no JS-evaluation hooks.

@MainActor
private final class Recorder {
    var calls: [(name: String, arguments: [String: MCPValue])] = []
    var audit: [MCPAppsAuditEvent] = []
    var openedLinks: [URL] = []
}

@MainActor
private struct Backend: MCPAppsBackend {
    let recorder: Recorder
    func callTool(name: String, arguments: [String: MCPValue]) async -> Result<MCPToolResult, MCPServerError> {
        recorder.calls.append((name, arguments))
        return .success(MCPToolResult(text: "ok", structuredContent: .object(["echo": .string(name)])))
    }
    func readResource(uri: String) async -> Result<MCPResourceContent, MCPServerError> { .failure(.notConnected) }
}

private func tool(_ name: String) -> MCPToolDescriptor {
    MCPToolDescriptor(serverID: MCPServerID(rawValue: "https://example.invalid/mcp"), name: name, description: "", rawSchema: Data("{}".utf8), estimatedTokens: 0)
}

/// A widget that speaks the MCP Apps handshake through `window.parent.postMessage` (as the
/// bundled ext-apps client does) and then probes its own containment.
private let probeWidget = #"""
<!doctype html><html><body><script>
var id = 100;
function rpc(method, params) { window.parent.postMessage({jsonrpc:'2.0', id: ++id, method: method, params: params||{}}, '*'); }
function note(method, params) { window.parent.postMessage({jsonrpc:'2.0', method: method, params: params||{}}, '*'); }
function report(k, v) { rpc('tools/call', {name:'report', arguments:{key:k, value:String(v)}}); }
var pending = {};
window.addEventListener('message', function (e) {
  var m = e.data;
  if (m && m.id === 1 && m.result) {
    note('ui/notifications/initialized');  // the bridge refuses requests until this is sent
    report('protocolVersion', m.result.protocolVersion);
    report('csp-connect', JSON.stringify(m.result.hostCapabilities.sandbox.csp.connectDomains));
    runProbes();
  }
  if (m && m.method === 'ui/notifications/tool-input') report('tool-input', JSON.stringify(m.params.arguments));
  if (m && m.method === 'ui/notifications/tool-result') report('tool-result', JSON.stringify(m.params.structuredContent));
});
function runProbes() {
  fetch('https://example.com/').then(function () { report('fetch', 'REACHED'); }, function () { report('fetch', 'blocked'); });
  try { var ws = new WebSocket('wss://example.com/'); ws.onopen = function () { report('ws', 'REACHED'); }; ws.onerror = function () { report('ws', 'blocked'); }; } catch (x) { report('ws', 'blocked'); }
  var img = new Image(); img.onload = function () { report('img', 'REACHED'); }; img.onerror = function () { report('img', 'blocked'); }; img.src = 'https://example.com/x.png';
  try { report('parent-dom', window.parent.document.body ? 'READABLE' : 'none'); } catch (x) { report('parent-dom', 'blocked'); }
  try { report('storage', typeof localStorage === 'undefined' ? 'none' : (localStorage.setItem('a','b'), 'WRITABLE')); } catch (x) { report('storage', 'blocked'); }
  try { window.webkit.messageHandlers.mcpBridge.postMessage(JSON.stringify({jsonrpc:'2.0', id: 900, method:'tools/call', params:{name:'report', arguments:{key:'direct-handler', value:'REACHED'}}})); } catch (x) { report('direct-handler', 'no-handler'); }
  try { window.top.location.href = 'https://example.com/'; } catch (x) {}
  rpc('ui/open-link', {url:'https://example.com'});
  rpc('ui/message', {role:'user', content:{type:'text', text:'hi model'}});
  setTimeout(function () { report('done', '1'); }, 800);
}
window.parent.postMessage({jsonrpc:'2.0', id: 1, method:'ui/initialize', params:{protocolVersion:'2026-01-26', clientInfo:{name:'probe', version:'1'}, appCapabilities:{}}}, '*');
</script></body></html>
"""#

/// A widget that reports the host context it is given and asks for fullscreen when told to.
private let contextWidget = #"""
<!doctype html><html><body><script>
var id = 100;
function rpc(method, params) { window.parent.postMessage({jsonrpc:'2.0', id: ++id, method: method, params: params||{}}, '*'); }
function note(method, params) { window.parent.postMessage({jsonrpc:'2.0', method: method, params: params||{}}, '*'); }
function report(k, v) { rpc('tools/call', {name:'report', arguments:{key:k, value:String(v)}}); }
window.addEventListener('message', function (e) {
  var m = e.data;
  if (m && m.id === 1 && m.result) {
    note('ui/notifications/initialized');
    var c = m.result.hostContext;
    report('theme0', c.theme);
    report('modes', JSON.stringify(c.availableDisplayModes));
    rpc('ui/request-display-mode', {mode: 'fullscreen'});
  }
  if (m && m.id > 100 && m.result && m.result.mode) report('mode-reply', m.result.mode);
  if (m && m.method === 'ui/notifications/host-context-changed') {
    var p = m.params;
    if (p.displayMode) report('mode-change', p.displayMode);
    if (p.containerDimensions) report('dims', p.containerDimensions.width + 'x' + p.containerDimensions.height);
    if (p.theme) report('theme-change', p.theme);
  }
});
window.parent.postMessage({jsonrpc:'2.0', id: 1, method:'ui/initialize', params:{protocolVersion:'2026-01-26', clientInfo:{name:'ctx', version:'1'}, appCapabilities:{availableDisplayModes:['inline','fullscreen']}}}, '*');
</script></body></html>
"""#

@MainActor
@Suite(.serialized) struct MCPAppViewControllerTests {
    private func makeController(recorder: Recorder, html: String = probeWidget, meta: MCPValue? = nil, sandbox: MCPAppsSandboxPolicy = .closed, modes: [String] = ["inline"]) throws -> MCPAppViewController {
        _ = NSApplication.shared
        let content = MCPResourceContent(uri: "ui://probe/w", mimeType: "text/html;profile=mcp-app", text: html, meta: meta)
        let resource = try MCPAppResource(content: content, requestedURI: "ui://probe/w")
        return MCPAppViewController(
            resource: resource, tools: [tool("report")], backend: Backend(recorder: recorder),
            configuration: MCPAppsBridgeConfiguration(hostName: "TestHost", hostVersion: "1", teardownTimeout: .milliseconds(200)),
            sandboxPolicy: sandbox,
            actions: MCPAppsHostActions(openLink: { recorder.openedLinks.append($0) }),
            supportedDisplayModes: modes,
            audit: { recorder.audit.append($0) })
    }

    private func waitForReport(_ recorder: Recorder, key: String = "done", timeout: Duration = .seconds(15)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if recorder.calls.contains(where: { $0.arguments["key"] == .string(key) }) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private func reports(_ recorder: Recorder) -> [String: String] {
        var out: [String: String] = [:]
        for call in recorder.calls where call.name == "report" {
            if case .string(let k)? = call.arguments["key"], case .string(let v)? = call.arguments["value"] { out[k] = v }
        }
        return out
    }

    @Test func aHostileWidgetIsContainedAndTheBridgeWorksEndToEnd() async throws {
        let recorder = Recorder()
        let controller = try makeController(recorder: recorder)
        controller.bridge.deliverToolInput(arguments: ["startDate": .string("today")])
        controller.bridge.deliverToolResult(MCPToolResult(text: "t", structuredContent: .object(["totalCount": .number(3)])))
        await controller.load()
        let finished = await waitForReport(recorder)
        let r = reports(recorder)
        await controller.close()

        #expect(finished, "widget never finished its probes; got \(r)")
        // The bridge works through the sandboxed iframe + relay.
        #expect(r["protocolVersion"] == "2026-01-26")
        #expect(r["csp-connect"] == "[]")
        #expect(r["tool-input"] == #"{"startDate":"today"}"#)
        #expect(r["tool-result"]?.contains("\"totalCount\":3") == true)
        // Network is closed at every layer.
        #expect(r["fetch"] == "blocked")
        #expect(r["ws"] == "blocked")
        #expect(r["img"] == "blocked")
        // The iframe is an opaque origin: no parent DOM, no storage.
        #expect(r["parent-dom"] == "blocked")
        #expect(r["storage"] == "blocked")
        // A direct call to the native handler from the widget frame is dropped.
        #expect(r["direct-handler"] == nil)
        // Denied by default: link and message never reached the host actions.
        #expect(recorder.openedLinks.isEmpty)
        #expect(recorder.audit.contains { $0.method == "ui/open-link" && $0.outcome == .denied })
        #expect(recorder.audit.contains { $0.method == "ui/message" && $0.outcome == .denied })
    }

    @Test func closeTearsDownAndStopsAcceptingMessages() async throws {
        let recorder = Recorder()
        let controller = try makeController(recorder: recorder)
        await controller.load()
        _ = await waitForReport(recorder)
        await controller.close()
        #expect(controller.bridge.state == .tornDown)
    }

    @Test func fullscreenIsGrantedNotifiedAndCanBeExited() async throws {
        let recorder = Recorder()
        let controller = try makeController(recorder: recorder, html: contextWidget, modes: ["inline", "fullscreen"])
        await controller.load()
        #expect(await waitForReport(recorder, key: "mode-change"))
        var r = reports(recorder)
        #expect(r["modes"] == #"["inline","fullscreen"]"#)
        #expect(r["mode-reply"] == "fullscreen")
        #expect(r["mode-change"] == "fullscreen")
        #expect(controller.displayMode == "fullscreen")
        // The host leaves fullscreen; the widget is told.
        recorder.calls.removeAll()
        controller.exitFullscreen()
        #expect(await waitForReport(recorder, key: "mode-change"))
        r = reports(recorder)
        #expect(r["mode-change"] == "inline")
        #expect(controller.displayMode == "inline")
        await controller.close()
    }

    @Test func widgetOnlySeesFullscreenWhenTheHostSupportsIt() async throws {
        let recorder = Recorder()
        let controller = try makeController(recorder: recorder, html: contextWidget)  // inline only
        await controller.load()
        #expect(await waitForReport(recorder, key: "mode-reply"))
        let r = reports(recorder)
        #expect(r["modes"] == #"["inline"]"#)
        #expect(r["mode-reply"] == "inline")  // the request is politely refused
        #expect(controller.displayMode == "inline")
        await controller.close()
    }

    @Test func containerSizeAndThemeReachTheWidget() async throws {
        let recorder = Recorder()
        let controller = try makeController(recorder: recorder, html: contextWidget)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.webView
        window.orderFrontRegardless()
        await controller.load()
        #expect(await waitForReport(recorder, key: "theme0"))
        #expect(["light", "dark"].contains(reports(recorder)["theme0"] ?? ""))
        // Resize the container after the widget is up: it must hear about the new size.
        recorder.calls.removeAll()
        window.setContentSize(NSSize(width: 700, height: 520))
        #expect(await waitForReport(recorder, key: "dims"))
        #expect(reports(recorder)["dims"] == "700x520")
        // Switch appearance: the widget must hear about the theme.
        recorder.calls.removeAll()
        window.appearance = NSAppearance(named: .darkAqua)
        controller.webView.appearance = NSAppearance(named: .darkAqua)
        #expect(await waitForReport(recorder, key: "theme-change"))
        #expect(reports(recorder)["theme-change"] == "dark")
        await controller.close()
        window.orderOut(nil)
    }
}
