import AppKit
import Foundation
import TermiPetCore

struct PiColleagueThread: Identifiable, Equatable {
    let id: UUID
    let sessionID: String
    var label: String
    /// Redacted excerpt lines this thread's comment reacted to. It stays in memory,
    /// is never persisted and is never rendered in the chat, but it is re-sent as
    /// context when the user replies so the colleague keeps the original thread.
    var excerptLines: [String]
    var messages: [ChatMessage]
    var hasUnread: Bool

    init(
        id: UUID = UUID(),
        sessionID: String,
        label: String,
        excerptLines: [String] = [],
        messages: [ChatMessage] = [],
        hasUnread: Bool = false
    ) {
        self.id = id
        self.sessionID = sessionID
        self.label = label
        self.excerptLines = excerptLines
        self.messages = messages
        self.hasUnread = hasUnread
    }
}

@MainActor
final class PiColleagueController: ObservableObject {
    /// Cadence tick. The actual gap is 20-40 minutes and lives in the persisted state.
    static let tickInterval: TimeInterval = 60
    static let maximumThreads = 12
    static let maximumMessagesPerThread = 12
    /// After a failed state write, wait before scanning the session files again.
    static let blockedRetryInterval: TimeInterval = 5 * 60

    @Published private(set) var threads: [PiColleagueThread] = []
    @Published private(set) var settings: PiColleagueSettings
    @Published private(set) var isReplying = false
    @Published private(set) var lastReplyFailed = false
    @Published private(set) var storageFailed = false
    /// False when another TermiPet instance holds the ownership lock: this window
    /// then neither changes settings nor sends anything.
    @Published private(set) var isOwned = false
    /// True when the persisted state file exists but cannot be read. The feature
    /// stays inert and never overwrites the file until the user repairs or deletes it.
    @Published private(set) var stateIsCorrupt = false

    /// Number of threads holding an unread comment.
    var unreadCount: Int {
        threads.filter(\.hasUnread).count
    }

    private let store: PiColleagueStateStore
    private let scanner: PiSessionScanner
    private let service: PiColleagueService
    private let lock: PiColleagueOwnershipLock
    private let now: @MainActor () -> Date
    private let calendar: Calendar
    private let wakeNotifications: NotificationCenter

    private var state = PiColleagueState()
    private var rng = SystemRandomNumberGenerator()
    private var timer: Timer?
    private var lastTimerTick: Date?
    private var dispatchTask: Task<Void, Never>?
    private var replyTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var isInFlight = false
    /// Bumped whenever consent changes, so a response that arrives after a
    /// disable/re-enable cycle cannot be delivered.
    private var dispatchGeneration = 0
    private var scanBlockedUntil: Date?

    init(
        store: PiColleagueStateStore = PiColleagueStateStore(),
        scanner: PiSessionScanner = PiSessionScanner(),
        service: PiColleagueService = PiColleagueService(),
        lock: PiColleagueOwnershipLock = PiColleagueOwnershipLock(),
        now: @escaping @MainActor () -> Date = { Date() },
        calendar: Calendar = .current,
        wakeNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.store = store
        self.scanner = scanner
        self.service = service
        self.lock = lock
        self.now = now
        self.calendar = calendar
        self.wakeNotifications = wakeNotifications
        self.settings = state.settings
    }

    /// Claims the single-instance lock, then loads the durable state **under** that
    /// lock. A second app launch fails to acquire and stays inert.
    func start() {
        guard acquireOwnership() else { return }
        guard !stateIsCorrupt, settings.isEnabled,
              let due = PiColleaguePlanner.nextDueOnStart(state: state, now: now(), rng: &rng)
        else {
            stopTimer()
            return
        }
        var updated = state
        updated.nextDue = due
        guard persist(updated) else { return }
        startTimer()
    }

    func stop() {
        dispatchGeneration &+= 1
        stopTimer()
        dispatchTask?.cancel()
        dispatchTask = nil
        replyTask?.cancel()
        replyTask = nil
        isInFlight = false
        isReplying = false
        unregisterWakeObserver()
        lock.release()
        isOwned = false
    }

    func setEnabled(_ enabled: Bool) {
        // Refuses silently in the UI (the toggle is disabled there); this is the
        // programmatic guard so a non-owner can never desync shared consent state.
        guard acquireOwnership(), !stateIsCorrupt else { return }

        var updated = state
        updated.settings.isEnabled = enabled
        updated.nextDue = enabled
            ? PiColleaguePlanner.nextDue(after: now(), settings: updated.settings, rng: &rng)
            : nil

        // Consent is only applied once it is durable: a failed write leaves both the
        // switch and the runtime exactly as they were.
        guard persist(updated) else { return }
        dispatchGeneration &+= 1

        if enabled {
            startTimer()
        } else {
            // Disabling stops the timer and the in-flight automatic request, and
            // suppresses its late delivery. Manual pet chat is unaffected.
            stopTimer()
            dispatchTask?.cancel()
            dispatchTask = nil
            isInFlight = false
        }
    }

    /// Marks one viewed thread as read. Other threads keep their unread comment.
    func markRead(threadID: UUID) {
        guard let index = threads.firstIndex(where: { $0.id == threadID }),
              threads[index].hasUnread
        else {
            return
        }
        threads[index].hasUnread = false
    }

    func reply(threadID: UUID, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isOwned, !stateIsCorrupt, !trimmed.isEmpty, !isReplying,
              let index = threads.firstIndex(where: { $0.id == threadID })
        else {
            return
        }

        let history = threads[index].messages
        let excerptLines = threads[index].excerptLines
        threads[index].messages.append(ChatMessage(role: .user, content: trimmed))
        trimMessages(at: index)
        lastReplyFailed = false
        isReplying = true

        let messages = PiColleaguePrompt.replyMessages(
            history: history,
            excerptLines: excerptLines,
            reply: trimmed
        )
        replyTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isReplying = false }
            let requestID = PiColleagueSessionTag.make()
            do {
                let outcome = try await self.service.comment(
                    messages: messages,
                    sessionTag: requestID
                )
                self.recordRequest(requestID, outcome: .verified)
                guard !Task.isCancelled else { return }
                switch outcome {
                case .comment(let reply):
                    self.append(reply: reply, toThread: threadID)
                case .skip, .rejected:
                    self.lastReplyFailed = true
                }
            } catch is CancellationError {
                self.recordRequest(requestID, outcome: .cancelled)
                return
            } catch {
                self.recordRequest(requestID, outcome: PiColleagueService.requestOutcome(for: error))
                self.lastReplyFailed = true
            }
        }
    }

    /// Sleep/wake: cancel an automatic request that spanned the sleep (its result
    /// cannot be trusted or delivered) and push an overdue due time a full quiet gap
    /// into the future, exactly like a restart.
    func handleWake() {
        dispatchGeneration &+= 1
        dispatchTask?.cancel()
        dispatchTask = nil
        isInFlight = false

        guard isOwned, !stateIsCorrupt, settings.isEnabled,
              let due = PiColleaguePlanner.nextDueOnStart(state: state, now: now(), rng: &rng)
        else {
            return
        }
        var updated = state
        updated.nextDue = due
        persist(updated)
    }

    // MARK: - Ownership and state

    private func acquireOwnership() -> Bool {
        if isOwned {
            reloadState()
            return true
        }
        guard lock.acquire() else {
            isOwned = false
            // Read-only view for display; nothing is written while not owned.
            reloadState()
            return false
        }
        isOwned = true
        reloadState()
        return true
    }

    /// Loads the durable state. Never overwrites a corrupt file, and never treats a
    /// corrupt file as "no receipts yet" - that would silently allow repeats.
    private func reloadState() {
        switch store.load() {
        case .missing:
            state = PiColleagueState()
            stateIsCorrupt = false
        case .loaded(let loaded):
            state = loaded
            stateIsCorrupt = false
        case .corrupt:
            state = PiColleagueState()
            stateIsCorrupt = true
        }
        settings = state.settings
    }

    // MARK: - Cadence

    private func startTimer() {
        stopTimer()
        lastTimerTick = now()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.handleTimerTick()
            }
        }
        timer.tolerance = 15
        self.timer = timer
        registerWakeObserver()
    }

    /// A missed tick may reach the run loop before the workspace wake notification.
    /// Re-stagger before reserving or spending a request in that case.
    func handleTimerTick() {
        let moment = now()
        let previous = lastTimerTick
        lastTimerTick = moment
        if let previous, moment.timeIntervalSince(previous) > 2 * Self.tickInterval {
            handleWake()
            return
        }
        runCadence()
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        lastTimerTick = nil
        // The wake observer only exists while the cadence runs.
        unregisterWakeObserver()
    }

    private func registerWakeObserver() {
        guard wakeObserver == nil else { return }
        wakeObserver = wakeNotifications.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleWake()
            }
        }
    }

    private func unregisterWakeObserver() {
        guard let wakeObserver else { return }
        wakeNotifications.removeObserver(wakeObserver)
        self.wakeObserver = nil
    }

    /// One cadence. The timer calls this; tests drive it directly with an injected clock.
    ///
    /// The scan is intentionally main-actor: it is a bounded 16 KiB head + 512 KiB tail
    /// per candidate file, once per 20-40 minute cadence, which keeps the decision path
    /// deterministic and testable. Backgrounding it would need an async re-entrant
    /// cadence for a few milliseconds of work.
    func runCadence() {
        guard isOwned, !stateIsCorrupt, settings.isEnabled else { return }
        let moment = now()
        if let blockedUntil = scanBlockedUntil, moment < blockedUntil { return }
        guard PiColleaguePlanner.shouldRun(state: state, now: moment, isInFlight: isInFlight) else { return }

        let snapshots = scanner.snapshots(now: moment)
        let cycle = PiColleaguePlanner.plan(
            state: state,
            snapshots: snapshots,
            now: moment,
            calendar: calendar,
            rng: &rng
        )
        if cycle.hasStateChange, !persist(cycle.state) {
            // Fail closed: without a durable reservation nothing may be sent, and the
            // same scan must not repeat every tick while writes keep failing.
            scanBlockedUntil = moment.addingTimeInterval(Self.blockedRetryInterval)
            return
        }
        guard let candidate = cycle.candidate else { return }

        isInFlight = true
        let generation = dispatchGeneration
        dispatchTask = Task { [weak self] in
            await self?.dispatch(candidate: candidate, generation: generation)
        }
    }

    private func dispatch(candidate: PiSessionSnapshot, generation: Int) async {
        defer {
            if generation == dispatchGeneration {
                isInFlight = false
                dispatchTask = nil
            }
        }

        let excerptLines = PiColleaguePrompt.redactedExcerptLines(candidate.excerpt)
        let requestID = PiColleagueSessionTag.make()
        do {
            let outcome = try await service.comment(
                messages: PiColleaguePrompt.messages(
                    redactedLines: excerptLines,
                    isPartial: candidate.isPartialContext
                ),
                sessionTag: requestID
            )
            recordRequest(requestID, outcome: .verified)
            // Disabling suppresses a late result, and re-enabling must not revive it.
            guard !Task.isCancelled,
                  generation == dispatchGeneration,
                  settings.isEnabled,
                  !stateIsCorrupt
            else {
                return
            }
            guard case .comment(let text) = outcome else { return }
            // A dormant Mac (sleep/wake) can stretch the call: only deliver while
            // the source session is still in the activity window.
            guard PiColleagueEligibility.isEligible(candidate, now: now(), calendar: calendar) else { return }
            deliver(text: text, snapshot: candidate, excerptLines: excerptLines)
        } catch {
            // The attempt is already reserved on disk: no retry for this session.
            recordRequest(requestID, outcome: PiColleagueService.requestOutcome(for: error))
            return
        }
    }

    private func deliver(text: String, snapshot: PiSessionSnapshot, excerptLines: [String]) {
        if let index = threads.firstIndex(where: { $0.sessionID == snapshot.sessionID }) {
            threads[index].messages.append(ChatMessage(role: .assistant, content: text))
            threads[index].excerptLines = excerptLines
            threads[index].hasUnread = true
            trimMessages(at: index)
        } else {
            threads.append(
                PiColleagueThread(
                    sessionID: snapshot.sessionID,
                    label: snapshot.displayLabel,
                    excerptLines: excerptLines,
                    messages: [ChatMessage(role: .assistant, content: text)],
                    hasUnread: true
                )
            )
            if threads.count > Self.maximumThreads {
                threads.removeFirst(threads.count - Self.maximumThreads)
            }
        }

        let updated = state.markingCommented(sessionID: snapshot.sessionID, at: now())
        if persist(updated) {
            state = updated
        }
    }

    private func append(reply: String, toThread threadID: UUID) {
        guard let index = threads.firstIndex(where: { $0.id == threadID }) else { return }
        threads[index].messages.append(ChatMessage(role: .assistant, content: reply))
        trimMessages(at: index)
    }

    private func trimMessages(at index: Int) {
        guard threads.indices.contains(index), threads[index].messages.count > Self.maximumMessagesPerThread else { return }
        threads[index].messages.removeFirst(threads[index].messages.count - Self.maximumMessagesPerThread)
    }

    /// Best-effort provenance for one internal-tagged request: the ID that was sent
    /// and whether the endpoint echoed it. A failed write is not a safety failure, so
    /// it does not raise the settings warning.
    private func recordRequest(_ requestID: String, outcome: PiColleagueRequestRecord.Outcome) {
        guard isOwned, !stateIsCorrupt else { return }
        let updated = state.recordingRequest(requestID: requestID, outcome: outcome, at: now())
        guard (try? store.save(updated)) != nil else { return }
        state = updated
    }

    /// Persists state and mirrors it into the published settings. Returns false when
    /// nothing was written, in which case callers must fail closed.
    @discardableResult
    private func persist(_ updated: PiColleagueState) -> Bool {
        guard isOwned else { return false }
        guard !stateIsCorrupt else {
            storageFailed = true
            return false
        }
        do {
            try store.save(updated)
            state = updated
            settings = updated.settings
            storageFailed = false
            scanBlockedUntil = nil
            return true
        } catch {
            storageFailed = true
            return false
        }
    }
}
