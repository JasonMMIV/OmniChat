# OmniChat

> Cross-Platform LLM Chat Application with abundant features

English | [繁體中文](README_ZH_TW.MD)

---

<p align="center">
  <img src="Screenshots/Windows.jpg" alt="OmniChat Desktop Interface" width="90%" />
</p>

OmniChat is a modern, feature-rich AI chat application designed for text file editing,  deep research, multi-agent collaboration, seamless voice interaction, and a unified cross-platform experience.

---

## ✨ Key Features

### 📁 Workspace

Give AI direct access to your files with a secure, sandboxed Workspace:

- **Basic File Operations**: Read, write, append, delete, move, copy, search, and list files within a user-defined directory — all through the LLM's function calling.
- **Text File Editing**: Fine-grained edits via literal text replacement (`file_edit`) and unified diff patching (`file_patch`), with automatic conflict detection.
- **Document Text Extraction**: Extract readable text from **PDF**, **Word (DOCX)**, and **PowerPoint (PPTX)** documents via `file_extract_text` — perfect for summarizing reports, resumes, and slide decks. Large documents are read incrementally with `next_offset` continuation; scanned PDFs (image-only) are not OCR'd.
- **Common File Types**: `.txt`, `.md`, `.json`, `.csv`, `.yaml`, `.xml`, `.py`, `.js`, `.ts`, `.dart`, `.html`, `.css`, `.log`, `.cfg`, `.toml`, `.ini`, `.env`, `.sh`, `.bat`, `.ps1`, `.sql`, `.java`, `.kt`, `.swift`, `.c`, `.cpp`, `.h`, `.rs`, `.go`, `.rb`, `.php`, `.lua`, `.r`, `.tex`, `.svg`, and more.
- **Flexible Configuration**: Set a global default directory, per-project workspace, or per-conversation override. Supports Android and Windows.

<p align="center">
  <img src="Screenshots/Workspace_1.jpg" alt="Workspace Settings" width="30%" />
   
  <img src="Screenshots/Workspace_2.jpg" alt="Workspace File Cards" width="30%" />
   
  <img src="Screenshots/Workspace_3.jpg" alt="Workspace File Browser" width="30%" />
</p>

---

### 🤖 AI Team (Mixture of Agents)

Supports two advanced multi-agent collaboration pipelines for complex problem solving:

- **Parallel (MoA)**: Orchestrate 1–4 "proposer" models to explore a question independently, then let an "aggregator" model synthesize their perspectives into a single, comprehensive response.
- **Chain (CMoA)**: Sequential reasoning chain (Proposer -> Self-Audit Critics 0~3 -> Aggregator). Critics apply 7 Analytical Lenses (Adversarial, Causal/Structural, Comparative, Temporal, etc.) to stress-test and audit preceding outputs.
- **Real-Time Streaming**: Proposals and audit logs stream live as each model completes, rendered in clean, layered collapsible sections.

<p align="center">
  <img src="Screenshots/AI_TEAM.jpg" alt="AI Team Interface" width="30%" />
</p>

---

### 🎨 Customizable New Chat Empty State & Dynamic AI Greetings

Personalize your empty chat screen with zero-latency greetings and branding:

- **Flexible Logo & Icon Display**: Choose between OmniChat logo, active model icon, custom uploaded image, or hidden logo.
- **Zero-Latency AI Dynamic Greetings**: Pre-caches AI-generated warm greetings in the background upon app start for instant display.
- **Dedicated Greeting Model & Prompts**: Independently select the model for greeting generation, customize prompts, and toggle thinking budget (Enable Thinking).
- **Refined Visual Layout**: Enlarged logo aesthetics (100px) and bold typography for a modern, premium feel.

<p align="center">
  <img src="Screenshots/Customizable_New_Chat_Empty_State_1.jpg" alt="Customizable Empty State 1" width="30%" />
    
  <img src="Screenshots/Customizable_New_Chat_Empty_State_2.jpg" alt="Customizable Empty State 2" width="30%" />
</p>

---

### 🎙️ Real-Time Voice Chat

Experience AI interaction as natural as a phone call:

- **Universal Model Support**: Connect with your preferred LLM backends.
- **Bluetooth Optimization**: Enhanced headset detection and audio routing in Call Mode.
- **Native Performance**: Utilizes system-level Speech-to-Text (STT) for low latency.

<p align="center">
  <img src="Screenshots/Voice_Chat.jpg" alt="Voice Chat Interface" width="30%" />
</p>

---

### 💳 Account Balance Monitoring

Keep track of your usage effortlessly. Real-time account balance is displayed directly within the Model Selection menu and Provider Settings (supports OpenAI, Gemini, DeepSeek, OpenRouter, Neuralwatt, and more).

<p align="center">
  <img src="Screenshots/Account_Balance.jpg" alt="Account Balance Monitoring" width="30%" />
</p>

---

### 🔬 Deep Research

Preset agent protocol designed for complex scientific, technical, and investigative research:

- **Dual Think & Search Engine**: Combines multi-round deep reasoning with real-time web search. Uses targeted search queries to resolve uncertainties and fuels subsequent reasoning loops.
- **Epistemic Discipline**: Enforces a strict distinction between *Evidence* (empirical facts), *Inference* (logical deductions), and *Judgment* (value choices).
- **Rigorous Synthesis**: Dynamic stopping criteria based on information saturation, producing decision-useful research reports backed by verifiable citations and epistemic calibration.

---

### 📚 Academic Search

Built-in free academic search providers for scholarly literature, fully integrated into the search service:

- **arXiv**: Search preprints through the official arXiv API — no API key or registration required, with automatic rate-limit throttling (one request every 3 seconds).
- **PubMed (E-utilities)**: Two-step esearch → efetch flow returns paper titles and abstracts from NCBI.
- **Semantic Scholar**: Paper search via the Academic Graph API with graceful rate-limit messaging.

All three providers work out of the box; PubMed and Semantic Scholar accept an optional API key to raise their rate limits. Official brand icons are displayed across all UI surfaces (mobile & desktop).

---

### 🌐 Advanced Web Search & Local MCP Tools

- **Advanced Web Search**: Integrated Tinyfish Search API, Google Search API, and multiple search providers for high-quality real-time information.
- **Inline Voice Dictation**: Dictate text directly into the chat input bar with localized support for English and Chinese.
- **Local JavaScript MCP**: Secure, sandboxed environment (QuickJS/JavaScriptCore) allowing AI to execute code locally for calculations and data processing.

---

### 🛠️ Customizable Input Bar Buttons

Tailor the chat input bar tools to your workflow — one shared layout for mobile and desktop:

- **Drag to Reorder**: Rearrange input bar buttons (model selector, web search, MCP, quick phrases, dictation, camera/photos, file upload, reasoning, AI Team, instruction injection, voice chat, context management, OCR) in **Settings → Display Settings → Input Bar Buttons**.
- **Show/Hide Toggles**: Hide rarely used buttons entirely; platform-specific buttons (camera/photos on mobile, file upload/OCR on desktop) are only shown where available.
- **One-Tap Reset**: Restore the default order and visibility anytime.

---

## 💻 Cross-Platform Support

Enjoy a consistent experience across your devices:

- **Windows**
- **Android**
