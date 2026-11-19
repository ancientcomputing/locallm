import LocalLMLabSDKCore
import SwiftUI

// MCP prompts in the message box: ready-made requests a source offers, picked by the user from a `/` menu
// or "Use a Prompt…", their arguments filled in a small form with the source's suggestions, the result put in the box to
// read, edit and send. The model never picks prompts.

/// A prompt the user picked, with its source.
struct ChatPromptChoice: Identifiable {
    let server: MCPServerID
    let sourceName: String
    let prompt: MCPPromptDescriptor
    var id: String { server.rawValue + "\u{0}" + prompt.name }
}

/// The sources' prompts matching `query` (name, title or description), by source.
@MainActor
private func promptChoices(in manager: MCPServerManager, matching query: String) -> [ChatPromptChoice] {
    let query = query.trimmingCharacters(in: .whitespaces)
    return MCPContentReader.prompts(in: manager).flatMap { source in
        source.prompts.map { ChatPromptChoice(server: source.server.id, sourceName: source.server.displayName, prompt: $0) }
    }
    .filter { choice in
        query.isEmpty || [choice.prompt.name, choice.prompt.title ?? "", choice.prompt.description, choice.sourceName]
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

/// One prompt in a list: "Source › Title" and its description.
private struct ChatPromptRow: View {
    let choice: ChatPromptChoice

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(choice.sourceName) › \(choice.prompt.title ?? choice.prompt.name)")
            if !choice.prompt.description.isEmpty {
                Text(choice.prompt.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Above the message box while it starts with `/`: the matching prompts, up to eight; a click picks one.
struct ChatPromptMatches: View {
    let manager: MCPServerManager
    let query: String
    let pick: (ChatPromptChoice) -> Void

    var body: some View {
        let matches = promptChoices(in: manager, matching: query)
        VStack(alignment: .leading, spacing: 6) {
            if matches.isEmpty {
                Text(MCPContentReader.prompts(in: manager).isEmpty ? "None of your sources offers prompts."
                     : "No prompt matches “\(query)”.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(matches.prefix(8)) { choice in
                Button { pick(choice) } label: { ChatPromptRow(choice: choice) }.buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// "Use a Prompt…": every prompt, searchable.
struct ChatPromptPicker: View {
    let manager: MCPServerManager
    @State var query: String
    let pick: (ChatPromptChoice) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Use a Prompt from a Tool Source").font(.headline)
            Text("Ready-made requests offered by the tool sources (MCP servers) you've configured. Pick one and it goes into your message.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Search", text: $query).textFieldStyle(.roundedBorder)
            List(promptChoices(in: manager, matching: query)) { choice in
                Button { pick(choice) } label: { ChatPromptRow(choice: choice) }.buttonStyle(.plain)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: 480, height: 420)
    }
}

/// A prompt's arguments: one field each, required ones marked, with the source's suggestions as the user types.
struct ChatPromptForm: View {
    let choice: ChatPromptChoice
    let manager: MCPServerManager
    let done: (MCPContentReader.PromptFill) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    @State private var suggestions: [String: [String]] = [:]
    @State private var working = false
    @State private var problem: String?
    @State private var connected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(choice.sourceName) › \(choice.prompt.title ?? choice.prompt.name)").font(.headline)
            if !choice.prompt.description.isEmpty {
                Text(choice.prompt.description).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(choice.prompt.arguments, id: \.name) { argument in
                        field(argument)
                    }
                }
            }
            if let problem { Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use") { use() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || missingRequired)
            }
        }
        .padding()
        .frame(width: 460, height: 400)
        .task(id: connected) {
            // Suggestions need the source connected: connect it, then ask for each field's.
            guard !connected else { return }
            _ = await manager.activate(choice.server)
            connected = true
        }
    }

    private func field(_ argument: MCPPromptArgument) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(argument.required ? "\(argument.name) (required)" : argument.name).font(.subheadline.weight(.semibold))
            if !argument.description.isEmpty { Text(argument.description).font(.caption).foregroundStyle(.secondary) }
            TextField(argument.name, text: Binding(get: { values[argument.name] ?? "" }, set: { values[argument.name] = $0 }))
                .textFieldStyle(.roundedBorder)
                // Again whenever any field changes: a field's suggestions can depend on the others (a department's names).
                .task(id: "\(connected)|" + values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")) {
                    if connected { await suggest(argument.name) }
                }
            let offered = (suggestions[argument.name] ?? []).filter { $0 != values[argument.name] }
            if !offered.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(offered.prefix(12), id: \.self) { value in
                            Button(value) { values[argument.name] = value }.buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    private var missingRequired: Bool {
        choice.prompt.arguments.contains { $0.required && (values[$0.name] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// The source's suggestions for `argument` as typed so far, with the other values as context; a pause first, so
    /// typing doesn't send a request per key.
    private func suggest(_ argument: String) async {
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let context = values.filter { $0.key != argument && !$0.value.isEmpty }
        suggestions[argument] = await manager.complete(server: choice.server, .prompt(name: choice.prompt.name), argument: argument,
                                                       value: values[argument] ?? "", context: context)
    }

    private func use() {
        problem = nil
        working = true
        let arguments = values.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        Task {
            let filled = await MCPContentReader.fill(prompt: choice.prompt.name, server: choice.server, arguments: arguments,
                                                     manager: manager)
            working = false
            switch filled {
            case .success(let fill): done(fill)
            case .failure(let error): problem = error.message
            }
        }
    }
}
