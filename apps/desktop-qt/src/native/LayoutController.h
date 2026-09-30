#pragma once

#include <QObject>

#include "NativeController.h"

class NodeClient;
class ShellBridge;

// The window's layout the shell keeps itself: whether the thread list is
// hidden, and the app's zoom. Remembered on this device (`sidebarCollapsed`
// and `zoomLevel` in its preferences); every window follows the zoom, as
// Electron's zoom follows the app's origin.
//
// Publishes `layout` for ShellWindow: {sidebarCollapsed, zoom (a factor)}.
// Action and keybinding command: `sidebar.toggle` (the sidebar's hide
// button, the header's show button, mod+b). Commands `view.zoomIn`,
// `view.zoomOut` and `view.resetZoom` (the application menu's mod+= and
// mod++, mod+-, mod+0).
class LayoutController : public QObject, public NativeController {
  Q_OBJECT

public:
  LayoutController(ShellBridge* bridge, NodeClient* client, QObject* parent = nullptr);

  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;

  bool sidebarCollapsed() const { return m_sidebarCollapsed; }
  void setSidebarCollapsed(bool collapsed);
  void toggleSidebar() { setSidebarCollapsed(!m_sidebarCollapsed); }
  // Chromium's zoom level: each step of 0.5 is a factor of 1.2^0.5.
  double zoomLevel() const { return m_zoomLevel; }
  double zoom() const;
  void setZoomLevel(double level);

private:
  void load();
  void publish();

  ShellBridge* m_bridge;
  bool m_loaded = false;
  bool m_active = false;
  bool m_sidebarCollapsed = false;
  double m_zoomLevel = 0;
};
