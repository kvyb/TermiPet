import Foundation

public enum PiColleagueRejection: String, Equatable, Sendable {
    case empty
    case truncated
    case serverError
    case reasoningLeakage
    case tooLong
    case malformedStream
    case unexpectedFinishReason
    case missingSessionTag
    case mismatchedSessionTag
    case httpStatus
}

public enum PiColleagueResponseOutcome: Equatable, Sendable {
    case comment(String)
    case skip
    case rejected(PiColleagueRejection)
}

/// Incremental SSE reader for the humanlike endpoint.
///
/// The stream is only accepted when it terminates cleanly with `[DONE]` or a
/// `finish_reason` of `stop`. `length` counts as truncated, any other
/// `finish_reason`, `error` payloads and undecodable `data:` chunks are rejected,
/// and reasoning channels (`reasoning_content`, thinking/ChatML markers) are
/// rejected rather than shown. Accumulation stops as soon as the response cannot
/// be accepted any more, so a hostile or broken stream cannot grow without bound.
public struct PiColleagueStreamParser: Sendable {
    public static let doneMarker = "[DONE]"
    public static let maximumCommentCharacters = 2000

    private var buffer = ""
    private var sawTerminal = false
    private var sawReasoning = false
    private var truncated = false
    private var serverError = false
    private var malformedChunk = false
    private var unexpectedFinishReason = false
    private var oversized = false

    public init() {}

    public var isTerminal: Bool {
        sawTerminal || truncated || serverError || sawReasoning || malformedChunk || unexpectedFinishReason || oversized
    }

    public var text: String {
        buffer
    }

    /// Feeds one SSE line (`data: {...}` / `data: [DONE]`). Other SSE lines are ignored.
    public mutating func consume(sseLine line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return }
        let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty else { return } // Empty SSE heartbeats carry no model output.
        if payload == Self.doneMarker {
            sawTerminal = true
            return
        }
        consume(json: payload)
    }

    public mutating func consume(json: String) {
        guard let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            // An unreadable chunk may be half of a split payload: reject instead of
            // delivering a mangled comment.
            malformedChunk = true
            return
        }

        if object["error"] != nil {
            serverError = true
            return
        }
        guard let choices = object["choices"] as? [[String: Any]], let choice = choices.first else { return }

        if let delta = choice["delta"] as? [String: Any] {
            if Self.hasNonEmptyString(delta["reasoning_content"]) || Self.hasNonEmptyString(delta["reasoning"]) {
                sawReasoning = true
            }
            if let content = delta["content"] as? String {
                buffer += content
                if buffer.trimmingCharacters(in: .whitespacesAndNewlines).count > Self.maximumCommentCharacters {
                    oversized = true
                }
            }
        }

        if let finish = choice["finish_reason"] as? String {
            switch finish {
            case "stop":
                sawTerminal = true
            case "length":
                truncated = true
            case "error", "failed":
                serverError = true
            default:
                unexpectedFinishReason = true
            }
        }
    }

    public func outcome() -> PiColleagueResponseOutcome {
        if serverError { return .rejected(.serverError) }
        if sawReasoning { return .rejected(.reasoningLeakage) }
        if oversized { return .rejected(.tooLong) }
        if truncated { return .rejected(.truncated) }
        if malformedChunk { return .rejected(.malformedStream) }
        if unexpectedFinishReason { return .rejected(.unexpectedFinishReason) }
        guard sawTerminal else { return .rejected(.truncated) }

        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .rejected(.empty) }
        if trimmed.hasPrefix("[SKIP]") { return .skip }
        if trimmed.count > Self.maximumCommentCharacters { return .rejected(.tooLong) }
        if Self.containsReasoningMarkers(trimmed) { return .rejected(.reasoningLeakage) }
        return .comment(trimmed)
    }

    private static func hasNonEmptyString(_ value: Any?) -> Bool {
        guard let text = value as? String else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static let reasoningMarkers = [
        "<thinking>", "</thinking>", "<think>", "</think>",
        "<reasoning>", "</reasoning>", "<analysis>", "</analysis>",
        "<|im_start|>", "<|im_end|>", "<|assistant|>", "<|endoftext|>",
        "reasoning_content", "thinking process", "chain of thought", "思考过程",
    ]

    static func containsReasoningMarkers(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return reasoningMarkers.contains { lowered.contains($0) }
    }
}
