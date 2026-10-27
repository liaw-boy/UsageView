import XCTest
@testable import QuotaBarCore

final class MarkdownBlocksTests: XCTestCase {
    func testSplitsHeadingParagraphAndBullets() {
        let blocks = MarkdownBlocks.parse("## Title\nfirst line\nsecond line\n\n- one\n  - nested\n2. two")
        XCTAssertEqual(blocks, [
            .heading(level: 2, text: "Title"),
            .paragraph("first line\nsecond line"),
            .bullet(marker: "•", text: "one", indent: 0),
            .bullet(marker: "•", text: "nested", indent: 1),
            .bullet(marker: "2.", text: "two", indent: 0)
        ])
    }

    func testCodeFenceKeepsContentVerbatim() {
        let blocks = MarkdownBlocks.parse("before\n```swift\nlet a = 1\n\n# not a heading\n```\nafter")
        XCTAssertEqual(blocks, [
            .paragraph("before"),
            .code(language: "swift", text: "let a = 1\n\n# not a heading"),
            .paragraph("after")
        ])
    }

    func testUnclosedFenceRunsToTheEnd() {
        XCTAssertEqual(MarkdownBlocks.parse("```\nx = 1"), [.code(language: nil, text: "x = 1")])
    }

    func testStraySpaceInsideBoldMarkersIsMovedOutside() {
        XCTAssertEqual(MarkdownBlocks.parse("**done. **"), [.paragraph("**done.** ")])
        XCTAssertEqual(MarkdownBlocks.parse("**  done**"), [.paragraph(" **done**")])
        XCTAssertEqual(MarkdownBlocks.parse("**ok**"), [.paragraph("**ok**")])
    }

    func testNonMarkdownLinesStayParagraphs() {
        XCTAssertEqual(MarkdownBlocks.parse("#hashtag and 2024.5 items"), [.paragraph("#hashtag and 2024.5 items")])
        XCTAssertEqual(MarkdownBlocks.parse(""), [])
    }
}
