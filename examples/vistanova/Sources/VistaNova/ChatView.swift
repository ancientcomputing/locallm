import SwiftUI
import AppKit
import LocalLMLabSDKCore

private extension View {
    /// `Link` gives no visual cursor feedback on macOS by default — show the pointing hand a
    /// clickable URL implies.
    func pointingHandCursor() -> some View {
        onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

@available(macOS 27, *)
struct ChatView: View {
    @Bindable var model: AppModel
    /// The Tavily setup sheet must always be dismissable — confirmed live: a `.constant(true)`
    /// binding (the earlier version) can never be set back to false, so Cancel had nothing to
    /// do and the dialog was stuck up. This tracks "the user dismissed it this session" so
    /// cancelling doesn't just make it reappear on the same launch; search stays disabled until
    /// Tavily connects, whether that's now or later via Settings (see SearchBox).
    @State private var tavilySetupDismissedForSession = false

    private var showingTavilySetup: Binding<Bool> {
        Binding(
            get: { !model.tavilyConfigured && !tavilySetupDismissedForSession },
            set: { isPresented in if !isPresented { tavilySetupDismissedForSession = true } }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            banner
            toolbar
            Divider()
            transcript
            Divider()
            SearchBox(model: model)
        }
        .background(model.isClassicTheme ? ClassicTheme.chrome : Color.clear)
        .sheet(isPresented: showingTavilySetup) {
            TavilySetupView(model: model)
        }
        // isPresented, not .sheet(item:) — confirmed live that item-identity-based presentation
        // doesn't reliably re-trigger for a second download after the first was cancelled (the
        // sheet just never reappeared, even though a real second download was running in the
        // background). A plain Bool transition is the same fix that made the Tavily setup sheet
        // above reliably dismissable/re-presentable.
        .sheet(isPresented: Binding(get: { model.pendingDownload != nil }, set: { _ in })) {
            DownloadProgressView(model: model)
        }
    }

    private var banner: some View {
        Image("VistaNovaBanner")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity)
    }

    // Model choice lives in Settings only now — see AppModel.searchModel/summaryModel.
    private var toolbar: some View {
        HStack(spacing: 12) {
            if !model.tavilyConnected {
                Label("Tavily not connected", systemImage: "exclamationmark.triangle")
                    .font(AppFont.caption)
                    .foregroundStyle(.orange)
            }

            Spacer()
            SettingsLink { Label("Settings", systemImage: "gearshape") }
        }
        .padding(10)
        .background(model.isClassicTheme ? ClassicTheme.chrome : Color.clear)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(model.threads) { thread in
                        ThreadView(thread: thread, model: model)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .onChange(of: model.threads) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        // "Classic" gives the page area its own white background — Navigator's chrome was gray,
        // the page itself was white — distinct from the gray toolbar/search box around it.
        .background(model.isClassicTheme ? Color.white : Color.clear)
    }

}

/// The search field's own container — sunken bevel in Classic, soft rounded fill by default.
@available(macOS 27, *)
private struct SearchFieldContainer: ViewModifier {
    let isClassic: Bool
    func body(content: Content) -> some View {
        if isClassic {
            content.classicSunken(cornerRadius: 3)
        } else {
            content
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
        }
    }
}

/// The app's primary control, first-class rather than an inline computed property — a bigger,
/// more prominent search box (not a chat text field) is the whole point of "first-classing" it:
/// its own type is what makes further sizing/styling passes tractable.
@available(macOS 27, *)
private struct SearchBox: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = model.lastError {
                Text(error).font(AppFont.caption).foregroundStyle(.red)
            }
            HStack(spacing: 12) {
                ZStack(alignment: .trailing) {
                    TextField("Search the web…", text: $model.input, axis: .vertical)
                        .font(AppFont.searchBox)
                        .textFieldStyle(.plain)
                        .lineLimit(1...4)
                        .padding(.vertical, 14)
                        .padding(.leading, 18)
                        .padding(.trailing, model.input.isEmpty ? 18 : 44)
                        .onSubmit { Task { await model.send() } }
                        .disabled(!model.tavilyConnected || model.isSearching)
                    if !model.input.isEmpty && !model.isSearching {
                        // Explicit "new topic" signal — the only thing that closes the current
                        // thread now (see AppModel's top comment). Edit the box in place instead
                        // to refine within the same thread.
                        Button {
                            model.clearForNewTopic()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 14)
                    }
                }
                .modifier(SearchFieldContainer(isClassic: model.isClassicTheme))

                if model.isSearching {
                    ProgressView()
                        .controlSize(.regular)
                        .frame(width: 48, height: 48)
                } else if model.isClassicTheme {
                    Button {
                        Task { await model.send() }
                    } label: {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(ClassicTheme.accent)
                    }
                    .buttonStyle(ClassicTheme.RaisedBevel())
                    .disabled(model.input.trimmingCharacters(in: .whitespaces).isEmpty || !model.tavilyConnected)
                } else {
                    Button {
                        Task { await model.send() }
                    } label: {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 18))
                            .frame(width: 48, height: 48)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.input.trimmingCharacters(in: .whitespaces).isEmpty || !model.tavilyConnected)
                }
            }
        }
        .padding(16)
    }
}

@available(macOS 27, *)
private struct ThreadView: View {
    let thread: TopicThread
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(thread.title)
                .font(AppFont.headline)
            ForEach(thread.turns) { turn in
                TurnView(turn: turn, model: model, showsQuery: turn.id != thread.turns.first?.id)
            }
        }
        .padding(12)
        .background {
            if model.isClassicTheme {
                Color.white.overlay(Rectangle().strokeBorder(ClassicTheme.chromeDark, lineWidth: 1))
            } else {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.3))
            }
        }
    }
}

@available(macOS 27, *)
private struct TurnView: View {
    let turn: SearchTurn
    let model: AppModel
    /// false for a thread's first turn — its query is already the thread's own bold header
    /// immediately above, so repeating it here would be the exact duplication fixed earlier.
    var showsQuery: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // What the user actually typed for THIS turn — the thread's own bold header only
            // covers the first turn, so a later turn (a refinement typed into the still-open
            // box) otherwise has no record of its own literal input anywhere.
            if showsQuery {
                Text(turn.query)
                    .font(AppFont.subheadline).bold()
            }
            // What was actually sent to tavily_search — can legitimately differ from the above
            // (a rewritten/expanded query), so both are worth showing rather than picking one.
            Text("Search terms: \(turn.searchQuery ?? turn.query)")
                .font(AppFont.caption).italic()
                .foregroundStyle(.secondary)
            ForEach(turn.links) { link in
                Link(destination: URL(string: link.url) ?? URL(string: "https://example.com")!) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(link.title)
                            .font(AppFont.body)
                            .underline()
                            .foregroundStyle(model.isClassicTheme ? ClassicTheme.link : .blue)
                        Text(link.url)
                            .font(AppFont.caption2)
                            .underline()
                            .foregroundStyle(model.isClassicTheme ? ClassicTheme.link.opacity(0.8) : .blue.opacity(0.8))
                    }
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
            summarySection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var summarySection: some View {
        if model.summarizingTurnIDs.contains(turn.id) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Summarizing…").font(AppFont.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        } else if let summary = turn.summary {
            Text(summary)
                .font(AppFont.body)
                .padding(.top, 4)
        } else {
            Button("Summarize") {
                Task { await model.summarize(turnID: turn.id) }
            }
            .font(AppFont.caption)
            .padding(.top, 4)
        }
    }
}

/// Shown the first time `summaryModel` (the default: Qwen3-4B-4bit) isn't downloaded yet —
/// triggered from inside `summarize()` itself, not a separate "browse models" flow. Cancelling
/// just means no summary this time; nothing else in the app is blocked by it.
@available(macOS 27, *)
private struct DownloadProgressView: View {
    // @Bindable, not a plain `let download: PendingDownload` snapshot — the earlier version
    // captured the download's value once at presentation time, so the progress bar never
    // actually animated as AppModel.downloadSummaryModel() updated the real fraction. Reading
    // `model.pendingDownload` directly here re-renders live as that property changes.
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Downloading summary model").font(AppFont.title2).bold()
            if let download = model.pendingDownload {
                Text(download.repoID).font(AppFont.caption).foregroundStyle(.secondary)
                ProgressView(value: download.fraction)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.cancelPendingDownload() }
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}
