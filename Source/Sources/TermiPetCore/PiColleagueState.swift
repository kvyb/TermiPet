import Darwin
import Foundation

public struct PiColleagueSettings: Codable, Equatable, Sendable {
    public static let defaultMinimumGap: TimeInterval = 20 * 60
    public static let defaultMaximumGap: TimeInterval = 40 * 60
    public static let shortestAllowedGap: TimeInterval = 60

    /// Opt-in: colleague comments stay off until the user turns them on.
    public var isEnabled: Bool
    public var minimumGap: TimeInterval
    public var maximumGap: TimeInterval

    public init(
        isEnabled: Bool = false,
        minimumGap: TimeInterval = PiColleagueSettings.defaultMinimumGap,
        maximumGap: TimeInterval = PiColleagueSettings.defaultMaximumGap
    ) {
        self.isEnabled = isEnabled
        self.minimumGap = max(minimumGap, Self.shortestAllowedGap)
        self.maximumGap = max(maximumGap, self.minimumGap)
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case minimumGap
        case maximumGap
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false,
            minimumGap: try container.decodeIfPresent(TimeInterval.self, forKey: .minimumGap) ?? Self.defaultMinimumGap,
            maximumGap: try container.decodeIfPresent(TimeInterval.self, forKey: .maximumGap) ?? Self.defaultMaximumGap
        )
    }
}

/// Minimal local receipt. No excerpt text, no prompt, no secrets.
public struct PiColleagueReceipt: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// An automatic comment was attempted for this session. Failed calls still
        /// consume the session so a broken endpoint cannot cause retry storms.
        case attempted
        case commented
    }

    public var sessionID: String
    public var status: Status
    public var recordedAt: Date

    public init(sessionID: String, status: Status, recordedAt: Date) {
        self.sessionID = sessionID
        self.status = status
        self.recordedAt = recordedAt
    }
}

/// Minimal provenance for one outgoing internal-tagged request.
///
/// Records only the request ID that was sent in `x-session-id` and whether the
/// endpoint echoed it. No prompt, excerpt, history or response text is ever stored.
public struct PiColleagueRequestRecord: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        /// HTTP 2xx and the echoed `x-session-id` matched the sent tag.
        case verified
        /// The response carried no `x-session-id` header at all.
        case tagMissing
        /// The echoed header did not match the sent tag.
        case tagMismatch
        /// Non-2xx status or a non-HTTP response, so the tag could not be verified.
        case httpStatus
        /// Transport failure before any verification could happen.
        case failed
        /// The request was cancelled; it may still have reached the endpoint.
        case cancelled
    }

    public var requestID: String
    public var outcome: Outcome
    public var recordedAt: Date

    public init(requestID: String, outcome: Outcome, recordedAt: Date) {
        self.requestID = requestID
        self.outcome = outcome
        self.recordedAt = recordedAt
    }
}

public struct PiColleagueState: Codable, Equatable, Sendable {
    /// Bounded provenance ring: newest request last, oldest dropped.
    public static let maximumRecordedRequests = 20

    public var settings: PiColleagueSettings
    public var nextDue: Date?
    public var lastAttemptAt: Date?
    /// Lifetime, per session ID. Never reset daily.
    public var receipts: [String: PiColleagueReceipt]
    /// Bounded, body-free provenance for internal-tagged requests.
    public var recentRequests: [PiColleagueRequestRecord]

    public init(
        settings: PiColleagueSettings = PiColleagueSettings(),
        nextDue: Date? = nil,
        lastAttemptAt: Date? = nil,
        receipts: [String: PiColleagueReceipt] = [:],
        recentRequests: [PiColleagueRequestRecord] = []
    ) {
        self.settings = settings
        self.nextDue = nextDue
        self.lastAttemptAt = lastAttemptAt
        self.receipts = receipts
        self.recentRequests = recentRequests
    }

    private enum CodingKeys: String, CodingKey {
        case settings
        case nextDue
        case lastAttemptAt
        case receipts
        case recentRequests
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            settings: try container.decodeIfPresent(PiColleagueSettings.self, forKey: .settings) ?? PiColleagueSettings(),
            nextDue: try container.decodeIfPresent(Date.self, forKey: .nextDue),
            lastAttemptAt: try container.decodeIfPresent(Date.self, forKey: .lastAttemptAt),
            receipts: try container.decodeIfPresent([String: PiColleagueReceipt].self, forKey: .receipts) ?? [:],
            recentRequests: try container.decodeIfPresent([PiColleagueRequestRecord].self, forKey: .recentRequests) ?? []
        )
    }

    public func hasRecorded(sessionID: String) -> Bool {
        receipts[sessionID] != nil
    }

    public func markingCommented(sessionID: String, at date: Date) -> PiColleagueState {
        var copy = self
        copy.receipts[sessionID] = PiColleagueReceipt(sessionID: sessionID, status: .commented, recordedAt: date)
        return copy
    }

    public func recordingRequest(
        requestID: String,
        outcome: PiColleagueRequestRecord.Outcome,
        at date: Date
    ) -> PiColleagueState {
        var copy = self
        copy.recentRequests.append(PiColleagueRequestRecord(requestID: requestID, outcome: outcome, recordedAt: date))
        if copy.recentRequests.count > Self.maximumRecordedRequests {
            copy.recentRequests.removeFirst(copy.recentRequests.count - Self.maximumRecordedRequests)
        }
        return copy
    }
}

/// Result of reading the durable state file.
///
/// A missing file is normal (nothing configured yet). An unreadable file is not:
/// callers must stay inert and must never overwrite it, otherwise a decode bug or a
/// crash mid-write would silently reset the lifetime dedupe list.
public enum PiColleagueStateLoad: Equatable, Sendable {
    case missing
    case loaded(PiColleagueState)
    case corrupt
}

public struct PiColleagueStateStore {
    public let stateURL: URL

    public init(stateURL: URL = PiColleagueStateStore.defaultStateURL()) {
        self.stateURL = stateURL
    }

    public func load() -> PiColleagueStateLoad {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return .missing }
        guard let data = try? Data(contentsOf: stateURL), !data.isEmpty else { return .corrupt }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(PiColleagueState.self, from: data) else { return .corrupt }
        return .loaded(state)
    }

    public func save(_ state: PiColleagueState) throws {
        let parent = stateURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        try data.write(to: stateURL, options: .atomic)
    }

    public static func defaultStateURL() -> URL {
        applicationSupportURL().appendingPathComponent("TermiPet/pi-colleague.json")
    }

    static func applicationSupportURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
    }
}

/// Exclusive, non-blocking advisory lock so a second TermiPet launch cannot send
/// duplicate colleague requests. Held for the lifetime of the owning instance.
public final class PiColleagueOwnershipLock {
    public let lockURL: URL
    private var descriptor: Int32 = -1

    public init(lockURL: URL = PiColleagueOwnershipLock.defaultLockURL()) {
        self.lockURL = lockURL
    }

    public var isOwned: Bool {
        descriptor >= 0
    }

    @discardableResult
    public func acquire() -> Bool {
        guard descriptor < 0 else { return true }
        try? FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return false }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        descriptor = fd
        return true
    }

    public func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit {
        release()
    }

    public static func defaultLockURL() -> URL {
        PiColleagueStateStore.applicationSupportURL().appendingPathComponent("TermiPet/pi-colleague.lock")
    }
}
