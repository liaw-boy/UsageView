import AppKit
import Foundation

/// Checks GitHub (`liaw-boy/quotabar`) for newer releases and performs one-click self-update.
/// Uses the `gh` CLI when available (supporting private repos with existing local keyring auth),
/// and falls back to the public GitHub Releases endpoint through `HTTPClient`.
@MainActor
public final class UpdateService: ObservableObject {
    public nonisolated static let repo = "liaw-boy/quotabar"
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

    public init(http: HTTPClient = HTTPClient()) {
        self.http = http
    }

    public func checkForUpdates() async {
        status = .checking
        do {
            var release = try await fetchLatestReleaseViaGH()
            if release == nil {
                release = try await fetchLatestReleaseViaAPI()
            }
            if let release {
                let latest = Self.cleanVersion(release.tag)
                let current = Self.cleanVersion(Self.currentVersion)
                if Self.isNewer(latest, than: current) {
                    status = .available(version: latest, notes: release.name, assetURL: release.assetName)
                } else {
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
        guard case .available(let version, _, _) = status else { return }
        status = .updating("正在從 GitHub 下載 v\(version)…")
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("QuotaBarUpdate-\(UUID().uuidString)")
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let downloaded = await Task.detached { () -> URL? in
            guard let gh = Self.findGHExecutable() else { return nil }
            let code = Self.runProcess(
                gh,
                args: ["release", "download", "--repo", Self.repo, "--pattern", "*.zip", "--dir", tempDir.path]
            ).status
            guard code == 0,
                  let zip = (try? fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil))?
                      .first(where: { $0.pathExtension == "zip" })
            else { return nil }
            let unzipCode = Self.runProcess("/usr/bin/ditto", args: ["-x", "-k", zip.path, tempDir.path]).status
            guard unzipCode == 0 else { return nil }
            return tempDir.appendingPathComponent("QuotaBar.app")
        }.value

        if let newApp = downloaded, fm.fileExists(atPath: newApp.path) {
            status = .updating("正在替換並重新啟動…")
            replaceAndRelaunch(with: newApp)
        } else {
            // Open the GitHub releases page so the user can inspect or download directly.
            if let url = URL(string: "https://github.com/\(Self.repo)/releases") {
                NSWorkspace.shared.open(url)
            }
            status = .failed("找不到預編譯 zip 資產，已為你開啟 GitHub Releases 頁面")
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

    private func replaceAndRelaunch(with newBundle: URL) {
        let currentBundle = Bundle.main.bundleURL
        guard currentBundle.pathExtension == "app" else {
            status = .failed("請從 QuotaBar.app 執行以套用自動替換更新")
            return
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(currentBundle.path)"
        mv "\(newBundle.path)" "\(currentBundle.path)"
        open "\(currentBundle.path)"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", script]
        try? p.run()
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
        p.standardError = Pipe()
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
