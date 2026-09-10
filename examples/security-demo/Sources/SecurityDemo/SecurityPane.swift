import SwiftUI

// The "Security panel" — the same shape LocalLM Lab ships, trimmed to what this demo exercises.
// Editing anything here changes the next Run: the level re-filters the tool list, the toggles
// add or remove the confirmation authorizer.

struct SecurityPane: View {
    @Bindable var model: AppModel

    private var security: DemoSecurity { model.security }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                connectorSection
                mcpSection
                Divider()
                footnotes
            }
            .padding(20)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Security").font(.title2.bold())
            Text("A model with tools can act, not just answer. The level decides which tools it "
                 + "sees; “Confirm each” decides whether a call runs or asks you first.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var connectorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connectors").font(.headline)
            HStack(alignment: .firstTextBaseline) {
                Text("📅 Calendar").frame(width: 110, alignment: .leading)
                Picker("", selection: Binding(
                    get: { security.calendarLevel },
                    set: { security.calendarLevel = $0 })) {
                    ForEach(ConnectorLevel.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().frame(width: 130)
            }
            Toggle("Confirm each change", isOn: Binding(
                get: { security.calendarConfirm },
                set: { security.calendarConfirm = $0 }))
                .disabled(security.calendarLevel == .readOnly)
            Text(levelHint).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var levelHint: String {
        switch security.calendarLevel {
        case .readOnly: return "Model sees GetUpcomingEvents only (plus the always-on Clock)."
        case .changes:  return "Model sees read + Add + Update. Delete is filtered out."
        case .full:     return "Model sees every Calendar tool, including Delete."
        }
    }

    private var mcpSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MCP servers").font(.headline)
            Text("An MCP server's tools are written by its operator. Confirming each call is wise "
                 + "for one you don't fully trust.")
                .font(.caption).foregroundStyle(.secondary)
            Text("todoist").font(.body.weight(.medium))
            Toggle("Confirm each tool call", isOn: Binding(
                get: { security.todoistConfirm },
                set: { security.todoistConfirm = $0 }))
            Text("Tools: find-tasks, add-tasks, complete-tasks — all rated .mutate. MCP tools "
                 + "are opaque, so there's no level split (and even find-tasks asks); only this "
                 + "toggle. LocalLM Lab's \u{201C}don't ask again\u{201D} is how you'd quiet the safe ones.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var footnotes: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("With every toggle off, `makeSession` gets no authorizer — it runs like a bare "
                  + "LanguageModelSession.", systemImage: "info.circle")
            Label("A denied call comes back to the model as the tool result; the turn continues.",
                  systemImage: "arrow.uturn.left")
            Label("No answer within ~120s auto-denies.", systemImage: "clock")
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}
