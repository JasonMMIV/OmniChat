#ifndef FLUTTER_PLUGIN_SPEECH_TO_TEXT_WINDOWS_PLUGIN_H_
#define FLUTTER_PLUGIN_SPEECH_TO_TEXT_WINDOWS_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Media.SpeechRecognition.h>
#include <winrt/Windows.Globalization.h>

#include <memory>
#include <mutex>
#include <string>
#include <vector>
#include <queue>
#include <functional>
#include <atomic>
#include <optional>

namespace speech_to_text_windows {

using namespace winrt;
using namespace Windows::Media::SpeechRecognition;

class SpeechToTextWindowsPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  SpeechToTextWindowsPlugin(flutter::PluginRegistrarWindows *registrar);
  virtual ~SpeechToTextWindowsPlugin();

  SpeechToTextWindowsPlugin(const SpeechToTextWindowsPlugin&) = delete;
  SpeechToTextWindowsPlugin& operator=(const SpeechToTextWindowsPlugin&) = delete;

  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void Initialize(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void Listen(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void Stop(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void Cancel(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void GetLocales(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void SendTextRecognition(const std::string& text, bool is_final);

  void SendError(const std::string& error);

  void SendStatus(const std::string& status);

  std::string ToUtf8(std::wstring_view wstr);

  // Thread dispatching via Message-Only Window
  void RunOnMainThread(std::function<void()> task);
  
  // Message-Only Window Helpers
  void CreateMessageWindow();
  void DestroyMessageWindow();
  static LRESULT CALLBACK MessageWindowProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);

  // Async helpers (using shared_ptr for coroutine compatibility)
  fire_and_forget InitializeAsync(std::string localeId, std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  fire_and_forget StartListeningAsync(std::string localeId, std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  fire_and_forget StopListeningAsync(std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  SpeechRecognizer m_recognizer{ nullptr };
  
  // Threading state
  HWND m_messageWindow = nullptr; // Our private message-only window
  std::mutex m_queueMutex;
  std::queue<std::function<void()>> m_taskQueue;
  static const UINT WM_RUN_ON_MAIN_THREAD = WM_USER + 4242;
  static const LPCWSTR kMessageWindowClassName;

  std::mutex m_mutex;
  std::atomic<bool> m_isListening{ false };
  std::string m_currentLocale;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> m_channel;
};

}  // namespace speech_to_text_windows

extern "C" __declspec(dllexport) void SpeechToTextWindowsPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);

#endif  // FLUTTER_PLUGIN_SPEECH_TO_TEXT_WINDOWS_PLUGIN_H_