import Foundation

/// Read-only access to credentials that official tools already stored. Never writes anything.
public protocol CredentialSource: Sendable {
    func keychain(service: String, account: String?) -> String?
    func file(_ path: String) -> Data?
    func env(_ key: String) -> String?
}

public struct SystemCredentialSource: CredentialSource {
    public init() {}

    /// Uses `/usr/bin/security` so an unsigned/ad-hoc app can read items after the user clicks "Always Allow".
    public func keychain(service: String, account: String?) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        var args = ["find-generic-password", "-s", service]
        if let account { args += ["-a", account] }
        p.arguments = args + ["-w"]
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

    public func file(_ path: String) -> Data? {
        try? Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    }

    public func env(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key]
    }
}

// MARK: - Parsing helpers

enum Parse {
    static func object(_ data: Data?) -> [String: Any]? {
        data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    static func object(_ text: String?) -> [String: Any]? {
        object(text.map { Data($0.utf8) })
    }

    static func number(_ v: Any?) -> Double? {
        switch v {
        case let n as NSNumber: n.doubleValue
        case let s as String: Double(s)
        default: nil
        }
    }

    static func date(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
