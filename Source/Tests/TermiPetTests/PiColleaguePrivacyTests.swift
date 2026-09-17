import XCTest
@testable import TermiPetCore

final class PiColleaguePrivacyTests: XCTestCase {
    func testCredentialShapesAreMasked() {
        let cases = [
            "export API_KEY=sk-abcdef0123456789",
            "Authorization: Bearer ghp_0123456789abcdefghij",
            "password: hunter2secret",
            "AWS key AKIAIOSFODNN7EXAMPLE",
            "-----BEGIN RSA PRIVATE KEY-----",
            "session cookie value eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0",
        ]

        for input in cases {
            let redacted = PiColleagueRedactor.redact(input)
            XCTAssertTrue(
                redacted.contains(PiColleagueRedactor.maskedCredential) || redacted.contains(PiColleagueRedactor.maskedEmail),
                "not masked: \(input) -> \(redacted)"
            )
            XCTAssertFalse(redacted.contains("sk-abcdef0123456789"))
            XCTAssertFalse(redacted.contains("ghp_0123456789abcdefghij"))
            XCTAssertFalse(redacted.contains("hunter2secret"))
            XCTAssertFalse(redacted.contains("AKIAIOSFODNN7EXAMPLE"))
            XCTAssertFalse(redacted.contains("eyJhbGciOiJIUzI1NiJ9"))
        }
    }

    func testContactDetailsAreMasked() {
        let redacted = PiColleagueRedactor.redact("write to dev@example.com or call 41555501234")

        XCTAssertTrue(redacted.contains(PiColleagueRedactor.maskedEmail))
        XCTAssertTrue(redacted.contains(PiColleagueRedactor.maskedNumber))
        XCTAssertFalse(redacted.contains("dev@example.com"))
        XCTAssertFalse(redacted.contains("41555501234"))
    }

    func testHomeDirectoryPathsAreShortened() {
        let redacted = PiColleagueRedactor.redact("/Users/example/Documents/Code/TermiPet/Source/main.swift broke")

        XCTAssertEqual(redacted, "~/Documents/Code/TermiPet/Source/main.swift broke")
    }

    func testOrdinaryProseSurvives() {
        let input = "The reconnect test is flaky again, but the retry guard looks right."

        XCTAssertEqual(PiColleagueRedactor.redact(input), input)
    }

    func testExcerptPromptKeepsColleagueVoiceAndRedactsBeforeSending() {
        let excerpt = [
            PiSessionExcerptLine(role: .user, text: "can you check the token=abc1234567890123 rotation", timestamp: nil),
            PiSessionExcerptLine(role: .assistant, text: "I rotated it and reran the suite.", timestamp: nil),
        ]

        let messages = PiColleaguePrompt.messages(excerpt: excerpt)

        XCTAssertEqual(messages.map(\.role), ["system", "user"])
        XCTAssertEqual(messages.first?.content, PiColleaguePrompt.systemPrompt)
        XCTAssertTrue(messages.first?.content.contains("untrusted context") ?? false)
        XCTAssertFalse(messages.first?.content.contains("桌面宠物") ?? true)
        XCTAssertTrue(messages.last?.content.contains(PiColleaguePrompt.excerptHeader) ?? false)
        XCTAssertTrue(messages.last?.content.contains("[user] can you check") ?? false)
        XCTAssertFalse(messages.last?.content.contains("abc1234567890123") ?? true)
    }

    func testReplyContextIsBoundedAndKeepsOneVoice() {
        var history: [ChatMessage] = []
        for index in 0..<20 {
            history.append(ChatMessage(role: index.isMultiple(of: 2) ? .user : .assistant, content: "message \(index) " + String(repeating: "x", count: 900)))
        }

        let messages = PiColleaguePrompt.replyMessages(history: history, reply: "thanks, that helps")

        XCTAssertEqual(messages.first?.role, "system")
        XCTAssertEqual(messages.first?.content, PiColleaguePrompt.systemPrompt)
        XCTAssertEqual(messages.last, OllamaChatMessage(role: "user", content: "thanks, that helps"))
        XCTAssertLessThanOrEqual(messages.count, PiColleaguePrompt.maximumReplyHistoryMessages + 2)
        let characters = messages.map(\.content.count).reduce(0, +)
        XCTAssertLessThanOrEqual(
            characters,
            PiColleaguePrompt.maximumReplyHistoryCharacters + PiColleaguePrompt.systemPrompt.count + "thanks, that helps".count
        )
    }

    func testReplyTextIsRedacted() {
        let messages = PiColleaguePrompt.replyMessages(history: [], reply: "my api_key=supersecretvalue123 expired")

        XCTAssertFalse(messages.last?.content.contains("supersecretvalue123") ?? true)
        XCTAssertTrue(messages.last?.content.contains(PiColleagueRedactor.maskedCredential) ?? false)
    }

    func testCliFlagsAndSpaceSeparatedKeysAreMasked() {
        let cases = [
            "node --token=abcdef1234567890abcdef1234567890 server.js",
            "The client_secret 8f14e45fceea167a5a36dedd4bea2543 must rotate",
            "export AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        ]

        for input in cases {
            let redacted = PiColleagueRedactor.redact(input)
            XCTAssertTrue(redacted.contains(PiColleagueRedactor.maskedCredential), "not masked: \(input) -> \(redacted)")
        }
        XCTAssertFalse(PiColleagueRedactor.redact(cases[0]).contains("abcdef1234567890abcdef1234567890"))
        XCTAssertFalse(PiColleagueRedactor.redact(cases[1]).contains("8f14e45fceea167a5a36dedd4bea2543"))
        XCTAssertFalse(PiColleagueRedactor.redact(cases[2]).contains("wJalrXUtnFEMI"))
    }

    func testOrdinaryProseAroundKeyWordsStaysReadable() {
        XCTAssertEqual(PiColleagueRedactor.redact("the token expired"), "the token expired")
        XCTAssertEqual(PiColleagueRedactor.redact("secret ingredient found"), "secret ingredient found")
        XCTAssertEqual(PiColleagueRedactor.redact("password incorrect"), "password incorrect")
    }

    func testRedactionIsIdempotent() {
        let inputs = [
            "see /opt/homebrew/etc/nginx.conf and Package.swift",
            "~/Documents/Code/TermiPet/Source/very/long/path/that/exceeds/the/character/limit/main.swift",
            "node --token=abcdef1234567890abcdef1234567890 server.js",
            "write to dev@example.com or call 41555501234",
            "an ordinary sentence about the retry queue",
        ]

        for input in inputs {
            let once = PiColleagueRedactor.redact(input)
            XCTAssertEqual(PiColleagueRedactor.redact(once), once, "not idempotent: \(input)")
        }
    }

    func testReplyContextCarriesTheThreadExcerptAndStaysBounded() {
        let excerptLines = PiColleaguePrompt.redactedExcerptLines([
            PiSessionExcerptLine(role: .user, text: "the retry queue keeps growing", timestamp: nil),
            PiSessionExcerptLine(role: .assistant, text: "moved it into a bounded queue", timestamp: nil),
        ])
        let history = [ChatMessage(role: .assistant, content: "Nice, that queue fix is the right shape.")]

        let messages = PiColleaguePrompt.replyMessages(history: history, excerptLines: excerptLines, reply: "thanks")

        XCTAssertEqual(messages.map(\.role), ["system", "user", "assistant", "user"])
        XCTAssertTrue(messages[1].content.contains(PiColleaguePrompt.replyContextNote))
        XCTAssertTrue(messages[1].content.contains("[user] the retry queue keeps growing"))
        XCTAssertEqual(messages[2].content, "Nice, that queue fix is the right shape.")
        XCTAssertEqual(messages[3].content, "thanks")
    }

    func testPartialExcerptIsMarkedForTheModel() {
        let lines = PiColleaguePrompt.redactedExcerptLines([
            PiSessionExcerptLine(role: .assistant, text: "tail answer", timestamp: nil),
        ])

        let full = PiColleaguePrompt.messages(redactedLines: lines)
        let partial = PiColleaguePrompt.messages(redactedLines: lines, isPartial: true)

        XCTAssertEqual(full.count, 2)
        XCTAssertFalse(full[1].content.contains(PiColleaguePrompt.partialNote))
        XCTAssertTrue(partial[1].content.contains(PiColleaguePrompt.partialNote))
        XCTAssertTrue(partial[1].content.contains("[assistant] tail answer"))
    }
}
