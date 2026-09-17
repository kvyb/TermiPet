import Foundation
@testable import TermiPetCore

/// Synthetic Pi session files. No real session content is ever read by tests.
enum PiSessionFixture {
    static func temporaryRoot(function: String = #function) -> URL {
        let safeName = function.replacingOccurrences(of: "(", with: "-").replacingOccurrences(of: ")", with: "")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("termipet-pi-fixtures", isDirectory: true)
            .appendingPathComponent(safeName + "-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func iso(_ date: Date) -> String {
        Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date)
    }

    static func header(id: String, cwd: String = "/Users/example/Projects/training", timestamp: Date) -> [String: Any] {
        [
            "type": "session",
            "version": 3,
            "id": id,
            "timestamp": iso(timestamp),
            "cwd": cwd,
        ]
    }

    static func user(id: String, parentID: String?, text: String, timestamp: Date) -> [String: Any] {
        [
            "type": "message",
            "id": id,
            "parentId": parentID as Any,
            "timestamp": iso(timestamp),
            "message": [
                "role": "user",
                "content": text,
                "timestamp": timestamp.timeIntervalSince1970 * 1000,
            ],
        ]
    }

    static func assistant(id: String, parentID: String?, text: String, timestamp: Date) -> [String: Any] {
        [
            "type": "message",
            "id": id,
            "parentId": parentID as Any,
            "timestamp": iso(timestamp),
            "message": [
                "role": "assistant",
                "content": [["type": "text", "text": text]],
                "stopReason": "stop",
                "timestamp": timestamp.timeIntervalSince1970 * 1000,
            ],
        ]
    }

    /// Assistant message with mixed blocks: thinking, tool call and text.
    static func assistantMixed(id: String, parentID: String?, text: String, timestamp: Date) -> [String: Any] {
        [
            "type": "message",
            "id": id,
            "parentId": parentID as Any,
            "timestamp": iso(timestamp),
            "message": [
                "role": "assistant",
                "content": [
                    ["type": "thinking", "thinking": "SECRET_THINKING_MARKER"],
                    ["type": "toolCall", "id": "call_1", "name": "bash", "arguments": ["command": "SECRET_TOOL_COMMAND"]],
                    ["type": "text", "text": text],
                ],
                "stopReason": "toolUse",
            ],
        ]
    }

    static func toolResult(id: String, parentID: String?, text: String, timestamp: Date) -> [String: Any] {
        [
            "type": "message",
            "id": id,
            "parentId": parentID as Any,
            "timestamp": iso(timestamp),
            "message": [
                "role": "toolResult",
                "toolCallId": "call_1",
                "toolName": "bash",
                "content": [["type": "text", "text": text]],
                "isError": false,
            ],
        ]
    }

    static func compaction(id: String, parentID: String?, summary: String, timestamp: Date) -> [String: Any] {
        [
            "type": "compaction",
            "id": id,
            "parentId": parentID as Any,
            "timestamp": iso(timestamp),
            "summary": summary,
            "tokensBefore": 12000,
        ]
    }

    static func customMessage(id: String, parentID: String?, content: String, timestamp: Date) -> [String: Any] {
        [
            "type": "custom_message",
            "id": id,
            "parentId": parentID as Any,
            "timestamp": iso(timestamp),
            "customType": "example.extension",
            "content": content,
            "display": true,
        ]
    }

    static func sessionInfo(id: String, parentID: String?, name: String, timestamp: Date) -> [String: Any] {
        [
            "type": "session_info",
            "id": id,
            "parentId": parentID as Any,
            "timestamp": iso(timestamp),
            "name": name,
        ]
    }

    @discardableResult
    static func write(
        root: URL,
        project: String,
        fileName: String,
        objects: [[String: Any]],
        rawLines: [String] = [],
        modifiedAt: Date? = nil
    ) throws -> URL {
        let directory = root.appendingPathComponent(project, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName)

        var lines: [String] = []
        for object in objects {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            lines.append(String(decoding: data, as: UTF8.self))
        }
        lines.append(contentsOf: rawLines)
        let content = lines.joined(separator: "\n") + "\n"
        try content.write(to: url, atomically: true, encoding: .utf8)

        if let modifiedAt {
            try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        }
        return url
    }
}

/// Deterministic generator so randomized gaps are reproducible in tests.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed &+ 0x9E3779B97F4A7C15
    }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Records the byte count of every scanner read (test seam).
final class PiSessionReadRecorder: @unchecked Sendable {
    private(set) var byteCounts: [Int] = []

    func record(_ count: Int) {
        byteCounts.append(count)
    }
}
