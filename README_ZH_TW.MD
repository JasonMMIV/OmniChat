# OmniChat

> 功能豐富的跨平台 LLM 聊天應用程式

[English](README.md) | 繁體中文

---

<p align="center">
  <img src="Screenshots/Windows.jpg" alt="OmniChat 桌面端介面" width="90%" />
</p>

OmniChat 是一款現代化、功能豐富的 AI 聊天軟體，專為文字檔案編輯、深度研究、AI團隊協作、流暢的語音互動與跨平台體驗而設計。

---

## ✨ 核心特色

### 📁 工作區 (Workspace)

讓 AI 直接存取您的檔案，透過安全沙箱工作區進行操作：

- **基本檔案操作**：在用戶指定的目錄內進行讀取、寫入、追加、刪除、移動、複製、搜尋及列出檔案 — 全部透過 LLM 的 function calling 完成。
- **文字檔案編輯**：支援精確文字替換 (`file_edit`) 與 unified diff 補丁 (`file_patch`) 兩種編輯模式，並具備自動衝突檢測。
- **文件文字抽取**：透過 `file_extract_text` 從 **PDF**、**Word (DOCX)**、**PowerPoint (PPTX)** 與 **Excel (XLSX)** 文件中抽取可讀文字 — 非常適合摘要報告、履歷、簡報與試算表內容。DOCX / PPTX / XLSX 中的表格會以 **Markdown 表格**（`| 欄位A | 欄位B |`）輸出並附上表頭分隔線，XLSX 工作表會以名稱標記（`--- Sheet N (name) ---`）。大型文件可使用 `next_offset` 分段續讀；掃描型 PDF（純圖片）不支援 OCR。
- **壓縮檔解壓縮**：透過 `file_extract_zip` 將 `.zip` 壓縮檔解壓縮至工作區 — 每個條目路徑都會驗證是否侷限於工作區內（防 Zip-Slip），危險檔案類型會被阻擋，並限制總解壓大小與檔案數量。
- **PDF 報表生成**：透過 `file_create_pdf` 直接在工作區生成排版精美的 PDF — 支援標題、粗體/斜體、清單、表格、程式碼區塊與頁碼，內建簡中/繁中字型渲染（無需內嵌字型檔）。
- **常用檔案類型**：聊天上傳支援**任何檔案類型** — `.txt`、`.md`、`.json`、`.csv`、`.yaml`、`.xml`、`.html`、`.svg`、`.py`、`.js`、`.ts`、`.dart`、`.sql`、原始碼、壓縮檔等。文字類檔案會直接內嵌給模型閱讀；**PDF / DOCX / PPTX / XLSX** 文件則會自動抽取文字內容。
- **靈活配置**：可設定全域預設目錄、個別專案工作區或單一對話覆寫設定。支援 Android 與 Windows 平台。

<p align="center">
  <img src="Screenshots/Workspace_1.jpg" alt="工作區設定" width="30%" />
   
  <img src="Screenshots/Workspace_2.jpg" alt="工作區檔案卡片" width="30%" />
   
  <img src="Screenshots/Workspace_3.jpg" alt="工作區檔案瀏覽器" width="30%" />
</p>

---

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

### 🔬 深度研究

專為複雜探索與學術/技術調研設計的預置 AI 助手：

- **Think & Search 雙驅動**：結合多輪深度推理與聯網搜尋，依據當前思維盲點自動生成精準搜尋語義，並由搜尋結果驅動下一輪深化推理。
- **認識論紀律 **：嚴格區分「客觀證據 」、「合理推論 」與「主觀判斷 」，拒絕將假設誤標為事實。
- **嚴謹終止條件與引用**：動態評估資訊飽和度與反例測試結果，產出附帶可追溯引用來源與認知誠實標記的專業調研報告。

---

### 📚 學術搜尋

內建學術搜尋服務，將三大免費學術資料庫直接整合至搜尋功能中：

- **arXiv**：透過官方 arXiv API 搜尋預印本論文 — 無需 API 金鑰或註冊，並自動套用速率限制（每 3 秒最多一次請求）。
- **PubMed（E-utilities）**：以 esearch → efetch 兩階段流程，回傳 NCBI 論文的標題與摘要。
- **Semantic Scholar**：透過 Academic Graph API 搜尋論文，並以優雅的方式處理速率限制訊息。

三大服務皆可開箱即用；PubMed 與 Semantic Scholar 可選填 API 金鑰以提升速率限制。所有介面（行動版與桌面版）均顯示官方品牌圖示。

---

### 🌐 進階聯網搜尋與本地工具

- **進階聯網搜尋**：整合 Tinyfish Search API、Google Search API 與多種搜尋引擎，提供更精準、高品質的即時聯網資訊。
- **內建語音聽寫**：支援在聊天輸入欄直接進行語音聽寫，提供完整的繁簡中、英文語系支援。
- **本地 JavaScript MCP**：安全沙盒環境 (QuickJS/JavaScriptCore)，允許 AI 本地執行程式碼進行複雜運算與資料處理。

---

### 🛠️ 自訂輸入列按鈕

依照個人工作流程打造聊天輸入列,手機與桌面板共用同一套設定:

- **拖曳調整順序**:在「設定 → 顯示設定 → 輸入列按鈕」中自由排列輸入列按鈕(模型選擇、聯網搜尋、MCP、快捷短語、語音聽寫、相機/相簿、上傳檔案、深度思考、AI 團隊、指令注入、語音聊天、上下文管理、OCR)。
- **顯示/隱藏開關**:可隱藏不常用的按鈕;平台專屬按鈕(手機的相機/相簿、桌面的上傳檔案/OCR)僅在對應平台顯示。
- **一鍵重置**:隨時恢復預設的順序與顯示狀態。

---

## 💻 跨平台支援

無論在桌面或行動裝置，享受一致且順暢的體驗：

- **Windows**
- **Android**
