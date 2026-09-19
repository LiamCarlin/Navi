import SwiftUI

/// A small, streaming-tolerant markdown block parser. Splits text into blocks
/// (headings, paragraphs, lists, code fences, quotes, rules); inline styling
/// (bold, italics, code spans, links) is delegated to `AttributedString(markdown:)`.
///
/// Designed to be re-run on every streamed chunk: it is linear in the text and
/// treats an unterminated code fence as an open code block.
enum LightMarkdown {
    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullets([String])
        case numbered(start: Int, items: [String])
        case code(language: String?, text: String)
        case quote(String)
        case rule
    }

    static func parse(_ source: String) -> [Block] {
        var blocks: [Block] = []
        var para: [String] = []
        var bullets: [String] = []
        var numbered: [String] = []
        var numberedStart = 1
        var quote: [String] = []

        func flushPara() {
            if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: " "))); para = [] }
        }
        func flushBullets() {
            if !bullets.isEmpty { blocks.append(.bullets(bullets)); bullets = [] }
        }
        func flushNumbered() {
            if !numbered.isEmpty { blocks.append(.numbered(start: numberedStart, items: numbered)); numbered = [] }
        }
        func flushQuote() {
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: " "))); quote = [] }
        }
        func flushAll() { flushPara(); flushBullets(); flushNumbered(); flushQuote() }

        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        var i = 0
        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)

            // Fenced code block (``` or ~~~), possibly unterminated while streaming.
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flushAll()
                let fence = String(line.prefix(3))
                let lang = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    body.append(lines[i]); i += 1
                }
                blocks.append(.code(language: lang.isEmpty ? nil : lang, text: body.joined(separator: "\n")))
                i += 1   // skip closing fence (or run past EOF)
                continue
            }

            if line.isEmpty {
                flushAll(); i += 1; continue
            }

            // Horizontal rule
            let compact = line.filter { $0 != " " }
            if compact.count >= 3, let c = compact.first, "-*_".contains(c), compact.allSatisfy({ $0 == c }) {
                flushAll(); blocks.append(.rule); i += 1; continue
            }

            // Heading
            if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                if level <= 6, line.dropFirst(level).first == " " || line.count == level {
                    flushAll()
                    let text = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
                    blocks.append(.heading(level: level, text: text))
                    i += 1; continue
                }
            }

            // Bullet
            if let rest = bulletContent(line) {
                flushPara(); flushNumbered(); flushQuote()
                bullets.append(rest); i += 1; continue
            }

            // Numbered
            if let (n, rest) = numberedContent(line) {
                flushPara(); flushBullets(); flushQuote()
                if numbered.isEmpty { numberedStart = n }
                numbered.append(rest); i += 1; continue
            }

            // Quote
            if line.hasPrefix(">") {
                flushPara(); flushBullets(); flushNumbered()
                quote.append(line.dropFirst().trimmingCharacters(in: .whitespaces)); i += 1; continue
            }

            // Continuation of a list item / quote (indented or plain text right after).
            if !bullets.isEmpty, raw.hasPrefix("  ") {
                bullets[bullets.count - 1] += " " + line; i += 1; continue
            }
            if !numbered.isEmpty, raw.hasPrefix("  ") {
                numbered[numbered.count - 1] += " " + line; i += 1; continue
            }

            flushBullets(); flushNumbered(); flushQuote()
            para.append(line)
            i += 1
        }
        flushAll()
        return blocks
    }

    private static func bulletContent(_ line: String) -> String? {
        for prefix in ["- ", "* ", "+ ", "• "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        if line == "-" || line == "*" { return "" }
        return nil
    }

    private static func numberedContent(_ line: String) -> (Int, String)? {
        let digits = line.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, digits.count <= 3, let n = Int(digits) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let sep = rest.first, sep == "." || sep == ")" else { return nil }
        let after = rest.dropFirst()
        guard after.first == " " || after.isEmpty else { return nil }
        return (n, after.trimmingCharacters(in: .whitespaces))
    }

    // MARK: Inline

    /// Inline markdown → AttributedString with code spans styled monospaced.
    static func inline(_ text: String, baseSize: CGFloat = 14, weight: Font.Weight = .regular) -> AttributedString {
        var attr: AttributedString
        if let parsed = try? AttributedString(
            markdown: text,
            options: .init(allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace,
                           failurePolicy: .returnPartiallyParsedIfPossible)) {
            attr = parsed
        } else {
            attr = AttributedString(text)
        }
        attr.font = .system(size: baseSize, weight: weight)
        for run in attr.runs {
            guard let intent = run.inlinePresentationIntent else { continue }
            var font: Font = .system(size: baseSize, weight: weight)
            if intent.contains(.code) {
                font = .system(size: baseSize - 1, weight: .medium, design: .monospaced)
                attr[run.range].backgroundColor = Color.primary.opacity(0.07)
                attr[run.range].foregroundColor = Color.primary.opacity(0.9)
            } else {
                if intent.contains(.stronglyEmphasized) { font = font.weight(.semibold) }
                if intent.contains(.emphasized) { font = font.italic() }
            }
            attr[run.range].font = font
        }
        return attr
    }
}

// MARK: - View

/// Renders markdown blocks. `caret` appends a blinking caret to the final
/// block while an answer streams.
struct MarkdownText: View {
    let text: String
    var streaming: Bool = false

    var body: some View {
        let blocks = LightMarkdown.parse(text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { idx, block in
                MarkdownBlockView(block: block, showsCaret: streaming && idx == blocks.count - 1)
            }
            if streaming && blocks.isEmpty {
                HStack(spacing: 0) { StreamingCaret() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

struct MarkdownBlockView: View {
    let block: LightMarkdown.Block
    var showsCaret: Bool = false

    var body: some View {
        switch block {
        case .heading(let level, let text):
            inlineText(text, size: headingSize(level), weight: .semibold)
                .padding(.top, level <= 2 ? 4 : 2)
        case .paragraph(let text):
            inlineText(text, size: 14)
                .lineSpacing(3.5)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Circle().fill(.secondary).frame(width: 4.5, height: 4.5).offset(y: -2.5)
                        inlineText(item, size: 14, caret: showsCaret && i == items.count - 1)
                            .lineSpacing(3)
                    }
                    .padding(.leading, 4)
                }
            }
        case .numbered(let start, let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(start + i).")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 16, alignment: .trailing)
                        inlineText(item, size: 14, caret: showsCaret && i == items.count - 1)
                            .lineSpacing(3)
                    }
                }
            }
        case .code(let language, let code):
            CodeBlockView(language: language, code: code, showsCaret: showsCaret)
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(PanelStyle.accentGradient).frame(width: 3)
                inlineText(text, size: 14, caret: showsCaret)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }
            .padding(.vertical, 2)
        case .rule:
            Hairline().padding(.vertical, 4)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 20
        case 2: return 17
        case 3: return 15.5
        default: return 14.5
        }
    }

    @ViewBuilder
    private func inlineText(_ text: String, size: CGFloat, weight: Font.Weight = .regular, caret: Bool? = nil) -> some View {
        let showCaret = caret ?? showsCaret
        if showCaret {
            TimelineView(.periodic(from: .now, by: 0.55)) { ctx in
                let on = Int(ctx.date.timeIntervalSinceReferenceDate / 0.55) % 2 == 0
                Text(LightMarkdown.inline(text, baseSize: size, weight: weight) + caretString(size: size, visible: on))
            }
        } else {
            Text(LightMarkdown.inline(text, baseSize: size, weight: weight))
        }
    }

    private func caretString(size: CGFloat, visible: Bool) -> AttributedString {
        var c = AttributedString("▍")
        c.font = .system(size: size, weight: .regular)
        c.foregroundColor = visible ? Color.indigo : Color.clear
        return c
    }
}

/// Standalone blinking caret for the moment before any text has arrived.
struct StreamingCaret: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.55)) { ctx in
            let on = Int(ctx.date.timeIntervalSinceReferenceDate / 0.55) % 2 == 0
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.indigo)
                .frame(width: 3, height: 17)
                .opacity(on ? 1 : 0.15)
        }
    }
}

struct CodeBlockView: View {
    let language: String?
    let code: String
    var showsCaret: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                Text(language.lowercased())
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
            }
            ScrollView(.horizontal) {
                HStack(alignment: .bottom, spacing: 2) {
                    Text(code.isEmpty ? " " : code)
                        .font(.system(size: 12.5, design: .monospaced))
                        .lineSpacing(2.5)
                        .foregroundStyle(.primary.opacity(0.9))
                    if showsCaret { StreamingCaret().frame(height: 15) }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, language == nil ? 10 : 8)
            }
            .scrollIndicators(.never)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.055)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}
