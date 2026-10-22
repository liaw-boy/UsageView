import Foundation

/// Scans local CLI / IDE conversation logs on disk (100% offline, read-only) to compute Today and 30-Day
/// token counts and API-equivalent USD spend for Claude, Codex, and Antigravity.
public actor LocalUsageScanner {
    public static let shared = LocalUsageScanner()

    public struct Record: Codable, Sendable {
        public let timestamp: Date
        public let tokens: Int
        public let costUSD: Double
        public let dedupKey: String?
        public let isSidechain: Bool
    }

    private struct CachedFile: Codable, Sendable {
        let mtime: Date
        let size: Int64
        let records: [Record]
    }

    private var fileCache: [String: CachedFile] = [:]
    private var loadedDiskCache = false
    private let diskCacheURL: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("QuotaBar/local-spend-cache-v1.json")

    public init() {}

    private func ensureDiskCacheLoaded() {
        guard !loadedDiskCache else { return }
        loadedDiskCache = true
        if let data = try? Data(contentsOf: diskCacheURL),
           let decoded = try? JSONDecoder().decode([String: CachedFile].self, from: data) {
            fileCache = decoded
        }
    }

    private func saveDiskCache() {
        try? FileManager.default.createDirectory(at: diskCacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(fileCache).write(to: diskCacheURL, options: .atomic)
    }

    public func scan(provider: ProviderID, now: Date = Date()) -> LocalSpendSummary? {
        ensureDiskCacheLoaded()
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: now)
        guard let since = cal.date(byAdding: .day, value: -30, to: startOfToday) else { return nil }

        let beforeCount = fileCache.count
        let records: [Record]
        switch provider {
        case .claude:
            records = scanClaude(since: since)
        case .codex:
            records = scanCodex(since: since)
        case .antigravity:
            records = scanAntigravity(since: since)
        }
        if fileCache.count != beforeCount {
            saveDiskCache()
        }
        guard !records.isEmpty else { return nil }

        var todayCost = 0.0
        var todayTok = 0
        var monthCost = 0.0
        var monthTok = 0

        for r in records where r.timestamp >= since {
            monthCost += r.costUSD
            monthTok += r.tokens
            if r.timestamp >= startOfToday {
                todayCost += r.costUSD
                todayTok += r.tokens
            }
        }
        let summary = LocalSpendSummary(
            todayCostUSD: todayCost,
            todayTokens: todayTok,
            monthCostUSD: monthCost,
            monthTokens: monthTok
        )
        return summary.hasAnyUsage ? summary : nil
    }

    // MARK: - 1. Claude (`~/.claude/projects/**/*.jsonl`)

    private func scanClaude(since: Date) -> [Record] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var roots: [URL] = []
        if let envDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !envDir.isEmpty {
            roots.append(URL(fileURLWithPath: (envDir as NSString).expandingTildeInPath).appendingPathComponent("projects"))
        } else {
            roots.append(home.appendingPathComponent(".claude/projects"))
            roots.append(home.appendingPathComponent(".config/claude/projects"))
        }

        let files = discoverFiles(under: roots, ext: "jsonl", modifiedSince: since)
        guard !files.isEmpty else { return [] }

        var raw: [Record] = []
        for file in files {
            raw.append(contentsOf: cachedRecords(for: file, parser: Self.parseClaudeJSONL))
        }
        // Deduplicate by (message.id, requestId) keeping highest token count / non-sidechain
        var byKey: [String: Int] = [:]
        var deduped: [Record] = []
        for r in raw {
            guard let key = r.dedupKey else {
                deduped.append(r)
                continue
            }
            if let idx = byKey[key] {
                let existing = deduped[idx]
                if (!r.isSidechain && existing.isSidechain) || r.tokens > existing.tokens {
                    deduped[idx] = r
                }
            } else {
                byKey[key] = deduped.count
                deduped.append(r)
            }
        }
        return deduped
    }

    private static func parseClaudeJSONL(_ data: Data) -> [Record] {
        let usageMarker = Data(#""usage":{"#.utf8)
        let assistantMarker = Data(#""type":"assistant""#.utf8)
        var out: [Record] = []
        var cursor = data.startIndex

        // Single-pass search for `"usage":{` across memory-mapped file buffer:
        // skips multi-megabyte base64/tool-output lines without splitting the entire file!
        while let usageRange = data.range(of: usageMarker, in: cursor..<data.endIndex) {
            cursor = usageRange.upperBound

            // Find the start and end of the enclosing line (bounded lookback/lookahead)
            let lineStart = data[..<usageRange.lowerBound].lastIndex(of: UInt8(ascii: "\n")).map { data.index(after: $0) }
                ?? data.startIndex
            let lineEnd = data[usageRange.upperBound...].firstIndex(of: UInt8(ascii: "\n")) ?? data.endIndex

            // Header window (first 1KB of line) + tail window (from 512B before `"usage":{` to end of line)
            let headerEnd = min(lineEnd, lineStart + 1024)
            let headerSlice = data[lineStart..<headerEnd]
            let tailStart = max(lineStart, usageRange.lowerBound - 512)
            let tailSlice = data[tailStart..<lineEnd]

            guard headerSlice.range(of: assistantMarker) != nil || tailSlice.range(of: assistantMarker) != nil else {
                continue
            }

            let objStart = data.index(usageRange.lowerBound, offsetBy: 8) // points to `{`
            guard let usageSlice = extractBalancedJSONObject(in: data[objStart..<lineEnd], from: objStart),
                  let usage = (try? JSONSerialization.jsonObject(with: Data(usageSlice))) as? [String: Any],
                  let inTok = (usage["input_tokens"] as? NSNumber)?.intValue,
                  let outTok = (usage["output_tokens"] as? NSNumber)?.intValue
            else { continue }

            let cacheCreateObj = usage["cache_creation"] as? [String: Any]
            let cacheWrite5m = (cacheCreateObj?["ephemeral_5m_input_tokens"] as? NSNumber)?.intValue
                ?? (usage["cache_creation_input_tokens"] as? NSNumber)?.intValue ?? 0
            let cacheWrite1h = (cacheCreateObj?["ephemeral_1h_input_tokens"] as? NSNumber)?.intValue ?? 0
            let cacheRead = (usage["cache_read_input_tokens"] as? NSNumber)?.intValue ?? 0
            let totalTokens = inTok + cacheWrite5m + cacheWrite1h + cacheRead + outTok
            guard totalTokens > 0 else { continue }

            guard let tsRaw = extractJSONStringValue(key: #""timestamp":""#, in: headerSlice)
                ?? extractJSONStringValue(key: #""timestamp":""#, in: tailSlice),
                  let ts = Parse.date(tsRaw)
            else { continue }

            let model = extractJSONStringValue(key: #""model":""#, in: tailSlice)
                ?? extractJSONStringValue(key: #""model":""#, in: headerSlice)
                ?? "claude-sonnet-4-6"
            if model == "<synthetic>" { continue }
            let isFast = (usage["speed"] as? String) == "fast"

            let cost = ModelRateTable.estimateClaudeCost(
                model: model,
                input: inTok,
                cacheWrite5m: cacheWrite5m,
                cacheWrite1h: cacheWrite1h,
                cacheRead: cacheRead,
                output: outTok,
                isFast: isFast
            )

            let msgID = (extractJSONStringValue(key: #""id":"msg_"#, in: tailSlice)
                ?? extractJSONStringValue(key: #""id":"msg_"#, in: headerSlice)).map { "msg_" + $0 }
            let reqID = extractJSONStringValue(key: #""requestId":""#, in: headerSlice)
                ?? extractJSONStringValue(key: #""requestId":""#, in: tailSlice)
            let key = msgID.map { "\($0)|\(reqID ?? "")" }
            let sidechain = headerSlice.range(of: Data(#""isSidechain":true"#.utf8)) != nil
            out.append(Record(timestamp: ts, tokens: totalTokens, costUSD: cost, dedupKey: key, isSidechain: sidechain))
        }
        return out
    }

    private static func extractBalancedJSONObject(in slice: Data.SubSequence, from braceStart: Data.Index) -> Data.SubSequence? {
        var depth = 0
        var inString = false
        var escaped = false
        var idx = braceStart
        let maxEnd = min(slice.endIndex, braceStart + 2048)
        while idx < maxEnd {
            let b = slice[idx]
            if inString {
                if escaped {
                    escaped = false
                } else if b == UInt8(ascii: "\\") {
                    escaped = true
                } else if b == UInt8(ascii: "\"") {
                    inString = false
                }
            } else {
                if b == UInt8(ascii: "\"") {
                    inString = true
                } else if b == UInt8(ascii: "{") {
                    depth += 1
                } else if b == UInt8(ascii: "}") {
                    depth -= 1
                    if depth == 0 {
                        return slice[braceStart...idx]
                    }
                }
            }
            idx = slice.index(after: idx)
        }
        return nil
    }

    private static func extractJSONStringValue(key: String, in slice: Data.SubSequence) -> String? {
        let pattern = Data(key.utf8)
        guard let found = slice.range(of: pattern) else { return nil }
        let start = found.upperBound
        let limit = min(slice.endIndex, start + 128)
        var end = start
        while end < limit && slice[end] != UInt8(ascii: "\"") {
            end = slice.index(after: end)
        }
        guard end < limit else { return nil }
        return String(decoding: slice[start..<end], as: UTF8.self)
    }

    // MARK: - 2. Codex (`~/.codex/sessions/**/*.jsonl`)

    private func scanCodex(since: Date) -> [Record] {
        let homePath = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? "~/.codex"
        let base = URL(fileURLWithPath: (homePath as NSString).expandingTildeInPath)
        let roots = [
            base.appendingPathComponent("sessions"),
            base.appendingPathComponent("archived_sessions"),
        ]
        let files = discoverFiles(under: roots, ext: "jsonl", modifiedSince: since)
        guard !files.isEmpty else { return [] }

        var out: [Record] = []
        for file in files {
            out.append(contentsOf: cachedRecords(for: file, parser: Self.parseCodexJSONL))
        }
        return out
    }

    private static func parseCodexJSONL(_ data: Data) -> [Record] {
        var out: [Record] = []
        var currentModel = "gpt-5.3-codex"
        var prevIn = 0, prevCached = 0, prevOut = 0, prevReason = 0

        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let type = obj["type"] as? String
            else { continue }
            let payload = obj["payload"] as? [String: Any]

            if type == "turn_context", let m = (payload?["model"] ?? payload?["model_name"]) as? String, !m.isEmpty {
                currentModel = m
                continue
            }
            guard type == "event_msg",
                  payload?["type"] as? String == "token_count",
                  let tsRaw = obj["timestamp"] as? String,
                  let ts = Parse.date(tsRaw)
            else { continue }

            let info = payload?["info"] as? [String: Any]
            let inTok: Int
            let cachedTok: Int
            let outTok: Int
            let reasonTok: Int

            if let last = info?["last_token_usage"] as? [String: Any] {
                inTok = (last["input_tokens"] as? NSNumber)?.intValue ?? 0
                cachedTok = (last["cached_input_tokens"] as? NSNumber)?.intValue ?? 0
                outTok = (last["output_tokens"] as? NSNumber)?.intValue ?? 0
                reasonTok = (last["reasoning_output_tokens"] as? NSNumber)?.intValue ?? 0
                if let tot = info?["total_token_usage"] as? [String: Any] {
                    prevIn = (tot["input_tokens"] as? NSNumber)?.intValue ?? prevIn
                    prevCached = (tot["cached_input_tokens"] as? NSNumber)?.intValue ?? prevCached
                    prevOut = (tot["output_tokens"] as? NSNumber)?.intValue ?? prevOut
                    prevReason = (tot["reasoning_output_tokens"] as? NSNumber)?.intValue ?? prevReason
                }
            } else if let tot = info?["total_token_usage"] as? [String: Any] {
                let tIn = (tot["input_tokens"] as? NSNumber)?.intValue ?? 0
                let tCached = (tot["cached_input_tokens"] as? NSNumber)?.intValue ?? 0
                let tOut = (tot["output_tokens"] as? NSNumber)?.intValue ?? 0
                let tReason = (tot["reasoning_output_tokens"] as? NSNumber)?.intValue ?? 0
                inTok = max(0, tIn - prevIn)
                cachedTok = max(0, tCached - prevCached)
                outTok = max(0, tOut - prevOut)
                reasonTok = max(0, tReason - prevReason)
                prevIn = tIn; prevCached = tCached; prevOut = tOut; prevReason = tReason
            } else {
                continue
            }

            let total = inTok + outTok + reasonTok
            guard total > 0 else { continue }
            let model = (payload?["model"] as? String) ?? (info?["model"] as? String) ?? currentModel
            let cost = ModelRateTable.estimateCodexCost(
                model: model,
                input: max(0, inTok - cachedTok),
                cached: min(cachedTok, inTok),
                output: outTok + reasonTok
            )
            out.append(Record(timestamp: ts, tokens: total, costUSD: cost, dedupKey: nil, isSidechain: false))
        }
        return out
    }

    // MARK: - 3. Antigravity (`~/.gemini/antigravity*/conversations/*.db`)

    private func scanAntigravity(since: Date) -> [Record] {
        let geminiDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: geminiDir.path) else { return [] }
        let convDirs = entries
            .filter { $0.hasPrefix("antigravity") }
            .sorted()
            .map { geminiDir.appendingPathComponent($0).appendingPathComponent("conversations") }

        var dbFiles: [URL] = []
        var seenCanonical = Set<String>()
        for dir in convDirs {
            for file in discoverFiles(under: [dir], ext: "db", modifiedSince: since) {
                let canon = file.resolvingSymlinksInPath().path
                if seenCanonical.insert(canon).inserted {
                    dbFiles.append(file)
                }
            }
        }
        guard !dbFiles.isEmpty else { return [] }

        var out: [Record] = []
        for db in dbFiles {
            out.append(contentsOf: cachedAntigravityRecords(for: db))
        }
        return out
    }

    private func cachedAntigravityRecords(for dbURL: URL) -> [Record] {
        let path = dbURL.path
        let attrs = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
        let walAttrs = (try? FileManager.default.attributesOfItem(atPath: path + "-wal")) ?? [:]
        let mtime = max(
            (attrs[.modificationDate] as? Date) ?? .distantPast,
            (walAttrs[.modificationDate] as? Date) ?? .distantPast
        )
        let size = ((attrs[.size] as? NSNumber)?.int64Value ?? 0) + ((walAttrs[.size] as? NSNumber)?.int64Value ?? 0)

        if let cached = fileCache[path], cached.mtime == mtime, cached.size == size {
            return cached.records
        }
        let parsed = Self.parseAntigravityDB(path: path)
        fileCache[path] = CachedFile(mtime: mtime, size: size, records: parsed)
        return parsed
    }

    private static func parseAntigravityDB(path: String) -> [Record] {
        return autoreleasepool {
            let hasSteps = runSQLite(path: path, sql: "SELECT 1 FROM pragma_table_info('steps') WHERE name = 'metadata'") != nil
            let stepCol = hasSteps
                ? " || '|' || COALESCE((SELECT CASE WHEN length(metadata) <= 32768 THEN hex(metadata) ELSE '' END FROM steps WHERE idx = g.idx), '')"
                : ""
            let sql = """
            SELECT CASE WHEN length(g.data) <= 65536 THEN hex(g.data) ELSE '' END\(stepCol)
            FROM gen_metadata g WHERE g.data IS NOT NULL ORDER BY g.idx;
            """
            guard let rawText = runSQLite(path: path, sql: sql) else { return [] }

            var out: [Record] = []
            for line in rawText.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: "|", omittingEmptySubsequences: false)
                guard let hexSub = parts.first, !hexSub.isEmpty,
                      let blob = ProtoDecode.bytes(fromHex: String(hexSub))
                else { continue }
                let stepBlob: [UInt8]? = (parts.count > 1 && !parts[1].isEmpty)
                    ? ProtoDecode.bytes(fromHex: String(parts[1]))
                    : nil
                guard let ev = ProtoDecode.decodeGeneration(blob: blob, stepBlob: stepBlob) else { continue }
                let total = ev.inputTokens + ev.cacheReadTokens + ev.outputTokens
                guard total > 0 else { continue }
                let cost = ModelRateTable.estimateAntigravityCost(
                    model: ev.modelID ?? ev.label ?? "gemini-3.1-pro",
                    input: ev.inputTokens,
                    cacheRead: ev.cacheReadTokens,
                    output: ev.outputTokens
                )
                out.append(Record(
                    timestamp: Date(timeIntervalSince1970: TimeInterval(ev.timestampSeconds)),
                    tokens: total,
                    costUSD: cost,
                    dedupKey: nil,
                    isSidechain: false
                ))
            }
            return out
        }
    }

    private static func runSQLite(path: String, sql: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = ["-readonly", "-batch", "-noheader", path, sql]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    // MARK: - File Discovery & Cache

    private func cachedRecords(for url: URL, parser: (Data) -> [Record]) -> [Record] {
        let path = url.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return [] }
        let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        if let cached = fileCache[path], cached.mtime == mtime, cached.size == size {
            return cached.records
        }
        guard size > 0, size <= 1_000_000_000 else { return [] }
        let records: [Record] = autoreleasepool {
            guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return [] }
            return parser(data)
        }
        fileCache[path] = CachedFile(mtime: mtime, size: size, records: records)
        return records
    }

    private func discoverFiles(under roots: [URL], ext: String, modifiedSince since: Date) -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        for root in roots {
            let resolved = root.resolvingSymlinksInPath()
            guard let enumerator = fm.enumerator(
                at: resolved,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let fileURL as URL in enumerator where fileURL.pathExtension == ext {
                if let vals = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                   vals.isRegularFile == true {
                    // For .db files, also check the -wal modification time
                    var mtime = vals.contentModificationDate ?? .distantPast
                    if ext == "db",
                       let walAttrs = try? fm.attributesOfItem(atPath: fileURL.path + "-wal"),
                       let walMtime = walAttrs[.modificationDate] as? Date {
                        mtime = max(mtime, walMtime)
                    }
                    if mtime >= since {
                        found.append(fileURL)
                    }
                }
            }
        }
        return found.sorted { $0.path < $1.path }
    }
}

// MARK: - Official API Model Pricing Table (USD per 1M tokens)

private enum ModelRateTable {
    static func estimateClaudeCost(
        model: String,
        input: Int,
        cacheWrite5m: Int,
        cacheWrite1h: Int,
        cacheRead: Int,
        output: Int,
        isFast: Bool
    ) -> Double {
        let m = model.lowercased()
        let (inRate, outRate): (Double, Double)
        if m.contains("opus-4-1") || m.contains("opus-4-0") || m.contains("opus-4-2025") {
            (inRate, outRate) = (15.0, 75.0)
        } else if m.contains("opus-5-5") {
            (inRate, outRate) = (4.0, 20.0)
        } else if m.contains("opus") {
            // Claude Opus 4.5 / 4.6 / 4.7 / 4.8 / 5
            (inRate, outRate) = (5.0, 25.0)
        } else if m.contains("fable") {
            (inRate, outRate) = (10.0, 50.0)
        } else if m.contains("haiku") {
            (inRate, outRate) = (1.0, 5.0)
        } else {
            // Default to Claude Sonnet 4 / 4.5 / 4.6 ($3 / $15 per MTok)
            (inRate, outRate) = (3.0, 15.0)
        }
        let mult = isFast ? 2.0 : 1.0
        let cw5mRate = inRate * 1.25
        let cw1hRate = inRate * 2.0
        let crRate = inRate * 0.10
        let usd = (
            Double(input) * inRate +
            Double(cacheWrite5m) * cw5mRate +
            Double(cacheWrite1h) * cw1hRate +
            Double(cacheRead) * crRate +
            Double(output) * outRate
        ) / 1_000_000.0
        return usd * mult
    }

    static func estimateCodexCost(model: String, input: Int, cached: Int, output: Int) -> Double {
        let m = model.lowercased()
        let (inRate, cacheRate, outRate): (Double, Double, Double)
        if m.contains("mini") {
            (inRate, cacheRate, outRate) = (0.40, 0.10, 1.60)
        } else if m.contains("pro") {
            (inRate, cacheRate, outRate) = (15.0, 3.75, 60.0)
        } else {
            // GPT-5 / GPT-5.1 / GPT-5.2 / GPT-5.3 Codex / GPT-5.4 standard API rates
            (inRate, cacheRate, outRate) = (2.50, 0.25, 10.0)
        }
        return (Double(input) * inRate + Double(cached) * cacheRate + Double(output) * outRate) / 1_000_000.0
    }

    static func estimateAntigravityCost(model: String, input: Int, cacheRead: Int, output: Int) -> Double {
        let m = model.lowercased()
        if m.contains("claude") || m.contains("sonnet") || m.contains("opus") {
            return estimateClaudeCost(model: m, input: input, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: cacheRead, output: output, isFast: false)
        }
        let (inRate, cacheRate, outRate): (Double, Double, Double)
        if m.contains("argon") {
            (inRate, cacheRate, outRate) = (2.0, 0.10, 10.0)
        } else if m.contains("flash") {
            (inRate, cacheRate, outRate) = (0.75, 0.075, 3.75)
        } else {
            // Gemini 3.1 Pro / Gemini Pro
            (inRate, cacheRate, outRate) = (1.25, 0.125, 10.0)
        }
        return (Double(input) * inRate + Double(cacheRead) * cacheRate + Double(output) * outRate) / 1_000_000.0
    }
}

// MARK: - Lightweight Protobuf Decoder for Antigravity Local Conversation DB

private enum ProtoDecode {
    struct Generation {
        let modelID: String?
        let label: String?
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let timestampSeconds: Int64
    }

    static func bytes(fromHex hex: String) -> [UInt8]? {
        guard hex.utf8.count.isMultiple(of: 2) else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(hex.utf8.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let b = UInt8(hex[idx..<next], radix: 16) else { return nil }
            out.append(b)
            idx = next
        }
        return out
    }

    static func decodeGeneration(blob: [UInt8], stepBlob: [UInt8]?) -> Generation? {
        guard let wrapped = bytesField(1, in: blob),
              let usage = bytesField(4, in: wrapped)
        else { return nil }
        let sysPrompt = Int(varintField(1, in: usage) ?? 0)
        let inTok = Int(varintField(2, in: usage) ?? 0)
        let outTok = Int(varintField(3, in: usage) ?? 0)
        let cacheTok = Int(varintField(5, in: usage) ?? 0)
        guard inTok > 0 || outTok > 0 || cacheTok > 0 else { return nil }

        let modelID = stringField(19, in: wrapped)
        let label = stringField(21, in: wrapped)
        let embeddedTS = bytesField(9, in: wrapped).flatMap { bytesField(4, in: $0) }.flatMap { varintField(1, in: $0) }
        let stepTS = stepBlob.flatMap { bytesField(1, in: $0) }.flatMap { varintField(1, in: $0) }
        guard let ts = embeddedTS ?? stepTS, ts > 0 else { return nil }

        return Generation(
            modelID: modelID,
            label: label,
            inputTokens: sysPrompt + inTok,
            outputTokens: outTok,
            cacheReadTokens: cacheTok,
            timestampSeconds: Int64(ts)
        )
    }

    private static func decodeVarint(_ bytes: [UInt8], at offset: Int) -> (UInt64, Int)? {
        var val: UInt64 = 0
        for i in 0..<10 {
            let pos = offset + i
            guard pos < bytes.count else { return nil }
            let b = bytes[pos]
            val |= UInt64(b & 0x7f) << (i * 7)
            if (b & 0x80) == 0 { return (val, pos + 1) }
        }
        return nil
    }

    private static func bytesField(_ target: UInt32, in bytes: [UInt8]) -> [UInt8]? {
        var offset = 0
        while offset < bytes.count {
            guard let (tag, next) = decodeVarint(bytes, at: offset) else { return nil }
            let fieldNum = UInt32(tag >> 3)
            switch tag & 0x7 {
            case 0:
                guard let (_, after) = decodeVarint(bytes, at: next) else { return nil }
                offset = after
            case 2:
                guard let (len, start) = decodeVarint(bytes, at: next),
                      start + Int(len) <= bytes.count else { return nil }
                if fieldNum == target { return Array(bytes[start..<(start + Int(len))]) }
                offset = start + Int(len)
            case 1:
                offset = next + 8
            case 5:
                offset = next + 4
            default:
                return nil
            }
        }
        return nil
    }

    private static func varintField(_ target: UInt32, in bytes: [UInt8]) -> UInt64? {
        var offset = 0
        while offset < bytes.count {
            guard let (tag, next) = decodeVarint(bytes, at: offset) else { return nil }
            let fieldNum = UInt32(tag >> 3)
            switch tag & 0x7 {
            case 0:
                guard let (v, after) = decodeVarint(bytes, at: next) else { return nil }
                if fieldNum == target { return v }
                offset = after
            case 2:
                guard let (len, start) = decodeVarint(bytes, at: next),
                      start + Int(len) <= bytes.count else { return nil }
                offset = start + Int(len)
            case 1:
                offset = next + 8
            case 5:
                offset = next + 4
            default:
                return nil
            }
        }
        return nil
    }

    private static func stringField(_ target: UInt32, in bytes: [UInt8]) -> String? {
        guard let b = bytesField(target, in: bytes),
              let s = String(bytes: b, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return nil }
        return s
    }
}
