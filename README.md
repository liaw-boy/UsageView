# QuotaBar

macOS 原生狀態列小工具，查看 **Claude / Codex / Antigravity** 的 5 小時與每週額度。

- **架構與資料行為**參考 OpenUsage（Stale-while-revalidate 快取、失敗保留舊值、120 秒逾時、Codex 視窗長度分類、Antigravity 雙主機合併）。
- **自有 UI 設計**：「雙環儀表」（外圈 5h、內圈每週；Antigravity 分段顯示 Gemini 與 Claude/GPT 池）、毛玻璃面板、品牌色與門檻狀態色（>80% 琥珀、>95% 紅）、使用速度（悠閒 / 剛好 / 燒很快）標籤、已用/剩餘 % 切換。
- **零額度消耗與零金鑰內嵌保證**：
  - 專案原始碼不內嵌任何 API Key、OAuth Client Secret 或個人資訊。
  - 所有網路請求強制經過 [`EndpointGuard`](Sources/QuotaBarCore/Services/EndpointGuard.swift) 唯讀白名單，阻擋任何模型推論、重設點數消耗、以及任何 OAuth Token 刷新請求。

## 執行與測試

```sh
swift test                      # 執行白名單與解析單元測試
QUOTABAR_LOG=1 swift run        # 開發執行（終端機印出所有通過白名單的 URL）
./bundle.sh                     # 打包成 QuotaBar.app（無 Dock 圖示）
```

## 唯一允許的網路端點（[`EndpointGuard`](Sources/QuotaBarCore/Services/EndpointGuard.swift)）

| Provider | 方法 | 端點 | 用途 |
|---|---|---|---|
| Claude | `GET` | `https://api.anthropic.com/api/oauth/usage` | Claude Code `/usage` 唯讀查詢 |
| Codex | `GET` | `https://chatgpt.com/backend-api/wham/usage` | Codex `/status` 唯讀查詢 |
| Antigravity | `POST` | `https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary` | 唯讀額度摘要（body `{}`） |
| Antigravity | `POST` | `https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary` | 備援主機唯讀額度摘要 |
