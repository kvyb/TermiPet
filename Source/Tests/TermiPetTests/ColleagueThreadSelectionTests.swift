import XCTest
@testable import TermiPet

@MainActor
final class ColleagueThreadSelectionTests: XCTestCase {
    private func thread(_ sessionID: String) -> PiColleagueThread {
        PiColleagueThread(sessionID: sessionID, label: sessionID, messages: [])
    }

    func testDefaultTargetIsTheNewestThread() {
        var selection = ColleagueThreadSelection()
        XCTAssertNil(selection.target(in: []))

        let alpha = thread("alpha")
        let beta = thread("beta")
        selection.sync(with: [alpha, beta])

        XCTAssertEqual(selection.target(in: [alpha, beta])?.sessionID, "beta")
    }

    func testNewCommentDoesNotMoveAnExplicitSelection() {
        var selection = ColleagueThreadSelection()
        let alpha = thread("alpha")
        let beta = thread("beta")
        selection.sync(with: [alpha])
        selection.select(alpha.id)

        // A comment from another session arrives while the user is reading alpha.
        XCTAssertFalse(selection.sync(with: [alpha, beta]))

        XCTAssertEqual(selection.target(in: [alpha, beta])?.sessionID, "alpha")
    }

    func testVanishedThreadFallsBackAndAsksToDropTheDraft() {
        var selection = ColleagueThreadSelection()
        let alpha = thread("alpha")
        let beta = thread("beta")
        selection.sync(with: [alpha])
        selection.select(alpha.id)

        // The capped thread list dropped the selected thread: retarget once, and tell
        // the view to drop the draft instead of sending it to another session.
        XCTAssertTrue(selection.sync(with: [beta]))

        XCTAssertEqual(selection.target(in: [beta])?.sessionID, "beta")
    }
}
