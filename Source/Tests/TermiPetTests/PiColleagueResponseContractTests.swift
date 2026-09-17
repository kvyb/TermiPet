import XCTest
@testable import TermiPetCore

final class PiColleagueResponseContractTests: XCTestCase {
    private func parse(_ lines: [String]) -> PiColleagueResponseOutcome {
        var parser = PiColleagueStreamParser()
        for line in lines {
            parser.consume(sseLine: line)
        }
        return parser.outcome()
    }

    func testStreamingCommentIsAssembledUntilFinishReason() {
        let outcome = parse([
            "data: {\"choices\":[{\"delta\":{\"content\":\"That \"},\"finish_reason\":null}]}",
            "",
            "data: {\"choices\":[{\"delta\":{\"content\":\"p95 spike is \"},\"finish_reason\":null}]}",
            "data: {\"choices\":[{\"delta\":{\"content\":\"worth a look.\"},\"finish_reason\":\"stop\"}]}",
        ])

        XCTAssertEqual(outcome, .comment("That p95 spike is worth a look."))
    }

    func testDoneMarkerTerminatesWithoutFinishReason() {
        let outcome = parse([
            "data: {\"choices\":[{\"delta\":{\"content\":\"Short.\"}}]}",
            "data: [DONE]",
        ])

        XCTAssertEqual(outcome, .comment("Short."))
    }

    func testMissingTerminalMarkerIsTruncated() {
        let outcome = parse([
            "data: {\"choices\":[{\"delta\":{\"content\":\"half a thou\"}}]}",
        ])

        XCTAssertEqual(outcome, .rejected(.truncated))
    }

    func testLengthFinishReasonIsTruncated() {
        let outcome = parse([
            "data: {\"choices\":[{\"delta\":{\"content\":\"this got cut\"},\"finish_reason\":\"length\"}]}",
            "data: [DONE]",
        ])

        XCTAssertEqual(outcome, .rejected(.truncated))
    }

    func testServerErrorIsRejected() {
        XCTAssertEqual(parse(["data: {\"error\":{\"message\":\"upstream failed\"}}"]), .rejected(.serverError))
        XCTAssertEqual(
            parse([
                "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"error\"}]}",
                "data: [DONE]",
            ]),
            .rejected(.serverError)
        )
    }

    func testReasoningChannelsAreRejected() {
        let reasoningDelta = parse([
            "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"let me think\"}}]}",
            "data: {\"choices\":[{\"delta\":{\"content\":\"Answer\"}}]}",
            "data: [DONE]",
        ])
        let reasoningText = parse([
            "data: {\"choices\":[{\"delta\":{\"content\":\"<thinking>internal</thinking> Answer\"}}]}",
            "data: [DONE]",
        ])

        XCTAssertEqual(reasoningDelta, .rejected(.reasoningLeakage))
        XCTAssertEqual(reasoningText, .rejected(.reasoningLeakage))
    }

    func testSkipIsSuppressed() {
        XCTAssertEqual(parse(["data: {\"choices\":[{\"delta\":{\"content\":\"[SKIP]\"}}]}", "data: [DONE]"]), .skip)
        XCTAssertEqual(parse(["data: {\"choices\":[{\"delta\":{\"content\":\"[SKIP] nothing new\"}}]}", "data: [DONE]"]), .skip)
    }

    func testEmptyResponseIsRejected() {
        XCTAssertEqual(parse(["data: [DONE]"]), .rejected(.empty))
        XCTAssertEqual(parse(["data: {\"choices\":[{\"delta\":{\"content\":\"   \"}}]}", "data: [DONE]"]), .rejected(.empty))
    }

    func testOversizedResponseIsRejected() {
        let huge = String(repeating: "x", count: PiColleagueStreamParser.maximumCommentCharacters + 10)
        let outcome = parse([
            "data: {\"choices\":[{\"delta\":{\"content\":\"\(huge)\"},\"finish_reason\":\"stop\"}]}",
        ])

        XCTAssertEqual(outcome, .rejected(.tooLong))
    }

    func testNonDataSseLinesAreIgnored() {
        let outcome = parse([
            ": keep-alive",
            "event: message",
            "",
            "data: {\"choices\":[{\"delta\":{\"content\":\"fine\"},\"finish_reason\":\"stop\"}]}",
        ])

        XCTAssertEqual(outcome, .comment("fine"))
    }

    func testEmptyDataHeartbeatDoesNotRejectTheStream() {
        var parser = PiColleagueStreamParser()
        parser.consume(sseLine: "data: ")
        XCTAssertFalse(parser.isTerminal)
        parser.consume(sseLine: #"data: {"choices":[{"delta":{"content":"nice"},"finish_reason":"stop"}]}"#)
        XCTAssertEqual(parser.outcome(), .comment("nice"))
    }

    func testMalformedDataChunkIsRejected() {
        // A payload split across two data lines must never be stitched into a comment.
        let outcome = parse([
            "data: {\"choices\":[{\"delta\":{\"content\":\"half",
            "data: a sentence\"}}]}",
            "data: [DONE]",
        ])

        XCTAssertEqual(outcome, .rejected(.malformedStream))
    }

    func testUnknownFinishReasonIsRejected() {
        for finish in ["tool_calls", "content_filter", "pause", "weird"] {
            let outcome = parse([
                "data: {\"choices\":[{\"delta\":{\"content\":\"text\"},\"finish_reason\":\"\(finish)\"}]}",
                "data: [DONE]",
            ])
            XCTAssertEqual(outcome, .rejected(.unexpectedFinishReason), finish)
        }
    }

    func testThinkAndChatMLMarkersAreRejected() {
        let markers = ["<think>hmm</think> Answer", "\u{1F914} <|im_start|>system<|im_end|>", "<analysis>x</analysis> text"]
        for text in markers {
            let outcome = parse([
                "data: {\"choices\":[{\"delta\":{\"content\":\"\(text)\"},\"finish_reason\":\"stop\"}]}",
            ])
            XCTAssertEqual(outcome, .rejected(.reasoningLeakage), text)
        }
    }

    func testAccumulationIsBoundedDuringTheStream() {
        var parser = PiColleagueStreamParser()
        let chunk = String(repeating: "x", count: 500)
        for _ in 0..<6 {
            parser.consume(json: #"{"choices":[{"delta":{"content":"\#(chunk)"}}]}"#)
        }

        // No terminal marker yet: the in-flight cap must already stop the stream.
        XCTAssertTrue(parser.isTerminal)
        XCTAssertEqual(parser.outcome(), .rejected(.tooLong))
    }

    func testReasoningStopsTheStreamEarly() {
        var parser = PiColleagueStreamParser()
        parser.consume(sseLine: "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"thinking\"}}]}")

        XCTAssertTrue(parser.isTerminal)
        XCTAssertEqual(parser.outcome(), .rejected(.reasoningLeakage))
    }

    func testSessionTagsAreUniqueAndWellFormed() {
        var seen: Set<String> = []
        for _ in 0..<500 {
            let tag = PiColleagueSessionTag.make()
            XCTAssertTrue(PiColleagueSessionTag.isValid(tag), tag)
            XCTAssertTrue(tag.hasPrefix("internal-termipet-"))
            XCTAssertTrue((8...64).contains(tag.count))
            seen.insert(tag)
        }
        XCTAssertEqual(seen.count, 500)

        XCTAssertFalse(PiColleagueSessionTag.isValid("internal-termipet-"))
        XCTAssertFalse(PiColleagueSessionTag.isValid("other-agent-0123456789"))
        XCTAssertFalse(PiColleagueSessionTag.isValid("internal-termipet-" + String(repeating: "x", count: 60)))
        XCTAssertFalse(PiColleagueSessionTag.isValid("internal-termipet-abc$def"))
    }

    func testSamplerAndDeadlineMatchTheContract() {
        XCTAssertEqual(PiColleagueEndpoint.urlString, "https://api.lessthanthreeai.com/v1/chat/completions")
        XCTAssertEqual(PiColleagueEndpoint.model, "qwen3.8-27b-humanlike-chat")
        XCTAssertEqual(PiColleagueEndpoint.resourceDeadline, 240)
        XCTAssertEqual(PiColleagueEndpoint.maximumResponseTokens, 256)
        XCTAssertEqual(PiColleagueSampling.temperature, 0.7)
        XCTAssertEqual(PiColleagueSampling.topP, 0.8)
        XCTAssertEqual(PiColleagueSampling.topK, 20)
        XCTAssertEqual(PiColleagueSampling.minP, 0.0)
        XCTAssertEqual(PiColleagueSampling.presencePenalty, 1.5)
        XCTAssertEqual(PiColleagueSampling.repetitionPenalty, 1.0)
        XCTAssertFalse(PiColleagueSampling.enableThinking)
    }
}
