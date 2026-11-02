import AppKit
import QuotaBarCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - View

struct ToolManagerView: View {
    @State private var inventory = ToolingInventory()
    @State private var tool: ToolID = .opencode
    @State private var kind: ToolingKind = .skill
    @State private var loading = false
    @State private var busy: String?
    @State private var pendingRemoval: ToolingItem?
    @State private var message: (title: String, body: String)?
    @State private var showingAdd = false

    private let actions = ToolingActions()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "工具管理", subtitle: "OpenCode、Claude Code、Codex 的 Skill / MCP / Plugin / Agent") {
                headerActions
            }
            toolPicker
            kindTabs
            content
        }
        .pageFrame(scrolls: false)
        .background(Theme.panelBackground)
        .environment(\.colorScheme, .dark)
        .task { await reload() }
        .overlay { if let busy { busyOverlay(busy) } }
        .confirmationDialog(
            pendingRemoval.map { "確定要移除「\($0.name)」？" } ?? "",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            if let item = pendingRemoval {
                Button("移除", role: .destructive) { Task { await perform("移除中…") { try await actions.remove(item) } } }
            }
            Button("取消", role: .cancel) { pendingRemoval = nil }
        } message: {
            if let item = pendingRemoval { Text(removalExplanation(item)) }
        }
        .alert(message?.title ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好") { message = nil }
        } message: {
            Text(message?.body ?? "")
        }
        .sheet(isPresented: $showingAdd) {
            AddSheet(tool: tool, kind: kind) { result in
                showingAdd = false
                if let result { Task { await perform("處理中…", work: result) } }
            }
        }
    }

    // MARK: Data

    private func reload() async {
        loading = true
        inventory = await Task.detached(priority: .userInitiated) { ToolingScanner.scan() }.value
        loading = false
    }

    private func perform(_ label: String, work: @escaping () async throws -> String) async {
        busy = label
        defer { busy = nil }
        do {
            let output = try await work()
            pendingRemoval = nil
            await reload()
            message = ("完成", output.isEmpty ? "已完成。" : output)
        } catch {
            pendingRemoval = nil
            message = ("失敗", error.localizedDescription)
        }
    }

    private func removalExplanation(_ item: ToolingItem) -> String {
        var lines: [String] = []
        switch actions.removalMethod(for: item) {
        case .trash:
            lines.append("會移到「垃圾桶」，可以復原。")
            if let loc = item.location { lines.append((loc as NSString).abbreviatingWithTildeInPath) }
        case .cli(let command):
            lines.append("會執行：\(command)")
        case .editOpenCodeConfig:
            lines.append("會從 opencode.json 刪除這個設定（先自動備份原檔）。")
        case .none:
            lines.append("無法從這裡移除。")
        }
        if !item.sharedWith.isEmpty {
            lines.append("⚠︎ 這個項目與 \(item.sharedWith.map(\.displayName).joined(separator: "、")) 共用，移除後那邊也會消失。")
        }
        // OpenCode watches its config files and reloads automatically; the others need a restart.
        lines.append(item.tool == .opencode
            ? "OpenCode 會自動重新載入設定，不需要重開（必要時用 /reload）。"
            : "變更通常需要重新啟動 \(item.tool.displayName) 才會生效。")
        return lines.joined(separator: "\n")
    }

    // MARK: Sidebar

    private var toolPicker: some View {
        HStack(spacing: 8) {
            ForEach(ToolID.allCases) { t in
                let selected = tool == t
                let missing = inventory.notInstalled.contains(t)
                Button { tool = t } label: {
                    HStack(spacing: 6) {
                        Text(t.displayName)
                        if missing {
                            Text("未安裝").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                        }
                    }
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(missing ? 0.45 : (selected ? 1 : 0.75)))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(selected ? Color.white.opacity(0.16) : Color.white.opacity(0.05), in: Capsule())
                    .overlay(Capsule().strokeBorder(selected ? Color.white.opacity(0.3) : Color.clear, lineWidth: 0.8))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Header

    private var canAdd: Bool {
        guard !inventory.notInstalled.contains(tool), tool != .codex else { return false }
        return kind != .agent
    }

    private var kindTabs: some View {
        HStack(spacing: 4) {
            ForEach(ToolingKind.allCases) { k in
                let selected = kind == k
                Button { kind = k } label: {
                    HStack(spacing: 5) {
                        Text(k.title)
                        Text("\(inventory.count(for: tool, kind: k))")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(selected ? .white : .white.opacity(0.55))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(selected ? Color.white.opacity(0.18) : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private var headerActions: some View {
        HStack(spacing: 8) {
            if loading { ProgressView().controlSize(.small) }
            Button { Task { await reload() } } label: {
                Label("重新掃描", systemImage: "arrow.clockwise")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Theme.cardBackground, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.cardBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.85))
            if canAdd {
                Button { showingAdd = true } label: {
                    Label("新增", systemImage: "plus")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.9))
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let items = inventory.items(for: tool, kind: kind)
        if inventory.notInstalled.contains(tool) {
            placeholder("找不到 \(tool.displayName) 的設定資料夾，看起來尚未安裝。")
        } else if items.isEmpty {
            placeholder("沒有已安裝的 \(kind.title)。")
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(items) { row($0) }
                    ForEach(inventory.warnings, id: \.self) { w in
                        Text("⚠︎ \(w)").font(.system(size: 11)).foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.5))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ item: ToolingItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    statusBadge(item.status)
                    ForEach(item.sharedWith) { other in
                        badge("與 \(other.displayName) 共用", tint: Theme.brandColor(.antigravity))
                    }
                }
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(2)
                }
                if let loc = item.location {
                    Text((loc as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)

            if actions.canAuthorize(item) {
                iconButton("key.fill", help: "在「終端機」開始 OAuth 授權") {
                    Task { await perform("開啟終端機…") { try actions.authorize(item) } }
                }
            }
            if actions.canToggle(item) {
                iconButton(item.status == .enabled ? "pause.circle" : "play.circle",
                           help: item.status == .enabled ? "停用" : "啟用") {
                    Task { await perform("套用中…") { try await actions.setEnabled(item, enabled: item.status != .enabled) } }
                }
            }
            if let loc = item.location {
                iconButton("folder", help: "在 Finder 顯示") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: loc)])
                }
            }
            if actions.removalMethod(for: item) != nil {
                iconButton("trash", help: "移除", tint: Color(red: 0.98, green: 0.45, blue: 0.45)) {
                    pendingRemoval = item
                }
            }
        }
        .padding(10)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.cardBorder, lineWidth: 0.8))
    }

    private func iconButton(_ systemName: String, help: String, tint: Color = .white.opacity(0.6),
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .foregroundStyle(tint)
                .frame(width: 22, height: 20)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private func statusBadge(_ s: ToolingStatus) -> some View {
        switch s {
        case .enabled: badge("啟用", tint: Color(red: 0.30, green: 0.88, blue: 0.56))
        case .disabled: badge("停用", tint: .gray)
        case .unknown: EmptyView()
        }
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .bold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(tint.opacity(0.15), in: Capsule())
            .fixedSize()
    }

    private func busyOverlay(_ label: String) -> some View {
        ZStack {
            Color.black.opacity(0.45)
            VStack(spacing: 8) {
                ProgressView()
                Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
            }
            .padding(20)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 12))
        }
        .ignoresSafeArea()
    }
}

// MARK: - Add sheet

private struct AddSheet: View {
    let tool: ToolID
    let kind: ToolingKind
    /// Returns the work to run, or nil when cancelled.
    let done: ((() async throws -> String)?) -> Void

    private let actions = ToolingActions()

    @State private var name = ""
    @State private var spec = ""
    @State private var isRemote = true
    @State private var url = ""
    @State private var command = ""
    @State private var pairs = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            switch kind {
            case .skill:
                Text("選擇一個包含 SKILL.md 的資料夾，會複製到 \(tool.displayName) 的 skills 資料夾（不覆蓋同名項目）。")
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.7))
                Button("選擇資料夾…") { pickFolder() }
            case .plugin:
                field("套件", text: $spec, prompt: tool == .opencode ? "npm 套件或 Git 指定字串" : "plugin@marketplace")
                Text(tool == .opencode ? "會執行 opencode plugin add" : "會執行 claude plugin install")
                    .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5))
            case .mcp:
                field("名稱", text: $name, prompt: "my-server")
                Picker("", selection: $isRemote) {
                    Text("遠端 (HTTP)").tag(true)
                    Text("本機 (stdio)").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden()
                if isRemote {
                    field("網址", text: $url, prompt: "https://example.com/mcp")
                    field("標頭（選填，一行一個 Key: Value）", text: $pairs, prompt: "Authorization: Bearer …", multiline: true)
                } else {
                    field("指令", text: $command, prompt: "npx -y some-mcp-server")
                    field("環境變數（選填，一行一個 KEY=value）", text: $pairs, prompt: "API_KEY=…", multiline: true)
                }
                Text(tool == .opencode
                     ? "建議填 {env:MY_TOKEN} 這種環境變數參照，不要把金鑰寫進設定檔。遠端伺服器多半支援 OAuth，可先留空再用鑰匙按鈕授權。"
                     : "UsageView 不會儲存或顯示機密值，但 \(tool.displayName) 的 CLI 只能用命令列參數接收，執行的幾秒內同一台電腦上的其他程式可能看到。請盡量用可隨時撤銷的 token。")
                    .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            case .agent:
                EmptyView()
            }

            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("取消") { done(nil) }
                if kind != .skill {
                    Button("新增") { submit() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(18)
        .frame(width: 420)
        .background(Theme.panelBackground)
        .environment(\.colorScheme, .dark)
    }

    private var title: String {
        "新增 \(tool.displayName) 的 \(kind.title)"
    }

    @ViewBuilder
    private func field(_ label: String, text: Binding<String>, prompt: String, multiline: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.75))
            if multiline {
                TextEditor(text: text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .frame(height: 54)
                    .scrollContentBackground(.hidden)
                    .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
            } else {
                TextField(prompt, text: text).textFieldStyle(.roundedBorder)
            }
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "安裝"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let t = tool
        done({ try ToolingActions().installSkill(from: folder, for: t) })
    }

    /// "Key: Value" (headers) or "KEY=value" (env), one per line.
    private func parsePairs(separator: Character) -> [String: String] {
        var out: [String: String] = [:]
        for line in pairs.split(separator: "\n") {
            guard let idx = line.firstIndex(of: separator) else { continue }
            let k = line[..<idx].trimmingCharacters(in: .whitespaces)
            let v = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
            if !k.isEmpty, !v.isEmpty { out[k] = v }
        }
        return out
    }

    private func submit() {
        error = nil
        let t = tool
        switch kind {
        case .plugin:
            let s = spec
            do { try ToolingActions.validateSpec(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
            catch { self.error = error.localizedDescription; return }
            done({ try await ToolingActions().addPlugin(s, for: t) })
        case .mcp:
            let n = name
            do { try ToolingActions.validateName(n.trimmingCharacters(in: .whitespacesAndNewlines)) }
            catch { self.error = error.localizedDescription; return }
            let spec: NewMCP
            if isRemote {
                do { try ToolingActions.validateURL(url.trimmingCharacters(in: .whitespacesAndNewlines)) }
                catch { self.error = error.localizedDescription; return }
                spec = .remote(url: url.trimmingCharacters(in: .whitespacesAndNewlines), headers: parsePairs(separator: ":"))
            } else {
                do { _ = try ToolingActions.splitCommand(command) }
                catch { self.error = error.localizedDescription; return }
                spec = .local(command: command, env: parsePairs(separator: "="))
            }
            done({ try await ToolingActions().addMCP(name: n, spec: spec, for: t) })
        case .skill, .agent:
            done(nil)
        }
    }
}
