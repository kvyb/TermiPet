import XCTest
@testable import TermiPetCore

final class PiSessionScannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_787_000_000) // fixed synthetic clock

    private func time(minutesAgo: Double) -> Date {
        now.addingTimeInterval(-minutesAgo * 60)
    }

    func testExcerptKeepsOnlyUserAndAssistantText() throws {
        let root = PiSessionFixture.temporaryRoot(function: #function)
        let file = try PiSessionFixture.write(
            root: root,
            project: "--Users-example-Projects-training--",
            fileName: "one.jsonl",
            objects: [
                PiSessionFixture.header(id: "session-one", timestamp: time(minutesAgo: 30)),
                PiSessionFixture.user(id: "u1", parentID: nil, text: "first question", timestamp: time(minutesAgo: 29)),
                PiSessionFixture.assistantMixed(id: "a1", parentID: "u1", text: "answer text", timestamp: time(minutesAgo: 28)),
                PiSessionFixture.toolResult(id: "t1", parentID: "a1", text: "SECRET_TOOL_OUTPUT", timestamp: time(minutesAgo: 27)),
                PiSessionFixture.compaction(id: "c1", parentID: "t1", summary: "SECRET_COMPACTION_SUMMARY", timestamp: time(minutesAgo: 26)),
                PiSessionFixture.customMessage(id: "m1", parentID: "c1", content: "SECRET_CUSTOM_MESSAGE", timestamp: time(minutesAgo: 25)),
                PiSessionFixture.sessionInfo(id: "s1", parentID: "m1", name: "Refactor auth module", timestamp: time(minutesAgo: 24)),
                PiSessionFixture.user(
                    id: "u2",
                    parentID: "s1",
                    text: "second question\n<system-reminder>SECRET_REMINDER_BLOCK</system-reminder>",
                    timestamp: time(minutesAgo: 5)
                ),
                PiSessionFixture.assistant(id: "a2", parentID: "u2", text: "final answer", timestamp: time(minutesAgo: 4)),
            ],
            modifiedAt: now
        )

        let scanner = PiSessionScanner(rootURL: root)
        let snapshot = try XCTUnwrap(scanner.snapshot(fileURL: file))

        XCTAssertEqual(snapshot.sessionID, "session-one")
        XCTAssertEqual(snapshot.sessionLabel, "Refactor auth module")
        XCTAssertEqual(snapshot.excerpt.map(\.role), [.user, .assistant, .user, .assistant])
        XCTAssertEqual(
            snapshot.excerpt.map(\.text),
            ["first question", "answer text", "second question", "final answer"]
        )
        let joined = snapshot.excerpt.map(\.text).joined(separator: "\n")
        XCTAssertFalse(joined.contains("SECRET_"))
        XCTAssertEqual(snapshot.lastUserActivity?.timeIntervalSince1970 ?? 0, time(minutesAgo: 5).timeIntervalSince1970, accuracy: 1)
    }

    func testActiveBranchIgnoresAbandonedBranch() throws {
        let root = PiSessionFixture.temporaryRoot(function: #function)
        let file = try PiSessionFixture.write(
            root: root,
            project: "--Users-example-Projects-training--",
            fileName: "branches.jsonl",
            objects: [
                PiSessionFixture.header(id: "session-branch", timestamp: time(minutesAgo: 40)),
                PiSessionFixture.user(id: "a1", parentID: nil, text: "shared question", timestamp: time(minutesAgo: 39)),
                PiSessionFixture.assistant(id: "a2", parentID: "a1", text: "abandoned answer", timestamp: time(minutesAgo: 38)),
                PiSessionFixture.user(id: "b1", parentID: "a1", text: "chosen question", timestamp: time(minutesAgo: 10)),
                PiSessionFixture.assistant(id: "b2", parentID: "b1", text: "chosen answer", timestamp: time(minutesAgo: 9)),
            ],
            modifiedAt: now
        )

        let snapshot = try XCTUnwrap(PiSessionScanner(rootURL: root).snapshot(fileURL: file))
        let texts = snapshot.excerpt.map(\.text)

        XCTAssertEqual(texts, ["shared question", "chosen question", "chosen answer"])
        XCTAssertFalse(texts.contains("abandoned answer"))
    }

    func testPartialContextIsMarkedWhenOnlyTailIsRead() throws {
        let root = PiSessionFixture.temporaryRoot(function: #function)
        let longQuestion = String(repeating: "context ", count: 80)
        let file = try PiSessionFixture.write(
            root: root,
            project: "--Users-example-Projects-training--",
            fileName: "partial.jsonl",
            objects: [
                PiSessionFixture.header(id: "session-partial", timestamp: time(minutesAgo: 40)),
                PiSessionFixture.user(id: "u1", parentID: nil, text: longQuestion, timestamp: time(minutesAgo: 30)),
                PiSessionFixture.assistant(id: "a1", parentID: "u1", text: "tail answer", timestamp: time(minutesAgo: 20)),
            ],
            modifiedAt: now
        )

        let snapshot = try XCTUnwrap(
            PiSessionScanner(rootURL: root, maximumTailBytes: 300).snapshot(fileURL: file)
        )

        XCTAssertTrue(snapshot.isPartialContext)
        XCTAssertEqual(snapshot.lastUserActivity, nil)
        XCTAssertEqual(snapshot.excerpt.map(\.text), ["tail answer"])
    }

    func testMalformedLinesAreSkippedAndMissingHeaderFailsClosed() throws {
        let root = PiSessionFixture.temporaryRoot(function: #function)
        let malformed = try PiSessionFixture.write(
            root: root,
            project: "--Users-example-Projects-training--",
            fileName: "malformed.jsonl",
            objects: [
                PiSessionFixture.header(id: "session-malformed", timestamp: time(minutesAgo: 20)),
                PiSessionFixture.user(id: "u1", parentID: nil, text: "still readable", timestamp: time(minutesAgo: 5)),
            ],
            rawLines: ["{\"type\":\"message\",\"id\":\"broken\"", "not json at all", "{\"type\":\"message\":"],
            modifiedAt: now
        )
        let headerless = try PiSessionFixture.write(
            root: root,
            project: "--Users-example-Projects-training--",
            fileName: "headerless.jsonl",
            objects: [
                PiSessionFixture.user(id: "u1", parentID: nil, text: "no header here", timestamp: time(minutesAgo: 5)),
            ],
            modifiedAt: now
        )

        let scanner = PiSessionScanner(rootURL: root)
        let snapshot = try XCTUnwrap(scanner.snapshot(fileURL: malformed))
        XCTAssertEqual(snapshot.excerpt.map(\.text), ["still readable"])
        XCTAssertNil(scanner.snapshot(fileURL: headerless))
    }

    func testHarnessNotificationsDoNotCountAsUserActivity() throws {
        let root = PiSessionFixture.temporaryRoot(function: #function)
        let file = try PiSessionFixture.write(
            root: root,
            project: "--Users-example-Projects-training--",
            fileName: "harness.jsonl",
            objects: [
                PiSessionFixture.header(id: "session-harness", timestamp: time(minutesAgo: 200)),
                PiSessionFixture.user(id: "u1", parentID: nil, text: "real question", timestamp: time(minutesAgo: 150)),
                PiSessionFixture.assistant(id: "a1", parentID: "u1", text: "real answer", timestamp: time(minutesAgo: 149)),
                PiSessionFixture.user(id: "u2", parentID: "a1", text: "<system-reminder>you have new mail</system-reminder>", timestamp: time(minutesAgo: 1)),
                PiSessionFixture.user(id: "u3", parentID: "u2", text: "[System] background job finished", timestamp: time(minutesAgo: 1)),
            ],
            modifiedAt: now
        )

        let snapshot = try XCTUnwrap(PiSessionScanner(rootURL: root).snapshot(fileURL: file))

        XCTAssertEqual(snapshot.excerpt.map(\.text), ["real question", "real answer"])
        XCTAssertEqual(
            snapshot.lastUserActivity?.timeIntervalSince1970 ?? 0,
            time(minutesAgo: 150).timeIntervalSince1970,
            accuracy: 1
        )
    }

    func testSymlinkedAndNestedSessionsAreIgnored() throws {
        let root = PiSessionFixture.temporaryRoot(function: #function)
        let direct = try PiSessionFixture.write(
            root: root,
            project: "--Users-example-Projects-training--",
            fileName: "direct.jsonl",
            objects: [
                PiSessionFixture.header(id: "session-direct", timestamp: time(minutesAgo: 10)),
                PiSessionFixture.user(id: "u1", parentID: nil, text: "direct text", timestamp: time(minutesAgo: 5)),
            ],
            modifiedAt: now
        )
        try PiSessionFixture.write(
            root: root,
            project: "--Users-example-Projects-training--/nested-artifacts",
            fileName: "nested.jsonl",
            objects: [
                PiSessionFixture.header(id: "session-nested", timestamp: time(minutesAgo: 10)),
                PiSessionFixture.user(id: "u1", parentID: nil, text: "nested text", timestamp: time(minutesAgo: 5)),
            ],
            modifiedAt: now
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("--Users-example-Projects-training--/link.jsonl"),
            withDestinationURL: direct
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked-project", isDirectory: true),
            withDestinationURL: root.appendingPathComponent("--Users-example-Projects-training--", isDirectory: true)
        )

        let sessionIDs = PiSessionScanner(rootURL: root).snapshots(now: now).map(\.sessionID)

        XCTAssertEqual(sessionIDs, ["session-direct"])
    }

    func testDuplicateSessionIDKeepsNewestActivity() throws {
        let root = PiSessionFixture.temporaryRoot(function: #function)
        try PiSessionFixture.write(
            root: root,
            project: "--Users-example-Projects-training--",
            fileName: "older.jsonl",
            objects: [
                PiSessionFixture.header(id: "session-duplicate", timestamp: time(minutesAgo: 200)),
                PiSessionFixture.user(id: "u1", parentID: nil, text: "older text", timestamp: time(minutesAgo: 150)),
            ],
            modifiedAt: now
        )
        try PiSessionFixture.write(
            root: root,
            project: "--Users-example-Projects-training--",
            fileName: "newer.jsonl",
            objects: [
                PiSessionFixture.header(id: "session-duplicate", timestamp: time(minutesAgo: 60)),
                PiSessionFixture.user(id: "u1", parentID: nil, text: "newer text", timestamp: time(minutesAgo: 30)),
            ],
            modifiedAt: now
        )

        let snapshots = PiSessionScanner(rootURL: root).snapshots(now: now)

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.excerpt.map(\.text), ["newer text"])
    }

    func testExcerptIsBoundedInLinesAndCharacters() throws {
        let root = PiSessionFixture.temporaryRoot(function: #function)
        let longText = String(repeating: "abcdefghij", count: 200)
        var objects: [[String: Any]] = [PiSessionFixture.header(id: "session-bounded", timestamp: time(minutesAgo: 120))]
        var parentID: String? = nil
        for index in 0..<30 {
            let user = PiSessionFixture.user(
                id: "u\(index)",
                parentID: parentID,
                text: "message \(index) \(longText)",
                timestamp: time(minutesAgo: Double(100 - index))
            )
            objects.append(user)
            parentID = "u\(index)"
        }
        let file = try PiSessionFixture.write(
            root: root,
            project: "--Users-example-Projects-training--",
            fileName: "bounded.jsonl",
            objects: objects,
            modifiedAt: now
        )

        let snapshot = try XCTUnwrap(PiSessionScanner(rootURL: root).snapshot(fileURL: file))
        let total = snapshot.excerpt.map(\.text.count).reduce(0, +)

        XCTAssertLessThanOrEqual(snapshot.excerpt.count, PiSessionScanner.maximumExcerptLines)
        XCTAssertLessThanOrEqual(total, PiSessionScanner.maximumExcerptCharacters + PiSessionScanner.maximumExcerptLines)
        XCTAssertTrue(snapshot.excerpt.last?.text.hasPrefix("message 29 ") ?? false)
    }

    func testTailWithoutUserTextFailsClosed() throws {
        // Large sessions can bury the last user turn under a multi-megabyte tool
        // result. The bounded tail then finds no genuine user text and the session
        // must be skipped rather than guessed at.
        let root = PiSessionFixture.temporaryRoot(function: #function)
        let file = try PiSessionFixture.write(
            root: root,
            project: "--Users-example-Projects-training--",
            fileName: "buried.jsonl",
            objects: [
                PiSessionFixture.header(id: "session-buried", timestamp: time(minutesAgo: 30)),
                PiSessionFixture.user(id: "u1", parentID: nil, text: "recent question", timestamp: time(minutesAgo: 5)),
                PiSessionFixture.toolResult(
                    id: "t1",
                    parentID: "u1",
                    text: String(repeating: "output line\n", count: 2_000),
                    timestamp: time(minutesAgo: 4)
                ),
            ],
            modifiedAt: now
        )

        let scanner = PiSessionScanner(rootURL: root, maximumTailBytes: 2_048)
        let snapshot = try XCTUnwrap(scanner.snapshot(fileURL: file))

        XCTAssertTrue(snapshot.isPartialContext)
        XCTAssertNil(snapshot.lastUserActivity)
        XCTAssertTrue(snapshot.excerpt.isEmpty)
        XCTAssertFalse(PiColleagueEligibility.isEligible(snapshot, now: now, calendar: .current))
        XCTAssertTrue(
            PiColleagueEligibility.candidates([snapshot], state: PiColleagueState(), now: now, calendar: .current).isEmpty
        )
    }

    func testLabelsAreSanitizedBasenamesWithoutFullPaths() throws {
        let root = PiSessionFixture.temporaryRoot(function: #function)
        let file = try PiSessionFixture.write(
            root: root,
            project: "--Users-example-Projects-training--",
            fileName: "labels.jsonl",
            objects: [
                PiSessionFixture.header(
                    id: "session-labels",
                    cwd: "/Users/example/Documents/Code/myapps/training",
                    timestamp: time(minutesAgo: 20)
                ),
                PiSessionFixture.user(id: "u1", parentID: nil, text: "question", timestamp: time(minutesAgo: 10)),
            ],
            modifiedAt: now
        )

        let snapshot = try XCTUnwrap(PiSessionScanner(rootURL: root).snapshot(fileURL: file))

        XCTAssertEqual(snapshot.projectLabel, "training")
        XCTAssertEqual(snapshot.displayLabel, "training · session-")
        XCTAssertFalse(snapshot.displayLabel.contains("/"))
        XCTAssertFalse(snapshot.displayLabel.contains("Users"))
    }

    func testLargeSessionIsReadWithinTheByteBudget() throws {
        // Real sessions reach tens of megabytes: the header read must not pull the
        // whole file in, and the tail must stop at its own budget.
        let root = PiSessionFixture.temporaryRoot(function: #function)
        let padding = String(repeating: "padding ", count: 900_000) // ~6.3 MB
        let file = try PiSessionFixture.write(
            root: root,
            project: "--Users-example-Projects-training--",
            fileName: "huge.jsonl",
            objects: [
                PiSessionFixture.header(id: "session-huge", timestamp: time(minutesAgo: 30)),
                [
                    "type": "custom",
                    "id": "padding",
                    "parentId": NSNull(),
                    "timestamp": PiSessionFixture.iso(time(minutesAgo: 29)),
                    "customType": "fixture.padding",
                    "data": padding,
                ],
                PiSessionFixture.user(id: "u1", parentID: nil, text: "recent question", timestamp: time(minutesAgo: 5)),
                PiSessionFixture.assistant(id: "a1", parentID: "u1", text: "recent answer", timestamp: time(minutesAgo: 4)),
            ],
            modifiedAt: now
        )
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 5 * 1024 * 1024, "fixture must be a realistically large session")

        let recorder = PiSessionReadRecorder()
        let scanner = PiSessionScanner(
            rootURL: root,
            maximumTailBytes: 4_096,
            readObserver: { recorder.record($0) }
        )
        let snapshot = try XCTUnwrap(scanner.snapshot(fileURL: file))

        XCTAssertEqual(snapshot.excerpt.map(\.text), ["recent question", "recent answer"])
        XCTAssertEqual(recorder.byteCounts.count, 2, "one header read and one tail read")
        XCTAssertLessThanOrEqual(
            recorder.byteCounts.max() ?? 0,
            PiSessionScanner.maximumHeaderBytes,
            "no read may exceed the byte budget"
        )
        XCTAssertLessThanOrEqual(
            recorder.byteCounts.reduce(0, +),
            64 * 1024,
            "a cadence must not read megabytes of a session"
        )
    }

    func testNativeWorkflowNotificationsAreNotUserActivity() throws {
        // Auto-generated notifications are recent, the only genuine user turn is stale.
        let root = PiSessionFixture.temporaryRoot(function: #function)
        let file = try PiSessionFixture.write(
            root: root,
            project: "--Users-example-Projects-training--",
            fileName: "native-notifications.jsonl",
            objects: [
                PiSessionFixture.header(id: "session-native", timestamp: time(minutesAgo: 400)),
                PiSessionFixture.user(
                    id: "u1",
                    parentID: nil,
                    text: "genuine question from this morning",
                    timestamp: time(minutesAgo: 320)
                ),
                PiSessionFixture.assistant(id: "a1", parentID: "u1", text: "genuine answer", timestamp: time(minutesAgo: 319)),
                PiSessionFixture.user(id: "u2", parentID: "a1", text: "Workflow child completed: refactor step", timestamp: time(minutesAgo: 1)),
                PiSessionFixture.user(id: "u3", parentID: "u2", text: "Background task completed: nightly job", timestamp: time(minutesAgo: 1)),
                PiSessionFixture.user(id: "u4", parentID: "u3", text: "Subagent finished: code review pass", timestamp: time(minutesAgo: 1)),
                PiSessionFixture.user(id: "u5", parentID: "u4", text: "Workflow completed", timestamp: time(minutesAgo: 1)),
                PiSessionFixture.user(id: "u6", parentID: "u5", text: "- Background task failed: upload retry", timestamp: time(minutesAgo: 1)),
            ],
            modifiedAt: now
        )

        let snapshot = try XCTUnwrap(PiSessionScanner(rootURL: root).snapshot(fileURL: file))

        XCTAssertEqual(snapshot.excerpt.map(\.text), ["genuine question from this morning", "genuine answer"])
        XCTAssertEqual(
            snapshot.lastUserActivity?.timeIntervalSince1970 ?? 0,
            time(minutesAgo: 320).timeIntervalSince1970,
            accuracy: 1
        )
        XCTAssertFalse(
            PiColleagueEligibility.isEligible(snapshot, now: now, calendar: .current),
            "automatic notifications alone must not make a session eligible"
        )
        XCTAssertTrue(
            PiColleagueEligibility
                .candidates([snapshot], state: PiColleagueState(), now: now, calendar: .current)
                .isEmpty
        )
    }

    func testWorkflowNotificationsDoNotHideRealUserDiscussion() throws {
        // Normal talk about subagents and workflows is user text and still counts.
        let root = PiSessionFixture.temporaryRoot(function: #function)
        let file = try PiSessionFixture.write(
            root: root,
            project: "--Users-example-Projects-training--",
            fileName: "user-talk.jsonl",
            objects: [
                PiSessionFixture.header(id: "session-talk", timestamp: time(minutesAgo: 30)),
                PiSessionFixture.user(id: "u1", parentID: nil, text: "the subagent crashed again", timestamp: time(minutesAgo: 4)),
                PiSessionFixture.assistant(id: "a1", parentID: "u1", text: "restarted it", timestamp: time(minutesAgo: 3)),
                PiSessionFixture.user(
                    id: "u2",
                    parentID: "a1",
                    text: "nice, the workflow completed cleanly after that",
                    timestamp: time(minutesAgo: 2)
                ),
                PiSessionFixture.user(
                    id: "u3",
                    parentID: "u2",
                    text: "subagent workers keep stealing my CPU",
                    timestamp: time(minutesAgo: 1)
                ),
            ],
            modifiedAt: now
        )

        let snapshot = try XCTUnwrap(PiSessionScanner(rootURL: root).snapshot(fileURL: file))

        XCTAssertEqual(
            snapshot.excerpt.map(\.text),
            [
                "the subagent crashed again",
                "restarted it",
                "nice, the workflow completed cleanly after that",
                "subagent workers keep stealing my CPU",
            ]
        )
        XCTAssertTrue(PiColleagueEligibility.isEligible(snapshot, now: now, calendar: .current))
    }
}
