import CryptoKit
import Foundation

/// Public half of the release signing key (Ed25519, base64 of the 32 raw bytes), generated with
/// `scripts/gen_signing_key.swift`. The private half never lives in this repository.
/// While empty, every update is refused: an unverifiable download is never installed.
enum UpdateSigningKey {
    static let publicKeyBase64 = "RwWcVvq57l+xQxtSBfa5vqQaMmEN+Mh9+7KI00PM+RY="

    static var publicKey: Data { Data(base64Encoded: publicKeyBase64) ?? Data() }
}

enum UpdateVerifier {
    static func verify(_ payload: Data, signature: Data, publicKey: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(signature, for: payload)
    }

    /// Signature files are base64 text, possibly with a trailing newline.
    static func decodeBase64(_ text: Data) -> Data? {
        guard let s = String(data: text, encoding: .utf8) else { return nil }
        return Data(base64Encoded: s.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

enum UpdateSchedule {
    static let interval: TimeInterval = 6 * 3600

    static func isDue(lastCheck: Date?, now: Date, interval: TimeInterval = UpdateSchedule.interval) -> Bool {
        guard let lastCheck, lastCheck <= now else { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }
}

enum UpdateInstaller {
    enum InstallError: LocalizedError {
        case replaceFailed(String)

        var errorDescription: String? {
            switch self {
            case .replaceFailed(let reason): "替換失敗，已保留舊版：\(reason)"
            }
        }
    }

    /// Swaps `current` for `new` without ever leaving the user without an app: the old bundle is moved aside first
    /// and moved back if anything goes wrong.
    static func replace(current: URL, with new: URL, fileManager fm: FileManager = .default) throws {
        let backup = current.deletingLastPathComponent()
            .appendingPathComponent(".\(current.lastPathComponent).old-\(UUID().uuidString)")
        do {
            try fm.moveItem(at: current, to: backup)
        } catch {
            throw InstallError.replaceFailed(error.localizedDescription)
        }
        do {
            try fm.moveItem(at: new, to: current)
        } catch {
            // A failed cross-volume move can leave a partial bundle at `current`; clear it so the backup can return.
            try? fm.removeItem(at: current)
            try? fm.moveItem(at: backup, to: current)
            throw InstallError.replaceFailed(error.localizedDescription)
        }
        try? fm.removeItem(at: backup)
    }
}
