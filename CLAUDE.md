# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 專案概述

UsageView：macOS 14+ 原生狀態列 App（Swift 5.10、純 SwiftPM、無 Xcode 專案），監控 Claude / Codex / Antigravity 的訂閱額度，另外以本機資料顯示 OpenCode 花費。SwiftPM package 名稱與 target 仍叫 `QuotaBar`，產出的 App 叫 `UsageView`。README（繁體中文）有完整功能與截圖說明。

## 常用指令

```bash
swift test                                   # 全部測試
swift test --filter QuotaBarTests/testClaudeMapper   # 單一測試
QUOTABAR_LOG=1 swift run                     # 除錯：印出所有通過白名單的 HTTP 請求
./bundle.sh                                  # release build → UsageView.app / .app.zip / .dmg（含 icon 生成、ad-hoc codesign）
.build/debug/QuotaBar --export-docs-images <dir>   # 匯出 README 預覽圖（AppDelegate.main 內的特殊參數）
```

沒有 linter 設定。`reference-openusage/`、`reference-quotagem/` 是參考用的外部專案（已 gitignore），不要修改或當成本專案程式碼。

## 架構

兩個 target，依賴方向單向：`QuotaBar`（UI，executable）→ `QuotaBarCore`（資料層，無 UI）。測試只依賴 Core。

**Core（`Sources/QuotaBarCore`）**
- `Providers/Providers.swift`：每家 AI 一個 `ProviderRuntime`（`ClaudeRuntime`/`CodexRuntime`/`AntigravityRuntime`），由 `ProviderCatalog.all` 組裝。每個 provider = AuthStore（讀本機憑證）+ HTTP + Mapper（把回應正規化為 `MetricLine`）。Mapper 是純函式，測試主要針對這層。
- `Providers/OpenCodeUsage.swift`：OpenCode 沒有額度 API，`OpenCodeRuntime` 只以 SQLite 唯讀模式讀 `~/.local/share/opencode/opencode.db`（`session_message` 的 assistant `cost`/`tokens`），**不連網、不碰 `credential`/`account` 表**。預設只顯示花費（`lines` 為空）；選 Go / Go Plus / 自訂預算才換算 5H/7D 百分比（估算）。
- `Services/JSONCText.swift`：OpenCode 的 `opencode.json(c)` 允許註解與尾逗號。`object()` 解析 JSONC；`removingKey(path:)` 以「外科手術式」刪除單一鍵（註解、順序、縮排原封不動）——OpenCode 沒有 `mcp remove`，官方文件要求手動刪除設定項，所以不可整檔重新序列化。
- `Services/ToolingInventory.swift` / `Services/ToolingActions.swift`：「工具管理」視窗的資料層與唯一寫入層。Inventory 只讀 OpenCode / Claude Code / Codex 的 skill、MCP、plugin、agent（OpenCode 走 V2 `mcp.servers` + `plugins`，同時相容 V1 的 `mcp.<name>` + `plugin`；`disabled`/`enabled` 都認）（**絕不讀 MCP 的 env/headers/token**，只顯示型別＋host 或執行檔名）。Actions 負責刪除（檔案類一律 `trashItem` 移到垃圾桶，且只允許白名單資料夾的直接子項）、改 `opencode.json`（先備份 `*.usageview-bak-*`）、OAuth 授權改用 osascript 丟到「終端機」互動執行（官方文件警告 `opencode mcp auth` 的授權連結會被管線吞掉），以及呼叫 `opencode` / `claude` CLI（透過 `CommandRunning`，測試注入假 runner；參數用陣列傳入不經 shell，名稱/網址/指令都先驗證）。
- `Services/EndpointGuard.swift`：**所有網路請求的唯一關卡**。只允許白名單內的唯讀 method+host+path（不允許 query string、必須 https）。`HTTPClient` 每次請求前都會呼叫它。新增任何對外請求都必須先加進白名單並補測試；絕不可呼叫推論、重設額度、輪換 Claude/Codex OAuth refresh 的端點。
- `Services/Credentials.swift`：`CredentialSource` 抽象（Keychain / 檔案 / env），測試時可注入假實作。憑證只讀不寫，token 只存記憶體；`HTTPClient` 不跟隨任何轉址（`EndpointGuard` 只檢查原始 URL）。
- `Stores/SnapshotStore.swift`：Stale-While-Revalidate 快取，以磁碟上的 `fetchedAt` 與 `refreshMinutes` 決定是否重打 API（重啟 App 或開面板都不會多打）；失敗時保留舊快照並對 429 退避。
- `Stores/SettingsStore.swift`：以 `UserDefaults` 儲存，建構子可注入 `UserDefaults`（測試用獨立 suite）。每家 AI 有三層獨立開關：追蹤／面板／狀態列；未追蹤者完全不讀憑證、不發請求。
- `LocalUsageScanner` 離線掃描 `~/.claude/projects`、`~/.codex/sessions`、`~/.gemini/antigravity*` 計算 token 與 API 等效花費；`ConversationManager` 掃描 Claude / Codex / Antigravity 對話並移至垃圾桶（「釋放空間」門檻由 `SettingsStore.cleanupMinAgeDays`/`cleanupMinSizeMB` 設定）；`UpdateService` 從 GitHub Release 檢查/下載/熱替換更新（每 6 小時檢查一次；唯一不經 `EndpointGuard` 的下載，改用 `gh`/`curl` 抓 `UsageView.app.zip` 與 `.sig`，以內嵌 Ed25519 公鑰驗證通過才解壓安裝，見 `UpdateSecurity.swift`）。

**App（`Sources/QuotaBar`）**
- `App/AppContainer.swift`：`@main` 的 `AppDelegate`（純 AppKit、`.accessory` 無 Dock 圖示）+ `AppContainer` composition root 串起 settings/store/updater/notifier/status item；`QuotaNotifier` 負責 80%/95% 與「滿血復活」通知；`DocsImageExporter` 產生 README 圖片。
- `App/ToolManagerWindow.swift`：獨立 `NSWindow`（非 popover）的工具管理視窗；開啟時切 `.regular` 顯示 Dock 圖示，關閉回 `.accessory`。
- `App/StatusItemController.swift`：`NSStatusItem` 渲染與 `NSPopover` 尺寸同步（popover 高度需限制在螢幕可視範圍內，預覽容器固定 368x508pt）。
- `Views/`：SwiftUI。`DashboardView`（主面板+偏好設定）、`RingGaugeView`（品牌 logo、雙環儀表、狀態列等寬視圖）、`ConversationManagerView`、`UsageStatisticsView`。

## 注意事項

- 發版簽章：`swift scripts/gen_signing_key.swift <私鑰路徑>` 產生金鑰（私鑰不進 repo），把印出的公鑰貼到 `UpdateSecurity.swift` 的 `publicKeyBase64`；打包時設 `UPDATE_SIGNING_KEY=<私鑰路徑> ./bundle.sh` 產生 `.sig`，release 要同時上傳 zip 與 `.sig`。正式發版請加 `RELEASE=1`（沒有私鑰會直接失敗）。公鑰為空或沒有 `.sig` 時自動更新一律拒絕。
- 版本號寫死在 `bundle.sh`（`CFBundleShortVersionString` 與結尾的 echo 兩處），並需與 GitHub Release tag 對應，自動更新才正確；發版/tag 需先徵得使用者同意。
- 狀態列文字用隱藏的 `"100%"` 等寬模板鎖寬，避免輪播時寬度跳動，改狀態列視圖時要保留這個行為。
- 原始碼與測試不可內嵌金鑰、個人路徑或真實帳號資料（測試資料一律虛構）。
