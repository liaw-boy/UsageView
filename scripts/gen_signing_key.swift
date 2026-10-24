// Generates the Ed25519 release signing key pair.
// Usage: swift scripts/gen_signing_key.swift <private-key-output-path>
// The private key is written (mode 0600) to the given path, which must NOT be inside this repository.
// Paste the printed public key into Sources/QuotaBarCore/Services/UpdateSecurity.swift (`publicKeyBase64`).
import CryptoKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: gen_signing_key.swift <private-key-output-path>\n".utf8))
    exit(2)
}
let path = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.path
let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL.path
guard !(path == cwd || path.hasPrefix(cwd + "/")) else {
    FileHandle.standardError.write(Data("refusing to write the private key inside the current directory (repository): \(path)\n".utf8))
    exit(1)
}
let key = Curve25519.Signing.PrivateKey()
// O_EXCL: fail instead of overwriting; 0600 from the moment the file exists.
let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
guard fd >= 0 else {
    FileHandle.standardError.write(Data("could not create \(path) (it must not already exist)\n".utf8))
    exit(1)
}
let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
handle.write(Data(key.rawRepresentation.base64EncodedString().utf8))
print("private key written to \(path) (keep it secret and backed up; never commit it)")
print("publicKeyBase64 = \"\(key.publicKey.rawRepresentation.base64EncodedString())\"")
