# OmniChat

> 支援 AI 團隊與深度研究的跨平台 LLM 聊天應用程式

[English](README.md) | 繁體中文

---

<p align="center">
  <img src="Screenshots/Windows.jpg" alt="OmniChat 桌面端介面" width="90%" />
</p>

OmniChat 是一款現代化、功能豐富的 AI 聊天軟體，專為流暢的語音互動、深度研究、團隊協作與跨平台體驗而設計。

---

## ✨ 核心特色

### 🤖 AI 團隊（混合智能體）

支援兩種強大的多模型協作架構，為複雜問題提供深度的分析與解答：

- **並列式 (MoA)**：協調 1–4 個「提案模型」平行探索問題，再由「彙整模型」將多方觀點融匯成一份更完整、更精準的回答。
- **鍊式 (CMoA)**：結合「提案 -> 自我審計 (0~3 輪) -> 最終彙整」的多輪思維鏈。審計模型運用 7 大分析透鏡（對抗式、因果/結構式、比較式、時間軸等）進行反思與自我質疑，確保推論高度扎實。
- **即時呈現**：所有提案與審計推論過程皆即時流式渲染，並提供獨立折疊區塊便於追蹤。

<p align="center">
  <img src="Screenshots/AI_TEAM.jpg" alt="AI 團隊介面" width="30%" />
</p>

---

### 🎨 自訂新對話開場與 AI 動態問候語

打造個性化的新對話頁面體驗：

- **彈性 Logo 與圖示選擇**：可自由切換 OmniChat 官方圖示、當前 AI 模型圖示、自訂上傳圖片或隱藏 Logo。
- **Zero-Latency AI 動態問候語**：啟動 App 時於背景自動快取由 AI 生成的溫馨問候語，開場即刻顯示無延遲。
- **專屬問候語模型與提示詞**：可獨立設定問候語生成模型，並客製化提示詞與思考預算（Enable Thinking）。
- **美觀視覺佈局**：優化放大 Logo 比重與粗體文字佈局，帶來大氣現代的首頁質感。

<p align="center">
  <img src="Screenshots/Customizable_New_Chat_Empty_State_1.jpg" alt="自訂開場頁面 1" width="30%" />
  &nbsp;&nbsp;
  <img src="Screenshots/Customizable_New_Chat_Empty_State_2.jpg" alt="自訂開場頁面 2" width="30%" />
</p>

---

### 🎙️ 即時語音聊天

打造如同打電話般的 AI 對話體驗：

- **廣泛模型支援**：相容於各類 LLM 模型，選擇您偏好的 AI 助手。
- **藍牙通話模式**：針對藍牙耳機優化，支援通話模式 (Call Mode) 音訊路由，體驗更佳。
- **原生語音辨識**：整合系統原生 STT (Speech-to-Text) 引擎，辨識更精準快速。

<p align="center">
  <img src="Screenshots/Voice_Chat.jpg" alt="即時語音聊天介面" width="30%" />
</p>

---

### 💳 帳戶餘額監控

無需切換頁面，直接在「模型選擇選單」與「供應商設定」中即時查看剩餘額度（包含 OpenAI, Gemini, DeepSeek, OpenRouter, Neuralwatt 等），輕鬆掌握 API 使用狀況。

<p align="center">
  <img src="Screenshots/Account_Balance.jpg" alt="帳戶餘額監控" width="30%" />
</p>

---

### 🔬 Deep Research（深度研究）

專為複雜探索與學術/技術調研設計的預置 AI 助手：

- **Think & Search 雙驅動**：結合多輪深度推理與聯網搜尋（Web Search），依據當前思維盲點自動生成精準搜尋語義，並由搜尋結果驅動下一輪深化推理。
- **認識論紀律 (Epistemic Discipline)**：嚴格區分「客觀證據 (Evidence)」、「合理推論 (Inference)」與「主觀判斷 (Judgment)」，拒絕將假設誤標為事實。
- **嚴謹終止條件與引用**：動態評估資訊飽和度與反例測試結果，產出附帶可追溯引用來源（Citations）與認知誠實 (Epistemic Honesty) 標記的專業調研報告。

---

### 🌐 進階聯網搜尋與本地工具

- **進階聯網搜尋**：整合 Tinyfish Search API、Google Search API 與多種搜尋引擎，提供更精準、高品質的即時聯網資訊。
- **內建語音聽寫**：支援在聊天輸入欄直接進行語音聽寫，提供完整的繁簡中、英文語系支援。
- **本地 JavaScript MCP**：安全沙盒環境 (QuickJS/JavaScriptCore)，允許 AI 本地執行程式碼進行複雜運算與資料處理。

---

## 💻 跨平台支援

無論在桌面或行動裝置，享受一致且順暢的體驗：

- **Windows**
- **Android**
