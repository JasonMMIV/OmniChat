# OmniChat 上架審查計畫 (Windows Store & F-Droid Store Review Plan)

本計畫旨在全面審核 OmniChat 專案，確保順利通過 **Windows Store (Microsoft Store)** 與 **F-Droid** 雙平台的上架審查，並修復專案中的潛在缺陷、安全隱患與跨平台相容性問題。

---

## 審查進度總覽 (Review Status Dashboard)

| 階段 | 審查主題 | 狀態 | 核心結果摘要 |
| :--- | :--- | :---: | :--- |
| **Phase 0** | **準備與靜態基線掃描** | ✅ **已完成 (已修復)** | 排除 vendored 範例測試錯誤，靜態分析錯誤歸零 (`0 errors`)；移出 `nuget.exe` 追蹤。 |
| **Phase 1** | **F-Droid 合規性與開源授權專項** | ✅ **已完成 (待執行修復)** | 識別 Syncfusion 非 FOSS 授權阻礙；盤點過度權限 (`MANAGE_EXTERNAL_STORAGE`, `BLUETOOTH_ADVERTISE`)。 |
| **Phase 2** | **Windows Store 規範與 MSIX 專項** | ⏳ 待啟動 | WACK 測試防禦、MSIX 封裝、微軟 AI 內容政策、WebView2 依賴。 |
| **Phase 3** | **深度安全性與 MCP 架構** | ⏳ 待啟動 | API Key 安全儲存、備份匯出防洩漏、MCP 命令注入防禦、WebView/XSS。 |
| **Phase 4** | **跨平台穩定性與程式碼品質** | ⏳ 待啟動 | 原生插件跨平台隔離調用、Dispose 生命週期、檔案路徑相容性。 |
| **Phase 5** | **上架元數據與發布就緒確認** | ⏳ 待啟動 | 第三方開源授權聲明、雙語隱私權政策、商店多尺寸 Icon、F-Droid Recipe。 |

---

## 各階段詳細審查與執行紀錄

### 階段 0：準備與靜態基線掃描 (Pre-Review & Baseline Scan)
**狀態**：✅ **審查完成且阻礙點已修復**

#### 1. 審查發現與數據：
- **掃描規模**：314 個 Dart 檔案，約 16.5 萬行代碼。
- **靜態分析（修正前）**：共 3,906 項（2 Errors, 594 Warnings, 3,310 Infos）。
- **主要棄用 API**：2,266 處 `deprecated_member_use`（已另行擬定 [`DEPRECATED_API_MIGRATION_PLAN.md`](file:///c:/Users/w2bn1/Documents/GitHub/OmniChat/DEPRECATED_API_MIGRATION_PLAN.md) 供未來日常維護執行）。

#### 2. 已實施修正 (Applied Fixes)：
- [x] **【C-01】消除靜態分析編譯錯誤**：
  - 在 `analysis_options.yaml` 中新增 `analyzer.exclude`，排除 `dependencies/**/example/**`、`build/**` 與 `**/*.g.dart`。
  - **驗證結果**：`flutter analyze` 編譯錯誤降為 **0 Errors**。
- [x] **【C-02】移除預編譯二進制檔 Git 追蹤**：
  - 執行 `git rm --cached windows/nuget.exe`（8.48 MB）解除追蹤，消除 F-Droid 機器掃描對二進制 Blob (Binary Blobs) 的 Hard Reject 風險。
- [x] **【W-03】工作區金鑰安全確認**：
  - 確認 `.jks` 及 `key.properties` 均已受到 `.gitignore` 正確保護，未發生公開倉庫外洩。

---

### 階段 1：F-Droid 上架合規性專項審查 (F-Droid Compliance & FOSS Audit)
**狀態**：✅ **審查完成 (待安排代碼重構與替換)**

#### 1. 核心審查發現：

##### 🔴 阻礙 F-Droid 收錄之關鍵問題 (Critical Issues)：
1. **【C-F01】專有商業授權依賴：Syncfusion (`syncfusion_flutter_*`)**
   - **問題**：`syncfusion_flutter_sliders` 與 `syncfusion_flutter_pdf` 採用 Syncfusion 專有商業授權，非 OSI 認證 FOSS，F-Droid 官方掃描會直接拒收。
   - **影響範圍與替代方案**：
     - `syncfusion_flutter_sliders`：僅在 2 個檔案（`assistant_settings_edit_page.dart` 與 `display_settings_page.dart`）的 4 處單值滑桿使用（助理參數、字型大小、自動捲動秒數、背景強度）。**可直接平替為 Flutter 原生 Material 3 `Slider` / `SliderTheme`，達成 0 依賴**。
     - `syncfusion_flutter_pdf`：在 `document_text_extractor.dart`（PDF文字提取）與 `markdown_pdf_converter.dart`（Markdown 轉 PDF）使用。**可替換為 100% MIT 開源的 `pdf` 官方生態套件（`package:pdf/pdf.dart`）**。
2. **【C-F02】Android 權限過度宣告：`MANAGE_EXTERNAL_STORAGE`**
   - **問題**：`AndroidManifest.xml:6` 宣告了全域檔案存取權限。但代碼中自訂 Workspace 走的是系統 SAF（`ACTION_OPEN_DOCUMENT_TREE`），根本無需此權限。
   - **修復方案**：從 `AndroidManifest.xml` 與相關調用中徹底移除 `MANAGE_EXTERNAL_STORAGE`。
3. **【C-F03】冗餘的藍牙廣播權限：`BLUETOOTH_ADVERTISE`**
   - **問題**：`AndroidManifest.xml:18` 宣告了 BLE 廣播權限。語音聊天（Bluetooth SCO 耳機通話）僅需 `BLUETOOTH_CONNECT`。
   - **修復方案**：移除 `BLUETOOTH_ADVERTISE`。

##### 🟡 需在 F-Droid 宣告與網路優化項目 (Warnings)：
1. **【W-F01】全域明文傳輸 (`usesCleartextTraffic="true"`)**：
   - 建議配置 `res/xml/network_security_config.xml`，僅放行區域網路 Private IP 網段（Ollama 端點），其餘公網強制走 HTTPS。
2. **【W-F02】F-Droid Anti-Features 標籤預期 (`NonFreeNet`)**：
   - 支援雲端商業模型 API 屬於標準行為，需在 F-Droid Metadata 宣告 `AntiFeatures: [NonFreeNet]` 並註明原因。
3. **【W-F03】`google_fonts` 動態下載字型行為**：
   - 需於設定介面或 Metadata 說明字型下載行為，並確保預設系統字型可正常離線運作。

---

### 階段 2：Windows Store (Microsoft Store) 規範與封裝審查 (Windows Store & Packaging Audit)
**目標**：確保應用程式通過 Windows App Certification Kit (WACK) 與微軟商店政策。

1. **MSIX 封裝與應用程式識別**：
   - 審查 Windows 打包配置（Package Identity、Publisher 名稱、Version 格式 `x.x.x.0`）。
   - 檢查 `AppxManifest.xml` 中的 Capabilities 宣告（如 `microphone`, `internetClient`, `runFullTrust` 等）是否做到最小權限原則。
2. **WACK (Windows App Certification Kit) 規範檢查**：
   - **安全性防禦**：二進制檔案必須啟用 DEP (資料執行防止)、ASLR (位址空間配置隨機化) 與 Control Flow Guard。
   - **乾淨安裝與移除**：應用程式不能要求無理由的管理員提權 (UAC Elevation)，解除安裝時需能乾淨移除。
   - **崩潰與系統休眠**：不能阻止系統正常休眠或因無效例外導致靜默崩潰。
3. **微軟商店內容政策審查**：
   - **隱私權政策 (Privacy Policy)**：微軟商店強制要求在 App 內與商店頁面提供有效且公開的隱私權政策 URL。
   - **AI 生成內容政策 (Store Policy 10.8.4)**：檢查是否有合規的 AI 內容免責聲明、敏感內容過濾機制與使用者回報/封鎖管道。
   - **WebView2 依賴性**：檢查 `webview_windows` 是否妥善處理系統缺少 Evergreen WebView2 Runtime 時的降級與提示邏輯。
4. **桌面原生體驗與系統整合**：
   - 審查系統匣（Tray Icon）、全域快速鍵（Hotkey）、視窗縮放/最小化到系統匣的生命週期是否正常。

---

### 階段 3：深度安全性、隱私保護與 MCP 架構審查 (Security & Architecture Audit)
**目標**：防止金鑰洩漏、命令注入與不安全的數據儲存。

1. **憑證與敏感資訊安全性**：
   - 審查使用者的 API Key、自定義 Token 是存放在 `flutter_secure_storage`（加密存儲）還是明文 `shared_preferences` / `hive`。
   - 審查對話備份（Backup / Export）功能：匯出對話或設定檔時，是否會無意間將使用者的 API Key 以明文打包匯出。
   - 檢查程式碼中是否有任何寫死的測試 Token、開發金鑰或後端憑證。
2. **MCP (Model Context Protocol) 執行安全性**：
   - 審查本地 MCP Tool 執行邏輯：是否存在任意指令注入（Command Injection）風險。
   - 是否具備使用者確認機制（Human-in-the-loop）：在執行高風險操作（讀寫檔案、執行 Shell 指令）前是否有明確的 UI 授權提示。
3. **網路傳輸與 Web 內容安全**：
   - 審查 WebSocket、HTTP Client 與 Proxy (SOCKS5) 的連線加密與憑證校驗機制。
   - 檢查 `mermaid.min.js` 與 `mark.html` 等 WebView 注入腳本，防範 XSS（跨網站腳本攻擊）或本地檔案洩漏。
4. **本地數據與快取管理**：
   - 檢查暫存音訊、圖片暫存檔、快取日誌是否有定時清除機制，避免長期佔用空間或洩漏隱私。

---

### 階段 4：跨平台穩定性、資源生命週期與程式碼邏輯審查 (Multiplatform & Code Quality)
**目標**：消除執行時期 Crash、記憶體洩漏與平台特異性 Bug。

1. **跨平台邊界防護 (Platform Guarding)**：
   - 檢查所有 Windows 專屬套件（`window_manager`, `tray_manager`, `webview_windows`, `speech_to_text_windows`）在 Android 上執行時是否有嚴格的 `Platform.isWindows` 保護，避免 Android 啟動即崩潰。
   - 檢查 Android 專屬套件（`flutter_background`, `mobile_scanner`, `image_gallery_saver_plus`）在 Windows 上的調用保護。
2. **檔案系統與路徑相容性**：
   - 檢查路徑處理是否使用 `path.join()`，防範 Windows 反斜線 `\` 與 POSIX 斜線 `/` 造成的路徑解析錯誤。
   - 檢查 Windows 上的檔案鎖定（File Lock）情境處理（例如同時讀寫 Hive Box 或記錄檔）。
3. **資源釋放與記憶體管理**：
   - 審查 15 個業務模組中 `StreamSubscription`、`Timer`、`TextEditingController`、`ScrollController` 是否都在 `dispose()` 中被正確釋放。
   - 檢查大檔案、音訊流及圖片預覽在低記憶體設備上的管理機制。
4. **錯誤處理與容錯（Error Handling）**：
   - 檢查 LLM 串流中斷、網路超時、API 速率限制（Rate Limit 429）等網路異常是否有友善的 UI 回饋，而非無聲卡死。

---

### 階段 5：上架元數據、法律條款與發布就緒確認 (Metadata & Release Readiness)
**目標**：完善所有上架所需的文檔、資產與發布自動化。

1. **第三方開源聲明 (Third-Party Notices)**：
   - 在 App 內「設定/關於」頁面中，建立完整的第三方開源軟體授權清單（符合各開源協議的要求）。
2. **隱私權政策與服務條款**：
   - 撰寫符合雙平台要求的繁體中文/英文隱私權政策（明確聲明資料僅儲存於本地端、API 直接與模型供應商通訊、不收集個人隱私等）。
3. **商店資產（Store Assets）規範**：
   - **Windows Store**：App Icon 尺寸（44x44, 50x50, 150x150, 300x300 等不同 DPI）、宣傳圖、各語言描述與分類。
   - **F-Droid**：準備 Fastlane 元數據結構（`fastlane/metadata/android/<locale>/`），包含 `short_description.txt`, `full_description.txt`, `title.txt` 及螢幕截圖。
4. **F-Droid Metadata Recipe 撰寫準備**：
   - 擬定 `.fdroid.yml` 或 `metadata/<package_id>.yml` 的建置腳本，確保 build flags 與 gradle 參數正確。
