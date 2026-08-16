import LocalLMLabSDKCore
import SwiftUI

// "Attach a resource" / "use a prompt" — the piece of Components that turns a connected MCP
// server's resources/prompts (already listable and enable-able via MCPServerPickerView) into
// something a host app can actually use, not just see. Modeled directly on LocalLM Lab's own
// PlaygroundMCPSheets.swift (MCPResourcesSheet/MCPPromptsSheet), generalized the same way
// MCPServerPickerView already was: Core's readResource/getPrompt calls live here (same split as
// MCPServerPickerView's Save As, which calls Core's exportSummary()), but what "attach" or "use"
// actually MEANS — append to a text field, feed a session, save somewhere — is entirely up to the
// host app via the onAttach/onUse callbacks. This view has no opinion on where the result goes,
// same reason MCPServerPickerView has no persistence of its own.
//
// Only shows resources/prompts from ENABLED, connected servers (manager.core.resourcesForSession()
// / .resourceTemplatesForSession() / .promptsForSession()) — same session-scoped filtering
// LocalLM Lab's own sheets use, and the same reason MCPServerPickerView's resource toggle exists
// at all: "enabling one only makes it available for a host app to attach explicitly."

@available(macOS 26.0, *)
public struct MCPResourcesView: View {
    @ObservedObject private var manager: MCPServerManagerObservable
    private let onAttach: (MCPResourceDescriptor, MCPResourceContent) -> Void

    public init(manager: MCPServerManagerObservable, onAttach: @escaping (MCPResourceDescriptor, MCPResourceContent) -> Void) {
        self.manager = manager
        self.onAttach = onAttach
    }

    public var body: some View {
        let resources = manager.core.resourcesForSession()
        let templates = manager.core.resourceTemplatesForSession()
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if resources.isEmpty && templates.isEmpty {
                    Text("No resources available. Connect an MCP server and enable a resource in the server picker.")
                        .foregroundStyle(.secondary)
                        .padding(24)
                } else {
                    ForEach(resources, id: \.uri) { resource in
                        ResourceRow(resource: resource, read: { await manager.core.readResource(server: resource.serverID, uri: resource.uri) }, onAttach: onAttach)
                    }
                    ForEach(templates, id: \.uriTemplate) { template in
                        ResourceTemplateRow(template: template, read: { uri in await manager.core.readResource(server: template.serverID, uri: uri) }, onAttach: onAttach)
                    }
                }
            }
            .padding(16)
        }
    }
}

@available(macOS 26.0, *)
private struct ResourceRow: View {
    let resource: MCPResourceDescriptor
    let read: () async -> Result<MCPResourceContent, MCPServerError>
    let onAttach: (MCPResourceDescriptor, MCPResourceContent) -> Void

    @State private var reading = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(resource.name).font(.system(size: 13, weight: .medium))
            Text(resource.description.isEmpty ? resource.uri : resource.description)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            HStack {
                Text(resource.uri).font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                Button(reading ? "Reading…" : "Attach") {
                    Task {
                        reading = true
                        switch await read() {
                        case .success(let content):
                            error = nil
                            onAttach(resource, content)
                        case .failure(let mcpError):
                            error = mcpError.errorDescription
                        }
                        reading = false
                    }
                }
                .disabled(reading)
            }
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

@available(macOS 26.0, *)
private struct ResourceTemplateRow: View {
    let template: MCPResourceTemplateDescriptor
    let read: (String) async -> Result<MCPResourceContent, MCPServerError>
    let onAttach: (MCPResourceDescriptor, MCPResourceContent) -> Void

    @State private var values: [String: String] = [:]
    @State private var reading = false
    @State private var error: String?

    private var placeholders: [String] {
        var names: [String] = []
        var current = ""
        var inBraces = false
        for char in template.uriTemplate {
            if char == "{" { inBraces = true; current = ""; continue }
            if char == "}" { inBraces = false; names.append(current); continue }
            if inBraces { current.append(char) }
        }
        return names
    }

    private func resolvedURI() -> String {
        var uri = template.uriTemplate
        for placeholder in placeholders {
            let value = values[placeholder] ?? ""
            let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            uri = uri.replacingOccurrences(of: "{\(placeholder)}", with: encoded)
        }
        return uri
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(template.name).font(.system(size: 13, weight: .medium))
            Text(template.description.isEmpty ? template.uriTemplate : template.description)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            ForEach(placeholders, id: \.self) { placeholder in
                TextField(placeholder, text: Binding(
                    get: { values[placeholder] ?? "" },
                    set: { values[placeholder] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button(reading ? "Reading…" : "Resolve & Attach") {
                    let uri = resolvedURI()
                    Task {
                        reading = true
                        switch await read(uri) {
                        case .success(let content):
                            error = nil
                            let descriptor = MCPResourceDescriptor(
                                serverID: template.serverID, uri: uri, name: template.name,
                                description: template.description, mimeType: template.mimeType
                            )
                            onAttach(descriptor, content)
                        case .failure(let mcpError):
                            error = mcpError.errorDescription
                        }
                        reading = false
                    }
                }
                .disabled(reading)
            }
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

@available(macOS 26.0, *)
public struct MCPPromptsView: View {
    @ObservedObject private var manager: MCPServerManagerObservable
    private let onUse: (MCPPromptDescriptor, [MCPPromptMessage]) -> Void

    public init(manager: MCPServerManagerObservable, onUse: @escaping (MCPPromptDescriptor, [MCPPromptMessage]) -> Void) {
        self.manager = manager
        self.onUse = onUse
    }

    public var body: some View {
        let prompts = manager.core.promptsForSession()
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if prompts.isEmpty {
                    Text("No prompts available. Connect an MCP server and enable it in the server picker.")
                        .foregroundStyle(.secondary)
                        .padding(24)
                } else {
                    ForEach(prompts, id: \.name) { prompt in
                        PromptRow(prompt: prompt, get: { args in await manager.core.getPrompt(server: prompt.serverID, name: prompt.name, arguments: args) }, onUse: onUse)
                    }
                }
            }
            .padding(16)
        }
    }
}

@available(macOS 26.0, *)
private struct PromptRow: View {
    let prompt: MCPPromptDescriptor
    let get: ([String: String]) async -> Result<[MCPPromptMessage], MCPServerError>
    let onUse: (MCPPromptDescriptor, [MCPPromptMessage]) -> Void

    @State private var values: [String: String] = [:]
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(prompt.name).font(.system(size: 13, weight: .medium))
            if !prompt.description.isEmpty {
                Text(prompt.description).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(prompt.arguments, id: \.name) { arg in
                TextField(arg.required ? "\(arg.name) (required)" : arg.name, text: Binding(
                    get: { values[arg.name] ?? "" },
                    set: { values[arg.name] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button(loading ? "Loading…" : "Use") {
                    let missingRequired = prompt.arguments.contains {
                        $0.required && (values[$0.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
                    guard !missingRequired else {
                        error = "Fill in all required arguments."
                        return
                    }
                    Task {
                        loading = true
                        switch await get(values) {
                        case .success(let messages):
                            error = nil
                            onUse(prompt, messages)
                        case .failure(let mcpError):
                            error = mcpError.errorDescription
                        }
                        loading = false
                    }
                }
                .disabled(loading)
            }
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
