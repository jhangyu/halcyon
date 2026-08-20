#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>
#include <string>

#include "halcyon_native.h"
#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

  // Records the file Windows handed the app on the command line (shell
  // association / "Open with"). Must be called before Create(): the path is
  // pushed to Dart from OnCreate, as soon as the channel exists.
  void SetLaunchFile(const std::string& utf8_path);

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // Sends |utf8_path| to Dart on halcyon/open_with, if the channels are up.
  void DeliverOpenFile(const std::string& utf8_path);

  // Handles WM_DROPFILES by forwarding the first dropped path.
  void HandleDroppedFiles(WPARAM wparam);

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Halcyon's platform channels. Created in OnCreate once the engine exists,
  // and destroyed in OnDestroy BEFORE |flutter_controller_|, since the
  // channels hold a messenger borrowed from the engine.
  std::unique_ptr<halcyon::Channels> channels_;

  // File passed on the command line at launch, pending delivery to Dart.
  std::string launch_file_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
