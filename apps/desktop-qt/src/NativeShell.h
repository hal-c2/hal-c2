#pragma once

#include <QHash>
#include <QObject>
#include <QUrl>

#include "ClusterController.h"
#include "ComposerController.h"
#include "NodeClient.h"
#include "ShellStore.h"
#include "SidebarController.h"
#include "TerminalController.h"

class ShellBridge;

// The shell's own client of its node: one protocol-3 connection, the shell
// shape folded into rows, and the controllers that take the sidebar, the
// composer's turn RPCs, the terminal drawer and this machine's cluster settings
// off the page. Until the first shell snapshot lands the page keeps doing
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
  ComposerController* composer() { return &m_composer; }
  TerminalController* terminals() { return &m_terminals; }
  ClusterController* cluster() { return &m_cluster; }

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
  SidebarController m_sidebar;
  ComposerController m_composer;
  TerminalController m_terminals;
  ClusterController m_cluster;
};
