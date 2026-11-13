# OmniChat v1.28.0

> Draft for the GitHub v1.28.0 release body.

## Highlights

- **Android PRoot shell (`shell_exec`)** — Run one foreground command inside a pinned Ubuntu Base rootfs, with approval, timeout/cancel, output caps, workspace mount mapping, and a Settings → Android Shell installer. Available on **arm64-v8a only**.
- **Background long-running tasks** — Desktop tray status (running / completed / failed / stopped) and Android completion or failure notifications. Tap the status or notification to return to the conversation.
- **Subagents (`spawn_subagent`)** — Isolated helper runs with a fresh context, independent step/token budgets, serialized execution, and summary-only results returned to the parent conversation.
- **Tool image delivery transparency** — Vision-capable models can inspect tool-result images; tool cards explain when an image is not sent and recover from provider rejection.
- **Workspace file tools** — `file_grep` adds regex content search, and `file_view_image` adds workspace image previews with vision-model delivery.
- **Live preview dev server** — Serve the workspace over loopback with SSE reload, console-error capture, and a dedicated preview panel.
- **Playwright browser QA preset** — One-click MCP setup for browser automation, including STDIO transport and screenshot previews.
- **Workspace and model UX** — Workspace file-map injection, context usage ring, context-window chips, localized tool cards, and simplified workspace permissions.

## Fixes

- Centered Markdown code-block titles and limited block actions to hover/tap.
- Translated the hotkeys, tray, and topics-panel settings into English.
- Fixed context-ring placement and dead context-button taps on the home screen.
- Stopped inline image markers from crashing or blocking turns.
- Fixed workspace subpage navigation and disk-usage copy.

## Android ABI support / Android ABI 支援

| ABI | App | PRoot `shell_exec` |
|:--|:--:|:--:|
| `arm64-v8a` | ✅ | ✅ |
| `armeabi-v7a` (32-bit ARM) | ✅ | ❌ |
| `x86_64` (emulators / Chromebooks) | ✅ | ❌ |

The universal APK includes Flutter builds for all three ABIs, so the chat app can run on all of them. The PRoot native libraries (`libproot_exec.so`, `libproot_loader.so`, `libandroid-shmem.so`) are packaged only under `lib/arm64-v8a/`; `armeabi-v7a` and `x86_64` still install the shared arm64 rootfs asset, but the native probe rejects those process ABIs, so `shell_exec` is not advertised and the asset is unusable. Settings → Android Shell remains visible and reports the shell as unsupported there. All other app features remain available.

## Known limitations

- Android `shell_exec` is foreground-only: no PTY, background jobs, or in-app terminal.
- The PRoot environment is not a security sandbox; commands run with the app's permissions.

## Downloads

- `OmniChat_windows_v1.28.0_setup.exe` — Windows x64
- `OmniChat_v1.28.0_android.apk` — Android 7.0+ (universal, versionCode 8112)
