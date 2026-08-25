---
layout: default
title: OmniChat Privacy Policy
---

# OmniChat Privacy Policy

_Last updated: 2026-08-16_

This policy explains what data OmniChat ("the app") collects, stores, and shares. It applies to all platforms (Android, Windows, and others).

## 1. The short version

- OmniChat is a **local-first** AI chat client. There is **no OmniChat server** and **no OmniChat account**.
- The app does **not** collect analytics, telemetry, usage statistics, advertising identifiers, or crash reports.
- Your chat history and settings are stored **on your device**.
- When you chat, your messages are sent **directly from your device to the AI model provider you configured** (for example OpenAI, Google Gemini, Anthropic Claude, DeepSeek, OpenRouter, Moonshot, or Neuralwatt). The app itself does not see or store those transmissions.
- No data is shared with any third party except the providers you explicitly configure.

## 2. Data stored on your device

The following data is stored locally on your device:

- **Chat history and messages** — stored in a local database (Hive) on your device.
- **Settings and preferences** — stored in local preferences.
- **API keys and tokens** — stored in the operating system's encrypted credential store (Android Keystore / Windows DPAPI) where supported. You are responsible for keeping these credentials private.
- **Voice recordings** — audio captured for voice chat is processed on your device and sent to the speech-recognition service you configured; temporary audio files may be kept locally.
- **Temporary files** — HTML previews, images, and other temporary data may be written to your device's temporary directory.

## 3. Data transmitted to services you configure

OmniChat does not operate servers. All network traffic goes directly between your device and the services you configure:

- **AI model providers** — chat messages, tool results, and conversation context are sent to the model provider you selected (for example OpenAI, Google Gemini, Anthropic Claude, DeepSeek, OpenRouter, Moonshot, Neuralwatt, or a self-hosted endpoint).
- **Speech recognition / synthesis services** — audio and text used for voice chat.
- **Web search providers** — search queries you or the assistant issue are sent to the search provider you configured (for example Tavily, Bing, DuckDuckGo, Serper, Grok, or others).
- **Fonts** — if you select a Google Font, the font is fetched at runtime from Google's font servers. The default font is the system font and works fully offline.

Each of these providers has its own privacy policy, and the data you send them is subject to that provider's terms.

## 4. Backups and export

OmniChat lets you export or back up your chat history and settings (for example, to a local file or to cloud storage you choose, such as Dropbox or WebDAV). **Backup files contain your chat history and may contain sensitive settings.** Keep backup files private and treat them like your passwords.

## 5. Children

OmniChat is not directed at children under the age of 13, and we do not knowingly collect personal information from children.

## 6. Changes to this policy

We may update this policy from time to time. The latest version is always available at this page.

## 7. Contact

If you have questions about this policy, please open an issue at:
https://github.com/JasonMMIV/OmniChat/issues
