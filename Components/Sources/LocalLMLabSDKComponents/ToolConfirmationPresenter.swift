import FoundationModels
import LocalLMLabSDKCore
import SwiftUI

// The single-process SwiftUI implementation of `ToolConfirmationChannel`
// (the protocol + `ConfirmingToolAuthorizer` itself now live in Core, so a
// headless / multi-process host can reuse them — see
// docs/sdk-authority-model.md §1.1).
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
            ToolConfirmationView(request: request) { allow in
                presenter.resolve(request.id, allow: allow)
            }
        }
    }
}

@available(macOS 26.0, *)
struct ToolConfirmationView: View {
    let request: ToolConfirmationRequest
    let decide: (Bool) -> Void

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

            HStack {
                Spacer()
                Button("Deny", role: .cancel) { decide(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Allow") { decide(true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
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
    private var originLabel: String {
        switch call.origin {
        case .host: "this app"
        case .mcp(_, let displayName): "MCP server \(displayName)"
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
