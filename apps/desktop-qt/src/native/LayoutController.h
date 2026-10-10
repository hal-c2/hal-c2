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
// it draws: the width chosen, less when the window leaves it no room, never
// under the minimum), sidebarOverlay (the window is too narrow for the list
// beside the thread, so a layout draws it over the thread), zoom (a factor)}.
// While `sidebarOverlay`, the list starts hidden and showing it is not
// remembered: the device keeps what a window with room last chose. Action and
// keybinding command: `sidebar.toggle` (the sidebar's hide button, the
// header's show button, mod+b). `sidebar.resize {width}` sets the width
// chosen (no width: back to the default), and `layout.window {width}` says
// how wide the window is. Commands `view.zoomIn`, `view.zoomOut` and
// `view.resetZoom` (the application menu's mod+= and mod++, mod+-, mod+0).
class LayoutController : public QObject, public NativeController {
  Q_OBJECT

public:
  LayoutController(ShellBridge* bridge, McClient* client, QObject* parent = nullptr);

  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;

  // Whether the list is hidden now: in a window too narrow for it beside
  // the thread, until the user shows it over the thread.
  bool sidebarCollapsed() const { return sidebarOverlay() ? !m_overlayOpen : m_sidebarCollapsed; }
  void setSidebarCollapsed(bool collapsed);
  void toggleSidebar() { setSidebarCollapsed(!sidebarCollapsed()); }
  // The window cannot fit the list at its minimum beside the thread.
  bool sidebarOverlay() const { return m_windowWidth > 0 && m_windowWidth < kSidebarMinWidth + kContentMinWidth; }
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
  // The window's width, so the list shrinks to fit a narrow one and goes
  // over the thread in one with no room for both.
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
  // Shown over the thread (sidebarOverlay); forgotten when the window widens.
  bool m_overlayOpen = false;
  double m_zoomLevel = 0;
  int m_sidebarWidth = kSidebarWidth;
  int m_windowWidth = 0;
  // The widest the window leaves room for, or none while it has not said.
  int sidebarRoom() const;
};
