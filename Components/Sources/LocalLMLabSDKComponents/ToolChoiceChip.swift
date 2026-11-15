import LocalLMLabSDKCore
import SwiftUI

/// "Why these tools": under each reply, which sources were picked, how sure the matcher was, and
/// how long it took; tapped, the whole record (`TurnInfo`). From ChatAgain.
public struct ToolChoiceChip: View {
    let info: TurnInfo
    let developer: Bool
    @State private var expanded = false

    /// `developer`: also show the turn's timings, tokens restored from the prompt cache and the tool
    /// block's size, where the record has them.
    public init(info: TurnInfo, developer: Bool = false) {
        self.info = info
        self.developer = developer
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "wrench.and.screwdriver")
                    Text(summary)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.quaternary.opacity(0.5), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Why these tools: \(summary)")
            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Tools picked by \(info.matcher) in \(Int(info.milliseconds.rounded())) ms, before the model started").font(.caption)
                    if !info.byAttachment.isEmpty {
                        Text("By attachment type: \(info.byAttachment.joined(separator: ", "))").font(.caption)
                    }
                    if !info.sources.isEmpty {
                        Text("Best-matching sources: " + info.sources.map { "\($0.name) \(Int(($0.score * 100).rounded()))%" }.joined(separator: " · "))
                            .font(.caption)
                    }
                    if let checked = info.inContext {
                        // Mid-chat, a source joins only if the latest message needs it beyond the earlier ones; a
                        // workspace question scored Files 100% and went unanswered with no sign why (2026-10-25).
                        Text("Checked against the earlier messages: " + checked.map { "\($0.name) \(Int(($0.score * 100).rounded()))%" }.joined(separator: " · "))
                            .font(.caption)
                    }
                    Text(info.offered.isEmpty ? "No tools offered." : "Offered: " + info.offered.joined(separator: ", ")).font(.caption)
                    if !info.connected.isEmpty { Text("Connected for this turn: \(info.connected.joined(separator: ", "))").font(.caption) }
                    if let files = info.fileActivity { Text("Files: \(files.joined(separator: "; "))").font(.caption) }
                    ForEach(info.dropped ?? [], id: \.self) { Text("Dropped \($0): unused").font(.caption).foregroundStyle(.secondary) }
                    ForEach(info.heldBack ?? [], id: \.self) { Text("\($0) held back: not mentioned in this chat").font(.caption).foregroundStyle(.secondary) }
                    ForEach(info.unavailable, id: \.self) { Text("Unavailable: \($0)").font(.caption).foregroundStyle(.orange) }
                    if developer {
                        Text(developerLine).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.secondary)
                .padding(.leading, 8)
            }
        }
    }

    /// "Calendar, Documents · picked in 573 ms", and in developer mode "· turn 4.2 s".
    private var summary: String {
        let sources = Set(info.offered.compactMap { $0.components(separatedBy: " › ").first })
        var text = (sources.isEmpty ? "No tools" : sources.sorted().joined(separator: ", "))
            + " · picked in \(Int(info.milliseconds.rounded())) ms"
        if developer, let total = info.totalMilliseconds { text += " · turn \(Self.seconds(total))" }
        return text
    }

    /// "850 ms" under a second, else "4.2 s".
    public static func seconds(_ milliseconds: Double) -> String {
        milliseconds < 1000 ? "\(Int(milliseconds.rounded())) ms" : String(format: "%.1f s", milliseconds / 1000)
    }

    private var developerLine: String {
        var parts: [String] = []
        if let total = info.totalMilliseconds { parts.append("turn \(Self.seconds(total))") }
        if let ttft = info.firstTokenMilliseconds { parts.append("first token \(Int(ttft.rounded())) ms") }
        if let restored = info.restoredTokens { parts.append("restored \(restored) tokens") }
        if let block = info.toolBlockTokens { parts.append("tool block ~\(block) tokens") }
        return parts.joined(separator: " · ")
    }
}
