import LocalLMLabSDKCore
import SwiftUI

// The chat list beside a conversation: search, rename, delete, and a slot under the
// list for the app's own hint (ChatAgain Free: "More chats with ChatAgain Pro").

public struct ChatSidebar<Footer: View>: View {
    let store: ConversationStore
    let selection: UUID?
    let open: (UUID) -> Void
    let delete: (UUID) -> Void
    let conversations: ((String) -> [ConversationMeta])?
    let responding: Bool
    let notice: String?
    let footer: () -> Footer
    /// The highlighted row: follows `selection`, and snaps back to it after a click the app refuses.
    @State private var shown: UUID?
    @State private var query = ""
    @State private var renaming: UUID?
    @State private var newTitle = ""
    /// The rename field has the keyboard: given when Rename is chosen, so typing edits the title at once.
    @FocusState private var renameFocused: Bool

    /// - Parameters:
    ///   - conversations: the chats listed for a search (empty: all); `store.search` by default.
    ///   - responding: the open chat is replying. The app refuses a switch then, so a click on another chat
    ///     still goes to `open` (to say why) but its row isn't left highlighted.
    ///   - notice: a line under the list, such as why the app refused a click ("Wait for this reply…").
    ///   - footer: under the list.
    public init(store: ConversationStore, selection: UUID?, open: @escaping (UUID) -> Void, delete: @escaping (UUID) -> Void,
                conversations: ((String) -> [ConversationMeta])? = nil, responding: Bool = false, notice: String? = nil,
                @ViewBuilder footer: @escaping () -> Footer) {
        self.store = store
        self.selection = selection
        self.open = open
        self.delete = delete
        self.conversations = conversations
        self.responding = responding
        self.notice = notice
        self.footer = footer
        _shown = State(initialValue: selection)
    }

    public var body: some View {
        // The footer goes under the list and "No chats yet" in it: with `.safeAreaInset` or `.overlay` on the List, its
        // scroll area was 2 points tall and the list couldn't scroll (macOS 27, 2026-11-04).
        VStack(spacing: 0) {
            list
            if let notice {
                // Red, on a red tint: in secondary grey it was too faint to notice (2026-11-06).
                Label(notice, systemImage: "exclamationmark.circle.fill")
                    .font(.callout.weight(.medium)).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 8).padding(.bottom, 8)
                    .transition(.opacity)
            }
            footer()
        }
        .animation(.default, value: notice)
    }

    private var list: some View {
        List(selection: Binding(get: { shown }, set: { id in
            guard let id else { return }
            shown = id
            let refused = responding && id != selection
            open(id)
            // Refused (the app said why): highlight the open chat again. Next turn of the run loop, after the
            // List has finished its own selection change, or it keeps the clicked row (2026-11-06).
            if refused { DispatchQueue.main.async { shown = selection } }
        })) {
            if store.conversations.isEmpty {
                Text("No chats yet").foregroundStyle(.secondary).selectionDisabled()
            }
            ForEach(conversations?(query) ?? store.search(query)) { meta in
                Group {
                    if renaming == meta.id {
                        // Focused on Rename, title selected (as Finder does): without it the list kept the keyboard,
                        // the row stayed highlighted, and Return had to be pressed before typing (2026-10-26). Return
                        // or clicking away saves; Escape cancels.
                        TextField("Title", text: $newTitle)
                            .focused($renameFocused)
                            .onSubmit { commitRename(meta.id) }
                            .onExitCommand { renaming = nil }
                            .onChange(of: renameFocused) { _, focused in
                                if !focused, renaming == meta.id { commitRename(meta.id) }
                            }
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(meta.title).lineLimit(1)
                            Text(meta.updated, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .tag(meta.id)
                .contextMenu {
                    Button("Rename") {
                        newTitle = meta.title
                        renaming = meta.id
                        // Next turn of the run loop: the field exists only once the row has been redrawn.
                        DispatchQueue.main.async { renameFocused = true }
                    }
                    Button("Delete", role: .destructive) { delete(meta.id) }
                }
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search chats")
        .onChange(of: selection) { _, new in shown = new }
    }

    private func commitRename(_ id: UUID) {
        store.rename(id, to: newTitle)   // an empty title is ignored by the store
        renaming = nil
    }
}

public extension ChatSidebar where Footer == EmptyView {
    init(store: ConversationStore, selection: UUID?, open: @escaping (UUID) -> Void, delete: @escaping (UUID) -> Void,
         conversations: ((String) -> [ConversationMeta])? = nil, responding: Bool = false, notice: String? = nil) {
        self.init(store: store, selection: selection, open: open, delete: delete, conversations: conversations,
                  responding: responding, notice: notice) { EmptyView() }
    }
}

/// No chat open: the app's name, what it does, and New Chat.
public struct ChatEmptyStateView: View {
    let title: String
    let message: String
    let newChat: () -> Void

    public init(title: String, message: String, newChat: @escaping () -> Void) {
        self.title = title
        self.message = message
        self.newChat = newChat
    }

    public var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 40)).foregroundStyle(.tint)
            Text(title).font(.title.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            Button("New Chat", action: newChat).buttonStyle(.borderedProminent).controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

public extension ToolConfirmationPresenter {
    /// The confirmation sheet's extras for an MCP call: why it asks, "Always allow
    /// this tool", and for an untrusted server "Trust this server…" with what that unlocks.
    /// `appName` goes in the note ("ChatAgain can't tell whether…").
    func useStandardMCPExtras(manager: MCPServerManager, appName: String) {
        extras = { call in
            guard case .mcp(let id, let name) = call.origin, let state = manager.servers[id] else { return ToolConfirmationExtras() }
            // A check that asks every time (a copied tool call, an unread image): neither trust nor
            // Always Allow would stop the question, so neither is offered. The sheet's impact reason says what
            // was found.
            if call.requiresUser {
                return ToolConfirmationExtras(note: "This check asks every time, whatever \(name)'s trust or Always Allow says.")
            }
            let allow: @MainActor () -> Void = { manager.setToolApproval(.allow, server: id, tool: call.toolName) }
            guard state.trust != .trusted else {
                // The note follows the call's impact, as the sheet's top line does: one impact, stated once.
                let does: String? = switch call.impact {
                case .destructive: "can delete"
                case .mutate: "changes data"
                default: nil
                }
                return ToolConfirmationExtras(note: does.map { "\(name) is trusted; its labels say \(call.toolName) \($0)." },
                                              alwaysAllow: allow)
            }
            return ToolConfirmationExtras(
                note: "\(name) is untrusted, so \(appName) can't tell whether \(call.toolName) changes anything. Every call asks.",
                alwaysAllow: allow, trustSummary: "Its own labels about its tools will count. " + MCPToolLabels(state.tools).trustEffect,
                trust: { manager.setTrust(.trusted, server: id) })
        }
    }
}
