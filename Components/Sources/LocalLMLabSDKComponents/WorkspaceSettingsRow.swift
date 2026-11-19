import LocalLMLabSDKCore
import SwiftUI

/// The three access levels as a picker, worded as the user reads them. Used by the Settings row
/// and the Add workspace card, so both apps say the same thing.
public struct WorkspaceAccessPicker: View {
    @Binding var access: Workspace.Access

    public init(access: Binding<Workspace.Access>) {
        _access = access
    }

    public var body: some View {
        Picker("Access", selection: $access) {
            ForEach(Workspace.Access.allCases, id: \.self) { level in
                Text(Self.title(level)).tag(level)
            }
        }
        .help("Read-only: the assistant never changes files here. Ask before changes: you're asked before each change. Read and write: it changes, replaces and deletes files without asking; a deleted file goes to the Trash, and a replaced file's old version is kept in the chat's folder.")
    }

    public static func title(_ access: Workspace.Access) -> String {
        switch access {
        case .readOnly: "Read-only"
        case .askBeforeChanges: "Ask before changes"
        case .readWrite: "Read and write"
        @unknown default: access.label
        }
    }
}

/// What a workspace row asks its host to do. Each app keeps its own `SavedWorkspaces` store and refreshes its
/// tools after a change.
public struct WorkspaceSettingsActions {
    /// Returns why the name can't be used, or nil when it was renamed.
    public var rename: (String) -> String?
    public var setDescription: (String) -> Void
    public var setAccess: (Workspace.Access) -> Void
    public var setDefault: (Bool) -> Void
    public var showInFinder: () -> Void
    public var remove: () -> Void

    public init(rename: @escaping (String) -> String?, setDescription: @escaping (String) -> Void,
                setAccess: @escaping (Workspace.Access) -> Void, setDefault: @escaping (Bool) -> Void,
                showInFinder: @escaping () -> Void, remove: @escaping () -> Void) {
        self.rename = rename
        self.setDescription = setDescription
        self.setAccess = setAccess
        self.setDefault = setDefault
        self.showInFinder = showInFinder
        self.remove = remove
    }
}

/// One of the user's workspaces in Settings: its name, folder, Default folder, access level, description, and Show in
/// Finder and Remove. Shared so every app shows the access level (ChatAgain had none).
///
/// Default folder and the access level apply when changed. An edited name or description shows Apply and Revert:
/// before, it saved only on Return or when Settings closed, with nothing saying whether it had.
///
/// What the name, Default folder and Read and write mean is said in a line under the row, not only in tooltips:
/// "What does Default mean?" (from ChatAgain's usability review). One secondary line, and at most one
/// orange one.
public struct WorkspaceSettingsRow: View {
    let workspace: SavedWorkspace
    let isDefault: Bool
    let isAvailable: Bool
    let actions: WorkspaceSettingsActions
    @State private var name = ""
    @State private var description = ""
    @State private var nameProblem: String?
    @State private var confirmingRemove = false

    public init(workspace: SavedWorkspace, isDefault: Bool, isAvailable: Bool, actions: WorkspaceSettingsActions) {
        self.workspace = workspace
        self.isDefault = isDefault
        self.isAvailable = isAvailable
        self.actions = actions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.weight(.medium))
                    .frame(maxWidth: 180)
                    .onSubmit { apply() }
                    .help("The short name the assistant uses for this folder. Letters, digits, - _ or .")
                Text(SavedWorkspaces.abbreviated(workspace.path)).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                if !isAvailable {
                    Text("Unavailable").font(.caption).foregroundStyle(.orange)
                        .help("The folder can't be reached (moved, deleted, or on a disk that isn't connected). It isn't offered until it's back.")
                }
                Spacer()
                Toggle("Default folder", isOn: Binding(get: { isDefault }, set: { actions.setDefault($0) }))
                    .toggleStyle(.checkbox)
                    .help("A file you name without saying where is looked for here, like a project's working folder. New files still go to the chat's own folder unless you name a workspace.")
                WorkspaceAccessPicker(access: Binding(get: { workspace.access }, set: { actions.setAccess($0) }))
                    .labelsHidden()
                    .fixedSize()
                Button { actions.showInFinder() } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless).help("Show in Finder").disabled(!isAvailable)
                Button { confirmingRemove = true } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless).help("Remove this workspace (the folder is left alone)")
            }
            LabeledContent("Description") {
                TextField("e.g. Swift source, docs and examples", text: $description)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { apply() }
            }
            if let warning { Text(warning).font(.caption).foregroundStyle(.orange) }
            HStack {
                // Inline rather than a dialog: a dialog can close the popover an app shows this row in.
                Text(confirmingRemove ? "Remove \(workspace.id)? The folder stays; its name, description and access are forgotten." : caption)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if confirmingRemove {
                    Button("Cancel") { confirmingRemove = false }
                    Button("Remove", role: .destructive) { confirmingRemove = false; actions.remove() }
                } else if isEdited {
                    Button("Revert", action: revert)
                    Button("Apply", action: apply)
                        .buttonStyle(.borderedProminent)
                        .disabled(trimmedDescription.isEmpty)
                }
            }
        }
        .onAppear(perform: revert)
    }

    /// The secondary line: what's pending, else what the name, Default folder and Read and write mean here.
    private var caption: String {
        if isEdited { return trimmedDescription.isEmpty ? "Add a description to apply." : "Apply to save the name and description." }
        var parts = ["Say \u{201C}\(workspace.id)\u{201D} in a message to mean this folder."]
        if isDefault { parts.append("As the default folder, it's where a file you name without saying where is looked for.") }
        if workspace.access == .readWrite { parts.append("Read and write: files change without asking; deleted ones go to the Trash.") }
        return parts.joined(separator: " ")
    }

    /// The orange line: a name that can't be used, else a missing description.
    private var warning: String? {
        if let nameProblem { return nameProblem }
        return trimmedDescription.isEmpty ? "Say what's in this folder so the assistant knows when to look here." : nil
    }

    private var trimmedDescription: String { description.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The description the field shows: empty when the saved one is only the folder's path (`SavedWorkspaces.add`'s
    /// stand-in), which tells the assistant little and repeats the path beside the name.
    private var savedDescription: String {
        let saved = workspace.description
        return saved == workspace.path || saved == SavedWorkspaces.abbreviated(workspace.path) ? "" : saved
    }

    /// The name or description differs from what's saved.
    private var isEdited: Bool { name != workspace.id || trimmedDescription != savedDescription }

    private func apply() {
        if !trimmedDescription.isEmpty, trimmedDescription != savedDescription { actions.setDescription(trimmedDescription) }
        // A name that can't be used stays in the field with the reason, so it can be fixed or reverted.
        nameProblem = name != workspace.id ? actions.rename(name) : nil
    }

    private func revert() {
        name = workspace.id
        description = savedDescription
        nameProblem = nil
    }
}
