#pragma once

#include <QHash>
#include <QObject>
#include <QUrl>

#include <memory>
#include <vector>

#include "NativeController.h"
#include "NodeClient.h"
#include "ShellStore.h"
#include "SidebarController.h"

class ShellBridge;

// The shell's own client of its node: one protocol-3 connection, the shell
// shape folded into rows, the sidebar, and the registered controllers
// (NativeController.h) that take the composer's turn RPCs, the terminal drawer,
// this machine's cluster settings and whatever moves next off the page. Until the first shell snapshot lands the page keeps doing
// everything; after it, `native` (and a `shell.native` action to the page) says
// which keys and actions the shell now owns. The sidebar stays with the page
// while it groups projects from outside the node's cluster.
//
// The page's saved environments outside the cluster (`environmentAccess`:
// origin and access token per environment the page is connected to) are lent
// to the node (HalC2.Links.borrow), so the node reaches them with what the
// page already paired, and taken back when the page forgets one.
class NativeShell : public QObject {
  Q_OBJECT

public:
  explicit NativeShell(ShellBridge* bridge, QObject* parent = nullptr);

  void open(const QUrl& origin, const QString& token) { m_client.open(origin, token); }

  NodeClient* client() { return &m_client; }
  SidebarController* sidebar() { return &m_sidebar; }
  // The registered controller of type T, or null.
  template <class T>
  T* controller() const {
    for (const Controller& entry : m_controllers) {
      if (auto* found = qobject_cast<T*>(entry.object.get())) return found;
    }
    return nullptr;
  }
  // Registers the controllers that name one as `HalC2.Shell` singletons.
  void registerQmlSingletons() const;

private:
  void update();
  void announce();
  void lend();

  ShellBridge* m_bridge;
  // Environment id -> the token lent to the node over the current connection.
  // Before m_client, which still reports its calls and readiness as it goes.
  QHash<QString, QString> m_lent;
  NodeClient m_client;
  ShellStore m_store;
  // Not registered: it is the one piece that goes back to the page, while the
  // page groups projects from outside the node's cluster.
  SidebarController m_sidebar;
  struct Controller {
    // Owned here rather than by QObject parenting, so they go before the
    // client and store they use.
    std::unique_ptr<QObject> object;
    NativeController* native;
    const char* qmlName;
  };
  std::vector<Controller> m_controllers;
  // Whether the controllers have taken over from the page.
  bool m_active = false;
};
