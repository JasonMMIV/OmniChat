# 導入 kelivo v1.1.13–v1.1.17 Markdown 渲染功能評估

> 評估日期：2026-08-15　｜　對照上游：`Chevey339/kelivo` tags `v1.1.13` / `v1.1.15` / `v1.1.16` / `v1.1.17`
> 對照下游：OmniChat `v1.17.3+84`
>
> **修訂紀錄（2026-08-15 二輪驗證）**：
> 1. Mermaid 建議由「暫緩」升為 **P2 可導入**——修正記憶體論述（訊息清單為 `ListView.builder` 虛擬化、無 keep-alive，**不存在「大量活體 WebView 常駐」**），真實缺口為「滾動時 WebView2 反覆 mount/unmount churn + 無 Tab/全螢幕互動」；且 `mermaid_exporter.dart` 已有同款渲染→快取路徑，移植成本低於初估。
> 2. 行內數學優先導入**閉合邊界**（修貨幣誤判，最高頻），CJK 邊界語意更正為「**精度改善**」：OmniChat 對 `已知，$x+y=1$` 等 CJK 緊鄰**本就解析正常**（無邊界檢查＝過度匹配），非「CJK 標點無法開啟」。
> 3. `EscapeAwareBoldMd/ItalicMd` 等系列更正為「**反斜線轉義感知**（`(?<![\\s\\])` 守閉合標記）」而非數學保護；OmniChat 數學 component 註冊於 Bold/Italic 之前（gpt_markdown 先匹配先贏）已免疫 `$x_1 * x_2$` 漏 `*`/`_` 干擾 → 不需導入。
> 4. 關鍵 commit 已定位：`2d08a5d3`（CJK/數學邊界）、`29675371`（表格數學與轉義管線）、`25b4b127`（scrollable inline math）均在 v1.1.16；Mermaid bitmap-first 在 v1.1.15。
> 5. **表格 toolbar 設計決定**：kelivo 的 toolbar 僅在 compact 模式顯示（`useCompactTable = !isDesktop || maxWidth < 520`，桌面寬視窗無 toolbar——實測 Windows 版確認）。OmniChat 採**比照 code block 標頭**的 toolbar（桌面/行動一致顯示），動作含**複製 markdown** 與**匯出 .md**（非 CSV，`toMarkdown()` 已存在），**省略預覽按鈕**（表格已直接渲染）。
> 6. **Mermaid 導入範圍（2026-08-15 決定，後續更新）**：① image/code **雙分頁導入**（確認「圖片/程式碼」tab 即 `_MermaidTab{image,code}`）；② **全螢幕互動導入**（`_openMermaidImageViewer` 點圖開 `ImageViewerPage`——捏合縮放/平移/存圖簿納入範圍，稍早曾排除、已反轉）；③ **既有 mermaid toolbar 已調整**（已完成）：移除「下載 .mmd」按鈕、PNG 下載按鈕補上「下載」標籤。

## 1. 上游基礎差異（關鍵前提）

- kelivo **v1.1.12 起**才與 OmniChat 同用 pub.dev `gpt_markdown: ^1.1.4`；**v1.1.13 起**改為本地 vendored fork（`dependencies/gpt_markdown`，版本 **1.1.7**）。
- 該 fork 的 lib 檔案（`gpt_markdown.dart` / `markdown_component.dart` / `theme.dart` / `markdown_config.dart`）在 **v1.1.13 → v1.1.17 之間 SHA 完全相同**——引擎本體零變動。
- 比對 pub.dev `gpt_markdown 1.1.4` 與 1.1.7 的公開 API 表面（gpt_markdown.dart）為**空 diff** → 1.1.4→1.1.7/1.1.8 升級無 breaking change。
- **結論**：v1.1.13–v1.1.17 的全部 Markdown 功能都落在**應用層**（kelivo `markdown_with_highlight.dart` 2686 → 5606 行、`plantuml_block.dart` 257 → 464 行），移植即移植應用層程式碼，**無需 fork 套件**。

## 2. 逐項評估

### v1.1.13

| 項目 | 上游實作 | OmniChat 現況 | 建議 |
|---|---|---|---|
| HTML `<details>/<summary>`（巢狀深度 6、`open` 屬性） | `DetailsHtmlMd extends BlockMd`（遞迴 pattern）+ `_DetailsHtmlBlock`（StatefulWidget，`IosCardPress`、AnimatedRotation） | **完全沒有**（全專案 `details`/`summary` 0 命中） | **導入（P0）**——GPT-5.x/Claude 日益輸出 `<details>` 折疊內容 |
| HTML `<a href>` 標籤 | `HtmlAnchorMd extends InlineMd`（解析 `<a href="…">text</a>`） | 僅 markdown 語法 `[text](url)`（`LineSafeLinkMd`），無 raw `<a>` | **導入（P0）** |
| 程式碼區塊體驗 | `_codeBlockStateKey(language, code)`（streaming 重建保留展開/收合）、`_codeBlockBorderColor`、collapsed highlighted preview | 有 copy/download/preview（`_downloadExtensionFor`/`_isPreviewable`），但**無狀態保留 key**——streaming 每 chunk 重建會重置收合狀態 | **導入（P1，小改）** |
| 表格 toolbar（複製/匯出） | kelivo v1.1.13 起表格上方 header bar（`rows.toCsv()` 匯出）；v1.1.15 擴充為 toolbar（複製 markdown／複製圖片／匯出 CSV／存圖片）。**僅 compact 模式顯示**（`useCompactTable = !isDesktopPlatform \|\| constraints.maxWidth < 520`）——桌面寬視窗無 toolbar（實測 Windows 版無 toolbar 之原因） | `tableBuilder` 只渲染表格、**無任何按鈕**；「下載」按鈕僅在 code block（下載的是原始碼文字，與表格資料匯出**不重複**）；mobile 端表格包在 `SelectionContainer.disabled` 內無法選取複製 | **導入（P1）**——**設計決定**：比照 OmniChat code block 標頭 toolbar（語言標籤 + 動作列），**桌面/行動一致顯示**（不採 kelivo 的 compact-only）；動作含**複製 markdown** 與**匯出 .md**（比 CSV 邏輯一致，`toMarkdown()` 已存在），省略**預覽按鈕**（表格已直接渲染，預覽多此一舉） |

### v1.1.15

| 項目 | 上游實作 | OmniChat 現況 | 建議 |
|---|---|---|---|
| Mermaid 渲染穩定度 | `MermaidBitmapRenderStatus/RenderResult` + `debugMermaidBitmapRenderOverride`（測試 seam）+ image/code 雙分頁 + `_renderQueued/_renderingBitmap`——**bitmap 優先（暫存 Overlay WebView2 渲染 → 快取 → `Image.memory`）、失敗回退 code tab** | 顯示走 live WebView2（`createMermaidView`），`MermaidImageCache` 僅匯出時寫入（`mermaid_exporter.dart`）；Windows crash 已另以 streaming 延遲 WebView2 + `WM_GETOBJECT` 攔截防護（v1.5.26–v1.5.29）。**訊息清單為 `ListView.builder` 虛擬化且無 keep-alive**——無「大量活體 WebView 常駐」，但每個可見圖表釘住一個原生 WebView、滾動時反覆 mount/unmount 有 jank。既有 toolbar：複製＋下載 .mmd＋PNG 下載（僅圖示） | **導入（P2，範圍已確認）**——① **image/code 雙分頁導入**；② **全螢幕檢視導入**（`_openMermaidImageViewer` 點圖開 `ImageViewerPage`，含捏合縮放/平移/存圖簿）；③ 既有 toolbar 已調整（2026-08-15 完成：移除 .mmd 下載、PNG 下載補「下載」標籤）；`mermaid_exporter.dart` 渲染路徑可複用 |
| 行內數學渲染 | `_maxInlineMathBodyLength = 512`（UI 執行緒 lookahead 上限）+ `_isDollarMathOnMarkdownTableRow`（表格列不當 `$` 數學）+ `_canCloseDollarMath` 閉合邊界 + `_isValidDollarMathBody(allowUnescapedPipes)` | `preprocessFences` 以 regex `(?<!\$)\$([^\$\n]+?)\$(?!\$)` 將 `$...$` 轉 `\(...\)`——**無長度上限、無表格感知、無閉合邊界**。實測 "Price is $5 and total is $10" → 誤轉 `\(5 and total is \)`（**最高頻 bug**） | **導入（P0）**——優先導入**閉合邊界**（修貨幣誤判）＋ 表格列 `|` 保護 ＋ 512 lookahead 上限 |

### v1.1.16

| 項目 | 上游實作 | OmniChat 現況 | 建議 |
|---|---|---|---|
| 表格分隔符處理 | `EscapeAwareTableMd` + `_findClosingDollarMathInTableCell/_findClosingParenMathInTableCell`（cell 範圍內允許未轉義 `|`） | cell 分割發生在套件 `TableMd`，cell 內含 `|` 的數學無法渲染 | **隨行內數學同捆導入（P0）** |
| 行內 LaTeX（`_InlineMathScrollable`） | 自訂 render object 水平捲動、保留 baseline（`GestureDetector` + `RenderProxyBox`，約 90 行） | 已有 `LayoutBuilder + SingleChildScrollView` 包 inline math（功能等效、每 span 元素樹較重） | **不導入（獨立項目）**——行為已等效；「順帶採用」＝ P0 行內數學重構改寫同一路徑時，可順手換成 kelivo 的 render-object 版（drag 捲動、無 ScrollView 開銷），不另立工項 |
| CJK 相容邊界 | `_canOpenDollarMath/_canCloseDollarMath`：`$` 前後須 whitespace/ASCII 標點/Unicode 標點/**CJK 字元**；`范围$\pm 2$`、`（$PaCO_2$` 成立、`abc$x$` 不成立、閉合 `$` 前為空白則拒絕閉合 | OmniChat regex 無邊界要求——`已知，$x+y=1$` 等 CJK 緊鄰**本就解析正常**（不是「無法開啟」）；真實缺口是**過度匹配**（貨幣 `$5 ... $`、`abc$x$`、`\$x$` 轉義盲點） | **隨行內數學導入（P0）**——語意是「**精度改善**」而非「修 CJK 解析失敗」 |
| 程式碼區塊控制 | `EscapeAwareTableMd/BoldMd/ItalicMd/ImageMd/HighlightedTextMd`（`(?<![\\s\\])` 反斜線轉義感知系列） | `_maskDollarsInCode`（v1.17.1 已移植）已覆蓋 `$` 遮罩；OmniChat 數學 component 註冊於 Bold/Italic 之前（gpt_markdown 合併 regex 先匹配先贏）→ `$x_1 * x_2$` 整段被數學 component 吞掉，`*`/`_` 不會漏出觸發斜體/粗體 | **選配（低效益）**——EscapeAware 系列本質是**轉義感知**、非數學保護，OmniChat 已免疫主要干擾 |
| PlantUML 區塊樣式 | `_PlantUMLTab{image,code}` 分頁 + `_PlantUMLBlockColors` 主題 + 406px 預覽高度 + `ExportCaptureScope` | `plantuml_block.dart` 265 行（= kelivo v1.1.15 舊版） | **選配（P2，純視覺）** |

### v1.1.17

| 項目 | 上游實作 | OmniChat 現況 | 建議 |
|---|---|---|---|
| fenced code 內 HTML 誤解析 | `_maskHtmlTagStartsInsideFencedCode`（`<` → `\uE002` 遮罩、渲染時還原） | 目前無 `DetailsHtmlMd`，此 bug 主要由 v1.1.13 的 details pattern 吞 fenced code 內容觸發 | **隨 details/summary 同捆導入（P0）** |
| TeX hex color `#` 轉義 | 修 kelivo 自己的 `_escapeLatex` 把 `\color{#RRGGBB}` 的 `#` 誤轉 `\#` | **OmniChat 無 `_escapeLatex`**（lib/ 全域無 TeX `#` 轉義，原樣送 `Math.tex()`） | **不適用，跳過** |

## 3. 附帶建議：gpt_markdown 1.1.4 → 1.1.8

- 公開 API 相容（已驗證空 diff）；1.1.5 修 block latex 語法、1.1.7 修跨行 bold（dotAll）與 link 樣式一致性、1.1.8 修「單換行連續連結」。
- OmniChat `preprocessFences` step 8 正是 1.1.8 所修問題的 workaround → 升級後可驗證是否可簡化。
- 獨立於 kelivo 移植的低風險升級，需跑完整測試套件確認無回歸。

## 4. 結論與建議優先序

| 優先 | 項目 | 來源 | 預估成本 |
|---|---|---|---|
| P0 | 行內數學加固（**閉合邊界修貨幣誤判** ＋ 表格 cell `|` 保護 ＋ 512 lookahead 上限 ＋ CJK/Latin 邊界精度） | v1.1.15 / v1.1.16 | 中 |
| P0 | `<details>/<summary>` + `<a href>` + fenced code HTML 遮罩（同捆） | v1.1.13 / v1.1.17 | 中 |
| P1 | 程式碼區塊狀態保留（`_codeBlockStateKey`） | v1.1.13 | 低 |
| P1 | 表格 toolbar（複製/匯出 markdown，比照 code block 樣式、桌面/行動一致、無預覽） | v1.1.13 | 低 |
| P2 | PlantUML 分頁樣式 | v1.1.16 | 中 |
| P2 | gpt_markdown 1.1.4 → 1.1.8 升級 | — | 低 |
| P2 | Mermaid bitmap-first（**image/code 雙分頁 ＋ 點圖全螢幕檢視**；toolbar 已先調整） | v1.1.15 | 中（可複用 `mermaid_exporter.dart` 渲染路徑） |
| 跳過 | TeX `#` 轉義修復 | v1.1.17 | 不適用 |

## 5. 移植注意事項

- **訊息清單為 `ListView.builder` 虛擬化（無 keep-alive）**：Mermaid 記憶體論述應以「每個可見圖表釘住原生 WebView ＋ 滾動 mount/unmount churn」為準，**勿宣稱「大量活體 WebView 常駐」**（滾出視口即 dispose）。
- **關鍵 commit 定位**：行內數學/CJK 邊界 = `2d08a5d3`、表格數學與轉義管線 = `29675371`、scrollable inline math = `25b4b127`（皆 v1.1.16）；Mermaid bitmap-first = v1.1.15。移植可直接以這些 commit 為 diff 基準。
- **Mermaid 移植路徑**：把 `mermaid_exporter.dart` 既有「渲染→`MermaidImageCache`」提升為主要顯示路徑（暫存 Overlay WebView2 → `Image.memory`），另加 image/code 分頁與點圖開 `ImageViewerPage`；失敗時回退 code tab。
- OmniChat 已具備 `ios_tactile.dart`、`plantuml_encoder.dart`、`clipboard_images.dart`、`export_capture_scope.dart` 等上游功能依賴，移植無前置缺件。
- 移植時不得直接覆寫 `markdown_with_highlight.dart`（OmniChat 已含 v1.1.6/7 的 `_maskDollarsInCode`、`unmaskCodeDollars` 等客製化，與 kelivo 新版行內數學 scanner 需整合而非取代）。
- 行內數學路徑在 OmniChat 是「`preprocessFences` 先 `$`→`\(` 轉換 + 兩個 InlineMd component 兜底」，與 kelivo v1.1.15+ 的「app 層自寫 scanner」不同——移植應把 v1.1.15/16 的邊界判斷移植進 `preprocessFences` 的 `$`→`\(` 轉換（表格列除外），而非複製 kelivo 的整套 scanner。
