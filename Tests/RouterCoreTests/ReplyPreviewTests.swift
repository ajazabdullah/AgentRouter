import XCTest
@testable import RouterCore

final class ReplyPreviewTests: XCTestCase {
    func testDefaultsToLastSentence() {
        let reply = "I reviewed the diff. The fix subagent is still running. Once it reports, I'll verify and push."
        XCTAssertEqual(ReplyPreview.lastSentences(reply), "Once it reports, I'll verify and push.")
    }
    func testTakesLastTwoSentences() {
        let reply = "I reviewed the diff. The fix subagent is still running. Once it reports, I'll check its tests myself, then verify, install and push."
        XCTAssertEqual(ReplyPreview.lastSentences(reply, count: 2, limit: 240),
                       "The fix subagent is still running. Once it reports, I'll check its tests myself, then verify, install and push.")
    }
    func testSkipsCodeBlocksAndMarkdown() {
        let reply = """
        ## Summary
        - **Tests:** all `17` pass
        ```swift
        let secret = "not prose."
        ```
        Ready to push.
        """
        XCTAssertEqual(ReplyPreview.lastSentences(reply, count: 2), "Tests: all 17 pass. Ready to push.")
    }
    func testLongSentenceKeepsItsStartAtWordBoundary() {
        let reply = "Done. Once it reports, I'll check its tests myself, add the SESSION.md entries, run the review, then verify, install and push."
        let result = ReplyPreview.lastSentences(reply)!
        XCTAssertTrue(result.hasPrefix("Once it reports, I'll check"))
        XCTAssertTrue(result.hasSuffix("…"))
        XCTAssertLessThanOrEqual(result.count, 101)
        XCTAssertFalse(result.contains(" …"))
    }
    func testHardWrappedProseStaysOneSentence() {
        let reply = "I reviewed the diff. The fix subagent is still running and\nwill report back shortly."
        XCTAssertEqual(ReplyPreview.lastSentences(reply), "The fix subagent is still running and will report back shortly.")
    }
    func testClosingParenthesisAfterPeriodAddsNoExtraPeriod() {
        XCTAssertEqual(ReplyPreview.lastSentences("Done. (Tests pass.)"), "(Tests pass.)")
    }
    func testTruncationKeepsOpeningQuote() {
        let reply = "\"Once it reports, I'll check its tests myself, add the SESSION.md entries, run the review, then verify, install and push.\""
        XCTAssertTrue(ReplyPreview.lastSentences(reply)!.hasPrefix("\"Once"))
    }
    func testEmptyOrCodeOnlyReplyHasNoPreview() {
        XCTAssertNil(ReplyPreview.lastSentences("   \n\n"))
        XCTAssertNil(ReplyPreview.lastSentences("```\nonly code\n```"))
    }
}
