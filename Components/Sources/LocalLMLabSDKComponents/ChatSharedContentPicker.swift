import LocalLMLabSDKCore
import SwiftUI

/// "Attach Shared Content…" in the message box's paperclip menu: content the user's MCP servers share, by
/// server, searchable; an address with parts to fill in asks for them. The chosen content is read and saved as a
/// file, then attached like any file: what was read when the message is sent is what the model sees.
struct ChatSharedContentPicker: View {
    let manager: MCPServerManager
    /// The saved file and its source's name.
    let attach: (URL, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var filling: (server: MCPServerID, template: MCPResourceTemplateDescriptor)?
    @State private var values: [String: String] = [:]
    @State private var reading = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Attach from a Tool Source").font(.headline)
            Text("Files and content shared by the tool sources (MCP servers) you've configured. Pick one to attach it to your message.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let filling {
                form(filling.server, filling.template)
            } else {
                TextField("Search", text: $search).textFieldStyle(.roundedBorder)
                list
            }
            if let problem { Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            HStack {
                if reading { ProgressView().controlSize(.small); Text("Reading…").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { if filling != nil { filling = nil } else { dismiss() } }.keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: 480, height: 440)
    }

    private var list: some View {
        List {
            ForEach(MCPContentReader.attachable(in: manager), id: \.server.id) { source in
                Section(source.server.displayName) {
                    ForEach(source.resources.filter(matches), id: \.uri) { resource in
                        row(resource.title ?? resource.name, about: resource.description) {
                            take(resource.uri, server: source.server.id, name: resource.title ?? resource.name)
                        }
                    }
                    ForEach(source.templates.filter { matches($0.title ?? $0.name, $0.description, $0.uriTemplate) }, id: \.uriTemplate) { template in
                        row((template.title ?? template.name) + "…", about: template.description) {
                            values = [:]
                            filling = (source.server.id, template)
                        }
                    }
                }
            }
        }
    }

    private func row(_ title: String, about: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if !about.isEmpty { Text(about).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(reading)
    }

    private func form(_ server: MCPServerID, _ template: MCPResourceTemplateDescriptor) -> some View {
        let parts = MCPContentReader.parts(of: template.uriTemplate)
        return VStack(alignment: .leading, spacing: 8) {
            Text(template.title ?? template.name).font(.subheadline.weight(.semibold))
            if !template.description.isEmpty { Text(template.description).font(.caption).foregroundStyle(.secondary) }
            ForEach(parts, id: \.self) { part in
                TextField(part, text: Binding(get: { values[part] ?? "" }, set: { values[part] = $0 }))
                    .textFieldStyle(.roundedBorder)
            }
            Button("Attach") {
                take(MCPContentReader.fill(template.uriTemplate, with: values), server: server, name: nil)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(reading || parts.contains { (values[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty })
            Spacer()
        }
    }

    private func matches(_ resource: MCPResourceDescriptor) -> Bool {
        matches(resource.title ?? resource.name, resource.description, resource.uri)
    }

    private func matches(_ fields: String...) -> Bool {
        let query = search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty || fields.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private func take(_ uri: String, server: MCPServerID, name: String?) {
        problem = nil
        reading = true
        Task {
            let saved = await MCPContentReader.saveForAttaching(uri, server: server, manager: manager, name: name)
            reading = false
            switch saved {
            case .success(let file):
                attach(file, manager.servers[server]?.displayName ?? "")
                dismiss()
            case .failure(let error):
                problem = error.message
            }
        }
    }
}
