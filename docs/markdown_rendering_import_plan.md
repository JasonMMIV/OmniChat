# OmniChat Markdown 與內容渲染：kelivo 1.3.2–1.3.4 導入評估與實作計畫

> **文件狀態**：實作中——Phase 0（護欄）與 Phase 1A（P0 穩定性）核心完成；Phase 1B 大部分完成（長圖 tiling／capture freeze、code cache／串流、Markdown 預覽本地化與 per-preview 隔離）；Gate 1 依賴/build spike 技術通過（APK +14.4 MB），剩實機量測、截圖/視覺 QA 與 Gate 2（2026-11-04 進度更新）  
> **日期**：2026-11-04（初版 2026-11-03；最後進度更新 2026-11-04）  
> **適用版本**：OmniChat v1.27.0+  
> **目標平台**：Windows（x64 / ARM64）、Android（arm64-v8a）；macOS / Linux / iOS 非本輪驗收目標  
> **上游基準**：kelivo `v1.3.2`（`b1702b3`）、`v1.3.3`（`12af1d1`）、`v1.3.4`（`4a7da9b`）  
> **相關程式**：`lib/shared/widgets/markdown_with_highlight.dart`（4,475 行）、`lib/shared/widgets/mermaid_bridge_stub.dart`、`lib/features/chat/widgets/message_export_sheet.dart`、`assets/html/mark.html`

---

## 0. 摘要（TL;DR）

### 0.1 一句話結論

**不建議整套移植上游的 `markstream` 渲染引擎。** 本輪應採「**獨立修正先行 + gpt_markdown 現代管線遷移（有硬性 Gate）+ markstream 作為 fallback**」的三段式策略：先用低風險修正拿到大部分使用者可見價值，再以 time-boxed spike 決定是否把渲染器現代化；只有在 modern pipeline 明確失敗時才啟動 markstream 移植。

> **2026-11-04 修訂**：Gate 1 自 Phase 0 後即可獨立 spike（不依賴 Phase 1）；Gate 2 的比較基準改為「Phase 1B 調校後的 legacy」——若 1B 已達 §6.4 目標，modern pipeline 降為可選投資而非必做項。

### 0.2 逐項判定

| # | 上游改動 | OmniChat 現況 | 判定 | 優先級 | 建議做法 |
|:--|:--|:--|:--|:--|:--|
| 1 | 重寫整套 Markdown 引擎（`markstream`） | gpt_markdown 1.3.0 + 4,475 行客製；目前被 `components`/`inlineComponents` 鎖在 legacy regex parser | **不整套導入** | 策略性 | 先現代化 gpt_markdown 1.4.x（plusparse + builders）；markstream 僅作 Gate 失敗後的 fallback |
| 2 | GitHub alerts | legacy 已支援（`ModernBlockQuote` alert card，2026-11-04）；modern `alertBuilder` 待 Gate 2 | **導入** | P1 | modern：`alertBuilder`；legacy fallback 已落地。注意：只升 1.3.4 不會生效 |
| 3 | Directive cards（`:::note`） | 無 | **導入** | P1 | modern：自訂 `MarkdownBlockSyntax` + `MarkdownBlockComponent`；legacy：`DirectiveBlockMd` |
| 4 | 行內 HTML | legacy 已支援安全 inline 子集、基本 block HTML、巢狀 list、div/section 與基本 table（2026-11-04）；table colspan/rowspan、`pre` 高亮仍未做 | **導入（白名單子集）** | P1 | `InlineHtmlMd` + `HtmlBlockMd` + `markdown_html_policy.dart`；禁止任意 HTML |
| 5 | 主題化程式碼高亮 | 固定 GitHub / Atom One Dark；每次 build 重跑 `highlight.parse` | **導入** | P1 | `ColorScheme` token palette + syntax tree LRU 8 MB + plain-text 驗證 |
| 6 | 數學公式 | `flutter_math_fork`；支援 `$`/`$$`/`\(`/`\[`；<code>```math</code> legacy fence 已補（2026-11-04） | **部分導入** | P2 | 公式裁切修正已完成；1.4 下 `val_latex_flutter` 為硬依賴（Latin Modern 字型進 APK，Gate 1 實測），是否改用其 renderer 另定 |
| 7 | 有尺寸上限的 SVG | legacy 已支援 Markdown SVG、inline SVG 與 PlantUML guard（2026-11-04） | **部分導入** | P2 | `SafeSvgImage` + 尺寸/節點/路徑預算；不 fork `vector_graphics_compiler` |
| 8 | Mermaid 改由系統 WebView | **已經是** WebView2 / `webview_flutter`，但為離屏截圖，無 render-complete 契約 | **部分導入（穩定性）** | P0 | 加 `ready`/`rendered`/`error` 協議、requestId、移除 900 ms timeout、單次重試 |
| 9 | 區塊公式不再被裁切 | `LatexBlockScrollableMd` 的垂直 padding 在 scroll viewport 外 | **導入** | P0 | 把 padding 移到 scroll clip 內；加 pixel/golden test |
| 10 | 表格與文字在自訂背景可讀 | 表格/details 已有不透明底（`cs.surface`/`alphaBlend`）；真正暴露面＝frosted 氣泡 66% 透明與 assistant 無氣泡的**正文** | **導入（範圍縮小）** | P0 | `MarkdownSurfaceScope` + frosted／無氣泡正文對比；「default assistant + wallpaper 改不透明 block 底」另案 product sign-off |
| 11 | 長圖匯出完整精度 + 預覽加速 | 單張 `RepaintBoundary.toImage(pixelRatio: 3)`；長圖會撞 GPU texture 上限 | **導入** | P0 | 分塊 capture + 拼接 + 縮圖預覽 + 進度/取消 |
| 12 | 串流、長訊息、Markdown 預覽加速 | 60 ms throttle；`preprocessFences` 每 tick 約 14 次全字串掃描；預覽依賴 CDN | **導入** | P0/P1 | 預處理 memoization/串流 fast path、code cache、modern pipeline、預覽資產本地化 |

### 0.3 對應使用者原始四點

| 上游 bullet | 本文件章節 |
|:--|:--|
| 1. 重寫 Markdown 引擎：alerts、directive、inline HTML、主題高亮、數學、bounded SVG | §3.1–§3.7 |
| 2. Mermaid 改系統 WebView、區塊公式不裁切、表格/文字在自訂背景可讀 | §3.8–§3.10 |
| 3. 長圖完整精度 + 預覽加速 | §3.11 |
| 4. 串流、長訊息、Markdown 預覽加速 | §3.12 |

> 補充：`MarkdownWithCodeHighlight` 也用於 user message（`enableUserMarkdown` 開啟時）與 AI Team proposals；alerts/directives/HTML 會一併出現在這些位置。**這是產品決策，不是 QA 附註**——使用者自己貼未閉合的 `:::` 或 `> [!NOTE]` 會在自己的氣泡觸發卡片渲染。Phase 4 必須明確決策（建議預設：user 輸入關閉 alerts/directives，HTML 只讀渲染；AI Team 由產品另定）。

### 0.4 為什麼不是「直接搬 markstream」？

1. **成本與風險不對稱**：markstream 是 AST + incremental + selection + Flutter renderer 的完整替換；OmniChat 目前有 4,475 行客製 UI（code block、table toolbar/CSV、Mermaid bitmap overlay、PlantUML、details、citation、export capture、AI Team proposals）。整包替換是 6–10 週等級的專案，且會把 Windows `SelectionArea`/WebView2 的既有避坑全部重驗一次。
2. **四個 bullet 不需要整包替換**：alerts/directives/HTML/SVG/主題高亮/公式裁切/背景對比/長圖/串流，都可以在現有架構上分項達成；其中串流的根本解是「**離開 legacy regex pipeline**」與「**增量預處理**」，不是非得換套件。
3. **上游 markstream 沒有獨立 LICENSE**：它位於 kelivo 根目錄的 AGPL-3.0 之下。OmniChat 也是 AGPL-3.0，法律上可移植，但需保留 notices、標註 upstream commit、提供對應源碼；真正的成本是長期維護一個 vendored fork。
4. **gpt_markdown 1.4.0 已經補上大量上游能力**：GitHub alerts（1.3.1+）、HTML allowlist、SVG、sup/sub/highlight、CommonMark 0.31.2、incremental plusparse。若能在不破壞客製 UI 的前提下遷移，會比自研或整包 fork 更划算。

### 0.5 實作進度（2026-11-04）

| 階段 | 狀態 | 說明 |
|:--|:--|:--|
| Phase 0 護欄 | 🟡 大部分完成 | fixture corpus、env-guarded benchmark、`flutter analyze`／回歸測試已綠；Windows/Android 實機 baseline 與 `markdown_pipeline_v1` flag 尚未做 |
| Phase 1A P0 穩定性 | 🟢 核心完成 | Mermaid render-complete/strict/negative cache、公式裁切、`MarkdownSurfaceScope`（聊天氣泡 + AI Team + export）已落地；4 背景 × 3 氣泡對比矩陣已自動化（`markdown_surface_contrast_test`，24 組），截圖/實機 smoke 待補 |
| Phase 1B P0 匯出／串流 | 🟢 大部分完成 | 長圖 tiling + 進度／取消 + 縮圖預覽 + runtime flag、code palette/cache、串流 fast path／code deferral、Markdown 預覽本地化已完成（local classic vendor + per-preview `preview_*` 子目錄 + `loadFile`）；長圖 freeze／遠端圖片 settle 已補，記憶體量測與實機 smoke 待補 |
| Phase 2–5 | 🟡 部分開始 | GitHub alerts、directives、inline HTML 子集、Markdown／inline SVG 與 PlantUML guard legacy fallback 已落地；Gate 1 依賴/build spike 已完成（技術通過、APK +14.4 MB），Gate 2 與長訊息硬化未開始 |

**本輪落地（2026-11-04）**

- `lib/shared/markdown/markdown_surface_scope.dart`、`markdown_math.dart`、`markdown_code_cache.dart`、`markdown_code_palette.dart`、`markdown_alert.dart`、`markdown_alert_style.dart`、`markdown_directive.dart`、`markdown_html_policy.dart`。
- `lib/shared/widgets/markdown_callout_card.dart`、`markdown_directive_block.dart`、`inline_html_md.dart`、`safe_svg_image.dart`。
- `lib/shared/widgets/long_image_exporter.dart`、`mermaid_failure_cache.dart`。
- `markdown_with_highlight.dart`：SurfaceScope ink/shadow、共用 `ScrollableBlockMath`、single-layer Mermaid capture、syntax-tree cache、palette、`preprocessCached`、串流 fast path、code block deferral。
- `chat_message_widget.dart`：氣泡提供 `MarkdownSurfaceScope`；`ai_team_proposals_section.dart` 與 `message_export_sheet.dart` 也已顯式接入。
- `html_preview_page.dart`：loading indicator、10 s timeout、失敗訊息與 retry（`MarkdownSurfaceScope` 之外的 UX 收尾）。
- `mermaid_bridge_stub.dart`：`ready`/`rendered`/`error`、export `requestId`、`securityLevel: strict`、timeout 收斂。
- `message_export_sheet.dart`／`image_preview_sheet.dart`：tiling、進度／取消、縮圖預覽、runtime flag；移除 `_renderAndSavePagedOld` 與 `_shareAnchorRect`。
- 長圖 capture：`TickerMode(false)`、固定 `SettingsProvider`／`Theme`／`MediaQuery` 快照、每 tile `ImageCache` pending 等待（防接縫／空白圖）。
- `lib/utils/markdown_preview_assets.dart`、`assets/html/vendor/**`、`mark.html`：本地 classic vendor（markdown-it/KaTeX/highlight.js/DOMPurify/js-base64/Mermaid）、temp 解壓、每個 Markdown 預覽獨立 `preview_*/index.html` + `<base href="../">`；預覽頁改用 `loadFile`。
- 設定：`long_image_tiling_v1`（device-local、`_localOnlyKeys`、Display → Rendering 開關、4 語系）。

**2026-11-04 追加**

- 長圖：`picture.toImage` 後立即 dispose tiles，降低 encode 峰值；single-shot fallback 的 `ui.Image` 也在 finally dispose。
- GitHub alerts / directives legacy：`markdown_alert.dart`、`markdown_alert_style.dart`、`markdown_directive.dart`、共用 `MarkdownCalloutCard`；五類型 + danger、custom title、四語系標題、標題 4.5:1 對比矩陣、alert/directive list fixture、串流未閉合 partial。
- Math fence：<code>```math</code>/`latex` 走共用 `ScrollableBlockMath`；串流中 defer、math 關閉 fallback code、解析失敗（含 `$$`/`\[...\]`）同步 fallback code block；`math.md` fixture 與 `markdown_math_clipping_test` 覆蓋。
- Inline HTML：`InlineHtmlMd` 安全子集（b/i/u/s/mark/code/kbd/sub/sup/span/font/br）、`HtmlBlockMd`（p/ul/ol/li/blockquote/pre/hr）、`DangerousHtmlMd` 丟棄主動內容、`<a>` scheme allowlist；`inline_html.md`、`block_html.md` fixture 與 `markdown_html_policy_test` 覆蓋。
- SVG：`SafeSvgImage` 支援 Markdown `![](x.svg)` 與 PlantUML；行內 `<svg>` 由 `InlineSvgMd` + `SafeSvgText` 共用 pre-scan；Markdown 512 KB、PlantUML 2 MB/10 秒、SSRF redirect、async local file、root/viewBox 4096、element/path/depth budget、active/external-reference pre-scan；`safe_svg_image_test` 7 項、`safe_svg_text_test` 4 項、`svg_parse_guard_test` 1 項、`plantuml_tabs_test` 6 項；`inline_svg.md` fixture 全綠。
- 測試：alert/directive/contrast/fixtures 批次全綠、Markdown 廣域回歸 **74 項全綠**（含 inline SVG + currentColor、block HTML、SVG parse timeout、PlantUML 404/超大/非 SVG）。

**驗證**

- `flutter analyze lib`：0 errors。
- Markdown/Mermaid/PlantUML/details/export/settings 相關批次：33、69、23、19 項測試全綠（批次間有重疊）；Preview/Markdown 最終批次 84 項全綠。
- 新增測試：`markdown_math_clipping_test`、`markdown_surface_scope_test`、`markdown_surface_contrast_test`、`markdown_alert_test`、`markdown_directive_test`、`markdown_html_policy_test`、`mermaid_capture_policy_test`、`markdown_code_cache_test`、`markdown_code_palette_test`、`markdown_preprocessor_streaming_test`、`code_block_streaming_defer_test`、`long_image_export_plan_test`、`mermaid_failure_cache_test`、`markdown_fixtures_smoke_test`、`settings_provider_long_image_tiling_test`、`markdown_preview_assets_test`、`safe_svg_image_test`、`safe_svg_text_test`、`svg_parse_guard_test`；fixture 新增 `inline_svg.md`、`block_html.md`。
- Markdown 預覽：`mark.html` 已無 CDN/ES module；Chrome `file://` smoke（`preview_*/index.html` + `<base href="../">`）14/14 資源 200、零 console error，表格／KaTeX（含 display math）／code／task list／Mermaid SVG 全部渲染；KaTeX plugin 以 external 方式打包（6.3 KB，避免重複 ~270 KB）。

**刻意延後**

- `markdown_pipeline_v1`／Gate 2：modern pipeline 尚未開始，flag 先不建立空殼；Gate 1 只驗證依賴與 build。
- 4 背景 × 3 氣泡截圖/實機視覺 QA、Windows/Android 實機 smoke。
- 長圖記憶體總帳與 release 實機 baseline。

---

## 1. 上游 1.3.2–1.3.4 到底改了什麼

### 1.1 版本對照

| 版本 | 日期 | 渲染相關內容 | 備註 |
|:--|:--|:--|:--|
| **v1.3.2** | 2026-10-26 | 以自研 `markstream` 0.1.0 取代 vendored `gpt_markdown` 1.1.7；GitHub alerts、directive cards、inline HTML、主題化高亮、數學、bounded SVG；長圖匯出精度/預覽；串流與長訊息效能 | 渲染改動主體 |
| **v1.3.3** | 2026-11-02 | Mermaid 改由系統 WebView；區塊公式 glyph 裁切修正；自訂聊天背景上的表格/文字對比；可選 legacy inline code 樣式；長會話工具卡效能 | 渲染修正 |
| **v1.3.4** | 2026-11-02 | **沒有渲染改動**；訊息儲存/AOT crash、Android 選取選單、iOS Live Activity、語音提示色 | 不要把它算進渲染範圍 |

> 上游沒有 `CHANGELOG.md`（v1.3.2–v1.3.4 的 raw 路徑為 404），Release Notes 是唯一正式變更紀錄。

### 1.2 關鍵 commit / 檔案

| Commit | 內容 | 對 OmniChat 的意義 |
|:--|:--|:--|
| `60b886b` | 移除 `gpt_markdown` 與舊渲染管線，全部改用 markstream | 上游是整包替換，不是漸進修補 |
| `f72c06c` / `c088f60` | alerts + directive cards；alert 自訂標題、bounded SVG、`==highlight==` | 功能語義可借鏡 |
| `3bf2d9e` | inline HTML 子集（native text/adapters） | 可作為白名單規格 |
| `039af88` | 每個 formula widget 自持 parse tree，移除全域 cache | flutter_math_fork 的 tree 會持有 widget/GlobalKey |
| `2df8153` | 把 `theme.mathPadding` 移到水平 scroll clip 內 | 公式裁切修正的直接依據 |
| `257aca7` | Mermaid native WebView；移除 Dart 端 900 ms export timeout | 與 OmniChat 現行 `_captureMermaidBitmap` 高度相關 |
| `b5dd009` | `proseInk` / `blockContentTheme`；表格 cell 用 block 自己的 ink | 自訂背景對比的設計參考 |
| `b9d54cb` | 長圖保留 PNG bit depth/alpha、copy byte rows、mount once、reuse capture tiles | 長圖分塊/預覽的設計參考 |
| `4eef28a` | `MARKSTREAM_RENDER` 效能 benchmark；50 ms coalescing timer | 效能驗收方式可借鏡 |

### 1.3 markstream 架構摘要（僅作為 fallback 參考）

- `dependencies/markstream`，`version: 0.1.0`、`publish_to: none`，只依賴 `lucide_icons_flutter`。
- 核心 `lib/src/core`：immutable AST、block/inline parser、`ParserOptions.llm()` / `commonMark()` / `gfm()`、`IncrementalDocument`（完成的 leading blocks 保持 identity，只重 parse 開放的 container）、`MarkdownStructure` 非渲染掃描、`toPlainText`/`toMarkdown`/`toHtml`/`tableToCsv`。
- Flutter 層：`MarkstreamView`、`MarkstreamTheme.fromColorScheme`、`MarkstreamExtensions`（code/directive/named-inline builders）、`CodeHighlighter`、`MathRenderer`、`ImageBuilder`、`LinkHandler`。
- 上游 app 入口：`lib/shared/markdown/markdown_with_code_highlight.dart`，以 `options`/`theme`/`extensions`/`codeHighlighter`/`mathRenderer` 組裝。
- 測試規模：上游宣稱 root 8k+ tests、markstream 約 296 tests、389 golden checks（commit message 數字，未獨立重跑）。

---

## 2. OmniChat 現況盤點

> 以下為 2026-11-03 的**實作前**盤點。2026-11-04 已落地的差異見 §0.5 與 Phase 1A/1B；尚未完成的項目（modern pipeline、實機量測等）也在該處如實標明。

### 2.1 渲染入口與客製元件

唯一入口：`lib/shared/widgets/markdown_with_highlight.dart` 的 `MarkdownWithCodeHighlight`（4,475 行）。

目前傳入 `GptMarkdown` 的方式：

```dart
final components = List<MarkdownComponent>.from(
  MarkdownComponent.globalComponents,
);
// ... insert SoftHrLine / ModernBlockQuote / ModernCheckBoxMd / ...
final inlineComponents = List<MarkdownComponent>.from(
  MarkdownComponent.inlineComponents,
);
// ... insert HtmlAnchorMd / LineSafeLinkMd / ...
```

**關鍵事實**：gpt_markdown 1.3.x 的 `MIGRATION.md` 明確指出，只要傳入 `components` 或 `inlineComponents`（即使是空 list），整個 widget 就會切到 **legacy regex parser**，忽略 `blockComponents`，也沒有 plusparse 的 incremental segment cache、span-level reveal、lazy sliver。OmniChat 目前正是這條路徑。

這造成兩個直接後果：

1. **GitHub alerts 不會生效**：alerts 是 plusparse 的 `MdBlockQuote.alert` 功能；legacy 路徑的 `ModernBlockQuote` 會先攔截引言。**（2026-11-04 已以 legacy fallback 繞過：`ModernBlockQuote` 先分流 alert。）**
2. **串流效能無法只靠升級套件解決**：legacy parser 每個 chunk 重 parse；`preprocessFences` 又額外做十幾次全字串掃描。

### 2.2 主要客製元件

| 元件 | 行數/位置 | 作用 | 現代管線替代 |
|:--|:--|:--|:--|
| `SoftHrLine` | 2,927 | 柔和分隔線 | `hrBuilder` |
| `EscapeAwareTableMd` | 3,390 | 表格 cell 的 `\|`/math 分割 | built-in table + `tableBuilder` |
| `FencedCodeBlockMd` | 3,538 | fenced code 優先權、Mermaid/PlantUML 分流、串流時延後 WebView | built-in fence + `codeBuilder` / `blockComponents` |
| `LatexBlockScrollableMd` | 3,574 | 區塊公式水平捲動 | `blockLatexBuilder` + `LatexStyle` |
| `InlineLatexScrollableMd` / `Dollar` / `Paren` | 3,614 / 3,658 / 3,724 | 行內公式 | `inlineLatexBuilder` |
| `DetailsHtmlMd` | 3,770 | `<details>/<summary>`（深度 6） | gpt_markdown 1.4 HTML 子集；或保留 |
| `HtmlAnchorMd` | 3,968 | `<a href>` | built-in HTML |
| `AtxHeadingMd` / `SetextHeadingMd` | 4,005 / 4,118 | 標題樣式 | built-in + `headingBuilder` |
| `LabelValueLineMd` | 4,151 | 已停用 | 刪除 |
| `ModernBlockQuote` | 4,210 | 引言卡片 | `blockQuoteBuilder` |
| `ModernCheckBoxMd` / `ModernRadioMd` | 4,269 / 4,329 | 工作清單/選項 | built-in + builders |
| `LineSafeLinkMd` | 4,394 | 行內連結 | built-in link（1.3+ 改為 TextSpan） |
| `BackslashEscapeMd` | 4,405 | 反斜線轉義 | built-in CommonMark |

### 2.3 Mermaid / PlantUML

- `mermaid_bridge_stub.dart`：Windows 用 `webview_windows`，Android/iOS 用 `webview_flutter`；**離屏 Overlay + PNG 截圖**，不是 inline WebView。
- `_MermaidBlockState`：
  - 220 ms `_settledBitmapRenderDelay` debounce。
  - 插入 overlay 後等 120 ms，再以 **900 ms timeout × 4 次**呼叫 `exportPngBytes()`（bridge 內另有 8 s 隱性 timeout——兩層 timeout 疊加，見 §3.8 收斂）。
  - 固定預覽高度 406 px。
  - HTML 只回傳 `height` 與 `export`，**沒有 `rendered`/`error` 事件**。
- `PlantUMLBlock`：2026-11-04 前為 `SvgPicture.network` 直載（無大小/節點/時間上限）；現已改走 `SafeSvgImage`（2 MB、10 秒、SSRF、結構 pre-scan）。

### 2.4 數學

- `_renderMath` 直接呼叫 `flutter_math_fork` 的 `Math.tex`。
- `LatexBlockScrollableMd` 的結構是：

```dart
Padding(                      // 垂直 padding 在 scroll viewport 外
  padding: EdgeInsets.symmetric(vertical: 4),
  child: LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      scrollDirection: Axis.horizontal,   // viewport 會 clip
      child: ConstrainedBox(
        constraints: BoxConstraints(minWidth: constraints.maxWidth),
        child: Center(child: math),
      ),
    ),
  ),
)
```

TeX glyph 可能畫出 layout bounds；`SingleChildScrollView` 的 viewport 會把上下呼吸空間裁掉。上游 `2df8153` 正是把 padding 移到 clip 內。

### 2.5 程式碼高亮

- `SelectableHighlightView` 每次 build 都執行 `highlight.parse(source, language: language)`，再把 `Node` 轉成 `TextSpan`。
- 主題固定：`isDark ? atomOneDarkReasonableTheme : githubTheme`，再將 `root` 背景改成透明。
- 沒有語法樹快取、沒有主題 token 映射、沒有 wallpaper/frosted 的對比變體。
- 長 code block 在 streaming 期間每個 chunk 都重 parse，是僅次於 `preprocessFences` 的熱點。

### 2.6 表格與聊天背景

- `_buildBubbleContainer` 支援三種樣式：
  - `defaultStyle`：user 有淡色氣泡；**assistant 沒有氣泡**。
  - `frosted`：`white/0xFF1C1C1E` + 66% opacity + `BackdropFilter`。
  - `solid`：白/`0xFF1C1C1E`。
- 每個 assistant 可有自己的背景圖（`Assistant.background`），上面有黑色漸層遮罩（`chatBackgroundMaskStrength`）。
- 表格：`_wrapTableWithToolbar` 把整張表包進 `Container(color: cs.surface)`（不透明圓角容器）；header 另有 `Color.alphaBlend(primary, cs.surface)`。**表格不是透明的**——存在的問題是「不透明色塊在自訂背景上突兀」的外觀問題，不是可讀性問題。
- `<details>` 區塊與 code block 同樣以 `alphaBlend(…, cs.surface)` 得到不透明底。
- 真正暴露面只剩兩處：`frosted` 氣泡（66% 透明）上的**正文**、`defaultStyle` assistant（無氣泡）+ 背景圖上的**正文**——`cs.onSurface` 與背景圖的對比沒有保證。

### 2.7 長圖匯出

`message_export_sheet.dart` 的 `_renderWidgetDirectly`：

1. 把 `ExportCaptureScope(enabled: true)` 的內容放進 `OverlayEntry`，位置 `(-10000, -10000)`。
2. 等 3 個 frame + 500 ms。
3. 對整個 `RepaintBoundary` 呼叫一次 `boundary.toImage(pixelRatio: 3.0)`（桌面 2.0）。
4. `image.toByteData(format: png)` → 暫存檔 → 預覽。

問題：

- 寬 480 × 3 = 1,440 px。Android 常見 max texture 4,096 / 8,192，對應 logical 高度上限約 **1,365 / 2,730 px**（不是 2,700/5,400）；更長的訊息就可能失敗或得到空白。
- 桌面寬 720 × pixelRatio 2 = 1,440 px；max texture 16,384 對應 logical 高度上限 **8,192 px**（不是 5,460）；長對話同樣會撞牆。
- 預覽直接解碼整張 PNG；`1,440 × 30,000` RGBA 約 173 MB，Android 容易 OOM。
- 舊的 `_renderAndSavePagedOld` 有分頁概念，但沒有被使用，且以 `jumpTo` + 固定延遲實作，精度/接縫不可靠。

### 2.8 串流與預覽

- `StreamController._streamThrottleInterval = 60 ms`，透過 `StreamingContentNotifier` 只重建單一訊息，這部分是好的。
- 但每個 tick 仍會重建 `GptMarkdown`，而 `preprocessFences` 每次做：
  1. `\r\n` 正規化
  2. link title 移除
  3. `$` in code 遮罩
  4. inline dollar scanner
  5. display math 正規化
  6. bullet fence
  7. opening fence dedent
  8. closing fence dedent
  9. inline closing fence
  10. setext/HR heuristic
  11. heading enumeration
  12. unmatched fence count
  13. trailing-link split/join
  14. `_sanitizeImageLinks` / `_extractImageUrls`（在 build 內）
- 60 ms → 每秒約 16 次全訊息掃描；訊息越長越慢，Android 尤其明顯。
- Markdown 預覽 `assets/html/mark.html` 從 `esm.sh` / `jsdelivr` 載入 markdown-it、KaTeX、highlight.js、mermaid、DOMPurify；離線或網路慢時會白屏/延遲，且每次都重新載入。

### 2.9 現有測試

與渲染直接相關：

- `test/markdown_latex_code_mask_test.dart`
- `test/markdown_table_toolbar_test.dart`
- `test/mermaid_bitmap_tabs_test.dart`
- `test/plantuml_tabs_test.dart`
- `test/details_summary_html_test.dart`
- `test/code_block_state_retention_test.dart`
- `test/markdown_media_sanitizer_test.dart`
- `test/inline_math_boundary_test.dart`

缺口：alerts/directives/HTML/SVG/背景對比/公式裁切/長圖/串流效能的回歸測試。

---

## 3. 逐項評估

### 3.1 重寫整套 Markdown 渲染引擎（markstream）

**上游做法**：以 AST + incremental parser + Flutter renderer 的 markstream 取代 gpt_markdown，並把 alerts、directives、HTML、code、table、math、details、selection 全部收進同一套 theme/extension。

**OmniChat 現況**：gpt_markdown 1.3.0 + 4,475 行客製、17 個 `BlockMd`/`InlineMd` 客製類；legacy regex pipeline；大量客製 UI 與平台 workaround。

**判定：不整套導入（本輪）。**

理由：

- 這是 renderer 替換，不是功能移植；會影響所有訊息、AI Team proposals、export、selection、copy、Mermaid 延後策略。
- Windows 的 `SelectionArea` 禁令與 WebView2 COM race 需要重驗；markstream 不會自動解決。
- 上游 markstream 是 internal package，沒有 pub 版本；vendored fork 需長期同步。
- 本輪的四個 bullet 可以在不換引擎的情況下達成 80% 以上。

**替代方案比較**：

| 方案 | 內容 | 優點 | 缺點 | 粗估 |
|:--|:--|:--|:--|:--|
| A. 全量移植 markstream | vendored `dependencies/markstream` + 改寫入口/adapters | 與上游長期對齊；AST/incremental/selection 一次到位 | 6–10 週；高回歸風險；Windows 重驗；fork 維護 | 30–50 人日 |
| **B. 現代化 gpt_markdown（建議）** | 升 1.4.x；移除 `components`/`inlineComponents`；改用 `blockComponents`/builders/plusparse | 2–3 週；取得 incremental、alerts、HTML、SVG；保留現有 UI 資產 | custom builder parity 需逐項驗證；1.4 行為變更 | 12–18 人日 |
| C. 留在 legacy + 手工補功能 | 自建 alerts/directives/HTML/SVG/cache | 風險最低；可立即 ship | 無 incremental；技術債累積；串流仍受限 | 20–30 人日（含 P0） |

**建議**：先做 C 的 P0 獨立修正，再執行 B 的 Gate 1/Gate 2。若 B 失敗，才轉 A。

**啟動 A 的硬性條件**（任一成立）：

- B 的 Gate 2 中，>5% fixture 有無法在 2 天內修好的視覺/行為差異。
- Windows 串流選取崩潰或 WebView 重建無法保住。
- `material_ui` 與現有 Flutter/Material 型別/build 無法解決。
- 50 KB 訊息 p95 build time 相對 **1B 調校後的 legacy** 改善 < 15%（現代管線的邊際增益不足）。
- 需要 markstream 的 source-offset selection / 精確 partial inline 才能滿足需求。

### 3.2 GitHub alerts

**上游做法**：`> [!NOTE]`、`[!TIP]`、`[!IMPORTANT]`、`[!WARNING]`、`[!CAUTION]`；可自訂標題；`alertBuilder` / `AlertStyle`；directive 與 alert 共用卡片。

**OmniChat 現況（2026-11-04）**：`ModernBlockQuote` 是自訂 `InlineMd`，原先會把整個 `>` 區塊當普通引言；現已在同一 renderer 內先呼叫 `parseMarkdownAlert`，五種類型、custom title、body 都走 alert card，標題以 `SelectionContainer.disabled` 排除在 SelectCopy 之外。

**判定：導入（P1）。**

**重要陷阱**：只把 gpt_markdown 升到 1.3.4 **不會**讓 alerts 生效。原因：

- alerts 在 plusparse 的 `MdBlockQuote.alert`。
- OmniChat 仍傳 `components`/`inlineComponents` → legacy parser。
- `ModernBlockQuote` 會先匹配引言。

因此有兩條路：

1. **Modern pipeline（建議）**：移除 `components`/`inlineComponents`，註冊 `alertBuilder`，用 `AlertBuildDetails` 的 `title`/`content`/`type` 畫 OmniChat 卡片。
2. **Legacy fallback（已落地）**：`lib/shared/markdown/markdown_alert.dart` 的 `parseMarkdownAlert` 負責 marker/custom title/body；`ModernBlockQuote` 在一般引言判斷前先分流成 alert card，內部再走 `MarkdownComponent.generate`。不需額外 `AlertBlockMd` 註冊順序。

**UI 規格**：

- 左側 3 px accent bar；底色為 accent 的 8–12% tint；圓角 12；icon + 標題 + 內容。
- 五種類型（2026-11-04 實作）：Note（`Lucide.Info` / primary）、Tip（`Lucide.Lightbulb` / tertiary）、Important（`Lucide.BadgeInfo` / secondary）、Warning（`Lucide.TriangleAlert` / tertiary-error blend）、Caution（`Lucide.OctagonAlert` / error）；標題色再向 `onSurface` 混合 55% 確保對比。
- 標題預設本地化；`title="..."` 覆寫。
- 串流中 marker 未完整時，先按一般引言渲染；marker 完成後切卡，不要閃爍。
- 複製 Markdown 時保留 `[!TYPE]` marker（與上游 `to_markdown` 一致）。

**測試**：

- 五種類型、大小寫、`[!NOTE] custom title`。
- 引言內含清單/程式碼/表格/巢狀引言。
- 串流中 marker 分段抵達。
- 複製/匯出保留 marker。
- l10n ×4。

### 3.3 Directive cards

**上游做法**：`:::note` / `:::tip` / `:::warning` / `:::danger` 葉節點與容器；`title="..."`；未知 directive 保留 children 但不畫卡；未閉合在串流中顯示 partial。

**OmniChat 現況（2026-11-04）**：legacy fallback 已落地：`markdown_directive.dart` 解析 `:::type title="..."`，`DirectiveBlockMd` 使用共用 `MarkdownCalloutCard`；五種名稱 + `danger`、未知 directive 保留 children、未閉合顯示 partial（完成後不跳回原文）。code fence 內 `:::` 已測試保持 literal；巢狀 directive、4-space indented code block（gpt_markdown 會先正規化縮排）、directive body 內的 `:::` 仍是已知限制。

**判定：導入（P1）。**

> `FencedBlockSyntax` 只匹配「整行等於 `opening`」的寫法，`:::note title="x"` 不會 match。若要支援 title，必須用自訂 `MarkdownBlockSyntax`（parse 第一行取 type/title），或先把 `title` 解析成 payload；不要假設 `FencedBlockSyntax` 能處理。

**語法**：

```markdown
:::note
內容
:::

:::warning title="自訂標題"
內容
:::
```

**實作**：

- Modern：`MarkdownBlockSyntax`（自訂 prefix `:::`，parse `:::note` / `:::note title="..."`）+ `MarkdownBlockComponent`，builder 讀 `MdCustomBlock.body` / `closed`。未知名稱 fallback 成普通段落。
- Legacy：`DirectiveBlockMd`（`BlockMd`），regex 抓 `^:::\s*(note|tip|important|warning|caution|danger)\s*(?:title="([^"]*)")?\s*\n([\s\S]*?)\n:::$`（`:::` 後容忍空白——LLM 常輸出 `::: note`）；未閉合時吃到 EOF 並標記 `closed=false`。
- 重用 3.2 的 `_MarkdownCalloutCard`；`danger` 對應 error，`important` 對應 secondary。
- 巢狀 directive 第一版不支援（上游也只做 leaf/container 的非同名巢狀）；文件要註明。
- 標題只接受純文字；strip HTML；長度上限 200。

**測試**：

- 五種 directive + 自訂 title。
- 未知 directive 不吞內容。
- 未閉合串流。
- directive 內含 code/table/math。
- directive 在 list item 內（若 parser 不支援，記錄為已知限制）。

### 3.4 行內 HTML

**上游做法**：native text/adapters 的子集；`b/strong`、`i/em`、`u`、`s/del`、`mark`、`font[color]`、`code`、`kbd`、`sub`、`sup`、`a`、`img`、`br`；`span[style]` 只接受有界 CSS；`<img>` 尺寸 ≤ 4096；主動元素丟棄、active URL scheme 拒絕；完整 HTML 文件走 preview。

**OmniChat 現況（2026-11-04）**：`InlineHtmlMd` 已支援 `b/strong`、`i/em`、`u`、`s/del`、`mark`、`code`、`kbd`、`sub/sup`、`span[style]`、`font[color]`、`br`；`DangerousHtmlMd` 丟棄 `script/iframe/object/embed/form/input/meta/link/base/style/img`。`<a>` 的 `href` 只允許 http/https/mailto/tel（`markdown_html_policy.dart`），`javascript:`/`data:`/`file:`/`omnichat:` 不再可點。`HtmlBlockMd` 支援 `p`、`ul`、`ol`、`li`、`blockquote`、`pre`、`hr`、`div`、`section`、基本 `table`（無 colspan/rowspan），並支援巢狀 `ul`/`ol`（depth 6）；任意 CSS 尚未做。

**判定：導入（白名單子集，P1）。**

**允許清單**：

- Inline：`b`、`strong`、`i`、`em`、`u`、`s`、`del`、`mark`、`code`、`kbd`、`sub`、`sup`、`a`、`br`、`span`（有限 style）、`font`（color）。
- Block：`p`、`details`/`summary`（現有）、`ul`/`ol`/`li`、`blockquote`、`pre`、`hr`、`div`、`section`、基本 `table`（無 colspan/rowspan）。
- 第一版**不支援**：`img`（先走 Markdown 圖片管線）、任意 CSS、`rowspan`/`colspan`。基本 `table` 已支援，但不做 colspan/rowspan；inline SVG 見 §3.7。
- **注意**：gpt_markdown 1.4 預設會渲染 HTML `<table>`；若政策要排除，必須在 `htmlTags` remove `table/thead/tbody/tr/td/th`，否則會與 Markdown table 並存。

**`span[style]` 允許屬性**：

- `color`、`background-color`（named/hex/rgb/rgba，拒絕 `url()`）；作者前景色會正規化為不透明，並向 `onSurface` 拉回至 4.5:1。
- `font-weight`（normal/bold/100–900）、`font-style`（normal/italic/oblique）。
- `text-decoration`（underline/line-through/overline）。`font-size` 尚未支援。
- 其他 CSS 一律忽略。

**安全**：

- Legacy inline 子集目前用 component regex（非 `package:html`）匹配單一 tag pair；除 `span[style]`/`font[color]` 的允許屬性外一律忽略，active content 由 `DangerousHtmlMd` 丟棄。modern 路徑再改用 `package:html` + allowlist。
- 2026-11-04：`HtmlAnchorMd` 的 scheme allowlist 已生效；markdown link `_handleLinkTap` 也重用 `isSafeHtmlLink`，`file:`/`ms-settings:`/`omnichat:` 不再直達 `url_launcher`。
- 已知限制：block HTML 支援 `p/ul/ol/li/blockquote/pre/hr/div/section` 與基本 `table`；table 的 colspan/rowspan 未做、table 儲存格寬度上限 320 px；任意 CSS 未做；`pre` 不做語法高亮且忽略 `class`/`lang`；巢狀 list/div 深度上限分別為 6/4；gpt_markdown 會正規化縮排，4-space indented code 內若出現 block tag 可能被當成 HTML（請用 fenced code）；`span`/`font` 的作者色以 block surface 量測對比並向 `onSurface` 拉回，frosted/wallpaper 直接回退 `onSurface`；巢狀同名 inline tag 可能留下 closing tag；`sub`/`sup` 用 `WidgetSpan`，在 SelectionArea 中不可選取；`<u>` 由 gpt_markdown 內建 `UnderLineMd` 先攔截。
- 丟棄 `script`、`iframe`、`object`、`embed`、`form`、`input`、`meta`、`link`、`base`、`style`。
- 丟棄所有 `on*` 事件屬性。
- `href` 只允許 `http`/`https`/`mailto`/`tel`；**不放行 `omnichat:` 等 app scheme**——LLM 輸出 `<a href="com.psyche.omnichat://oauth-callback?...">` 可能誤觸 app 的 OAuth deep link（手冊 §3.19 Provider OAuth）。`javascript:`、`data:text/html`、`file://` 拒絕。日後若需要 app scheme，須排除 `oauth-callback` 路徑並另過 security/product review。
- 巢狀深度 ≤ 16；單一 HTML 片段 ≤ 32 KB；超出則原文顯示。
- 串流中未閉合 tag 以原文顯示，不吞後續內容。

**實作**：

- Modern：gpt_markdown 1.4 的 HTML 支援（預設開啟，`html: false` 可關）＋ `htmlTags` allowlist；仍要在 `MarkdownWithCodeHighlight` 入口做一次 pre-scan/長度限制。
- Legacy fallback：`InlineHtmlMd`（inline tags → `TextSpan`）與 `HtmlBlockMd`（p/ul/ol/blockquote/pre/hr/div/section/table → widgets）已落地；巢狀 list 已支援（depth 6），table colspan/rowspan、`pre` 高亮與任意 CSS 仍待。
- 若 modern 的 HTML 行為與 OmniChat table/code 客製衝突，優先保留 Markdown table/code，HTML table 走 preview。

**測試**：

- XSS corpus：`<script>`、`<img onerror>`、`<a href="javascript:">`、`<svg onload>`、`<iframe>`。
- Markdown 連結 scheme：`[x](file:...)`、`[x](ms-settings:...)` 不得直達 `url_launcher`——legacy `LineSafeLinkMd` 與 modern built-in link 都要驗證（遷移前先確認現行實作的行為）。
- 格式巢狀：`<b><i>`, `<mark>`, `<kbd>`, `<sup>`, `<sub>`。
- 串流未閉合。
- CJK/emoji/URL。
- 表格 cell 內的 inline HTML。

### 3.5 主題化程式碼高亮

**上游做法**：`KelivoCodeHighlighter` 使用 `highlight` + `flutter_highlight` 主題；依 brightness 選 github/atom-one-dark；為 plain/wallpaper 分別提供 muted comment/quote/meta palette；**快取 syntax tree**（`ByteLruCache<String, List<Node>>`，8 MB），不快取 styled span；若 `span.toPlainText() != source` 則 fallback plain；語言正規化；36 px chrome 統一 code/table/diagram。

**OmniChat 現況**：`SelectableHighlightView` 每次 build `highlight.parse`；固定主題；無 cache；code block header 用 theme tint。

**判定：導入（P1）。**

**設計**：

- `MarkdownCodePalette.fromColorScheme(cs, brightness, surfaceStyle)`：
  - `background` = `surfaceContainer` 或 `alphaBlend(primary 3–6%, surface)`。
  - `header` = `surfaceContainerHigh`。
  - `text` = `onSurface`。
  - `comment` / `quote` / `meta` = `onSurfaceVariant`，wallpaper/frosted 再提高對比。
  - `keyword` = `primary`；`string` = `tertiary`；`number`/`literal` = `secondary`；`type`/`built_in` = `primary` 的變體；`tag`/`attr` = `error`/`tertiary`。
- `CodeHighlightCache`：
  - cache entry 必須**連原始 code 一起存**（`code → tree`）；命中時以字串相等（`==`）比對 code——字串比較遠比 parse 便宜，並杜絕 hash 碰撞回傳另一段 code 的 syntax tree（那會渲染錯誤高亮，是**正確性**問題，不是多一次 parse 的效能問題）。
  - lookup key 用 `normalizedLanguage|code.hashCode` 即可，或重用專案 OAuth cch 的 XXH64 實作（`lib/core/services/auth/claude_oauth_request.dart` 的 `xxh64Hex`）；無論用哪種 hash，都必須搭配上一步的 code 相等比對。
  - byte budget 8 MB（以 code length + node 數估算），LRU evict。
  - 只 cache parse tree；`TextSpan` 每次 build 重建（便宜）。
  - 若 `plainText != source`，回傳 `null` 並 fallback。
  - **cache 救不了串流熱點**：開放 fence 內容每 60 ms 都在變，key 每 tick miss，長 code 仍逐 tick 重 parse。對症解法是「**未閉合 fence 串流中直接 plain text、閉合後才 highlight**」（與 Mermaid 的 `isStreaming` deferral 同一契約）。
  - 命中率量測情境＝已完成訊息的重複 build（主題切換、捲動回收、展開/收合、匯出）；串流中不設 hit 目標。
- `SelectableHighlightView` 改為讀 cache；collapsed 狀態只畫前 2 行 plain text，不 parse。
- 擴充 `_normalizeLanguage`：`html/svg → xml`、`mermaid/plantuml → plaintext`、`tsx/jsx → typescript/javascript`、`shell → bash`。
- 可選：把 `flutter_highlight` 換成 `val_highlight_flutter`（gpt_markdown 1.4 內建），但語言數 55 < 現有 ~190；先用 `highlight` + cache。

**測試**：

- 同一 code/theme 連續 build 只 parse 一次（cache hit）。
- 主題切換不重 parse，只重畫 span。
- code 文字與 `TextSpan.toPlainText()` 完全一致。
- 長 code block（10k 行）首次/第二次 render 時間。
- collapsed block 不 parse。

### 3.6 數學公式

**上游做法**：仍用 `flutter_math_fork`（vendored），但每個 formula widget 自持 parse tree；<code>```math</code> fence；`normalizeMathTex`；解析失敗 fallback code block；區塊公式 padding 在 scroll clip 內。gpt_markdown 1.3.1+ 另用 `val_latex_flutter` 支援串流中未閉合公式。

**OmniChat 現況（2026-11-04）**：`flutter_math_fork`；`$`/`$$`/`\(`/`\[`；<code>```math</code>／`latex` fence 已支援（legacy `FencedCodeBlockMd` 與 `codeBuilder` 兩條路徑）；padding 修正已在共用 `ScrollableBlockMath`。串流中先顯示 code block，完成後才切公式；`tex` 不當 math（使用者通常想複製 LaTeX 原始碼）。

**判定：部分導入（P2）。**

> Modern 路徑的 <code>```math</code> **不能**用 `FencedBlockSyntax` 攔：built-in code fence 會先吃掉，且 `FencedBlockSyntax` 只認 `:::` 容器。必須在 `codeBuilder`（`CodeBlockBuilder(context, name, code, closed)`）裡判斷 `name == 'math'`。Legacy 路徑才是在 `FencedCodeBlockMd` 加分支。

**必做**：

1. [x] `FencedCodeBlockMd`（legacy）與 `codeBuilder` 已增加 `math`/`latex` 分支，交給共用 `ScrollableBlockMath`；math rendering 關閉或串流中先顯示 code block。解析失敗時 `_MathFence` 先以 `TexParser` 同步驗證，失敗直接退回可複製/下載的 code block（`$$`/`\[...\]` 也走同一路徑，避免首帧 TeX 與次帧 code block 造成長圖接縫）。
2. 公式裁切修正（P0，見 3.9）。
3. 為 repeated formula 建立 per-widget parse tree，避免全域 cache 持有 `GlobalKey`/widget（上游 `039af88` 的教訓）。目前 `_renderMath` 每次重建 parse，沒有 cache，暫時安全；若加 cache 必須 per-widget。

**可選**：

- 把 `_renderMath` 的 import 換成 `package:val_latex_flutter/flutter_math_compat.dart`（drop-in），取得串流 partial 公式、`\tag`/`align`/`\ce`/`\SI`；視覺會變成 Latin Modern Math，golden 需更新。
- 若不想改視覺，維持 `flutter_math_fork`；串流 partial 公式列為已知限制。

**測試**：

- `$$...$$`、`\[...\]`、`$...$`、`\(...\)`、<code>```math</code>。
- 解析失敗 fallback。
- 長公式水平捲動、tall glyph 不裁切。
- 串流中未閉合（若用 val_latex）。
- 表格 cell 內公式（`EscapeAwareTableMd` / modern parser）。

### 3.7 有尺寸上限的 SVG

**上游做法**：fork `vector_graphics_compiler`，共用 `GeometryBudget` 65,536 units；path copy/transform、dash command、curve subdivision（≤64 層）、pattern bitmap（每邊 ≤4,096 px、總 tiles ≤4,194,304 px）都扣預算；超限丟 `StateError`，呼叫端顯示 source link；inline `<img>` 尺寸 ≤4096；inline SVG 用 `currentColor`。

**OmniChat 現況（2026-11-04）**：

- Markdown `![](x.svg)` 已走 `SafeSvgImage`：512 KB bytes cap、SSRF check 每個 redirect hop、本機檔案 async length/read、4096 px 尺寸上限、`SvgPicture.string`；render 前 pre-scan 拒絕 script/foreignObject/iframe、`on*`、外部 href 與外部 `url(...)`，並限制 root/viewBox 尺寸、5,000 elements、path 總長 256 KB、depth 64。
- 行內 `<svg>...</svg>` 已走 `InlineSvgMd` + `SafeSvgText`：無網路/檔案存取，共用同一套 pre-scan、512 KB、4096 px；`script` 等主動內容顯示 broken-image，不執行。
- 快取只保留成功載入且通過 pre-scan 的 remote/local 文件（最多 8 份，失敗即移除）；data URI 不進 static cache，避免大字串被長期 pin 住。
- `SvgParseGuard` 對 `SvgPicture.string` 做 2 秒 preflight：超時或解析失敗時，inline SVG 顯示可選取的原始 SVG；remote/PlantUML 走各自 `errorBuilder`。preflight 會額外做一次 parse/decode；合法但超過 2 秒的 SVG 會停在 source fallback，直到 SVG 內容變更。
- 已知限制：`SsrfGuard()` 使用預設值（拒私網），因此自架 LAN SVG 會被擋；SVG 目前沒有點擊放大手勢。
- 行內 SVG 使用 `WidgetSpan`，不進入 SelectionArea/SelectCopy 的純文字；串流中尚未閉合的 `<svg>` 會先顯示原文，閉合後才切成圖片（completed 後才 render）。
- PlantUML 沿用 Markdown structural caps；超過 5,000 elements、256 KB path 或含外部 click link 的圖會顯示 error view，code tab 仍可使用。
- 行內 `<svg>` 已支援安全子集；`<svg>` 內的 script/foreignObject/iframe、外部引用與超限結構會被拒絕。
- `PlantUMLBlock` 已改走 `SafeSvgImage`：2 MB bytes cap、10 秒 timeout、SSRF guard、結構 pre-scan；失敗顯示既有 error view。
- code block 的 SVG 是 XML 樹狀預覽，不是圖片渲染。

**判定：部分導入（P2）。**

**建議範圍**：

1. [x] Markdown `![](x.svg)`：`SafeSvgImage` + `flutter_svg`；512 KB、SSRF redirects、async local files、4096 px。行內 `<svg>` 由 `SafeSvgText` 共用同一 guard。原 guard 範圍：
   - 來源 bytes ≤ 512 KB（網路圖片先 `http.get` 限流，或 `SvgPicture.network` 無法限流 → 先下載再 `SvgPicture.string`）。**下載路徑必須復用 `lib/core/services/web/ssrf_guard.dart`**（web_fetch 同款：拒內網/loopback/重定向後私網）——這會把 SSRF 面帶進圖片載入路徑，不能裸 `http.get`；本機檔案路徑判斷一律 async（手冊 §5.1.6 教訓：UNC 路徑同步 `existsSync` 可卡 10–25 s）。
   - [x] root `width`/`height` ≤ 4096；`viewBox` 面積 ≤ 4,194,304 px（widget 與 pre-scan 兩層）。
   - [x] element 數 ≤ 5,000；path `d` 總長 ≤ 256 KB；depth ≤ 64。
   - [x] 拒絕 `<script>`、`<foreignObject>`、外部 `href`/`xlink:href`、`url(...)`、`on*`。
   - [x] parse/render timeout 2 s：`SvgParseGuard` 以 `vg.loadPicture` bounded preflight；inline 失敗顯示原始 SVG source fallback，remote/PlantUML 使用 `errorBuilder`。
2. [x] PlantUML：`PlantUMLBlock` 改用 `SafeSvgImage`（timeout 10 s、max 2 MB；下載前過 `SsrfGuard`，逐 redirect 檢查），通過後 `SvgPicture.string`；失敗顯示 error view。404/超大/非 SVG 的專項測試已補（`plantuml_tabs_test`）。
3. **不 fork `vector_graphics_compiler`**：維護成本高；先用輸入 guard。若日後出現繞過 guard 的惡意 SVG，再評估 vendored fork。

**測試**：

- 正常 inline SVG、`currentColor`（`SafeSvgText` + `SvgTheme`）。
- 超寬/超高/大面積/大量 path/深巢狀 → 拒絕且不凍結 UI。
- `<script>`/`foreignObject`/外部 href → 剝除。
- [x] PlantUML 404/超大/非 SVG → error view；`plantuml_tabs_test` 以注入 `SsrfGuard` + fake `http.Client` 覆蓋。
- [x] 解析失敗 → inline SVG source fallback（`SafeSvgText` + `SvgParseGuard`）。

### 3.8 Mermaid 改由系統 WebView

**上游做法**：v1.3.3 把 Mermaid 放到 native/system WebView；`257aca7` 移除 Dart 端 900 ms export timeout，因為 timeout 會留下 in-flight export，下一次 retry 會替換 result callback；native bridge 自己等 Mermaid render-complete 並 bounded wait；Android integration test 用 5 s cold start 模擬。

**OmniChat 現況**：**已經是系統 WebView**（Windows WebView2、Android `webview_flutter`），但流程是「離屏 WebView → PNG 截圖」，且：

- 沒有 `rendered`/`error` 事件。
- `_captureMermaidBitmap` 等 120 ms 後，900 ms timeout ×4；`exportPngBytes` 內另有 8 s timeout——兩層 timeout 疊加，最壞 ~12 s。
- `_exportCompleter` 是單一欄位；timeout 後下一次呼叫會覆蓋，late message 可能送到錯的 completer。
- 固定 406 px 預覽高度（`BoxFit.contain` 會縮小，不會裁切，但高圖文字很小）。
- `securityLevel: 'loose'`。

**判定：部分導入（穩定性，P0）。**

**不需要**：把離屏 bitmap 改成 inline live WebView。OmniChat 的 bitmap 設計對長聊天/列表回收較安全，也避開 Windows WebView2 COM race；保留。

**需要**：

- HTML 在 `mermaid.initialize` 後送 `{type:'ready'}`；`mermaid.run` 成功送 `{type:'rendered', ok:true, width, height}`，失敗送 `{type:'error', message}`。
- `exportSvgToPng(requestId)` 回傳 `{type:'export', requestId, data}`；Dart 以 `Map<int, Completer>` 管理，late message 按 id 丟棄。
- Dart 流程：
  1. 插入 overlay。
  2. 等 `rendered`（cold start 上限 5 s，對齊 Android 5 s cold start 測試）。
  3. 送一次 export request，等 5 s。
  4. 失敗才 dispose 整個 view，重建一次（不是同一個 view 重試）。
- **收斂 timeout 為單層**：現況兩層（bridge 內 8 s + capture 迴圈 900 ms×4）各自為政，會把最壞 fallback 從 ~4 s 拖到 ~12 s。改為 bridge 不自帶 timeout、Dart 端單一總 timeout（8 s）。
- `dispose` 時 cancel debounce、complete/error 所有 pending、移除 overlay；late message 直接 ignore。
  - `securityLevel: 'strict'`；關閉 link/click callback，部分 diagram 會失去互動；這是安全換取功能的取捨。**2026-11-04 實測 mermaid 10.6.1：strict 下 `<br>`/`<br/>` 仍正常換行**（6 個案例全數成功、無 console error；無需改寫，升級 mermaid 時需重驗）。
  - 移除 900 ms timeout 後，最壞情況會等滿 10 s（rendered 5 s + export 5 s）；既有 loading view 需保留，並提供 cancel/dispose。
- 負 cache：invalid code 記 30 s，避免每次 rebuild 都 spawn WebView。
- 可選：依 bitmap 長寬比調整預覽高度（240–600 px），改善高圖可讀性。
- 保留 `isStreaming` 時 defer 成 code block 的契約；modern pipeline 遷移時必須保留 `closed`/stable block identity，否則每 chunk 重建 WebView 會重現 COM crash。

**測試**：

- Android `loadHtmlString` 延遲 5 s 仍成功。
- invalid mermaid 顯示 `mermaid-error-body`，不卡 loading。
- 快速改 code / 捲動回收 / dispose，無 late callback 例外。
- 同一 code 第二次 cache hit。
- Windows WebView2 缺失時 fallback code block（既有 §5.1 契約）。

### 3.9 區塊公式不再被裁切

**上游做法**：`2df8153` 把 `theme.mathPadding` 移到水平 `SingleChildScrollView` 的 clip 內，讓 glyph 的 vertical overpaint 有呼吸空間；同時保持水平方向仍在 viewport 外裁切。測試比較 pixel rows 與未裁切參考。

**OmniChat 現況**：見 2.4，padding 在 scroll viewport 外。

**判定：導入（P0）。**

**修正**：

```dart
LayoutBuilder(
  builder: (context, constraints) => SelectionContainer.disabled(
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      primary: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(minWidth: constraints.maxWidth),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Center(child: math),
        ),
      ),
    ),
  ),
)
```

重點：`Padding` 必須在 `SingleChildScrollView` 的 child 內，而不是包住 scroll view。

**落點**：修正直接寫在共用模組 `markdown_math.dart`（§4.1）的 block math widget，`LatexBlockScrollableMd`（legacy）與 modern 的 `blockLatexBuilder` 都委派同一 widget——不要把修正只寫在 legacy 的 `LatexBlockScrollableMd`，否則 Gate 2 成功後 modern 路徑要重做一次，pixel test 也無法跨管線存活。

**測試**：

- `\frac{a}{b}`、`\int`、`\sum`、`\sqrt` 等 tall glyph。
- font size 15.5 / 24；textScale 1.0 / 1.5。
- `$$` 與 <code>```math</code> 兩種入口。
- pixel test：頂/底 row 不得有被切掉的 ink；水平 viewport 外的 ink 仍為 0（可捲動）。
- 加 golden 或 `RenderRepaintBoundary.toImage` row-alpha 比較（參考上游 `math_block_clipping_test.dart`）。

### 3.10 表格與文字在自訂聊天背景的可讀性

**上游做法**：`MarkstreamTheme.proseInk`（plain → `colors.ink`；有背景 → `body.color`）；`blockContentTheme` 把 body/headings/quote/task/rule 改成 block 自己的 paired ink；table cell 走 `_blockContent.inlineText`；details/HTML 同步；translucent chrome 用 `on.withValues(alpha: .78)`；SVG/image 用 `proseInk`。測試涵蓋 wallpaper table capture。

**OmniChat 現況**：表格與 details/code **已有不透明底**（§2.6）——真正暴露面是 frosted 氣泡 66% 透明與 default assistant 無氣泡的**正文**；`cs.onSurface` 不保證與背景圖對比。表格/程式碼存在的是「不透明色塊突兀」的外觀問題，不是對比問題。

**判定：導入（P0，範圍縮小）。**

**設計（比上游簡化）**：

- 新增 `MarkdownSurfaceScope`（InheritedWidget）：

```dart
class MarkdownSurface {
  final Color surface;        // block 的不透明底色
  final Color surfaceContainer;
  final Color onSurface;      // paired ink
  final Color onSurfaceVariant;
  final bool isTranslucent;   // frosted / bare over wallpaper
  final bool hasWallpaper;
}
```

- `MarkdownWithCodeHighlight` 從 scope 讀取；沒有 scope 時 fallback `Theme.of(context).colorScheme`。
- `ChatMessageWidget._buildBubbleContainer` 依樣式提供：
  - `solid`：`surface = white/1C1C1E`，`onSurface = cs.onSurface`。
  - `frosted`：`surface = Color.alphaBlend(white/1C1C1E 0.66, cs.surface)`，`isTranslucent = true`。
  - `default` assistant + wallpaper：P0 先只做正文對比（plain text 加輕微 `Shadow` 或建議使用 frosted）；「block 改不透明底」是**可見設計變更**，獨立排程等 product sign-off（見 Phase 1A），不卡 P0 批次。
  - 無 wallpaper/default：`surface = cs.surface`。
- Block 元素（table、quote、details、code、mermaid、PlantUML）一律使用 `surface` 或 `surfaceContainer` 作為不透明底；text 用 `onSurface`。table/details/code 現況已接近此狀態——本項的作用是**把顏色來源統一改由 `MarkdownSurfaceScope` 提供**（為 modern pipeline 鋪路），而非改變現有視覺。
- Table：
  - 外層 `ClipRRect` + `ColoredBox(surface)`。
  - header `surfaceContainerHigh`；body row 不再透明。
  - 格線 `outlineVariant`；cell `onSurface`。
- Quote/details：`surfaceContainerLow` + `onSurface`；quote bar 用 `primary`。
- Code/Mermaid/PlantUML：header/body 改用 `surfaceContainer`/`surface`；comment 用 `onSurfaceVariant`。
- Link：`primary`；若 `primary` 與 `surface` 對比不足，用 `onSurface` + underline。
- 不做「依背景圖亮度動態算 ink」的複雜版本；用 paired opaque surface 保證對比，成本低且可預測。

**驗收矩陣**：

- 主題：light / dark。
- 氣泡：default / frosted / solid。
- 背景：無、明亮、暗、花俏（4 張）。
- 元件：table、quote、details、code、math、link。
- 自動量測：body text 對 `surface` 的 contrast ratio ≥ 4.5:1；large text ≥ 3:1。
- 截圖/pixel test：frosted／無氣泡正文對背景圖的對比達標（scoped pixel 斷言，非跨平台 golden）；table 維持不透明底列為回歸項（不得被 SurfaceScope 改動弄成透明）。

### 3.11 長圖匯出完整精度 + 預覽加速

**上游做法**：`b9d54cb` 保留 native PNG bit depth/alpha、copy byte rows、requested resolution；mount export content once、reuse capture tiles for preview、localized per-stage progress；測試 16-bit colors、mixed-depth slices、seams、preview reuse。

**OmniChat 現況**：單張 `toImage(pixelRatio: 3/2)`；無分塊；預覽解碼整張 PNG。

**判定：導入（P0）。**

**設計**：

1. **Mount once**：維持現在的 offscreen overlay，內容只 build 一次；量測 `contentKey.currentContext.size`。
2. **Tiling**：
   - 以保守上限推導：`maxTilePx = min(4096, deviceMaxTexture)`；`tileLogicalHeight = min(floor(maxTilePx / pixelRatio), totalHeight)`。Mobile 3x 預設 1024（=3,072 px），Desktop 2x 預設 2048（=4,096 px）；不要寫死 2048×3（=6,144 > 4,096）。
   - 每個 tile 用 `ClipRect` + `Transform.translate(offset: (0, -tileOffset))`，或 `SingleChildScrollView` + controller；`RepaintBoundary.toImage(pixelRatio)` 後只取前 `tileHeightPx` 行。
   - 最後一個 tile 的高度 = `totalHeightPx - drawnPx`，不得多取。
3. **拼接**：
   - 方案 A（先做）：`ui.PictureRecorder` + `Canvas.drawImageRect` 到最終 `ui.Image`（`FilterQuality.none`），再 `toByteData(png)`。**注意：最終 `ui.Image` 仍是整張**——1,440×40,000 ≈ 230 MB RGBA（120 MP ≈ 480 MB）。方案 A 只解 GPU texture 上限，不解總記憶體；這正是 tiling 要解的 OOM 換了個位置存在。因此上限必須依平台收斂（見第 6 點），且 Android 的「逐 tile 串流編碼」（tile → scanline → IDAT 直接寫檔）從「實測 OOM 才做」升級為**超限時的預設考量**。
   - 方案 B（若 Android OOM）：注意 `package:image` 的 `PngEncoder` 仍是從記憶體中的 `Image` 編碼，**不是**逐行 streaming；若要走這條，必須自行用 `ZLibEncoder` + 手動 IDAT chunks 寫 scanline，工程量較高。第一版先做方案 A + 硬性像素上限；只有實測 OOM 才引入真正 scanline encoder。
   - 文件要註明：Flutter `toImage` 產出的是 8-bit RGBA；上游的 16-bit/原生 bit-depth 路徑主要服務 iOS native capture，Windows/Android 這條 Flutter 路徑不適用，不要把它當成本輪驗收項。
4. **預覽（2026-11-04 落地）**：
   - `LongImageExporter` 產生 `*-preview.png`（寬 ≤1080、總像素 ≤8MP；不鎖高度，避免長圖縮成過窄）；`showImagePreviewSheet` 用縮圖顯示，儲存/分享/複製仍用全解析度檔。預覽關閉後刪除縮圖。
   - 全解析度 PNG 仍在匯出時整張 encode；真正的按需 encode 與逐 tile 串流編碼列後續。
5. **進度/取消/凍結**：
   - `onProgress(stage, current, total)`：`rendering` / `stitching` / `encoding`。
   - `CancelableOperation` 或 `bool _cancelled`；route pop 時取消、移除 overlay、dispose images。
   - **capture 期間凍結重建**：100 tiles 逐塊 `toImage` 可能 >15 s，期間任何 provider 通知都會重建被捕獲的樹 → 不同 tile 畫到不同版本內容＝接縫。2026-11-04 已以「初始 settle 後啟用 `TickerMode(false)`」+ 固定 `SettingsProvider`／`Theme`／`MediaQuery` 快照包住 content；Provider-mediated 重建被阻斷，直接 listener 不在保證內。逐 tile 仍有 mounted/disposed 守衛，取消是唯一退出路徑。
   - 遠端圖片：每 tile capture 前等待 `ImageCache.pendingImageCount == 0`，全匯出共用 4 s 等待預算（預留 2 s 給 tile，支援取消）；僅涵蓋 ImageProvider，SVG/WebView 尚未納入。
6. **上限（依平台收斂；2026-11-04 實作值）**：
   - Windows：80 MP；Android：36 MP（涵蓋測試案例 1,440×24,000 ≈ 34.6 MP，RGBA ~138 MB）。
   - 峰值約為最終 RGBA 的 3 倍（tile images + composed image + encoder buffer），因此 cap 以峰值反推；Android 峰值約 430 MB，低階機仍有風險。
   - 超過 cap 時先降 `effectivePixelRatio`（最低 1x）；1x 仍超限才拋 `LongImageTooLargeException`。
   - 真正的逐 tile 串流編碼（scanline/IDAT）仍未實作，列為後續 Android 硬化項。

**測試**：

- 480×8,000 logical、pixelRatio 3 → 1,440×24,000 PNG；尺寸精確、無接縫、alpha 正確。
- 兩個 tile 交界處 pixel diff = 0（或只有抗鋸齒允許值）。
- 取消匯出不留 overlay/temp file。
- 超過上限顯示錯誤，不 crash。
- 100 則訊息匯出成功；預覽 < 2 s（縮圖）。

### 3.12 串流、長訊息、Markdown 預覽加速

**上游做法**：markstream `IncrementalDocument` 重用 completed leading blocks、只重 parse 開放 container；renderer 在 `didUpdateWidget` 排 50 ms coalescing timer；`SliverGptMarkdown` lazy render；benchmark `MARKSTREAM_RENDER`。

**OmniChat 現況**：

- 60 ms throttle（好），但 legacy parser + 14 次全字串預處理 + 每次 code highlight parse（壞）。
- `MarkdownWithCodeHighlight.build` 每次重建 components list、closures、theme key。
- 長訊息是一個大 widget；沒有 block-level lazy。
- 預覽依賴 CDN（已於 2026-11-04 改為本地 vendor）。

**判定：導入（P0/P1）。**

**Track A（P0）：預處理 memoization + 串流 fast path**

- 抽出 `MarkdownPreprocessor`：
  - cache `(text, enableMath, enableDollarLatex)` → result，last 4 筆 LRU；theme/selection rebuild 直接命中。
  - 快取 `_sanitizeImageLinks` / `_extractImageUrls` 結果，避免每次 build 重跑兩個 regex。
  - `streaming: true` 時**保留**：
    - `UnicodeSanitizer.sanitize`
    - `_sanitizeImageLinks`（否則圖片會在完成瞬間才出現）
    - `_replaceInlineDollarMath`（否則 `$...$` 會先顯示原文再跳成公式）
    - code `$` 遮罩（若仍用 legacy math）
    - 未閉合 fence 的 cheap scanner（確保 code block 穩定）
  - **只跳過** link title 正規化（純外觀、不改變 block 邊界）；其餘 pass 全部保留。
  - **block-boundary passes 一律保留**（inline dollar scanner、display math 正規化、fence bullet/dedent/closing、setext、heading enum、未閉合 fence 自動閉合）——這些會改變 fence/heading/HR 的辨識，跳過會讓串流中結構與完成後不同、造成跳版。`test/markdown_preprocessor_streaming_test.dart` 以「串流與 full pass 輸出相等」的 fixture 清單守住此契約。
  - `isStreaming=false` 時做一次 full preprocess；**「完成前後無跳版」是明確驗收條件（非附註）**：串流最後一 tick 與 full-pass 後逐 block 對照，pixel/text 皆不得跳版。
- 若 modern pipeline 遷移成功，`preprocessFences` 大多可刪除，只留 media/Unicode/heading enum 等極少數 workaround。
- 目標：50 KB 訊息、60 ms tick，preprocess p95 < 2 ms（Desktop）/ < 5 ms（Android）。

**Track B（P1）：code highlight cache + 未閉合 fence deferral**

- 見 3.5；collapsed block 不 parse；**串流中所有 code block 先以 plain text 呈現、完成後才 highlight**（legacy 預處理會自動補上未閉合 fence，`closed` 資訊不可靠；以 `isStreaming` 全域 defer，效果等同未閉合 fence deferral，且保證每 tick 不重 parse）。
- cache 命中率 >90% 的量測情境＝已完成訊息的重複 build（主題切換/捲動回收/匯出）；串流中 key 每 tick 都變，不設 hit 目標。
- **記憶體總帳**：code tree LRU 8 MB + preprocess LRU（4×200 KB）+ Mermaid bitmap/高度 cache + 既有圖片 cache，在 Phase 1B 收尾時列合計並在 Android 低階機量測——多項 P0 同時落地後的擠壓要能歸因。

**Track C（P1，可選）：modern pipeline**

- 見 3.1 / 4.2；plusparse incremental + `SliverGptMarkdown`（長訊息）。
- 長期最乾淨的解；**Gate 2 的比較基準是「1B 調校後的 legacy」**——若 Track A/B 已達 §6.4 目標，modern 降為可選（僅在需要 alerts/directives/HTML/SVG 或 block-level lazy 時繼續投資，見 Phase 3 決策分支）。

**Track D（P1）：Markdown 預覽本地化（2026-11-04 完成）**

- `assets/html/mark.html` 改本地 vendor：
  - `markdown-it`、`@vscode/markdown-it-katex`、`markdown-it-task-lists`、`js-base64`、`katex`（含 fonts）、`highlight.js`、`DOMPurify`、`mermaid`（重用 `assets/mermaid.min.js`）——`mark.html` import 的全部八個套件，漏一個 preview 直接壞。
  - 移除 `esm.sh`/`jsdelivr` import；改為 classic UMD/IIFE scripts，避免 file:// 的 ES module CORS 限制。
- `MarkdownPreviewAssets` 一次性把 vendor 解壓到 temp；每個 Markdown 預覽寫入獨立 `preview_*/index.html`（`<base href="../">`），`HtmlPreviewPage`、`WebViewPage`、桌面 dialog 改用 `loadFile`/`loadUrl`，相對路徑可直接解析。
- `MarkdownPreviewHtmlBuilder` cache template；外部瀏覽器 fallback 保留；`HtmlPreviewPage` 已加 loading indicator／10 s timeout／retry。
- 目標：cold < 1.5 s、warm < 300 ms、offline 可用；cold/warm 尚待 Windows/Android 實機量測。

**Track E（P2）：長訊息 lazy**

- modern pipeline 後使用 `SliverGptMarkdown` 或把訊息切成 block list，`ListView.builder` 只 build 可見 block。
- 若留在 legacy，先做「長訊息 > 32 KB 時折疊 code/table，只渲染前 N 個 block + 展開按鈕」的保守方案。
- 注意：export 時要 disable culling（`cullToViewport: false` 或等價），否則長圖會空白。

**Benchmark**：

- `test/perf/markdown_render_bench.dart`：
  - **必須顯式 env guard**：`main()` 開頭 `if (Platform.environment['MARKDOWN_BENCH_RUN'] == null) return;` 預設 short-circuit——「不含 `expect`，`flutter test` 會跳過」是錯的，runner 仍會載入並執行 `main()`，沒有 guard CI 每次都跑。
  - fixtures：10 KB / 50 KB / 200 KB；含 code/table/math/mermaid/CJK。**mermaid fixture 在 Windows bench 會拉起真實 WebView2，計時噪音大**：bench 中以 mock/placeholder 渲染路徑取代，或把 mermaid 量測獨立為手動 scenario。
  - 指標：`firstPumpMedianUs`、`firstPumpP95Us`、`contentPumpMedianUs`、`contentPumpP95Us`、`coldFirstFrameUs`。
  - 5 次 fresh process（`MARKDOWN_BENCH_RUN=1..5`）。
- 目標：50 KB p95 content pump 改善 ≥30%（**比較基準＝Phase 0 baseline，僅適用於 1B 的 Track A/B**；Gate 2 的 modern 比較基準另定，見 Phase 3）；10 KB 不退化 >10%；Android 中階機無 >32 ms 的長 frame。

---

## 4. 目標架構與設計

### 4.1 模組拆分

在 `lib/shared/markdown/` 底下逐步拆（不要一次大搬家）：

```text
lib/shared/markdown/
  markdown_with_code_highlight.dart   # 入口、pipeline 選擇、theme wiring
  markdown_preprocessor.dart          # preprocess + cache + streaming fast path
  markdown_surface_scope.dart         # paired surface/ink
  markdown_code_palette.dart          # ColorScheme -> highlight theme
  markdown_code_cache.dart            # syntax tree LRU
  markdown_alert.dart                 # legacy alert 解析（五類型 + custom title）
  markdown_alert_style.dart           # alert accent/title/背景色（可測對比）
  markdown_directive.dart             # legacy ::: directive 解析
  ../widgets/markdown_callout_card.dart      # alerts + directives 共用卡片（已拆）
  ../widgets/markdown_directive_block.dart   # legacy DirectiveBlockMd
  markdown_inline_html.dart           # 白名單 HTML
  ../widgets/safe_svg_image.dart      # Markdown SVG guard（512 KB、SSRF、4096 px）
  markdown_math.dart                  # block/inline math + math fence
  markdown_diagrams.dart              # Mermaid/PlantUML block UI（可選）
```

`markdown_with_highlight.dart` 目前 4,475 行、17 個 `BlockMd`/`InlineMd` 客製類；先把新功能放新檔，舊元件留在原檔，等 modern pipeline 遷移時再刪/搬。這樣可以避免大規模 move 造成 review 困難。

### 4.2 gpt_markdown 現代管線遷移對照

| 現有 legacy | 現代 API | 動作 |
|:--|:--|:--|
| `components: [...]` | `blockComponents: [...]` | **必須移除** `components`；否則仍是 legacy |
| `inlineComponents: [...]` | `inlinePatterns` / `inlineDirectives` | **必須移除** `inlineComponents` |
| `SoftHrLine` | `hrBuilder` | port 樣式 |
| `EscapeAwareTableMd` | built-in table + `tableBuilder` | port table UI/toolbar/CSV；確認 cell inline markdown |
| `FencedCodeBlockMd` | built-in fence + `codeBuilder` | port `_CollapsibleCodeBlock`；保留 parser 的 `closed` 與 widget 層 `isStreaming`（WebView deferral 看後者；兩者不是同一個東西） |
| `LatexBlockScrollableMd` | `blockLatexBuilder` + `LatexStyle` | 改為委派共用 block math widget（§3.9/§4.1）；裁切修正不重做 |
| `InlineLatex*` | `inlineLatexBuilder` | port scroll |
| `DetailsHtmlMd` | built-in HTML `<details>`（**待 Gate 2 驗證**；1.4 changelog 未明列 details） | 先驗證 state/巢狀；不確定就保留 custom |
| `HtmlAnchorMd` | built-in HTML `<a>` | 刪除 |
| `AtxHeadingMd` / `SetextHeadingMd` | built-in + `headingBuilder` | port 樣式 |
| `LabelValueLineMd` | 已停用 | 刪除 |
| `ModernBlockQuote` | `blockQuoteBuilder` / `alertBuilder` | port 卡片 + alerts |
| `ModernCheckBoxMd` / `ModernRadioMd` | built-in + `checkboxBuilder` / `radioOptionBuilder` | port 樣式 |
| `LineSafeLinkMd` | built-in link（1.3+ TextSpan） | 刪除；**遷移前先確認** built-in link 的 scheme 驗證（`file:`/`ms-settings:` 不得直達 `url_launcher`），契約補進本表 |
| `BackslashEscapeMd` | built-in CommonMark | 刪除 |
| `preprocessFences` 大部分 | parser 原生處理 | 只留 media/Unicode/必要 heuristic |

**遷移順序建議**：

1. 先移除 `inlineComponents` 與 `components`，只留最小 `blockComponents`，跑 fixture 清單，記錄差異。
2. 逐項把 builder 接上（code → table → math → quote/alert → heading → checkbox）。
3. 最後刪除 legacy 元件與 `preprocessFences` 的死碼。
4. 每一步都要有 feature flag 與 golden 對照。

### 4.3 Feature flag /  rollout

- 編譯期：`const bool kMarkdownModernPipeline = bool.fromEnvironment('MARKDOWN_MODERN', defaultValue: false);`
- 執行期（beta）：`SettingsProvider` 裝置私有 key `markdown_pipeline_v1`（`legacy` / `modern`），預設 `legacy`。**依手冊 §5.7 規則加入 `data_sync.dart` 的 `_localOnlyKeys`**（新增裝置私有偏好必須同時入冊，成本為零，避免未來被備份意外覆寫）。
- 入口 `MarkdownWithCodeHighlight` 內分流：
  - `modern` → 新 `MarkdownModernView`。
  - `legacy` → 現有 `GptMarkdown` + components。
- 先 dogfood 一個 release；modern 穩定後把預設改 `modern`；再過一個 release 刪 legacy。
- 不要永久雙軌；文件要寫「移除 legacy 的 release gate」。

### 4.4 `MarkdownSurfaceScope`

```dart
class MarkdownSurfaceScope extends InheritedWidget {
  const MarkdownSurfaceScope({
    super.key,
    required this.surface,
    required super.child,
  });

  final MarkdownSurface surface;

  static MarkdownSurface of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<MarkdownSurfaceScope>();
    return scope?.surface ?? MarkdownSurface.fromColorScheme(
      Theme.of(context).colorScheme,
    );
  }

  @override
  bool updateShouldNotify(MarkdownSurfaceScope oldWidget) =>
      oldWidget.surface != surface;
}
```

`MarkdownSurface` 需有 `==`/`hashCode`，避免每次 build 都通知。

> **2026-11-04 現況**：`ChatMessageWidget` 依氣泡樣式提供 scope；`ai_team_proposals_section.dart` 使用卡片灰字 ink，`message_export_sheet.dart` 使用 `ColorScheme` exported surface。三者都不再 fallback。

### 4.5 Mermaid render-complete 協議

HTML → Dart：

```json
{"type":"ready"}
{"type":"rendered","ok":true,"width":720,"height":480}
{"type":"error","message":"..."}
{"type":"export","requestId":7,"data":"<base64 png>"}
```

Dart：

```dart
final pending = <int, Completer<Uint8List?>>{};
int _nextRequestId = 1;

Future<Uint8List?> exportPngBytes() async {
  await _rendered.future.timeout(const Duration(seconds: 5));
  final id = _nextRequestId++;
  final completer = Completer<Uint8List?>();
  pending[id] = completer;
  _controller.runJavaScript('exportSvgToPng($id);');
  try {
    return await completer.future.timeout(const Duration(seconds: 5));
  } finally {
    pending.remove(id);
  }
}
```

規則：

- `rendered` 之前不送 export。
- 每次 export 一個 requestId；late message 按 id 丟棄。
- 失敗時整個 view dispose + 重建一次；不要在同一個 view 上「重試」。（目前 capture 為 3×160 ms 有界重試 + failure cache；完整「重建一次」尚待實機驗證）
- timeout 只有一層（bridge 協議）：rendered 5 s、export 5 s；HTML reload 時在同一個 10 s deadline 內重新等待當前 completer，外層不再重複 timeout。
- `dispose` 時將所有 pending complete(null)。
- per-State `_failedBitmapRenderKeys` 已於 2026-11-04 移除，改為 30 s TTL 的 `MermaidFailureCache`（global negative cache）。

### 4.6 長圖 tiling

```text
totalHeightPx = ceil(contentHeight * pixelRatio)
maxTilePx = 4096                             // 固定保守值；Dart 端無法查 deviceMaxTexture
tilePx = min(maxTilePx, totalHeightPx)
for offset in 0..totalHeightPx step tilePx:
    boundary = RepaintBoundary(
      child: SizedBox(
        width: width,
        height: tilePx / pixelRatio,
        child: ClipRect(
          child: Transform.translate(
            offset: Offset(0, -offset / pixelRatio),
            child: content,
          ),
        ),
      ),
    )
    image = await boundary.toImage(pixelRatio: pixelRatio)
    cropTop = 0
    cropHeight = min(tilePx, totalHeightPx - offset)
    drawImageRect(image, src: Rect(0, 0, image.width, cropHeight), dst: ...)
```

注意：

- `content` 只 build 一次，但每個 tile 仍需要 layout；若用 `Transform.translate`，content 的 layout 高度是完整的，可能還是很大。實務上可用 `SingleChildScrollView` + `controller.jumpTo`，content 只 layout 一次，tile boundary 只截 viewport；這樣 memory 較好。兩種都做 benchmark 後選一。
- 每個 tile 之間要 `await endOfFrame`，確保 paint 完成。
- **capture 期間凍結重建 + 逐 tile mounted/disposed 守衛**（§3.11 第 5 點）：tile 愈多離屏 overlay 存活愈久，任何 provider 通知造成的重建都會產生跨 tile 接縫。
- 遠端圖片：每 tile 前確認 frame settle（現行「3 frames + 500 ms」機制保留於每 tile 前），否則截到空白。
- `FilterQuality.none`，避免縮放造成模糊。
- 最後 encode 前檢查 `drawnPx == totalHeightPx`。

### 4.7 Markdown 預覽本地資產

```text
assets/html/
  mark.html
  vendor/
    markdown-it.min.js
    markdown-it-katex.min.js       # @vscode plugin IIFE, KaTeX external
    markdown-it-task-lists.min.js
    katex.min.js
    katex.min.css
    fonts/*.woff2
    highlight.min.js
    atom-one-dark.min.css
    purify.min.js
    base64.min.js
    README.md
```

- `pubspec.yaml` assets 加入 `assets/html/vendor/` 與 `assets/html/vendor/fonts/`。
- `mark.html` 使用相對路徑 classic scripts／CSS；`MarkdownPreviewAssets` 一次性把 vendor 解壓到 temp，並把每個 Markdown 預覽寫入獨立 `preview_*/index.html`（`<base href="../">` 指回 vendor），所有預覽入口改用 `loadFile`/`loadUrl`，因此 Windows/Android/macOS 都不依賴 `loadHtmlString` 的 base URL。
- `MarkdownPreviewHtmlBuilder` 快取 template 字串；`mark.html` 無 CDN、無 ES modules。
- Mermaid 統一使用既有 `assets/mermaid.min.js`（runtime 複製到預覽目錄），不再使用 esm.sh 版本。
- `THIRD_PARTY_NOTICES.md` 已補 markdown-it、@vscode/markdown-it-katex、markdown-it-task-lists、js-base64、KaTeX、highlight.js、DOMPurify、Mermaid；`assets/html/vendor/README.md` 記錄版本與來源。

> **2026-11-04 現況**：已實作。`markdown_preview_assets_test` 驗證 vendor 解壓、並行 dedupe、marker reuse、mark.html 無 CDN、每個 vendor 引用都存在、builder 置換 `<base href="../">` 且無殘留 `{{...}}`，以及預覽目錄隔離／刪除；Chrome `file://` smoke（`preview_*/index.html` + `<base href="../">`）：14/14 本地資源 200、零 console error，表格／KaTeX（inline + display）／code／task list／Mermaid SVG 全部渲染。KaTeX plugin 以 external 方式打包（6.3 KB，避免重複 ~270 KB）；cold/warm、loading/timeout 已補（HtmlPreviewPage），macOS/iOS 實機仍待補。
>
> **隔離**：每個 Markdown 預覽使用獨立 `preview_*` 子目錄，關閉時整目錄刪除；raw workspace `.html`/`.svg` 走另一個獨立 temp 目錄。舊 `preview_*` 目錄（WebView 未釋放／崩潰）由 `writeHtml` 以 7 天門檻 best-effort 清理，避免無限累積。

### 4.8 依賴與版本

| 套件 | 現在 | 建議 | 備註 |
|:--|:--|:--|:--|
| `gpt_markdown` | `^1.1.4`（lock 1.3.0） | 正式 pin **1.3.0**；本機 override spike **1.4.0** | 1.3.4 是 patch 選項，但本 spike 以 production 1.3.0 為 baseline，避免同時改兩個變數。不要用 `^1.3.x`：caret 會直接解析到 1.4.0。1.4 需要 Dart ≥3.12 / Flutter ≥3.44；本機 3.47.6 / 3.13.5 已滿足 |
| `flutter_svg` | `^2.2.1` | `^2.3.0`（1.4 要求） | 相容 caret |
| `val_latex_flutter` | 無 | 1.4.0 **硬依賴** `^0.1.2`（最新 0.1.3） | 不是可選——pub.dev 依賴清單：material_ui、val_highlight、val_highlight_flutter、val_latex_flutter、xml。捆綁 9 個 Latin Modern text OTF（~1 MB），`val_latex` 另帶 math 字型；**Gate 1 的 APK 增量必須實測** |
| `image` | 無 | 可選 | 若 tiling 方案 B 需要 PNG encode |
| `material_ui` | 無 | 1.4.0 transitive | **最大未知數**；Gate 1 必須驗證與 `flutter/material.dart` 型別共存 |
| SDK constraint | `^3.11.0` | 1.4 正式化時改 `^3.12.0` | 正式依賴仍是 1.3.0，所以目前保留 `^3.11.0`；Gate 1 只在 override 下用 3.12+。CI 已升 3.47.6，本機 3.47.6 / 3.13.5 |

---

## 5. 實作計畫

> 以下人日為單一熟悉 Flutter 的工程師估算，含實作、測試、code review，不含長期維護。  
> 順序刻意把「不依賴 parser 的修正」放前面，讓價值先落地。

### Phase 0：基線與護欄（2–3 人日）

- [x] 建立 Markdown fixture corpus（見 §6.2），放在 `test/fixtures/markdown/`（2026-11-04）。
- [x] 建立 `test/perf/markdown_render_bench.dart`（env guard，預設 skipped）；2026-11-04 baseline：10 KB 2.7 s、50 KB 17.9 s、200 KB 240.7 s（test binding，非 release）。
- [ ] 錄製 Windows/Android baseline：串流 50 KB、100 則長圖匯出、preview cold/warm/offline。
- [x] 確認 `flutter analyze`、現有渲染測試全綠（2026-11-04：`flutter analyze lib` 0 errors；相關批次全綠）。
- [ ] 加 feature flag `markdown_pipeline_v1`（預設 legacy）與 `MARKDOWN_MODERN` dart-define。
- [x] 文件化目前 `MarkdownWithCodeHighlight` 的 public 行為（2026-11-04：GitHub alerts legacy 已支援；HTML 子集、math 邊界仍待整理）。

**驗收**：baseline 數據與 fixtures 進 repo；不改行為。

### Phase 1A：P0 穩定性與可讀性（6–8 人日）

- [x] **Mermaid render-complete 協議**（3–4 人日；2026-11-04 落地）
  - `mermaid_bridge_stub.dart`：`ready`/`rendered`/`error`、export `requestId`；Windows `webMessage` 與 Android `LifecycleChannel`/`ExportChannel` 都已接上。
  - 移除 900 ms capture 迴圈；bridge 內 rendered 5 s、export 5 s（同一 deadline），capture 以 3×160 ms 有界重試吸收 overlay/WebView 尚未就緒。
  - `securityLevel: 'strict'`；negative cache 30 s（`MermaidFailureCache`）。**實測 mermaid 10.6.1：strict 下 `<br>` 仍正常換行，未加 `<br>` 改寫。**
  - 測試：`mermaid_capture_policy_test.dart`、`mermaid_failure_cache_test.dart`、`mermaid_bitmap_tabs_test.dart`；Android/Windows 實機 cold start 尚待手動驗證。
  - [ ] 失敗「重建一次」政策未另做；目前是 capture 有界重試 + failure cache。
- [x] **公式裁切修正**（1 人日；2026-11-04 落地）
  - 修正落於共用 `markdown_math.dart` 的 `ScrollableBlockMath`；`LatexBlockScrollableMd` 委派之，Gate 2 後 modern 路徑重用同一 widget。
  - `test/markdown_math_clipping_test.dart` 覆蓋 padding 在 scroll viewport 內與實際 markdown 路徑。
- [x] **正文對比 + `MarkdownSurfaceScope`**（2–3 人日；2026-11-04 核心落地）
  - `MarkdownSurface`/`MarkdownSurfaceScope` + `ChatMessageWidget` 依 solid/frosted/default+wallpaper 提供實際 bubble surface；只在有 scope 時覆寫 markdown ink。
  - Table/code/details/quote 的底色與 ink 改由 scope 提供；frosted／無氣泡正文加淡陰影。
  - 測試：`test/markdown_surface_scope_test.dart`（scoped ink/shadow）。
  - [x] `ai_team_proposals_section.dart` 與 `message_export_sheet.dart` 已顯式提供 scope（AI Team 保留卡片灰字 ink；export 使用 `ColorScheme` surface）。
  - [ ] 「default assistant + wallpaper 改不透明 block 底」仍等 product sign-off。
  - [x] 4 背景 × 3 氣泡 × light/dark 對比矩陣已自動化：`test/markdown_surface_contrast_test.dart`（24 組，`onSurface` ≥ 4.5:1、`onSurfaceVariant` ≥ 3.0:1，含 frosted／wallpaper 陰影政策）。
  - [ ] 實際背景圖／氣泡截圖與實機視覺 QA 尚未做。

**驗收**：Mermaid 冷啟動不卡死；公式 pixel test 通過；4 背景 × 3 氣泡 × light/dark 可讀。

### Phase 1B：P0 匯出、預覽、串流、code cache（10–14 人日）

- [x] **Code palette + syntax tree cache**（2–3 人日；2026-11-04 落地）
  - `MarkdownCodePalette`（ColorScheme tokens；`name` 保留原主題色；依顏色簽名快取）。
  - `CodeHighlightCache` LRU 8 MB（entry 存原始 code、命中字串比對；只快取 round-trip 成功的樹；巢狀節點估算）；collapsed block 不 parse；串流中 code block 以 plain text 呈現，完成後才 highlight。
  - 測試：`markdown_code_cache_test.dart`、`markdown_code_palette_test.dart`、`code_block_streaming_defer_test.dart`。
  - [x] 編碼階段 tile 釋放：`picture.toImage` 完成後立即 dispose 所有 tile images，encode 峰值由「tiles + composed + encoder」降為「composed + encoder」（2026-11-04）。
  - [ ] capture 階段仍受 `ui.Picture` 保留全部 tiles（≈ 1 frame）限制；逐 tile 串流編碼未做。記憶體總帳（code LRU + preprocess LRU + Mermaid cache + 圖片 cache）與 Android 低階機量測尚未做。
- [x] **長圖 tiling + 進度/取消**（4–5 人日；2026-11-04 落地）
  - `lib/shared/widgets/long_image_exporter.dart`；`_renderWidgetDirectly` 預設 tiling，`--dart-define=LONG_IMAGE_TILING=false` 回退單張。
  - 分塊 capture（effective ratio）、絕對座標拼接、進度/取消、平台 cap。
  - 縮圖預覽已接上（寬 ≤1080、≤8MP；預覽關閉後刪除）；`test/long_image_export_plan_test.dart` 覆蓋計畫數學與縮圖尺寸。
  - runtime flag `long_image_tiling_v1`（device-local、加入 `_localOnlyKeys`）與設定頁 Display → Rendering 開關（2026-11-04 完成）。
  - [x] capture freeze：初始 settle 後才啟用 `TickerMode(false)`；匯出 content 以固定 `SettingsProvider`／`Theme`／`MediaQuery` 快照包住，避免 Provider-mediated 重建（直接 listener 不在保證內）。
  - [x] 遠端圖片 settle：每 tile 前等待 `ImageCache.pendingImageCount == 0`，全匯出共用 4 s 等待預算（預留 2 s 給 tile），並支援取消；僅涵蓋 ImageProvider，SVG/WebView 不在此列。
- [x] **Markdown 預覽本地化**（2–3 人日；2026-11-04 落地）
  - `assets/html/vendor/`：markdown-it 14、task-lists、@vscode/markdown-it-katex（IIFE，KaTeX external）、KaTeX 0.16.8（含 woff2）、highlight.js 11.9、DOMPurify、js-base64；Mermaid 重用 `assets/mermaid.min.js`。
  - `mark.html` 改 classic UMD/IIFE scripts，移除 CDN 與 ES modules；避免 file:// module CORS。
  - `MarkdownPreviewAssets` 一次性解壓到 temp；每個 Markdown 預覽寫入獨立 `preview_*/index.html`（`<base href="../">`），關閉時刪除整個子目錄；`HtmlPreviewPage`／`WebViewPage`／桌面 dialog 改用 `loadFile`/`loadUrl`。
  - `MarkdownPreviewHtmlBuilder` template cache；外部瀏覽器 fallback 寫入獨立 `open_*` 子目錄（只保留一份）。
  - 測試：`markdown_preview_assets_test.dart`（vendor 引用、並行 dedupe、marker reuse、預覽目錄隔離／刪除、外部檔 pruning、builder 置換 `<base href="../">` 且無殘留 `{{...}}`）；Chrome `file://` smoke（子目錄 + base href）14/14 資源 200、零 console error。
  - [x] `HtmlPreviewPage` 已加 loading indicator、10 s timeout 與 retry（桌面 dialog 已有 init error UI）。
  - [ ] Windows/Android/macOS/iOS 實機離線與 cold/warm 量測。
- [x] **預處理 memoization + 串流 fast path**（2–3 人日；2026-11-04 落地）
  - `preprocessFences(..., streaming: true)`；**所有會改變 block 邊界的 passes 一律保留**（fence bullet/dedent/closing、setext/HR、heading enum、display math、trailing-link 分段），串流只跳過 link-title 外觀正規化。
  - `preprocessCached` 4-entry LRU；key 不再複製整段輸入；串流結果不進 cache。
  - 完成時 full pass；測試以「串流輸出 == full pass 輸出」守住 block-boundary 契約。
  - 測試：`markdown_preprocessor_streaming_test.dart`、`code_block_streaming_defer_test.dart`、`markdown_fixtures_smoke_test.dart`。
  - [ ] micro-benchmark 與「完成前後截圖」尚未做。

**驗收**：100 則長圖匯出成功且預覽 <2 s（已具備 tiling/縮圖；實機待測）；preview 離線可用（**本地 vendor 已驗證；實機待測**）；50 KB 串流 preprocess p95 待 release/實機量測。

### Phase 2：gpt_markdown 1.4 依賴/build spike（Gate 1，2–3 人日；**獨立 spike，Phase 0 後即可與 Phase 1 並行**——結果直接決定 Phase 4 的 alerts/directives/HTML/SVG 走 modern 或 legacy 路徑）

- [x] 分支策略：本次 spike 在 main 工作區執行（未建分支）；正式 `spike/markdown-modern` 與 SDK bump 留給 Gate 2。
- [x] 本次 spike 使用本機 `pubspec_overrides.yaml`（`gpt_markdown: 1.4.0`、`flutter_svg: 2.3.0`、SDK 由環境提供）；已加入 `.gitignore`，內容見下方「本機 override 內容」。
- [x] `flutter pub get`、`flutter analyze`（spike override；analyze 0 errors）
- [x] `flutter build windows --debug`、`flutter build apk --debug`（spike override；兩平台成功）
- [x] 檢查 `material_ui` 與 `flutter/material.dart` 的型別共存；用最小 `GptMarkdown` + 自訂 builder 驗證（無 duplicate type；HTML table smoke test 通過）
- [x] 驗證 1.4 的 HTML 預設是否會渲染 `table`（會；正式路徑仍 legacy，政策待 Gate 2 決定）
- [x] 檢查 APK size / minSdk / plugin 衝突；實測 **release** APK 增量（+14.4 MB；libapp.so +13.99 MB、assets/packages +0.91 MB）。`aapt dump badging` 顯示 baseline 與 1.4 APK 的 `sdkVersion` 都是 **24**；沒有 plugin 要求 bump。
- [x] 核對授權並更新 `THIRD_PARTY_NOTICES.md`（gpt_markdown/material_ui/val_* BSD-3；Latin Modern GUST；flutter_svg MIT）
- [x] 記錄結果；技術上通過，但 release APK +14.4 MB、CI 版本與 Gate 2 成本需納入決策。

**Gate 1 通過條件**：兩平台 debug build 成功；無 duplicate Material 型別錯誤；**APK size 增量實測並記錄，納入 Phase 4 決策**（原訂 < 3 MB 為參考值——字型資產可能吃掉大半預算）。

**Gate 1 結果（2026-11-04，spike）**

- 以 `pubspec_overrides.yaml` 將 `gpt_markdown` 升到 1.4.0、`flutter_svg` 2.3.0，並保留專案的 `permission_handler_windows`／`speech_to_text_windows` path overrides。解析到 `material_ui` 1.10.0、`val_latex_flutter`/`val_latex` 0.1.3、`val_highlight`/`val_highlight_flutter` 0.1.1。
- 本機：Flutter 3.47.6 / Dart 3.13.5。`flutter analyze lib`：**0 errors**。
- Windows `flutter build windows --debug`：**成功**（保留 path overrides 後約 143 秒）。
- Android `flutter build apk --debug`：**成功**（JDK 17，約 447 秒）；`flutter build apk --release`：**成功**（176.8 MB）。下列增量一律指 **release APK**，不是 debug。
- **Release APK** size：1.3.0 baseline **162.4 MB** → 1.4.0 **176.8 MB**，增量 **+14.4 MB（+8.9%）**。拆解：`libapp.so` 三個 ABI 合計 +13.99 MB（Dart AOT，未壓縮），`assets/flutter_assets/packages` +0.91 MB；val_latex 的 Latin Modern 字型與 gpt_markdown 的 JetBrains Mono 只佔其中小部分。
- `material_ui`：沒有 duplicate Material 型別／編譯錯誤；`test/gate1_modern_spike_test.dart` 以 Flutter `MaterialApp` host 驗證 1.4 的 HTML table 可渲染。此測試預設 skip，需 `flutter test --dart-define=GATE1_MODERN_GPT_MARKDOWN=true test/gate1_modern_spike_test.dart` 才執行，避免 CI 在 1.3.0 pin 下誤跑。專案目前仍走 legacy `components`，所以 1.4 HTML 行為尚未進入正式路徑。
- 未驗證：material_ui 的 theme/token 繼承只以「MaterialApp host + 無 exception」覆蓋；實際顏色與 4 背景 × 3 氣泡對照留 Gate 2。
- CI：已把 `build-stable.yml`、`build-stable-38.yml`、`build-linux-arm64.yml` 的 Flutter pin 更新為 **3.47.6**（1.4 最低需求為 3.44 / Dart 3.12）；手冊同步記錄「正式 SDK 仍 ^3.11.0，1.4 spike 需 3.12+」。代價是 CI 不再測 `^3.11.0` 的宣告下限；Gate 2 前要決定恢復 floor job 或 bump SDK constraint。
- **判定：技術上通過，但成本明顯。** 不在 Gate 2 前合併到正式依賴；spike override 保留在工作區，移除即可回到 1.3.0。Phase 4 需把 +14.4 MB release APK 成本與 material_ui 維護面納入決策。
- 授權已核對：gpt_markdown／material_ui／val_* 為 BSD-3-Clause，Latin Modern 為 GUST Font License，flutter_svg 為 MIT；已記入 `THIRD_PARTY_NOTICES.md`。

**本機 override 內容**（`pubspec_overrides.yaml`，已 gitignore；建立後執行 `flutter pub get`）。注意：override 對 `flutter build apk --release` 同樣生效，Gate 2 前不要用這個工作區產 release：

```yaml
dependency_overrides:
  gpt_markdown: 1.4.0
  flutter_svg: 2.3.0
  # pubspec_overrides replaces the dependency_overrides section in pubspec.yaml.
  permission_handler_windows:
    path: ./dependencies/flutter-permission-handler/permission_handler_windows
  speech_to_text_windows:
    path: ./dependencies/speech_to_text_windows
```

### Phase 3：modern pipeline 平權 spike（Gate 2，7–10 人日）

- [ ] 移除 `components` 與 `inlineComponents`，只留 `blockComponents`；確認進入 plusparse。
- [ ] 依 §4.2 對照表逐項接 builder：
  - code block（重用 `_CollapsibleCodeBlock`；保留 `closed`/`isStreaming`）。
  - table（toolbar/CSV/選取）。
  - math（block/inline/scroll/clip）。
  - quote/alert。
  - heading/hr/checkbox/radio。
  - details/HTML。
  - citation/link。
- [ ] 將 `preprocessFences` 縮到最小；確認沒有 regex parser 專屬 workaround 殘留。
- [ ] **Mask 清理**：`codeDollarMask`/`unmaskCodeDollars` 從 `_CollapsibleCodeBlock`、`FencedCodeBlockMd`、`highlightBuilder` 移除；`fencedHtmlTagStartMask` 從 code 路徑移除。漏掉會讓 code 顯示 `___CODE_DOLLAR_MASK___`。
- [ ] 跑 fixture corpus 視覺/行為對照；記錄差異。
- [ ] Windows 60 ms 串流壓力測試（含 Mermaid/PlantUML deferral、SelectionArea 禁令）。
- [ ] 量測 50 KB/200 KB p95；與 **1B 調校後的 legacy** 比較（不是 Phase 0 baseline）。
- [ ] 驗證 `DetailsHtmlMd` 在 1.4 是否仍有等價 `<details>` 行為；沒有就保留 custom。
- [ ] 決定 alerts/directives/HTML/SVG 是否直接採用 library 能力；不足處補 custom。

**Gate 2 通過條件**：

- fixture 差異 ≤5%，且可在 2 天內修完。**量測程序**：逐 fixture checklist，legacy/modern 各截一圖（本機手動對照，不入 repo），逐一標記 pass/diff——沒有程序的 gate 等於沒有 gate；不做跨平台 snapshot golden，差異斷言用 scoped pixel（如 §3.9 row-alpha 法）。
- Windows 無選取崩潰、無 WebView 重建。
- 50 KB p95 相對 **1B 調校後的 legacy** 再改善 ≥15%；**若 1B（Track A/B）已達 §6.4 總目標，此項不再強制 → modern 降為可選**（僅在需要 alerts/directives/HTML/SVG 或 block-level lazy 時繼續）。
- table/code/math/citation/export 行為與 legacy 等價。

**若 Gate 2 失敗**：停止 hybrid；alerts/directives/HTML/SVG 全走 legacy 自建（Phase 4 成本升為 6–9 人日，見 §8/里程碑）；轉 Phase 5 評估 markstream，或退回 legacy + Phase 1 的成果。

### Phase 4：功能完成與 UX（3–5 人日）

> **2026-11-04 現況**：GitHub alerts、directives 與 inline HTML 安全子集 legacy fallback 已先行落地（五類型 + danger、custom title、l10n、標題 4.5:1 對比矩陣、SelectCopy 標題排除；b/i/u/s/mark/code/kbd/sub/sup/span/font/br；p/ul/ol/li/blockquote/pre/hr/div/section/基本 table，含巢狀 list）；table colspan/rowspan、`pre` 高亮與 modern builder 平權仍待。

- [ ] **決策：user message（`enableUserMarkdown`）與 AI Team 是否啟用新語法**（建議預設：user 輸入關閉 alerts/directives，HTML 只讀；見 §0.3）。
- [x] GitHub alerts（legacy fallback 已於 2026-11-04 落地：五種類型、custom title、body、標題排除 SelectCopy；modern `alertBuilder` 待 Gate 2 平權）。
- [x] Directives（legacy 已於 2026-11-04 落地：`DirectiveBlockMd` + `MarkdownCalloutCard`，支援 `:::note/tip/important/warning/caution/danger`、custom title、未知名稱保留 children、串流未閉合 partial；modern `MarkdownBlockSyntax` 待 Gate 2）。
- [x] Inline HTML 白名單（legacy：`InlineHtmlMd` + `DangerousHtmlMd`；b/strong、i/em、u、s/del、mark、code、kbd、sub/sup、span[style]、font[color]、br；p/ul/ol/li/blockquote/pre/hr/div/section/table（無 colspan/rowspan）；script/iframe/img 等主動內容丟棄；`<a>` 只允許 http/https/mailto/tel）。
- [x] <code>```math</code> fence（legacy，`math`/`latex`；`math.md` fixture + math clipping test；串流 defer、math 關閉 fallback code）；可選 val_latex 尚未導入。
- [x] SVG guard（Markdown `![](x.svg)` 與 PlantUML 已落地：`SafeSvgImage` 512 KB/2 MB、SSRF every redirect、async local file、4096 px；inline `<svg>` 已由 `SafeSvgText` 支援）。
- [x] code palette + cache 已在 Phase 1B 完成；Phase 4 僅保留主題微調
- [x] l10n ×4：alert/directive 五個標題共用同一組 en/zh/zh_Hans/zh_Hant 字串；SVG/export/preview 錯誤字串待後續。
- [x] SelectCopy 回歸：`SelectCopyPage`／`SelectCopySheet` 直接使用原始 `message.content`，未渲染卡片；alert 與 directive 共用 `MarkdownCalloutCard`，標題以 `SelectionContainer.disabled` 避免手動選取混入。
- [ ] 外觀 QA：light/dark、4 背景、3 氣泡、textScale 1.0/1.5、CJK/emoji/RTL。

**驗收**：§6.1 的功能測試全綠；無 XSS/DoS 高風險項。

### Phase 5：長訊息/效能硬化與決策（3–5 人日）

- [ ] modern `SliverGptMarkdown` 或 block-level lazy（若 Gate 2 通過）。
- [ ] 200 KB 訊息、100 則會話、Android 中階機 benchmark。
- [ ] 修正 regression；更新 `OmniChat 專案開發與維護手冊.md` §3.9/§4/§5。
- [ ] 決定：
  - modern 穩定 → 預設 modern、標記 legacy deprecated、下個 release 刪除。
  - modern 不穩 → 啟動 markstream 移植計畫（另立文件，30–50 人日）。
- [ ] 更新 `THIRD_PARTY_NOTICES.md`（gpt_markdown、vendored JS、若移植 markstream）。

### 5.1 里程碑

| 里程碑 | 內容 | 預估 |
|:--|:--|:--|
| M1 | Phase 0 + 1A：Mermaid/公式/對比 | 8–11 人日 |
| M2 | Phase 1B：長圖/預覽/預處理/code cache | 10–14 人日 |
| M3 | Gate 1：1.4 build spike（Phase 0 後即可並行） | 2–3 人日 |
| M4 | Gate 2：modern parity spike | 7–10 人日 |
| M5 | Phase 4：功能完成（Gate 2 通過 3–5／失敗 6–9：全 legacy 自建） | 3–9 人日 |
| M6 | Phase 5：硬化/決策 | 3–5 人日 |
| **總計** | 不含 markstream fallback；Gate 2 通過 33–48／失敗 36–52 人日 | **33–52 人日** |

> 若只做 P0（M1+M2）即可拿到大部分使用者價值：約 18–25 人日。

**2026-11-04 進度**：M1 核心完成（4 背景 × 3 氣泡對比矩陣已自動化；截圖/實機 QA 待補）；M2 大部分完成（Markdown 預覽本地化與 per-preview 隔離、capture freeze、遠端 settle 已完成；記憶體量測/實機待補）；M3–M6 未開始。

---

## 6. 測試與驗收

### 6.1 測試矩陣

> Golden 策略：不做跨平台 snapshot golden（字型/平台差異太吵）；視覺斷言用 **scoped pixel 斷言**（row-alpha、區域色彩抽樣），截圖僅本機手動對照。

| 區域 | Unit/Widget | Golden/Pixel | Perf | Manual |
|:--|:--|:--|:--|:--|
| Alerts | 5 類型、title、巢狀、串流 | 卡片外觀 | — | light/dark |
| Directives | 5 類型、未知、未閉合 | 卡片外觀 | — | 串流 |
| Inline HTML | 白名單、XSS、malformed | inline 樣式 | — | CJK/emoji |
| Code highlight | cache、fallback、語言映射 | 主題對照 | 10k 行 | 主題切換 |
| Math | `$`/`$$`/`\[`/<code>```math</code>、錯誤 fallback | 裁切 pixel test | 長公式 | textScale |
| SVG | 尺寸/節點/路徑上限、XSS | 正常 SVG | 大 SVG | 網路/本地 |
| Mermaid | 協議、timeout、negative cache | 正常/錯誤 | 冷啟動 | Android 5 s |
| Surface | paired ink、正文對比 | frosted/無氣泡正文 scoped pixel；table 不透明回歸 | — | light/dark |
| Export | 尺寸、接縫、alpha、取消 | 接縫 pixel diff | 100 則 | Windows/Android |
| Streaming | preprocess cache、fast path | 完成前後對照 | 50/200 KB | 60 ms 壓力 |
| Preview | 本地資產、離線、timeout | — | cold/warm | 離線 |

### 6.2 Fixture corpus

`test/fixtures/markdown/`（2026-11-04 已建立基本 corpus）：

- `basic_cjk.md`：中英混合、標點、emoji。
- `alerts.md`：5 類型 + custom title + 巢狀。
- `directives.md`：5 類型 + 未知 + 未閉合。
- `inline_html.md`：b/i/u/mark/kbd/sup/sub/span/font/a/br；XSS payload。
- `inline_svg.md`：安全 inline SVG；含 `script` 的 SVG 顯示 broken-image。
- `tables.md`：escaped pipe、math in cell、alignment、長 cell、CJK。
- `code.md`：多語言、長 code、fence in list、unclosed fence。
- `math.md`：inline/block、tall glyph、<code>```math</code>、invalid TeX。
- `mermaid.md`：flowchart/sequence/gantt、invalid。
- `plantuml.md`：正常/404/超大 SVG。
- `mixed_100kb.md`、`mixed_200kb.md`：串流/長訊息；目前由 `test/perf/markdown_render_bench.dart` 以 `basic_cjk.md` 執行期合成（未另存大檔）。
- `wallpaper.md`：table/quote/code/details 組合。

### 6.3 指令

```bash
flutter analyze
flutter test test/markdown_latex_code_mask_test.dart \
  test/markdown_table_toolbar_test.dart \
  test/mermaid_bitmap_tabs_test.dart \
  test/plantuml_tabs_test.dart \
  test/details_summary_html_test.dart \
  test/code_block_state_retention_test.dart \
  test/markdown_media_sanitizer_test.dart \
  test/inline_math_boundary_test.dart \
  test/markdown_math_clipping_test.dart \
  test/markdown_surface_scope_test.dart \
  test/mermaid_capture_policy_test.dart \
  test/mermaid_failure_cache_test.dart \
  test/markdown_code_cache_test.dart \
  test/markdown_code_palette_test.dart \
  test/markdown_preprocessor_streaming_test.dart \
  test/code_block_streaming_defer_test.dart \
  test/markdown_fixtures_smoke_test.dart \
  test/long_image_export_plan_test.dart \
  test/ai_team_proposals_section_test.dart \
  test/markdown_preview_assets_test.dart \
  test/settings_provider_long_image_tiling_test.dart \
  test/data_sync_local_only_keys_test.dart
# alerts/directives/inline HTML/SVG 測試待 Phase 4 建立
# benchmark（env guard；無 MARKDOWN_BENCH_RUN 時 short-circuit）
for i in 1 2 3 4 5; do MARKDOWN_BENCH_RUN=$i flutter test test/perf/markdown_render_bench.dart; done
```

Windows/Android 手動：

- Windows 11 + WebView2：Mermaid 冷啟動、長圖 100 則、串流選取、theme 切換。
- Android 13/14 中階機：WebView cold start 5 s、長圖、背景圖、textScale 1.5。
- 離線：Markdown preview、Mermaid asset、本地圖片。

### 6.4 效能目標

| 指標 | Baseline | 目標 |
|:--|:--|:--|
| 50 KB 訊息 content pump p95（Windows） | 量測 | ≤16 ms |
| 50 KB 訊息 content pump p95（Android 中階） | 量測 | ≤32 ms |
| 200 KB 首次 render | 量測 | 不退化 >10% |
| preprocess p95（50 KB） | 量測 | legacy fast path <5 ms Desktop / <10 ms Android；modern 路徑 <2 ms |
| code highlight cache hit | 0% | >90%（已完成訊息的重複 build；串流中不適用——未閉合 fence 直接 plain text） |
| Markdown preview cold / warm | 量測 | <1.5 s / <300 ms；offline 可用 |
| 100 則長圖匯出 | 可能失敗 | 成功；預覽 <2 s；無 OOM |

> **2026-11-04 baseline（Windows debug test binding，`basic_cjk` 重複）**：10 KB 2,697 ms、50 KB 17,934 ms、200 KB 240,653 ms（first pump）。此為 test binding 的數字、非 release，且目前只是 single-shot baseline——5 次 fresh process 的 p95 聚合尚未實作；200 KB 的 O(n²) 級成本直接佐證 modern pipeline（Gate 2）的必要性，不能只靠 fast path 解決。
>
> **2026-11-04 實作現況**：preprocess fast path、code cache、長圖 tiling/縮圖、Markdown preview 本地 vendor 已落地；上表的 p95、preview cold/warm 與 100 則長圖仍需 release/實機量測。code cache 命中率的量測情境限「已完成訊息的重複 build」，串流中不適用（未閉合 fence 直接 plain text）。

---

## 7. 風險與回滾

| 風險 | 機率 | 影響 | 緩解 | 觸發回滾 |
|:--|:--|:--|:--|:--|
| gpt_markdown 1.4 `material_ui` 與 Flutter Material 型別衝突 | 中 | 高 | Gate 1 最小 spike；必要時留在 1.3.x + legacy | build 無法在 2 天內修好 |
| modern parser 行為差異（lists/links/`$`/HTML） | 高 | 中 | fixture corpus + feature flag；差異 >5% 即停 | Gate 2 失敗 |
| Gate 2 失敗的代價被低估 | 中 | 中 | Phase 4 估算隨 Gate 分岔（3–5 vs 6–9 人日）；1B 達標時 modern 降為可選 | Phase 3 結束時評估 |
| Windows `SelectionArea`/streaming 崩潰 | 中 | 高 | 保留 legacy 平台守衛；60 ms 壓力測試；不在 streaming 加 SelectionArea | 任一 crash |
| WebView2 COM race（Mermaid） | 中 | 高 | 保留 offscreen bitmap；render-complete；dispose 守衛；失敗重建 | 0xc0000374 重現 |
| 長圖 OOM / 接縫 | 中 | 高 | tiling + 平台上限 + 縮圖預覽；capture 凍結重建 + 逐 tile 守衛；Android 串流編碼為超限預設考量 | OOM/空白圖/接縫 |
| SVG DoS | 中 | 中 | 尺寸/節點/路徑 guard；timeout；拒絕外部引用 | UI 凍結 |
| AGPL/vendored fork 維護 | 低 | 中 | 先不移植；若移植，pin commit + notices + 同步計畫 | 上游 breaking |
| Preview file:// 隔離 | 低 | 低 | 已改為每個 Markdown 預覽獨立 `preview_*` 子目錄 + `<base href="../">`；raw HTML/SVG 走另一個 temp；舊目錄 7 天 best-effort 清理 | 發現跨預覽讀取或清理失敗 |
| Scope creep（雙軌永久化） | 中 | 中 | 明定 legacy 移除 release gate | 超過 2 個 release 仍未收斂 |

**回滾策略**：

- Phase 1A/1B 的 P0 修正直接生效，不依賴 modern flag；modern pipeline 待 `markdown_pipeline_v1`／`MARKDOWN_MODERN` 建立後才啟用（目前尚未建立）。
- 長圖 exporter 保留舊 `_renderWidgetDirectly` 作 fallback（`--dart-define=LONG_IMAGE_TILING=false`，或 runtime `long_image_tiling_v1`；設定頁 Display → Rendering）。
- Mermaid 協議改動**沒有**另存 `mermaid_bridge_legacy.dart`；回滾以 release/git revert 為主，協議向後相容（舊頁面仍可只回傳 bitmap）。
- `MarkdownSurfaceScope` 目前覆蓋聊天氣泡、AI Team 與 export；三者都是 additive wrapper，回退風險低。
- Markdown preview 本地化沒有 runtime flag；回滾以 git revert 為主，vendor 資產不影響舊 HTML（舊版本仍可用 CDN template）。
- 資料層無 migration；回滾不需改 DB。

---

## 8. 工作量與排程

| 階段 | 人日 | 可平行 |
|:--|:--|:--|
| Phase 0 基線 | 2–3 | — |
| Phase 1A Mermaid/公式/對比 | 6–8 | 是（3 軌） |
| Phase 1B 長圖/預覽/預處理/code cache | 10–14 | 是（4 軌） |
| Phase 2 Gate 1 | 2–3 | **是（獨立 spike；Phase 0 後即可與 1A 並行，提早約兩週確定 Phase 4 路徑）** |
| Phase 3 Gate 2 | 7–10 | 部分 |
| Phase 4 功能完成 | 3–5（Gate 2 通過）／6–9（失敗：全 legacy 自建） | 是 |
| Phase 5 硬化/決策 | 3–5 | — |
| **合計** | **33–48（Gate 2 通過）／36–52（失敗）** | 建議 2 人平行 → 約 3.5–5.5 週 |

**若只做 P0（建議先 ship）**：18–25 人日，約 3–4 週（1 人）或 2–2.5 週（2 人）。

**2026-11-04 現況**：Phase 0 護欄與 Phase 1A 核心完成；Phase 1B 的長圖/code cache/串流/預覽本地化（含 per-preview 隔離）與 capture freeze/遠端 settle 完成，剩記憶體量測/實機 baseline；Phase 2–5 未開始。剩餘 P0 主要是實機 baseline 與截圖/視覺 QA。

> 估算為 rough order-of-magnitude（±30%）。Phase 4 的 alerts/directives/HTML/SVG 若 Gate 2 通過（gpt_markdown 1.4 已提供）取下限；Gate 2 失敗時全走 legacy 自建（最貴路徑）取上限 6–9 人日——單一 3–5 人日的估算會低估 Gate 2 失敗的實際代價。

**markstream fallback（另案）**：30–50 人日，6–10 週；不包含在本計畫的承諾範圍。

---

## 9. 不建議 / 暫不導入

1. **全量 markstream 移植（本輪）**：成本/風險不對稱；先走 modern gpt_markdown。若 Gate 2 失敗再啟動。
2. **改用 `flutter_markdown_plus`**：不支援 alerts/directives/HTML/math/SVG/串流 incremental；會直接退步。
3. **把 Mermaid 改成 inline live WebView（Windows）**：與現有 WebView2 COM race 避坑衝突；保留離屏 bitmap。
4. **任意 HTML passthrough**：LLM 輸出不可信；只做白名單子集。
5. **完整 fork `vector_graphics_compiler`**：維護成本高；先用輸入 guard，日後再評估。
6. **Markdown preview 繼續依賴 CDN**：離線/速度都不可接受；已於 2026-11-04 改為本地 vendor（見 §4.7），不再依賴 CDN。
7. **永久雙軌 legacy/modern**：最多存在 2 個 release；必須有移除 gate。
8. **上游 v1.3.3「長會話工具卡效能」為明列 non-goal**：`ProcessGroupCard` 在長對話同樣是渲染熱路徑，本輪不動；若 §6.4 benchmark 顯示其為瓶頸，另案處理——明列以避免日後被當漏項。

---

## 10. 開放問題

1. **產品目標**：要的是「功能/效能對齊」還是「與 kelivo 渲染結果 1:1」？前者可用 modern gpt_markdown；後者才需要 markstream。
2. **Android 最低 WebView 版本**：preview 已改用 classic UMD/IIFE scripts，不再需要 ES module 支援；Mermaid 仍使用既有 asset，舊 WebView 只需支援基本 ES2017。
3. **長圖上限（依平台收斂）**：2026-11-04 實作值 Windows 80 MP／Android 36 MP（涵蓋 1,440×24,000）；超限先降 `effectivePixelRatio`，1x 仍超限才拋錯。Android 逐 tile 串流編碼仍未實作，列後續硬化。方案 A 的最終 `ui.Image` 仍是整張常駐，記憶體上限是本質約束。
4. **新依賴**：`val_latex_flutter` 是 gpt_markdown 1.4.0 硬依賴（Latin Modern 字型 ~1–2 MB 進 APK，Gate 1 實測）；**可選的只是是否改用其 renderer**（公式視覺改為 Latin Modern Math）。`image`（PNG encode）視串流編碼方案而定。
5. **程式碼主題**：2026-11-04 已實作跟隨 app palette（`MarkdownCodePalette`）；是否另提供「經典 GitHub/Atom」選項仍待產品決定。
6. **Directives 範圍**：只支援 `:::note/tip/important/warning/caution/danger`，還是要自訂名稱？自訂名稱需要額外 UI/設定。
7. **Directive title 語法**：`:::note title="x"` 需要自訂 `MarkdownBlockSyntax`（`FencedBlockSyntax` 不支援）；是否接受第一版只支援無 title 的 `:::note`？
8. **Markdown preview vendor 載入策略（已決定）**：採「vendor 解壓到 temp + 每個預覽獨立 `preview_*/index.html` + `<base href="../">` + `loadFile`/`loadUrl`」；不使用 `loadHtmlString` base URL 或 absolute file URL。macOS/iOS 實機仍待驗證。

---

## 附錄 A：上游 commit / 檔案對照

| 區域 | Upstream commit | Upstream 檔案 |
|:--|:--|:--|
| Renderer 替換 | `60b886b` | `dependencies/markstream/**`、`lib/shared/markdown/**` |
| Adapters/wrapper | `2a6e7a9` | `lib/shared/markdown/markdown_with_code_highlight.dart` |
| Streaming | `36d4d9a` | `markstream` renderer / app wrapper |
| Code/table/math/details | `dcc1278` | `markstream/.../render/blocks/*` |
| Alerts/directives | `f72c06c`, `c088f60` | `markstream/.../syntax/alert.dart`、`directive_card.dart` |
| Inline HTML | `3bf2d9e` | `markstream/.../html_block_builder.dart` |
| Bounded SVG | `c088f60` | `dependencies/vector_graphics_compiler/**` |
| Math cache | `039af88` | `lib/shared/markdown/math_adapter.dart` |
| Math clipping | `2df8153` | `markstream/.../blocks/math_block.dart` |
| Mermaid native | `257aca7` | `lib/shared/markdown/diagram_code_blocks.dart`、`mermaid_bridge_stub.dart` |
| Surface contrast | `b5dd009` | `markstream/.../theme/markstream_theme.dart`、renderer |
| Long image export | `b9d54cb` | export capture / long image pipeline |
| Perf benchmark | `4eef28a` | `test/perf/markstream_render_bench.dart` |

## 附錄 B：OmniChat 檔案/符號對照

| 功能 | 檔案 | 符號 |
|:--|:--|:--|
| Markdown 入口 | `lib/shared/widgets/markdown_with_highlight.dart` | `MarkdownWithCodeHighlight`（呼叫點：`chat_message_widget.dart` ×4、`ai_team_proposals_section.dart` ×2、`message_export_sheet.dart` ×2） |
| 預處理 | 同上 | `preprocessFences`、`_maskDollarsInCode`、`_replaceInlineDollarMath` |
| Code block | 同上 + `lib/shared/markdown/markdown_code_cache.dart`、`markdown_code_palette.dart` | `_CollapsibleCodeBlock`、`SelectableHighlightView`、`CodeHighlightCache` |
| Mermaid | 同上 | `_MermaidBlock`、`_MermaidBlockState` |
| PlantUML | `lib/shared/widgets/plantuml_block.dart` | `PlantUMLBlock` |
| Mermaid bridge | `lib/shared/widgets/mermaid_bridge_stub.dart` | `createMermaidView`、`_MermaidInlineWindowsView` |
| Math | `markdown_with_highlight.dart`、`lib/shared/markdown/markdown_math.dart` | `_renderMath`、`LatexBlockScrollableMd`、`ScrollableBlockMath`、`InlineLatex*` |
| Table | 同上 | `EscapeAwareTableMd`、`_wrapTableWithToolbar` |
| Details | 同上 | `DetailsHtmlMd`、`_DetailsHtmlBlock` |
| Preview | `lib/utils/markdown_preview_html.dart`、`markdown_preview_assets.dart`、`assets/html/mark.html` | `MarkdownPreviewHtmlBuilder`、`MarkdownPreviewAssets`（per-preview `preview_*` 子目錄） |
| Export | `lib/features/chat/widgets/message_export_sheet.dart`、`lib/shared/widgets/long_image_exporter.dart` | `_renderWidgetDirectly`、`_renderAndSaveMessageImage`、`LongImageExporter` |
| Surface scope | `lib/shared/markdown/markdown_surface_scope.dart` | `MarkdownSurface`、`MarkdownSurfaceScope` |
| Bubble surface | `lib/features/chat/widgets/chat_message_widget.dart` | `_buildBubbleContainer` |
| Background | `lib/features/home/pages/home_page.dart`、`home_mobile_layout.dart` | `_buildChatBackground`、`MobileBackgroundLayer` |
| Streaming | `lib/features/home/controllers/stream_controller.dart` | `scheduleThrottledUpdate`、`_streamThrottleInterval` |

## 附錄 C：測試檔現況

**已落地（2026-11-04）**

```text
test/markdown_math_clipping_test.dart
test/markdown_surface_scope_test.dart
test/mermaid_capture_policy_test.dart
test/mermaid_failure_cache_test.dart
test/markdown_code_cache_test.dart
test/markdown_code_palette_test.dart
test/markdown_preprocessor_streaming_test.dart
test/code_block_streaming_defer_test.dart
test/markdown_fixtures_smoke_test.dart
test/long_image_export_plan_test.dart
test/markdown_preview_assets_test.dart
test/markdown_surface_contrast_test.dart
test/markdown_alert_test.dart
test/markdown_directive_test.dart
test/markdown_html_policy_test.dart
test/safe_svg_image_test.dart
test/settings_provider_long_image_tiling_test.dart
test/data_sync_local_only_keys_test.dart
test/perf/markdown_render_bench.dart
test/fixtures/markdown/*.md
```

**待新增（Phase 4／剩餘 P0）**

```text
test/markdown_alerts_directives_test.dart
test/markdown_inline_html_test.dart
test/markdown_svg_bounds_test.dart
test/markdown_preview_offline_test.dart    # 若要做 WebView 整合；目前為手動 smoke
test/message_export_long_image_test.dart  # 100 則實機/整合測試
```

---

**文件結束。**
