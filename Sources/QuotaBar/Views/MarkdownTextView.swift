import QuotaBarCore
import SwiftUI

/// Renders a chat message's Markdown: headings, bullets, code blocks and inline styling.
/// No third-party renderer; block splitting is `MarkdownBlocks`, inline styling is `AttributedString(markdown:)`.
struct MarkdownTextView: View {
    private let blocks: [MarkdownBlock]
    let fontSize: CGFloat
    let lineSpacing: CGFloat

    init(text: String, fontSize: CGFloat, lineSpacing: CGFloat) {
        blocks = MarkdownBlocks.parse(text)
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: fontSize * 0.55) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(.system(size: fontSize + CGFloat(max(0, 4 - level)) * 1.5, weight: .bold))
                .padding(.top, 2)
        case .paragraph(let text):
            Text(inline(text))
                .font(.system(size: fontSize))
                .lineSpacing(lineSpacing)
        case .bullet(let marker, let text, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Text(inline(text))
                    .font(.system(size: fontSize))
                    .lineSpacing(lineSpacing)
            }
            .padding(.leading, CGFloat(indent) * 14)
        case .code(_, let text):
            Text(text)
                .font(.system(size: fontSize - 1, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
                .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }

    private func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
