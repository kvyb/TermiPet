import XCTest
@testable import TermiPetCore

final class PiColleagueStateTests: XCTestCase {
    private let now = try! Date("2026-09-17T12:00:00Z", strategy: .iso8601)

    private func makeStore(function: String = #function) -> PiColleagueStateStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("termipet-pi-state", isDirectory: true)
            .appendingPathComponent(function + "-" + UUID().uuidString, isDirectory: true)
        return PiColleagueStateStore(stateURL: directory.appendingPathComponent("pi-colleague.json"))
    }

    func testDefaultsAreOptInAndQuiet() {
        let settings = PiColleagueSettings()

        XCTAssertFalse(settings.isEnabled)
        XCTAssertEqual(settings.minimumGap, 20 * 60)
        XCTAssertEqual(settings.maximumGap, 40 * 60)

        let state = PiColleagueState()
        XCTAssertNil(state.nextDue)
        XCTAssertNil(state.lastAttemptAt)
        XCTAssertTrue(state.receipts.isEmpty)
    }

    func testStateRoundTripsThroughDisk() throws {
        let store = makeStore()
        var state = PiColleagueState(settings: PiColleagueSettings(isEnabled: true), nextDue: now.addingTimeInterval(1_200))
        state.lastAttemptAt = now
        state.receipts["session-a"] = PiColleagueReceipt(sessionID: "session-a", status: .commented, recordedAt: now)

        try store.save(state)

        XCTAssertEqual(store.load(), .loaded(state))
        guard case .loaded(let loaded) = store.load() else { return XCTFail("expected a loaded state") }
        XCTAssertTrue(loaded.hasRecorded(sessionID: "session-a"))
    }

    func testReservationIsOnlyUsableOnceItIsOnDisk() throws {
        let store = makeStore()
        let due = now.addingTimeInterval(25 * 60)
        var state = PiColleagueState(settings: PiColleagueSettings(isEnabled: true), nextDue: due)
        state.receipts["session-reserve"] = PiColleagueReceipt(
            sessionID: "session-reserve",
            status: .attempted,
            recordedAt: now
        )
        state.lastAttemptAt = now

        try store.save(state)

        guard case .loaded(let loaded) = store.load() else { return XCTFail("expected a loaded state") }
        XCTAssertEqual(loaded, state)
        XCTAssertEqual(loaded.nextDue, due)
        XCTAssertTrue(loaded.hasRecorded(sessionID: "session-reserve"))
    }

    func testFailedWriteLeavesNoReservation() {
        let blockingFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("termipet-pi-state-blocker-" + UUID().uuidString)
        try? Data("not a directory".utf8).write(to: blockingFile)
        let store = PiColleagueStateStore(stateURL: blockingFile.appendingPathComponent("nested/pi-colleague.json"))
        var state = PiColleagueState(settings: PiColleagueSettings(isEnabled: true))
        state.receipts["session-blocked"] = PiColleagueReceipt(
            sessionID: "session-blocked",
            status: .attempted,
            recordedAt: now
        )

        XCTAssertThrowsError(try store.save(state))
        XCTAssertEqual(store.load(), .missing)
    }

    func testMissingStateFileIsNormal() {
        XCTAssertEqual(makeStore().load(), .missing)
    }

    func testCorruptStateIsReportedInsteadOfSilentlyReset() throws {
        let store = makeStore()
        let directory = store.stateURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: store.stateURL)

        // A corrupt file must never look like "no receipts yet": that would let the
        // next toggle overwrite the lifetime dedupe list and repeat comments.
        XCTAssertEqual(store.load(), .corrupt)

        try Data().write(to: store.stateURL)
        XCTAssertEqual(store.load(), .corrupt)

        try Data("[]".utf8).write(to: store.stateURL)
        XCTAssertEqual(store.load(), .corrupt)
    }

    func testOwnershipLockAllowsOnlyOneHolder() {
        let lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("termipet-pi-lock-" + UUID().uuidString)
            .appendingPathComponent("pi-colleague.lock")
        let first = PiColleagueOwnershipLock(lockURL: lockURL)
        let second = PiColleagueOwnershipLock(lockURL: lockURL)

        XCTAssertTrue(first.acquire())
        XCTAssertTrue(first.isOwned)
        XCTAssertFalse(second.acquire())
        XCTAssertFalse(second.isOwned)

        first.release()
        XCTAssertFalse(first.isOwned)
        XCTAssertTrue(second.acquire())
        XCTAssertTrue(second.isOwned)
        second.release()
    }

    func testRequestProvenanceIsBoundedAndBodyFree() throws {
        let store = makeStore()
        var state = PiColleagueState(settings: PiColleagueSettings(isEnabled: true))
        for index in 0..<30 {
            state = state.recordingRequest(
                requestID: "internal-termipet-\(String(format: "%016d", index))",
                outcome: index.isMultiple(of: 2) ? .verified : .tagMismatch,
                at: now.addingTimeInterval(Double(index))
            )
        }

        try store.save(state)
        guard case .loaded(let loaded) = store.load() else { return XCTFail("expected a loaded state") }

        XCTAssertEqual(loaded.recentRequests.count, PiColleagueState.maximumRecordedRequests)
        XCTAssertEqual(loaded.recentRequests.first?.requestID, "internal-termipet-0000000000000010")
        XCTAssertEqual(loaded.recentRequests.last?.requestID, "internal-termipet-0000000000000029")
        XCTAssertEqual(loaded.recentRequests.last?.outcome, .tagMismatch)
        XCTAssertEqual(loaded.recentRequests.last?.recordedAt, now.addingTimeInterval(29))

        // Only the ID, the echo outcome and a timestamp are persisted.
        let raw = try String(contentsOf: store.stateURL, encoding: .utf8)
        XCTAssertTrue(raw.contains("recentRequests"))
        XCTAssertTrue(raw.contains("internal-termipet-0000000000000029"))
        XCTAssertFalse(raw.contains("excerpt"))
        XCTAssertFalse(raw.contains("content"))
    }

    func testStateFileWithoutProvenanceStillLoads() throws {
        // Older state files (written before provenance existed) must keep working.
        let store = makeStore()
        let directory = store.stateURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = """
        {
          "settings": { "isEnabled": true, "minimumGap": 1200, "maximumGap": 2400 },
          "receipts": {
            "session-legacy": { "sessionID": "session-legacy", "status": "commented", "recordedAt": "2026-09-17T12:00:00Z" }
          }
        }
        """
        try Data(legacy.utf8).write(to: store.stateURL)

        guard case .loaded(let loaded) = store.load() else { return XCTFail("expected a loaded state") }
        XCTAssertTrue(loaded.hasRecorded(sessionID: "session-legacy"))
        XCTAssertEqual(loaded.settings.isEnabled, true)
        XCTAssertTrue(loaded.recentRequests.isEmpty)
    }
}
