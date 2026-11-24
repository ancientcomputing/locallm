import AppKit
import ImageIO
import LocalLMLabSDKCore
import SwiftUI
import UniformTypeIdentifiers

// The message box under a chat: text, attachments (picked, dropped, pasted, or
// imported from an iPhone), editing the last message, Send and Stop. An app fills its slots: a
// banner above the box (ChatAgain's quota), the row under it (the model's name, ChatAgain's status
// lights), and the attachment types it accepts.

public struct ChatComposer<Banner: View, Leading: View, ModelLabel: View>: View {
    let controller: ChatController
    let isEnabled: Bool
    let acceptedTypes: [UTType]
    let send: (String, [URL]) -> Void
    let addSource: () -> Void
    let banner: () -> Banner
    let leading: () -> Leading
    let modelLabel: () -> ModelLabel
    @State private var text = ""
    @State private var attachments: [URL] = []
    /// Files that couldn't be attached, and why (`ChatAttachments.unreadable`), until dismissed or the next attach.
    @State private var refused: [String] = []
    @State private var picking = false
    /// The "Attach Shared Content…" picker: content an MCP server shares.
    @State private var choosingShared = false
    /// "Use a Prompt…", and the prompt whose arguments are being filled in.
    @State private var choosingPrompt = false
    @State private var fillingPrompt: ChatPromptChoice?
    /// The prompt the message box was filled from, for the message's "From …" line, until it's sent or cleared.
    @State private var promptSource: String?
    /// Attachments read from a source, by file: its name for the chip ("Everything › features.md").
    @State private var attachmentSources: [URL: String] = [:]
    @State private var pasteMonitor: Any?
    @FocusState private var focused: Bool
    @Environment(\.chatComposerPlaceholder) private var placeholder

    /// Text, PDF, CSV, TSV, JSON, Markdown, HTML, RTF, Word (.docx) and images. Images select the Images plug-in by their type,
    /// as a PDF selects Documents, or go to a model that sees them.
    public static var standardTypes: [UTType] {
        var types: [UTType] = [.pdf, .plainText, .commaSeparatedText, .tabSeparatedText, .json,
                               UTType(filenameExtension: "md") ?? .plainText, .html, .rtf, .image]
        if let docx = UTType(filenameExtension: "docx") { types.append(docx) }
        return types
    }

    /// - Parameters:
    ///   - isEnabled: whether a message can be sent now, besides a turn running (ChatAgain: quota left).
    ///   - send: the app's send (it may start a chat first); `controller.send` by default.
    ///   - addSource: no longer used, kept so existing callers build. Adding a tool source is the app's toolbar
    ///     (the Tool Sources sheet); the in-chat card still appears when the chat offers it (a server address in a
    ///     message, the pasted-key card). The composer's Add Tool Source… repeated the toolbar (2026-10-25).
    ///   - banner: above the message box.
    ///   - leading: under the box, on the left.
    ///   - modelLabel: under the box, on the right (`ChatModelLabel`).
    public init(controller: ChatController, isEnabled: Bool = true, acceptedTypes: [UTType] = Self.standardTypes,
                send: ((String, [URL]) -> Void)? = nil, addSource: (() -> Void)? = nil,
                @ViewBuilder banner: @escaping () -> Banner, @ViewBuilder leading: @escaping () -> Leading,
                @ViewBuilder modelLabel: @escaping () -> ModelLabel) {
        self.controller = controller
        self.isEnabled = isEnabled
        self.acceptedTypes = acceptedTypes
        self.send = send ?? { [controller] in controller.send($0, attachments: $1) }
        self.addSource = addSource ?? { [controller] in _ = controller.showAddSource() }
        self.banner = banner
        self.leading = leading
        self.modelLabel = modelLabel
    }

    private var acceptsImages: Bool { acceptedTypes.contains { $0.conforms(to: .image) } }
    private var dropTypes: [UTType] { acceptsImages ? [.fileURL, .image] : [.fileURL] }
    private var acceptsPDF: Bool { acceptedTypes.contains { $0.conforms(to: .pdf) } }
    /// Import from iPhone's Scan Documents (PDF) and Add Sketch (PNG), for an app outside the sandbox: there SwiftUI's
    /// importer gets them. In the sandbox it never does (Cocoa error 66563), so they're left to the message field,
    /// which takes only Take Photo (TIFF), and stay greyed out rather than fail (2026-10-30).
    private var importTypes: [UTType] {
        guard !ProcessInfo.processInfo.environment.keys.contains("APP_SANDBOX_CONTAINER_ID") else { return [] }
        return (acceptsImages ? [.image, .png, .jpeg, .tiff, .heic] : []) + (acceptsPDF ? [.pdf] : [])
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            banner()
            // The message box: a rounded field, as in the Claude app, with the status row below it.
            VStack(alignment: .leading, spacing: 6) {
                if controller.editingLastMessage != nil {
                    HStack {
                        Label("Editing your last message: sending replaces it and its reply.", systemImage: "pencil").font(.caption)
                        Spacer()
                        Button("Cancel") { controller.editingLastMessage = nil; text = "" }.buttonStyle(.borderless).font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                ForEach(refused, id: \.self) { why in
                    HStack(alignment: .firstTextBaseline) {
                        Label(why, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button { refused.removeAll { $0 == why } } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).accessibilityLabel("Dismiss")
                    }
                }
                if !attachments.isEmpty {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(attachments, id: \.self) { url in
                                HStack(spacing: 4) {
                                    if ChatAttachmentThumbnail.isImage(url.lastPathComponent) {
                                        ChatAttachmentThumbnail(url: url, height: 18)
                                    } else {
                                        Image(systemName: "doc")
                                    }
                                    Text(attachmentSources[url].map { "\($0) › \(url.lastPathComponent)" } ?? url.lastPathComponent)
                                        .lineLimit(1)
                                    Button { attachments.removeAll { $0 == url } } label: { Image(systemName: "xmark.circle.fill") }
                                        .buttonStyle(.borderless).accessibilityLabel("Remove \(url.lastPathComponent)")
                                }
                                .font(.caption)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.quaternary.opacity(0.6), in: Capsule())
                            }
                        }
                    }
                }
                // `/` at the start of the box: the sources' prompts, filtered by what follows.
                if text.hasPrefix("/"), !text.contains("\n") {
                    ChatPromptMatches(manager: controller.lab.mcp, query: String(text.dropFirst())) { choice in
                        text = ""
                        use(choice)
                    }
                }
                HStack(alignment: .bottom, spacing: 8) {
                    // The server list isn't observable: also look again when the chat's cards change (a source added
                    // from an add-source card), not only when something else redraws the box.
                    let _ = controller.cards.count
                    let shares = !MCPContentReader.attachable(in: controller.lab.mcp).isEmpty
                    let prompts = !MCPContentReader.prompts(in: controller.lab.mcp).isEmpty
                    if !shares && !prompts {
                        Button { picking = true } label: {
                            Image(systemName: "paperclip").font(.title2)
                        }
                        .buttonStyle(.borderless)
                        .help("Attach Files…")
                        .accessibilityLabel("Attach files")
                    } else {
                        // A source shares content or prompts: files, or those, under a heading that says where they
                        // come from. "Tool sources" is what both apps call MCP servers.
                        Menu {
                            Button("Files…") { picking = true }
                            Section("From Your Tool Sources") {
                                if shares { Button("Attach Shared Content…") { choosingShared = true } }
                                if prompts { Button("Use a Prompt…") { choosingPrompt = true } }
                            }
                        } label: {
                            Image(systemName: "paperclip").font(.title2)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Attach")
                        .accessibilityLabel("Attach")
                    }
                    TextField(placeholder ?? "Message", text: $text, axis: .vertical)
                        .lineLimit(1...8)
                        .textFieldStyle(.plain)
                        .font(MarkdownStyle.standard.body)
                        .foregroundStyle(MarkdownStyle.standard.text)
                        .focused($focused)
                        .onSubmit(submit)
                        // File › Import from iPhone (`ImportFromDevicesCommands` in the app's commands): a photo,
                        // sketch or document scan from Continuity Camera arrives here as an attachment.
                        .background(MessageFieldImports(takes: acceptsImages || acceptsPDF) { add($0) })
                    if controller.status == .responding {
                        Button { controller.stop() } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                            .buttonStyle(.plain).accessibilityLabel("Stop")
                    } else {
                        Button(action: submit) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                            .buttonStyle(.plain)
                            .disabled(!canSend)
                            .help(placeholder ?? "Send")
                            .keyboardShortcut(.return, modifiers: .command)
                            .accessibilityLabel("Send")
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
            .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .onTapGesture { focused = true }
            // On the left, the app's own (ChatAgain's status lights); on the right, the model that
            // answers, as the Claude app shows its model under the message box.
            HStack {
                leading()
                Spacer()
                modelLabel()
            }
        }
        .padding(12)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
        .onAppear { focused = true }
        // A long paste becomes an attachment as it happens, as in the Claude app (doc 41 B11): the field
        // keeps what was typed around it. `ChatController.send` does the same at send time for a
        // message that grew long some other way.
        .onChange(of: text) { old, new in
            guard let pasted = ChatPastedAttachments.longInsertion(from: old, to: new,
                                                                   limit: controller.configuration.longMessageCharacters),
                  let url = ChatPastedAttachments.saveText(pasted.inserted) else { return }
            add([url])
            text = pasted.remaining
        }
        .onChange(of: controller.editingLastMessage) { _, editing in
            if let editing {
                text = ChatAttachments.text(of: editing)
                focused = true
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: acceptedTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { add(urls) }
        }
        .sheet(isPresented: $choosingShared) {
            ChatSharedContentPicker(manager: controller.lab.mcp) { file, source in
                attachmentSources[file] = source
                add([file])
            }
        }
        .sheet(isPresented: $choosingPrompt) {
            ChatPromptPicker(manager: controller.lab.mcp, query: "") { choice in
                choosingPrompt = false
                use(choice)
            }
        }
        .sheet(item: $fillingPrompt) { choice in
            ChatPromptForm(choice: choice, manager: controller.lab.mcp) { fill in
                fillingPrompt = nil
                take(fill, from: choice)
            }
        }
        .onDrop(of: dropTypes, isTargeted: nil) { providers in
            attach(providers)
            return true
        }
        .onPasteCommand(of: dropTypes) { attach($0) }
        .importsItemProviders(importTypes) { providers in
            attach(providers)
            return true
        }
        // ⌘V in the message field: the field itself only takes text, so a copied file or image
        // (a screenshot copied to the clipboard, a file copied in Finder) is attached instead.
        .onAppear {
            let images = acceptsImages
            pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard focused, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      event.charactersIgnoringModifiers == "v" else { return event }
                let pasted = ChatPastedAttachments.fromPasteboard(.general, images: images)
                guard !pasted.isEmpty else { return event }
                add(pasted)
                return nil
            }
        }
        .onDisappear {
            if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
            pasteMonitor = nil
        }
    }

    /// Every way in (picker, drop, paste, import) comes here: files nothing can read are refused, with why.
    private func add(_ urls: [URL]) {
        refused = []
        for url in urls {
            if let why = ChatAttachments.unreadable(url, accepted: acceptedTypes) { refused.append(why) } else { attachments.append(url) }
        }
    }

    /// Files by their URL; images with no file (dragged from a browser or Photos, a sketch from an iPhone) are
    /// saved as PNGs first, and a scan from an iPhone as a PDF, since attachments are copied into the chat's
    /// folder by name.
    private func attach(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in add([url]) } }
                }
            } else if acceptsPDF, provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.pdf.identifier) { data, _ in
                    guard let data, let url = ChatPastedAttachments.savePDF(data) else { return }
                    Task { @MainActor in add([url]) }
                }
            } else if acceptsImages, provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data, let url = ChatPastedAttachments.savePNG(data) else { return }
                    Task { @MainActor in add([url]) }
                }
            }
        }
    }

    private var canSend: Bool {
        isEnabled && controller.status == .ready
            && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    private func submit() {
        guard canSend else { return }
        // A message filled from a prompt starts with its "[From …]" line, which the chat shows as a label.
        send(promptSource.map { "\(ChatAttachments.promptPrefix)\($0)]\n" + text } ?? text, attachments)
        text = ""
        attachments = []
        refused = []
        promptSource = nil
        attachmentSources = [:]
    }

    /// A prompt picked from the `/` menu or "Use a Prompt…": its form when it has arguments, else straight in.
    private func use(_ choice: ChatPromptChoice) {
        if choice.prompt.arguments.isEmpty {
            Task {
                switch await MCPContentReader.fill(prompt: choice.prompt.name, server: choice.server, arguments: [:],
                                                   manager: controller.lab.mcp) {
                case .success(let fill): take(fill, from: choice)
                case .failure(let error): refused = [error.message]
                }
            }
        } else {
            fillingPrompt = choice
        }
    }

    /// A filled prompt into the message box, to read, edit and send (never sent on its own).
    private func take(_ fill: MCPContentReader.PromptFill, from choice: ChatPromptChoice) {
        text = fill.text
        add(fill.files)
        refused += fill.notes
        promptSource = "\(choice.sourceName): \(choice.prompt.title ?? choice.prompt.name)"
        focused = true
    }
}

public extension ChatComposer where Banner == EmptyView, Leading == EmptyView {
    /// A composer with no banner and nothing on the left under the box.
    init(controller: ChatController, isEnabled: Bool = true, acceptedTypes: [UTType] = Self.standardTypes,
         send: ((String, [URL]) -> Void)? = nil, addSource: (() -> Void)? = nil,
         @ViewBuilder modelLabel: @escaping () -> ModelLabel) {
        self.init(controller: controller, isEnabled: isEnabled, acceptedTypes: acceptedTypes, send: send, addSource: addSource,
                  banner: { EmptyView() }, leading: { EmptyView() }, modelLabel: modelLabel)
    }
}

/// The model that answers, under the message box: its name, and a detail such as its quantization.
public struct ChatModelLabel: View {
    let name: String
    let detail: String?
    let help: String?

    public init(_ name: String, detail: String? = nil, help: String? = nil) {
        self.name = name
        self.detail = detail
        self.help = help
    }

    public var body: some View {
        HStack(spacing: 5) {
            Text(name).foregroundStyle(MarkdownStyle.standard.text.opacity(0.75))
            if let detail { Text(detail).foregroundStyle(.secondary) }
        }
        .font(.system(size: 14))
        .help(help ?? name)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Model: \(([name] + (detail.map { [$0] } ?? [])).joined(separator: " · "))")
    }
}

/// A small preview of an attached image, decoded off the main thread at the size shown (a phone
/// photo is 10–20 MB). The height is fixed before the image loads, so the transcript's rows keep
/// their height.
public struct ChatAttachmentThumbnail: View {
    let url: URL
    let height: CGFloat
    @State private var image: NSImage?

    public init(url: URL, height: CGFloat) {
        self.url = url
        self.height = height
    }

    public static func isImage(_ name: String) -> Bool {
        UTType(filenameExtension: (name as NSString).pathExtension)?.conforms(to: .image) ?? false
    }

    public var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: height > 40 ? 10 : 3).fill(.quaternary).aspectRatio(1, contentMode: .fit)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: height > 40 ? 10 : 3))
        .accessibilityLabel("Image \(url.lastPathComponent)")
        .task(id: url) {
            let pixels = height * (NSScreen.main?.backingScaleFactor ?? 2) * 2
            let url = url
            image = await Task.detached { Self.load(url, maxPixel: pixels) }.value
        }
    }

    nonisolated private static func load(_ url: URL, maxPixel: CGFloat) -> NSImage? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }
}

/// Files and images from the clipboard or a drop, as attachments.
public enum ChatPastedAttachments {
    /// File URLs if the clipboard has files; otherwise, with `images`, an image (a copied screenshot)
    /// saved as a PNG.
    public static func fromPasteboard(_ pasteboard: NSPasteboard, images: Bool = true) -> [URL] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls
        }
        guard images, let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff),
              let url = savePNG(data) else { return [] }
        return [url]
    }

    /// The text inserted between `old` and `new` (a paste), when it's longer than `limit`, and `new`
    /// without it.
    public static func longInsertion(from old: String, to new: String, limit: Int) -> (inserted: String, remaining: String)? {
        guard new.count - old.count > limit else { return nil }
        let prefix = old.commonPrefix(with: new).count
        let oldRest = old.dropFirst(prefix), newRest = new.dropFirst(prefix)
        var suffix = 0
        while suffix < oldRest.count, oldRest[oldRest.index(oldRest.endIndex, offsetBy: -suffix - 1)]
                == newRest[newRest.index(newRest.endIndex, offsetBy: -suffix - 1)] {
            suffix += 1
        }
        let inserted = String(newRest.dropLast(suffix))
        guard inserted.count > limit else { return nil }
        return (inserted, String(new.prefix(prefix)) + String(newRest.suffix(suffix)))
    }

    /// Writes a long pasted text as "Pasted text.txt" in a temporary folder; the chat copies it from there.
    public static func saveText(_ text: String) -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Pasted attachments/\(UUID().uuidString)", isDirectory: true)
        return ChatAttachments.savePasted(text, in: folder).map { folder.appendingPathComponent($0) }
    }

    /// Writes image data as "Pasted image <time>.png" in a temporary folder; the chat copies it from there.
    public static func savePNG(_ data: Data) -> URL? {
        guard let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return save(png, as: "Pasted image", extension: "png")
    }

    /// Writes a document scanned on an iPhone as "Scanned document <time>.pdf" in a temporary folder.
    public static func savePDF(_ data: Data) -> URL? {
        guard data.starts(with: Array("%PDF".utf8)) else { return nil }
        return save(data, as: "Scanned document", extension: "pdf")
    }

    /// Writes what File › Import from iPhone brought: a scan as a PDF, a photo or sketch as "Photo <time>" in its own
    /// format (`filename`'s extension: a JPEG stays a JPEG), or as a PNG when it has none. `nil` for anything else.
    public static func saveImported(_ data: Data, filename: String) -> URL? {
        if data.starts(with: Array("%PDF".utf8)) { return savePDF(data) }
        guard NSBitmapImageRep(data: data) != nil else { return nil }
        let ext = (filename as NSString).pathExtension.lowercased()
        guard let type = UTType(filenameExtension: ext), type.conforms(to: .image) else { return savePNG(data) }
        return save(data, as: "Photo", extension: ext)
    }

    /// Each in a folder of its own, as `saveText` does: two photos from one import, or two pastes in a second, had the
    /// same name, and the second overwrote the first (security review 2026-11-01, S7). The name stays the one the chat
    /// shows; `TemporaryFolders.sweep` removes these folders after a day.
    private static func save(_ data: Data, as name: String, extension ext: String) -> URL? {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pasted attachments/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = folder.appendingPathComponent("\(name) \(formatter.string(from: Date())).\(ext)")
        do { try data.write(to: url, options: .withoutOverwriting) } catch { return nil }
        return url
    }
}

/// File › Import from iPhone in the message field. macOS hands a Continuity Camera photo only to a focused text view
/// that takes pictures, as TextEdit's does; such a view takes Take Photo (TIFF), not Scan Documents (PDF) or Add Sketch
/// (PNG), which `ChatComposer.importTypes` covers outside the sandbox. In a sandboxed app (every Mac App Store app) a SwiftUI
/// importer (`importsItemProviders`) or a custom requestor is asked, says yes, and never gets it: Cocoa error 66563
/// (ChatAgain and sandboxed probes; it works unsandboxed). So while the message field has focus,
/// its field editor takes pictures, and whatever lands is taken out of the text and attached. AppKit sets the shared
/// field editor up again for each field it edits, so other fields stay plain text. Placed as the field's background,
/// to tell the message field from others.
private struct MessageFieldImports: NSViewRepresentable {
    let takes: Bool
    let attach: ([URL]) -> Void

    func makeNSView(context: Context) -> Watcher { Watcher() }

    func updateNSView(_ view: Watcher, context: Context) {
        view.takes = takes
        view.attach = attach
    }

    static func dismantleNSView(_ view: Watcher, coordinator: ()) { view.stop() }

    final class Watcher: NSView {
        var takes = false
        var attach: ([URL]) -> Void = { _ in }
        private var watching: NSObjectProtocol?
        private var editing: NSObjectProtocol?
        private weak var editor: NSTextView?
        /// Pictures just attached, by content: one landing is seen by more than one edit.
        private var recent: [Data: Date] = [:]

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            // Focus can move without an edit (a click, Tab, the app coming forward): checked as the window updates.
            watching = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
        }

        func stop() {
            release()
            if let watching { NotificationCenter.default.removeObserver(watching) }
            watching = nil
        }

        private func check() {
            // While the iPhone takes the photo, the window's "waiting for iPhone" popover has focus and the editor is
            // let go of; the photo still lands in it. So it's watched until text editing moves somewhere else.
            if editor != nil, takes, window != nil, !(window?.firstResponder is NSText) {
                return
            }
            guard takes, let window, let field = window.firstResponder as? NSTextView, field.isFieldEditor,
                  let control = field.delegate as? NSTextField, isMessageField(control) else {
                release()
                return
            }
            guard editor !== field || !field.importsGraphics else { return }
            release()
            editor = field
            field.isRichText = true
            field.importsGraphics = true
            guard let storage = field.textStorage else { return }
            editing = NotificationCenter.default.addObserver(forName: NSTextStorage.willProcessEditingNotification, object: storage, queue: nil) { [weak self] note in
                // The storage comes from the notification rather than being captured: NSTextStorage isn't Sendable.
                guard let storage = note.object as? NSTextStorage else { return }
                // Read now: the text field passes its text on as plain text, which drops the picture. Changed after:
                // the text can't change while an edit is being processed.
                let pictures = Self.pictures(in: storage)
                guard !pictures.isEmpty else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.takeOut(pictures) } }
            }
        }

        /// This view is the message field's background: they cover the same place.
        private func isMessageField(_ control: NSTextField) -> Bool {
            let mine = convert(bounds, to: nil)
            return control.convert(control.bounds, to: nil).contains(NSPoint(x: mine.midX, y: mine.midY))
        }

        private func release() {
            if let editing { NotificationCenter.default.removeObserver(editing) }
            editing = nil
            editor = nil
        }

        nonisolated private static func pictures(in storage: NSTextStorage) -> [(data: Data, name: String)] {
            var found: [(data: Data, name: String)] = []
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
                guard let attachment = value as? NSTextAttachment,
                      let data = attachment.fileWrapper?.regularFileContents ?? attachment.contents else { return }
                found.append((data, attachment.fileWrapper?.preferredFilename ?? ""))
            }
            return found
        }

        /// Pictures that landed in the text become attachments; the text is left as typed.
        private func takeOut(_ pictures: [(data: Data, name: String)]) {
            if let field = editor, let storage = field.textStorage {
                var ranges: [NSRange] = []
                storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                    if value != nil { ranges.append(range) }
                }
                for range in ranges.reversed() where field.shouldChangeText(in: range, replacementString: "") {
                    field.replaceCharacters(in: range, with: "")
                }
                if !ranges.isEmpty { field.didChangeText() }
            }
            let now = Date()
            recent = recent.filter { now.timeIntervalSince($0.value) < 5 }
            let new = pictures.filter { recent[$0.data] == nil }
            for picture in new { recent[picture.data] = now }
            let urls = new.compactMap { ChatPastedAttachments.saveImported($0.data, filename: $0.name) }
            if !urls.isEmpty { attach(urls) }
        }
    }
}

extension EnvironmentValues {
    @Entry var chatComposerPlaceholder: String? = nil
}

extension View {
    /// The message box's placeholder and its Send button's tooltip in place of "Message": why sending is off when
    /// the app turned it off (`isEnabled: false`), such as "You can send again at about 3:40 PM" while Private Cloud
    /// Compute's quota is used up. The box still took typing with only a grey Send button, and nothing on it said
    /// why (review, 2026-10-31). Nil: the default.
    public func chatComposerPlaceholder(_ text: String?) -> some View {
        environment(\.chatComposerPlaceholder, text)
    }
}
