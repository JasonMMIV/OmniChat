#include "speech_to_text_windows_plugin.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <windows.h>
#include <iostream>
#include <string>
#include <future>
#include <sstream>
#include <iomanip>

using namespace winrt;
using namespace Windows::Media::SpeechRecognition;
using namespace Windows::Globalization;
using namespace Windows::Foundation;

namespace speech_to_text_windows {

// Helper to escape JSON string
static std::string EscapeJsonString(const std::string& s) {
    std::ostringstream o;
    for (char c : s) {
        if (c == '"') o << "\\\"";
        else if (c == '\\') o << "\\b\\a\\c\\k\\s\\l\\a\\s\\h\\b\\a\\c\\k\\s\\l\\a\\s\\h";
        else if (c == '\b') o << "\\b";
        else if (c == '\f') o << "\\f";
        else if (c == '\n') o << "\\n";
        else if (c == '\r') o << "\\r";
        else if (c == '\t') o << "\\t";
        else if (static_cast<unsigned char>(c) <= 0x1f) {
            o << "\\u" << std::hex << std::setw(4) << std::setfill('0') << static_cast<int>(c);
        } else {
            o << c;
        }
    } 
    return o.str();
}

void SpeechToTextWindowsPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  std::cout << "[OmniChat] RegisterWithRegistrar called" << std::endl;
  auto channel = 
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "speech_to_text_windows",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<SpeechToTextWindowsPlugin>(registrar);
  plugin->m_channel = std::move(channel);

  plugin->m_channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto &call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  registrar->AddPlugin(std::move(plugin));
}

const LPCWSTR SpeechToTextWindowsPlugin::kMessageWindowClassName = L"OmniChatSpeechMessageWindow";

SpeechToTextWindowsPlugin::SpeechToTextWindowsPlugin(flutter::PluginRegistrarWindows *registrar) {
    std::cout << "[OmniChat] SpeechToTextWindowsPlugin created" << std::endl;
    CreateMessageWindow();
}

SpeechToTextWindowsPlugin::~SpeechToTextWindowsPlugin() {
    std::cout << "[OmniChat] SpeechToTextWindowsPlugin destroying" << std::endl;
    DestroyMessageWindow();
    
    if (m_recognizer) {
        try {
            if (m_isListening) {
                m_recognizer.ContinuousRecognitionSession().StopAsync().get();
            }
            m_recognizer.Close();
        } catch (...) {}
    }
}

void SpeechToTextWindowsPlugin::CreateMessageWindow() {
    WNDCLASSEX windowClass = {0};
    windowClass.cbSize = sizeof(WNDCLASSEX);
    windowClass.lpfnWndProc = SpeechToTextWindowsPlugin::MessageWindowProc;
    windowClass.hInstance = GetModuleHandle(nullptr);
    windowClass.lpszClassName = kMessageWindowClassName;
    
    RegisterClassEx(&windowClass);

    m_messageWindow = CreateWindowEx(
        0,
        kMessageWindowClassName,
        L"OmniChatSpeechMsgWindow",
        0,
        0, 0, 0, 0,
        HWND_MESSAGE,
        nullptr,
        GetModuleHandle(nullptr),
        this
    );

    if (m_messageWindow) {
        std::cout << "[OmniChat] Message-Only Window created: " << m_messageWindow << std::endl;
        // Store 'this' pointer in the window user data so WndProc can access it
        SetWindowLongPtr(m_messageWindow, GWLP_USERDATA, (LONG_PTR)this);
    } else {
        std::cout << "[OmniChat] ERROR: Failed to create Message-Only Window! Error: " << GetLastError() << std::endl;
    }
}

void SpeechToTextWindowsPlugin::DestroyMessageWindow() {
    if (m_messageWindow) {
        DestroyWindow(m_messageWindow);
        m_messageWindow = nullptr;
    }
    UnregisterClass(kMessageWindowClassName, GetModuleHandle(nullptr));
}

LRESULT CALLBACK SpeechToTextWindowsPlugin::MessageWindowProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
    SpeechToTextWindowsPlugin* plugin = (SpeechToTextWindowsPlugin*)GetWindowLongPtr(hwnd, GWLP_USERDATA);

    if (message == WM_RUN_ON_MAIN_THREAD) {
        if (plugin) {
            // std::cout << "[OmniChat] WndProc processing tasks..." << std::endl;
            std::queue<std::function<void()>> tasks;
            {
                std::lock_guard<std::mutex> lock(plugin->m_queueMutex);
                tasks.swap(plugin->m_taskQueue);
            }
            while (!tasks.empty()) {
                tasks.front()();
                tasks.pop();
            }
        }
        return 0;
    }
    return DefWindowProc(hwnd, message, wparam, lparam);
}

void SpeechToTextWindowsPlugin::RunOnMainThread(std::function<void()> task) {
    if (m_messageWindow && IsWindow(m_messageWindow)) {
        {
            std::lock_guard<std::mutex> lock(m_queueMutex);
            m_taskQueue.push(task);
        }
        BOOL posted = PostMessage(m_messageWindow, WM_RUN_ON_MAIN_THREAD, 0, 0);
        if (!posted) {
            std::cout << "[OmniChat] ERROR: PostMessage failed! Error: " << GetLastError() << std::endl;
            // Fallback: execute directly (unsafe)
            task(); 
        }
    } else {
        std::cout << "[OmniChat] WARNING: No Message Window! Executing on current thread. " << std::endl;
        task(); 
    }
}

std::string SpeechToTextWindowsPlugin::ToUtf8(std::wstring_view wstr) {
    if (wstr.empty()) return std::string();
    int size_needed = WideCharToMultiByte(CP_UTF8, 0, wstr.data(), (int)wstr.size(), NULL, 0, NULL, NULL);
    std::string strTo(size_needed, 0);
    WideCharToMultiByte(CP_UTF8, 0, wstr.data(), (int)wstr.size(), &strTo[0], size_needed, NULL, NULL);
    return strTo;
}

void SpeechToTextWindowsPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method_name = method_call.method_name();
  std::cout << "[OmniChat] v1.5.4 HandleMethodCall: " << method_name << std::endl;
  
  if (method_name == "hasPermission") {
    result->Success(flutter::EncodableValue(true));
  } else if (method_name == "initialize") {
    Initialize(method_call, std::move(result));
  } else if (method_name == "listen") {
    Listen(method_call, std::move(result));
  } else if (method_name == "stop") {
    Stop(std::move(result));
  } else if (method_name == "cancel") {
    Cancel(std::move(result));
  } else if (method_name == "locales") {
    GetLocales(std::move(result));
  } else {
    result->NotImplemented();
  }
}

void SpeechToTextWindowsPlugin::Initialize(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    std::cout << "[OmniChat] Initialize called, starting async..." << std::endl;
    InitializeAsync("", std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(std::move(result)));
}

fire_and_forget SpeechToTextWindowsPlugin::InitializeAsync(
    std::string localeId, 
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    
    std::cout << "[OmniChat] InitializeAsync start. Locale: '" << localeId << "'" << std::endl;
    
    auto weak_result = result; 
    
    try {
        {
            std::lock_guard<std::mutex> lock(m_mutex);
            if (m_recognizer) {
                std::cout << "[OmniChat] Closing existing recognizer" << std::endl;
                m_recognizer.Close();
                m_recognizer = nullptr;
            }

            if (!localeId.empty()) {
                try {
                    std::cout << "[OmniChat] Creating Language for: " << localeId << std::endl;
                    Language lang(to_hstring(localeId));
                    m_recognizer = SpeechRecognizer(lang);
                    m_currentLocale = localeId;
                } catch (...) {
                    std::cout << "[OmniChat] Failed to create Language, falling back to default" << std::endl;
                    m_recognizer = SpeechRecognizer();
                    m_currentLocale = "";
                }
            } else {
                std::cout << "[OmniChat] Creating default SpeechRecognizer" << std::endl;
                m_recognizer = SpeechRecognizer();
                m_currentLocale = "";
            }
        }

        SpeechRecognizer recognizer;
        {
             std::lock_guard<std::mutex> lock(m_mutex);
             recognizer = m_recognizer;
        }

        if (recognizer) {
            std::cout << "[OmniChat] Adding constraints..." << std::endl;
            auto constraint = SpeechRecognitionTopicConstraint(SpeechRecognitionScenario::Dictation, L"dictation");
            recognizer.Constraints().Append(constraint);

            std::cout << "[OmniChat] Compiling constraints (Async)..." << std::endl;
            SpeechRecognitionCompilationResult compileResult = co_await recognizer.CompileConstraintsAsync();
            std::cout << "[OmniChat] Compilation result status: " << (int)compileResult.Status() << std::endl;
            
            RunOnMainThread([weak_result, compileResult]() {
                if (weak_result) {
                    if (compileResult.Status() == SpeechRecognitionResultStatus::Success) {
                        weak_result->Success(flutter::EncodableValue(true));
                    } else {
                        std::string err = "Compilation failed: " + std::to_string((int)compileResult.Status());
                        weak_result->Error("INIT_ERROR", err);
                    }
                }
            });

        } else {
             std::cout << "[OmniChat] Recognizer is null!" << std::endl;
             RunOnMainThread([weak_result]() {
                 if (weak_result) weak_result->Error("INIT_ERROR", "Failed to create recognizer");
             });
        }

    } catch (hresult_error const& ex) {
        std::string msg = ToUtf8(ex.message());
        std::cout << "[OmniChat] InitializeAsync Exception: " << msg << std::endl;
        RunOnMainThread([weak_result, msg]() {
            if (weak_result) weak_result->Error("INIT_EXCEPTION", msg);
        });
    } catch (...) {
        std::cout << "[OmniChat] InitializeAsync Unknown Exception" << std::endl;
        RunOnMainThread([weak_result]() {
            if (weak_result) weak_result->Error("INIT_UNKNOWN", "Unknown error during initialization");
        });
    }
}

void SpeechToTextWindowsPlugin::Listen(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    
    std::cout << "[OmniChat] Listen called" << std::endl;
    if (m_isListening) {
        std::cout << "[OmniChat] Already listening, ignoring." << std::endl;
        result->Success(flutter::EncodableValue(true));
        return;
    }

    std::string localeId = "";
    const auto *arguments = std::get_if<flutter::EncodableMap>(method_call.arguments());
    if (arguments) {
        auto it = arguments->find(flutter::EncodableValue("localeId"));
        if (it != arguments->end() && !it->second.IsNull()) {
            if (std::holds_alternative<std::string>(it->second)) {
                localeId = std::get<std::string>(it->second);
            }
        }
    }
    std::cout << "[OmniChat] Listen requested locale: " << localeId << std::endl;
    
    StartListeningAsync(localeId, std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(std::move(result)));
}

fire_and_forget SpeechToTextWindowsPlugin::StartListeningAsync(
    std::string localeId,
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    
    std::cout << "[OmniChat] StartListeningAsync begin" << std::endl;
    auto weak_result = result;
    
    try {
        SpeechRecognizer recognizer;
        bool needReinit = false;

        {
             std::lock_guard<std::mutex> lock(m_mutex);
             if (!m_recognizer) {
                 needReinit = true;
             } else if (!localeId.empty() && localeId != m_currentLocale) {
                 std::cout << "[OmniChat] Locale changed from '" << m_currentLocale << "' to '" << localeId << "'. Re-initializing..." << std::endl;
                 needReinit = true;
             } else if (localeId.empty() && !m_currentLocale.empty()) {
                 std::cout << "[OmniChat] Locale changed from '" << m_currentLocale << "' to Default. Re-initializing..." << std::endl;
                 needReinit = true;
             }

             if (needReinit) {
                 if (m_recognizer) {
                     m_recognizer.Close();
                     m_recognizer = nullptr;
                 }
                 
                 if (!localeId.empty()) {
                     try {
                         Language lang(to_hstring(localeId));
                         m_recognizer = SpeechRecognizer(lang);
                         m_currentLocale = localeId;
                     } catch (hresult_error const& ex) {
                         std::cout << "[OmniChat] Failed to create Language (" << localeId << "), HRESULT: 0x" << std::hex << ex.code() << std::dec << std::endl;
                         
                         // Best Effort Chinese Fallback
                         if (localeId.find("zh") != std::string::npos) {
                             std::string fallbackLocale = (localeId == "zh-TW") ? "zh-CN" : "zh-TW";
                             std::cout << "[OmniChat] Attempting Chinese fallback: " << fallbackLocale << std::endl;
                             try {
                                 Language langFallback(to_hstring(fallbackLocale));
                                 m_recognizer = SpeechRecognizer(langFallback);
                                 m_currentLocale = fallbackLocale;
                             } catch (...) {
                                 std::cout << "[OmniChat] Chinese fallback failed. Using default." << std::endl;
                                 std::cout << "[OmniChat] CRITICAL: Chinese Speech Pack appears to be missing or incompatible." << std::endl; 
                                 std::cout << "[OmniChat] Please verify: Settings > Time & Language > Speech > Installed Voice Packages." << std::endl;
                                 m_recognizer = SpeechRecognizer();
                                 m_currentLocale = "";
                             }
                         } else {
                             std::cout << "[OmniChat] Falling back to default." << std::endl;
                             m_recognizer = SpeechRecognizer();
                             m_currentLocale = "";
                         }
                     } catch (...) {
                         std::cout << "[OmniChat] Failed to create Language (" << localeId << "), Unknown Error. Falling back to default." << std::endl;
                         m_recognizer = SpeechRecognizer();
                         m_currentLocale = "";
                     }
                 } else {
                     m_recognizer = SpeechRecognizer();
                     m_currentLocale = "";
                 }
             }
             
             recognizer = m_recognizer;
        }

        if (needReinit && recognizer) {
             std::cout << "[OmniChat] Adding constraints (Re-init)..." << std::endl;
             auto constraint = SpeechRecognitionTopicConstraint(SpeechRecognitionScenario::Dictation, L"dictation");
             recognizer.Constraints().Append(constraint);

             std::cout << "[OmniChat] Compiling constraints (Re-init)..." << std::endl;
             SpeechRecognitionCompilationResult compileResult = co_await recognizer.CompileConstraintsAsync();
             if (compileResult.Status() != SpeechRecognitionResultStatus::Success) {
                 std::cout << "[OmniChat] Compilation failed: " << (int)compileResult.Status() << std::endl;
                 RunOnMainThread([weak_result]() {
                     if (weak_result) weak_result->Error("LISTEN_INIT_FAILED", "Failed to compile constraints");
                 });
                 co_return;
             }
        }

        if (!recognizer) {
             std::cout << "[OmniChat] Recognizer null in Listen" << std::endl;
             RunOnMainThread([weak_result]() {
                 if (weak_result) weak_result->Error("NOT_INITIALIZED", "Recognizer is null");
             });
             co_return;
        }

        std::cout << "[OmniChat] Subscribing events..." << std::endl;
        recognizer.HypothesisGenerated([this](auto const&, auto const& args) {
             // std::cout << "[OmniChat] HypothesisGenerated" << std::endl;
             SendTextRecognition(ToUtf8(args.Hypothesis().Text()), false);
        });

        recognizer.ContinuousRecognitionSession().ResultGenerated([this](auto const&, auto const& args) {
             std::cout << "[OmniChat] ResultGenerated" << std::endl;
             SendTextRecognition(ToUtf8(args.Result().Text()), true);
        });
        
        recognizer.ContinuousRecognitionSession().Completed([this](auto const&, auto const&) {
             std::cout << "[OmniChat] Session Completed" << std::endl;
             SendStatus("notListening");
             m_isListening = false;
        });

        std::cout << "[OmniChat] Starting continuous recognition..." << std::endl;
        co_await recognizer.ContinuousRecognitionSession().StartAsync();
        std::cout << "[OmniChat] Started." << std::endl;
        
        m_isListening = true;
        SendStatus("listening");
        
        RunOnMainThread([weak_result]() {
            if (weak_result) weak_result->Success(flutter::EncodableValue(true));
        });

    } catch (hresult_error const& ex) {
        m_isListening = false;
        std::string msg = ToUtf8(ex.message());
        std::cout << "[OmniChat] StartListeningAsync Exception: " << msg << std::endl;
        RunOnMainThread([weak_result, msg]() {
            if (weak_result) weak_result->Error("LISTEN_FAILED", msg);
        });
    } catch (...) {
        m_isListening = false;
        std::cout << "[OmniChat] StartListeningAsync Unknown Exception" << std::endl;
    }
}

void SpeechToTextWindowsPlugin::Stop(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    std::cout << "[OmniChat] Stop called" << std::endl;
    StopListeningAsync(std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(std::move(result)));
}

fire_and_forget SpeechToTextWindowsPlugin::StopListeningAsync(
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    
    SpeechRecognizer recognizer;
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        recognizer = m_recognizer;
    }

    auto weak_result = result;

    if (recognizer && m_isListening) {
        try {
            std::cout << "[OmniChat] Stopping session..." << std::endl;
            co_await recognizer.ContinuousRecognitionSession().StopAsync();
            std::cout << "[OmniChat] Stopped." << std::endl;
            m_isListening = false;
            SendStatus("notListening");
            
            RunOnMainThread([weak_result]() {
                if (weak_result) weak_result->Success(flutter::EncodableValue(true));
            });
        } catch (...) {
            std::cout << "[OmniChat] Stop Exception" << std::endl;
            RunOnMainThread([weak_result]() {
                if (weak_result) weak_result->Error("STOP_FAILED", "Failed to stop session");
            });
        }
    } else {
        RunOnMainThread([weak_result]() {
            if (weak_result) weak_result->Success(flutter::EncodableValue(true));
        });
    }
}

void SpeechToTextWindowsPlugin::Cancel(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    Stop(std::move(result));
}

void SpeechToTextWindowsPlugin::GetLocales(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    std::cout << "[OmniChat] GetLocales called" << std::endl;
    flutter::EncodableList locales;
    
    try {
        auto systemLang = SpeechRecognizer::SystemSpeechLanguage();
        if (systemLang) {
             std::cout << "[OmniChat] System Default Speech Language: " << ToUtf8(systemLang.LanguageTag()) << std::endl;
        }

        auto languages = SpeechRecognizer::SupportedTopicLanguages();

        for (auto const& lang : languages) {
            std::string tag = ToUtf8(lang.LanguageTag());
            std::string name = ToUtf8(lang.DisplayName());
            locales.push_back(flutter::EncodableValue(tag + ":" + name));
        }
    } catch (...) {}

    std::cout << "[OmniChat] Found " << locales.size() << " locales" << std::endl;
    result->Success(flutter::EncodableValue(locales));
}

void SpeechToTextWindowsPlugin::SendTextRecognition(const std::string& text, bool is_final) {
    RunOnMainThread([this, text, is_final]() {
        if (m_channel) {
            std::string safeText = EscapeJsonString(text);
            std::string json = "{\"recognizedWords\":\"" + safeText + "\",\"finalResult\":" + (is_final ? "true" : "false") + "}";
            
            try {
                m_channel->InvokeMethod("textRecognition", std::make_unique<flutter::EncodableValue>(json));
            } catch (...) {
                std::cout << "[OmniChat] InvokeMethod Exception!" << std::endl;
            }
        }
    });
}

void SpeechToTextWindowsPlugin::SendError(const std::string& error) {
    RunOnMainThread([this, error]() {
        if (m_channel) m_channel->InvokeMethod("notifyError", std::make_unique<flutter::EncodableValue>(error));
    });
}

void SpeechToTextWindowsPlugin::SendStatus(const std::string& status) {
  std::cout << "[OmniChat] Status: " << status << std::endl;
  RunOnMainThread([this, status]() {
      if (m_channel) m_channel->InvokeMethod("notifyStatus", std::make_unique<flutter::EncodableValue>(status));
  });
}

} // namespace speech_to_text_windows

extern "C" __declspec(dllexport) void SpeechToTextWindowsPluginRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar) {
  speech_to_text_windows::SpeechToTextWindowsPlugin::RegisterWithRegistrar(flutter::PluginRegistrarManager::GetInstance()->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
