#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // The Flutter engine's child window (created by FlutterViewController).
  // We subclass it to also short-circuit WM_GETOBJECT at the child level,
  // forming a double-layer guard alongside the parent window's WM_GETOBJECT
  // intercept in MessageHandler. The Flutter Windows engine enables its
  // accessibility / semantics pipeline whenever ANY window owned by the engine
  // receives WM_GETOBJECT (which can be sent by Windows itself for taskbar
  // thumbnails / Alt+Tab / DWM, not only by external screen readers). Closing
  // only the parent path still allowed the engine to be activated through the
  // child HWND, contributing to the residual flutter_windows.dll 0xc0000005
  // crashes observed in v1.5.28. See CHANGES_LOG v1.5.28 (parent layer) and
  // v1.5.29 Fix B (this child layer).
  HWND child_hwnd_ = nullptr;

  // Window subclass procedure installed on child_hwnd_ via SetWindowSubclass.
  // It must be static (the subclass proc signature is fixed by Win32 API).
  static LRESULT CALLBACK ChildWndSubclassProc(
      HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam,
      UINT_PTR id_subclass, DWORD_PTR ref_data) noexcept;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
