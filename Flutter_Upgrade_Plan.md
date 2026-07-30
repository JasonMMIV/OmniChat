# OmniChat × Flutter 3.35.1 → 3.44.7 升級計畫

> 狀態:規劃完成,尚未執行。所有步驟皆可在獨立 commit/PR 內分階段驗收,可回滾。
>
> 目標版本:Flutter 3.44.7(stable 最新,2026-07-10 發布)
> 目前鎖定:Flutter 3.35.1 / Dart 3.9.0(`pubspec.lock:1905-1907` 已實際要求,但 `pubspec.yaml:22` 仍寫 `^3.8.1`)
> 支援平台:Android、iOS、Windows、Linux(macOS、web 目錄存在但非主要維護)

---

## 影響總評

### 會不會影響原功能?

**結論:現有功能基本保留。必須的 Dart 程式碼變更為 0;唯一必改是 1 行 Kotlin gradle 設定。**

真正必須動工(才不會壞):
- `android/settings.gradle.kts:22` 手動套用 `org.jetbrains.kotlin.android 2.1.0` — 3.44/AGP 9 改內建 Kotlin,繼續留著會 build 失敗。**只需刪該行,0 行 Dart 程式碼變更。**
- iOS `UISceneDelegate`(Apple 即將強制)— 因 `ios/Runner/AppDelegate.swift` 已客製 `app.clipboard` 通道,**CLI 不會自動遷移,必須手動**。

會自動視覺改變(不需改碼,但行為變了):
- Android 預設頁面轉場 → `FadeForwardsPageTransitionsBuilder` + Predictive Back(3.38)
- Material 3 tokens 更新(3.41)、Variable font weight 渲染(3.41)

確認不影響功能(0 個 match in `lib/`):
- `OverlayPortal.targetsRootOverlay`、`SemanticsProperties.focusable`、`RawMenuAnchor`、`TextInputConnection.setStyle`、`cacheExtent`、`extends IconData`、`findChildIndexCallback`、`containsSemantics` 全未使用
- **3.38 SnackBar-with-action 不再自動關閉** — 專案用 `AppSnackBar` 自訂管理(`lib/shared/widgets/snackbar.dart`),未走 `SnackBarAction`,不受影響

只是 deprecation 警告(功能照舊):
- `withOpacity` ~1749 處、`MaterialState*` 31 處(已存在)
- 新增:`onReorder` deprecated(15+ 處 `ReorderableListView.builder`),callback 仍可運作
- 未來才會破壞:`WillPopScope` 2 處(`lib/shared/pages/webview_page.dart:126`、`lib/shared/widgets/interactive_drawer.dart:355`)

---

## 更新的好處(對這個專案具體相關)

| 版本 | 對 OmniChat 直接相關 |
|---|---|
| **3.38** | Android Activity **記憶體洩漏修復**(3.29 引入,影響所有 Flutter app)、**16 KB page size + NDK r28**(Google Play 自 2025-11-01 強制,現已釘 NDK 28.2 但引擎也要)、iOS 26 / Xcode 26 完整支援、Predictive Back 預設 |
| **3.41** | **Linux 合併執行緒預設**(穩定/效能)、`platforms:` 資產限定平台(把 `mermaid.min.js` 限定 desktop,mobile bundle 縮小)、iOS `BackdropFilter` **bounded blur 修正**、Material/Cupertino **解耦啟動**、`RepeatingAnimationBuilder`/`Navigator.popUntilWithResult`、Widget Previews 支援 `dart:ffi`(`super_clipboard`/`irondash` 受惠) |
| **3.44** | **Hybrid Composition++**(Android `webview_flutter` HTML 預覽的撕裂/觸控根因修補)、**Swift Package Manager 取代 CocoaPods**(擺脫 Ruby 安裝摩擦,`ios/Podfile` 可淘汰)、**Canonical 成為 Desktop 主任護者**(Linux/Windows embedder 長期受惠)、Windows **stylus input**、桌面 tooltip/popup/dialog 視窗實驗 API(未來可逐步取代部分 `window_manager`/`tray_manager` 自幹碼)、iOS motion accessibility、0×0 環境韌性(一堆元件不再崩)、**Agentic Hot Reload** |
| 通用 | 每個 stable 都補 Skia/Impeller 安全修補、DevTools 效能、`flutter analyze` 改進 |

**最關鍵對應**:OmniChat 是「桌面 + webview 重度」的 LLM 客戶端,HC++、Canonical Desktop 主護、Android 記憶體洩漏、SwiftPM 這四項幾乎是為這個專案 tailor-made;加上 16 KB / iOS 26 是合規底線。

---

## 預先檢查(在做任何變更前先做)

| 檢查 | 動作 | 紅燈處置 |
|---|---|---|
| 環境安裝 3.44.7 | `flutter upgrade` 或安裝 SDK 3.44.7 stable | 鎖進 `.metadata` 並 commit |
| 啟用 Git 分支 | `git switch -c upgrade/flutter-3.44` | — |
| pub.dev 相容性 | 查 `super_clipboard`、`super_native_extensions`、`irondash_engine_context`、`syncfusion_flutter_sliders`、`syncfusion_flutter_pdf`、`mobile_scanner`、`gpt_markdown`、`webview_flutter`、`webview_windows`、`flutter_js`、`speech_to_text` 是否有支援 Flutter 3.44 的最新版 | 任一不相容 → 該階段先停在 3.41 或先 bump 該套件 |
| 電腦端預先安裝 | JDK 17、NDK r28(r28b 已用)、CocoaPods 1.16+、Android SDK API 36 | Flutter 3.38 起強制 Java 17 |
| 製作 `flutter analyze` 與各平台 build 基線 | `flutter analyze 2>&1 > analyze-before.txt`、`flutter build apk --debug` 等 | 升級前已知警告數,升級後可比對 |

---

## Phase A — pubspec.yaml/lock 收斂(獨立可 commit)

1. `pubspec.yaml:22` `sdk: ^3.8.1` → `sdk: ^3.9.0`
   - 實際鎖檔 `pubspec.lock:1905-1907` 已要求 dart ≥3.9.0 / flutter ≥3.35.1,只是 pubspec 寫舊了
2. `flutter pub get` — 重生成 `pubspec.lock`,`sdks:` 段應顯示 3.44.7
3. **不要** 跑 `flutter pub upgrade --major-versions`
   - 會把 `gpt_markdown 1.1.4` 的 highlightBuilder 簽名撞壞,見 `lib/shared/widgets/markdown_with_highlight.dart:310` 的簽名註記
   - 也會把 `mobile_scanner` 跳到 8.x 即破壞性 API 變更
4. commit:`chore: align Dart SDK constraint with lockfile (3.8→3.9)`

---

## Phase B — Flutter 升級實作(由 CLI 主導)

```
flutter upgrade          # 升到 3.44.7
flutter clean
flutter pub get
flutter precache --android --ios --windows --linux
```

- `.metadata:7` revision 會被 CLI 改寫 — commit
- `pubspec.lock` 的 `sdks:` 段會更動 — commit
- `windows/flutter/generated_plugins.cmake`、`linux/flutter/generated_plugin_registrant.cc`、`ios/Flutter/GeneratedPluginRegistrant.*`、`macos/Flutter/GeneratedPluginRegistrant.swift` 會重生成 — commit

**驗收**:`flutter --version` 顯示 3.44.7;`flutter pub get` 無錯誤。

---

## Phase C — Android 建置設定同步(`android/`)

依 Flutter 3.44 推薦的相容集群(AGP 8.11.1 + Gradle 8.14 + KGP 2.2.20 + Java 17)與 built-in Kotlin 遷移指南做決策:

| 檔案:行 | 現況 | 改成 | 理由 |
|---|---|---|---|
| `android/settings.gradle.kts:21` | `com.android.application` version `"8.9.1"` | `"8.11.1"` | 3.38 測試確認的相容版 |
| `android/settings.gradle.kts:22` | `org.jetbrains.kotlin.android` version `"2.1.0"` | 保留但 bump 到 `"2.2.20"` | 3.44 仍允許手動 KGP(向後相容),AGP 9 等獨立 phase 做 |
| `android/gradle/wrapper/gradle-wrapper.properties:5` | `gradle-8.12-all.zip` | `gradle-8.14-all.zip` | AGP 8.11.1 要 Gradle ≥8.13 |
| `android/app/build.gradle.kts:14` | `ndkVersion = "28.2.13676358"` | 保留或改 `flutter.ndkVersion`(取消註解 `:13`) | Flutter 3.38+ 預設 NDK r28,可省去自訂釘 |
| `android/app/build.gradle.kts:16-17` | `JavaVersion.VERSION_11` | `JavaVersion.VERSION_17` | Flutter 3.38 強制 Java 17 最低;AGP 8.11+ 也需要 |
| `android/gradle.properties:3` | `android.enableJetifier=true` | **暫時保留**(沒有依賴需要 jetifier 也可直接刪,先留以保護) | AGP 9 世帶會拔,本輪先穩 |
| `android/app/build.gradle.kts:70-94` | 重複的 `dependencies{}` + `android{lint{}}` 各 2 份 | 刪除重複 `:83-94`,只留 `:70-81` | 順手清理 |

**iOS floor 關聯驗證**:`flutter.minSdkVersion` 在 3.44 = 24,`targetSdkVersion`=36,`compileSdkVersion`=36 — 用 `flutter.*` 變數(`android/app/build.gradle.kts:30-33` 已用),不用改。

**驗收**:`flutter build apk --debug` 成功。

---

## Phase D — iOS Podfile / Podfile.lock / SwiftPM

3.44 起 **Swift Package Manager 是 iOS/macOS 預設依賴管理員**,CLI 自動遷移 Xcode 專案;Polyfill:有套件仍需 CocoaPods 時 CLI 會 fallback 並印警告。

1. `flutter build ios --debug --no-codesign` — 觀察 CLI 是否自動把 `ios/Runner.xcodeproj` 改用 SwiftPM
2. 若所有 iOS plugin 都有 SwiftPM → `ios/Podfile`、`ios/Podfile.lock` 可整個刪除
3. 若有套件(如 `mobile_scanner 7.1.3`、`super_native_extensions 0.9.1`)尚未提供 SwiftPM → CLI 會印警告並 fallback,**保留 Podfile 也安全**
4. 若 SwiftPM 真卡住,`pubspec.yaml` 加 `--enable-swift-package-manager: false` 是合法逃生艙(但 3.44 後終將移除)

**驗收**:`flutter build ios --debug --no-codesign` 成功;`ios/Podfile.lock` 是否新生成或保留取決於套件生態。

---

## Phase E — iOS UIScene 手動遷移(因 AppDelegate 客製,**不能跳過**)

`ios/Runner/AppDelegate.swift` 已自訂 `app.clipboard` 通道 → CLI 不會自動遷移。

按 Apple 的 [UISceneDelegate migration guide](https://docs.flutter.dev/release/breaking-changes/uiscenedelegate) 做:

1. 把 `@main` AppDelegate 的 `UIApplication` lifecycle 重寫成 `UISceneDelegate`(Scene-based) — 主要把視窗/`rootViewController` 邏輯搬進 `SceneDelegate`,AppDelegate 只留 plugin registrant 與通用初始化
2. 將 `app.clipboard` 註冊移到 Scene 流程的相應位置(controller 在 scene 內取得)
3. 新增 `ios/Runner/SceneDelegate.swift`
4. 修改 `ios/Runner/Info.plist` 加入 `UIApplicationSceneManifest`
5. `Podfile:7` `platform :ios, '13.0'`,若 3.44 提高地板則同步調整;`ios/Flutter/AppFrameworkInfo.plist:24` `MinimumOSVersion` 也跟著改
6. 已 bonus 清整:`Podfile:41-53` 的 `PERMISSION_CAMERA=1` post_install 保留(已需要)

**驗收**:在 iOS 17+ 裝置/simulator 啟動正常,`getClipboardImages` 仍有回應。

---

## Phase F — Deprecation 清整(Dart 程式碼,4 個 spot + 2 個 widget)

1. **`WillPopScope` → `PopScope`**(2 處):
   - `lib/shared/pages/webview_page.dart:126`
   - `lib/shared/widgets/interactive_drawer.dart:355`
   - 套用 3.24 的 `PopScope(canPop:, onPopInvokedWithResult:)`(注意 3.38 又改了簽名為 `PopScopeWithResult`)
2. **`useMaterial3: true` 移除**(4 處):
   - `lib/theme/theme_factory.dart:156,221,305,369` — 直接刪該行(Material 3 自 3.16 起為預設)
3. **`withOpacity` → `withValues(alpha:)`**、**`MaterialState*` → `WidgetState*`** — **本輪不做**(1749+31 處,voluminous,警告非錯誤,且專案已 partially migrated 49 處);列入後續增量遷移任務

**驗收**:`flutter analyze` 成功(警告數應比升級前略增,因新增 `onReorder` deprecated);**0 errors**。

---

## Phase G — 既有 bug 順手修(全數確認過,非 Flutter 造成)

| Bug | 位置 | 修法 |
|---|---|---|
| **重複 MainActivity**(app.process_text 已失效) | `android/app/src/main/kotlin/com/psyche/kelivo/MainActivity.kt`(孤兒)、`com/psyche/omnichat/MainActivity.kt`(active) | 把 `app.process_text` 的 `getInitialText`/`onProcessText` 整進 active 的 omnichat `MainActivity`,刪掉 kelivo package 目錄;確認 `AndroidManifest.xml:25` `android:name=".MainActivity"` 仍指向 omnichat |
| 不存在的 analyzer exclude | `analysis_options.yaml:31` `dependencies/flutter_tts/**` | 刪該行(此路徑不存在) |
| macOS-gated channel 確認 | `lib/desktop/macos_window_position.dart:9`(`app.windowPosition`) | 確認所有呼叫點有 `kIsMacOS` / `Platform.isMacOS` gating; 否則在 Windows/Linux 上會 `MissingPluginException` |
| Linux 視窗標題舊名 | `linux/runner/my_application.cc:44,:48` `"kelivo"` | 改 `"OmniChat"`(與其他平台一致) |
| `Jetifier=true` 假依賴檢查 | `android/gradle.properties:3` | 跑 `cd android && ./gradlew :app:dependencies` 並檢查 `androidx` 出現情況;若乾淨直接刪 Jetifier 行 |

**驗收**:`flutter build apk --debug` + `flutter build linux --debug` + `flutter build windows --debug` 全綠。

---

## Phase H — 全平台驗收

1. `flutter analyze`(對照 `analyze-before.txt`,新增的應為 `onReorder`、`CupertinoDynamicColor.withAlpha/withOpacity` 等 deprecated_member_use warnings)
2. `dart fix --dry-run` 可看自動遷移提案
3. `flutter test`(若專案有 widget test;配合 build_runner 跑 `dart run build_runner build --delete-conflicting-outputs` 因 hive_generator)
4. 各平台跑起來手動 smoke test:
   - **Windows**:tray、HTML 預覽(`webview_windows`)、剪貼簿貼圖(`app.clipboard`)、語音輸入(`speech_to_text_windows` — 用 fork)
   - **Android**:`app.process_text` 文字分享、前景服務、WebView HTML 預覽
   - **iOS**:UIScene 啟動、camera 權限、剪貼簿
   - **Linux**:tray(appindicator)、剪貼簿貼圖
5. 看是否需要產 v1.5.33 release;`pubspec.yaml:19` `version: 1.5.32+56` → `1.6.0+57`(升級 major 跳號)

---

## Phase I — 後續可選(本輪不做但記下)

- **AGP 9 + built-in Kotlin 遷移**:等依賴生態確認 super_clipboard/irondash 等都遷完 AGP 9 後,再換 `android/settings.gradle.kts:22` 移除 KGP 行(參見 3.44 `migrate-to-built-in-kotlin` 指南)
- **平台專屬資源**(3.41 `platforms:`):`pubspec.yaml` 的 `assets` 段把 `assets/mermaid.min.js`、`assets/html/mark.html` 標 `[windows, linux, macos]`,mobile bundle 顯著縮小
- **Hybrid Composition++**:opt-in 實驗 `AndroidManifest.xml` 加 `<meta-data android:name="io.flutter.embedding.android.EnableHcpp" android:value="true" />` — 改善 Android WebView/PlatformView 滾動撕裂(直接受惠於 webview 用法)
- **`withOpacity` / `MaterialState*` 全面遷移**(1749+31 處)— 可一次性 PR 用 codemod

---

## 風險卡點總覽

| 卡點 | 影響層級 | 處置策略 |
|---|---|---|
| **`super_clipboard`/`irondash`/`super_native_extensions` 是否支援 3.44** | 阻塞桌面剪貼簿/原生選單 | 必走預先檢查;若卡 → 先停在 phase B 後回 3.41 |
| **`Syncfusion 31.2.x` 大版本跳號** | 商業授權 + widgets API 變化 | 必走預先恢復到 31.2.15;32.x 要重新申請 license;若未改版先觀察 |
| **`gpt_markdown 1.1.4` 簽名硬編** | chat mark 區塊崩 | 強調**不要** `--major-versions` 升 |
| **iOS AppDelegate 客製** | UIScene migration 不可跳 | 已納入 Phase E,不跳過 |
| **C++ `/WX` + `std::codecvt` deprecation** | tray_manager 編譯警告成錯 | 升級後第一次 windows build 必看;真壞掉就改 tray_manager fork CMake 去掉 `/WX` 或改用 C++20 `char8_string` 工具 |

---

## 異動估算

總程式碼異動(不含 generated):
- 1 行 `pubspec.yaml`(SDK 約束)
- 5 行 `android/settings.gradle.kts` / `gradle-wrapper.properties` / `build.gradle.kts`(版本)
- 1 行 `useMaterial3` × 4、`WillPopScope` × 2 處(~10-15 行)
- 1 個新 `SceneDelegate.swift` + 改 `AppDelegate.swift`(~50 行)
- 合併 MainActivity(~30 行重組)
- 刪除 stale `analysis_options` exclude 1 行 + 重複 gradle 區塊 12 行

**核心 Dart 改動 < 100 行**

---

## 本地 fork 套件保留說明

四個本地 patch 套件(tray_manager、mcp_client、permission_handler_windows、speech_to_text_windows)都是行為修補,升級 Flutter **不會讓原版套件取代它們**,必須繼續維護:

- **`tray_manager`** — 自訂 tray popup UX(`dependencies/tray_manager/packages/tray_manager/windows/tray_manager_plugin.cpp:366-369`)、睡眠/喚醒圖示還原(`:245-260`)、subwindow 註冊 guard(`:120-130`)
- **`mcp_client`** — 追蹤上游 1.0.2 並含本地 MCP 功能
- **`permission_handler_windows`** — 避免位置持續被監控(`dependencies/.../permission_handler_windows_plugin.cpp:143-147`),上版仍會建長-lived Geolocator
- **`speech_to_text_windows`** — 修正回傳 JSON 格式不符(`dependencies/.../speech_to_text_windows_plugin.cpp:587-600`)+ lifecycle race safety

唯一 forward-looking 風險:`tray_manager` 用 `std::codecvt_utf8_utf16`(C++17 deprecated, C++26 移除),若未來 Flutter 把 Windows toolchain 推進到 C++20/26 會硬錯;目前 C++17 仍 OK。

---

## 參考文件

- Flutter 3.44 announcement: https://blog.flutter.dev/whats-new-in-flutter-3-44-b0cc1ad3c527
- Flutter 3.41 announcement: https://blog.flutter.dev/whats-new-in-flutter-3-41-302ec140e632
- Flutter 3.38 announcement: https://blog.flutter.dev/whats-new-in-flutter-3-38-3f7b258f7228
- Breaking changes index: https://docs.flutter.dev/release/breaking-changes
- Migrate to built-in Kotlin: https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin/for-app-developers
- UISceneDelegate migration: https://docs.flutter.dev/release/breaking-changes/uiscenedelegate
- Hybrid Composition++: https://docs.flutter.dev/platform-integration/android/platform-views#hcpp
- Swift Package Manager: https://docs.flutter.dev/packages-and-plugins/swift-package-manager/for-app-developers