import XCTest
@testable import TermiPetCore

final class PiColleagueSchedulingTests: XCTestCase {
    private let now = try! Date("2026-09-17T12:00:00Z", strategy: .iso8601)

    private func time(_ iso: String) -> Date {
        try! Date(iso, strategy: .iso8601)
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func snapshot(
        id: String,
        minutesAgo: Double?,
        excerpt: String = "question",
        sessionID: String? = nil
    ) -> PiSessionSnapshot {
        PiSessionSnapshot(
            sessionID: sessionID ?? id,
            projectLabel: "training",
            sessionLabel: nil,
            lastUserActivity: minutesAgo.map { now.addingTimeInterval(-$0 * 60) },
            excerpt: [PiSessionExcerptLine(role: .user, text: excerpt, timestamp: nil)],
            isPartialContext: false,
            fileURL: URL(fileURLWithPath: "/tmp/\(id).jsonl")
        )
    }

    func testEligibilityRequiresTodayAndWithinThreeHours() {
        let calendar = utcCalendar()

        XCTAssertTrue(PiColleagueEligibility.isEligible(snapshot(id: "a", minutesAgo: 10), now: now, calendar: calendar))
        XCTAssertTrue(PiColleagueEligibility.isEligible(snapshot(id: "a", minutesAgo: 179), now: now, calendar: calendar))
        XCTAssertFalse(PiColleagueEligibility.isEligible(snapshot(id: "a", minutesAgo: 181), now: now, calendar: calendar))
        XCTAssertFalse(PiColleagueEligibility.isEligible(snapshot(id: "a", minutesAgo: nil), now: now, calendar: calendar))
        XCTAssertFalse(PiColleagueEligibility.isEligible(snapshot(id: "a", minutesAgo: -5), now: now, calendar: calendar))
        // Millisecond rounding and small clock skew must not disqualify a fresh session.
        XCTAssertTrue(PiColleagueEligibility.isEligible(snapshot(id: "a", minutesAgo: -0.001), now: now, calendar: calendar))
    }

    func testEligibilityUsesLocalCalendarDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        // 00:30 in Los Angeles on 2026-09-17.
        let localNow = time("2026-09-17T07:30:00Z")

        let lateLastNight = PiSessionSnapshot(
            sessionID: "late-last-night",
            projectLabel: nil,
            sessionLabel: nil,
            lastUserActivity: time("2026-09-17T05:30:00Z"), // 22:30 the previous local day
            excerpt: [],
            isPartialContext: false,
            fileURL: URL(fileURLWithPath: "/tmp/yesterday.jsonl")
        )
        let today = PiSessionSnapshot(
            sessionID: "today",
            projectLabel: nil,
            sessionLabel: nil,
            lastUserActivity: time("2026-09-17T07:00:00Z"), // 00:00 local
            excerpt: [],
            isPartialContext: false,
            fileURL: URL(fileURLWithPath: "/tmp/today.jsonl")
        )

        XCTAssertTrue(PiColleagueEligibility.isEligible(today, now: localNow, calendar: calendar))
        XCTAssertFalse(PiColleagueEligibility.isEligible(lateLastNight, now: localNow, calendar: calendar))
    }

    func testCandidatesExcludeRecordedSessionsAndSortNewestFirst() {
        var state = PiColleagueState()
        state.receipts["old"] = PiColleagueReceipt(sessionID: "old", status: .commented, recordedAt: now.addingTimeInterval(-86_400))
        let snapshots = [
            snapshot(id: "recent", minutesAgo: 5),
            snapshot(id: "old", minutesAgo: 10),
            snapshot(id: "stale", minutesAgo: 500),
        ]

        let candidates = PiColleagueEligibility.candidates(snapshots, state: state, now: now, calendar: utcCalendar())

        XCTAssertEqual(candidates.map(\.sessionID), ["recent"])
    }

    func testLifetimeReceiptSurvivesAcrossDays() {
        var state = PiColleagueState()
        state.receipts["yesterday"] = PiColleagueReceipt(
            sessionID: "yesterday",
            status: .attempted,
            recordedAt: now.addingTimeInterval(-86_400)
        )

        let candidates = PiColleagueEligibility.candidates(
            [snapshot(id: "yesterday", minutesAgo: 30)],
            state: state,
            now: now,
            calendar: utcCalendar()
        )

        XCTAssertTrue(candidates.isEmpty)
    }

    func testShouldRunRequiresEnabledDueAndIdle() {
        var state = PiColleagueState()
        state.settings.isEnabled = true
        state.nextDue = now.addingTimeInterval(-60)
        state.lastAttemptAt = now.addingTimeInterval(-3_600)

        XCTAssertTrue(PiColleaguePlanner.shouldRun(state: state, now: now, isInFlight: false))
        XCTAssertFalse(PiColleaguePlanner.shouldRun(state: state, now: now, isInFlight: true))

        var disabled = state
        disabled.settings.isEnabled = false
        XCTAssertFalse(PiColleaguePlanner.shouldRun(state: disabled, now: now, isInFlight: false))

        var notDue = state
        notDue.nextDue = now.addingTimeInterval(600)
        XCTAssertFalse(PiColleaguePlanner.shouldRun(state: notDue, now: now, isInFlight: false))

        var justAttempted = state
        justAttempted.lastAttemptAt = now.addingTimeInterval(-60)
        XCTAssertFalse(PiColleaguePlanner.shouldRun(state: justAttempted, now: now, isInFlight: false))
    }

    func testGlobalGapStaysWithinTwentyToFortyMinutes() {
        var rng = SeededGenerator(seed: 7)
        let settings = PiColleagueSettings()

        for _ in 0..<200 {
            let due = PiColleaguePlanner.nextDue(after: now, settings: settings, rng: &rng)
            let gap = due.timeIntervalSince(now)
            XCTAssertGreaterThanOrEqual(gap, 20 * 60)
            XCTAssertLessThanOrEqual(gap, 40 * 60)
        }
    }

    func testRestartPushesOverdueScheduleInsteadOfCatchingUp() throws {
        var rng = SeededGenerator(seed: 11)
        var state = PiColleagueState()

        XCTAssertNil(PiColleaguePlanner.nextDueOnStart(state: state, now: now, rng: &rng))

        state.settings.isEnabled = true
        let first = try XCTUnwrap(PiColleaguePlanner.nextDueOnStart(state: state, now: now, rng: &rng))
        XCTAssertGreaterThanOrEqual(first.timeIntervalSince(now), 20 * 60)

        var future = state
        future.nextDue = now.addingTimeInterval(900)
        XCTAssertEqual(PiColleaguePlanner.nextDueOnStart(state: future, now: now, rng: &rng), future.nextDue)

        var overdue = state
        overdue.nextDue = now.addingTimeInterval(-3_600)
        let resumed = try XCTUnwrap(PiColleaguePlanner.nextDueOnStart(state: overdue, now: now, rng: &rng))
        XCTAssertGreaterThanOrEqual(resumed.timeIntervalSince(now), 20 * 60)
    }

    func testPlanSendsOneNewestCandidateAndReservesIt() {
        var rng = SeededGenerator(seed: 3)
        var state = PiColleagueState()
        state.settings.isEnabled = true
        state.nextDue = now.addingTimeInterval(-1)
        let snapshots = [
            snapshot(id: "older", minutesAgo: 40),
            snapshot(id: "newest", minutesAgo: 2),
            snapshot(id: "stale", minutesAgo: 500),
        ]

        let cycle = PiColleaguePlanner.plan(state: state, snapshots: snapshots, now: now, calendar: utcCalendar(), rng: &rng)

        XCTAssertEqual(cycle.candidate?.sessionID, "newest")
        XCTAssertTrue(cycle.hasStateChange)
        XCTAssertEqual(cycle.state.receipts["newest"]?.status, .attempted)
        XCTAssertEqual(cycle.state.lastAttemptAt, now)
        XCTAssertGreaterThan(cycle.state.nextDue ?? now, now)
        XCTAssertNil(cycle.state.receipts["older"])

        let second = PiColleaguePlanner.plan(
            state: cycle.state,
            snapshots: snapshots,
            now: now.addingTimeInterval(30),
            calendar: utcCalendar(),
            rng: &rng
        )
        XCTAssertEqual(second.candidate?.sessionID, "older")

        var spent = cycle.state
        spent.receipts["older"] = PiColleagueReceipt(sessionID: "older", status: .attempted, recordedAt: now)
        let third = PiColleaguePlanner.plan(
            state: spent,
            snapshots: snapshots,
            now: now.addingTimeInterval(60),
            calendar: utcCalendar(),
            rng: &rng
        )
        XCTAssertNil(third.candidate)
        XCTAssertTrue(third.hasStateChange)
    }

    func testPlanIsInertWhenDisabled() {
        var rng = SeededGenerator(seed: 5)
        var state = PiColleagueState()
        state.nextDue = now.addingTimeInterval(-1)

        let cycle = PiColleaguePlanner.plan(
            state: state,
            snapshots: [snapshot(id: "eligible", minutesAgo: 5)],
            now: now,
            calendar: utcCalendar(),
            rng: &rng
        )

        XCTAssertNil(cycle.candidate)
        XCTAssertFalse(cycle.hasStateChange)
        XCTAssertEqual(cycle.state, state)
    }

    func testQuietCadenceAdvancesWithoutCandidate() {
        var rng = SeededGenerator(seed: 9)
        var state = PiColleagueState()
        state.settings.isEnabled = true
        state.nextDue = now.addingTimeInterval(-1)

        let cycle = PiColleaguePlanner.plan(
            state: state,
            snapshots: [snapshot(id: "stale", minutesAgo: 400)],
            now: now,
            calendar: utcCalendar(),
            rng: &rng
        )

        XCTAssertNil(cycle.candidate)
        XCTAssertTrue(cycle.hasStateChange)
        XCTAssertNil(cycle.state.receipts["stale"])
        XCTAssertGreaterThan(cycle.state.nextDue ?? now, now)
        XCTAssertNil(cycle.state.lastAttemptAt)
    }
}
