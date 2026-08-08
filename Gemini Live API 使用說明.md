# Gemini Live API 使用說明

> 更新日期：2026-08（已對照官方文件核實：[Live API 概覽](https://ai.google.dev/gemini-api/docs/live-api)、[SDK 教學](https://ai.google.dev/gemini-api/docs/live-api/get-started-sdk)、[WebSocket 教學](https://ai.google.dev/gemini-api/docs/live-api/get-started-websocket)、[Capabilities](https://ai.google.dev/gemini-api/docs/live-api/capabilities)）
> 本文件為非官方整理，官方文件可能隨時變更，請以官方為準。

## 1. 這是什麼？

Gemini Live API 是 Google 提供的**即時雙向串流 API**（底層為 `BidiGenerateContent` WebSocket），支援**音訊對音訊**的低延遲對話、打斷（barge-in）與即時工具呼叫。適合做語音助理、即時翻譯、對話式 Agent 等應用。它與一般 `generateContent` 是**不同的 endpoint**，Live 模型只能在這裡使用。

> 目前狀態：Live API 官方標記為 **Preview**。官方另推出已正式可用（GA）的 **Interactions API** 並建議新專案優先評估，但即時語音對話目前仍以 Live API 為主。

## 2. 前置準備

| 項目         | 說明                                                                      |
| ---------- | ----------------------------------------------------------------------- |
| API Key    | 到 [AI Studio](https://aistudio.google.com/apikey) 取得，與一般 Gemini API 同一把 |
| Python SDK | `pip install google-genai`（目前 2.16.x）                                  |
| JS SDK     | `npm install @google/genai`；瀏覽器免建置可用 CDN（見 §4）                       |
| 免費額度       | 有免費 tier（token 數受地區與模型影響），多數國家/地區可用                                     |

WebSocket 直連 endpoint（自行實作時用，已驗證正確）：

```
wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=YOUR_API_KEY
```

**兩種實作架構**（官方文件明列）：

- **Server-to-server**：後端用 SDK 連 WebSocket，前端再把串流轉給後端，API Key 不暴露。
- **Client-to-server**：前端直接連 Live API WebSocket（效能較佳、設定簡單），**但 API Key 會暴露在用戶端**。正式環境請改用 **Ephemeral token**，端點為（僅支援 v1beta）：

```
wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContentConstrained?access_token={short-lived-token}
```

（Ephemeral token 需先向 REST API 換取，見官方 [Ephemeral tokens 指南](https://ai.google.dev/gemini-api/docs/live-api/ephemeral-tokens)。）

## 3. Python 快速開始

```python
import asyncio
from google import genai
from google.genai import types

client = genai.Client()  # 會讀 GEMINI_API_KEY 環境變數
model = "gemini-3.1-flash-live-preview"  # 現行 Live 模型，以 AI Studio rate limit 頁面為準

config = types.LiveConnectConfig(
    response_modalities=["AUDIO"],          # 可改 ["TEXT"] 或兩者
    speech_config=types.SpeechConfig(
        voice_config=types.PrebuiltVoiceConfig(voice_name="Kore")
    ),
    realtime_input_config=types.RealtimeInputConfig(
        automatic_activity_detection=types.AutomaticActivityDetection(
            start_of_speech_sensitivity="DEFAULT",
            end_of_speech_sensitivity="DEFAULT",
            prefix_padding_ms=100,
            silence_duration_ms=500,
        )
    ),
)

async def main():
    async with client.aio.live.connect(model=model, config=config) as session:
        print("已連線！")
        # 送文字
        await session.send_realtime_input(text="你好，請用一句話介紹自己")
        # 送音訊（16-bit PCM 16kHz bytes）
        # await session.send_realtime_input(
        #     audio=types.Blob(data=audio_bytes, mime_type="audio/pcm;rate=16000")
        # )
        # 音訊串流暫停時（例如關麥克風），送結束訊號：
        # await session.send_realtime_input(audio_stream_end=True)

        async for response in session.receive():
            sc = response.server_content
            if sc and sc.model_turn:
                for part in sc.model_turn.parts:
                    if part.inline_data:
                        audio = part.inline_data.data
                        print(f"收到音訊區塊：{len(audio)} bytes")
            # 音訊轉錄（需在 config 開啟 input/output_audio_transcription，見 §6）
            if sc:
                if sc.input_transcription:
                    print("我（轉錄）：", sc.input_transcription.text)
                if sc.output_transcription:
                    print("Gemini（轉錄）：", sc.output_transcription.text)
            if sc and sc.turn_complete:
                print("本輪結束")

asyncio.run(main())
```

註：官方範例的 `config` 也可直接傳 dict，例如 `config = {"response_modalities": ["AUDIO"]}`。

## 4. JavaScript 快速開始

```javascript
import { GoogleGenAI, Modality } from '@google/genai';

const ai = new GoogleGenAI({ apiKey: 'YOUR_API_KEY' });  // 或省略以讀 GEMINI_API_KEY
const model = 'gemini-3.1-flash-live-preview';

const session = await ai.live.connect({
  model,
  config: {
    responseModalities: [Modality.AUDIO],
    speechConfig: {
      voiceConfig: { prebuiltVoiceConfig: { voiceName: 'Kore' } }
    }
  },
  callbacks: {
    onopen: () => console.log('連線成功'),
    onmessage: (msg) => {
      const sc = msg.serverContent;
      const parts = sc?.modelTurn?.parts ?? [];
      for (const part of parts) {
        if (part.inlineData) {
          const base64Audio = part.inlineData.data; // 播放此音訊（24kHz PCM base64）
        }
        if (part.text) console.log('Gemini:', part.text);
      }
      // 音訊轉錄（需在 config 開啟 inputAudioTranscription / outputAudioTranscription）
      if (sc?.inputTranscription) console.log('我：', sc.inputTranscription.text);
      if (sc?.outputTranscription) console.log('Gemini：', sc.outputTranscription.text);
    },
    onerror: (e) => console.error(e.message),
    onclose: (e) => console.log('連線關閉', e.code, e.reason), // 1007 通常是 API Key 無效
  },
});

session.sendRealtimeInput({ text: 'Hello from JS!' });
// 送出麥克風 PCM（取代舊的 sendInputAudio({ data }) 寫法）：
// session.sendRealtimeInput({ audio: { data: pcmBase64, mimeType: 'audio/pcm;rate=16000' } });
// 暫停麥克風時送結束訊號：
// session.sendRealtimeInput({ audioStreamEnd: true });
```

**瀏覽器直接使用（免建置）**：

```html
<script type="importmap">
{ "imports": { "@google/genai": "https://cdn.jsdelivr.net/npm/@google/genai@2.16.0/+esm" } }
</script>
<script type="module">
import { GoogleGenAI, Modality } from "@google/genai";
// 其餘同上
</script>
```

## 5. 關鍵設定重點

- **音訊格式**：輸入為 **16-bit little-endian PCM**（原生 16kHz，但 API 會自動重採樣，其他取樣率也可送，MIME 需標明 `audio/pcm;rate=XXXX`）；輸出固定 **24kHz PCM**。
- **回應方式**：`responseModalities` 選 `AUDIO` / `TEXT`；不指定音訊時模型可自行決定。
- **語音**：用 `PrebuiltVoiceConfig` 選內建音色（如 `Kore`、`Puck`、`Charon`、`Fenrir`、`Aoede`、`Leda`、`Orus`、`Zephyr` 等；Live 音色與 TTS 相同，可在 AI Studio 試聽，實際支援依模型而定）。
- **Turn detection（誰該說話）**：預設為**伺服器端自動 VAD**（`realtimeInputConfig.automaticActivityDetection`，可調 `start_of_speech_sensitivity`、`end_of_speech_sensitivity`、`prefix_padding_ms`、`silence_duration_ms`）；也可關閉自動 VAD，改由客戶端用 `activityStart` / `activityEnd` 自行控制。
- **打斷（barge-in）**：預設「使用者一開始說話即中斷模型輸出」；被中斷時伺服器回 `serverContent.interrupted = true`，應用程式應**停止播放並清空音訊佇列**。
- **串流結束**：麥克風暫停超過約 1 秒時應送 `audio_stream_end`（JS：`audioStreamEnd: true`）清掉緩存音訊，之後可隨時恢復串流。

## 6. 進階功能

- **Function calling**：在 `LiveConnectConfig` 的 `tools` 宣告函式 → 模型回傳 `toolCall`（內含 `functionCalls`）→ 你執行後送 `send_tool_response(function_responses=...)` / `sendToolResponse({ functionResponses })` 回去，模型繼續對話。註：非同步（NON_BLOCKING）function calling 目前僅 2.5 模型支援。
- **System instruction**：用 `system_instruction` 設定角色與行為。
- **Session 管理**：連線建立後可長時間複用，直到 `session.close()`；另支援 session resumption 恢復先前對話。
- **音訊轉錄（語音→文字）**：在 config 加 `input_audio_transcription: {}` / `output_audio_transcription: {}`（JS：`inputAudioTranscription` / `outputAudioTranscription`），伺服器會在 `serverContent` 回傳 `input_transcription.text` / `output_transcription.text`（語言自動偵測）。
- **思考等級**：3.1 用 `thinkingConfig.thinkingLevel`（minimal / low / medium / high）；2.5 用 `thinkingConfig.thinkingBudget`（思考 token 數）。可設 `includeThoughts: true` 取得思考摘要。
- **Affective dialog / Proactive audio**：需 `apiVersion: 'v1beta'`，且**目前不支援 3.1 模型**（僅 2.5）。
- **即時翻譯**：`gemini-3.5-live-translate-preview` 提供即時語音對語音翻譯（70+ 語言），見官方 [Live Translation 指南](https://ai.google.dev/gemini-api/docs/live-api/live-translate)。

## 7. 現行 Live 模型（2026-08 查證）

| 模型 | 說明 | 備註 |
| --- | --- | --- |
| `gemini-3.1-flash-live-preview` | 官方目前範例使用的 Live 模型，低延遲語音對話 | 用 `thinkingLevel`；單一事件可含多個 part；`sendClientContent` 僅限初始 context（需設 `initial_history_in_client_content`） |
| `gemini-2.5-flash-native-audio-preview-12-2025` | 上一代旗艦 Live 模型 | 支援非同步 function calling、affective dialog、proactive audio（需 v1beta） |
| `gemini-3.5-live-translate-preview` | 即時語音對語音翻譯 | 70+ 語言 |

> 模型名稱與版本隨時可能變動，**一律以 AI Studio 的 rate limit 頁面顯示的名稱為準**。

## 8. 注意事項

- 免費 tier 的 token 與 RPD（每日請求數）有限，production 建議開啟付費。
- 部分地區不支援，請查 [available regions](https://ai.google.dev/gemini-api/docs/available-regions)。
- **安全性**：瀏覽器直連（client-to-server）時 API Key 會暴露在用戶端，正式環境請改用 **ephemeral token**（見 §2）或後端代理。
- **SDK 版本**：目前 `@google/genai` 為 2.16.x；**3.0.0 起有 breaking changes**（例如移除 `LiveConnectConfig.generation_config`），建議鎖定 `< 3.0.0`。
- Live API 目前為 **Preview**；官方建議新專案評估已 GA 的 **Interactions API**。

## 9. 附錄：實作驗證工具

本文件內容已用同目錄的 `gemini-live-test.html` 實作驗證過：

- 輸入 API Key、選擇模型（已更新為 §7 現行清單）、選擇回應方式與音色
- 支援文字對話、麥克風語音輸入（16kHz PCM 串流）、語音即時播放（24kHz PCM）、音訊轉錄
- 完整日誌顯示連線事件與錯誤碼（例如 code 1007 = API Key 無效）

直接用 Chrome 開啟即可，無需安裝任何套件。
