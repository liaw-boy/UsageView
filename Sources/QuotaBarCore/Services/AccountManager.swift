import AppKit
import Foundation

public actor AccountManager {
    public static let shared = AccountManager()

    private let storageURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".usageview", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [
                .posixPermissions: 0o700
            ])
        }
        return dir.appendingPathComponent("profiles.json")
    }()

    private var profiles: [AccountProfile] = []
    private var isLoaded = false

    public init() {}

    // MARK: - Persistence

    private func loadProfiles() {
        guard !isLoaded else { return }
        isLoaded = true
        guard let data = try? Data(contentsOf: storageURL),
              let list = try? JSONDecoder().decode([AccountProfile].self, from: data)
        else {
            profiles = []
            return
        }
        profiles = list
    }

    private func saveProfiles() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        try? data.write(to: storageURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
    }

    public func getProfiles(provider: ProviderID? = nil) -> [AccountProfile] {
        loadProfiles()
        if let provider {
            return profiles.filter { $0.provider == provider }
        }
        return profiles
    }

    // MARK: - Auto Discovery & Snapshot

    /// Inspects the currently active system credentials on disk/keychain.
    /// If not yet recorded as a profile, captures it and fetches full email/name from the official API.
    public func autoSnapshotCurrentIfNeeded() async -> [AccountProfile] {
        loadProfiles()

        for provider in ProviderID.allCases {
            guard let raw = getCurrentSystemPayload(provider: provider) else { continue }

            // Check if this payload is already stored in an existing profile
            if let existingIndex = profiles.firstIndex(where: { $0.provider == provider && isPayloadMatching($0.rawPayload, raw, provider: provider) }) {
                // Ensure it is marked active
                for i in profiles.indices where profiles[i].provider == provider {
                    profiles[i].isActive = (i == existingIndex)
                }
            } else {
                // Brand new active account discovered! Fetch real details from API
                let info = await fetchAccountInfo(provider: provider, rawPayload: raw)
                let defaultName = info.name ?? info.email ?? "主要帳號"
                let newProfile = AccountProfile(
                    provider: provider,
                    name: defaultName,
                    email: info.email,
                    orgName: info.orgName,
                    plan: info.plan,
                    colorTag: defaultColor(for: provider, index: profiles.filter { $0.provider == provider }.count),
                    rawPayload: raw,
                    isActive: true,
                    createdAt: Date(),
                    lastUsedAt: Date()
                )
                // Set any other profiles of this provider to inactive
                for i in profiles.indices where profiles[i].provider == provider {
                    profiles[i].isActive = false
                }
                profiles.append(newProfile)
            }
        }

        saveProfiles()
        return profiles
    }

    private func isPayloadMatching(_ a: String, _ b: String, provider: ProviderID) -> Bool {
        if a == b { return true }
        guard let objA = Parse.object(a), let objB = Parse.object(b) else { return false }

        switch provider {
        case .claude:
            let tokA = (objA["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String
            let tokB = (objB["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String
            return tokA != nil && tokA == tokB
        case .codex:
            let tokA = (objA["tokens"] as? [String: Any])?["access_token"] as? String
            let tokB = (objB["tokens"] as? [String: Any])?["access_token"] as? String
            return tokA != nil && tokA == tokB
        case .antigravity:
            let tokA = (objA["token"] as? [String: Any])?["access_token"] as? String ?? objA["access_token"] as? String
            let tokB = (objB["token"] as? [String: Any])?["access_token"] as? String ?? objB["access_token"] as? String
            return tokA != nil && tokA == tokB
        }
    }

    // MARK: - Current System Payload Reader

    private func getCurrentSystemPayload(provider: ProviderID) -> String? {
        let creds = SystemCredentialSource()
        switch provider {
        case .claude:
            if let text = creds.keychain(service: "Claude Code-credentials", account: nil), !text.isEmpty {
                return text
            }
            let base = creds.env("CLAUDE_CONFIG_DIR") ?? "~/.claude"
            if let d = creds.file(base + "/.credentials.json"), let s = String(data: d, encoding: .utf8), !s.isEmpty {
                return s
            }
            return nil
        case .codex:
            let home = creds.env("CODEX_HOME") ?? "~/.codex"
            if let d = creds.file(home + "/auth.json"), let s = String(data: d, encoding: .utf8), !s.isEmpty {
                return s
            }
            return nil
        case .antigravity:
            if var text = creds.keychain(service: "gemini", account: "antigravity"), !text.isEmpty {
                let prefix = "go-keyring-base64:"
                if text.hasPrefix(prefix), let d = Data(base64Encoded: String(text.dropFirst(prefix.count))),
                   let decoded = String(data: d, encoding: .utf8) {
                    text = decoded
                }
                return text
            }
            return nil
        }
    }

    // MARK: - API Info Fetcher

    public func fetchAccountInfo(provider: ProviderID, rawPayload: String) async -> (email: String?, name: String?, orgName: String?, plan: String?) {
        guard let obj = Parse.object(rawPayload) else { return (nil, nil, nil, nil) }

        switch provider {
        case .claude:
            guard let oauth = obj["claudeAiOauth"] as? [String: Any],
                  let token = (oauth["accessToken"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty
            else { return (nil, nil, nil, nil) }

            let subType = oauth["subscriptionType"] as? String
            let tier = oauth["rateLimitTier"] as? String
            let plan = ClaudeMapper.formatPlan(subscriptionType: subType, rateLimitTier: tier)

            // Request https://api.anthropic.com/api/oauth/account
            var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/account")!)
            req.httpMethod = "GET"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("claude-cli/2.1.294 (external, cli)", forHTTPHeaderField: "User-Agent")

            if let (data, resp) = try? await URLSession.shared.data(for: req),
               let http = resp as? HTTPURLResponse, http.statusCode == 200,
               let userObj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                let email = userObj["email_address"] as? String
                let name = (userObj["full_name"] as? String) ?? (userObj["display_name"] as? String)
                var orgName: String? = nil
                if let memberships = userObj["memberships"] as? [[String: Any]],
                   let firstOrg = memberships.first?["organization"] as? [String: Any] {
                    orgName = firstOrg["name"] as? String
                }
                return (email, name, orgName, plan)
            }
            return (nil, nil, nil, plan)

        case .antigravity:
            let src = obj["token"] as? [String: Any] ?? obj
            guard let token = (src["access_token"] ?? src["accessToken"]) as? String, !token.isEmpty else {
                return (nil, nil, nil, nil)
            }

            // Request https://www.googleapis.com/oauth2/v3/userinfo
            var req = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            if let (data, resp) = try? await URLSession.shared.data(for: req),
               let http = resp as? HTTPURLResponse, http.statusCode == 200,
               let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                let email = info["email"] as? String
                let name = info["name"] as? String
                return (email, name, nil, "Gemini")
            }
            return (nil, nil, nil, nil)

        case .codex:
            let tokens = obj["tokens"] as? [String: Any] ?? [:]
            let email = tokens["email"] as? String
            let accountId = tokens["account_id"] as? String
            let name = email != nil ? nil : accountId
            return (email, name, nil, nil)
        }
    }

    // MARK: - Actions: Switch Account

    /// Atomically replaces system credentials with the chosen profile.
    public func switchAccount(to profile: AccountProfile) async throws {
        loadProfiles()

        let payload = profile.rawPayload

        switch profile.provider {
        case .claude:
            // 1. Write ~/.claude/.credentials.json
            let home = FileManager.default.homeDirectoryForCurrentUser
            let fileURL = home.appendingPathComponent(".claude/.credentials.json")
            if let data = payload.data(using: .utf8) {
                try data.write(to: fileURL, options: .atomic)
            }
            // 2. Update macOS Keychain item "Claude Code-credentials"
            let user = NSUserName()
            _ = Self.writeKeychain(service: "Claude Code-credentials", account: user, password: payload)

        case .codex:
            // 1. Write ~/.codex/auth.json
            let home = FileManager.default.homeDirectoryForCurrentUser
            let fileURL = home.appendingPathComponent(".codex/auth.json")
            if let data = payload.data(using: .utf8) {
                try data.write(to: fileURL, options: .atomic)
            }

        case .antigravity:
            // 1. Write Keychain "gemini" / "antigravity"
            let b64 = "go-keyring-base64:" + Data(payload.utf8).base64EncodedString()
            _ = Self.writeKeychain(service: "gemini", account: "antigravity", password: b64)
        }

        // Update active profile state
        for i in profiles.indices where profiles[i].provider == profile.provider {
            if profiles[i].id == profile.id {
                profiles[i].isActive = true
                profiles[i].lastUsedAt = Date()
            } else {
                profiles[i].isActive = false
            }
        }

        saveProfiles()
    }

    // MARK: - Actions: Save Current as Profile

    public func saveCurrentAsNewProfile(provider: ProviderID, name: String, colorTag: String) async throws -> AccountProfile {
        loadProfiles()
        guard let raw = getCurrentSystemPayload(provider: provider) else {
            throw NSError(domain: "AccountManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "目前系統中找不到 \(provider.displayName) 的登入憑證"])
        }

        let info = await fetchAccountInfo(provider: provider, rawPayload: raw)
        let profile = AccountProfile(
            provider: provider,
            name: name.isEmpty ? (info.name ?? info.email ?? "自訂帳號") : name,
            email: info.email,
            orgName: info.orgName,
            plan: info.plan,
            colorTag: colorTag,
            rawPayload: raw,
            isActive: true,
            createdAt: Date(),
            lastUsedAt: Date()
        )

        for i in profiles.indices where profiles[i].provider == provider {
            profiles[i].isActive = false
        }
        profiles.append(profile)
        saveProfiles()
        return profile
    }

    public func renameProfile(id: String, newName: String, colorTag: String?) {
        loadProfiles()
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[idx].name = newName
        if let colorTag { profiles[idx].colorTag = colorTag }
        saveProfiles()
    }

    public func deleteProfile(id: String) throws {
        loadProfiles()
        profiles.removeAll { $0.id == id }
        saveProfiles()
    }

    // MARK: - Keychain Helper

    @discardableResult
    private static func writeKeychain(service: String, account: String?, password: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        var args = ["add-generic-password", "-s", service, "-w", password, "-U"]
        if let account, !account.isEmpty {
            args += ["-a", account]
        }
        p.arguments = args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func defaultColor(for provider: ProviderID, index: Int) -> String {
        let colors = ["#4A90E2", "#50E3C2", "#F5A623", "#BD10E0", "#E02020", "#7ED321", "#9013FE"]
        return colors[index % colors.count]
    }
}
