#pragma once

#include <QObject>
#include <QStringList>
#include <QUrl>

#include <memory>
#include <typeindex>
#include <unordered_map>
#include <vector>

#include "LocalCache.h"
#include "NativeController.h"
#include "McClient.h"
#include "ShellStore.h"
#include "SidebarController.h"

class NativeShell;
class QQmlEngine;
class ShellBridge;

struct NativeControllerEntry {
  QString name;
  // Owned by the window or shell that lists it, not by QObject parenting, so
  // they go before the client and store they use.
  std::unique_ptr<QObject> object;
  NativeController* native;
  const char* qmlName;
};

// One window's view of the MC: its bridge (the `Shell` its QML reads), its
// sidebar, and one of each per-window controller (the route, the composer, the
// panels, the terminal drawer, the palette, toasts...). Everything else, and
// the MC connection itself, is the NativeShell's, one per process: the
// drafts and composer text too, which every window's controllers keep in one
// store (NativeShell::common) so closing a window loses no unsent work.
class NativeWindow : public QObject {
  Q_OBJECT

public:
  // The id of the window that keeps its route and panels directly in the
  // state folder: the first one, on a first launch.
  static inline const QString kMain = QStringLiteral("main");

  NativeWindow(NativeShell* shell, const QString& id, ShellBridge* bridge, std::unique_ptr<ShellBridge> owned = {});
  ~NativeWindow() override;

  QString id() const { return m_id; }
  NativeShell* shell() const { return m_shell; }
  ShellBridge* bridge() const { return m_bridge; }
  SidebarController* sidebar() { return &m_sidebar; }
  // This window's controller of type T, else the shared one, or null.
  template <class T>
  T* controller() const;
  // The QML singleton `qmlName` as this window's QML sees it.
  QObject* singleton(const char* qmlName) const;

  // Where it keeps its route and panels.
  void setStoreDirs(const QString& state);

private:
  friend class NativeShell;
  void activate();
  // Shows the cached sidebar and the thread the window was left on.
  void preview();
  bool handle(const QString& action, const QVariant& payload);

  NativeShell* m_shell;
  QString m_id;
  std::unique_ptr<ShellBridge> m_ownedBridge;
  ShellBridge* m_bridge;
  // Not registered: the interceptor asks it first, before the controllers.
  SidebarController m_sidebar;
  std::vector<NativeControllerEntry> m_controllers;
  // This window's and the shared controllers, in name order: who sees an
  // action first.
  std::vector<NativeController*> m_handlers;
};

// The shell's own client of its MC: one protocol-3 connection, the shell
// shape folded into rows, and its windows (NativeWindow), each with its own
// sidebar and controllers (NativeController.h): the composer's turn RPCs, the
// terminal drawer, navigation and the rest, beside the shared ones every
// window reads alike (settings, alerts, quitting). The controllers start once
// the first shell snapshot lands; until then the windows show the sidebar and
// the open thread the cache kept (LocalCache), which nothing acts on.
class NativeShell : public QObject {
  Q_OBJECT

public:
  explicit NativeShell(ShellBridge* bridge, QObject* parent = nullptr);
  ~NativeShell() override;

  // Connects to the MC at `origin`; every window's bridge learns where it is.
  void open(const QUrl& origin, const QString& token);
  // Leaves the MC for good: the connection closes, and the rows of its
  // machines, what the cache kept of them and every draft go. The controllers
  // stay, for whichever MC open() names next. Not for reconnecting
  // (McClient::reconnect).
  void close();

  McClient* client() { return &m_client; }
  ShellStore* store() { return &m_store; }
  // What the client keeps of the MC between runs (setStoreDirs' `cache`).
  LocalCache* cache() { return &m_cache; }
  // The main window's.
  SidebarController* sidebar() { return main()->sidebar(); }
  // The main window's controller of type T, else the shared one, or null.
  template <class T>
  T* controller() const {
    return main()->controller<T>();
  }
  // The shared controller of type T, or null.
  template <class T>
  T* shared() const {
    for (const NativeControllerEntry& entry : m_shared) {
      if (auto* found = qobject_cast<T*>(entry.object.get())) return found;
    }
    return nullptr;
  }
  // The window `controller` belongs to, for reaching a sibling:
  // NativeShell::of(this)->controller<ToastController>(). A shared
  // controller's is the window the user acts in (activeWindow).
  static NativeWindow* of(const QObject* controller);

  // The oldest open window. There is always one: the last to close stays,
  // hidden, for the next launch (or macOS's reopen).
  NativeWindow* main() const { return m_windows.front().get(); }
  const std::vector<std::unique_ptr<NativeWindow>>& windows() const { return m_windows; }
  NativeWindow* window(const QString& id) const;
  // The window the user last acted in (dispatched from, or focused).
  NativeWindow* activeWindow() const { return m_activeWindow ? m_activeWindow : main(); }
  void setActiveWindow(NativeWindow* window) { m_activeWindow = window; }
  // Opens another window (`window.new`), or the one `id` names; it reopens
  // with its own route, drafts and panels after a restart until it closes.
  NativeWindow* openWindow(const QString& id = {});
  // The user closed a window: it goes, with its route and panels, and the
  // others stay. The last one stays too, and says so (lastWindowClosed).
  void closeWindow(const QString& id);

  // The one T every window's controllers keep alike (DraftController's
  // drafts, ComposerController's text), made on first use.
  template <class T>
  T& common() {
    std::shared_ptr<void>& slot = m_common[std::type_index(typeid(T))];
    if (!slot) slot = std::make_shared<T>();
    return *static_cast<T*>(slot.get());
  }

  // Where windows keep their files: the drafts and composer text in `data`,
  // the route and panels of the window `kMain` directly in `state` and any
  // other's under `shell-windows/<id>/`, and which are open, oldest first, in
  // `<state>/shell-windows.json`. The first window takes the first of those.
  // `cache` holds the client's cache of the MC; without it nothing is cached.
  void setStoreDirs(const QString& state, const QString& data, const QString& cache = {});
  // Opens the rest of the windows that were open when the app last quit.
  void restoreWindows();

  // Registers the controllers that name one as `HalC2.Shell` singletons, each
  // engine getting its window's (ShellRuntime tags an engine with its bridge).
  void registerQmlSingletons();
  NativeWindow* windowFor(QQmlEngine* engine) const;

  // Every registration, in name order, and the keys the shared bridge
  // publishes (the shared controllers' and `backendError`).
  const QList<NativeControllerRegistration>& registrations() const { return m_registrations; }
  const QStringList& sharedKeys() const { return m_sharedKeys; }
  // Whether the MC's first snapshot has landed and the controllers started.
  bool isActive() const { return m_active; }

signals:
  // open() was called with this credential: whoever remembers the MC between
  // runs (the phone's Pairing) keeps the one the shell last connected with.
  void opened(const QUrl& origin, const QString& token);
  void windowOpened(NativeWindow* window);
  // Before `window` goes (deleteLater): whatever shows it should go first.
  void windowClosing(NativeWindow* window);
  // The user closed the one window left, which stays open here: the app
  // quits, or on macOS waits to show it again.
  void lastWindowClosed();
  // The MC's first snapshot arrived and every controller started: the
  // windows show the user's projects and threads. Once per run.
  void ready();

private:
  friend class NativeWindow;
  void update();
  void activate(NativeWindow* window);
  void saveWindows() const;
  // The ids shell-windows.json lists, oldest first.
  QStringList savedWindows() const;
  QString windowDir(const QString& id) const;

  // Before the store and the windows that write to it, so it goes after them.
  LocalCache m_cache;
  McClient m_client;
  ShellStore m_store;
  // The bridge the shared controllers publish on, which every window's
  // mirrors: the first window's, which outlives it.
  ShellBridge* m_sharedBridge;
  QList<NativeControllerRegistration> m_registrations;
  QStringList m_sharedKeys;
  std::vector<NativeControllerEntry> m_shared;
  std::unordered_map<std::type_index, std::shared_ptr<void>> m_common;
  std::vector<std::unique_ptr<NativeWindow>> m_windows;
  NativeWindow* m_activeWindow = nullptr;
  QString m_stateDir;
  // Whether the first snapshot has landed and the controllers have started.
  bool m_active = false;
};

template <class T>
T* NativeWindow::controller() const {
  for (const NativeControllerEntry& entry : m_controllers) {
    if (auto* found = qobject_cast<T*>(entry.object.get())) return found;
  }
  return m_shell->shared<T>();
}
