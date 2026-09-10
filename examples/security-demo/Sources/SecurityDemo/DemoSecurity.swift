import FoundationModels
import LocalLMLabSDKCore
import Observation

// The example's "Security panel" — and the one place it turns into SDK types.
//
// Two parts, the same split LocalLM Lab uses:
//   - `DemoSecurity`  : @MainActor @Observable UI state the panel binds to
//   - `DemoPolicy`    : an immutable Sendable snapshot the run loop hands to the SDK
//
// A run takes a snapshot, so editing the panel mid-turn never changes a session already built.

enum ConnectorLevel: String, CaseIterable, Identifiable, Sendable {
    case readOnly = "Read-only"
    case changes  = "Changes"
    case full     = "Full"

    var id: String { rawValue }

    /// The selection ceiling this level implies. `Sequence.limited(toMaxImpact:)` keeps a tool
    /// only if its `ImpactRatedTool.impact` is at or below this.
    var maxImpact: ToolImpact {
        switch self {
        case .readOnly: return .read
        case .changes:  return .mutate
        case .full:     return .destructive
        }
    }
}

@MainActor
@Observable
final class DemoSecurity {
    /// Applies to the Calendar connector's tools. Todoist tools are opaque (all `.mutate`), so
    /// there's no useful level split for them — only the confirm toggle.
    var calendarLevel: ConnectorLevel = .changes

    /// Ask before each Calendar change the model attempts.
    var calendarConfirm = true

    /// Ask before each Todoist (MCP) tool call.
    var todoistConfirm = true

    func snapshot() -> DemoPolicy {
        DemoPolicy(calendarLevel: calendarLevel,
                   calendarConfirm: calendarConfirm,
                   todoistConfirm: todoistConfirm)
    }
}

struct DemoPolicy: Sendable {
    var calendarLevel: ConnectorLevel
    var calendarConfirm: Bool
    var todoistConfirm: Bool

    /// True when any confirmation is wanted — if not, `makeSession` gets no authorizer and
    /// runs exactly like a bare `LanguageModelSession`.
    var wantsConfirmation: Bool { calendarConfirm || todoistConfirm }

    /// Lever 1 — selection: filter the Calendar tool list down to `calendarLevel`.
    func limitedCalendarTools(_ tools: [any Tool]) -> [any Tool] {
        tools.limited(toMaxImpact: calendarLevel.maxImpact)
    }

    /// Lever 2 — invocation: the per-call policy for `ConfirmingToolAuthorizer`. Reads always
    /// run; a mutating/destructive call is confirmed when its connector's toggle is on.
    func requirement(for call: PendingToolCall) -> ConfirmingToolAuthorizer.Requirement {
        guard call.impact >= .mutate else { return .allow }
        switch call.origin {
        case .host:            // the only host tools here are Calendar's
            return calendarConfirm ? .confirm : .allow
        case .mcp:
            return todoistConfirm ? .confirm : .allow
        @unknown default:
            return .confirm
        }
    }
}
