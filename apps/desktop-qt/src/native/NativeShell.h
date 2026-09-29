#pragma once

#include <QObject>
#include <QStringList>
#include <QUrl>

#include <memory>
#include <typeindex>
#include <unordered_map>
#include <vector>

#include "NativeController.h"
#include "NodeClient.h"
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

// One window's view of the node: its bridge (the `Shell` its QML reads), its
// sidebar, and one of each per-window controller (the route, the composer, the
// panels, the terminal drawer, the palette, toasts...). Everything else, and
// the node connection itself, is the NativeShell's, one per process: the
// drafts and composer text too, which every window's controllers keep in one
// store (NativeShell::common) so closing a window loses no unsent work.
class NativeWindow : public QObject {
  Q_OBJECT

public:
  // The first window, the one main.cpp builds its bridge for.
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
  void announce();
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
  bool m_active = false;
};

// The shell's own client of its node: one protocol-3 connection, the shell
// shape folded into rows, and its windows (NativeWindow), each with its own
// sidebar and controllers (NativeController.h) that take the composer's turn
// RPCs, the terminal drawer and whatever moves next off the page, beside the
// shared ones every window reads alike (settings, alerts, quitting).
// Until the first shell snapshot lands the page keeps doing everything; after
// it the sidebar, and every controller, is the shell's, and `native` (and a
// `shell.native` action to the page) says which keys and actions it owns.
// Environments outside the cluster are the node's links (ConnectionsController).
class NativeShell : public QObject {
  Q_OBJECT

public:
  explicit NativeShell(ShellBridge* bridge, QObject* parent = nullptr);
  ~NativeShell() override;

  void open(const QUrl& origin, const QString& token) { m_client.open(origin, token); }

  NodeClient* client() { return &m_client; }
  ShellStore* store() { return &m_store; }
  // The first window's.
  SidebarController* sidebar() { return main()->sidebar(); }
  // The first window's controller of type T, else the shared one, or null.
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

  NativeWindow* main() const { return m_windows.front().get(); }
  const std::vector<std::unique_ptr<NativeWindow>>& windows() const { return m_windows; }
  NativeWindow* window(const QString& id) const;
  // The window the user last acted in (dispatched from, or focused).
  NativeWindow* activeWindow() const { return m_activeWindow ? m_activeWindow : main(); }
  void setActiveWindow(NativeWindow* window) { m_activeWindow = window; }
  // Opens another window (`window.new`), or the one `id` names; it reopens
  // with its own route, drafts and panels after a restart until it closes.
  NativeWindow* openWindow(const QString& id = {});
  // A window other than the first closed: its route and panels go with it.
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
  // the first window's route and panels directly in `state`, any other's under
  // `shell-windows/<id>/`, and which are open in `<state>/shell-windows.json`.
  void setStoreDirs(const QString& state, const QString& data);
  // Opens the windows that were open when the app last quit.
  void restoreWindows();

  // Registers the controllers that name one as `HalC2.Shell` singletons, each
  // engine getting its window's (ShellRuntime tags an engine with its bridge).
  void registerQmlSingletons();
  NativeWindow* windowFor(QQmlEngine* engine) const;

  // Every registration, in name order, and the keys the shared ones publish.
  const QList<NativeControllerRegistration>& registrations() const { return m_registrations; }
  const QStringList& sharedKeys() const { return m_sharedKeys; }

signals:
  void windowOpened(NativeWindow* window);
  // Before `window` goes (deleteLater): whatever shows it should go first.
  void windowClosing(NativeWindow* window);

private:
  friend class NativeWindow;
  void update();
  void activate(NativeWindow* window);
  void saveWindows() const;

  NodeClient m_client;
  ShellStore m_store;
  QList<NativeControllerRegistration> m_registrations;
  QStringList m_sharedKeys;
  std::vector<NativeControllerEntry> m_shared;
  std::unordered_map<std::type_index, std::shared_ptr<void>> m_common;
  std::vector<std::unique_ptr<NativeWindow>> m_windows;
  NativeWindow* m_activeWindow = nullptr;
  QString m_stateDir;
  // Whether the controllers have taken over from the page.
  bool m_active = false;
};

template <class T>
T* NativeWindow::controller() const {
  for (const NativeControllerEntry& entry : m_controllers) {
    if (auto* found = qobject_cast<T*>(entry.object.get())) return found;
  }
  return m_shell->shared<T>();
}
