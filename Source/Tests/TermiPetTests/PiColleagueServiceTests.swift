import XCTest
@testable import TermiPet
@testable import TermiPetCore

final class PiColleagueServiceTests: XCTestCase {
    private let sandboxURL = URL(string: "https://api.lessthanthreeai.com/v1/chat/completions")!

    func testRequestCarriesTagSamplerAndNoCredentials() throws {
        let messages = PiColleaguePrompt.messages(
            excerpt: [PiSessionExcerptLine(role: .user, text: "wire the retry guard", timestamp: nil)]
        )
        let tag = PiColleagueSessionTag.make()

        let request = try PiColleagueService.makeRequest(messages: messages, sessionTag: tag)

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url, sandboxURL)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-session-id"), tag)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertEqual(request.timeoutInterval, PiColleagueEndpoint.resourceDeadline)

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(json["model"] as? String, "qwen3.8-27b-humanlike-chat")
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["max_tokens"] as? Int, 256)
        XCTAssertEqual(json["top_k"] as? Int, 20)
        XCTAssertEqual((json["temperature"] as? Double) ?? -1, 0.7, accuracy: 0.0001)
        XCTAssertEqual((json["top_p"] as? Double) ?? -1, 0.8, accuracy: 0.0001)
        XCTAssertEqual((json["min_p"] as? Double) ?? -1, 0.0, accuracy: 0.0001)
        XCTAssertEqual((json["presence_penalty"] as? Double) ?? -1, 1.5, accuracy: 0.0001)
        XCTAssertEqual((json["repetition_penalty"] as? Double) ?? -1, 1.0, accuracy: 0.0001)
        XCTAssertEqual((json["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool, false)

        let encodedMessages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(encodedMessages.map { $0["role"] as? String }, ["system", "user"])
        XCTAssertEqual(encodedMessages.first?["content"] as? String, PiColleaguePrompt.systemPrompt)
    }

    func testEveryRequestGetsANewTag() throws {
        let messages = [OllamaChatMessage(role: "user", content: "ping")]
        let first = try PiColleagueService.makeRequest(messages: messages, sessionTag: PiColleagueSessionTag.make())
        let second = try PiColleagueService.makeRequest(messages: messages, sessionTag: PiColleagueSessionTag.make())

        XCTAssertNotEqual(
            first.value(forHTTPHeaderField: "x-session-id"),
            second.value(forHTTPHeaderField: "x-session-id")
        )
    }

    func testResponseValidationRejectsStatusAndTagProblems() {
        let tag = PiColleagueSessionTag.make()

        XCTAssertNoThrow(try PiColleagueService.validate(status: 200, echoedTag: tag, sentTag: tag))
        XCTAssertThrowsError(try PiColleagueService.validate(status: 502, echoedTag: tag, sentTag: tag)) { error in
            XCTAssertEqual(error as? PiColleagueServiceError, .httpStatus(502))
        }
        XCTAssertThrowsError(try PiColleagueService.validate(status: 200, echoedTag: nil, sentTag: tag)) { error in
            XCTAssertEqual(error as? PiColleagueServiceError, .missingSessionTag)
        }
        XCTAssertThrowsError(
            try PiColleagueService.validate(status: 200, echoedTag: PiColleagueSessionTag.make(), sentTag: tag)
        ) { error in
            XCTAssertEqual(error as? PiColleagueServiceError, .mismatchedSessionTag)
        }
    }

    func testFailedRequestOutcomesAreClassifiedForProvenance() {
        XCTAssertEqual(
            PiColleagueService.requestOutcome(for: PiColleagueServiceError.missingSessionTag),
            .tagMissing
        )
        XCTAssertEqual(
            PiColleagueService.requestOutcome(for: PiColleagueServiceError.mismatchedSessionTag),
            .tagMismatch
        )
        XCTAssertEqual(PiColleagueService.requestOutcome(for: PiColleagueServiceError.httpStatus(502)), .httpStatus)
        XCTAssertEqual(PiColleagueService.requestOutcome(for: PiColleagueServiceError.invalidResponse), .httpStatus)
        XCTAssertEqual(PiColleagueService.requestOutcome(for: URLError(.timedOut)), .failed)
        XCTAssertEqual(PiColleagueService.requestOutcome(for: CancellationError()), .cancelled)
        XCTAssertEqual(PiColleagueService.requestOutcome(for: URLError(.cancelled)), .cancelled)
    }
}
