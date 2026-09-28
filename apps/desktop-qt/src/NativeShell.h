#pragma once

#include <QObject>
#include <QUrl>

#include "ComposerController.h"
#include "NodeClient.h"
#include "ShellStore.h"
#include "SidebarController.h"
#include "TerminalController.h"

class ShellBridge;

// The shell's own client of its node: one protocol-3 connection, the shell
// shape folded into rows, and the controllers that take the sidebar, the
// composer's turn RPCs and the terminal drawer off the page. Until the first
// shell snapshot lands the page keeps doing everything; after it, `native`
// (and a `shell.native` action to the page) says which keys and actions the
// shell now owns. The sidebar stays with the page while it groups projects
// from outside the node's cluster.
class NativeShell : public QObject {
  Q_OBJECT

public:
  explicit NativeShell(ShellBridge* bridge, QObject* parent = nullptr);

  void open(const QUrl& origin, const QString& token) { m_client.open(origin, token); }

  NodeClient* client() { return &m_client; }
  SidebarController* sidebar() { return &m_sidebar; }
  ComposerController* composer() { return &m_composer; }
  TerminalController* terminals() { return &m_terminals; }

private:
  void update();
  void announce();

  ShellBridge* m_bridge;
  NodeClient m_client;
  ShellStore m_store;
  SidebarController m_sidebar;
  ComposerController m_composer;
  TerminalController m_terminals;
};
