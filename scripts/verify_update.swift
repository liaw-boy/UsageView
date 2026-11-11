// Verifies a release zip against its .sig with the public key embedded in the app, exactly as auto-update does.
// Build together with the app's verifier:
//   swiftc -parse-as-library -o /tmp/verify_update scripts/verify_update.swift Sources/QuotaBarCore/Services/UpdateSecurity.swift
//   /tmp/verify_update UsageView.app.zip UsageView.app.zip.sig
import Foundation

@main
enum VerifyUpdate {
    static func main() {
        let args = CommandLine.arguments
        guard args.count == 3,
              let zip = try? Data(contentsOf: URL(fileURLWithPath: args[1])),
              let raw = try? Data(contentsOf: URL(fileURLWithPath: args[2]))
        else {
            FileHandle.standardError.write(Data("usage: verify_update <zip> <sig>\n".utf8))
            exit(2)
        }
        let signature = UpdateVerifier.decodeBase64(raw) ?? raw
        guard !UpdateSigningKey.publicKey.isEmpty,
              UpdateVerifier.verify(zip, signature: signature, publicKey: UpdateSigningKey.publicKey)
        else {
            print("signature: FAIL")
            exit(1)
        }
        print("signature: OK")
    }
}
