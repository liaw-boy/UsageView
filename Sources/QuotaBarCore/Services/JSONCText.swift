import Foundation

/// Minimal JSONC support for OpenCode's `opencode.json(c)`.
///
/// Two jobs:
/// 1. Parse a file that may contain comments and trailing commas.
/// 2. Delete exactly one key **in place**, leaving every other byte — comments, key order, indentation,
///    trailing commas — untouched. OpenCode has no `mcp remove` command and its docs say to delete the entry
///    by hand, so a surgical edit is much safer than re-serializing the whole file.
public enum JSONCText {
    public enum EditError: LocalizedError, Equatable {
        case malformed
        case keyNotFound(String)

        public var errorDescription: String? {
            switch self {
            case .malformed: "設定檔格式不正確，無法安全修改。"
            case .keyNotFound(let k): "設定檔裡找不到「\(k)」。"
            }
        }
    }

    // MARK: - Masking (comments become spaces, so offsets stay identical to the original text)

    static func masked(_ chars: [Character]) -> [Character] {
        var out = chars
        var i = 0
        while i < out.count {
            let c = out[i]
            if c == "\"" {
                i = (try? endOfString(out, i)) ?? out.count
                continue
            }
            if c == "/", i + 1 < out.count, out[i + 1] == "/" {
                while i < out.count, out[i] != "\n" { out[i] = " "; i += 1 }
                continue
            }
            if c == "/", i + 1 < out.count, out[i + 1] == "*" {
                while i < out.count {
                    let end = out[i] == "*" && i + 1 < out.count && out[i + 1] == "/"
                    if out[i] != "\n" { out[i] = " " }
                    i += 1
                    if end { if i < out.count, out[i] != "\n" { out[i] = " " }; i += 1; break }
                }
                continue
            }
            i += 1
        }
        return out
    }

    /// Parses JSON or JSONC (comments and trailing commas allowed).
    public static func object(_ text: String) -> [String: Any]? {
        var chars = masked(Array(text))
        var i = 0
        while i < chars.count {
            if chars[i] == "\"" { i = (try? endOfString(chars, i)) ?? chars.count; continue }
            if chars[i] == "," {
                var j = i + 1
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == "}" || chars[j] == "]" { chars[i] = " " }
            }
            i += 1
        }
        let data = Data(String(chars).utf8)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Scanning primitives

    private static func skipWS(_ c: [Character], _ i: Int) -> Int {
        var i = i
        while i < c.count, c[i].isWhitespace { i += 1 }
        return i
    }

    /// `i` points at the opening quote; returns the index just past the closing quote.
    static func endOfString(_ c: [Character], _ i: Int) throws -> Int {
        var i = i + 1
        while i < c.count {
            if c[i] == "\\" { i += 2; continue }
            if c[i] == "\"" { return i + 1 }
            i += 1
        }
        throw EditError.malformed
    }

    static func endOfValue(_ c: [Character], _ start: Int) throws -> Int {
        var i = skipWS(c, start)
        guard i < c.count else { throw EditError.malformed }
        switch c[i] {
        case "\"":
            return try endOfString(c, i)
        case "{", "[":
            let open = c[i]
            let close: Character = open == "{" ? "}" : "]"
            var depth = 0
            while i < c.count {
                if c[i] == "\"" { i = try endOfString(c, i); continue }
                if c[i] == open { depth += 1 } else if c[i] == close {
                    depth -= 1
                    if depth == 0 { return i + 1 }
                }
                i += 1
            }
            throw EditError.malformed
        default:
            while i < c.count, !",}]".contains(c[i]), !c[i].isWhitespace { i += 1 }
            return i
        }
    }

    private struct Member {
        let key: String
        let keyStart: Int
        let valueStart: Int
        let valueEnd: Int
    }

    /// `objStart` points at `{`.
    private static func members(_ c: [Character], _ objStart: Int) throws -> [Member] {
        var i = skipWS(c, objStart)
        guard i < c.count, c[i] == "{" else { throw EditError.malformed }
        i += 1
        var out: [Member] = []
        while true {
            i = skipWS(c, i)
            guard i < c.count else { throw EditError.malformed }
            if c[i] == "}" { return out }
            if c[i] == "," { i += 1; continue }
            guard c[i] == "\"" else { throw EditError.malformed }
            let keyStart = i
            let keyEnd = try endOfString(c, i)
            let key = String(c[(keyStart + 1)..<(keyEnd - 1)])
            i = skipWS(c, keyEnd)
            guard i < c.count, c[i] == ":" else { throw EditError.malformed }
            let valueStart = skipWS(c, i + 1)
            let valueEnd = try endOfValue(c, valueStart)
            out.append(Member(key: key, keyStart: keyStart, valueStart: valueStart, valueEnd: valueEnd))
            i = valueEnd
        }
    }

    // MARK: - Surgical delete

    /// Removes `path` (e.g. `["mcp", "servers", "jira"]`) from `text`, preserving everything else byte for byte.
    public static func removingKey(path: [String], in text: String) throws -> String {
        guard !path.isEmpty else { throw EditError.malformed }
        let original = Array(text)
        let scan = masked(original)

        var objStart = skipWS(scan, 0)
        for key in path.dropLast() {
            guard let m = try members(scan, objStart).first(where: { $0.key == key }) else {
                throw EditError.keyNotFound(path.joined(separator: "."))
            }
            objStart = m.valueStart
            guard objStart < scan.count, scan[objStart] == "{" else { throw EditError.keyNotFound(path.joined(separator: ".")) }
        }
        let all = try members(scan, objStart)
        guard let target = all.first(where: { $0.key == path[path.count - 1] }) else {
            throw EditError.keyNotFound(path.joined(separator: "."))
        }

        var start = target.keyStart
        var end = target.valueEnd

        // Take the following comma when there is one, otherwise the preceding comma (the entry was last).
        var after = skipWS(scan, end)
        if after < scan.count, scan[after] == "," {
            end = after + 1
            after = end
        } else {
            var before = start - 1
            while before >= 0, scan[before].isWhitespace { before -= 1 }
            if before >= 0, scan[before] == "," { start = before }
        }

        // Swallow the now-empty line so the file keeps its shape.
        var lineStart = start - 1
        while lineStart >= 0, scan[lineStart] == " " || scan[lineStart] == "\t" { lineStart -= 1 }
        if lineStart >= 0, scan[lineStart] == "\n" {
            var tail = end
            while tail < scan.count, scan[tail] == " " || scan[tail] == "\t" { tail += 1 }
            if tail < scan.count, scan[tail] == "\n" {
                start = lineStart
                end = tail
            }
        }

        var result = original
        result.removeSubrange(start..<end)
        return String(result)
    }
}
