// Signs a release asset with the Ed25519 private key, writing a base64 detached signature to <file>.sig.
// Usage: swift scripts/sign_update.swift <file> <private-key-path>
import CryptoKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: sign_update.swift <file> <private-key-path>\n".utf8))
    exit(2)
}
let file = CommandLine.arguments[1]
let keyPath = CommandLine.arguments[2]
guard let payload = FileManager.default.contents(atPath: file),
      let keyText = try? String(contentsOfFile: keyPath, encoding: .utf8),
      let raw = Data(base64Encoded: keyText.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw),
      let signature = try? key.signature(for: payload)
else {
    FileHandle.standardError.write(Data("could not read file or private key\n".utf8))
    exit(1)
}
try signature.base64EncodedString().write(toFile: file + ".sig", atomically: true, encoding: .utf8)
print("signed \(file) -> \(file).sig")
