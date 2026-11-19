import AppKit
import SwiftUI

// Markdown for a chat's replies, block by block: headings, paragraphs, lists, block quotes, rules,
// fenced code (with Copy) and pipe tables. Inline syntax (bold, italic, code, links) goes through
// AttributedString. Streaming text re-parses each update; an unclosed fence renders as code so
// far. From ChatAgain; sizes and colours come from `MarkdownStyle`.

/// One block of a Markdown text, as `MarkdownParser.parse` reads it.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(items: [String])
    case numbered(start: Int, items: [String])
    case quote(String)
    case code(language: String, text: String)
    case table(header: [String], rows: [[String]])
    case rule
}

public enum MarkdownParser {
    /// The blocks of `text`, in order. Never fails: anything it doesn't recognise is a paragraph.
    public static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var i = 0
        var paragraph: [String] = []

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let fence = String(trimmed.prefix(3))
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i])
                    i += 1
                }
                blocks.append(.code(language: language, text: code.joined(separator: "\n")))
                i += 1
                continue
            }
            if trimmed.isEmpty {
                flush()
                i += 1
                continue
            }
            if let level = headingLevel(trimmed) {
                flush()
                blocks.append(.heading(level: level, text: String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)))
                i += 1
                continue
            }
            if ["---", "***", "___"].contains(trimmed.replacingOccurrences(of: " ", with: "")) && paragraph.isEmpty {
                blocks.append(.rule)
                i += 1
                continue
            }
            // A pipe table: a header row, then a |---|---| separator.
            if trimmed.hasPrefix("|") || trimmed.contains(" | "), i + 1 < lines.count, isSeparator(lines[i + 1]) {
                flush()
                let header = cells(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(cells(lines[i]))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }
            if let item = bulletItem(trimmed) {
                flush()
                var items = [item]
                i += 1
                while i < lines.count {
                    let next = lines[i].trimmingCharacters(in: .whitespaces)
                    if let more = bulletItem(next) { items.append(more) }
                    else if !next.isEmpty, lines[i].hasPrefix("  ") { items[items.count - 1] += "\n" + next }
                    else { break }
                    i += 1
                }
                blocks.append(.bullet(items: items))
                continue
            }
            if let (start, item) = numberedItem(trimmed) {
                flush()
                var items = [item]
                i += 1
                while i < lines.count {
                    let next = lines[i].trimmingCharacters(in: .whitespaces)
                    if let (_, more) = numberedItem(next) { items.append(more) }
                    else if !next.isEmpty, lines[i].hasPrefix("  ") { items[items.count - 1] += "\n" + next }
                    else { break }
                    i += 1
                }
                blocks.append(.numbered(start: start, items: items))
                continue
            }
            if trimmed.hasPrefix(">") {
                flush()
                var quoted: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quoted.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }
            paragraph.append(line)
            i += 1
        }
        flush()
        return blocks
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func bulletItem(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) { return String(line.dropFirst(2)) }
        return nil
    }

    private static func numberedItem(_ line: String) -> (Int, String)? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count < 4 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (Int(digits) ?? 1, String(rest.dropFirst(2)))
    }

    private static func isSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") || t.hasPrefix("-") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
    }

    static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// `text`'s inline Markdown (bold, italic, code, links) as an attributed string, inline code in
    /// `style`'s code font and background.
    public static func inline(_ text: String, style: MarkdownStyle = .standard) -> AttributedString {
        var styled = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        // A size smaller than the text, on a light background: at the body's size and regular
        // weight, inline code read as heavier than the light text around it.
        for run in styled.runs where run.inlinePresentationIntent?.contains(.code) == true {
            styled[run.range].font = style.inlineCode
            styled[run.range].backgroundColor = style.inlineCodeBackground
        }
        return styled
    }
}

/// Sizes and colours for `MarkdownView`. Set one for a view tree with `.markdownStyle(_:)`.
public struct MarkdownStyle: Sendable {
    public var body: Font
    /// Set on the text itself, so buttons among it keep their tint.
    public var text: Color
    /// Extra space between wrapped lines.
    public var lineSpacing: CGFloat
    /// Between the items of a list.
    public var listSpacing: CGFloat
    public var inlineCode: Font
    public var inlineCodeBackground: Color
    public var code: Font
    public var table: Font
    /// Heading sizes for levels 1, 2 and 3 and below; headings are semibold.
    public var headingSizes: (CGFloat, CGFloat, CGFloat)

    public init(body: Font, text: Color, lineSpacing: CGFloat, listSpacing: CGFloat, inlineCode: Font,
                inlineCodeBackground: Color, code: Font, table: Font, headingSizes: (CGFloat, CGFloat, CGFloat)) {
        self.body = body
        self.text = text
        self.lineSpacing = lineSpacing
        self.listSpacing = listSpacing
        self.inlineCode = inlineCode
        self.inlineCodeBackground = inlineCodeBackground
        self.code = code
        self.table = table
        self.headingSizes = headingSizes
    }

    public func heading(_ level: Int) -> Font {
        .system(size: level == 1 ? headingSizes.0 : level == 2 ? headingSizes.1 : headingSizes.2, weight: .semibold)
    }

    /// Reading-sized text: 16 pt Light body (regular weight reads as bold at this size), near-black
    /// (#0E0E0E) or near-white, a line height of about 1.6, headings close to the body size.
    public static let standard = MarkdownStyle(
        body: .system(size: 16, weight: .light),
        text: Color(nsColor: NSColor(name: "LocalLMLabMarkdownText") { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0.93, green: 0.93, blue: 0.91, alpha: 1)
                : NSColor(srgbRed: 0.055, green: 0.055, blue: 0.055, alpha: 1)
        }),
        lineSpacing: 6,
        listSpacing: 8,
        inlineCode: .system(size: 14, design: .monospaced),
        inlineCodeBackground: Color.gray.opacity(0.12),
        code: .system(size: 14, design: .monospaced),
        table: .system(size: 15, weight: .light),
        headingSizes: (20, 18, 16))
}

private struct MarkdownStyleKey: EnvironmentKey {
    static let defaultValue = MarkdownStyle.standard
}

extension EnvironmentValues {
    public var markdownStyle: MarkdownStyle {
        get { self[MarkdownStyleKey.self] }
        set { self[MarkdownStyleKey.self] = newValue }
    }
}

extension View {
    /// The style `MarkdownView`s in this view use.
    public func markdownStyle(_ style: MarkdownStyle) -> some View {
        environment(\.markdownStyle, style)
    }
}

/// A Markdown text, block by block. Suits a reply that's still streaming: each update re-parses.
public struct MarkdownView: View {
    let text: String
    let limit: Int?
    @State private var expanded = false
    @Environment(\.markdownStyle) private var style

    /// `limit`: past this many characters, show only the start (cut at a paragraph) until the user
    /// asks for the rest. Nil shows everything, as for a reply still streaming.
    public init(text: String, limit: Int? = nil) {
        self.text = text
        self.limit = limit
    }

    public var body: some View {
        let cut = expanded ? nil : limit.flatMap { cutPoint(at: $0) }
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownParser.parse(cut.map { String(text[..<$0]) } ?? text).enumerated()), id: \.offset) { _, block in
                BlockView(block: block, style: style)
            }
            if cut != nil || expanded {
                Button(expanded ? "Show less" : "Show the rest (\(text.count.formatted()) characters in all)") { expanded.toggle() }
                    .buttonStyle(.borderless).font(.caption)
            }
        }
        .lineSpacing(style.lineSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Where to cut a text longer than `limit`: the last blank line before it, else the limit.
    private func cutPoint(at limit: Int) -> String.Index? {
        guard text.count > limit else { return nil }
        let end = text.index(text.startIndex, offsetBy: limit)
        return text.range(of: "\n\n", options: .backwards, range: text.startIndex..<end)?.lowerBound ?? end
    }
}

private struct BlockView: View {
    let block: MarkdownBlock
    let style: MarkdownStyle

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(MarkdownParser.inline(text, style: style))
                .font(style.heading(level))
                .foregroundStyle(style.text)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Text(MarkdownParser.inline(text, style: style)).foregroundStyle(style.text).textSelection(.enabled)
        case .bullet(let items):
            VStack(alignment: .leading, spacing: style.listSpacing) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        Text(MarkdownParser.inline(item, style: style)).foregroundStyle(style.text).textSelection(.enabled)
                    }
                }
            }
        case .numbered(let start, let items):
            VStack(alignment: .leading, spacing: style.listSpacing) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(start + index).").foregroundStyle(.secondary).monospacedDigit()
                        Text(MarkdownParser.inline(item, style: style)).foregroundStyle(style.text).textSelection(.enabled)
                    }
                }
            }
        case .quote(let text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(.tertiary).frame(width: 3)
                Text(MarkdownParser.inline(text, style: style)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        case .code(let language, let text):
            MarkdownCodeBlock(language: language, text: text)
        case .table(let header, let rows):
            MarkdownTableBlock(header: header, rows: rows)
        case .rule:
            Divider()
        }
    }
}

/// A fenced code block with its language and a Copy button.
public struct MarkdownCodeBlock: View {
    let language: String
    let text: String
    @State private var copied = false
    @Environment(\.markdownStyle) private var style

    public init(language: String, text: String) {
        self.language = language
        self.text = text
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc").font(.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Copy code")
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            Divider()
            ScrollView(.horizontal) {
                Text(text).font(style.code).foregroundStyle(style.text).textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }
}

/// A table: a bold header row, then the rows, each cell's inline Markdown rendered.
public struct MarkdownTableBlock: View {
    let header: [String]
    let rows: [[String]]
    @Environment(\.markdownStyle) private var style

    public init(header: [String], rows: [[String]]) {
        self.header = header
        self.rows = rows
    }

    public var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(MarkdownParser.inline(cell, style: style)).font(style.table.bold()).foregroundStyle(style.text)
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0..<header.count, id: \.self) { column in
                            Text(MarkdownParser.inline(column < row.count ? row[column] : "", style: style)).font(style.table)
                                .foregroundStyle(style.text).textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(10)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }
}
