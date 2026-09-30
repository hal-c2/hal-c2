#include "ShellWindows.h"

#include <QPointer>

#include "NativeShell.h"
#include "ShellBridge.h"
#include "ThemeStore.h"

ShellWindows::ShellWindows(NativeShell* shell, ShellRuntime::Options options, ThemeStore* theme, QObject* parent)
    : QObject(parent), m_shell(shell), m_options(std::move(options)), m_theme(theme) {
  for (const auto& window : shell->windows()) add(window.get());
  connect(shell, &NativeShell::windowOpened, this, &ShellWindows::add);
  connect(shell, &NativeShell::windowClosing, this, [this](NativeWindow* window) {
    if (ShellRuntime* runtime = m_runtimes.take(window)) runtime->deleteLater();
  });
}

void ShellWindows::start() {
  m_started = true;
  for (ShellRuntime* runtime : std::as_const(m_runtimes)) runtime->start();
}

void ShellWindows::reopen() {
  if (ShellRuntime* runtime = m_runtimes.value(m_shell->main())) runtime->show();
}

void ShellWindows::add(NativeWindow* window) {
  if (m_runtimes.contains(window)) return;
  auto* runtime = new ShellRuntime(m_options, window->bridge(), m_theme, this);
  m_runtimes.insert(window, runtime);
  const QString id = window->id();
  connect(runtime, &ShellRuntime::closed, m_shell, [shell = m_shell, id] { shell->closeWindow(id); }, Qt::QueuedConnection);
  connect(runtime, &ShellRuntime::activated, m_shell, [shell = m_shell, window = QPointer<NativeWindow>(window)] {
    if (window) shell->setActiveWindow(window);
  });
  // ThemeController's resolved theme is the palette under theme.json; any
  // window's says the same, and applying it again is a no-op.
  connect(window->bridge(), &ShellBridge::stateEntryChanged, m_theme, [theme = m_theme](const QString& key, const QVariant& value) {
    if (key == QLatin1String("theme")) theme->applyBaseTheme(value);
  });
  if (m_started) runtime->start();
}
