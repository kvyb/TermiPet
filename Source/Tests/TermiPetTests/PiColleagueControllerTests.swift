import AppKit
import XCTest
@testable import TermiPet
@testable import TermiPetCore

/// Offline stub transport: no live calls, no real network.
final class PiColleagueStubProtocol: URLProtocol {
    struct Stub {
        var status: Int = 200
        var body: String = ""
        var delayNanoseconds: UInt64 = 0
        var echoSessionTag: Bool = true
        var echoedTagOverride: String?
    }

    nonisolated(unsafe) static var stub = Stub()
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?
    nonisolated(unsafe) static var bodies: [Data] = []

    static func reset() {
        stub = Stub()
        requestCount = 0
        lastRequest = nil
        lastBody = nil
        bodies = []
    }

    /// URLProtocol receives the body as a stream, so read it while it is available.
    static func readBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }

    static func lastBodyJSON() -> [String: Any]? {
        guard let body = lastBody,
              let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        else {
            return nil
        }
        return object
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        Self.lastRequest = request
        Self.lastBody = Self.readBody(from: request)
        if let body = Self.lastBody {
            Self.bodies.append(body)
        }
        let stub = Self.stub
        if stub.delayNanoseconds > 0 {
            usleep(useconds_t(stub.delayNanoseconds / 1000))
        }

        var headers: [String: String] = ["Content-Type": "text/event-stream"]
        if let override = stub.echoedTagOverride {
            headers[PiColleagueService.sessionTagHeader] = override
        } else if stub.echoSessionTag, let tag = request.value(forHTTPHeaderField: PiColleagueService.sessionTagHeader) {
            headers[PiColleagueService.sessionTagHeader] = tag
        }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.invalid")!,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(stub.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class PiColleagueControllerTests: XCTestCase {
    private var controller: PiColleagueController!
    private var store: PiColleagueStateStore!
    private var sandbox: URL!
    private var clock = Date()

    override func setUp() async throws {
        try await super.setUp()
        PiColleagueStubProtocol.reset()
        clock = Date()
    }

    override func tearDown() async throws {
        controller?.stop()
        controller = nil
        try await super.tearDown()
    }

    private func makeSessionsRoot() throws -> URL {
        let root = PiSessionFixture.temporaryRoot(function: #function)
        try PiSessionFixture.write(
            root: root,
            project: "--Users-example-Projects-training--",
            fileName: "one.jsonl",
            objects: [
                PiSessionFixture.header(id: "session-live", timestamp: clock),
                PiSessionFixture.user(
                    id: "u1",
                    parentID: nil,
                    text: "the retry queue keeps growing",
                    timestamp: clock.addingTimeInterval(45 * 60)
                ),
                PiSessionFixture.assistant(
                    id: "a1",
                    parentID: "u1",
                    text: "I moved the retry into a bounded queue.",
                    timestamp: clock.addingTimeInterval(45 * 60)
                ),
            ],
            modifiedAt: clock
        )
        return root
    }

    private func makeTwoSessionRoot() throws -> URL {
        let root = PiSessionFixture.temporaryRoot(function: #function)
        let sessions = [
            ("alpha.jsonl", "session-alpha", "alpha question", "alpha answer"),
            ("beta.jsonl", "session-beta", "beta question", "beta answer"),
        ]
        for (fileName, sessionID, question, answer) in sessions {
            try PiSessionFixture.write(
                root: root,
                project: "--Users-example-Projects-training--",
                fileName: fileName,
                objects: [
                    PiSessionFixture.header(id: sessionID, timestamp: clock),
                    PiSessionFixture.user(
                        id: "u1",
                        parentID: nil,
                        text: question,
                        timestamp: clock.addingTimeInterval(45 * 60)
                    ),
                    PiSessionFixture.assistant(
                        id: "a1",
                        parentID: "u1",
                        text: answer,
                        timestamp: clock.addingTimeInterval(45 * 60)
                    ),
                ],
                modifiedAt: clock
            )
        }
        return root
    }

    private func makeController(
        sessionsRoot: URL,
        stateURL: URL? = nil,
        lockURL: URL? = nil,
        wakeNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) -> PiColleagueController {
        let directory = sandbox ?? makeSandbox()
        store = PiColleagueStateStore(stateURL: stateURL ?? directory.appendingPathComponent("pi-colleague.json"))

        return PiColleagueController(
            store: store,
            scanner: PiSessionScanner(rootURL: sessionsRoot),
            service: stubService(),
            lock: PiColleagueOwnershipLock(lockURL: lockURL ?? directory.appendingPathComponent("pi-colleague.lock")),
            now: { [weak self] in self?.clock ?? Date() },
            calendar: .current,
            wakeNotifications: wakeNotifications
        )
    }

    private func makeSandbox() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("termipet-pi-controller", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        sandbox = directory
        return directory
    }

    private func stubService() -> PiColleagueService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PiColleagueStubProtocol.self]
        return PiColleagueService(session: URLSession(configuration: configuration))
    }

    private func persistedState() -> PiColleagueState? {
        guard case .loaded(let state) = store.load() else { return nil }
        return state
    }

    private func advanceClock(minutes: Double) {
        clock = clock.addingTimeInterval(minutes * 60)
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 3,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for \(description)")
    }

    private func sseComment(_ text: String) -> String {
        "data: {\"choices\":[{\"delta\":{\"content\":\"\(text)\"},\"finish_reason\":\"stop\"}]}\n\n"
    }

    func testEnabledCadenceDeliversOneCommentAndReservesIt() async throws {
        let root = try makeSessionsRoot()
        controller = makeController(sessionsRoot: root)
        PiColleagueStubProtocol.stub.body = sseComment("Nice, that queue fix is the right shape.")

        controller.start()
        controller.setEnabled(true)
        XCTAssertTrue(controller.settings.isEnabled)
        XCTAssertTrue(controller.isOwned)

        advanceClock(minutes: 45)
        controller.runCadence()

        await waitUntil("comment delivery") { self.controller.threads.count == 1 }
        XCTAssertEqual(controller.threads.first?.sessionID, "session-live")
        XCTAssertEqual(controller.threads.first?.label, "training · session-")
        XCTAssertEqual(controller.threads.first?.messages.map(\.content), ["Nice, that queue fix is the right shape."])
        XCTAssertEqual(controller.unreadCount, 1)
        XCTAssertEqual(PiColleagueStubProtocol.requestCount, 1)

        let tag = try XCTUnwrap(PiColleagueStubProtocol.lastRequest?.value(forHTTPHeaderField: PiColleagueService.sessionTagHeader))
        XCTAssertTrue(PiColleagueSessionTag.isValid(tag))
        let persisted = try XCTUnwrap(persistedState())
        XCTAssertEqual(persisted.receipts["session-live"]?.status, .commented)
        XCTAssertNotNil(persisted.lastAttemptAt)
        XCTAssertGreaterThan(persisted.nextDue ?? clock, clock)

        // Viewing exactly this thread clears its badge without duplicating a session.
        let threadID = try XCTUnwrap(controller.threads.first?.id)
        controller.markRead(threadID: threadID)
        XCTAssertEqual(controller.unreadCount, 0)
    }

    func testSecondCadenceNeverRepeatsTheSameSession() async throws {
        let root = try makeSessionsRoot()
        controller = makeController(sessionsRoot: root)
        PiColleagueStubProtocol.stub.body = sseComment("First comment.")

        controller.start()
        controller.setEnabled(true)
        advanceClock(minutes: 45)
        controller.runCadence()
        await waitUntil("first comment") { self.controller.threads.count == 1 }
        XCTAssertEqual(PiColleagueStubProtocol.requestCount, 1)

        advanceClock(minutes: 30)
        controller.runCadence()
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(PiColleagueStubProtocol.requestCount, 1)
        XCTAssertEqual(controller.threads.count, 1)
        XCTAssertEqual(controller.unreadCount, 1)
    }

    func testDisabledControllerNeverSends() async throws {
        let root = try makeSessionsRoot()
        controller = makeController(sessionsRoot: root)
        PiColleagueStubProtocol.stub.body = sseComment("Should not arrive.")

        controller.start()
        XCTAssertFalse(controller.settings.isEnabled)
        advanceClock(minutes: 45)
        controller.runCadence()
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(PiColleagueStubProtocol.requestCount, 0)
        XCTAssertTrue(controller.threads.isEmpty)
        // Nothing is written while the feature stays off.
        XCTAssertNotEqual(persistedState()?.settings.isEnabled, true)
    }

    func testFailedCallConsumesTheSessionWithoutRetryStorm() async throws {
        let root = try makeSessionsRoot()
        controller = makeController(sessionsRoot: root)
        PiColleagueStubProtocol.stub.status = 502
        PiColleagueStubProtocol.stub.body = "upstream unavailable"

        controller.start()
        controller.setEnabled(true)
        advanceClock(minutes: 45)
        controller.runCadence()
        await waitUntil("failed request") { PiColleagueStubProtocol.requestCount == 1 }

        XCTAssertTrue(controller.threads.isEmpty)
        XCTAssertEqual(controller.unreadCount, 0)
        XCTAssertEqual(persistedState()?.receipts["session-live"]?.status, .attempted)

        advanceClock(minutes: 30)
        controller.runCadence()
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(PiColleagueStubProtocol.requestCount, 1, "a failed attempt must not be retried")
    }

    func testMissingEchoHeaderIsRejectedBeforeDisplay() async throws {
        let root = try makeSessionsRoot()
        controller = makeController(sessionsRoot: root)
        PiColleagueStubProtocol.stub.echoSessionTag = false
        PiColleagueStubProtocol.stub.body = sseComment("Untrusted text.")

        controller.start()
        controller.setEnabled(true)
        advanceClock(minutes: 45)
        controller.runCadence()
        await waitUntil("rejected request") { PiColleagueStubProtocol.requestCount == 1 }
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(controller.threads.isEmpty)
        XCTAssertEqual(persistedState()?.receipts["session-live"]?.status, .attempted)
    }

    func testDisablingSuppressesLateDelivery() async throws {
        let root = try makeSessionsRoot()
        controller = makeController(sessionsRoot: root)
        PiColleagueStubProtocol.stub.body = sseComment("Too late.")
        PiColleagueStubProtocol.stub.delayNanoseconds = 2_000_000_000

        controller.start()
        controller.setEnabled(true)
        advanceClock(minutes: 45)
        controller.runCadence()
        await waitUntil("in-flight request", timeout: 5) { PiColleagueStubProtocol.requestCount == 1 }

        controller.setEnabled(false)
        try? await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertTrue(controller.threads.isEmpty)
        XCTAssertEqual(controller.unreadCount, 0)
        XCTAssertEqual(persistedState()?.settings.isEnabled, false)
    }

    func testSkipResponseDeliversNothing() async throws {
        let root = try makeSessionsRoot()
        controller = makeController(sessionsRoot: root)
        PiColleagueStubProtocol.stub.body = "data: {\"choices\":[{\"delta\":{\"content\":\"[SKIP]\"},\"finish_reason\":\"stop\"}]}\n\n"

        controller.start()
        controller.setEnabled(true)
        advanceClock(minutes: 45)
        controller.runCadence()
        await waitUntil("skip response") { PiColleagueStubProtocol.requestCount == 1 }
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(controller.threads.isEmpty)
        XCTAssertEqual(persistedState()?.receipts["session-live"]?.status, .attempted)
    }

    func testReplyUsesOnlyItsOwnThreadContext() async throws {
        let root = try makeSessionsRoot()
        controller = makeController(sessionsRoot: root)
        PiColleagueStubProtocol.stub.body = sseComment("First comment.")

        controller.start()
        controller.setEnabled(true)
        advanceClock(minutes: 45)
        controller.runCadence()
        await waitUntil("comment") { self.controller.threads.count == 1 }

        PiColleagueStubProtocol.stub.body = sseComment("Anytime.")
        let threadID = try XCTUnwrap(controller.threads.first?.id)
        controller.reply(threadID: threadID, text: "thanks")

        await waitUntil("reply") { self.controller.threads.first?.messages.count == 3 }
        XCTAssertEqual(controller.threads.first?.messages.map(\.role), [.assistant, .user, .assistant])
        XCTAssertEqual(controller.threads.first?.messages.map(\.content), ["First comment.", "thanks", "Anytime."])
        XCTAssertEqual(PiColleagueStubProtocol.requestCount, 2)
    }

    func testCadenceFailsClosedWhenReservationCannotBeWritten() async throws {
        let root = try makeSessionsRoot()
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("termipet-pi-state-readonly", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("pi-colleague.json")
        var seeded = PiColleagueState(
            settings: PiColleagueSettings(isEnabled: true),
            nextDue: clock.addingTimeInterval(-60)
        )
        seeded.lastAttemptAt = clock.addingTimeInterval(-3_600)
        try PiColleagueStateStore(stateURL: stateURL).save(seeded)

        controller = makeController(sessionsRoot: root, stateURL: stateURL)
        PiColleagueStubProtocol.stub.body = sseComment("Should never be sent.")
        // The file stays readable, but every later write fails: a persisted
        // reservation is what licenses the call.
        let directory = stateURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

        controller.start()
        advanceClock(minutes: 45)
        controller.runCadence()
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(controller.storageFailed)
        XCTAssertTrue(controller.settings.isEnabled)
        XCTAssertEqual(PiColleagueStubProtocol.requestCount, 0)
        XCTAssertTrue(controller.threads.isEmpty)
    }

    func testUnwritableStateKeepsTheFeatureDisabled() async throws {
        let root = try makeSessionsRoot()
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("termipet-pi-blocker-" + UUID().uuidString)
        try Data("blocked".utf8).write(to: blocker)
        controller = makeController(
            sessionsRoot: root,
            stateURL: blocker.appendingPathComponent("nested/pi-colleague.json")
        )

        controller.start()
        controller.setEnabled(true)
        advanceClock(minutes: 45)
        controller.runCadence()
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertFalse(controller.settings.isEnabled)
        XCTAssertTrue(controller.storageFailed)
        XCTAssertEqual(PiColleagueStubProtocol.requestCount, 0)
    }


    func testNonOwnerInstanceCannotChangeStateReplyOrSend() async throws {
        let root = try makeSessionsRoot()
        controller = makeController(sessionsRoot: root)
        PiColleagueStubProtocol.stub.body = sseComment("Owner comment.")

        controller.start()
        controller.setEnabled(true)
        advanceClock(minutes: 45)
        controller.runCadence()
        await waitUntil("owner comment") { self.controller.threads.count == 1 }
        let threadID = try XCTUnwrap(controller.threads.first?.id)
        let dueBefore = try XCTUnwrap(persistedState()?.nextDue)

        // A second instance sharing the same lock and state file stays inert.
        let second = PiColleagueController(
            store: PiColleagueStateStore(stateURL: store.stateURL),
            scanner: PiSessionScanner(rootURL: root),
            service: stubService(),
            lock: PiColleagueOwnershipLock(lockURL: try XCTUnwrap(sandbox).appendingPathComponent("pi-colleague.lock")),
            now: { [weak self] in self?.clock ?? Date() },
            calendar: .current,
            wakeNotifications: NotificationCenter()
        )
        second.start()

        XCTAssertFalse(second.isOwned)
        second.setEnabled(false)
        second.reply(threadID: threadID, text: "hello from the second window")
        advanceClock(minutes: 30)
        second.runCadence()
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(persistedState()?.settings.isEnabled, true, "a non-owner must not change consent")
        XCTAssertEqual(persistedState()?.nextDue, dueBefore, "a non-owner must not touch the schedule")
        XCTAssertEqual(PiColleagueStubProtocol.requestCount, 1, "a non-owner must not send anything")
        XCTAssertTrue(second.threads.isEmpty)
        // The non-owner shows the durable consent read-only: it cannot change it.
        XCTAssertTrue(second.settings.isEnabled)

        // The owning instance keeps working.
        PiColleagueStubProtocol.stub.body = sseComment("Anytime.")
        controller.reply(threadID: threadID, text: "thanks")
        await waitUntil("owner reply") { self.controller.threads.first?.messages.count == 3 }
        XCTAssertEqual(PiColleagueStubProtocol.requestCount, 2)

        second.stop()
    }

    func testCorruptStateBlocksSendingAndIsNeverOverwritten() async throws {
        let root = try makeSessionsRoot()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("termipet-pi-corrupt", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stateURL = directory.appendingPathComponent("pi-colleague.json")
        try Data("{ not json".utf8).write(to: stateURL)
        let corruptBytes = try Data(contentsOf: stateURL)

        controller = makeController(sessionsRoot: root, stateURL: stateURL)
        PiColleagueStubProtocol.stub.body = sseComment("Should never send.")

        controller.start()
        XCTAssertTrue(controller.stateIsCorrupt)
        XCTAssertFalse(controller.settings.isEnabled)

        controller.setEnabled(true)
        advanceClock(minutes: 45)
        controller.runCadence()
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(PiColleagueStubProtocol.requestCount, 0)
        XCTAssertTrue(controller.threads.isEmpty)
        XCTAssertEqual(controller.unreadCount, 0)
        XCTAssertFalse(controller.settings.isEnabled)
        XCTAssertEqual(try Data(contentsOf: stateURL), corruptBytes, "the unreadable state file must be left alone")
    }

    func testDisableThenReEnableDoesNotDeliverTheLateResult() async throws {
        let root = try makeSessionsRoot()
        controller = makeController(sessionsRoot: root)
        PiColleagueStubProtocol.stub.body = sseComment("Too late.")
        PiColleagueStubProtocol.stub.delayNanoseconds = 400_000_000

        controller.start()
        controller.setEnabled(true)
        advanceClock(minutes: 45)
        controller.runCadence()
        await waitUntil("in-flight request") { PiColleagueStubProtocol.requestCount == 1 }

        controller.setEnabled(false)
        controller.setEnabled(true)
        try? await Task.sleep(nanoseconds: 800_000_000)

        XCTAssertTrue(controller.threads.isEmpty)
        XCTAssertEqual(controller.unreadCount, 0)
        XCTAssertEqual(persistedState()?.receipts["session-live"]?.status, .attempted)
    }

    func testDelayedTimerTickRestaggersBeforeWakeNotificationOrSpending() async throws {
        let root = try makeSessionsRoot()
        controller = makeController(sessionsRoot: root)
        controller.start()
        controller.setEnabled(true)
        advanceClock(minutes: 45)

        // The overdue timer fired before the workspace wake notification.
        controller.handleTimerTick()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(PiColleagueStubProtocol.requestCount, 0)
        XCTAssertTrue(persistedState()?.receipts.isEmpty ?? false)
        let due = try XCTUnwrap(persistedState()?.nextDue)
        XCTAssertGreaterThanOrEqual(due.timeIntervalSince(clock), 1199)
        XCTAssertLessThanOrEqual(due.timeIntervalSince(clock), 2400)

        advanceClock(minutes: 1)
        controller.handleTimerTick()
        XCTAssertEqual(persistedState()?.nextDue, due, "ordinary ticks must not postpone the cadence forever")
    }

    func testWakeCancelsInFlightRequestAndReraisesTheGap() async throws {
        let root = try makeSessionsRoot()
        controller = makeController(sessionsRoot: root)
        PiColleagueStubProtocol.stub.body = sseComment("Too late.")
        PiColleagueStubProtocol.stub.delayNanoseconds = 400_000_000

        controller.start()
        controller.setEnabled(true)
        advanceClock(minutes: 45)
        controller.runCadence()
        await waitUntil("in-flight request") { PiColleagueStubProtocol.requestCount == 1 }

        // The lid was closed through the due time and the request spanned the sleep.
        advanceClock(minutes: 90)
        controller.handleWake()
        try? await Task.sleep(nanoseconds: 800_000_000)

        XCTAssertTrue(controller.threads.isEmpty)
        XCTAssertEqual(controller.unreadCount, 0)
        let persisted = try XCTUnwrap(persistedState())
        XCTAssertGreaterThanOrEqual(persisted.nextDue?.timeIntervalSince(clock) ?? 0, 20 * 60)
        XCTAssertEqual(persisted.receipts["session-live"]?.status, .attempted)
    }

    func testWakeNotificationReraisesAnOverdueGapOnlyWhileRunning() async throws {
        let root = try makeSessionsRoot()
        let center = NotificationCenter()
        controller = makeController(sessionsRoot: root, wakeNotifications: center)
        PiColleagueStubProtocol.stub.body = sseComment("Should not send.")

        controller.start()
        controller.setEnabled(true)
        let dueAfterEnable = try XCTUnwrap(persistedState()?.nextDue)

        // A due time still in the future is left alone.
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(persistedState()?.nextDue, dueAfterEnable)

        // Waking past the due time re-staggers a full quiet gap.
        advanceClock(minutes: 120)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        await waitUntil("wake re-stagger") { self.persistedState()?.nextDue != dueAfterEnable }
        let reraisdDue = try XCTUnwrap(persistedState()?.nextDue)
        XCTAssertGreaterThanOrEqual(reraisdDue.timeIntervalSince(clock), 20 * 60)

        // After stop() the observer is unregistered, so a further wake changes nothing.
        advanceClock(minutes: 120)
        controller.stop()
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(persistedState()?.nextDue, reraisdDue)
        XCTAssertEqual(PiColleagueStubProtocol.requestCount, 0)
    }

    func testReplyKeepsItsOwnThreadExcerptAndSendsNoLocalMetadata() async throws {
        let root = try makeTwoSessionRoot()
        controller = makeController(sessionsRoot: root)
        PiColleagueStubProtocol.stub.body = sseComment("First.")

        controller.start()
        controller.setEnabled(true)
        advanceClock(minutes: 45)
        controller.runCadence()
        await waitUntil("alpha comment") { self.controller.threads.count == 1 }

        advanceClock(minutes: 60)
        controller.runCadence()
        await waitUntil("beta comment") { self.controller.threads.count == 2 }
        XCTAssertEqual(controller.threads.map(\.sessionID), ["session-alpha", "session-beta"])

        let alpha = try XCTUnwrap(controller.threads.first { $0.sessionID == "session-alpha" })
        XCTAssertEqual(alpha.excerptLines.count, 2)
        XCTAssertTrue(alpha.excerptLines[0].contains("alpha question"))

        PiColleagueStubProtocol.stub.body = sseComment("Anytime.")
        controller.reply(threadID: alpha.id, text: "thanks")
        await waitUntil("alpha reply") {
            self.controller.threads.first { $0.sessionID == "session-alpha" }?.messages.count == 3
        }

        let body = try XCTUnwrap(PiColleagueStubProtocol.lastBody)
        let serialized = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(serialized.contains("alpha question"), "the reply keeps its own excerpt")
        XCTAssertTrue(serialized.contains("alpha answer"))
        XCTAssertTrue(serialized.contains("thanks"))
        XCTAssertFalse(serialized.contains("beta question"), "the other session must not leak into the reply")
        XCTAssertFalse(serialized.contains("beta answer"))
        // No serialized request (comments or reply) may carry local metadata.
        let serializedBodies = PiColleagueStubProtocol.bodies.map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(serializedBodies.count, 3)
        for body in serializedBodies {
            XCTAssertFalse(body.contains("training"), "project label stays local")
            XCTAssertFalse(body.contains("/Users/"))
            XCTAssertFalse(body.contains(".jsonl"))
            XCTAssertFalse(body.contains("session-alpha"))
            XCTAssertFalse(body.contains("session-beta"))
        }
    }

    func testMarkReadClearsOnlyTheViewedThread() async throws {
        let root = try makeTwoSessionRoot()
        controller = makeController(sessionsRoot: root)
        PiColleagueStubProtocol.stub.body = sseComment("Comment.")

        controller.start()
        controller.setEnabled(true)
        advanceClock(minutes: 45)
        controller.runCadence()
        await waitUntil("alpha comment") { self.controller.threads.count == 1 }
        advanceClock(minutes: 60)
        controller.runCadence()
        await waitUntil("beta comment") { self.controller.threads.count == 2 }

        let alphaID = try XCTUnwrap(controller.threads.first { $0.sessionID == "session-alpha" }?.id)
        XCTAssertEqual(controller.unreadCount, 2)

        controller.markRead(threadID: alphaID)

        XCTAssertEqual(controller.unreadCount, 1, "unviewed threads keep their unread comment")
        XCTAssertEqual(controller.threads.first { $0.sessionID == "session-alpha" }?.hasUnread, false)
        XCTAssertEqual(controller.threads.first { $0.sessionID == "session-beta" }?.hasUnread, true)
    }

    func testStaleResultIsNotDeliveredAfterTheWindowCloses() async throws {
        let root = try makeSessionsRoot()
        controller = makeController(sessionsRoot: root)
        PiColleagueStubProtocol.stub.body = sseComment("Too late.")
        PiColleagueStubProtocol.stub.delayNanoseconds = 400_000_000

        controller.start()
        controller.setEnabled(true)
        advanceClock(minutes: 45)
        controller.runCadence()
        await waitUntil("in-flight request") { PiColleagueStubProtocol.requestCount == 1 }

        // The Mac slept during the call: by delivery time the session is far outside
        // the 3 hour activity window, so the comment must be dropped.
        advanceClock(minutes: 300)
        try? await Task.sleep(nanoseconds: 800_000_000)

        XCTAssertTrue(controller.threads.isEmpty)
        XCTAssertEqual(controller.unreadCount, 0)
        XCTAssertEqual(persistedState()?.receipts["session-live"]?.status, .attempted)
    }

    func testEveryRequestRecordsItsSentTagAndEchoOutcome() async throws {
        let root = try makeSessionsRoot()
        controller = makeController(sessionsRoot: root)
        PiColleagueStubProtocol.stub.body = sseComment("First comment.")

        controller.start()
        controller.setEnabled(true)
        advanceClock(minutes: 45)
        controller.runCadence()
        await waitUntil("comment") { self.controller.threads.count == 1 }

        let sentTag = try XCTUnwrap(
            PiColleagueStubProtocol.lastRequest?.value(forHTTPHeaderField: PiColleagueService.sessionTagHeader)
        )
        let threadID = try XCTUnwrap(controller.threads.first?.id)
        var persisted = try XCTUnwrap(persistedState())
        XCTAssertEqual(persisted.recentRequests.count, 1)
        XCTAssertEqual(persisted.recentRequests.last?.requestID, sentTag, "the recorded ID is the tag actually sent")
        XCTAssertEqual(persisted.recentRequests.last?.outcome, .verified)

        // Manual replies are recorded too.
        PiColleagueStubProtocol.stub.body = sseComment("Anytime.")
        controller.reply(threadID: threadID, text: "thanks")
        await waitUntil("reply") { self.controller.threads.first?.messages.count == 3 }

        let replyTag = try XCTUnwrap(
            PiColleagueStubProtocol.lastRequest?.value(forHTTPHeaderField: PiColleagueService.sessionTagHeader)
        )
        persisted = try XCTUnwrap(persistedState())
        XCTAssertEqual(persisted.recentRequests.count, 2)
        XCTAssertEqual(persisted.recentRequests.last?.requestID, replyTag)
        XCTAssertEqual(persisted.recentRequests.last?.outcome, .verified)
        XCTAssertNotEqual(replyTag, sentTag, "every request keeps its own ID")

        // Provenance never stores the conversation itself.
        let raw = try String(contentsOf: store.stateURL, encoding: .utf8)
        XCTAssertFalse(raw.contains("First comment."))
        XCTAssertFalse(raw.contains("thanks"))
        XCTAssertFalse(raw.contains("Nice, that queue"))
    }

    func testUnverifiedEchoAndServerErrorsAreRecordedWithTheirOutcome() async throws {
        let root = try makeTwoSessionRoot()
        controller = makeController(sessionsRoot: root)
        PiColleagueStubProtocol.stub.body = sseComment("Untrusted.")
        // The endpoint echoes a different tag: unverified, nothing may be shown.
        PiColleagueStubProtocol.stub.echoedTagOverride = "internal-termipet-someoneelse00"

        controller.start()
        controller.setEnabled(true)
        advanceClock(minutes: 45)
        controller.runCadence()
        await waitUntil("tag mismatch recorded") {
            self.persistedState()?.recentRequests.last?.outcome == .tagMismatch
        }
        XCTAssertTrue(controller.threads.isEmpty)

        // Next cadence targets the other session, and the endpoint now fails.
        PiColleagueStubProtocol.stub.echoedTagOverride = nil
        PiColleagueStubProtocol.stub.status = 502
        advanceClock(minutes: 120)
        controller.runCadence()
        await waitUntil("server error recorded") {
            self.persistedState()?.recentRequests.last?.outcome == .httpStatus
        }

        let persisted = try XCTUnwrap(persistedState())
        XCTAssertEqual(persisted.recentRequests.map(\.outcome), [.tagMismatch, .httpStatus])
        XCTAssertEqual(persisted.receipts.count, 2, "both attempts stay consumed")
        XCTAssertTrue(controller.threads.isEmpty)
    }
}
