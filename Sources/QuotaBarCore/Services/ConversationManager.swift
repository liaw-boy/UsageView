import AppKit
import Foundation

public struct ConversationMessage: Sendable, Identifiable {
    public let id: String
    public let role: String
    public let text: String
    public let timestamp: Date?

    public init(id: String = UUID().uuidString, role: String, text: String, timestamp: Date? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
    }

    public var formattedTimestamp: String {
        guard let ts = timestamp else { return "" }
        let cal = Calendar.current
        let f = DateFormatter()
        if cal.isDateInToday(ts) {
            f.dateFormat = "HH:mm:ss"
        } else {
            f.dateFormat = "MM/dd HH:mm"
        }
        return f.string(from: ts)
    }
}

public struct ConversationSession: Identifiable, Sendable {
    public let id: String
    public let provider: ProviderID
    public let projectName: String
    public let projectPath: String
    public let prompt: String
    public let createdAt: Date
    public let updatedAt: Date
    public let totalSizeBytes: Int64
    public let mainFilePath: String
    public let subagentDirPath: String?
    public let tokenCount: Int
    public let costUSD: Double
    public let messageCount: Int

    public init(
        id: String,
        provider: ProviderID,
        projectName: String,
        projectPath: String,
        prompt: String,
        createdAt: Date,
        updatedAt: Date,
        totalSizeBytes: Int64,
        mainFilePath: String,
        subagentDirPath: String? = nil,
        tokenCount: Int = 0,
        costUSD: Double = 0.0,
        messageCount: Int = 0
    ) {
        self.id = id
        self.provider = provider
        self.projectName = projectName
        self.projectPath = projectPath
        self.prompt = prompt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.totalSizeBytes = totalSizeBytes
        self.mainFilePath = mainFilePath
        self.subagentDirPath = subagentDirPath
        self.tokenCount = tokenCount
        self.costUSD = costUSD
        self.messageCount = messageCount
    }

    public var formattedSize: String {
        let bytes = Double(totalSizeBytes)
        if bytes >= 1024 * 1024 * 1024 {
            return String(format: "%.2f GB", bytes / (1024 * 1024 * 1024))
        } else if bytes >= 1024 * 1024 {
            return String(format: "%.1f MB", bytes / (1024 * 1024))
        } else if bytes >= 1024 {
            return String(format: "%.0f KB", bytes / 1024)
        } else {
            return "\(totalSizeBytes) B"
        }
    }

    public var formattedRelativeTime: String {
        let secs = max(0, Int(Date().timeIntervalSince(updatedAt)))
        let m = secs / 60
        let h = m / 60
        let d = h / 24
        if d > 30 {
            let months = d / 30
            return "\(months) 個月前"
        } else if d > 0 {
            return "\(d) 天前"
        } else if h > 0 {
            return "\(h) 小時前"
        } else if m > 0 {
            return "\(m) 分鐘前"
        } else {
            return "剛剛"
        }
    }
}

public actor ConversationManager {
    public static let shared = ConversationManager()

    public init() {}

    public struct StorageStats: Sendable {
        public var totalBytes: Int64 = 0
        public var claudeBytes: Int64 = 0
        public var antigravityBytes: Int64 = 0
        public var claudeCount: Int = 0
        public var antigravityCount: Int = 0

        public init(
            totalBytes: Int64 = 0,
            claudeBytes: Int64 = 0,
            antigravityBytes: Int64 = 0,
            claudeCount: Int = 0,
            antigravityCount: Int = 0
        ) {
            self.totalBytes = totalBytes
            self.claudeBytes = claudeBytes
            self.antigravityBytes = antigravityBytes
            self.claudeCount = claudeCount
            self.antigravityCount = antigravityCount
        }

        public var formattedTotal: String {
            formatBytes(totalBytes)
        }
        public var formattedClaude: String {
            formatBytes(claudeBytes)
        }
        public var formattedAntigravity: String {
            formatBytes(antigravityBytes)
        }

        private func formatBytes(_ b: Int64) -> String {
            let bytes = Double(b)
            if bytes >= 1024 * 1024 * 1024 {
                return String(format: "%.2f GB", bytes / (1024 * 1024 * 1024))
            } else if bytes >= 1024 * 1024 {
                return String(format: "%.1f MB", bytes / (1024 * 1024))
            } else {
                return String(format: "%.0f KB", bytes / 1024)
            }
        }
    }

    // MARK: - Scan All

    public func scanAll() -> (sessions: [ConversationSession], stats: StorageStats) {
        var sessions: [ConversationSession] = []
        var stats = StorageStats()

        // 1. Claude
        let claudeSessions = scanClaudeSessions()
        sessions.append(contentsOf: claudeSessions)
        for s in claudeSessions {
            stats.claudeBytes += s.totalSizeBytes
            stats.claudeCount += 1
        }

        // 2. Antigravity
        let antigravitySessions = scanAntigravitySessions()
        sessions.append(contentsOf: antigravitySessions)
        for s in antigravitySessions {
            stats.antigravityBytes += s.totalSizeBytes
            stats.antigravityCount += 1
        }

        stats.totalBytes = stats.claudeBytes + stats.antigravityBytes
        return (sessions, stats)
    }

    // MARK: - Claude Scanner

    private func scanClaudeSessions() -> [ConversationSession] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let historyURL = home.appendingPathComponent(".claude/history.jsonl")
        var historyMap: [String: (prompt: String, project: String, createdAt: Date, updatedAt: Date)] = [:]

        if let historyData = try? Data(contentsOf: historyURL) {
            for line in historyData.split(separator: UInt8(ascii: "\n")) {
                guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                      let sid = obj["sessionId"] as? String, !sid.isEmpty
                else { continue }
                let prompt = (obj["display"] as? String) ?? ""
                let proj = (obj["project"] as? String) ?? ""
                let tsNum = (obj["timestamp"] as? NSNumber)?.doubleValue ?? 0
                let ts = tsNum > 0 ? Date(timeIntervalSince1970: tsNum / 1000.0) : Date()

                if let existing = historyMap[sid] {
                    let latestTs = max(existing.updatedAt, ts)
                    historyMap[sid] = (
                        existing.prompt.isEmpty ? prompt : existing.prompt,
                        existing.project.isEmpty ? proj : existing.project,
                        existing.createdAt,
                        latestTs
                    )
                } else {
                    historyMap[sid] = (prompt, proj, ts, ts)
                }
            }
        }

        let projectsURL = home.appendingPathComponent(".claude/projects")
        guard let pEntries = try? FileManager.default.contentsOfDirectory(at: projectsURL, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }

        var results: [ConversationSession] = []

        for pDir in pEntries {
            guard (try? pDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let dirName = pDir.lastPathComponent
            let decodedProject = decodeClaudeProjectName(dirName)

            guard let files = try? FileManager.default.contentsOfDirectory(at: pDir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else {
                continue
            }

            for file in files where file.pathExtension == "jsonl" {
                let sid = file.deletingPathExtension().lastPathComponent
                let mainSize = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let mainMtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()

                // Check subagents dir: <project>/<sid>/
                let subDir = pDir.appendingPathComponent(sid)
                var subSize: Int64 = 0
                var subDirExists = false
                var latestFileMtime = mainMtime

                if (try? subDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    subDirExists = true
                    if let enumerator = FileManager.default.enumerator(at: subDir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) {
                        for case let subFile as URL in enumerator {
                            guard subFile.lastPathComponent != ".DS_Store" else { continue }
                            if let vals = try? subFile.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
                                subSize += Int64(vals.fileSize ?? 0)
                                if subFile.pathExtension == "jsonl", let m = vals.contentModificationDate, m > latestFileMtime {
                                    latestFileMtime = m
                                }
                            }
                        }
                    }
                }

                let totalSize = Int64(mainSize) + subSize
                let hInfo = historyMap[sid]
                var prompt = hInfo?.prompt ?? ""
                let projPath = hInfo?.project ?? decodedProject
                let createdAt = hInfo?.createdAt ?? mainMtime
                // Use true conversation timestamp from history.jsonl if available; never corrupted by Finder opening!
                let updatedAt = hInfo?.updatedAt ?? latestFileMtime

                // If prompt is empty, read the first user prompt from the file
                if prompt.isEmpty {
                    prompt = extractFirstClaudePrompt(from: file) ?? ""
                }
                if prompt.isEmpty {
                    prompt = "對話 \(sid.prefix(8))"
                }

                let projName = (projPath as NSString).lastPathComponent

                results.append(ConversationSession(
                    id: sid,
                    provider: .claude,
                    projectName: projName.isEmpty ? "Claude" : projName,
                    projectPath: projPath,
                    prompt: prompt,
                    createdAt: createdAt,
                    updatedAt: updatedAt,
                    totalSizeBytes: totalSize,
                    mainFilePath: file.path,
                    subagentDirPath: subDirExists ? subDir.path : nil,
                    tokenCount: 0,
                    costUSD: 0.0,
                    messageCount: 0
                ))
            }
        }

        return results
    }

    private func decodeClaudeProjectName(_ dirName: String) -> String {
        // e.g. -Users-boywei-project-code-csie-quiz
        var s = dirName
        if s.hasPrefix("-") { s.removeFirst() }
        let parts = s.split(separator: "-").map(String.init)
        if parts.count >= 2, parts[0] == "Users" {
            return "/" + parts.joined(separator: "/")
        }
        return dirName
    }

    private func extractFirstClaudePrompt(from url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let chunk = handle.readData(ofLength: 32768)
        let marker = Data(#""type":"user""#.utf8)
        guard let r = chunk.range(of: marker) else { return nil }
        let slice = chunk[r.upperBound...]
        let contentMarker = Data(#""content":""#.utf8)
        guard let cr = slice.range(of: contentMarker) else { return nil }
        let start = cr.upperBound
        var end = start
        while end < slice.endIndex && slice[end] != UInt8(ascii: "\"") {
            end = slice.index(after: end)
        }
        guard end > start else { return nil }
        let raw = String(decoding: slice[start..<end], as: UTF8.self)
        return raw.replacingOccurrences(of: "\\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Antigravity Scanner

    private func scanAntigravitySessions() -> [ConversationSession] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let convDir = home.appendingPathComponent(".gemini/antigravity-cli/conversations")
        let brainBase = home.appendingPathComponent(".gemini/antigravity-cli/brain")

        guard let files = try? FileManager.default.contentsOfDirectory(at: convDir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            return []
        }

        var results: [ConversationSession] = []

        for file in files where file.pathExtension == "db" {
            let cid = file.deletingPathExtension().lastPathComponent
            let dbSize = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            var latestMtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()

            var extraSize: Int64 = 0

            // Check db-wal
            let walURL = file.deletingPathExtension().appendingPathExtension("db-wal")
            if let walVals = try? walURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
                extraSize += Int64(walVals.fileSize ?? 0)
                if let m = walVals.contentModificationDate, m > latestMtime { latestMtime = m }
            }

            // Check brain dir: ~/.gemini/antigravity-cli/brain/<cid>
            let brainDir = brainBase.appendingPathComponent(cid)
            var brainDirExists = false
            if (try? brainDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                brainDirExists = true
                if let enumerator = FileManager.default.enumerator(at: brainDir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) {
                    for case let subFile as URL in enumerator {
                        guard subFile.lastPathComponent != ".DS_Store" else { continue }
                        if let vals = try? subFile.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
                            extraSize += Int64(vals.fileSize ?? 0)
                            if let m = vals.contentModificationDate, m > latestMtime {
                                latestMtime = m
                            }
                        }
                    }
                }
            }

            let totalSize = Int64(dbSize) + extraSize

            // Read first prompt and true last timestamp from transcript
            var prompt = ""
            var trueLastDate: Date? = nil
            let projectPath = "/Users/boywei/project_code"
            let transcriptURL = brainDir.appendingPathComponent(".system_generated/logs/transcript.jsonl")

            if let tData = try? Data(contentsOf: transcriptURL) {
                let lines = tData.split(separator: UInt8(ascii: "\n"))
                for line in lines.reversed() {
                    guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                          let ca = obj["created_at"] as? String,
                          let d = Parse.date(ca)
                    else { continue }
                    trueLastDate = d
                    break
                }
                for line in lines {
                    guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                          let type = obj["type"] as? String, type == "USER_INPUT",
                          let content = obj["content"] as? String
                    else { continue }

                    if content.contains("<USER_REQUEST>") {
                        let parts = content.components(separatedBy: "<USER_REQUEST>")
                        if parts.count > 1 {
                            let sub = parts[1].components(separatedBy: "</USER_REQUEST>").first ?? ""
                            prompt = sub.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    } else {
                        prompt = content.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    break
                }
            }

            if prompt.isEmpty {
                prompt = "對話 \(cid.prefix(8))"
            }

            let projName = (projectPath as NSString).lastPathComponent
            let updatedAt = trueLastDate ?? latestMtime

            results.append(ConversationSession(
                id: cid,
                provider: .antigravity,
                projectName: projName.isEmpty ? "Antigravity" : projName,
                projectPath: projectPath,
                prompt: prompt,
                createdAt: updatedAt,
                updatedAt: updatedAt,
                totalSizeBytes: totalSize,
                mainFilePath: file.path,
                subagentDirPath: brainDirExists ? brainDir.path : nil,
                tokenCount: 0,
                costUSD: 0.0,
                messageCount: 0
            ))
        }

        return results
    }

    // MARK: - Safe Delete / Trash Action

    /// Safely moves the session's files to macOS Trash (垃圾桶). Returns the freed byte count.
    /// This is 100% reversible by the user in Finder Trash!
    public func moveToTrash(session: ConversationSession) throws -> Int64 {
        var freed: Int64 = 0
        let fm = FileManager.default

        // 1. Main file
        let mainURL = URL(fileURLWithPath: session.mainFilePath)
        if fm.fileExists(atPath: mainURL.path) {
            let size = (try? mainURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            try fm.trashItem(at: mainURL, resultingItemURL: nil)
            freed += Int64(size)
        }

        // 2. Subagent / Brain directory
        if let sub = session.subagentDirPath {
            let subURL = URL(fileURLWithPath: sub)
            if fm.fileExists(atPath: subURL.path) {
                // Compute size before trashing
                var sSize: Int64 = 0
                if let enumerator = fm.enumerator(at: subURL, includingPropertiesForKeys: [.fileSizeKey]) {
                    for case let f as URL in enumerator {
                        let sz = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                        sSize += Int64(sz)
                    }
                }
                try fm.trashItem(at: subURL, resultingItemURL: nil)
                freed += sSize
            }
        }

        // 3. Antigravity WAL/SHM files
        if session.provider == .antigravity {
            let walURL = URL(fileURLWithPath: session.mainFilePath + "-wal")
            let shmURL = URL(fileURLWithPath: session.mainFilePath + "-shm")
            if fm.fileExists(atPath: walURL.path) {
                try? fm.trashItem(at: walURL, resultingItemURL: nil)
            }
            if fm.fileExists(atPath: shmURL.path) {
                try? fm.trashItem(at: shmURL, resultingItemURL: nil)
            }
        }

        return freed
    }

    public func batchMoveToTrash(sessions: [ConversationSession]) -> (freedBytes: Int64, count: Int) {
        var totalFreed: Int64 = 0
        var count = 0
        for s in sessions {
            if let freed = try? moveToTrash(session: s) {
                totalFreed += freed
                count += 1
            }
        }
        return (totalFreed, count)
    }

    // MARK: - Preview Messages (Latest / Trailing First)

    /// Efficiently reads trailing lines from a file up to maxBytes without loading massive files in full.
    private func readTrailingLines(url: URL, maxBytes: Int = 4 * 1024 * 1024) -> [Data] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        if fileSize == 0 { return [] }

        let readSize = min(UInt64(maxBytes), fileSize)
        let offset = fileSize - readSize
        try? handle.seek(toOffset: offset)
        let data = handle.readData(ofLength: Int(readSize))

        var slices = data.split(separator: UInt8(ascii: "\n"))
        // If we sought into the middle of the file, drop the partial first line
        if offset > 0 && !slices.isEmpty {
            slices.removeFirst()
        }
        return slices.map { Data($0) }
    }

    private func parseClaudeMessages(lines: [Data]) -> [ConversationMessage] {
        var result: [ConversationMessage] = []
        for line in lines {
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let type = obj["type"] as? String
            else { continue }

            let ts = (obj["timestamp"] as? String).flatMap(Parse.date)
            if type == "user" {
                if let msg = obj["message"] as? [String: Any] {
                    if let text = msg["content"] as? String, !text.isEmpty {
                        result.append(ConversationMessage(role: "User", text: text, timestamp: ts))
                    } else if let arr = msg["content"] as? [[String: Any]] {
                        var combined = ""
                        for item in arr {
                            if let text = item["text"] as? String, !text.isEmpty {
                                combined += (combined.isEmpty ? "" : "\n") + text
                            }
                        }
                        if !combined.isEmpty {
                            result.append(ConversationMessage(role: "User", text: combined, timestamp: ts))
                        }
                    }
                }
            } else if type == "assistant" {
                if let msg = obj["message"] as? [String: Any] {
                    if let text = msg["content"] as? String, !text.isEmpty {
                        result.append(ConversationMessage(role: "Claude", text: text, timestamp: ts))
                    } else if let arr = msg["content"] as? [[String: Any]] {
                        var combined = ""
                        for item in arr {
                            if let text = item["text"] as? String, !text.isEmpty {
                                combined += (combined.isEmpty ? "" : "\n") + text
                            }
                        }
                        if !combined.isEmpty {
                            result.append(ConversationMessage(role: "Claude", text: combined, timestamp: ts))
                        }
                    }
                }
            }
        }
        return result
    }

    private func parseAntigravityMessages(lines: [Data]) -> [ConversationMessage] {
        var result: [ConversationMessage] = []
        for line in lines {
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let type = obj["type"] as? String
            else { continue }
            let ts = (obj["created_at"] as? String).flatMap(Parse.date)

            if type == "USER_INPUT", let raw = obj["content"] as? String {
                var clean = raw
                if clean.contains("<USER_REQUEST>") {
                    let parts = clean.components(separatedBy: "<USER_REQUEST>")
                    if parts.count > 1 {
                        clean = parts[1].components(separatedBy: "</USER_REQUEST>").first ?? clean
                    }
                }
                clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty {
                    result.append(ConversationMessage(role: "User", text: clean, timestamp: ts))
                }
            } else if type == "PLANNER_RESPONSE", let raw = obj["content"] as? String, !raw.isEmpty {
                result.append(ConversationMessage(role: "Antigravity", text: raw, timestamp: ts))
            }
        }
        return result
    }

    /// Loads the latest / most recent conversation messages (chronological order, tail of the conversation).
    public func loadPreviewMessages(session: ConversationSession, limit: Int = 40) -> [ConversationMessage] {
        if session.provider == .claude {
            let url = URL(fileURLWithPath: session.mainFilePath)
            let lines = readTrailingLines(url: url, maxBytes: 4 * 1024 * 1024)
            var parsed = parseClaudeMessages(lines: lines)
            if parsed.count < 8 {
                let largerLines = readTrailingLines(url: url, maxBytes: 16 * 1024 * 1024)
                if largerLines.count > lines.count {
                    parsed = parseClaudeMessages(lines: largerLines)
                }
            }
            return Array(parsed.suffix(limit))
        } else if session.provider == .antigravity {
            if let brain = session.subagentDirPath {
                let tURL = URL(fileURLWithPath: brain).appendingPathComponent(".system_generated/logs/transcript.jsonl")
                let lines = readTrailingLines(url: tURL, maxBytes: 4 * 1024 * 1024)
                var parsed = parseAntigravityMessages(lines: lines)
                if parsed.count < 8 {
                    let largerLines = readTrailingLines(url: tURL, maxBytes: 16 * 1024 * 1024)
                    if largerLines.count > lines.count {
                        parsed = parseAntigravityMessages(lines: largerLines)
                    }
                }
                return Array(parsed.suffix(limit))
            }
        }

        return []
    }

    /// Loads all messages for full export to Markdown.
    public func loadAllMessagesForExport(session: ConversationSession) -> [ConversationMessage] {
        if session.provider == .claude {
            let url = URL(fileURLWithPath: session.mainFilePath)
            guard let data = try? Data(contentsOf: url) else { return [] }
            let lines = data.split(separator: UInt8(ascii: "\n")).map { Data($0) }
            return parseClaudeMessages(lines: lines)
        } else if session.provider == .antigravity {
            if let brain = session.subagentDirPath {
                let tURL = URL(fileURLWithPath: brain).appendingPathComponent(".system_generated/logs/transcript.jsonl")
                guard let data = try? Data(contentsOf: tURL) else { return [] }
                let lines = data.split(separator: UInt8(ascii: "\n")).map { Data($0) }
                return parseAntigravityMessages(lines: lines)
            }
        }
        return []
    }

    // MARK: - Export to Markdown

    public func exportToMarkdown(session: ConversationSession, targetURL: URL) throws {
        let msgs = loadAllMessagesForExport(session: session)
        var md = """
        # 對話紀錄：\(session.projectName)
        - **服務商**：\(session.provider.displayName)
        - **對話 ID**：`\(session.id)`
        - **專案路徑**：`\(session.projectPath)`
        - **更新時間**：\(session.updatedAt.description)
        - **本地容量**：\(session.formattedSize)

        ---

        """

        for m in msgs {
            let rolePrefix = m.role == "User" ? "### 👤 User" : "### 🤖 \(m.role)"
            let tsStr = m.timestamp.map { " (\($0))" } ?? ""
            md += "\(rolePrefix)\(tsStr)\n\n\(m.text)\n\n---\n\n"
        }

        try md.write(to: targetURL, atomically: true, encoding: .utf8)
    }
}
