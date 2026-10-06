#pragma once

#include <QString>

#include <memory>

#include "Pairing.h"
#include "StoragePaths.h"

class NativeShell;
class ShellBridge;
class ShellRuntime;
class ThemeStore;

// The phone's shell as the app (main.cpp) and its scenarios (tests/features)
// both build it: the desktop's shell with what a phone turns off, the phone's
// root (HalC2/Mobile/MobileShell.qml) in one window, and the one environment
// it pairs with (Pairing). What differs between the two is in Options.
class MobileApp {
public:
  struct Options {
    // One root for the app's files (<home>/config, data, state, cache).
    QString home;
    // Where the bricks' and the phone's own QML are on disk, to load them from
    // there (and hot-reload); empty = the copies compiled in.
    QString bricksQmlDir;
    QString mobileQmlDir;
    // What an MC lists this client as.
    pairing::Client device = Pairing::thisDevice();
  };

  // What has to be chosen before any window: the software renderer when
  // there is no display, and the run-time style. Once, after the
  // QGuiApplication is made.
  static void prepare();

  explicit MobileApp(const Options& options);
  ~MobileApp();

  const StoragePaths& storage() const { return m_storage; }
  ShellBridge& bridge() { return *m_bridge; }
  NativeShell& native() { return *m_native; }
  ThemeStore& theme() { return *m_theme; }
  ShellRuntime& runtime() { return *m_runtime; }

  // Opens the environment the phone remembers, if it has one, and shows the
  // window.
  void start();

private:
  StoragePaths m_storage;
  // Declared in teardown order: the pairing and the window go before the
  // shell they read, and the shell before the bridge it intercepts.
  std::unique_ptr<ShellBridge> m_bridge;
  std::unique_ptr<NativeShell> m_native;
  std::unique_ptr<ThemeStore> m_theme;
  std::unique_ptr<ShellRuntime> m_runtime;
  std::unique_ptr<Pairing> m_pairing;
};
