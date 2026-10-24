import CryptoKit
import Foundation
import XCTest
@testable import QuotaBarCore

final class UpdateSecurityTests: XCTestCase {

    // MARK: - Signature verification

    func testValidSignatureIsAccepted() throws {
        let key = Curve25519.Signing.PrivateKey()
        let payload = Data("pretend this is a zip".utf8)
        let sig = try key.signature(for: payload)
        XCTAssertTrue(UpdateVerifier.verify(payload, signature: sig, publicKey: key.publicKey.rawRepresentation))
    }

    func testTamperedPayloadIsRejected() throws {
        let key = Curve25519.Signing.PrivateKey()
        let sig = try key.signature(for: Data("original".utf8))
        XCTAssertFalse(UpdateVerifier.verify(Data("tampered".utf8), signature: sig, publicKey: key.publicKey.rawRepresentation))
    }

    func testSignatureFromAnotherKeyIsRejected() throws {
        let signer = Curve25519.Signing.PrivateKey()
        let other = Curve25519.Signing.PrivateKey()
        let payload = Data("payload".utf8)
        let sig = try signer.signature(for: payload)
        XCTAssertFalse(UpdateVerifier.verify(payload, signature: sig, publicKey: other.publicKey.rawRepresentation))
    }

    func testMalformedKeyOrSignatureIsRejected() {
        let payload = Data("payload".utf8)
        XCTAssertFalse(UpdateVerifier.verify(payload, signature: Data(), publicKey: Data()))
        XCTAssertFalse(UpdateVerifier.verify(payload, signature: Data(repeating: 1, count: 64), publicKey: Data(repeating: 2, count: 5)))
    }

    func testBase64SignatureTextIsDecodedWithWhitespace() {
        let raw = Data((0..<64).map { UInt8($0) })
        let text = Data((raw.base64EncodedString() + "\n").utf8)
        XCTAssertEqual(UpdateVerifier.decodeBase64(text), raw)
        XCTAssertNil(UpdateVerifier.decodeBase64(Data("not base64!!".utf8)))
    }

    // MARK: - Check schedule

    func testScheduleDueRules() {
        let now = Date()
        XCTAssertTrue(UpdateSchedule.isDue(lastCheck: nil, now: now))
        XCTAssertFalse(UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(-3600), now: now))
        XCTAssertTrue(UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(-6 * 3600 - 1), now: now))
        // A timestamp in the future (clock changed) must not suppress checks forever.
        XCTAssertTrue(UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(3600), now: now))
    }

    // MARK: - Bundle replacement

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateInstallerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func makeBundle(at url: URL, marker: String) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try marker.write(to: url.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)
    }

    private func marker(of url: URL) -> String? {
        try? String(contentsOf: url.appendingPathComponent("marker.txt"), encoding: .utf8)
    }

    func testReplaceSwapsBundleAndRemovesBackup() throws {
        let dir = try makeDir()
        let current = dir.appendingPathComponent("App.app")
        let new = dir.appendingPathComponent("New.app")
        try makeBundle(at: current, marker: "old")
        try makeBundle(at: new, marker: "new")

        try UpdateInstaller.replace(current: current, with: new)

        XCTAssertEqual(marker(of: current), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: new.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(leftovers, ["App.app"])
    }

    func testReplaceRestoresOldBundleWhenNewOneIsMissing() throws {
        let dir = try makeDir()
        let current = dir.appendingPathComponent("App.app")
        try makeBundle(at: current, marker: "old")

        XCTAssertThrowsError(try UpdateInstaller.replace(current: current, with: dir.appendingPathComponent("Missing.app")))

        XCTAssertEqual(marker(of: current), "old")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(leftovers, ["App.app"])
    }
}

@MainActor
final class PendingUpdateTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: UUID().uuidString)!
    }

    func testPendingNewerUpdateSurvivesRestart() {
        let defaults = makeDefaults()
        defaults.set(["tag": "99.0.0", "notes": "Fictional release"], forKey: "pendingUpdate")
        let service = UpdateService(defaults: defaults)

        service.restorePendingUpdate()

        XCTAssertEqual(service.status, .available(version: "99.0.0", notes: "Fictional release", assetURL: nil))
        XCTAssertEqual(service.pendingTag, "99.0.0")
    }

    func testPendingUpdateThatIsNoLongerNewerIsDiscarded() {
        let defaults = makeDefaults()
        defaults.set(["tag": "v0.0.1", "notes": "Old"], forKey: "pendingUpdate")
        let service = UpdateService(defaults: defaults)

        service.restorePendingUpdate()

        XCTAssertEqual(service.status, .idle)
        XCTAssertNil(defaults.dictionary(forKey: "pendingUpdate"))
    }

    func testOutcomeMessagesDistinguishMissingKeyFromBadSignature() {
        XCTAssertNotEqual(UpdateService.failureMessage(for: .keyNotConfigured),
                          UpdateService.failureMessage(for: .signatureInvalid))
    }
}

final class UpdateHardeningTests: XCTestCase {
    func testReleaseTagFormatIsStrict() {
        for ok in ["v1.2.3", "0.10.0", "V2.0.1"] { XCTAssertTrue(UpdateService.isValidTag(ok), ok) }
        for bad in ["", "v1.2", "1.2.3.4", "v1.2.x", "v1.2.3/../x", "v1.2.3?x=1", "v1.2.3 ", "v1.2.3\n", "../v1.2.3", "v99999.0.0"] {
            XCTAssertFalse(UpdateService.isValidTag(bad), bad)
        }
    }

    func testBundleContentMustMatchExpectedIdentityAndBeNewer() {
        let ok = UpdateService.contentMatches(
            bundleID: "app.example.tool", version: "2.0.0",
            expectedVersion: "2.0.0", currentBundleID: "app.example.tool", currentVersion: "1.0.0"
        )
        XCTAssertTrue(ok)
        // Replayed old (validly signed) build uploaded under a newer tag.
        XCTAssertFalse(UpdateService.contentMatches(
            bundleID: "app.example.tool", version: "0.5.0",
            expectedVersion: "2.0.0", currentBundleID: "app.example.tool", currentVersion: "1.0.0"
        ))
        XCTAssertFalse(UpdateService.contentMatches(
            bundleID: "app.other", version: "2.0.0",
            expectedVersion: "2.0.0", currentBundleID: "app.example.tool", currentVersion: "1.0.0"
        ))
        XCTAssertFalse(UpdateService.contentMatches(
            bundleID: "app.example.tool", version: "1.0.0",
            expectedVersion: "1.0.0", currentBundleID: "app.example.tool", currentVersion: "1.0.0"
        ))
        XCTAssertFalse(UpdateService.contentMatches(
            bundleID: nil, version: nil,
            expectedVersion: "2.0.0", currentBundleID: "app.example.tool", currentVersion: "1.0.0"
        ))
    }

    func testEmptyEmbeddedKeyNeverVerifies() throws {
        // Guards against anyone turning "no key configured" into "skip verification".
        let key = Curve25519.Signing.PrivateKey()
        let payload = Data("x".utf8)
        let sig = try key.signature(for: payload)
        XCTAssertFalse(UpdateVerifier.verify(payload, signature: sig, publicKey: Data()))
    }
}
