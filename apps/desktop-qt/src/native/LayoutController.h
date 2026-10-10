#pragma once

#include <QObject>

#include "NativeController.h"

class McClient;
class ShellBridge;

// The window's layout the shell keeps itself: whether the thread list is
// hidden, how wide it is, and the app's zoom. Remembered on this device
// (`sidebarCollapsed`, `sidebarWidth` and `zoomLevel` in its preferences);
// every window follows the zoom.
//
// Publishes `layout` for ShellWindow: {sidebarCollapsed, sidebarWidth (what
// it draws: the width chosen, less when the window leaves it no room), zoom
// (a factor)}. Action and keybinding command: `sidebar.toggle` (the sidebar's
// hide button, the header's show button, mod+b). `sidebar.resize {width}`
// sets the width chosen (no width: back to the default), and
// `layout.window {width}` says how wide the window is. Commands `view.zoomIn`,
// `view.zoomOut` and `view.resetZoom` (the application menu's mod+= and
// mod++, mod+-, mod+0).
class LayoutController : public QObject, public NativeController {
  Q_OBJECT

public:
  LayoutController(ShellBridge* bridge, McClient* client, QObject* parent = nullptr);

  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;

  bool sidebarCollapsed() const { return m_sidebarCollapsed; }
  void setSidebarCollapsed(bool collapsed);
  void toggleSidebar() { setSidebarCollapsed(!m_sidebarCollapsed); }
  // Chromium's zoom level: each step of 0.5 is a factor of 1.2^0.5.
  double zoomLevel() const { return m_zoomLevel; }
  double zoom() const;
  void setZoomLevel(double level);
  // The thread list's width: the default and minimum, and the room the
  // thread keeps beside it.
  static constexpr int kSidebarWidth = 256;
  static constexpr int kSidebarMinWidth = 208;
  static constexpr int kContentMinWidth = 480;
  // The width drawn now.
  int sidebarWidth() const;
  // The width the user chose (the default when none), at least the minimum
  // and no more than the window allows.
  void setSidebarWidth(int width);
  void resetSidebarWidth();
  // The window's width, so the list shrinks to fit a narrow one.
  void setWindowWidth(int width);
  // How long a panel takes to open or close, in ms: the Panel animations
  // setting, or none when motion is reduced (the Reduce motion setting, or
  // the system's preference where the platform reports it).
  int panelAnimationMs() const;
  // The system's preference (main.cpp asks the platform); every window follows it.
  static void setSystemReducedMotion(bool reduced);

private:
  void load();
  void publish();

  ShellBridge* m_bridge;
  bool m_loaded = false;
  bool m_active = false;
  bool m_sidebarCollapsed = false;
  double m_zoomLevel = 0;
  int m_sidebarWidth = kSidebarWidth;
  int m_windowWidth = 0;
  // The widest the window leaves room for, or none while it has not said.
  int sidebarRoom() const;
};
