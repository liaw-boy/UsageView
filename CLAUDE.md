# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 專案概述

UsageView：macOS 14+ 原生狀態列 App（Swift 5.10、純 SwiftPM、無 Xcode 專案），監控 Claude / Codex / Antigravity 的訂閱額度。SwiftPM package 名稱與 target 仍叫 `QuotaBar`，產出的 App 叫 `UsageView`。README（繁體中文）有完整功能與截圖說明。

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
- `Services/EndpointGuard.swift`：**所有網路請求的唯一關卡**。只允許白名單內的唯讀 method+host+path（不允許 query string、必須 https）。`HTTPClient` 每次請求前都會呼叫它。新增任何對外請求都必須先加進白名單並補測試；絕不可呼叫推論、重設額度、輪換 Claude/Codex OAuth refresh 的端點。
- `Services/Credentials.swift`：`CredentialSource` 抽象（Keychain / 檔案 / env），測試時可注入假實作。憑證只讀不寫，token 只存記憶體；`HTTPClient` 不跟隨任何轉址（`EndpointGuard` 只檢查原始 URL）。
- `Stores/SnapshotStore.swift`：Stale-While-Revalidate 快取，以磁碟上的 `fetchedAt` 與 `refreshMinutes` 決定是否重打 API（重啟 App 或開面板都不會多打）；失敗時保留舊快照並對 429 退避。
- `Stores/SettingsStore.swift`：以 `UserDefaults` 儲存，建構子可注入 `UserDefaults`（測試用獨立 suite）。每家 AI 有三層獨立開關：追蹤／面板／狀態列；未追蹤者完全不讀憑證、不發請求。
- `LocalUsageScanner` 離線掃描 `~/.claude/projects`、`~/.codex/sessions`、`~/.gemini/antigravity*` 計算 token 與 API 等效花費；`ConversationManager` 掃描 Claude / Codex / Antigravity 對話並移至垃圾桶（「釋放空間」門檻由 `SettingsStore.cleanupMinAgeDays`/`cleanupMinSizeMB` 設定）；`UpdateService` 從 GitHub Release 檢查/下載/熱替換更新。

**App（`Sources/QuotaBar`）**
- `App/AppContainer.swift`：`@main` 的 `AppDelegate`（純 AppKit、`.accessory` 無 Dock 圖示）+ `AppContainer` composition root 串起 settings/store/updater/notifier/status item；`QuotaNotifier` 負責 80%/95% 與「滿血復活」通知；`DocsImageExporter` 產生 README 圖片。
- `App/StatusItemController.swift`：`NSStatusItem` 渲染與 `NSPopover` 尺寸同步（popover 高度需限制在螢幕可視範圍內，預覽容器固定 368x508pt）。
- `Views/`：SwiftUI。`DashboardView`（主面板+偏好設定）、`RingGaugeView`（品牌 logo、雙環儀表、狀態列等寬視圖）、`ConversationManagerView`、`UsageStatisticsView`。

## 注意事項

- 版本號寫死在 `bundle.sh`（`CFBundleShortVersionString` 與結尾的 echo 兩處），並需與 GitHub Release tag 對應，自動更新才正確；發版/tag 需先徵得使用者同意。
- 狀態列文字用隱藏的 `"100%"` 等寬模板鎖寬，避免輪播時寬度跳動，改狀態列視圖時要保留這個行為。
- 原始碼與測試不可內嵌金鑰、個人路徑或真實帳號資料（測試資料一律虛構）。
