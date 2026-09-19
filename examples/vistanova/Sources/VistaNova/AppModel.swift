// AppModel — the app's one piece of real logic: connect Tavily over MCP, let the user pick a
// LOCAL model for search and, independently, a LOCAL model for summarizing (Apple on-device or a
// downloaded MLX open-weight model either way — no cloud providers; a search backend other than
// Tavily, e.g. Brave/Exa, is a config option for later, not built yet), and run searches as topic
// threads. The two model choices are independent because they carry different risk: search needs
// reliable tool-calling above all else (system model, proven reliable there), while summarizing
// is pure text synthesis with no tool call at all, so it's the one place worth defaulting to an
// MLX model instead — see `defaultSummaryModel`.
//
// Refinement, in one paragraph: an earlier version had the model itself decide whether a new
// query continued the current topic or started a fresh one, silently expanding an ambiguous
// follow-up ("last ceo") using the thread's earlier turns. Confirmed live that this fails exactly
// where it matters most — that exact query, inside a Yahoo thread, got grounded to Tim Cook
// instead, silently, with no way to notice short of reading the tiny subtitle. So there is no
// automatic grounding or topic classification anymore. The composer leaves each submitted query
// sitting in the box (editable) instead of clearing it — the user edits it directly ("last ceo" →
// "yahoo last ceo") or hits the clear button to start a genuinely new topic, and *that* explicit
// action, not a model guess, is what decides whether the next search extends `activeThreadID` or
// starts a new one. Every search is a fresh, stateless `LocalLMLabSession` — nothing here relies
// on conversational memory inside the model any more.

import Foundation
import Observation
import FoundationModels
import LocalLMLabSDKCore
import LocalLMLabSDKInference

/// Progress state for a one-time MLX model download, triggered from `summarize()` the first time
/// the summary model isn't installed yet — see `AppModel.downloadSummaryModel()`.
struct PendingDownload: Identifiable {
    let id = UUID()
    let repoID: String
    var fraction: Double = 0
}

@Generable
struct WebPage {
    @Guide(description: "A short, descriptive title for the page")
    let title: String
    @Guide(description: "The page's full URL, starting with http:// or https://")
    let url: String
    @Guide(description: "tavily_search's own short description/snippet for this result — copy it verbatim, don't write a new one")
    let snippet: String
}

@Generable
struct SearchResults {
    @Guide(description: "Exactly 5 distinct web pages that cover the topic")
    let pages: [WebPage]
}

@available(macOS 27, *)
@MainActor
@Observable
final class AppModel {
    let lab: LocalLMLab
    /// The one MLX model this app has an opinion about is a *shipped pin*: exact commit, in code.
    /// Without it a fresh download tracks the repo's `main`, so its owner could swap the weights
    /// behind the same name and change what Summarize does, with no app release. Only a commit
    /// this app names can move it. A shipped pin that can't be fetched fails the download — it
    /// never falls back to `main`. Any other MLX model the user has on disk is not pinned by this
    /// app: it isn't downloaded here, so there's no first download to capture a pin from.
    private let mlxProvider = MLXModelProvider(pinnedRevisions: [
        AppModel.summaryModelRepo: AppModel.summaryModelRevision,
    ])

    /// A/B: the Netscape-era "Classic" chrome vs. the Modern look — purely cosmetic, so a plain
    /// UserDefaults toggle is enough (no need for the SDK's model-state snapshot machinery here).
    /// Classic is the out-of-box default (registered below); switching to Modern in Settings
    /// persists that choice same as any other value.
    var isClassicTheme: Bool {
        didSet { UserDefaults.standard.set(isClassicTheme, forKey: "isClassicTheme") }
    }

    /// Two independent model choices, not one — search needs reliable tool-calling above all
    /// else, while summarization is pure text synthesis with none of that risk, so it's the one
    /// place a different (and possibly less tool-reliable) model is worth defaulting to.
    var searchModel: ModelID = .system
    var summaryModel: ModelID = AppModel.defaultSummaryModel
    static let summaryModelRepo = "mlx-community/Qwen3-4B-4bit"
    /// Full 40-character Hugging Face commit hash, not a branch name. This is the
    /// commit the app's summaries were tried against; `main` was still at it on 2026-09-19. To
    /// adopt a newer version: review it, run Summarize against it, then change this hash — the
    /// repo and its commit move together, in a release.
    static let summaryModelRevision = "4dcb3d101c2a062e5c1d4bb173588c54ea6c4d25"
    static let defaultSummaryModel = ModelID(scheme: "mlx", rest: summaryModelRepo)!

    var threads: [TopicThread] = []
    var input: String = ""
    var isSearching = false
    var lastError: String?
    /// Turns currently summarizing — drives a per-turn spinner in ChatView.
    var summarizingTurnIDs: Set<UUID> = []
    /// Non-nil while downloading `summaryModel` for the first time — drives a progress sheet.
    var pendingDownload: PendingDownload?

    /// nil until Tavily has been added at least once (drives the blocking setup sheet).
    var tavilyConfigured = false
    var tavilyConnected = false

    private let tavilyURL = URL(string: "https://mcp.tavily.com/mcp/")!
    private var tavilyServerID: MCPServerID { MCPServerID(rawValue: tavilyURL.absoluteString) }

    /// The thread the next submitted query appends to. nil means the next submission starts a
    /// new thread — set that way by `clearForNewTopic()`, which is the ONLY thing that closes a
    /// thread now (no model classification involved).
    private var activeThreadID: UUID?

    /// Two independent things to know about a model before searching with it, both confirmed
    /// live to vary across MLX models: whether it reliably calls a tool at all (Qwen3-8B-4bit,
    /// Gemma, and Granite all answered "who founded Yahoo" from their own training data instead of
    /// calling tavily_search, despite being told not to), and separately, whether it supports
    /// Apple's constrained/"guided" generation that `@Generable` structured output relies on
    /// (Qwen3-8B-4bit: "The selected model does not support guided generation"). Both come from
    /// one `capabilityProbe` call (a real prompt + a trivial tool call), cached per model since
    /// that probe itself costs real inference time.
    private struct ModelSearchCapability { var toolCalling: Bool; var guidedGeneration: Bool }
    private var capabilityCache: [ModelID: ModelSearchCapability] = [:]

    init() {
        UserDefaults.standard.register(defaults: ["isClassicTheme": true])
        isClassicTheme = UserDefaults.standard.bool(forKey: "isClassicTheme")
        lab = LocalLMLab(configuration: .init(providers: [SystemModelProvider(), mlxProvider]))
        // The SDK's own persistence for exactly this (route map + residency + installed
        // records) — restore(from:) before reading the "search"/"summary" routes back, rather
        // than this app tracking either model choice as its own separate string.
        if let modelState = ModelStateStore.load() {
            lab.restore(from: modelState)
        }
        searchModel = lab.models.modelID(for: "search") ?? .system
        summaryModel = lab.models.modelID(for: "summary") ?? Self.defaultSummaryModel

        let settings = SettingsStore.load()
        threads = HistoryStore.load()

        if let tavily = settings.tavilyServer {
            tavilyConfigured = true
            Task { await reconnectTavily(shape: tavily) }
        }
    }

    /// For the "Web search model" picker only — a model actually ready to use right now. The
    /// summary picker uses `summaryModelOptions` instead, which also offers the (possibly not yet
    /// downloaded) default.
    var availableModels: [ModelID] {
        lab.models.knownModels.filter { lab.models.availability(for: $0).isAvailable }
    }

    /// Ready-to-use models plus the default summary model, even before it's been downloaded —
    /// picking it is what triggers `summarize()`'s one-time download prompt.
    var summaryModelOptions: [ModelID] {
        var options = availableModels
        if !options.contains(Self.defaultSummaryModel) { options.append(Self.defaultSummaryModel) }
        return options
    }

    func selectSearchModel(_ id: ModelID) {
        guard id != searchModel else { return }
        searchModel = id
        lab.models.route("search", to: id)
        ModelStateStore.save(lab.snapshot())
        endActiveThread()
    }

    func selectSummaryModel(_ id: ModelID) {
        guard id != summaryModel else { return }
        summaryModel = id
        lab.models.route("summary", to: id)
        ModelStateStore.save(lab.snapshot())
    }

    // MARK: - Tavily (MCP)

    func connectTavily(apiKey: String) async -> String? {
        let result = await lab.mcp.addServer(
            url: tavilyURL, displayName: "Tavily", authType: .pat, patToken: apiKey)
        switch result {
        case .success(let state):
            tavilyConfigured = true
            tavilyConnected = true
            var settings = SettingsStore.load()
            settings.tavilyServer = PersistedTavilyServer(
                url: tavilyURL.absoluteString, displayName: "Tavily",
                toolNames: ["tavily_search"], estimatedTokens: state.estimatedTokens)
            SettingsStore.save(settings)
            return nil
        case .failure(let error):
            return "\(error)"
        }
    }

    func removeTavily() {
        lab.mcp.removeServer(tavilyServerID)
        tavilyConfigured = false
        tavilyConnected = false
        var settings = SettingsStore.load()
        settings.tavilyServer = nil
        SettingsStore.save(settings)
    }

    private func reconnectTavily(shape: PersistedTavilyServer) async {
        lab.mcp.restore(from: [(
            id: tavilyServerID, url: tavilyURL, displayName: shape.displayName,
            tools: [], estimatedTokens: shape.estimatedTokens, enabled: true,
            authType: .pat, manualClientID: nil, resources: []
        )])
        let result = await lab.mcp.reconnect(tavilyServerID)
        if case .success = result {
            tavilyConnected = true
        } else {
            tavilyConnected = false
        }
    }

    // MARK: - Search

    func send() async {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isSearching, tavilyConnected else { return }
        // Left visible (but not editable — see ChatView's composer) after the turn finishes too,
        // success or failure — this app no longer clears the box for you. The user edits it
        // in place to refine, or hits the clear button to start a new topic; see this file's
        // top comment for why that replaced model-guessed refinement.
        lastError = nil
        isSearching = true
        defer { isSearching = false }

        do {
            let capability = await searchCapability(searchModel)
            guard capability.toolCalling else {
                lastError = "This model doesn't reliably call tools, so it can't be trusted to actually search rather than answer from its own training data. Pick a different model in Settings."
                return
            }
            let (session, capture) = try makeSearchSession(supportsGuidedGeneration: capability.guidedGeneration)
            let (links, searchQuery) = try await search(query: query, using: session, capture: capture, supportsGuidedGeneration: capability.guidedGeneration)

            if let threadID = activeThreadID {
                appendTurn(query: query, searchQuery: searchQuery, links: links, toThreadID: threadID)
            } else {
                let thread = TopicThread(
                    turns: [SearchTurn(query: query, searchQuery: searchQuery, links: links, timestamp: Date())],
                    createdAt: Date())
                activeThreadID = thread.id
                threads.append(thread)
                HistoryStore.save(threads)
            }
        } catch {
            lastError = await GenerationErrorDescription.describe(error)
        }
    }

    /// The explicit "new topic" signal — the composer's clear button. Nothing else closes a
    /// thread; see this file's top comment.
    func clearForNewTopic() {
        input = ""
        activeThreadID = nil
        lastError = nil
    }

    /// Switching models mid-thread: the thread closes (a different model shouldn't silently
    /// inherit a thread it never saw), but unlike `clearForNewTopic()` the box keeps its text —
    /// the user didn't ask to abandon what they typed, just to answer it with a different model.
    func endActiveThread() {
        activeThreadID = nil
    }

    /// Settings' "Reset History" — irreversible, so the button itself should confirm before
    /// calling this. Only the search history; Tavily's connection, model choices, and appearance
    /// are separate settings the user didn't ask this to touch.
    func resetHistory() {
        threads = []
        activeThreadID = nil
        HistoryStore.save(threads)
    }

    /// Apple's own models (on-device, PCC) always support tool calling and `@Generable` structured
    /// output; an MLX model needs a one-time real-prompt-plus-tool-call probe to find out either,
    /// since not all of them reliably do.
    private func searchCapability(_ id: ModelID) async -> ModelSearchCapability {
        guard id.scheme == "mlx" else { return ModelSearchCapability(toolCalling: true, guidedGeneration: true) }
        if let cached = capabilityCache[id] { return cached }
        let report = await mlxProvider.capabilityProbe(id)
        let capability = ModelSearchCapability(
            toolCalling: report.capabilities.contains(.toolCalling),
            guidedGeneration: report.capabilities.contains(.guidedGeneration))
        capabilityCache[id] = capability
        return capability
    }

    /// Deliberately a fresh, stateless session every call — no transcript carried over between
    /// searches. An earlier version reused one session per topic thread so the model could see
    /// prior turns, and separately explained the follow-up mechanic in its own instructions; the
    /// explaining backfired (the small on-device model started reasoning out loud about its own
    /// role instead of just searching: "I cannot fulfill this request because it involves a
    /// misunderstanding of my role"), and the reuse itself let a wrong guess happen silently
    /// (confirmed live: "last ceo" inside a Yahoo thread got grounded to Tim Cook). Refinement now
    /// happens in the composer, not the model — see this file's top comment.
    private func makeSearchSession(supportsGuidedGeneration: Bool) throws -> (LocalLMLabSession, SearchQueryCapture) {
        lab.models.route("search", to: searchModel)
        // The output-format line only gets added when guided generation isn't available: with it,
        // `@Generable` enforces the shape directly and an extra formatting instruction is just
        // more words for a small model to misread; without it, the model has no schema at all, so
        // the format has to be spelled out for parsePlainTextLinks to have anything reliable to
        // parse.
        let formatInstruction = supportsGuidedGeneration ? "" : """
             Respond with exactly 5 lines, one per result, each formatted exactly as \
            "Title — URL" and nothing else — no numbering, headers, or extra commentary.
            """
        let capture = SearchQueryCapture()
        let tool = TavilySearchTool(manager: lab.mcp, serverID: tavilyServerID, capture: capture)
        let session = try makeSessionSuppressingThinking(
            route: "search",
            tools: [tool],
            instructions: """
            You are a web search engine. Given a query, call tavily_search exactly once, then \
            report back the 5 results tavily_search returned. Do not answer from your own \
            knowledge and do not add commentary beyond the requested titles and URLs.\(formatInstruction)
            """,
            includeMCPTools: false)
        return (session, capture)
    }

    /// `effort: .off` is what actually suppresses a Qwen3-family model's `<think>…</think>` block
    /// (confirmed live: it was leaking straight into the Summarize output). As of SDK 1.0.0-RC.1
    /// this is a documented no-throw preference — a model that always reasons (DeepSeek-R1 and its
    /// distills) just keeps reasoning instead of failing the turn, so the try/catch fallback an
    /// earlier SDK version needed here is gone. (`ModelCapabilities.reasoningToggle` from
    /// `capabilityProbe(_:)` is available if a caller needs to know ahead of time whether `.off`
    /// will actually take effect — not needed here since we only use it best-effort.)
    private func makeSessionSuppressingThinking(route: RouteName, tools: [any Tool] = [], instructions: String, includeMCPTools: Bool) throws -> LocalLMLabSession {
        try lab.makeSession(route: route, tools: tools, instructions: instructions, includeMCPTools: includeMCPTools, options: .init(effort: .off))
    }

    /// Up to 2 full attempts, each running to completion (including cancelling its own event
    /// watcher) before the next starts — deliberately a loop, not recursion, so two attempts
    /// never watch `session.events` concurrently. Returns the links plus whatever query
    /// `TavilySearchTool` actually captured, so the UI can show what was really searched instead
    /// of just repeating the user's literal input.
    private func search(query: String, using session: LocalLMLabSession, capture: SearchQueryCapture, supportsGuidedGeneration: Bool) async throws -> (links: [SearchResultLink], searchQuery: String?) {
        var lastError: Error = SearchParseError.toolNotCalled
        for attempt in 0..<2 {
            do {
                let links = try await attemptSearch(query: query, using: session, supportsGuidedGeneration: supportsGuidedGeneration)
                return (links, await capture.query)
            } catch {
                lastError = error
                if attempt == 1 { throw error }
            }
        }
        throw lastError
    }

    private func attemptSearch(query: String, using session: LocalLMLabSession, supportsGuidedGeneration: Bool) async throws -> [SearchResultLink] {
        // Confirmed live: a model can answer a search query straight from its own training data
        // instead of calling tavily_search at all, despite explicit instructions not to (Qwen3,
        // Gemma, and Granite all did this for "who founded Yahoo?"). Watch the session's own
        // event stream for the tool actually starting, rather than trusting that a
        // plausible-looking response means it searched.
        var toolWasCalled = false
        let watcher = Task {
            for await event in session.events {
                if case .toolCallStarted(_, let name, _) = event, name == "tavily_search" {
                    toolWasCalled = true
                }
            }
        }
        defer { watcher.cancel() }

        if supportsGuidedGeneration {
            do {
                let response = try await session.languageModelSession.respond(to: query, generating: SearchResults.self)
                guard toolWasCalled else { throw SearchParseError.toolNotCalled }
                return response.content.pages.map { SearchResultLink(title: $0.title, url: $0.url, snippet: $0.snippet) }
            } catch {
                // Apple's on-device guardrail can intercept a turn about a public figure/name
                // after the model already produced a fully valid SearchResults payload — the
                // session then throws instead of returning, but the JSON survives in the error's
                // own description (confirmed live: a "Muhammad Ali" search threw "The model
                // declined to respond: {...5 real results...}"). Recover it rather than dead-end
                // a turn that actually worked. (A recovered payload implies the tool did run —
                // those are Tavily's own real results embedded in the decline text.)
                if let recovered = await Self.recoverPages(from: error) { return recovered }
                throw error
            }
        } else {
            // No structured-output support on this model (see searchCapability(_:)) — a plain
            // response.content String, parsed leniently for (title, url) pairs rather than
            // relying on the model to hit an exact format every time.
            let response = try await session.languageModelSession.respond(to: query)
            let links = Self.parsePlainTextLinks(response.content)
            guard toolWasCalled, !links.isEmpty else {
                throw toolWasCalled ? SearchParseError.noResultsParsed(rawText: response.content) : SearchParseError.toolNotCalled
            }
            return links
        }
    }

    enum SearchParseError: LocalizedError {
        case noResultsParsed(rawText: String)
        case toolNotCalled
        var errorDescription: String? {
            switch self {
            case .noResultsParsed(let rawText):
                return "Couldn't find any links in the model's response: \(rawText)"
            case .toolNotCalled:
                return "The model answered from its own knowledge instead of searching. Try again, or pick a different model."
            }
        }
    }

    /// Extracts (title, url) pairs from an unstructured model response — used when the selected
    /// model has no guided-generation support to enforce a schema. Scans line by line for a URL
    /// and takes the text before it (minus numbering/bullets) as the title, rather than requiring
    /// the exact "Title — URL" format the instructions ask for, since a small model won't always
    /// hit it precisely.
    private static func parsePlainTextLinks(_ text: String) -> [SearchResultLink] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { rawLine in
            let line = String(rawLine)
            guard let urlRange = line.range(of: #"https?://\S+"#, options: .regularExpression) else { return nil }
            let url = line[urlRange].trimmingCharacters(in: CharacterSet(charactersIn: ".,)]}\"'"))
            var title = line[line.startIndex..<urlRange.lowerBound]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "0123456789.-–—|:) \t"))
            if title.isEmpty { title = url }
            return SearchResultLink(title: title, url: url)
        }
    }

    private struct RawPage: Decodable { let title: String; let url: String; let snippet: String? }
    private struct RawSearchResults: Decodable { let pages: [RawPage] }

    private static func recoverPages(from error: Error) async -> [SearchResultLink]? {
        let description = await GenerationErrorDescription.describe(error)
        if let strict = recoverPagesStrict(description) { return strict }
        return recoverPagesLeniently(description)
    }

    /// The common case: the embedded payload is valid JSON.
    private static func recoverPagesStrict(_ description: String) -> [SearchResultLink]? {
        guard let start = description.firstIndex(of: "{"),
              let end = description.lastIndex(of: "}"),
              start < end else { return nil }
        let json = description[start...end]
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(RawSearchResults.self, from: data) else { return nil }
        return decoded.pages.map { SearchResultLink(title: $0.title, url: $0.url, snippet: $0.snippet ?? "") }
    }

    /// Confirmed live: the guardrail-declined path sometimes drops the quote(s) around a url
    /// value (`"url": https://…` instead of `"url": "https://…"`), inconsistently — sometimes
    /// missing the opening quote, sometimes both — which breaks strict JSON parsing outright.
    /// Pull (title, url) pairs out with a permissive regex instead of requiring well-formed JSON.
    private static func recoverPagesLeniently(_ description: String) -> [SearchResultLink]? {
        guard let regex = try? NSRegularExpression(
            pattern: #""title"\s*:\s*"([^"]*)"\s*,\s*"url"\s*:\s*"?(https?://[^\s",}]+)"?"#
        ) else { return nil }
        let ns = description as NSString
        let matches = regex.matches(in: description, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }
        return matches.map {
            SearchResultLink(title: ns.substring(with: $0.range(at: 1)), url: ns.substring(with: $0.range(at: 2)))
        }
    }

    private func appendTurn(query: String, searchQuery: String?, links: [SearchResultLink], toThreadID threadID: UUID) {
        guard let idx = threads.firstIndex(where: { $0.id == threadID }) else { return }
        threads[idx].turns.append(SearchTurn(query: query, searchQuery: searchQuery, links: links, timestamp: Date()))
        HistoryStore.save(threads)
    }

    // MARK: - Summarize

    /// Pure text synthesis over snippets already in hand — no tool call, so none of the
    /// tool-calling reliability problems `search(...)` has to work around apply here. Finds the
    /// turn across every thread rather than taking a thread id, since callers only ever have the
    /// turn on screen.
    func summarize(turnID: UUID) async {
        guard let threadIdx = threads.firstIndex(where: { $0.turns.contains(where: { $0.id == turnID }) }),
              let turnIdx = threads[threadIdx].turns.firstIndex(where: { $0.id == turnID }),
              !summarizingTurnIDs.contains(turnID) else { return }
        let turn = threads[threadIdx].turns[turnIdx]
        summarizingTurnIDs.insert(turnID)
        defer { summarizingTurnIDs.remove(turnID) }

        // First time the (possibly still-default) summary model is used: it may not be
        // downloaded yet. Show progress, let the user cancel — cancelling just means no summary
        // this time, not an error.
        //
        // `mlxProvider.installed` alone isn't trustworthy here: confirmed live that right after a
        // cancelled download (only a few MB of metadata on disk, not the real weights),
        // `installed` already lists the repo as present. Trusting that made this gate skip
        // `downloadSummaryModel()` entirely on the very next attempt — no `pendingDownload`, so no
        // sheet — while MLX's own lazy weight-fetch during session/inference setup silently pulled
        // the real ~2GB in the background with zero progress UI. `incompleteDownloadRepoIDs` is our
        // own record of "the last attempt for this repo didn't finish," independent of whatever the
        // SDK's bookkeeping says, so a retry always goes through the tracked path again.
        if summaryModel.scheme == "mlx",
           !mlxProvider.installed.contains(where: { $0.id == summaryModel }) || incompleteDownloadRepoIDs.contains(summaryModel.rest) {
            guard await downloadSummaryModel() else { return }
        }

        let sources = turn.links.enumerated().map { index, link in
            "\(index + 1). \(link.title)\(link.snippet.isEmpty ? "" : " — \(link.snippet)")"
        }.joined(separator: "\n")

        do {
            lab.models.route("summary", to: summaryModel)
            let session = try makeSessionSuppressingThinking(
                route: "summary",
                instructions: "Summarize the given web search results in 2-3 sentences, as one plain paragraph. No headers, no list, no commentary about the sources themselves.",
                includeMCPTools: false)
            let response = try await session.languageModelSession.respond(
                to: "Search results for \"\(turn.searchQuery ?? turn.query)\":\n\(sources)")
            threads[threadIdx].turns[turnIdx].summary = Self.stripThinkingBlock(response.content)
            HistoryStore.save(threads)
        } catch {
            lastError = await GenerationErrorDescription.describe(error)
        }
    }

    /// Drives `pendingDownload` (a progress sheet in ChatView) while `mlxProvider.download(_:)`
    /// runs. Earlier SDK versions had no way to actually cancel an in-flight download — we wrapped
    /// consumption in a `Task` and cancelled that, which stopped OUR wait but not the real
    /// background transfer (confirmed live: it kept running and finished on its own, so the very
    /// next Summarize attempt just found the model already installed). As of SDK 1.0.0-RC.1,
    /// `cancelDownload(_:)` aborts the real transfer — the stream below then throws instead of
    /// yielding `.completed`, which `isUserCancelled` distinguishes from a genuine failure so we
    /// don't show an error for a cancel the user asked for.
    private var isUserCancelledDownload = false

    /// Repo IDs whose most recent download attempt didn't reach `.completed` — see the comment at
    /// the `summarize()` gate above for why this exists alongside (not instead of)
    /// `mlxProvider.installed`.
    private var incompleteDownloadRepoIDs: Set<String> = []

    private func downloadSummaryModel() async -> Bool {
        let repoID = summaryModel.rest
        isUserCancelledDownload = false
        pendingDownload = PendingDownload(repoID: repoID)
        defer { pendingDownload = nil }
        do {
            for try await event in mlxProvider.download(repoID) {
                if case .progress(_, _, let fraction) = event {
                    pendingDownload?.fraction = fraction
                } else if case .completed = event {
                    incompleteDownloadRepoIDs.remove(repoID)
                    return true
                }
            }
            incompleteDownloadRepoIDs.insert(repoID)
            return false
        } catch {
            incompleteDownloadRepoIDs.insert(repoID)
            if !isUserCancelledDownload {
                lastError = await GenerationErrorDescription.describe(error)
            }
            return false
        }
    }

    func cancelPendingDownload() {
        isUserCancelledDownload = true
        mlxProvider.cancelDownload(summaryModel.rest)
    }

    /// Belt-and-suspenders for models that always reason (DeepSeek-R1 and its distills):
    /// `effort: .off` can't suppress their `<think>` block at all — `makeSessionSuppressingThinking`
    /// falls back to no effort option for those rather than failing, which means the tag can still
    /// reach us. Strip it from the visible text rather than showing the model's internal monologue.
    private static func stripThinkingBlock(_ text: String) -> String {
        guard let range = text.range(of: "</think>") else { return text }
        return String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

}
