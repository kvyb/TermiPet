import Foundation

/// Deterministic eligibility rules. All time inputs are injected so tests can
/// exercise day boundaries and the 3-hour window without a live clock.
public enum PiColleagueEligibility {
    /// A session qualifies only when its active branch contains real user text
    /// from today (local calendar) and no older than `window` (3 hours).
    ///
    /// `futureTolerance` absorbs millisecond rounding and small clock skew; it is
    /// far below the cadence, so it cannot re-admit stale sessions.
    public static func isEligible(
        _ snapshot: PiSessionSnapshot,
        now: Date,
        calendar: Calendar = .current,
        window: TimeInterval = PiSessionScanner.activityWindow,
        futureTolerance: TimeInterval = 60
    ) -> Bool {
        guard let activity = snapshot.lastUserActivity else { return false }
        let elapsed = now.timeIntervalSince(activity)
        guard elapsed >= -futureTolerance, elapsed <= window else { return false }
        return calendar.isDate(activity, inSameDayAs: now)
    }

    /// Newest activity first; sessions that already have a lifetime receipt are
    /// excluded, so an old session that has been commented on never repeats.
    public static func candidates(
        _ snapshots: [PiSessionSnapshot],
        state: PiColleagueState,
        now: Date,
        calendar: Calendar = .current,
        window: TimeInterval = PiSessionScanner.activityWindow
    ) -> [PiSessionSnapshot] {
        snapshots
            .filter { !state.hasRecorded(sessionID: $0.sessionID) }
            .filter { isEligible($0, now: now, calendar: calendar, window: window) }
            .sorted { lhs, rhs in
                let left = lhs.lastUserActivity ?? .distantPast
                let right = rhs.lastUserActivity ?? .distantPast
                if left != right { return left > right }
                return lhs.sessionID < rhs.sessionID
            }
    }
}

/// Outcome of one cadence. `candidate` is nil when nothing should be sent; the
/// returned `state` is what the caller must persist before doing anything else.
public struct PiColleagueCycle: Equatable {
    public let candidate: PiSessionSnapshot?
    public let state: PiColleagueState
    public let hasStateChange: Bool

    public init(candidate: PiSessionSnapshot?, state: PiColleagueState, hasStateChange: Bool) {
        self.candidate = candidate
        self.state = state
        self.hasStateChange = hasStateChange
    }
}

public enum PiColleaguePlanner {
    /// Guards against wake/restart catch-up bursts: even if a due time was missed,
    /// at most one attempt happens per cadence and never closer than this to the
    /// previous attempt.
    public static let minimumSpacing: TimeInterval = 10 * 60

    public static func shouldRun(
        state: PiColleagueState,
        now: Date,
        isInFlight: Bool,
        minimumSpacing: TimeInterval = PiColleaguePlanner.minimumSpacing
    ) -> Bool {
        guard state.settings.isEnabled, !isInFlight else { return false }
        guard let due = state.nextDue, now >= due else { return false }
        if let lastAttempt = state.lastAttemptAt, now.timeIntervalSince(lastAttempt) < minimumSpacing {
            return false
        }
        return true
    }

    /// Randomised global gap, 20-40 minutes by default.
    public static func nextDue(
        after now: Date,
        settings: PiColleagueSettings,
        rng: inout some RandomNumberGenerator
    ) -> Date {
        let gap = Double.random(in: settings.minimumGap...settings.maximumGap, using: &rng)
        return now.addingTimeInterval(gap)
    }

    /// Restart behaviour: an overdue due time is pushed a full quiet gap into the
    /// future instead of firing immediately, so relaunching cannot flush a burst.
    public static func nextDueOnStart(
        state: PiColleagueState,
        now: Date,
        rng: inout some RandomNumberGenerator
    ) -> Date? {
        guard state.settings.isEnabled else { return nil }
        if let due = state.nextDue, due > now { return due }
        return nextDue(after: now, settings: state.settings, rng: &rng)
    }

    /// One cadence: at most one candidate, reservation recorded in the returned
    /// state, next due time advanced whether or not a candidate was found.
    public static func plan(
        state: PiColleagueState,
        snapshots: [PiSessionSnapshot],
        now: Date,
        calendar: Calendar = .current,
        rng: inout some RandomNumberGenerator
    ) -> PiColleagueCycle {
        guard state.settings.isEnabled else {
            return PiColleagueCycle(candidate: nil, state: state, hasStateChange: false)
        }

        var next = state
        next.nextDue = nextDue(after: now, settings: state.settings, rng: &rng)

        guard let candidate = PiColleagueEligibility
            .candidates(snapshots, state: state, now: now, calendar: calendar)
            .first
        else {
            return PiColleagueCycle(candidate: nil, state: next, hasStateChange: true)
        }

        next.receipts[candidate.sessionID] = PiColleagueReceipt(
            sessionID: candidate.sessionID,
            status: .attempted,
            recordedAt: now
        )
        next.lastAttemptAt = now
        return PiColleagueCycle(candidate: candidate, state: next, hasStateChange: true)
    }
}
