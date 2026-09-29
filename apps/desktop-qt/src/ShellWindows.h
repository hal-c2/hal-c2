#pragma once

#include <QHash>
#include <QObject>

#include "ShellRuntime.h"

class NativeShell;
class NativeWindow;
class ThemeStore;

// Every NativeWindow on screen: one ShellRuntime (its engine and window) per
// window the shell has, made as the shell opens one and dropped as it closes
// one. The user closing a window closes only that window (NativeShell::
// closeWindow, queued so the window is not deleted inside its own close);
// the shell says when it was the last (NativeShell::lastWindowClosed).
class ShellWindows : public QObject {
  Q_OBJECT

public:
  ShellWindows(NativeShell* shell, ShellRuntime::Options options, ThemeStore* theme, QObject* parent = nullptr);

  // Shows the windows made so far; later ones show as they open.
  void start();
  ShellRuntime* runtime(NativeWindow* window) const { return m_runtimes.value(window); }
  // Shows the main window again once the user closed them all (macOS keeps
  // running without windows, as the Electron desktop did).
  void reopen();

private:
  void add(NativeWindow* window);

  NativeShell* m_shell;
  ShellRuntime::Options m_options;
  ThemeStore* m_theme;
  QHash<NativeWindow*, ShellRuntime*> m_runtimes;
  bool m_started = false;
};
