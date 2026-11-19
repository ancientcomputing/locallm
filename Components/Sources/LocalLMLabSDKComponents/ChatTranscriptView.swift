import AppKit
import LocalLMLabSDKCore
import SwiftUI

// A chat's transcript: one view for every SDK chat app, over a `ChatController`. The
// replies, reasoning, tool calls with their source and impact, the cards a turn ends with, files the
// tools wrote, the "why these tools" chip, Copy / Retry / Edit, and links from content confirmed
// before they open. What an app does differently comes in through slots: the empty
// chat, extra controls under a reply, the inline widget for a tool's view (MCPAppsHost's
// `MCPAppWidgetSlot`, which Components doesn't link) and the app's own cards.

/// What the reply-extras slot gets for one turn.
public struct ChatReplyContext {
    /// The turn's number in the transcript.
    public let turn: Int
    /// The newest turn.
    public let isLast: Bool
    /// The reply's text as Copy copies it: its assistant text, without reasoning or tool calls.
    public let text: String
    /// Why the turn got its tools, when it was recorded.
    public let info: TurnInfo?
}

/// How tool calls show in a transcript: `.plain`, one line per step in everyday words ("Read contract.pdf", "Checked
/// your calendar", "Used Hugging Face"), back-to-back calls of the same step merged, for people who aren't developers
/// (App Store builds); `.detailed`, each call with its tool's name, source, rating, arguments and result, and the
/// tools chip under each reply. An app picks one; ChatAgain switches them in its test builds.
public enum ChatToolDetail: Sendable { case plain, detailed }

public struct ChatTranscriptView<Empty: View, ReplyExtras: View, Widget: View, CustomCard: View>: View {
    let controller: ChatController
    let developer: Bool
    let toolDetail: ChatToolDetail
    let addWorkspace: (ChatCard, _ path: String, Workspace.Access) -> Void
    let empty: () -> Empty
    let replyExtras: (ChatReplyContext) -> ReplyExtras
    let widget: (ToolCallRecord) -> Widget
    let customCard: (ChatCard) -> CustomCard
    @State private var follow = Follow()
    @State private var linkToConfirm: URL?
    @State private var shownTurns = Self.turnsPerPage

    /// - Parameters:
    ///   - developer: the chip's developer details.
    ///   - toolDetail: plain steps (the default) or each call in detail, with the tools chip.
    ///   - addWorkspace: open a folder picker at `path`, save the pick, then `controller.complete(card, notice:)`.
    ///   - empty: shown while the chat has no messages (`ChatStarterView`).
    ///   - replyExtras: the app's own controls after Copy, Retry, Edit and the chip.
    ///   - widget: the inline view for a finished tool call that has one (`MCPAppWidgetSlot`).
    ///   - customCard: the app's `.custom` cards.
    public init(controller: ChatController, developer: Bool = false, toolDetail: ChatToolDetail = .plain,
                addWorkspace: @escaping (ChatCard, _ path: String, Workspace.Access) -> Void,
                @ViewBuilder empty: @escaping () -> Empty,
                @ViewBuilder replyExtras: @escaping (ChatReplyContext) -> ReplyExtras,
                @ViewBuilder widget: @escaping (ToolCallRecord) -> Widget,
                @ViewBuilder customCard: @escaping (ChatCard) -> CustomCard) {
        self.controller = controller
        self.developer = developer
        self.toolDetail = toolDetail
        self.addWorkspace = addWorkspace
        self.empty = empty
        self.replyExtras = replyExtras
        self.widget = widget
        self.customCard = customCard
    }

    private var entries: [HostTranscript.Entry] { controller.session?.hostTranscript.entries ?? [] }
    private var replyInProgress: HostTranscript.ReplyInProgress? { controller.session?.hostTranscript.replyInProgress }
    private var meta: ConversationMeta? { controller.store.meta(controller.conversation) }

    public var body: some View {
        let entries = entries
        let meta = meta
        let first = firstShown(entries)
        ScrollViewReader { proxy in
            ScrollView {
                // A plain stack: every row shown is made and measured, so the scroll position is always over real
                // content. A lazy stack placed rows by guessed heights and didn't make them while the window was
                // inactive, which left the transcript blank or drew turns over each other (ChatAgain on a MacBook
                // Air). A long chat shows its last turns; earlier ones come on request.
                VStack(alignment: .leading, spacing: 12) {
                    if first > 0 {
                        Button("Show earlier messages") {
                            let top = entries[first].id
                            shownTurns += Self.turnsPerPage
                            DispatchQueue.main.async { proxy.scrollTo(top, anchor: .top) }
                        }
                        .buttonStyle(.borderless).font(.callout).foregroundStyle(.tint)
                        .frame(maxWidth: .infinity)
                    } else {
                        cards(after: 0)
                    }
                    ForEach(Array(entries.enumerated().dropFirst(first)), id: \.element.id) { index, entry in
                        row(index, entry, entries, meta)
                    }
                    if let reply = replyInProgress {
                        ReplyInProgressView(reply: reply)
                    } else if controller.isCompacting {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Summarizing earlier messages so the chat stays fast…").foregroundStyle(.secondary)
                        }
                    } else if controller.status == .responding {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Thinking…").foregroundStyle(.secondary) }
                    }
                    cards(beyond: entries.count)
                    Color.clear.frame(height: 48).id(Self.bottom)
                }
                .font(MarkdownStyle.standard.body)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            // A chat opens at its end, and stays there when the window or the composer changes size.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            // One rule for following the end: while the user is at the bottom, new content scrolls into view; once
            // they scroll up, nothing moves until they come back down. Scrolls are never animated: an animated scroll
            // fades rows in and out as they move. Nothing watches the scroll geometry, which made long replies lay out
            // again and again within a frame (crashes on 2026-10-19); the phase only changes when the user scrolls.
            .onScrollPhaseChange { old, new, context in
                switch new {
                case .interacting:
                    follow.pinned = false
                case .idle where old == .interacting || old == .decelerating:
                    let geometry = context.geometry
                    follow.pinned = geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height < 40
                default:
                    break
                }
            }
            .onChange(of: growth) { _, _ in
                // Tokens can arrive several times a frame: scroll once, after this update.
                guard follow.pinned, !follow.scrollQueued else { return }
                follow.scrollQueued = true
                DispatchQueue.main.async {
                    follow.scrollQueued = false
                    if follow.pinned { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                }
            }
            .onChange(of: controller.status) { _, status in
                if status == .responding {
                    follow.pinned = true
                    proxy.scrollTo(Self.bottom, anchor: .bottom)
                }
            }
            .onChange(of: controller.conversation, initial: true) { _, _ in
                shownTurns = Self.turnsPerPage
                follow.pinned = true
                proxy.scrollTo(Self.bottom, anchor: .bottom)
            }
        }
        // A new chat's starter, over the transcript and pinned to the top. Not an if/else beside the transcript's
        // scroll view (8cfc383): swapping that view in once a chat's messages arrived after ChatAgain's PCC connect,
        // left it blank on a MacBook Air until a window event made it lay out. One scroll view, always
        // there; the starter only covers it while the chat is empty. Top-pinned, so a tall window still shows it all.
        .overlay(alignment: .top) {
            if entries.isEmpty && controller.cards.isEmpty && replyInProgress == nil && controller.status != .responding {
                ScrollView {
                    empty()
                        .padding(.horizontal, 20)
                        .frame(maxWidth: 820)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        // A link that came only from a page or file is confirmed before it opens.
        .environment(\.openURL, OpenURLAction { url in
            guard meta?.isContentLink(url) == true else { return .systemAction }
            linkToConfirm = url
            return .handled
        })
        .alert("Open a link from the content?", isPresented: Binding(
            get: { linkToConfirm != nil }, set: { if !$0 { linkToConfirm = nil } }
        ), presenting: linkToConfirm) { url in
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Cancel", role: .cancel) {}
        } message: { url in
            Text("This link came from a page or file the assistant read, not from you:\n\n\(url.absoluteString)")
        }
    }

    private static var bottom: String { "bottom" }

    /// How many turns a chat shows when it opens, and how many more "Show earlier messages" adds.
    private static var turnsPerPage: Int { 20 }

    /// The first entry shown: the start of the oldest of the last `shownTurns` turns.
    private func firstShown(_ entries: [HostTranscript.Entry]) -> Int {
        var turns = 0
        var previous: Int?
        for index in entries.indices.reversed() where entries[index].turn != previous {
            previous = entries[index].turn
            turns += 1
            if turns > shownTurns { return index + 1 }
        }
        return 0
    }

    /// One entry, then its turn's footer when it ends the turn, then any cards placed after it.
    @ViewBuilder private func row(_ index: Int, _ entry: HostTranscript.Entry, _ entries: [HostTranscript.Entry],
                                  _ meta: ConversationMeta?) -> some View {
        // Where the model's view of the chat starts over from a summary (`ChatController.compactsAbove`).
        if case .user = entry.content, let compaction = meta?.compactions?[entry.turn] {
            ChatCompactionDivider(compaction: compaction)
        }
        if toolDetail == .plain, case .toolCall = entry.content {
            if let run = plainToolRun(at: index, entries) {
                ChatPlainToolRow(records: run, failure: failureShown(after: index + run.count - 1, entries), widget: widget)
            }
        } else if !isShownAboveCard(entry, at: index) && !isBlankReply(entry) {
            // A message the model service failed on: the model's context dropped it, so it reads as not sent.
            let unanswered = isUnanswered(entry, meta)
            ChatEntryView(entry: entry, controller: controller, widget: widget)
                .opacity(unanswered ? 0.55 : 1)
            if unanswered {
                Label(meta?.unansweredNotes?[entry.turn] ?? "Not answered. The assistant didn't receive this message.",
                      systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        if isLastOfTurn(index, entries) {
            let context = ChatReplyContext(turn: entry.turn, isLast: index == entries.count - 1,
                                           text: replyText(turn: entry.turn, entries), info: meta?.turns[entry.turn])
            ChatTurnFooter(controller: controller, files: meta?.files[entry.turn] ?? [], context: context,
                           developer: developer, showsChip: toolDetail == .detailed, extras: replyExtras)
        }
        cards(after: index + 1)
    }

    /// Whether to keep the newest content in view. A reference, so setting it doesn't redraw.
    private final class Follow {
        var pinned = true
        var scrollQueued = false
    }
    /// Changes whenever the transcript grows: a new entry or card, or more of the reply in progress.
    private var growth: [Int] {
        [entries.count, controller.cards.count, replyInProgress?.text.count ?? -1, replyInProgress?.reasoning?.count ?? -1]
    }

    @ViewBuilder private func cards(after count: Int) -> some View {
        ForEach(controller.cards.filter { $0.after == count }) { card(for: $0) }
    }

    @ViewBuilder private func cards(beyond count: Int) -> some View {
        ForEach(controller.cards.filter { $0.after > count }) { card(for: $0) }
    }

    /// A card for a turn that stopped before it started (sign-in, access, clarify, review) shows the
    /// message it's holding first, as the user's bubble: the turn didn't reach the transcript, so
    /// nothing else would show it. The bubble stays there once the card is done; the resent turn's
    /// own copy of the message is hidden instead (`isShownAboveCard`), so it reads in order:
    /// message, card, answer. When one message stops at two cards in a row, only the first shows it.
    @ViewBuilder private func card(for card: ChatCard) -> some View {
        if let prompt = card.prompt, firstCard(holding: prompt, at: card.after)?.id == card.id {
            ChatUserBubble(text: prompt, fromWidget: false, folder: controller.filesFolder)
        }
        ChatCardView(card: card, controller: controller, addWorkspace: addWorkspace, custom: customCard)
    }

    private func firstCard(holding prompt: String, at position: Int) -> ChatCard? {
        controller.cards.first { $0.after == position && $0.prompt == prompt }
    }

    /// In `.plain`, the calls drawn as one line from `index`: a run of calls in one turn that read as the same step
    /// ("Read contract.pdf" for its outline and nine reads), with nothing shown between them. Nil for a call that's part
    /// of an earlier run, drawn there.
    private func plainToolRun(at index: Int, _ entries: [HostTranscript.Entry]) -> [ToolCallRecord]? {
        guard case .toolCall(let first) = entries[index].content else { return nil }
        let step = ChatToolCallText.plain(first).done
        func sameStep(_ i: Int) -> ToolCallRecord? {
            guard entries[i].turn == entries[index].turn, case .toolCall(let record) = entries[i].content,
                  ChatToolCallText.plain(record).done == step else { return nil }
            return record
        }
        var back = index - 1
        while back >= 0, isBlankReply(entries[back]) { back -= 1 }
        if back >= 0, sameStep(back) != nil { return nil }
        var run = [first]
        var next = index + 1
        while next < entries.count {
            if isBlankReply(entries[next]) { next += 1; continue }
            guard let record = sameStep(next) else { break }
            run.append(record)
            next += 1
        }
        return run
    }

    /// How a step that ended in a failure reads: the model often recovers in the same turn (a refused argument
    /// corrected, another tool tried), and "Something went wrong" for each of those alarmed the user over a reply that
    /// came out right.
    private func failureShown(after last: Int, _ entries: [HostTranscript.Entry]) -> ChatPlainToolRow<Widget>.Failure {
        let turn = entries[last].turn
        let later = entries[(last + 1)...].prefix { $0.turn == turn }
        if later.contains(where: { if case .toolCall(let record) = $0.content { record.state == .finished } else { false } }) {
            return .recovered
        }
        let isLatest = entries.last?.turn == turn
        return isLatest && controller.status == .responding ? .pending : .final
    }

    /// A user's message whose turn failed (`ConversationMeta.unanswered`).
    private func isUnanswered(_ entry: HostTranscript.Entry, _ meta: ConversationMeta?) -> Bool {
        guard case .user = entry.content else { return false }
        return meta?.unanswered?.contains(entry.turn) == true
    }

    /// The resent message of a resolved card, already shown above that card.
    private func isShownAboveCard(_ entry: HostTranscript.Entry, at index: Int) -> Bool {
        guard case .user(let text) = entry.content else { return false }
        return controller.cards.contains { $0.resolved && $0.after == index && $0.prompt == text }
    }

    /// An assistant entry with no text: a model that calls tools in a row can leave one between the
    /// calls, which showed as an empty gap.
    private func isBlankReply(_ entry: HostTranscript.Entry) -> Bool {
        guard case .assistant(let text) = entry.content else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func replyText(turn: Int, _ entries: [HostTranscript.Entry]) -> String {
        ChatReplyContext.replyText(turn: turn, in: entries)
    }

    private func isLastOfTurn(_ index: Int, _ entries: [HostTranscript.Entry]) -> Bool {
        index == entries.count - 1 ? replyInProgress == nil && controller.status != .responding
            : entries[index + 1].turn != entries[index].turn
    }
}

public extension ChatReplyContext {
    /// A turn's reply as Copy copies it: its assistant text, without reasoning or tool calls.
    static func replyText(turn: Int, in entries: [HostTranscript.Entry]) -> String {
        entries.filter { $0.turn == turn }.compactMap { entry -> String? in
            if case .assistant(let text) = entry.content { return text }
            return nil
        }
        .joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// An empty chat: an icon, a heading, what the app can do, and a few messages to try.
public struct ChatStarterView: View {
    let systemImage: String?
    let title: String
    let message: String
    let suggestions: [String]
    let send: (String) -> Void

    /// `systemImage`: the SF Symbol above the heading, as `ChatEmptyStateView` shows; nil for none.
    public init(systemImage: String? = "bubble.left.and.text.bubble.right", title: String = "What can I help with?",
                message: String, suggestions: [String], send: @escaping (String) -> Void) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.suggestions = suggestions
        self.send = send
    }

    public var body: some View {
        VStack(spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 40)).foregroundStyle(.tint)
            }
            Text(title).font(.title2.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 480)
            HStack {
                ForEach(suggestions, id: \.self) { example in
                    Button(example) { send(example) }.buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

/// Under each turn: files the tools wrote, the mark for links from content, Copy, (on the last turn)
/// Retry and Edit, the "why these tools" chip, and the app's extras.
private struct ChatTurnFooter<Extras: View>: View {
    let controller: ChatController
    let files: [String]
    let context: ChatReplyContext
    let developer: Bool
    let showsChip: Bool
    let extras: (ChatReplyContext) -> Extras
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(files, id: \.self) { name in
                FileCardView(url: controller.filesFolder.appendingPathComponent(name))
            }
            if let links = context.info?.contentLinks {
                Label(ContentLinksNote.text(links), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let room = context.info?.room?.note(assistant: controller.configuration.assistantName) {
                Label(room, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
            // As in the Claude app: icon-only actions with tooltips, under the last reply always and
            // under earlier ones on hover. Copy is the reply's text; Retry answers the same message
            // again from the conversation as it was; Edit puts the message back in the composer.
            HStack(spacing: 12) {
                if !context.text.isEmpty { ChatCopyButton(text: context.text).opacity(context.isLast || hovering ? 1 : 0) }
                if context.isLast, controller.canRegenerate {
                    ChatReplyActionButton(systemImage: "arrow.clockwise", help: "Retry") { controller.regenerate() }
                    ChatReplyActionButton(systemImage: "pencil", help: "Edit your message") { controller.editLast() }
                }
                if showsChip, let info = context.info { ToolChoiceChip(info: info, developer: developer) }
                extras(context)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
        }
    }
}

/// The note under a reply whose links came only from content the assistant read. Hosts once each;
/// past two, a general sentence: a list of models on hf.co named the host once per link (2026-10-25).
enum ContentLinksNote {
    static func text(_ links: [String]) -> String {
        let hosts = links.compactMap { URL(string: $0)?.host() }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let what = hosts.isEmpty || hosts.count > 2 ? "external sites" : hosts.joined(separator: " and ")
        return "This reply links to \(what), from a page or file the assistant read, not from you. Check before opening the links."
    }
}

/// An icon-only action under a reply, with its tooltip.
struct ChatReplyActionButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    init(systemImage: String, help: String, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) { Image(systemName: systemImage).font(.system(size: 13)) }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(help)
            .accessibilityLabel(help)
    }
}

/// Copies a reply's text; a check mark for a moment says it worked.
struct ChatCopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        ChatReplyActionButton(systemImage: copied ? "checkmark" : "doc.on.doc", help: copied ? "Copied" : "Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
        }
    }
}

private struct ChatEntryView<Widget: View>: View {
    let entry: HostTranscript.Entry
    let controller: ChatController
    let widget: (ToolCallRecord) -> Widget

    var body: some View {
        switch entry.content {
        case .user(let text):
            ChatUserBubble(text: text, fromWidget: entry.appInstance != nil, folder: controller.filesFolder)
        case .assistant(let text):
            MarkdownView(text: text, limit: 12_000)
        case .reasoning(let text):
            ReasoningDisclosure(text: text)
        case .toolCall(let record):
            ChatToolCallView(record: record, controller: controller, widget: widget)
        case .appContext(_, let text):
            DisclosureGroup {
                ChatLongText(text: text).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label("A view shared context with the model", systemImage: "rectangle.and.text.magnifyingglass")
                    .font(.caption).foregroundStyle(.secondary)
            }
        @unknown default:
            EmptyView()
        }
    }
}

/// The user's message, with its attachments (images as thumbnails) above it.
struct ChatUserBubble: View {
    let text: String
    let fromWidget: Bool
    let folder: URL?

    var body: some View {
        HStack {
            Spacer(minLength: 80)
            VStack(alignment: .trailing, spacing: 4) {
                if fromWidget {
                    Label("Sent by a view", systemImage: "rectangle.on.rectangle").font(.caption2).foregroundStyle(.secondary)
                }
                if let source = ChatAttachments.promptSource(in: text) {
                    Label("From \(source)", systemImage: "text.bubble").font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(ChatAttachments.names(in: text), id: \.self) { name in
                    if let folder, ChatAttachmentThumbnail.isImage(name) {
                        ChatAttachmentThumbnail(url: folder.appendingPathComponent(name), height: 180)
                            .onTapGesture(count: 2) { NSWorkspace.shared.open(folder.appendingPathComponent(name)) }
                    }
                    Label(name, systemImage: "paperclip")
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                        .onTapGesture(count: 2) { if let folder { NSWorkspace.shared.open(folder.appendingPathComponent(name)) } }
                }
                let shown = ChatAttachments.text(of: text)
                if !shown.isEmpty {
                    ChatLongText(text: shown)
                        .foregroundStyle(MarkdownStyle.standard.text)
                        .lineSpacing(MarkdownStyle.standard.lineSpacing)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color.accentColor.opacity(fromWidget ? 0.08 : 0.15), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }
}

/// Text that shows only its start when it's very long, with a control to show the rest: one huge
/// entry (a pasted document, long reasoning, a big tool argument) would otherwise make every layout
/// of the transcript slow enough to stall the app.
struct ChatLongText: View {
    let text: String
    var limit = 4_000
    @State private var expanded = false

    var body: some View {
        let long = text.count > limit
        VStack(alignment: .leading, spacing: 4) {
            Text(long && !expanded ? String(text.prefix(limit)) + "…" : text).textSelection(.enabled)
            if long {
                Button(expanded ? "Show less" : "Show all \(text.count.formatted()) characters") { expanded.toggle() }
                    .buttonStyle(.borderless).font(.caption).foregroundStyle(.tint)
            }
        }
    }
}

private struct ReplyInProgressView: View {
    let reply: HostTranscript.ReplyInProgress
    /// When the visible reply last grew.
    @State private var lastGrowth = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let reasoning = reply.reasoning { ReasoningDisclosure(text: reasoning, thinking: reply.isReasoning) }
            if reply.text.isEmpty {
                if reply.reasoning == nil {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Thinking…").foregroundStyle(.secondary) }
                }
            } else {
                MarkdownView(text: reply.text)
            }
            // The model is still at work but nothing new shows: it's writing a tool call (a whole
            // document for writeFile can take a minute), or it has finished reasoning and not yet
            // started the answer. Without this the screen looked stuck.
            if !reply.text.isEmpty || !reply.isReasoning && reply.reasoning != nil {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    if context.date.timeIntervalSince(lastGrowth) > 1.5 {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Working…").foregroundStyle(.secondary) }
                            .font(.callout)
                    }
                }
            }
        }
        .onChange(of: reply.text.count + (reply.reasoning?.count ?? 0)) { _, _ in lastGrowth = Date() }
    }
}

private struct ReasoningDisclosure: View {
    let text: String
    var thinking = false

    var body: some View {
        DisclosureGroup {
            ChatLongText(text: text).font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 6) {
                Label(thinking ? "Thinking…" : "Reasoning", systemImage: "brain").font(.caption).foregroundStyle(.secondary)
                if thinking { ProgressView().controlSize(.mini) }
            }
        }
    }
}

/// A tool call, with where it came from and what it may do (source, impact, and
/// "unverified" for an MCP server whose annotations aren't trusted), and its inline view when it has one.
private struct ChatToolCallView<Widget: View>: View {
    let record: ToolCallRecord
    let controller: ChatController
    let widget: (ToolCallRecord) -> Widget
    /// For a call saved before its record kept them: its source's name and trust, looked up once when the row
    /// appears. Read in `body`, the live server list redrew every tool row whenever any server's state changed
    /// (a reconnect, a tool-list refresh), and finished rows shifted with no input (ChatAgain on an Air).
    @State private var lookedUp: (source: String, trusted: Bool, impact: ToolImpact?)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Arguments").font(.caption2).foregroundStyle(.secondary)
                    ChatLongText(text: record.argumentsDescription).font(.caption.monospaced())
                    if let output = record.output {
                        Text("Result").font(.caption2).foregroundStyle(.secondary)
                        Text(output.prefix(2000)).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                HStack(spacing: 6) {
                    stateIcon
                    Text(readableToolName(record.tool.name)).font(.callout)
                    Text(source).font(.caption).foregroundStyle(.secondary)
                    impactBadge
                    if let how = ChatToolCallText.imageReading(record) { Text(how).font(.caption).foregroundStyle(.secondary) }
                    if let waiting = ChatToolCallText.stillWaiting(record, source: source) {
                        Text(waiting).font(.caption).foregroundStyle(.secondary)
                    }
                    if case .denied(let reason) = record.state { Text("Not allowed: \(reason)").font(.caption).foregroundStyle(.secondary) }
                    if case .failed(let reason) = record.state { Text(reason).font(.caption).foregroundStyle(.red).lineLimit(1) }
                }
            }
            ChatToolImages(record: record)
            if record.app != nil, record.state == .finished, record.mcpResult.map({ !$0.isError }) ?? false {
                widget(record)
            }
        }
        .accessibilityElement(children: .combine)
        .onAppear {
            guard lookedUp == nil, record.sourceName == nil || isMCP && record.serverTrusted == nil
                    || !isMCP && record.impact == nil else { return }
            lookedUp = (lookUpSource(), lookUpTrust(), lookUpImpact())
        }
    }

    // As when the call ran: the source may be gone or changed now (a removed workspace, a server reconnecting).
    private var source: String { record.sourceName ?? lookedUp?.source ?? "" }

    private var serverTrusted: Bool {
        guard isMCP else { return true }
        return record.serverTrusted ?? lookedUp?.trusted ?? true
    }

    private func lookUpSource() -> String {
        switch record.tool {
        case .mcp(let server, _): controller.sourceName(.mcp(server))
        case .plugin(let id, _): controller.sourceName(.plugin(id))
        case .host: "This app"
        case .provider: "Model provider"
        @unknown default: ""
        }
    }

    private var isMCP: Bool {
        if case .mcp = record.tool { return true }
        return false
    }

    private func lookUpTrust() -> Bool {
        guard case .mcp(let server, _) = record.tool else { return true }
        return controller.lab.mcp.servers[server]?.trust == .trusted
    }

    /// A plug-in tool's rating, for a call saved before its record kept it; one that can't be found may change data.
    private func lookUpImpact() -> ToolImpact? {
        guard case .plugin(let id, let name) = record.tool else { return nil }
        let tool = controller.lab.tools.plugins.first { $0.id == id }?.makeTools().first { $0.name == name }
        return (tool as? any ImpactRatedTool)?.impact ?? .mutate
    }

    /// What the tool may do: a plug-in's own rating; an MCP tool is "unverified" unless the user
    /// trusts its server, and then it's treated as able to change data.
    private var impact: ToolImpact? {
        switch record.tool {
        case .plugin:
            return record.impact ?? lookedUp?.impact   // as rated when it ran
        case .mcp:
            return serverTrusted ? nil : .mutate
        default:
            return nil
        }
    }

    @ViewBuilder private var impactBadge: some View {
        switch impact {
        case .mutate?: Text("may change data").font(.caption2).padding(.horizontal, 5).background(.orange.opacity(0.15), in: Capsule())
        case .destructive?: Text("may delete").font(.caption2).padding(.horizontal, 5).background(.red.opacity(0.15), in: Capsule())
        default: EmptyView()
        }
        if !serverTrusted {
            Text("unverified").font(.caption2).foregroundStyle(.secondary)
                .help("This server's own description of what its tools do isn't trusted, so they're treated as able to change data.")
        }
    }

    @ViewBuilder private var stateIcon: some View {
        switch record.state {
        case .awaitingApproval: Image(systemName: "hand.raised").foregroundStyle(.orange)
        case .running: ProgressView().controlSize(.mini)
        case .finished: Image(systemName: "checkmark.circle").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle").foregroundStyle(.red)
        case .denied: Image(systemName: "nosign").foregroundStyle(.secondary)
        @unknown default: Image(systemName: "questionmark.circle")
        }
    }
}

/// A step in `.plain`: what was done, in everyday words, quietly; a spinner while it runs; one plain sentence if it
/// failed or wasn't allowed. A tool's view (MCP Apps) still shows under it.
private struct ChatPlainToolRow<Widget: View>: View {
    /// How a failed last call reads: `recovered`, a later call in the turn worked; `pending`, the turn is still
    /// going; `final`, it's what the turn ended on.
    enum Failure { case recovered, pending, final }

    let records: [ToolCallRecord]
    var failure: Failure = .final
    let widget: (ToolCallRecord) -> Widget

    var body: some View {
        let label = ChatToolCallText.plain(records[0])
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if records.contains(where: { $0.state == .running }) {
                    ProgressView().controlSize(.mini)
                    Text(label.doing + "…")
                    if let last = records.last, let waiting = ChatToolCallText.stillWaiting(last, source: last.sourceName ?? "") {
                        Text(waiting).font(.caption)
                    }
                } else if records.contains(where: { $0.state == .awaitingApproval }) {
                    Image(systemName: "hand.raised").foregroundStyle(.orange)
                    Text(label.doing + "…")
                } else if case .failed(let reason)? = records.last?.state, reason.hasPrefix("Not run:") {
                    // Refused before it ran, as designed: a permission or sign-in the user is asked for after the reply,
                    // a declined or repeated call. "Something went wrong" for these read as a fault.
                    if reason.contains("permission") {
                        Image(systemName: "hand.raised")
                        Text("Needs your permission: " + ChatToolCallText.lowercasedFirst(label.doing))
                    } else if reason.contains("sign in") {
                        Image(systemName: "person.badge.key")
                        Text("Needs you to sign in: " + ChatToolCallText.lowercasedFirst(label.doing))
                    } else {
                        Image(systemName: "nosign")
                        Text("Not run: " + ChatToolCallText.lowercasedFirst(label.doing))
                    }
                } else if case .failed? = records.last?.state {
                    switch failure {
                    case .recovered:
                        Image(systemName: "arrow.uturn.right")
                        Text("Didn't work at first: " + ChatToolCallText.lowercasedFirst(label.doing))
                    case .pending:
                        Image(systemName: "arrow.uturn.right")
                        Text("Didn't work: " + ChatToolCallText.lowercasedFirst(label.doing))
                    case .final:
                        Image(systemName: "exclamationmark.circle")
                        Text("Something went wrong while " + ChatToolCallText.lowercasedFirst(label.doing))
                    }
                } else if records.contains(where: { if case .denied = $0.state { true } else { false } }) {
                    Image(systemName: "nosign")
                    Text("Not allowed: " + ChatToolCallText.lowercasedFirst(label.doing))
                } else {
                    Text(label.done)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            ForEach(records, id: \.id) { ChatToolImages(record: $0) }
            ForEach(records.filter { $0.app != nil && $0.state == .finished && $0.mcpResult.map { !$0.isError } ?? false }, id: \.id) {
                widget($0)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Images a tool returned (an MCP result's `image` content), shown under its row; the model gets a note.
struct ChatToolImages: View {
    let record: ToolCallRecord

    var body: some View {
        let images = (record.mcpResult?.images ?? []).compactMap { image in
            Data(base64Encoded: image.data).flatMap(NSImage.init(data:))
        }
        if !images.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                    let size = Self.shown(image.size)
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: size.width, height: size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .accessibilityLabel("Image from \(record.sourceName ?? "the tool")")
                }
            }
        }
    }

    /// An image's own size, shrunk to fit 240 × 160 when larger; never enlarged, so a small image stays sharp.
    static func shown(_ size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = min(1, 240 / size.width, 160 / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

/// Text for a tool call's row.
enum ChatToolCallText {
    /// A call in everyday words, as it runs and once done ("Reading contract.pdf", "Read contract.pdf"), for `.plain`.
    /// Built-in tools have their own phrases; an MCP tool reads as its server ("Used Hugging Face"); a raw tool name
    /// never shows. Calls with the same `done` in a row are one step.
    static func plain(_ record: ToolCallRecord) -> (doing: String, done: String) {
        let source = record.sourceName ?? fallbackSource(record.tool)
        let file = argument("path", of: record).map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
        let host = argument("url", of: record).flatMap { URL(string: $0)?.host() }
        func pair(_ doing: String, _ done: String) -> (doing: String, done: String) { (doing, done) }
        guard case .plugin(_, let name) = record.tool else { return pair("Using \(source)", "Used \(source)") }
        switch name {
        case "getUpcomingEvents": return pair("Checking your calendar", "Checked your calendar")
        case "addCalendarEvent": return pair("Adding an event to your calendar", "Added an event to your calendar")
        case "updateCalendarEvent": return pair("Changing an event in your calendar", "Changed an event in your calendar")
        case "deleteCalendarEvent": return pair("Deleting an event from your calendar", "Deleted an event from your calendar")
        case "getUpcomingReminders": return pair("Checking your reminders", "Checked your reminders")
        case "addReminder": return pair("Adding a reminder", "Added a reminder")
        case "updateReminder": return pair("Changing a reminder", "Changed a reminder")
        case "deleteReminder": return pair("Deleting a reminder", "Deleted a reminder")
        case "searchContacts", "listContacts": return pair("Looking in your contacts", "Looked in your contacts")
        case "addContact": return pair("Adding a contact", "Added a contact")
        case "updateContact": return pair("Changing a contact", "Changed a contact")
        case "deleteContact": return pair("Deleting a contact", "Deleted a contact")
        case "getCurrentTime": return pair("Checking the time", "Checked the time")
        case "getWeather": return pair("Checking the weather", "Checked the weather")
        case "getCurrentLocation": return pair("Finding your location", "Found your location")
        case "documentOutline", "readDocument", "searchDocument", "readWorkspaceFile", "readFileRange":
            let what = file ?? (name.contains("Document") ? "a document" : "a file")
            return pair("Reading \(what)", "Read \(what)")
        case "writeDocument", "writeWorkspaceFile": return pair("Saving \(file ?? "a file")", "Saved \(file ?? "a file")")
        case "editWorkspaceFile", "applyPatch": return pair("Editing \(file ?? "a file")", "Edited \(file ?? "a file")")
        case "deleteWorkspaceFile": return pair("Deleting \(file ?? "a file")", "Deleted \(file ?? "a file")")
        case "listWorkspaceFiles", "workspaceTree": return pair("Looking at your files", "Looked at your files")
        case "searchWorkspace": return pair("Searching your files", "Searched your files")
        case "fetchWebPage", "readWebPage", "searchWebPage":
            let what = host ?? "a web page"
            return pair("Reading \(what)", "Read \(what)")
        case "readImageText": return pair("Reading the image", "Read the image")
        case "loadTable", "sqlQuery", "csvInfo", "describeJson", "filterRows", "sortRows", "selectColumns", "aggregateRows",
             "dedupeRows", "concatRows", "jsonToCsv":
            let what = file ?? "a table"
            return pair("Working with \(what)", "Worked with \(what)")
        default: return pair("Using \(source)", "Used \(source)")
        }
    }

    static func lowercasedFirst(_ text: String) -> String { text.prefix(1).lowercased() + text.dropFirst() }

    /// A string argument of the call, for its file or page.
    private static func argument(_ key: String, of record: ToolCallRecord) -> String? {
        guard case .structure(let properties, _)? = record.arguments?.kind, case .string(let value)? = properties[key]?.kind
        else { return nil }
        return value
    }

    /// A source's name for a call saved before its record kept one, without reading live server state.
    private static func fallbackSource(_ tool: ToolReference) -> String {
        switch tool {
        case .mcp(let server, _): URL(string: server.rawValue)?.host() ?? "a tool"
        case .plugin(let id, _): id.rawValue.split(separator: ".").last.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "a tool"
        default: "a tool"
        }
    }

    /// While a call has been out 15 s or more: "Still waiting on Orders… (30 s)" (doc 41 B11).
    static func stillWaiting(_ record: ToolCallRecord, source: String) -> String? {
        guard record.state == .running, let seconds = record.stillRunningSeconds else { return nil }
        let name = source.isEmpty ? readableToolName(record.tool.name) : source
        return "Still waiting on \(name)… (\(seconds) s)"
    }

    /// For readImageText: whether Apple's on-device model looked at the image or only its text was
    /// read (the result's first line says which).
    static func imageReading(_ record: ToolCallRecord) -> String? {
        guard record.tool.name == "readImageText", record.state == .finished, let output = record.output else { return nil }
        let first = output.prefix { $0 != "\n" }
        if first.hasPrefix("Error:") { return "Couldn't read the image" }
        if first.contains("the on-device model described how it's laid out") { return "Layout described by the on-device model" }
        return first.contains(": the on-device model looked at it") ? "Looked at by the on-device model" : "Text read from the image"
    }
}

/// The line where a long chat was compacted: what the assistant reads now in place of the messages above it. Opens to
/// show the summary, so the user can see what the assistant still knows.
struct ChatCompactionDivider: View {
    let compaction: ChatCompaction
    @State private var isOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { isOpen.toggle() } label: {
                HStack(spacing: 8) {
                    rule
                    Label(compaction.summary == nil ? "Earlier messages left out" : "Earlier messages summarized",
                          systemImage: "text.line.first.and.arrowtriangle.forward")
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down").imageScale(.small)
                    rule
                }
                .font(.caption)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("The chat grew long, so the assistant now reads a summary of the messages above instead of the messages themselves.")
            if isOpen {
                VStack(alignment: .leading, spacing: 6) {
                    if let summary = compaction.summary {
                        Text("What the assistant remembers of the messages above:").font(.caption).foregroundStyle(.secondary)
                        Text(summary).textSelection(.enabled)
                    } else {
                        Text("The summary couldn't be written, so the assistant no longer sees the messages above this line.")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.vertical, 6)
    }

    private var rule: some View { Rectangle().fill(.separator).frame(height: 1) }
}
