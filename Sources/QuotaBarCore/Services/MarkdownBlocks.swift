import Foundation

/// Block-level structure of a chat message. Inline styling (bold, code, links) is left to
/// `AttributedString(markdown:)` at render time; this only splits the text into blocks.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(marker: String, text: String, indent: Int)
    case code(language: String?, text: String)
}

public enum MarkdownBlocks {
    public static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String] = []
        var codeLanguage: String?
        var inCode = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(normalizeEmphasis(paragraph.joined(separator: "\n"))))
            paragraph.removeAll()
        }

        for line in source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(language: codeLanguage, text: code.joined(separator: "\n")))
                    code.removeAll()
                    codeLanguage = nil
                    inCode = false
                } else {
                    flushParagraph()
                    let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    codeLanguage = lang.isEmpty ? nil : lang
                    inCode = true
                }
                continue
            }
            if inCode {
                code.append(line)
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            if let heading = headingMatch(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: normalizeEmphasis(heading.text)))
                continue
            }
            if let item = bulletMatch(line) {
                flushParagraph()
                blocks.append(.bullet(marker: item.marker, text: normalizeEmphasis(item.text), indent: item.indent))
                continue
            }
            paragraph.append(line)
        }
        if inCode { blocks.append(.code(language: codeLanguage, text: code.joined(separator: "\n"))) }
        flushParagraph()
        return blocks
    }

    /// CommonMark refuses `**text **` (space before the closing marker); models and people write it anyway.
    /// Moves the stray space outside the markers so the bold still renders.
    static func normalizeEmphasis(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(
            of: #"\*\*([^*\n]*?[^*\s\n])[ \t]+\*\*"#, with: "**$1** ", options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"\*\*[ \t]+([^*\n]*?[^*\s\n])\*\*"#, with: " **$1**", options: .regularExpression)
        return result
    }

    private static func headingMatch(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (hashes, text)
    }

    private static func bulletMatch(_ line: String) -> (marker: String, text: String, indent: Int)? {
        let leading = line.prefix(while: { $0 == " " || $0 == "\t" })
        let indent = min(3, leading.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2)
        let body = line.dropFirst(leading.count)
        guard let first = body.first else { return nil }

        if "-*+".contains(first), body.dropFirst().first == " " {
            let text = body.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : ("•", text, indent)
        }
        let digits = body.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let after = body.dropFirst(digits.count)
        guard let sep = after.first, sep == "." || sep == ")", after.dropFirst().first == " " else { return nil }
        let text = after.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : ("\(digits).", text, indent)
    }
}
