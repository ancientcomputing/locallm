import AppKit
import LocalLMLabSDKCore
import SwiftUI

// The single-process SwiftUI implementation of `MCPElicitationHandler`
// (docs/mcp-client-spec-upgrade.md §7.2). Mirrors `ToolConfirmationPresenter`:
// a `@MainActor` `ObservableObject` the host installs once and renders with
// `.mcpElicitationSheet(_:)`, then hands to Core:
//
//   @StateObject private var elicitation = MCPElicitationPresenter()
//   ...
//   .mcpElicitationSheet(elicitation)                       // near the root
//   ...
//   let manager = MCPServerManager(
//       handlers: MCPClientHandlers(elicitation: elicitation))
//
// With no presenter registered, Core never advertises the `elicitation`
// capability and a conformant server never asks — so this is purely opt-in.

/// An `MCPElicitationHandler` that queues server elicitation requests for a
/// SwiftUI sheet.
@available(macOS 26.0, *)
@MainActor
public final class MCPElicitationPresenter: ObservableObject, MCPElicitationHandler {
    /// Requests awaiting a decision, oldest first. The sheet shows `first`.
    @Published public private(set) var pending: [MCPElicitationPrompt] = []

    private let fallbackTimeout: Duration

    /// - Parameter fallbackTimeout: an unanswered prompt auto-cancels after
    ///   this long (Core's HTTP resource timeout is the harder backstop).
    public init(fallbackTimeout: Duration = .seconds(120)) {
        self.fallbackTimeout = fallbackTimeout
    }

    // MARK: MCPElicitationHandler

    public func handleElicitation(_ request: MCPElicitationRequest) async -> MCPElicitationResponse {
        let id = UUID()
        return await withCheckedContinuation { (continuation: CheckedContinuation<MCPElicitationResponse, Never>) in
            let gate = ResponseGate(continuation)
            pending.append(MCPElicitationPrompt(id: id, request: request, respond: { gate.resume($0) }))
            Task { [weak self, fallbackTimeout] in
                try? await Task.sleep(for: fallbackTimeout)
                self?.resolve(id, .cancel)
            }
        }
    }

    // MARK: Host-facing

    /// Resolve a pending prompt — the sheet's buttons call this. No-op for an
    /// unknown id (already resolved or timed out).
    public func resolve(_ id: MCPElicitationPrompt.ID, _ response: MCPElicitationResponse) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending.remove(at: index).respond(response)
    }

    private final class ResponseGate: @unchecked Sendable {
        private var continuation: CheckedContinuation<MCPElicitationResponse, Never>?
        init(_ continuation: CheckedContinuation<MCPElicitationResponse, Never>) { self.continuation = continuation }
        func resume(_ response: MCPElicitationResponse) {
            continuation?.resume(returning: response)
            continuation = nil
        }
    }
}

/// One server elicitation request awaiting a decision.
@available(macOS 26.0, *)
public struct MCPElicitationPrompt: Identifiable, Sendable {
    public let id: UUID
    public let request: MCPElicitationRequest
    let respond: @Sendable (MCPElicitationResponse) -> Void
}

// MARK: - SwiftUI

@available(macOS 26.0, *)
public extension View {
    /// Presents a sheet for each server elicitation request routed through
    /// `presenter`. Attach once, near the root.
    func mcpElicitationSheet(_ presenter: MCPElicitationPresenter) -> some View {
        modifier(MCPElicitationSheetModifier(presenter: presenter))
    }
}

@available(macOS 26.0, *)
private struct MCPElicitationSheetModifier: ViewModifier {
    @ObservedObject var presenter: MCPElicitationPresenter

    func body(content: Content) -> some View {
        let active = Binding<MCPElicitationPrompt?>(
            get: { presenter.pending.first },
            // Dismissing without choosing (Esc, drag-down) cancels.
            set: { if $0 == nil, let current = presenter.pending.first {
                presenter.resolve(current.id, .cancel)
            } })
        return content.sheet(item: active) { prompt in
            MCPElicitationView(request: prompt.request) { response in
                presenter.resolve(prompt.id, response)
            }
        }
    }
}

@available(macOS 26.0, *)
struct MCPElicitationView: View {
    let request: MCPElicitationRequest
    let decide: (MCPElicitationResponse) -> Void

    @State private var values: [String: MCPValue] = [:]
    /// Flipped on the first Submit attempt so per-field errors only appear
    /// after the user has tried, not while they are still typing.
    @State private var didAttemptSubmit = false
    /// URL mode: set once the user has opened the link, switching the sheet
    /// to a "waiting for the browser" state.
    @State private var didOpenURL = false

    private var serverLabel: String { request.serverName ?? request.serverURL?.host ?? "An MCP server" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            if !request.message.isEmpty {
                Text(request.message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let url = request.url {
                urlModeBody(url)
            } else {
                formBody
            }
        }
        .padding(20)
        .frame(minWidth: 400, idealWidth: 440, maxWidth: 460)
        .onAppear(perform: seedDefaults)
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: request.url == nil ? "list.bullet.rectangle" : "arrow.up.forward.app")
                .font(.title3).foregroundStyle(.tint).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(serverLabel) is asking for input").font(.headline)
                Label {
                    Text(secondaryIdentityLine)
                } icon: {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                }
                .font(.caption).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
            }
            Spacer(minLength: 0)
        }
    }

    private var secondaryIdentityLine: String {
        var parts = ["MCP server"]
        if let host = request.serverURL?.host { parts.append(host) }
        let app = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        parts.append(app.map { "not \($0)" } ?? "not this app")
        return parts.joined(separator: " · ")
    }

    // MARK: URL mode

    @ViewBuilder
    private func urlModeBody(_ url: URL) -> some View {
        if didOpenURL {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for the browser…").font(.caption).foregroundStyle(.secondary)
            }
            Text(url.absoluteString)
                .font(.caption.monospaced()).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
        } else {
            Text("Continue in your browser, then come back and confirm.")
                .font(.caption).foregroundStyle(.secondary)
        }

        HStack {
            Button("Decline") { decide(.decline) }
            Spacer()
            Button("Cancel", role: .cancel) { decide(.cancel) }.keyboardShortcut(.cancelAction)
            if didOpenURL {
                Button("I'm done") { decide(.accept([:])) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            } else {
                Button {
                    NSWorkspace.shared.open(url)
                    didOpenURL = true
                } label: {
                    Label("Open in browser", systemImage: "arrow.up.forward.app")
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: Form mode

    @ViewBuilder
    private var formBody: some View {
        Form {
            ForEach(request.fields, id: \.name) { field in
                Section { fieldRow(field) }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 120, maxHeight: 360)
        .scrollBounceBehavior(.basedOnSize)

        HStack {
            Button("Decline") { decide(.decline) }
                .help("Tell the server you won't provide this information.")
            Spacer()
            Button("Cancel", role: .cancel) { decide(.cancel) }
                .keyboardShortcut(.cancelAction)
                .help("Dismiss without answering.")
            Button("Submit") {
                didAttemptSubmit = true
                if validationErrors.isEmpty { decide(.accept(cleanedValues)) }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(didAttemptSubmit && !validationErrors.isEmpty)
        }
    }

    @ViewBuilder
    private func fieldRow(_ field: MCPElicitationField) -> some View {
        let label = displayLabel(for: field)
        VStack(alignment: .leading, spacing: 6) {
            switch field.kind {
            case .boolean:
                Toggle(labelWithMarker(label, field), isOn: boolBinding(field.name))

            case .enumeration(let options, let titles, let multiSelect):
                Text(labelWithMarker(label, field)).font(.callout)
                if multiSelect {
                    ForEach(Array(options.enumerated()), id: \.offset) { i, option in
                        Toggle(titles?[safe: i] ?? humanize(option), isOn: multiSelectBinding(field.name, option))
                            .toggleStyle(.checkbox)
                    }
                } else {
                    let picker = Picker("", selection: stringBinding(field.name)) {
                        ForEach(Array(options.enumerated()), id: \.offset) { i, option in
                            Text(titles?[safe: i] ?? humanize(option)).tag(option)
                        }
                    }
                    .labelsHidden()
                    if options.count <= 3 {
                        picker.pickerStyle(.segmented)
                    } else {
                        picker.pickerStyle(.menu)
                    }
                }

            case .number(let min, let max), .integer(let min, let max):
                Text(labelWithMarker(label, field)).font(.callout)
                if let min, let max, max > min {
                    HStack {
                        Slider(value: sliderBinding(field.name, min: min, max: max),
                               in: min...max,
                               step: isInteger(field) ? 1 : (max - min) / 100)
                        Text(numberDisplay(field.name)).monospacedDigit()
                            .frame(minWidth: 40, alignment: .trailing)
                    }
                } else {
                    TextField(rangeHint(min: min, max: max), text: numberBinding(field.name))
                }

            case .string(let format):
                Text(labelWithMarker(label, field)).font(.callout)
                stringControl(field: field, format: format)

            @unknown default:
                Text(labelWithMarker(label, field)).font(.callout)
                TextField("", text: stringBinding(field.name))
            }

            if let description = field.description, !description.isEmpty {
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
            if didAttemptSubmit, let error = validationErrors[field.name] {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func stringControl(field: MCPElicitationField, format: String?) -> some View {
        switch format {
        case "date":
            DatePicker("", selection: dateBinding(field.name), displayedComponents: .date)
                .labelsHidden().datePickerStyle(.field)
        case "date-time":
            DatePicker("", selection: dateBinding(field.name, includeTime: true))
                .labelsHidden().datePickerStyle(.field)
        default:
            TextField(placeholder(for: format), text: stringBinding(field.name))
                .textContentType(format == "email" ? .emailAddress : nil)
        }
    }

    // MARK: Labels

    private func displayLabel(for field: MCPElicitationField) -> String {
        field.title ?? humanize(field.name)
    }

    private func labelWithMarker(_ label: String, _ field: MCPElicitationField) -> String {
        field.required ? "\(label) *" : label
    }

    /// `assignee_email` / `assigneeEmail` / `assignee-email` → "Assignee email".
    private func humanize(_ raw: String) -> String {
        var spaced = ""
        var previousWasLower = false
        for character in raw {
            if character == "_" || character == "-" { spaced.append(" "); previousWasLower = false; continue }
            if character.isUppercase && previousWasLower { spaced.append(" ") }
            spaced.append(character)
            previousWasLower = character.isLowercase || character.isNumber
        }
        let trimmed = spaced.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard let first = trimmed.first else { return raw }
        let rest = trimmed.dropFirst().map { $0.lowercased() }
        return ([first.prefix(1).uppercased() + first.dropFirst().lowercased()] + rest).joined(separator: " ")
    }

    private func placeholder(for format: String?) -> String {
        switch format {
        case "email": return "name@example.com"
        case "uri": return "https://…"
        default: return ""
        }
    }

    private func rangeHint(min: Double?, max: Double?) -> String {
        switch (min, max) {
        case let (lo?, hi?): return "\(trimNumber(lo))–\(trimNumber(hi))"
        case let (lo?, nil): return "≥ \(trimNumber(lo))"
        case let (nil, hi?): return "≤ \(trimNumber(hi))"
        default: return "Number"
        }
    }

    private func trimNumber(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    private func isInteger(_ field: MCPElicitationField) -> Bool {
        if case .integer = field.kind { return true }
        return false
    }

    // MARK: Validation

    /// Field name → human-readable problem. Empty ⇒ OK to submit.
    private var validationErrors: [String: String] {
        var errors: [String: String] = [:]
        for field in request.fields {
            let value = values[field.name]
            let isEmpty = value == nil || value == .some(.string("")) || value == .some(.null)
            if field.required && isEmpty {
                errors[field.name] = "This field is required."
                continue
            }
            guard case .string(let format) = field.kind, case .string(let text)? = value, !text.isEmpty else { continue }
            switch format {
            case "email" where !text.contains("@") || !text.contains("."):
                errors[field.name] = "Enter a valid email address."
            case "uri" where URL(string: text)?.scheme == nil:
                errors[field.name] = "Enter a full URL, including https://."
            default:
                break
            }
        }
        return errors
    }

    /// Drop keys the user never touched so the server sees only real answers.
    private var cleanedValues: [String: MCPValue] {
        values.compactMapValues { $0.strippingEmpty() }
    }

    // MARK: Bindings

    private func seedDefaults() {
        guard values.isEmpty else { return }
        for field in request.fields {
            if let def = field.defaultValue { values[field.name] = def }
            else if case .boolean = field.kind { values[field.name] = .bool(false) }
            else if case .enumeration(let options, _, false) = field.kind, let first = options.first {
                values[field.name] = .string(first)
            } else if case .number(let min, _) = field.kind, let min { values[field.name] = .number(min) }
            else if case .integer(let min, _) = field.kind, let min { values[field.name] = .number(min) }
        }
    }

    private func numberDisplay(_ name: String) -> String {
        if case .number(let n)? = values[name] { return trimNumber(n) }
        return "—"
    }

    private func sliderBinding(_ name: String, min: Double, max: Double) -> Binding<Double> {
        Binding(
            get: { if case .number(let n)? = values[name] { return n } else { return min } },
            set: { values[name] = .number($0) })
    }

    private func dateBinding(_ name: String, includeTime: Bool = false) -> Binding<Date> {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = includeTime ? [.withInternetDateTime] : [.withFullDate]
        return Binding(
            get: {
                if case .string(let s)? = values[name], let date = formatter.date(from: s) { return date }
                return Date()
            },
            set: { values[name] = .string(formatter.string(from: $0)) })
    }

    private func stringBinding(_ name: String) -> Binding<String> {
        Binding(
            get: { if case .string(let s) = values[name] { return s } else { return "" } },
            set: { values[name] = .string($0) })
    }
    private func boolBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { if case .bool(let b) = values[name] { return b } else { return false } },
            set: { values[name] = .bool($0) })
    }
    private func numberBinding(_ name: String) -> Binding<String> {
        Binding(
            get: {
                if case .number(let n) = values[name] { return n == n.rounded() ? String(Int(n)) : String(n) }
                return ""
            },
            set: { values[name] = Double($0).map { .number($0) } ?? .string($0) })
    }
    private func multiSelectBinding(_ name: String, _ option: String) -> Binding<Bool> {
        Binding(
            get: {
                if case .array(let items) = values[name] { return items.contains(.string(option)) }
                return false
            },
            set: { isOn in
                var items: [MCPValue] = { if case .array(let a) = values[name] { return a } else { return [] } }()
                items.removeAll { $0 == .string(option) }
                if isOn { items.append(.string(option)) }
                values[name] = .array(items)
            })
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
