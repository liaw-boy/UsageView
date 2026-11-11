import AppKit
import Foundation

/// Checks GitHub (`liaw-boy/UsageView`) for newer releases and performs one-click self-update.
/// Uses the `gh` CLI when available (supporting private repos with existing local keyring auth),
/// and falls back to the public GitHub Releases endpoint through `HTTPClient`.
@MainActor
public final class UpdateService: ObservableObject {
    public nonisolated static let repo = "liaw-boy/UsageView"
    public static let currentVersion: String = {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.3.0"
    }()

    public enum Status: Equatable {
        case idle
        case checking
        case upToDate(String)
        case available(version: String, notes: String, assetURL: String?)
        case updating(String)
        case failed(String)
    }

    @Published public private(set) var status: Status = .idle
    private let http: HTTPClient
    private let defaults: UserDefaults
    private var periodicTimer: Timer?
    private static let lastCheckKey = "lastUpdateCheck"
    private static let pendingKey = "pendingUpdate"
    /// Raw release tag of the update currently offered (kept so downloads use the exact published tag).
    private(set) var pendingTag: String?

    public init(http: HTTPClient = HTTPClient(), defaults: UserDefaults = .standard) {
        self.http = http
        self.defaults = defaults
    }

    /// Checks on launch and then every `UpdateSchedule.interval`, but never more often than that: the last check time
    /// is persisted, so restarting the app does not hit GitHub again. The manual button still calls `checkForUpdates()`.
    public func startPeriodicChecks() {
        periodicTimer?.invalidate()
        restorePendingUpdate()
        Task { await checkIfDue() }
        let t = Timer(timeInterval: 30 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkIfDue() }
        }
        RunLoop.main.add(t, forMode: .common)
        periodicTimer = t
    }

    /// An update found before the app was restarted is offered again right away, even though the check itself is throttled.
    func restorePendingUpdate() {
        guard let saved = defaults.dictionary(forKey: Self.pendingKey) as? [String: String],
              let tag = saved["tag"], Self.isValidTag(tag) else {
            defaults.removeObject(forKey: Self.pendingKey)
            return
        }
        let version = Self.cleanVersion(tag)
        if Self.isNewer(version, than: Self.cleanVersion(Self.currentVersion)) {
            pendingTag = tag
            status = .available(version: version, notes: saved["notes"] ?? tag, assetURL: nil)
        } else {
            defaults.removeObject(forKey: Self.pendingKey)
        }
    }

    func checkIfDue(now: Date = Date()) async {
        let last = defaults.object(forKey: Self.lastCheckKey) as? Date
        guard UpdateSchedule.isDue(lastCheck: last, now: now) else { return }
        switch status {
        case .checking, .updating, .available: return
        default: break
        }
        await checkForUpdates()
    }

    public func checkForUpdates() async {
        status = .checking
        do {
            var release = try await fetchLatestReleaseViaGH()
            if release == nil {
                release = try await fetchLatestReleaseViaAPI()
            }
            defaults.set(Date(), forKey: Self.lastCheckKey)
            if let release, Self.isValidTag(release.tag) {
                let latest = Self.cleanVersion(release.tag)
                let current = Self.cleanVersion(Self.currentVersion)
                if Self.isNewer(latest, than: current) {
                    pendingTag = release.tag
                    defaults.set(["tag": release.tag, "notes": release.name], forKey: Self.pendingKey)
                    status = .available(version: latest, notes: release.name, assetURL: release.assetName)
                } else {
                    defaults.removeObject(forKey: Self.pendingKey)
                    status = .upToDate("目前已是最新版本（v\(current)）")
                }
            } else {
                status = .upToDate("目前已是最新版本（v\(Self.cleanVersion(Self.currentVersion))）")
            }
        } catch {
            status = .failed("檢查失敗：\(error.localizedDescription)")
        }
    }

    public func performUpdate() async {
        guard case .available(let version, _, _) = status, let tag = pendingTag, Self.isValidTag(tag) else { return }
        let currentBundle = Bundle.main.bundleURL
        guard currentBundle.pathExtension == "app" else {
            status = .failed("請從 UsageView.app 執行以套用自動替換更新")
            return
        }
        status = .updating("正在從 GitHub 下載 v\(version)…")
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("QuotaBarUpdate-\(UUID().uuidString)")
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: tempDir) }

        // Staged next to the installed app so the final swap is a same-volume rename, never a copy.
        let stagingParent = currentBundle.deletingLastPathComponent()
        let currentID = Bundle.main.bundleIdentifier
        let currentVersion = Self.currentVersion
        let outcome = await Task.detached {
            Self.downloadAndVerify(tag: tag, into: tempDir, stagingParent: stagingParent,
                                   currentBundleID: currentID, currentVersion: currentVersion)
        }.value

        switch outcome {
        case .ready(let newApp):
            status = .updating("正在替換並重新啟動…")
            replaceAndRelaunch(with: newApp)
        case .signatureInvalid, .contentMismatch:
            // Possible tampering: do not send the user to a download page.
            status = .failed(Self.failureMessage(for: outcome))
        case .keyNotConfigured, .downloadFailed, .signatureMissing:
            // Open the GitHub releases page so the user can inspect or download directly.
            if let url = URL(string: "https://github.com/\(Self.repo)/releases") {
                NSWorkspace.shared.open(url)
            }
            status = .failed(Self.failureMessage(for: outcome))
        }
    }

    // MARK: - Private helpers

    private struct ReleaseInfo: Sendable {
        let tag: String
        let name: String
        let assetName: String?
    }

    private func fetchLatestReleaseViaGH() async throws -> ReleaseInfo? {
        guard let gh = Self.findGHExecutable() else { return nil }
        let out = await Task.detached {
            Self.runProcess(gh, args: ["release", "view", "--repo", Self.repo, "--json", "tagName,name,assets"])
        }.value
        guard out.status == 0,
              let json = try? JSONSerialization.jsonObject(with: out.data) as? [String: Any],
              let tag = json["tagName"] as? String
        else { return nil }
        let name = (json["name"] as? String) ?? tag
        let assets = json["assets"] as? [[String: Any]] ?? []
        let zipAsset = assets.compactMap { $0["name"] as? String }.first { $0.hasSuffix(".zip") }
        return ReleaseInfo(tag: tag, name: name, assetName: zipAsset)
    }

    private func fetchLatestReleaseViaAPI() async throws -> ReleaseInfo? {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        req.httpMethod = "GET"
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let r = try await http.send(req)
        if r.status == 404 { return nil } // No release published yet
        guard r.status == 200, let tag = r.json["tag_name"] as? String else { return nil }
        let name = (r.json["name"] as? String) ?? tag
        let assets = r.json["assets"] as? [[String: Any]] ?? []
        let zipAsset = assets.compactMap { $0["name"] as? String }.first { $0.hasSuffix(".zip") }
        return ReleaseInfo(tag: tag, name: name, assetName: zipAsset)
    }

    enum DownloadOutcome: Sendable {
        case ready(URL)
        case downloadFailed
        case signatureMissing
        case signatureInvalid
        case contentMismatch
        case keyNotConfigured
    }

    nonisolated static func failureMessage(for outcome: DownloadOutcome) -> String {
        switch outcome {
        case .ready: ""
        case .signatureInvalid: "更新檔簽章驗證失敗，已拒絕安裝"
        case .contentMismatch: "更新檔內容與預期版本不符，已拒絕安裝"
        case .keyNotConfigured: "此版本尚未設定更新簽章金鑰，無法自動更新，已為你開啟 GitHub Releases 頁面"
        case .downloadFailed, .signatureMissing: "無法自動下載或驗證此版本，已為你開啟 GitHub Releases 頁面"
        }
    }

    /// Release tags must look like `v1.2.3`; anything else (from untrusted JSON) is never used to build a URL or argument.
    nonisolated static func isValidTag(_ tag: String) -> Bool {
        tag.range(of: #"^[vV]?\d{1,4}\.\d{1,4}\.\d{1,4}$"#, options: .regularExpression) != nil
    }

    /// The signature only covers the zip bytes, so the unpacked app must also be the expected app and a real upgrade;
    /// otherwise an old, validly signed build could be replayed under a newer tag.
    nonisolated static func contentMatches(bundleID: String?, version: String?, expectedVersion: String,
                                           currentBundleID: String?, currentVersion: String) -> Bool {
        guard let bundleID, let version, let currentBundleID else { return false }
        return bundleID == currentBundleID
            && cleanVersion(version) == cleanVersion(expectedVersion)
            && isNewer(cleanVersion(version), than: cleanVersion(currentVersion))
    }

    nonisolated private static let maxDownloadBytes = 100_000_000

    /// Downloads the release zip and its detached Ed25519 signature for exactly `tag`, verifies the zip against the
    /// embedded public key, and only then unpacks it. Nothing unverified is ever unpacked or installed.
    nonisolated private static func downloadAndVerify(tag: String, into tempDir: URL, stagingParent: URL,
                                                      currentBundleID: String?, currentVersion: String) -> DownloadOutcome {
        let fm = FileManager.default
        let publicKey = UpdateSigningKey.publicKey
        guard !publicKey.isEmpty else { return .keyNotConfigured }
        let zipURL = tempDir.appendingPathComponent("UsageView.app.zip")
        let sigURL = tempDir.appendingPathComponent("UsageView.app.zip.sig")
        let base = "https://github.com/\(repo)/releases/download/\(tag)/"
        func curl(_ name: String, to target: URL) -> Bool {
            runProcess("/usr/bin/curl", args: [
                "-fsSL", "--proto", "=https", "--proto-redir", "=https",
                "--max-time", "180", "--max-filesize", "\(maxDownloadBytes)",
                base + name, "-o", target.path,
            ]).status == 0 && fm.fileExists(atPath: target.path)
        }

        // 1. Try gh CLI if available; 2. Fall back to curl from public GitHub Releases
        var got = false
        if let gh = findGHExecutable() {
            let code = runProcess(gh, args: [
                "release", "download", tag, "--repo", repo,
                "--pattern", "UsageView.app.zip", "--pattern", "UsageView.app.zip.sig", "--dir", tempDir.path,
            ]).status
            got = code == 0 && fm.fileExists(atPath: zipURL.path)
        }
        if !got {
            guard curl("UsageView.app.zip", to: zipURL) else { return .downloadFailed }
        }
        if !fm.fileExists(atPath: sigURL.path) { _ = curl("UsageView.app.zip.sig", to: sigURL) }

        let size = (try? fm.attributesOfItem(atPath: zipURL.path)[.size] as? Int) ?? nil
        guard let size, size <= maxDownloadBytes, let zipData = try? Data(contentsOf: zipURL) else { return .downloadFailed }
        guard let sigText = try? Data(contentsOf: sigURL), let signature = UpdateVerifier.decodeBase64(sigText) else {
            return .signatureMissing
        }
        guard UpdateVerifier.verify(zipData, signature: signature, publicKey: publicKey) else {
            return .signatureInvalid
        }

        let extracted = tempDir.appendingPathComponent("extracted")
        try? fm.createDirectory(at: extracted, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard runProcess("/usr/bin/ditto", args: ["-x", "-k", zipURL.path, extracted.path]).status == 0,
              let app = (try? fm.contentsOfDirectory(at: extracted, includingPropertiesForKeys: nil))?
                  .first(where: { $0.pathExtension == "app" })
        else { return .downloadFailed }

        let info = Bundle(url: app)?.infoDictionary
        guard contentMatches(
            bundleID: info?["CFBundleIdentifier"] as? String,
            version: info?["CFBundleShortVersionString"] as? String,
            expectedVersion: cleanVersion(tag),
            currentBundleID: currentBundleID,
            currentVersion: currentVersion
        ) else { return .contentMismatch }

        // Moved out of `tempDir` so the caller's cleanup does not delete the verified bundle before it is installed.
        let staged = stagingParent.appendingPathComponent(".UsageView-staged-\(UUID().uuidString).app")
        guard (try? fm.moveItem(at: app, to: staged)) != nil else { return .downloadFailed }
        return .ready(staged)
    }

    private func replaceAndRelaunch(with newBundle: URL) {
        let currentBundle = Bundle.main.bundleURL
        guard currentBundle.pathExtension == "app" else {
            try? FileManager.default.removeItem(at: newBundle)
            status = .failed("請從 UsageView.app 執行以套用自動替換更新")
            return
        }
        do {
            try UpdateInstaller.replace(current: currentBundle, with: newBundle)
        } catch {
            try? FileManager.default.removeItem(at: newBundle)
            status = .failed(error.localizedDescription)
            return
        }
        // The new bundle is already in place; the helper only waits for this process to exit and reopens it.
        let pid = ProcessInfo.processInfo.processIdentifier
        // Path and pid are passed as arguments, never interpolated into the script text.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", #"while kill -0 "$1" 2>/dev/null; do sleep 0.2; done; open "$2""#, "_", "\(pid)", currentBundle.path]
        do {
            try p.run()
        } catch {
            status = .failed("已更新到新版，請手動重新開啟 UsageView")
            return
        }
        NSApp.terminate(nil)
    }

    nonisolated private static func findGHExecutable() -> String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated private static func runProcess(_ launchPath: String, args: [String]) -> (status: Int32, data: Data) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, Data()) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, data)
    }

    nonisolated static func cleanVersion(_ v: String) -> String {
        v.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^[vV]", with: "", options: .regularExpression)
    }

    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").compactMap { Int($0) }
        let b = current.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(a.count, b.count) {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av != bv { return av > bv }
        }
        return false
    }
}
