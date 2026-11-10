# 模型詳細資料：晶片樣式（方案 A）未來採用計畫書

- **狀態**： deferred／未採用（2026-11-10 決策）
- **目前採用**：方案 B — 舊樣式統一（segmented control）
- **適用範圍**：模型詳細資料 → 基本設定分頁的「模型類型、輸入模式、輸出模式、能力」
- **預覽**：`docs/ui_preview/model_detail_unified_compare.html?view=new`
  - 同一份 HTML 的 `?view=old` 是已採用的 B 版；`?view=compare` 可並排比較。

---

## 1. 為什麼先保留方案 A

方案 A 用「膠囊晶片（chip）」統一所有選取控制項：

- 五個輸入模式（文字、圖片、音訊、影片、PDF）可以自然換行。
- 每個模式有圖示，掃描速度比純文字 segmented 快。
- 模型類型、輸出模式、能力可以做成 2-up 晶片，視覺上比五格 segmented 更有層級。
- 未來若再加入新的 modality（例如檔案、程式碼、位置），chip 的擴充性較好。

目前先選 B，主要理由是：

1. 這個面板是設定表單，B 的等寬 segmented 比較像既有設定元件的語言。
2. 五格 segmented 在 390px 寬仍可容納，且視覺密度較高。
3. A 的 chip 若沒有處理好，容易看起來像「標籤」而不是「可選控制項」。
4. 目前沒有 golden test 基礎，先採 B 的風險較低。

---

## 2. 已修正的語義（A 版也必須遵守）

### 2.1 模型類型不是 modality

`ModelType` 維持 `{chat, embedding}`：

- `chat`：走 chat completions／responses。
- `embedding`：走 embeddings，回傳向量。

**不要把 `image` 加進 `ModelType`。** 圖像生成是 `output` modality（`Modality.image`）加上 Images API 路由，不是第三種模型類型。

若未來要支援 TTS、STT、Rerank、純圖像生成等不同端點，應新增完整的 `ModelTask` 類型與 request/response 路由，而不是只加 enum 值。

### 2.2 PDF 模式＝原生 PDF

- `Modality.pdf` 的語義是「模型可以接受原生 PDF 文件區塊」。
- 文字擷取是**所有文字模型的自動 fallback**，不是一個可選模式。
- 因此 UI 不應再出現「PDF 傳送方式：原生檔案／文字擷取」的選擇。
- 若 host 不支援原生 PDF，policy 自動退回文字擷取；不需要使用者手動切換。
- 若需要保留 per-model host-gate override，只能放在進階設定，並且要標示為「覆寫」而不是「模式」。

### 2.3 音訊沒有文字 fallback

- `Modality.audio` 開啟即代表原生音訊區塊。
- 不應顯示「音訊將以原生區塊送出（沒有文字替代）」這類廢話提示。
- 若 host 不支援，直接由 policy 剝除並在送出前提示，不需要在基本分頁常駐說明。

---

## 3. 視覺規格

### 3.1 Chip anatomy

| 屬性 | 規格 |
|---|---|
| 高度 | 35–40dp（建議 40dp 以符合觸控） |
| 圓角 | 10dp |
| 水平 padding | 10dp |
| icon | 14dp，與 label 間距 5dp |
| label | 12.2–12.5sp，w600 |
| 未選取背景 | light: `surface`／dark: `white10` |
| 未選取邊框 | `outlineVariant` 35% |
| 選取背景 | light: `primary` 14%／dark: `primary` 20% |
| 選取邊框 | `primary` 45% |
| 選取文字／icon | `primary` |
| hover | 上移 1dp、primary 45% 邊框、淡陰影 |
| pressed | scale 0.975 |
| 動畫 | 150–160ms ease |

### 3.2 Layout

- **二元選項**（模型類型、輸出模式、能力）：2-up，`Expanded` 或 `flex: 1`，讓兩個晶片填滿列寬。
- **五個輸入模式**：`Wrap(spacing: 6, runSpacing: 6)`，content-width chip；窄寬度自然換行。
- **不要**把五個輸入模式做成 2-up grid，否則會失去 chip 的流動感。
- 模型類型、能力若用 content-width chip，會看起來像散落的標籤；必須 2-up 填滿。

### 3.3 顏色與對比

- 選取狀態不能只靠顏色。建議在 chip 內加入：
  - `Semantics(selected: true)`；
  - 或選取時在 label 左側加一個 12dp check（會讓 chip 變成「有狀態的 chip」而不是 tag）。
- 若不加 check，至少要有 primary 邊框 + 背景 + 粗體三層差異。
- 深色模式下 primary 是 `#B6C4FF`，選取背景用 20% opacity；不要用 light 模式的 14%。

---

## 4. Flutter 實作建議

### 4.1 新增通用元件

建議新增 private widget：

```dart
class _ChoiceChipGroup<T> extends StatelessWidget {
  const _ChoiceChipGroup({
    required this.options,
    required this.selected,
    required this.onToggle,
    this.multiSelect = true,
    this.fill = false,
  });
}
```

或拆成：

- `_ChoiceChip`：單顆 chip 的視覺與互動。
- `_ChoiceChipGroup<T>`：排列、selected 狀態、2-up/Wrap。

不建議直接在 `model_detail_sheet.dart` 內複製五次 chip 實作。

### 4.2 映射

| 群組 | 選項 | 排列 |
|---|---|---|
| 模型類型 | `ModelType.chat` / `embedding` | 2-up，單選 |
| 輸入模式 | `Modality.values` | Wrap，多選，至少一個 |
| 輸出模式 | `text` / `image` | 2-up，多選，至少一個 |
| 能力 | `tool` / `reasoning` | 2-up，多選，可為空 |

### 4.3 與 B 的切換

- 不需要改資料模型：`Set<Modality>`、`Set<ModelAbility>`、`ModelType` 都不變。
- 不需要改 override schema。
- 只需要把 `_buildBasic` 內的四個控制項換成 chip group。
- 若要 A/B 可切換，建議用 compile-time flag 或 settings flag，不要同時渲染兩套。

---

## 5. 無障礙與測試

### 5.1 Accessibility

- 每个 chip 必須是 `Semantics(button: true, selected: ...)`。
- 最小觸控目標 44×44dp；若視覺高度 35dp，用 `MaterialTapTargetSize.padded` 或外層 padding 補足。
- 鍵盤／遙控器 focus 要有明顯 ring。
- 不要只用顏色區分 selected；至少加 check 或 `selected` semantics。

### 5.2 Widget tests

- 模型類型：chat ↔ embedding 切換，embedding 時隱藏輸入／輸出／能力。
- 輸入模式：五個 chip 全部可點；取消最後一個時自動回到 text。
- 輸出模式：text/image 至少一個。
- 能力：可全部取消。
- 寬度 360／390／430dp：五個 chip 不 overflow，Wrap 行數符合預期。
- 深色／淺色：selected 對比通過。
- Golden tests：基本分頁、embedding 狀態、深色模式。

---

## 6. 風險與對策

| 風險 | 對策 |
|---|---|
| chip 看起來像 tag，不像控制項 | 2-up 填滿、selected check、hover/pressed 動畫 |
| 五個 chip 在窄螢幕換行造成高度跳動 | 使用 `Wrap`，預留最小高度；golden test 360dp |
| 只用顏色表達 selected | 加 check 或 selected semantics |
| 與既有 segmented 混用造成不一致 | 只在這個面板使用 chip；tabs 仍用 segmented（導航不是選取控制項） |
| 未來 modality 增加 | chip group 以 `List<Modality>` 驅動，不寫死五個 |
| 使用者懷念 B 的密度 | 提供 settings flag 或只在桌面寬度使用 A |

---

## 7. 實作步驟（若未來重啟）

1. 新增 `_ChoiceChipGroup<T>` 與 `_ChoiceChip`。
2. 在 `model_detail_sheet.dart` 的 `_buildBasic` 替換四個控制項。
3. 保留 `_SegmentedSingle`／`_SegmentedMulti` 給 tabs 或其他設定頁。
4. 加 `Semantics` 與 44dp tap target。
5. 加 widget tests 與 golden tests（360/390/430、light/dark）。
6. 在 `docs/` 更新決策紀錄，標記 A 已啟用。
7. 若視覺不理想，rollback 只需把 `_buildBasic` 換回 `_SegmentedSingle`／`_SegmentedMulti`。

---

## 8. 決策紀錄

| 日期 | 決策 | 理由 |
|---|---|---|
| 2026-11-10 | 採用 B（舊樣式統一） | 與既有設定頁一致、密度高、五格在 390dp 可容納 |
| 2026-11-10 | A 先存檔，不實作 | chip 需要更多 golden/accessibility 工作；目前無迫切需求 |
| 2026-11-10 | PDF 模式＝原生 PDF；文字擷取為 fallback | 避免「PDF 模式 + 文字擷取」與純文字模式語義重疊 |
| 2026-11-10 | 移除基本分頁的原生輸入區塊與音訊提示 | 能力與傳送方式分離；音訊沒有 fallback，提示是廢話 |

---

## 9. 參考

- 預覽：`docs/ui_preview/model_detail_unified_compare.html?view=new`
- 目前實作：`lib/features/model/widgets/model_detail_sheet.dart`
- 能力推斷：`lib/core/providers/model_provider.dart`
- 原生輸入 policy：`lib/core/services/api/native_input_policy.dart`
- 原生輸入 serializer：`lib/core/services/api/native_input_parts.dart`
