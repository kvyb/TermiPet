import Foundation
import TermiPetCore

enum PiColleagueServiceError: LocalizedError, Equatable {
    case invalidResponse
    case httpStatus(Int)
    case missingSessionTag
    case mismatchedSessionTag

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "invalid response"
        case .httpStatus(let status): return "HTTP \(status)"
        case .missingSessionTag: return "missing x-session-id echo"
        case .mismatchedSessionTag: return "x-session-id echo mismatch"
        }
    }
}

/// Streaming client for the owner's humanlike endpoint.
///
/// Every request carries a unique `x-session-id` tag and the echoed header is
/// validated before any text is used. No API key is sent, no Authorization
/// header is added, and no request or response body is ever logged.
struct PiColleagueService {
    static let sessionTagHeader = "x-session-id"

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
            return
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = PiColleagueEndpoint.resourceDeadline
        configuration.timeoutIntervalForResource = PiColleagueEndpoint.resourceDeadline
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    static func makeRequest(
        messages: [OllamaChatMessage],
        sessionTag: String,
        url: URL = PiColleagueEndpoint.url
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = PiColleagueEndpoint.resourceDeadline
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(sessionTag, forHTTPHeaderField: sessionTagHeader)
        request.httpBody = try JSONEncoder().encode(Self.body(messages: messages))
        return request
    }

    /// Streams one comment. Throws on transport errors, HTTP failures and tag
    /// mismatches; cancellation propagates and is left to the caller to ignore.
    func comment(messages: [OllamaChatMessage], sessionTag: String) async throws -> PiColleagueResponseOutcome {
        let request = try Self.makeRequest(messages: messages, sessionTag: sessionTag)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PiColleagueServiceError.invalidResponse
        }
        try Self.validate(
            status: http.statusCode,
            echoedTag: http.value(forHTTPHeaderField: Self.sessionTagHeader),
            sentTag: sessionTag
        )

        var parser = PiColleagueStreamParser()
        for try await line in bytes.lines {
            parser.consume(sseLine: line)
            if parser.isTerminal { break }
        }
        return parser.outcome()
    }

    static func validate(status: Int, echoedTag: String?, sentTag: String) throws {
        guard (200..<300).contains(status) else {
            throw PiColleagueServiceError.httpStatus(status)
        }
        guard let echoedTag else {
            throw PiColleagueServiceError.missingSessionTag
        }
        guard echoedTag == sentTag else {
            throw PiColleagueServiceError.mismatchedSessionTag
        }
    }

    /// Local provenance classification for a failed request. No body or history is
    /// involved: it only says whether the sent tag could be verified.
    static func requestOutcome(for error: Error) -> PiColleagueRequestRecord.Outcome {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return .cancelled }
        guard let serviceError = error as? PiColleagueServiceError else { return .failed }
        switch serviceError {
        case .missingSessionTag:
            return .tagMissing
        case .mismatchedSessionTag:
            return .tagMismatch
        case .httpStatus, .invalidResponse:
            return .httpStatus
        }
    }

    // Wire format keys are snake_case by API contract.
    private struct Body: Encodable {
        let model: String
        let messages: [OllamaChatMessage]
        let stream: Bool
        let max_tokens: Int
        let temperature: Double
        let top_p: Double
        let top_k: Int
        let min_p: Double
        let presence_penalty: Double
        let repetition_penalty: Double
        let chat_template_kwargs: ChatTemplateKwargs

        struct ChatTemplateKwargs: Encodable {
            let enable_thinking: Bool
        }
    }

    private static func body(messages: [OllamaChatMessage]) -> Body {
        Body(
            model: PiColleagueEndpoint.model,
            messages: messages,
            stream: true,
            max_tokens: PiColleagueEndpoint.maximumResponseTokens,
            temperature: PiColleagueSampling.temperature,
            top_p: PiColleagueSampling.topP,
            top_k: PiColleagueSampling.topK,
            min_p: PiColleagueSampling.minP,
            presence_penalty: PiColleagueSampling.presencePenalty,
            repetition_penalty: PiColleagueSampling.repetitionPenalty,
            chat_template_kwargs: Body.ChatTemplateKwargs(enable_thinking: PiColleagueSampling.enableThinking)
        )
    }
}
