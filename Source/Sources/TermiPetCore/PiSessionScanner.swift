import Foundation

/// One recent piece of text from a Pi session file.
///
/// Only user and assistant text is ever collected. System prompts, thinking
/// blocks, tool calls, tool results, images, compaction/branch summaries and
/// extension entries are ignored by the scanner.
public struct PiSessionExcerptLine: Equatable, Sendable {
    public enum Role: String, Equatable, Sendable {
        case user
        case assistant
    }

    public let role: Role
    public let text: String
    public let timestamp: Date?

    public init(role: Role, text: String, timestamp: Date?) {
        self.role = role
        self.text = text
        self.timestamp = timestamp
    }
}

/// A bounded, local-only view of one Pi session file.
///
/// The snapshot never contains full paths, and nothing in it leaves the machine
/// until `PiColleagueRedactor` has processed the excerpt.
public struct PiSessionSnapshot: Equatable, Sendable {
    public let sessionID: String
    public let projectLabel: String?
    public let sessionLabel: String?
    public let lastUserActivity: Date?
    public let excerpt: [PiSessionExcerptLine]
    /// True when the active branch could not be walked to its root because only a
    /// bounded tail of the file was read. The excerpt is then a partial view.
    public let isPartialContext: Bool
    public let fileURL: URL

    public init(
        sessionID: String,
        projectLabel: String?,
        sessionLabel: String?,
        lastUserActivity: Date?,
        excerpt: [PiSessionExcerptLine],
        isPartialContext: Bool,
        fileURL: URL
    ) {
        self.sessionID = sessionID
        self.projectLabel = projectLabel
        self.sessionLabel = sessionLabel
        self.lastUserActivity = lastUserActivity
        self.excerpt = excerpt
        self.isPartialContext = isPartialContext
        self.fileURL = fileURL
    }

    public var shortSessionID: String {
        String(sessionID.prefix(8))
    }

    /// Local UI label. Never sent to any API.
    public var displayLabel: String {
        switch (projectLabel, sessionLabel) {
        case let (project?, name?):
            return "\(project) · \(name)"
        case let (project?, nil):
            return "\(project) · \(shortSessionID)"
        case let (nil, name?):
            return name
        case (nil, nil):
            return shortSessionID
        }
    }
}

/// Reads Pi session JSONL files without loading whole histories.
///
/// Layout: `~/.pi/agent/sessions/<project>/*.jsonl`. Only regular, non-symlinked
/// files directly inside project directories are scanned; nested subagent
/// sessions and artifact folders are never touched.
///
/// Session files carry no message origin metadata (user entries only have
/// role/content/timestamp), so synthetic harness notifications are excluded by
/// their known framing instead of by a source field.
public struct PiSessionScanner: Sendable {
    public static let defaultRootURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".pi/agent/sessions", isDirectory: true)

    /// Bytes read from the end of a session file (the active branch).
    ///
    /// Real Pi sessions reach tens of megabytes, so this stays a bounded tail read:
    /// a 512 KiB tail was measured to contain the last handful of user messages in
    /// live sessions of 11-33 MB. Anything older is never read.
    public static let maximumTailBytes = 512 * 1024
    /// Bytes read from the start of a session file (the header line).
    public static let maximumHeaderBytes = 16 * 1024
    /// A session counts as "recent" only when real user text is within this window.
    public static let activityWindow: TimeInterval = 3 * 60 * 60
    public static let maximumExcerptLines = 8
    public static let maximumExcerptCharacters = 2400
    public static let maximumLineCharacters = 600
    public static let maximumChainLength = 400
    /// Cheap pre-filter only. Eligibility is always re-checked against in-file timestamps.
    public static let modificationSlack: TimeInterval = 60 * 60

    public let rootURL: URL
    public let maximumTailBytes: Int
    let readObserver: (@Sendable (Int) -> Void)?

    public init(
        rootURL: URL = PiSessionScanner.defaultRootURL,
        maximumTailBytes: Int = PiSessionScanner.maximumTailBytes
    ) {
        self.init(rootURL: rootURL, maximumTailBytes: maximumTailBytes, readObserver: nil)
    }

    /// Internal seam: tests assert that no read exceeds the byte budget.
    init(rootURL: URL, maximumTailBytes: Int, readObserver: (@Sendable (Int) -> Void)?) {
        self.rootURL = rootURL
        self.maximumTailBytes = maximumTailBytes
        self.readObserver = readObserver
    }

    /// All snapshots that could plausibly contain recent activity, newest user
    /// activity first. Files with the same session ID collapse to the newest one.
    public func snapshots(now: Date = Date()) -> [PiSessionSnapshot] {
        var bySessionID: [String: PiSessionSnapshot] = [:]
        for fileURL in recentSessionFiles(now: now) {
            guard let snapshot = snapshot(fileURL: fileURL) else { continue }
            if let existing = bySessionID[snapshot.sessionID],
               (existing.lastUserActivity ?? .distantPast) >= (snapshot.lastUserActivity ?? .distantPast) {
                continue
            }
            bySessionID[snapshot.sessionID] = snapshot
        }
        return bySessionID.values.sorted { lhs, rhs in
            let left = lhs.lastUserActivity ?? .distantPast
            let right = rhs.lastUserActivity ?? .distantPast
            if left != right { return left > right }
            return lhs.sessionID < rhs.sessionID
        }
    }

    public func recentSessionFiles(now: Date = Date()) -> [URL] {
        let fileManager = FileManager.default
        guard let projects = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) else {
            return []
        }

        let cutoff = now.addingTimeInterval(-(Self.activityWindow + Self.modificationSlack))
        var files: [URL] = []
        for project in projects where Self.isRealDirectory(project) {
            guard let children = try? fileManager.contentsOfDirectory(
                at: project,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
            ) else {
                continue
            }
            for child in children where child.pathExtension == "jsonl" && Self.isRealFile(child) {
                let values = try? child.resourceValues(forKeys: [.contentModificationDateKey])
                guard let modified = values?.contentModificationDate, modified >= cutoff else { continue }
                files.append(child)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    public func snapshot(fileURL: URL) -> PiSessionSnapshot? {
        guard let headerRead = readBounded(fileURL, fromEnd: false, maximumBytes: Self.maximumHeaderBytes),
              let header = Self.sessionHeader(lines: Self.lines(in: headerRead.data, droppingFirstPartialLine: false))
        else {
            return nil
        }

        let tail = readBounded(fileURL, fromEnd: true, maximumBytes: maximumTailBytes)
        guard let tailData = tail?.data else { return nil }
        let entries = Self.entries(lines: Self.lines(in: tailData, droppingFirstPartialLine: tail?.startedMidFile ?? false))

        let projectLabel = Self.sanitizedLabel(
            header.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
        )
        let sessionLabel = Self.sanitizedLabel(entries.compactMap(\.sessionName).last)

        let chain = Self.activeBranch(in: entries)
        let extracted = Self.excerpt(from: chain.entries)
        return PiSessionSnapshot(
            sessionID: header.id,
            projectLabel: projectLabel,
            sessionLabel: sessionLabel,
            lastUserActivity: extracted.lastUserActivity,
            excerpt: extracted.lines,
            isPartialContext: chain.isPartial || (tail?.startedMidFile ?? false),
            fileURL: fileURL
        )
    }

    // MARK: - File access

    private struct BoundedRead {
        let data: Data
        let startedMidFile: Bool
    }

    private func readBounded(_ url: URL, fromEnd: Bool, maximumBytes: Int) -> BoundedRead? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        if size == 0 { return BoundedRead(data: Data(), startedMidFile: false) }

        let start = fromEnd ? max(0, Int(size) - maximumBytes) : 0
        do {
            try handle.seek(toOffset: UInt64(start))
            // Never read more than the budget: sessions reach tens of megabytes and
            // readToEnd() would pull the whole file in for the header alone.
            guard let data = try handle.read(upToCount: maximumBytes) else { return nil }
            readObserver?(data.count)
            return BoundedRead(data: data, startedMidFile: start > 0)
        } catch {
            return nil
        }
    }

    private static func lines(in data: Data, droppingFirstPartialLine: Bool) -> [Data] {
        var lines: [Data] = []
        var current = Data()
        for byte in data {
            if byte == 0x0A {
                if !current.isEmpty { lines.append(current) }
                current.removeAll(keepingCapacity: true)
            } else if byte != 0x0D {
                current.append(byte)
            }
        }
        if !current.isEmpty { lines.append(current) }
        if droppingFirstPartialLine, !lines.isEmpty {
            lines.removeFirst()
        }
        return lines
    }

    // MARK: - JSONL parsing

    private struct SessionHeader {
        let id: String
        let cwd: String?
    }

    private static func sessionHeader(lines: [Data]) -> SessionHeader? {
        for line in lines {
            guard let object = jsonObject(line) else { continue }
            guard object["type"] as? String == "session" else { continue }
            guard let id = object["id"] as? String, !id.isEmpty else { return nil }
            return SessionHeader(id: id, cwd: object["cwd"] as? String)
        }
        return nil
    }

    private struct ParsedEntry {
        let id: String
        let parentId: String?
        let kind: String
        let role: String?
        let text: String?
        let timestamp: Date?
        let sessionName: String?
    }

    private static func entries(lines: [Data]) -> [ParsedEntry] {
        var entries: [ParsedEntry] = []
        for line in lines {
            guard let object = jsonObject(line),
                  let kind = object["type"] as? String,
                  let id = object["id"] as? String,
                  !id.isEmpty
            else {
                continue
            }

            let entry = ParsedEntry(
                id: id,
                parentId: object["parentId"] as? String,
                kind: kind,
                role: messageRole(object),
                text: messageText(object),
                timestamp: entryTimestamp(object),
                sessionName: kind == "session_info" ? object["name"] as? String : nil
            )
            entries.append(entry)
        }
        return entries
    }

    private static func messageRole(_ object: [String: Any]) -> String? {
        guard object["type"] as? String == "message",
              let message = object["message"] as? [String: Any]
        else {
            return nil
        }
        return message["role"] as? String
    }

    private static func messageText(_ object: [String: Any]) -> String? {
        guard object["type"] as? String == "message",
              let message = object["message"] as? [String: Any],
              let role = message["role"] as? String,
              role == "user" || role == "assistant"
        else {
            return nil
        }

        let raw: String?
        if let text = message["content"] as? String {
            raw = text
        } else if let blocks = message["content"] as? [[String: Any]] {
            // Only plain text blocks: thinking, tool calls, images and tool
            // results are dropped.
            let texts = blocks.compactMap { block -> String? in
                guard block["type"] as? String == "text" else { return nil }
                return block["text"] as? String
            }
            raw = texts.isEmpty ? nil : texts.joined(separator: "\n")
        } else {
            raw = nil
        }

        guard let text = raw else { return nil }
        let cleaned = normalize(text)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func entryTimestamp(_ object: [String: Any]) -> Date? {
        if let message = object["message"] as? [String: Any],
           let milliseconds = message["timestamp"] as? Double {
            return Date(timeIntervalSince1970: milliseconds / 1000)
        }
        if let milliseconds = object["timestamp"] as? Double {
            return Date(timeIntervalSince1970: milliseconds / 1000)
        }
        if let iso = object["timestamp"] as? String {
            return try? Date(iso, strategy: .iso8601)
        }
        return nil
    }

    private static func jsonObject(_ line: Data) -> [String: Any]? {
        guard !line.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    // MARK: - Active branch

    private struct Branch {
        let entries: [ParsedEntry]
        let isPartial: Bool
    }

    private static func activeBranch(in entries: [ParsedEntry]) -> Branch {
        var byID: [String: ParsedEntry] = [:]
        for entry in entries where byID[entry.id] == nil {
            byID[entry.id] = entry
        }
        guard let leaf = entries.last else { return Branch(entries: [], isPartial: false) }

        var chain: [ParsedEntry] = []
        var seen: Set<String> = []
        var cursor: ParsedEntry? = leaf
        var isPartial = false
        while let entry = cursor {
            guard !seen.contains(entry.id), chain.count < maximumChainLength else {
                isPartial = true
                break
            }
            seen.insert(entry.id)
            chain.append(entry)
            guard let parentID = entry.parentId else { break }
            guard let parent = byID[parentID] else {
                // The parent lives outside the bounded read: partial view, never
                // fabricated context.
                isPartial = true
                break
            }
            cursor = parent
        }
        return Branch(entries: chain.reversed(), isPartial: isPartial)
    }

    // MARK: - Excerpt

    private struct Excerpt {
        let lines: [PiSessionExcerptLine]
        let lastUserActivity: Date?
    }

    private static func excerpt(from entries: [ParsedEntry]) -> Excerpt {
        var lines: [PiSessionExcerptLine] = []
        var lastUserActivity: Date?
        for entry in entries {
            guard let role = entry.role, let text = entry.text else { continue }
            let cleaned = strippingHarnessBlocks(text)
            guard !cleaned.isEmpty, !isHarnessNotification(cleaned) else { continue }

            guard let excerptRole = PiSessionExcerptLine.Role(rawValue: role) else { continue }
            if excerptRole == .user, let timestamp = entry.timestamp {
                lastUserActivity = max(lastUserActivity ?? timestamp, timestamp)
            }
            lines.append(PiSessionExcerptLine(role: excerptRole, text: cleaned, timestamp: entry.timestamp))
        }

        let recent = Array(lines.suffix(maximumExcerptLines))
        return Excerpt(lines: trimmed(recent), lastUserActivity: lastUserActivity)
    }

    /// Truncates long lines and drops the oldest lines until the character budget fits.
    private static func trimmed(_ lines: [PiSessionExcerptLine]) -> [PiSessionExcerptLine] {
        var result: [PiSessionExcerptLine] = []
        var budget = maximumExcerptCharacters
        for line in lines.reversed() {
            let text = truncate(line.text, to: maximumLineCharacters)
            if text.count > budget {
                let head = String(text.suffix(budget))
                if !head.isEmpty {
                    result.append(PiSessionExcerptLine(role: line.role, text: head, timestamp: line.timestamp))
                }
                budget = 0
                break
            }
            budget -= text.count
            result.append(PiSessionExcerptLine(role: line.role, text: text, timestamp: line.timestamp))
        }
        return result.reversed()
    }

    private static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }

    // MARK: - Sanitizing

    private static func normalize(_ text: String) -> String {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }

    /// Harness reminders are injected into user turns; they are noise, not user text.
    private static func strippingHarnessBlocks(_ text: String) -> String {
        var result = text
        while let start = result.range(of: "<system-reminder", options: [.caseInsensitive]) {
            if let end = result.range(of: "</system-reminder>", options: [.caseInsensitive], range: start.lowerBound..<result.endIndex) {
                result.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                result.removeSubrange(start.lowerBound..<result.endIndex)
                break
            }
        }
        return normalize(result)
    }

    /// Synthetic harness notifications arrive as user-role text with no origin
    /// metadata, so they have to be recognised by framing.
    private static func isHarnessNotification(_ text: String) -> Bool {
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let markers = [
            "<system>", "<system-reminder", "<notification", "<task-notification",
            "[system]", "system reminder:", "system-reminder:",
        ]
        if markers.contains(where: { lowered.hasPrefix($0) }) { return true }

        let normalized = lowered.trimmingCharacters(
            in: CharacterSet(charactersIn: "-*•·").union(.whitespaces)
        )
        return hasNativeNotificationFraming(normalized)
    }

    private static let notificationSubjects = ["workflow child", "workflow", "background task", "subagent", "sub-agent"]
    private static let notificationVerbs = ["completed", "finished", "failed", "errored", "done", "stopped"]

    /// Native workflow/background notifications, e.g. `Workflow child completed: …`,
    /// `Background task completed: …`, `Subagent finished: …`.
    ///
    /// Only this framing is matched, so ordinary discussion that merely mentions a
    /// subagent or a workflow ("the subagent crashed again") stays user text.
    private static func hasNativeNotificationFraming(_ normalized: String) -> Bool {
        for subject in notificationSubjects {
            for verb in notificationVerbs {
                let prefix = "\(subject) \(verb)"
                guard normalized.hasPrefix(prefix) else { continue }
                let boundary = normalized.dropFirst(prefix.count)
                guard let next = boundary.first else { return true }
                // The verb must end the phrase, not continue a longer word.
                if !next.isLetter, next != "_" { return true }
            }
        }
        return false
    }

    private static func sanitizedLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = raw
            .components(separatedBy: .controlCharacters)
            .joined()
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(40))
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }

    private static func isRealFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values?.isRegularFile == true && values?.isSymbolicLink != true
    }
}
