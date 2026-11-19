import FoundationModels
import LocalLMLabSDKCore
import SwiftUI

// The single-process SwiftUI implementation of `ToolConfirmationChannel`
// (the protocol + `ConfirmingToolAuthorizer` itself now live in Core, so a
// headless / multi-process host can reuse them).
//
// Wiring in a single-process SwiftUI app:
//
//   @StateObject private var toolConfirm = ToolConfirmationPresenter()
//   ...
//   .toolConfirmationSheet(toolConfirm)          // on a root view
//   ...
//   let session = try lab.makeSession(
//       route: .chat, tools: myTools,
//       authorizer: ConfirmingToolAuthorizer(channel: toolConfirm))

/// A `ToolConfirmationChannel` that queues pending tool calls for a SwiftUI
/// sheet. A `@MainActor` `ObservableObject` the host installs once and renders
/// with `.toolConfirmationSheet(_:)` (or its own UI driven off `pending`).
@available(macOS 26.0, *)
@MainActor
public final class ToolConfirmationPresenter: ObservableObject, ToolConfirmationChannel {
    /// Calls awaiting a decision, oldest first. The sheet shows `first`.
    @Published public private(set) var pending: [ToolConfirmationRequest] = []

    private let fallbackTimeout: Duration

    /// Optional extras the sheet offers for a call, decided by the host per call: a line saying why
    /// it asks, "Always allow this tool", and "Trust this server…" with what trusting unlocks.
    /// `nil` (default): the plain Allow / Deny sheet.
    public var extras: (@MainActor (PendingToolCall) -> ToolConfirmationExtras)?

    /// - Parameter fallbackTimeout: if a sheet sits unanswered this long the
    ///   request auto-denies and is removed. `ConfirmingToolAuthorizer` also
    ///   applies its own timeout; this is the presenter-side backstop.
    public init(fallbackTimeout: Duration = .seconds(120)) {
        self.fallbackTimeout = fallbackTimeout
    }

    // MARK: ToolConfirmationChannel

    public nonisolated func requestDecision(for call: PendingToolCall) async -> Bool {
        let id = UUID()
        let gate = DecisionGate()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                gate.attach(continuation)
                Task { @MainActor in
                    self.pending.append(ToolConfirmationRequest(id: id, call: call, decide: { gate.resume($0) }))
                    Task {
                        try? await Task.sleep(for: self.fallbackTimeout)
                        self.resolve(id, allow: false)
                    }
                }
            }
        } onCancel: {
            gate.resume(false)
            Task { @MainActor in self.discard(id) }
        }
    }

    // MARK: - Host-facing

    /// Resolve a pending request — the sheet's buttons call this, or a host
    /// presenting its own UI. A no-op if the id is unknown.
    public func resolve(_ id: ToolConfirmationRequest.ID, allow: Bool) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending.remove(at: index).decide(allow)
    }

    /// Drop a request without deciding it — used when the awaiting task was
    /// cancelled (the continuation is already resumed elsewhere).
    private func discard(_ id: ToolConfirmationRequest.ID) {
        pending.removeAll { $0.id == id }
    }
}

/// One tool call awaiting a decision.
@available(macOS 26.0, *)
public struct ToolConfirmationRequest: Identifiable, Sendable {
    public let id: UUID
    /// What the model wants to do.
    public let call: PendingToolCall
    /// Resume the waiting `requestDecision`. Resume-once; extra calls ignored.
    let decide: @Sendable (Bool) -> Void

    init(id: UUID, call: PendingToolCall, decide: @escaping @Sendable (Bool) -> Void) {
        self.id = id
        self.call = call
        self.decide = decide
    }
}

// MARK: - SwiftUI

@available(macOS 26.0, *)
public extension View {
    /// Presents a sheet for each tool call `ConfirmingToolAuthorizer` routes
    /// through `presenter`. Attach once, near the root.
    func toolConfirmationSheet(_ presenter: ToolConfirmationPresenter) -> some View {
        modifier(ToolConfirmationSheetModifier(presenter: presenter))
    }
}

/// What a confirmation sheet offers beyond Allow / Deny (`ToolConfirmationPresenter.extras`).
/// Each action runs, then the call is allowed.
@available(macOS 26.0, *)
public struct ToolConfirmationExtras {
    /// Why it's asking, e.g. "Brevo is untrusted, so ChatAgain can't tell whether this changes anything."
    public var note: String?
    /// Shown as "Always allow this tool": e.g. a per-tool `.allow` approval.
    public var alwaysAllow: (@MainActor () -> Void)?
    /// What trusting the source would unlock, shown before the user confirms.
    public var trustSummary: String?
    /// Shown as "Trust this server…", then "Trust and allow": e.g. `setTrust(.trusted, server:)`.
    public var trust: (@MainActor () -> Void)?

    public init(note: String? = nil, alwaysAllow: (@MainActor () -> Void)? = nil,
                trustSummary: String? = nil, trust: (@MainActor () -> Void)? = nil) {
        self.note = note
        self.alwaysAllow = alwaysAllow
        self.trustSummary = trustSummary
        self.trust = trust
    }
}

@available(macOS 26.0, *)
private struct ToolConfirmationSheetModifier: ViewModifier {
    @ObservedObject var presenter: ToolConfirmationPresenter

    func body(content: Content) -> some View {
        let active = Binding<ToolConfirmationRequest?>(
            get: { presenter.pending.first },
            // Dismissing without choosing (drag-down, Esc) denies.
            set: { if $0 == nil, let current = presenter.pending.first {
                presenter.resolve(current.id, allow: false)
            } })
        return content.sheet(item: active) { request in
            ToolConfirmationView(request: request, extras: presenter.extras?(request.call) ?? ToolConfirmationExtras()) { allow in
                presenter.resolve(request.id, allow: allow)
            }
        }
    }
}

@available(macOS 26.0, *)
struct ToolConfirmationView: View {
    let request: ToolConfirmationRequest
    var extras = ToolConfirmationExtras()
    let decide: (Bool) -> Void
    @State private var showingTrust = false

    private var call: PendingToolCall { request.call }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(tint)
                Text("Allow this action?").font(.headline)
            }

            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Tool", value: call.toolName)
                LabeledContent("From", value: originLabel)
                LabeledContent("Impact", value: impactLabel)
            }
            .font(.callout)

            // This call rated above the tool's usual impact (doc 29 W2): say why.
            if let reason = call.impactReason {
                Label(reason.prefix(1).uppercased() + reason.dropFirst(), systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !argumentRows.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(argumentRows, id: \.0) { key, value in
                        LabeledContent(key) {
                            Text(value).textSelection(.enabled).foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.caption)
            } else {
                Text(call.argumentsDescription)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let note = extras.note {
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            if showingTrust, let trust = extras.trust {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Trust \(sourceName)?").font(.subheadline.bold())
                    if let summary = extras.trustSummary {
                        Text(summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Spacer()
                        Button("Back") { showingTrust = false }
                        Button("Trust and Allow") { trust(); decide(true) }.buttonStyle(.borderedProminent)
                    }
                }
            } else {
                HStack {
                    if extras.trust != nil {
                        Button("Trust \(sourceName)…") { showingTrust = true }.buttonStyle(.link)
                    }
                    Spacer()
                    Button("Deny", role: .cancel) { decide(false) }
                        .keyboardShortcut(.cancelAction)
                    if let alwaysAllow = extras.alwaysAllow {
                        Button("Always Allow This Tool") { alwaysAllow(); decide(true) }
                    }
                    Button("Allow") { decide(true) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 360)
    }

    private var icon: String {
        switch call.impact {
        case .read: "eye"
        case .destructive: "trash"
        default: "pencil"
        }
    }
    private var tint: Color {
        switch call.impact {
        case .read: .secondary
        case .destructive: .red
        default: .orange
        }
    }
    private var impactLabel: String {
        switch call.impact {
        case .read: "Reads data"
        case .destructive: "Deletes or overwrites data"
        default: "Changes data"
        }
    }
    private var sourceName: String {
        switch call.origin {
        case .mcp(_, let displayName), .plugin(_, let displayName): displayName
        case .host: "this app"
        @unknown default: "this source"
        }
    }

    private var originLabel: String {
        switch call.origin {
        case .host: "this app"
        case .mcp(_, let displayName): "MCP server \(displayName)"
        case .plugin(_, let displayName): "the \(displayName) plug-in"
        @unknown default: "an external source"
        }
    }
    private var argumentRows: [(String, String)] {
        guard let content = call.arguments, case .structure(let props, let keys) = content.kind else {
            return []
        }
        return keys.compactMap { key in
            guard let value = props[key] else { return nil }
            return (key, Self.render(value))
        }
    }
    private static func render(_ content: GeneratedContent) -> String {
        switch content.kind {
        case .string(let s): s
        case .number(let n): "\(n)"
        case .bool(let b): b ? "true" : "false"
        case .null: "null"
        default: "\(content)"
        }
    }
}
