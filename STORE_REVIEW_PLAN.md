# OmniChat 上架審查計畫 (Windows Store & F-Droid Store Review Plan)

本計畫旨在全面審核 OmniChat 專案，確保順利通過 **Windows Store (Microsoft Store)** 與 **F-Droid** 雙平台的上架審查，並修復專案中的潛在缺陷、安全隱患與跨平台相容性問題。

---

## 審查進度總覽 (Review Status Dashboard)

| 階段 | 審查主題 | 狀態 | 核心結果摘要 |
| :--- | :--- | :---: | :--- |
| **Phase 0** | **準備與靜態基線掃描** | ✅ **已完成 (已修復)** | 排除 vendored 範例測試錯誤，靜態分析錯誤歸零 (`0 errors`)；移出 `nuget.exe` 追蹤。 |
| **Phase 1** | **F-Droid 合規性與開源授權專項** | ✅ **已完成 (決策：方案 A 優先，精簡版為備援)** | 識別 Syncfusion 非 FOSS 授權阻礙與 `MANAGE_EXTERNAL_STORAGE` 權限問題；**決策：主版本維持現狀並先以現狀送審（方案 A），僅在送審失敗時另建 F-Droid 精簡版（方案 C 備援）**；**已修復：C-F03（移除 `BLUETOOTH_ADVERTISE`）、W-F01（network security config 公網 HTTPS-only）、W-F02/W-F03（F-Droid Metadata 宣告）**。 |
| **Phase 2** | **Windows Store 規範與 MSIX 專項** | ✅ **審查完成且全部修復（W-C01～W-C05）** | MSIX 已封裝簽章並本機安裝＋**WACK OVERALL PASS**；AI 內容政策 App 內入口已實作；**W-C02 隱私權政策已上線（2026-08-25，GitHub Pages URL 已驗證 200，見下方正確路徑紀錄）**。 |
| **Phase 3** | **深度安全性與 MCP 架構** | ✅ **審查完成且全部結案（C-S01 降級長線；C-S02/C-S04 已修復）** | **C-S01**：per-provider API Key 明文存 SharedPreferences 且隨備份匯出——**不阻塞送審，改採備份加密路線（2026-08-25 決策，見下）**；**C-S02**：✅ **已修復（2026-08-25，DOMPurify 消毒＋mermaid escape＋textContent 錯誤輸出）**；**C-S04**：✅ **已修復（2026-08-25，preview_* 暫存檔切換/關閉時清理）**；MCP JS 沙箱/無 shell spawn 已達標；無硬編碼金鑰。 |
| **Phase 4** | **跨平台穩定性與程式碼品質** | 🔍 **審查完成（P4-F01 已修復）** | 原生插件跨平台隔離調用、Dispose 生命週期、檔案路徑相容性——重點抽查通過，僅 log_viewer 路徑分隔符 bug（已修）。詳見下方 Phase 4 紀錄。 |
| **Phase 5** | **上架元數據與發布就緒確認** | 🔍 **實作完成（P5-1/P5-3/P5-4 已交付；商店資產待手動上傳）** | App 內第三方開源授權聲明已接入（`showLicensePage`，行動+桌面+l10n×4）；Fastlane metadata 已建立（en-US + zh-TW）；F-Droid 建置 recipe 草稿見下方階段 5 紀錄；Windows MSIX tile logo 由 msix 工具自 `logo_path` 自動生成，Partner Center 商店宣傳圖待送審時手動上傳。 |

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
**狀態**：✅ **審查完成（決策定案：方案 A 優先送審，方案 C 精簡版為備援）**

#### 0. 版本策略 (Version Strategy)（2026-08-16 定案；方案 C 為備援）

- **主版本（現行）**：維持現狀，保留全部功能（含 Syncfusion 依賴與自訂 Workspace 目錄），供 Windows Store、一般 APK 與其他管道發佈。
- **F-Droid 送審策略（方案 A 優先）**：**先以現狀送審 F-Droid**，備妥 `MANAGE_EXTERNAL_STORAGE` 權限正當性說明（C-F02 方案 A）；若審查通過，則維持單一版本、無需精簡版。
- **F-Droid 精簡版（方案 C，備援）**：**僅在方案 A 失敗**（F-Droid 拒絕權限正當性，或 Syncfusion 授權被拒）時啟動——另行維護的精簡變體，移除 Syncfusion 依賴與自訂 Workspace 目錄功能（連帶移除 `MANAGE_EXTERNAL_STORAGE`），以符合 F-Droid 全 FOSS 政策。**犧牲少用功能**（PDF 匯出/文字提取、自訂外部 Workspace 目錄）；核心聊天、語音、搜尋、AI Team、MCP 等主要功能不受影響。
- **C-F03 例外**：`BLUETOOTH_ADVERTISE` 為冗餘權限、移除零成本，兩版本皆可直接移除。

#### 1. 核心審查發現：

##### 🔴 阻礙 F-Droid 收錄之關鍵問題 (Critical Issues)：
1. **【C-F01】專有商業授權依賴：Syncfusion (`syncfusion_flutter_*`)**
   - **問題**：`syncfusion_flutter_sliders` 與 `syncfusion_flutter_pdf` 採用 Syncfusion Community License（專有商業授權，非 OSI 認證 FOSS；需註冊且受營收門檻限制）。F-Droid 收錄政策要求應用及其所有依賴皆為 FOSS，含此類依賴將導致收錄審核被拒。
   - **影響範圍與替代方案**：
     - `syncfusion_flutter_sliders`：僅在 2 個檔案（`assistant_settings_edit_page.dart` 與 `display_settings_page.dart`）的 4 處單值滑桿使用（助理參數、字型大小、自動捲動秒數、背景強度）。**可直接平替為 Flutter 原生 Material 3 `Slider` / `SliderTheme`，達成 0 依賴**。
     - `syncfusion_flutter_pdf`：在 `document_text_extractor.dart`（PDF文字提取）與 `markdown_pdf_converter.dart`（Markdown 轉 PDF）使用。**產生部分可替換為 Apache-2.0 開源的 `package:pdf`（`package:pdf/pdf.dart`）；文字提取部分 `package:pdf` 無法勝任，需另以 PDF 讀取套件（如 `pdfx` / `pdfrx`）取代，替換前須先評估其平台支援與授權相容性**。
   - **決策（2026-08-16）**：**主版本維持現狀**，保留 Syncfusion 依賴。Syncfusion 為硬性阻礙（無正當性說明可解），預期送審會被拒——屆時啟動 **F-Droid 精簡版（備援方案 C）**：`syncfusion_flutter_sliders` 以 Flutter 原生 Material 3 `Slider` / `SliderTheme` 平替（4 處設定滑桿，無功能損失），`syncfusion_flutter_pdf` 相關功能（PDF 文字提取、Markdown 轉 PDF）**直接移除**（少用功能）。

##### 🟡 高風險與需處理事項 (High-Risk & Action Items)：
1. **【C-F02】全域儲存權限：`MANAGE_EXTERNAL_STORAGE`（Android 11+ Workspace 功能所需）**
   - **問題與現況分析**：`AndroidManifest.xml:6` 宣告 `MANAGE_EXTERNAL_STORAGE`（All Files Access）。自訂 Workspace 目錄雖透過 `FilePicker.platform.getDirectoryPath()`（系統 SAF `ACTION_OPEN_DOCUMENT_TREE`）選取，但 file_picker 回傳的是 raw filesystem path（如 `/storage/emulated/0/...`），而 Workspace 的檔案操作（`FileToolService`、`WorkspaceFileBrowser`）全部以 dart:io 直接對該 raw path 讀寫。SAF 授權僅涵蓋 content URI，不涵蓋 raw path；在 Android 11+ Scoped Storage 下，未取得 `MANAGE_EXTERNAL_STORAGE` 時此類 raw path 存取會失敗。因此此權限目前為 Workspace 功能的必要條件，非冗餘宣告（`requestLegacyExternalStorage` 僅對 Android 10 有效）。
   - **F-Droid 影響**：F-Droid 會嚴格審查此特殊權限，需以「LLM 檔案工作區管理」功能正當性說明，並於 Metadata 中如實宣告；不必然導致拒收。
   - **修復方案（方案 A 優先；方案 C 為備援）**：
     - **方案 A（優先，保留）**：維持權限與 `permission_handler` 調用（`workspace_settings_dialog.dart:19`、`workspace_sheet.dart:111`），**先以現狀送審 F-Droid**，備妥權限正當性說明；若審查通過即定案。
     - **方案 B（移除，長線目標）**：將 Workspace 檔案操作改寫為 SAF content URI + 持久化 URI 授權（`ContentResolver` 讀寫），涵蓋 `FileToolService` 與 `WorkspaceFileBrowser` 的全部檔案操作，完成後方可自 Manifest 與程式碼移除 `MANAGE_EXTERNAL_STORAGE`。
     - **方案 C（備援，僅在方案 A 失敗時採取）**：若方案 A 送審遭 F-Droid 拒絕（權限正當性不被接受），則於 **F-Droid 精簡版**中移除自訂 Workspace 目錄功能（外部目錄選取，以及 `FileToolService`/`WorkspaceFileBrowser` 對外部 raw path 的讀寫），即可自 Manifest 與程式碼一併移除 `MANAGE_EXTERNAL_STORAGE` 與相關 `permission_handler` 調用。
2. **【C-F03】冗餘的藍牙廣播權限：`BLUETOOTH_ADVERTISE`**：✅ **已修復**
   - **問題**：`AndroidManifest.xml:18` 宣告了 BLE 廣播權限；manifest merger 報告確認此權限僅來自 App 自身 Manifest，無任何 plugin 引入。代碼中語音聊天僅使用 Bluetooth SCO 音訊路由（`MainActivity.kt` 的 `AudioManager` / `startBluetoothSco`），無任何 BLE 廣播或週邊信標用途。
   - **修復方案**：移除 `BLUETOOTH_ADVERTISE`，保留 `BLUETOOTH_CONNECT` 與 `MODIFY_AUDIO_SETTINGS` 即可，符合權限最小化原則。
   - **實作（2026-08-16）**：已自 `AndroidManifest.xml` 移除 `BLUETOOTH_ADVERTISE` 宣告。

##### 🟡 需在 F-Droid 宣告與網路優化項目 (Warnings)：
1. **【W-F01】全域明文傳輸 (`usesCleartextTraffic="true"`)**：✅ **已修復**
   - **實作（2026-08-16）**：新增 `android/app/src/main/res/xml/network_security_config.xml`——`base-config cleartextTrafficPermitted="false"`（公網一律強制 HTTPS），`domain-config` 僅放行 loopback（`localhost`/`127.0.0.1`/`::1`）與模擬器主機（`10.0.2.2`）；Manifest 改為 `usesCleartextTraffic="false"` 並掛接 `networkSecurityConfig`。
   - **已知限制**：Android network security config **不支援 IP 網段/CIDR**（僅主機名與精確 IP），且新版 Flutter 已無 Dart 層 `NetworkSecurityPolicy` 覆寫機制；因此**無法**以平台設定表達「全部 Private IP 網段明文放行」。自架 LAN 端點（Ollama / MCP / 自訂 provider 走 `http://192.168.x.x`）在 Android 上將被擋下，需改用 HTTPS 或於配置中逐筆白名單；本機（localhost）與雲端 HTTPS 場景不受影響。
2. **【W-F02】F-Droid Anti-Features 標籤預期 (`NonFreeNet`)**：✅ **已完成**
   - **實作（2026-08-16）**：建立 `metadata/com.psyche.omnichat.yml`，宣告 `AntiFeatures: [NonFreeNet]` 並於 Description 註明原因（連線雲端商業模型 API）。
3. **【W-F03】`google_fonts` 動態下載字型行為**：✅ **已完成**
   - **實作（2026-08-16）**：於 `metadata/com.psyche.omnichat.yml` Description 說明字型下載行為；已確認預設字型為系統字型（`appFontFamily` 為空 → 系統字型），離線可用；僅使用者主動於字型選單選用 Google Fonts 時才觸發執行期下載。

---

### 階段 2：Windows Store (Microsoft Store) 規範與封裝審查 (Windows Store & Packaging Audit)
**目標**：確保應用程式通過 Windows App Certification Kit (WACK) 與微軟商店政策。
**狀態**：🔍 **審查完成（2026-08-16）——4 項阻礙待修復**

#### 審查發現總覽 (Findings)：

##### 🔴 阻礙上架之關鍵問題 (Critical Issues)：
1. **【W-C01】無 MSIX 封裝（最大阻礙）**
   - **現況**：倉庫內無 `AppxManifest.xml`、無 packaging project、無 `.msix`；目前僅有 Inno Setup 安裝檔（`installer.iss` → `OmniChat_windows_v1.18.3_setup.exe`）。
   - **影響**：Windows Store / Partner Center **只接受 MSIX 套件**，純 EXE 無法上架。
   - **修復方案**：建立 MSIX 封裝（`msix` Dart 套件＋`msix_config`、或 VS Packaging Project、或 MSIX Packaging Tool），以商店發行者憑證簽章；`Package Identity` 的 Publisher 需與 Partner Center 帳戶一致，Version 格式 `x.x.x.0`。
2. **【W-C02】無隱私權政策（微軟商店強制）**
   - **現況**：l10n 有 `aboutPagePrivacyPolicy` key 但**全 lib 未使用**（grep 確認）；About 頁僅 GitHub 與 LICENSE 連結，無隱私權政策。
   - **影響**：微軟商店強制要求 App 內與商店頁面提供**公開且有效**的隱私權政策 URL，缺漏會被拒審。
   - **修復方案**：撰寫雙語（繁中/英文）隱私權政策，放置公開 URL（如 GitHub Pages），About 頁加入連結。
3. **【W-C03】AI 生成內容政策缺口（Store Policy 10.8.4）**
   - **現況**：僅有匯出浮水印 `exportDisclaimerAiGenerated`（「內容由 AI 生成，請仔細甄別」）；**無** App 內 AI 內容免責聲明、**無**敏感內容過濾機制、**無**使用者回報/檢舉管道（l10n 無 report/回報/檢舉字串）。
   - **影響**：Policy 10.8.4 要求 AI 內容揭露＋審核/回報機制，缺漏會被拒審。
   - **修復方案**：新增 AI 內容免責聲明（首次使用/設定頁）、內容回報管道（如 mailto 或 issue tracker 連結）。
4. **【W-C04】WebView2 Runtime 缺失時無降級邏輯**：✅ **已修復**
   - **現況**：`html_preview_dialog.dart` Windows 分支 `await c.initialize()`（WebView2 COM init）**無 try/catch、無降級**；`webview_page.dart`（webview_flutter）controller 建立亦無守衛（僅 load 後操作有 catch）。Linux 有 `htmlPreviewNotSupportedOnLinux` snackbar，Windows 則無對應處理。
   - **影響**：系統缺少 Evergreen WebView2 Runtime 時，HTML 預覽/Mermaid 渲染直接拋錯。
   - **修復方案**：初始化包 try/catch，缺失時提示使用者安裝 WebView2 Runtime（附下載連結）或降級開啟外部瀏覽器。
   - **實作（2026-08-16）**：`html_preview_dialog.dart` 初始化包 try/catch，失敗時顯示錯誤 UI（`webView2NotAvailableTitle/Message`）＋「安裝 WebView2 Runtime」按鈕（官方下載頁）＋「用外部瀏覽器開啟」（暫存檔＋url_launcher）；`webview_page.dart` 載入包 try/catch，失敗時 snackbar 提示並在 URL 模式下自動降級外部瀏覽器。新增 l10n key ×3 × 4 語系。

##### 🟡 高風險與需處理事項 (High-Risk & Action Items)：
1. **【W-C05】Control Flow Guard 未啟用**：✅ **已修復**
   - **現況**：實測已建置 `OmniChat.exe`（build/windows/x64/runner/Release）DLL characteristics = `0x8160`——Dynamic base ✓、High Entropy VA ✓、NX compatible ✓（ASLR/DEP 已達標），但**缺 `0x4000` (GUARD_CF)**。`windows/` 下 CMake 無 `/guard:cf` 設定。
   - **修復方案**：於 `windows/CMakeLists.txt`（或 runner）加入 `/guard:cf` 編譯/連結旗標，重跑 `flutter build windows` 後以 dumpbin 驗證 `0x4000` 出現。
   - **實作（2026-08-16）**：`windows/CMakeLists.txt` `APPLY_STANDARD_SETTINGS` 加入 `/guard:cf`（compile＋link）；重建後 dumpbin 驗證 `DLL characteristics = 0xC160`（含 **Control Flow Guard**）。

##### ✅ 已達標項目 (Passed)：
- **UAC 提權**：`runner.exe.manifest` 無 `<requestedExecutionLevel>` → 預設 asInvoker，無多餘管理員提權 ✓
- **乾淨安裝/移除**：Inno Setup 標準 uninstaller（現行分發）✓
- **桌面原生體驗**：系統匣（`DesktopTrayController`，含 minimize-to-tray）、全域快速鍵（`hotkey_provider`/`hotkey_event_bus`）、視窗生命週期守衛（v1.5.29 `WM_GETOBJECT`/WebView2 守衛）✓
- **版本資訊**：`Runner.rc` 4 段版本（pubspec `1.18.3+93` → FILEVERSION `1,18,3,93`）；MSIX 封裝時需正規化為 `x.x.x.0`
- **未來 AppxManifest Capabilities 規劃**：`internetClient`（網路）、`microphone`（語音聊天）、`runFullTrust`（Win32 桌面應用）——最小權限原則。

##### W-C01 修復方案決策（2026-08-16）：
- **採用 `msix` Dart 套件**（`flutter pub run msix:create`）：不需 Visual Studio、純 CLI 可寫入 build script/CI；設定於 `pubspec.yaml` 的 `msix_config`。VS Packaging Project 僅在需要進階 AppxManifest 功能（多架構 bundle、特殊 extension）時才考慮，目前無此需求。
- **簽章策略**：① 送 Windows Store **不需購買憑證**——Partner Center 收件後以微軟商店憑證重新簽署，提交未簽章或開發憑證簽章的 `.msix` 皆可；② 本機 WACK 測試／側載用**免費自簽憑證**（`New-SelfSignedCertificate` 產生 .pfx，安裝至 Trusted People）；③ 僅商店外發佈（官網下載避免 SmartScreen 警告）才需向 CA 購買（DigiCert/Sectigo 等，約 $100–300/年）。Android 的 `upload-keystore.jks` 與 Windows 無關。
- **執行順序**：產生自簽憑證 → 加 `msix` dev 依賴＋`msix_config` → `flutter build windows --release` → `flutter pub run msix:create` → 本機安裝＋WACK 測試。
- **實作（2026-08-16）**：✅ 完成——`msix:create` 產出 `build/windows/x64/runner/Release/OmniChat.msix`（Identity `com.psyche.omnichat` `1.18.3.0`、Capabilities `internetClient`＋`microphone`＋`runFullTrust`）；自簽憑證（`windows/certs/`，gitignored）以 SignTool 簽章（`AppxSignature.p7x`）；匯入 `LocalMachine\TrustedPeople` 後 `Add-AppxPackage` **本機安裝成功**；WACK（Windows App Certification Kit）**OVERALL_RESULT=PASS**（21 PASS；3 項無訊息 FAIL：App resources／Blocked executables／Archive files usage，為未部署情境之資訊性項目）。注意：此 SDK 版 WACK 參數為 `/apptype`、`/appxPackagePath`、`/reportoutputpath`（包裝腳本 `tool/run_wack.ps1`）；`msix:create` 每次全量重建（>6 分鐘），簽章亦可用同套 SignTool 流程。
- **v1.18.4.0 重打包與 WACK 紀錄（2026-08-26）：✅ OVERALL_RESULT=PASS**（報告 `build/wack_report_20260826_093248.xml`）。版號 bump 至 `1.18.4+94`、`msix_version 1.18.4.0`。**關鍵陷阱紀錄**：① AppxManifest 的 `Publisher` 必須與簽章憑證主體**完全一致**，不符時 SignTool 報 `SignerSign() failed (0x8007000b)`；定案使用既有憑證 `14400D0709E999163C8ADF0DB5FA4D6225226128`（Subject `CN=OmniChat Dev`），Publisher 同步為 `CN=OmniChat Dev`。② `New-SelfSignedCertificate` 新建憑證的私鑰 signtool 存取不到（私鑰篩選失敗），勿再重造。③ `Export-PfxCertificate` 預設 AES 加密的 PFX，SignTool `/f` 直接讀取會失敗——改由憑證存放區以 `/sha1 <thumbprint>` 簽章（`tool/sign_msix.ps1`）。④ WACK 需提權執行，且報告檔名不可重複（已改時間戳）。新流程：`flutter build windows --release` → `flutter pub run msix:create --build-windows false --install-certificate false -p <密碼>` → `tool/sign_msix.ps1` → `tool/install_msix.ps1`（本機安裝）→ 提權跑 `tool/run_wack.ps1`。

##### W-C02 / W-C03 進度（2026-08-16）：
- **W-C02**：✅ **已完成（2026-08-25 結案）**——文稿、About 入口與 Pages 部署皆就緒，四個政策頁面 URL 已驗證 200。
  - **關鍵陷阱紀錄**：Pages 資料夾設定為 `/docs` 時，**網站根路徑直接對應 docs 資料夾內容，URL 不含 `/docs/` 前綴**。原記錄的 `…/OmniChat/docs/privacy_policy_en.html` 是錯誤路徑（自 2026-08-16 起持續 404 的根因）。
  - **正確 URL**：`https://jasonmmiv.github.io/OmniChat/privacy_policy_en.html`（繁中/AI 政策同理：`privacy_policy_zh_TW.html`、`ai_content_policy_en.html`、`ai_content_policy_zh_TW.html`）。商店頁面請填入此 URL。
  - **配套修正**：4 個 `.md` 已加 Jekyll front matter（否則 Jekyll 不會渲染 .md → .html）；`about_pane.dart`／`about_page.dart` 的 App 內連結已改為正確 URL。
- **W-C03**：✅ 文稿已草擬（`docs/ai_content_policy_en.md`、`docs/ai_content_policy_zh_TW.md`，含免責聲明＋回報管道）。✅ **App 內入口已實作（2026-08-16）**：About 頁（行動＋桌面）新增「AI 內容政策」列（`aboutPageAiContentPolicy`）→ 免責聲明對話框＋「開啟 GitHub Issues」回報按鈕（l10n ×4 語系）。

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
**狀態**：🔍 **審查完成（2026-08-16）——C-S02 待修復；C-S01 已降級為長線改善（2026-08-25）**

#### 審查發現總覽 (Findings)：

##### 🟡 長線改善 (Long-term Improvement)：
1. **【C-S01】per-provider API Key 明文儲存且隨備份匯出**
   - **現況**：`ProviderConfig.toJson()` 含 `apiKey`/`apiKeys`（明文）；`setProviderConfig()` 將其序列化寫入 **SharedPreferences**（`provider_configs_v1`）——多數金鑰**非**存於 `flutter_secure_storage`（`LiveApiKeyStore` 僅覆蓋 live key）。備份匯出（`data_sync.dart` `_exportSettingsJson()` → `prefs.snapshot()`）會將**全部 SharedPreferences（含所有 API Key）**打包進備份 ZIP（可上傳 Dropbox/WebDAV）。
   - **影響**：本機明文＋備份洩漏雙重風險；備份雲端同步時金鑰可能外洩。
   - **上架影響評估（2026-08-25）**：Windows Store 與 F-Droid 均**不審查 App 內部金鑰儲存實作**——微軟關注 WACK／隱私權政策 URL／AI 內容揭露；F-Droid 審查 FOSS 授權、權限清單與 Anti-Features。**本項不阻塞雙平台送審**。
   - **決策（2026-08-25）：降級為長線改善，改採「備份加密」兩全解法**
     - 原「遷移至 `flutter_secure_storage`」方案會導致備份不再攜帶金鑰，跨裝置還原後須重新輸入所有 API Key，UX 成本過高，予以否決（副作用詳見《OmniChat 專案開發與維護手冊》§7.3）。
     - 真正風險點是「備份 ZIP 攜明文金鑰上傳 Dropbox/WebDAV」，而非本機明文儲存（root 裝置方可觸及）。解法：於備份匯出加入**選用的密碼加密**（如 AES-GCM，可僅加密 settings JSON 的金鑰欄位或整包 ZIP），還原時輸入一次密碼即可完整攜帶所有金鑰跨裝置遷移。
     - 已確認 `data_sync.dart` 目前無任何加密邏輯，此為新增功能而非改動既有機制；建議做成「設定密碼才加密、不設定維持現狀」的漸進式設計。
2. **【C-S02】mark.html 未消毒 HTML 渲染（XSS）——✅ 已修復（2026-08-25）**
   - **現況（修復前）**：`assets/html/mark.html` 以 markdown-it `html: true` 渲染 LLM 輸出，**無 DOMPurify/消毒**，`innerHTML` 注入；WebView 以 `JavaScriptMode.unrestricted` 執行。LLM 輸出若含 `<script>`/`onerror`（prompt injection 來源），於「以網頁檢視」/桌面 HTML 預覽中會**執行 JS**。
   - **影響**：Prompt Injection → WebView 內 XSS（可向攻擊者伺服器發送請求、讀取頁面內容）。
   - **修復方案**：`mark.html` 引入 DOMPurify（esm.sh）於 `md.render()` 後消毒（保留 mermaid div）；或評估 `html: false`＋白名單。
   - **實作（2026-08-25）**：✅ 完成——`mark.html` 引入 DOMPurify 3.2.4，`md.render()` 後以 `USE_PROFILES: html/svg/mathml` 消毒再注入 `innerHTML`（KaTeX/SVG/task-list 標記保留）；mermaid fence 內容改以 `escapeHtml()` 輸出（mermaid.run 讀 textContent 不受影響）；錯誤訊息改用 `textContent` 注入。所有預覽入口（行動「以網頁檢視」、桌面 `html_preview_dialog`、`webview_page`）皆經此模板，單點修復。

##### 🟡 中低風險 (Medium/Low)：
3. **【C-S03】無 Human-in-the-loop 工具確認**：LLM 呼叫工具（檔案讀寫、刪除）時無 UI 授權確認（僅顯示 tool card）。MCP JS 執行已沙箱化（無網路、fresh runtime、timeout），STDIO spawn 用 `Process.start`（**無 shell**，注入不可行）——緩解因素存在，但高風險檔案操作無明確確認閘門。
4. **【C-S04】暫存檔未清理——✅ 已修復（2026-08-25）**：`html_preview_dialog` 的 `preview_*.html/.xml` 主題切換時改寫前先刪舊檔、dispose 時刪除當前檔；`_openInBrowser` 開外部瀏覽器的暫存檔刻意不追蹤刪除（瀏覽器可能仍在讀取）。既有已累積的舊檔待 OS 清理暫存目錄。

##### ✅ 已達標 (Passed)：
- **MCP JS 沙箱**：fresh runtime、禁用網路 API、QuickJS timeout/memory 限制、preflight 拒絕（v1.5.14）✓
- **無硬編碼金鑰**：grep 未發現測試 Token/開發金鑰/後端憑證 ✓
- **live API Key**：存於 `flutter_secure_storage`（Android Keystore / Windows DPAPI），含舊版明文遷移與清除 ✓
- **無分析/當機回報套件** ✓

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

#### 審查執行紀錄（2026-08-25）：
1. **跨平台邊界防護 (Platform Guarding)**——✅ 通過：
   - 全庫 `Platform.isX` 分支共 149+ 處，桌面/行動 UI 與插件調用均有防護。抽查高風險點皆正確分流：圖片預覽（`image_preview_sheet.dart`）桌面走 `_ImagePreviewDesktopDialog`，`ImageGallerySaverPlus.saveImage` 僅在行動路徑觸發；mermaid 橋接（`mermaid_bridge.dart`）以條件匯入 + Windows/Linux 分流；Android 專屬服務（`android_background.dart`、`notification_service.dart`）入口皆有 `!Platform.isAndroid return` 保護；WebView2 缺失時降級為可讀錯誤 UI（W-C04）。
   - 聽寫 STT 使用專屬 `SpeechToText.withMethodChannel()` 實例（避免 singleton 共用導致 listener 失效），含 `_disposed` 異步防護與靜音看門狗。
2. **檔案系統與路徑相容性**——✅ 通過（1 處修復）：
   - **【P4-F01】已修復**：`log_viewer_page.dart` 三處以 `path.split('/')` 取檔名，Windows 反斜線路徑會整串失敗 → 改用 `p.basename()`（package:path）。
   - 其餘抽查良好：`file_tool_service.dart` / `sandbox_path_resolver.dart` 均先 `p.normalize()` 再 `replaceAll('\\','/')` 且 Windows 比較用大小寫不敏感；備份同步（`data_sync.dart`）zip entry 名稱正規化為 POSIX 斜線並防 `..` 路徑穿越；Dart 字串拼接 `/` 在 Windows 上合法，無風險。
3. **資源釋放與記憶體管理**——✅ 通過：
   - 全庫 dispose/cancel 呼叫 247+ 處；抽查 desktop 關鍵元件均正確釋放：`desktop_home_page._hotkeySub`、`html_preview_dialog`（race-safe init/dispose 旗標，防 WebView2 COM heap race 0xc0000374）、各 popover/dialog 的 controller/timer。已知例外：`desktop_settings_page.dart` 字型載入 loadingTimer 若 fetch 拋錯不 cancel（低風險，timer 觸發僅多關一次 dialog，try-catch 包覆）。
4. **錯誤處理與容錯**——未深入（屬持續性工作）；串流中斷已有 retry/cancel 機制痕跡（`chat_actions.dart` per-conversation stream 管理），建議後續另開專項。

#### 結論：Phase 4 重點抽查通過，P4-F01 已修復。C-S04（preview_* 暫存檔清理）亦已於 2026-08-25 修復（見 Phase 3 紀錄）。

#### 審查清單（原規劃）：

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

#### 實作紀錄（2026-08-25）：
1. **第三方開源聲明——✅ 完成**：行動版 About 頁與桌面版 About Pane 新增「開源授權聲明」列（`aboutPageOpenSourceLicenses`，l10n en/zh/zh_Hans/zh_Hant ×4），調用 Flutter 內建 `showLicensePage()`——自動彙整 pubspec 全部依賴套件的開源授權文本（含 MIT/Apache-2.0/BSD 等），符合各協議的 attribution 要求；AGPL-3.0 本體授權另由既有 License 列指向 repo LICENSE。
2. **隱私權政策雙語——✅ 早已完成**（W-C02/W-C03 結案，GitHub Pages 四頁 200）。
3. **商店多尺寸 Icon——✅ 驗證通過（無需改動）**：Android mipmap 全 DPI 齊全、iOS appiconset 齊全（2026-08 圖標更新）；MSIX 由 `msix` 工具自 `logo_path` 自動生成 Square44x44/Square150x150 等 Visual Assets；**剩餘動作（使用者手動）**：Partner Center 送審時上傳商店宣傳圖（截圖/banner）。
4. **F-Droid Fastlane metadata——✅ 已建立**：`fastlane/metadata/android/{en-US,zh-TW}/`（title.txt / short_description.txt / full_description.txt），內容含 Kelivo fork 出處聲明與 AGPL-3.0 授權說明；螢幕截圖待送審前補拍放入 `fastlane/metadata/android/<locale>/images/`。
5. **F-Droid 建置 recipe 草稿（送審時填入 metadata/<package_id>.yml）**：
   - `Build:`：gradle 專案、`build: flutter build apk --release --flavor`（依實際 flavor 調整）；flutter 版本對齊 pubspec SDK（3.9.x 對應 F-Droid 的 flutter 版本字串需在 srclib 或 build 中指定）。
   - `srclibs`：無需額外 native lib；注意 `speech_to_text_windows`/`permission_handler_windows` 等 vendored dependencies 在 `dependencies/` 目錄（path deps），F-Droid 打包會一併納入原始碼 tarball，需確認授權檔案齊全。
   - Syncfusion 套件為非 FOSS 授權——Phase 1 決策方案 A：先以現狀送審，若被拒則另建精簡版（移除 syncfusion_flutter_sliders/pdf 後重建）。
   - `MANAGE_EXTERNAL_STORAGE` 已於 Phase 1 移除；`BLUETOOTH_ADVERTISE` 已移除。
   - versionCode/versionName 取自 Android gradle，F-Droid 以 CurrentVersionCode 對齊首發版本。

---

#### 原規劃清單：

1. **第三方開源聲明 (Third-Party Notices)**：
   - 在 App 內「設定/關於」頁面中，建立完整的第三方開源軟體授權清單（符合各開源協議的要求）。
2. **隱私權政策與服務條款**：
   - 撰寫符合雙平台要求的繁體中文/英文隱私權政策（明確聲明資料僅儲存於本地端、API 直接與模型供應商通訊、不收集個人隱私等）。
3. **商店資產（Store Assets）規範**：
   - **Windows Store**：App Icon 尺寸（44x44, 50x50, 150x150, 300x300 等不同 DPI）、宣傳圖、各語言描述與分類。
   - **F-Droid**：準備 Fastlane 元數據結構（`fastlane/metadata/android/<locale>/`），包含 `short_description.txt`, `full_description.txt`, `title.txt` 及螢幕截圖。
4. **F-Droid Metadata Recipe 撰寫準備**：
   - 擬定 `.fdroid.yml` 或 `metadata/<package_id>.yml` 的建置腳本，確保 build flags 與 gradle 參數正確。
