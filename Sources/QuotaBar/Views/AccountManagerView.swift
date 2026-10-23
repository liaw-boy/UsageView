import AppKit
import QuotaBarCore
import SwiftUI

public struct AccountManagerView: View {
    var onBack: () -> Void
    var onSwitched: () -> Void

    @State private var profiles: [AccountProfile] = []
    @State private var selectedProvider: ProviderID = .claude
    @State private var isLoading = true
    @State private var toastText: String? = nil
    @State private var showingRenameAlert = false
    @State private var renameTargetProfile: AccountProfile? = nil
    @State private var renameText = ""
    @State private var showingAddPrompt = false
    @State private var newProfileName = ""
    @State private var selectedColorTag = "#4A90E2"

    private let availableColors = ["#4A90E2", "#50E3C2", "#F5A623", "#BD10E0", "#E02020", "#7ED321", "#9013FE"]

    public init(onBack: @escaping () -> Void, onSwitched: @escaping () -> Void) {
        self.onBack = onBack
        self.onSwitched = onSwitched
    }

    private var filteredProfiles: [AccountProfile] {
        profiles.filter { $0.provider == selectedProvider }
    }

    public var body: some View {
        VStack(spacing: 8) {
            header
            providerTabs
            infoTipBar
            profileList
            footerActions
        }
        .frame(width: 368, height: 508)
        .background(Theme.panelBackground)
        .environment(\.colorScheme, .dark)
        .task {
            await loadData()
        }
        .overlay(alignment: .bottom) {
            if let toast = toastText {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color(red: 0.30, green: 0.88, blue: 0.56))
                    Text(toast)
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.85), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                .shadow(radius: 6)
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                onBack()
            } label: {
                HStack(spacing: 3.5) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .bold))
                    Text("返回面板")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(.white.opacity(0.88))
                .padding(.horizontal, 8.5)
                .padding(.vertical, 4)
                .background(Theme.cardBackground, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.cardBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)

            Spacer()

            Text("帳號切換與管理")
                .font(.system(size: 13.5, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Spacer()

            Button {
                Task { await loadData(forceRescan: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 25, height: 25)
                    .background(Theme.cardBackground, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.cardBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("重新掃描並同步帳號憑證")
        }
    }

    // MARK: - Provider Tabs

    private var providerTabs: some View {
        HStack(spacing: 5) {
            ForEach(ProviderID.allCases) { p in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedProvider = p
                    }
                } label: {
                    HStack(spacing: 4) {
                        ProviderLogoView(provider: p, size: 12, tinted: selectedProvider == p)
                        Text(p.displayName)
                            .font(.system(size: 11, weight: selectedProvider == p ? .bold : .medium, design: .rounded))
                    }
                    .foregroundStyle(selectedProvider == p ? .white : .white.opacity(0.55))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(selectedProvider == p ? Theme.brandColor(p).opacity(0.25) : Color.white.opacity(0.05), in: Capsule())
                    .overlay(
                        Capsule().strokeBorder(selectedProvider == p ? Theme.brandColor(p).opacity(0.65) : Color.white.opacity(0.08), lineWidth: 0.9)
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    // MARK: - Info Tip

    private var infoTipBar: some View {
        HStack(spacing: 5) {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color(red: 0.98, green: 0.72, blue: 0.22))
            Text("切換後終端機下一次執行指令立即生效，完全免開瀏覽器。")
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.60))
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Profile List

    private var profileList: some View {
        ScrollView(.vertical, showsIndicators: true) {
            if isLoading {
                VStack(spacing: 8) {
                    ProgressView().scaleEffect(0.85)
                    Text("讀取帳號 Profiles 中…")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
            } else if filteredProfiles.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.system(size: 26))
                        .foregroundStyle(.white.opacity(0.35))
                    Text("尚未儲存 \(selectedProvider.displayName) 帳號 Profile")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.70))
                    Text("點擊下方按鈕將目前本機正在使用的登入存為第一個 Profile！")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.45))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)

                    Button {
                        saveCurrentProfile()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle.fill")
                            Text("儲存目前本機登入")
                        }
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Theme.brandColor(selectedProvider), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 45)
            } else {
                LazyVStack(spacing: 7) {
                    ForEach(filteredProfiles) { profile in
                        profileCard(profile)
                    }
                }
                .padding(.bottom, 6)
            }
        }
        .frame(height: 335)
    }

    // MARK: - Profile Card

    private func profileCard(_ profile: AccountProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                // Colored Avatar
                ZStack {
                    Circle()
                        .fill(Color(hex: profile.colorTag).opacity(0.25))
                        .frame(width: 32, height: 32)
                    Circle()
                        .strokeBorder(Color(hex: profile.colorTag).opacity(0.80), lineWidth: 1.2)
                        .frame(width: 32, height: 32)
                    Text(String(profile.name.prefix(1)).uppercased())
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(hex: profile.colorTag))
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(profile.name)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)

                        if profile.isActive {
                            HStack(spacing: 3) {
                                Circle()
                                    .fill(Color(red: 0.35, green: 0.85, blue: 0.55))
                                    .frame(width: 5, height: 5)
                                Text("作用中")
                                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                            }
                            .foregroundStyle(Color(red: 0.35, green: 0.85, blue: 0.55))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(red: 0.35, green: 0.85, blue: 0.55).opacity(0.15), in: Capsule())
                        }
                    }

                    if let email = profile.email, !email.isEmpty {
                        Text(email)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.65))
                    } else if let org = profile.orgName, !org.isEmpty {
                        Text(org)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }

                Spacer(minLength: 4)

                if let plan = profile.plan, !plan.isEmpty {
                    Text(plan)
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.98, green: 0.72, blue: 0.22))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Color(red: 0.98, green: 0.72, blue: 0.22).opacity(0.14), in: Capsule())
                }
            }

            Divider().overlay(Color.white.opacity(0.08))

            // Card Bottom Actions
            HStack {
                if profile.isActive {
                    Text("目前 CLI 使用此帳號")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                } else {
                    Button {
                        switchAccount(to: profile)
                    } label: {
                        HStack(alignment: .center, spacing: 3.5) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 9.5))
                            Text("切換為此帳號")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Color(red: 0.18, green: 0.52, blue: 0.95), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                // Rename action
                Button {
                    openRename(profile)
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(5)
                }
                .buttonStyle(.plain)
                .help("重新命名此帳號")

                // Delete action
                Button {
                    deleteProfile(profile)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(profile.isActive ? .white.opacity(0.20) : Color(red: 0.95, green: 0.35, blue: 0.35))
                        .padding(5)
                }
                .buttonStyle(.plain)
                .disabled(profile.isActive)
                .help(profile.isActive ? "作用中帳號無法直接刪除" : "移除此 Profile")
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(Theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(profile.isActive ? Color(red: 0.35, green: 0.85, blue: 0.55).opacity(0.40) : Theme.cardBorder, lineWidth: 1)
        )
    }

    // MARK: - Footer Actions

    private var footerActions: some View {
        HStack(spacing: 8) {
            Button {
                saveCurrentProfile()
            } label: {
                HStack(alignment: .center, spacing: 4) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 10))
                    Text("儲存目前本機登入")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(.white.opacity(0.90))
                .padding(.horizontal, 10)
                .frame(height: 27)
                .background(Theme.cardBackground, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.cardBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("將目前本機正在生效的登入憑證抓取並存為新 Profile")

            Spacer()

            Button {
                openAddHelp()
            } label: {
                HStack(alignment: .center, spacing: 4) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 10))
                    Text("新增另一個帳號…")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 27)
                .background(Color(red: 0.18, green: 0.52, blue: 0.95), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 2)
    }

    // MARK: - Actions

    private func loadData(forceRescan: Bool = false) async {
        isLoading = true
        let list = await AccountManager.shared.autoSnapshotCurrentIfNeeded()
        await MainActor.run {
            self.profiles = list
            self.isLoading = false
            if forceRescan {
                showToast("已重新同步本機帳號憑證")
            }
        }
    }

    private func switchAccount(to profile: AccountProfile) {
        Task {
            do {
                try await AccountManager.shared.switchAccount(to: profile)
                await loadData()
                await MainActor.run {
                    onSwitched()
                    showToast("已切換至【\(profile.name)】！下一次執行指令立即生效")
                }
            } catch {
                showToast("切換失敗：\(error.localizedDescription)")
            }
        }
    }

    private func saveCurrentProfile() {
        let alert = NSAlert()
        alert.messageText = "儲存目前 \(selectedProvider.displayName) 本機登入"
        alert.informativeText = "為目前本機正在使用的登入帳號設定別名（例如：主要個人、公司 Team）："
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = "個人帳號"
        alert.accessoryView = input
        alert.addButton(withTitle: "儲存")
        alert.addButton(withTitle: "取消")

        if alert.runModal() == .alertFirstButtonReturn {
            let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            Task {
                do {
                    let p = try await AccountManager.shared.saveCurrentAsNewProfile(
                        provider: selectedProvider,
                        name: name.isEmpty ? "個人帳號" : name,
                        colorTag: availableColors[profiles.count % availableColors.count]
                    )
                    await loadData()
                    showToast("已成功建立 Profile：\(p.name)")
                } catch {
                    showToast("儲存失敗：\(error.localizedDescription)")
                }
            }
        }
    }

    private func openRename(_ profile: AccountProfile) {
        let alert = NSAlert()
        alert.messageText = "重新命名帳號"
        alert.informativeText = "請輸入「\(profile.name)」的新別名："
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = profile.name
        alert.accessoryView = input
        alert.addButton(withTitle: "更新")
        alert.addButton(withTitle: "取消")

        if alert.runModal() == .alertFirstButtonReturn {
            let newN = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !newN.isEmpty {
                Task {
                    await AccountManager.shared.renameProfile(id: profile.id, newName: newN, colorTag: nil)
                    await loadData()
                    showToast("已更新名稱為「\(newN)」")
                }
            }
        }
    }

    private func deleteProfile(_ profile: AccountProfile) {
        let alert = NSAlert()
        alert.messageText = "確定移除此帳號 Profile？"
        alert.informativeText = "將從 UsageView 移除「\(profile.name)」。\n（不會影響本機目前的系統狀態）"
        alert.addButton(withTitle: "移除")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning

        if alert.runModal() == .alertFirstButtonReturn {
            Task {
                try? await AccountManager.shared.deleteProfile(id: profile.id)
                await loadData()
                showToast("已移除 Profile")
            }
        }
    }

    private func openAddHelp() {
        let alert = NSAlert()
        alert.messageText = "如何新增另一個 \(selectedProvider.displayName) 帳號？"
        alert.informativeText = """
        在終端機中登入另一個帳號的步驟：

        1. 在 Terminal 執行官方登入指令（例如 claude login）。
        2. 瀏覽器彈出時，登入您的第二個帳號並完成授權。
        3. 登入完成後，回到這裡點擊「儲存目前本機登入」，即可存為第二個 Profile！

        存入後，未來在 UsageView 點擊「切換為此帳號」，就能秒級無縫輪替，再也不需要開瀏覽器了！
        """
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    private func showToast(_ text: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            toastText = text
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3.0))
            withAnimation(.easeInOut(duration: 0.25)) {
                toastText = nil
            }
        }
    }
}

// MARK: - Color Hex Helper

private extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 74, 144, 226)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
