#pragma once

#include <QObject>

#include "NativeController.h"

class NodeClient;
class ShellBridge;

// The window's layout the shell keeps itself: whether the thread list is
// hidden. Remembered on this device (`sidebarCollapsed` in its preferences).
//
// Publishes `layout` for ShellWindow: {sidebarCollapsed}.
// Action and keybinding command: `sidebar.toggle` (the sidebar's hide
// button, the header's show button, mod+b).
class LayoutController : public QObject, public NativeController {
  Q_OBJECT

public:
  LayoutController(ShellBridge* bridge, NodeClient* client, QObject* parent = nullptr);

  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;

  bool sidebarCollapsed() const { return m_sidebarCollapsed; }
  void setSidebarCollapsed(bool collapsed);
  void toggleSidebar() { setSidebarCollapsed(!m_sidebarCollapsed); }

private:
  void load();
  void publish();

  ShellBridge* m_bridge;
  bool m_loaded = false;
  bool m_active = false;
  bool m_sidebarCollapsed = false;
};
