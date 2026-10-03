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

    /// True when any confirmation is wanted. When false, `run()` passes `authorizer: nil` to
    /// `makeSession`: no invocation gate, so every tool call the model makes runs immediately,
    /// unconfirmed. (The level still limits *which* tools are in the session.)
    var wantsConfirmation: Bool { calendarConfirm || todoistConfirm }

    /// Lever 1 — selection: filter the Calendar tool list down to `calendarLevel`.
    func limitedCalendarTools(_ tools: [any Tool]) -> [any Tool] {
        tools.limited(toMaxImpact: calendarLevel.maxImpact)
    }

    /// Lever 2 — invocation. The app's own tools (here only Calendar's): ask before a change when
    /// the toggle is on. Reads always run.
    var calendarApproval: ToolApproval {
        calendarConfirm ? .ask(atOrAbove: .mutate, by: .user) : .allow
    }

    /// Lever 2 — invocation, per MCP server (`lab.mcp.setToolApproval`). Todoist stays untrusted, so
    /// its tools all count as changes: `nil` (the untrusted default) asks before each call.
    var todoistApproval: ToolApproval? {
        todoistConfirm ? nil : .allow
    }
}
