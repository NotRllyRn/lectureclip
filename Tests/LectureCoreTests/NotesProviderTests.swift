import XCTest
@testable import LectureCore

final class NotesProviderTests: XCTestCase {
    func testReasoningIsRemovedAndTruncatedReasoningIsNotShown() {
        XCTAssertEqual(NotesRequest.cleaned("<think>private draft</think>\nStudy notes"), "Study notes")
        XCTAssertEqual(NotesRequest.cleaned("<think>unfinished draft"), "")
        XCTAssertEqual(NotesRequest.cleaned("  Helpful summary  "), "Helpful summary")
        XCTAssertEqual(NotesRequest.cleaned("<think>one</think><think>two</think>Title"), "Title")
    }
}
