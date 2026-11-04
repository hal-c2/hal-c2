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
// Publishes `layout` for ShellWindow: {sidebarCollapsed (nothing of the list
// is drawn), sidebarWidth (what it draws: the width chosen, less when the
// window leaves it no room, never under the minimum; the rail's in a narrow
// window), sidebarMode ("full" two-line rows, "slim" one-line rows in a window
// under 1100, "rail" a column of icons in one under 860), sidebarOverlay (the
// full list is drawn over the thread: the rail's way back to full width),
// contentMinimumWidth (the room the thread keeps: a side panel that would
// leave it less goes over it instead), zoom (a factor)}.
// A narrow window keeps the list beside the thread as the rail, or nothing if
// the user hid it; `sidebar.toggle` there opens the full list over the thread
// and puts it away again, without that being remembered: the device keeps
// what a window with room last chose. A window whose layout has no slim rows
// or rail (the phone's tablet layout, `modes: false`) keeps the full list,
// and is narrow only with no room for the list's minimum beside the thread,
// where it shows nothing until toggled open over it. Action and keybinding command:
// `sidebar.toggle` (the sidebar's hide button, the header's show button, the
// rail's expand button, mod+b). `sidebar.resize {width}` sets the width
// chosen (no width: back to the default), and `layout.window {width,
// monospace, modes}` says how wide the window is, whether its interface font
// is monospaced, which widens the default, and whether its layout draws the
// slim rows and the rail (kept when left out; on until a window says). Commands `view.zoomIn`,
// `view.zoomOut` and `view.resetZoom` (the application menu's mod+= and
// mod++, mod+-, mod+0).
class LayoutController : public QObject, public NativeController {
  Q_OBJECT

public:
  LayoutController(ShellBridge* bridge, McClient* client, QObject* parent = nullptr);

  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;

  // Whether nothing of the list is drawn: hidden by the user, and in a
  // narrow window not opened over the thread; without the rail, a narrow
  // window shows nothing until it is.
  bool sidebarCollapsed() const {
    if (!m_modes && narrow()) return !m_overlayOpen;
    return m_sidebarCollapsed && !sidebarOverlay();
  }
  // Hides or shows the list; in a narrow window, closes or opens it over the thread.
  void setSidebarCollapsed(bool collapsed);
  void toggleSidebar();
  // The window is too narrow for the full list beside the thread: it keeps
  // a rail there instead. Without the rail, too narrow for its minimum.
  bool narrow() const {
    return m_windowWidth > 0 && m_windowWidth < (m_modes ? kRailBelow : kSidebarMinWidth + kContentMinWidth);
  }
  // The rail is drawn beside the thread.
  bool rail() const { return m_modes && narrow() && !m_overlayOpen; }
  // The full list is drawn over the thread.
  bool sidebarOverlay() const { return narrow() && m_overlayOpen; }
  // How the list draws: "full", "slim" or "rail".
  QString sidebarMode() const;
  // Chromium's zoom level: each step of 0.5 is a factor of 1.2^0.5.
  double zoomLevel() const { return m_zoomLevel; }
  double zoom() const;
  void setZoomLevel(double level);
  // The thread list's width: the default (wider in a monospace interface)
  // and minimum, the rail's, and the room the thread keeps beside it.
  static constexpr int kSidebarWidth = 256;
  static constexpr int kSidebarMonospaceWidth = 272;
  static constexpr int kSidebarMinWidth = 208;
  static constexpr int kRailWidth = 48;
  static constexpr int kContentMinWidth = 480;
  // The window widths under which the rows go slim, and the list a rail.
  static constexpr int kSlimBelow = 1100;
  static constexpr int kRailBelow = 860;
  // The default width for the window's interface font.
  int defaultSidebarWidth() const { return m_monospace ? kSidebarMonospaceWidth : kSidebarWidth; }
  // The width drawn now.
  int sidebarWidth() const;
  // The width the user chose, at least the minimum and no more than the
  // window allows; the reset goes back to the default, whatever the window.
  void setSidebarWidth(int width);
  void resetSidebarWidth();
  // The window's width, so the list shrinks to fit a narrow one and becomes
  // a rail in one with no room for both, and whether its interface font is
  // monospaced.
  void setWindowWidth(int width);
  void setMonospace(bool monospace);
  // Whether the window's layout draws the slim rows and the rail.
  void setModes(bool modes);
  // How long a panel takes to open or close, in ms: the Panel animations
  // setting, or none when motion is reduced (the Reduce motion setting, or
  // the system's preference where the platform reports it).
  int panelAnimationMs() const;
  // The system's preference (main.cpp asks the platform); every window follows it.
  static void setSystemReducedMotion(bool reduced);
  static bool systemReducedMotion();

private:
  void load();
  void publish();
  // What publish() says.
  QVariantMap state() const;
  // Changes the window and publishes what that changed.
  template <typename Change> void changeWindow(Change change);

  ShellBridge* m_bridge;
  bool m_loaded = false;
  bool m_active = false;
  bool m_sidebarCollapsed = false;
  // Opened over the thread in a narrow window (sidebarOverlay); forgotten
  // when the window widens.
  bool m_overlayOpen = false;
  double m_zoomLevel = 0;
  // The width the user chose, or 0 for the default.
  int m_sidebarWidth = 0;
  int m_windowWidth = 0;
  bool m_monospace = false;
  bool m_modes = true;
  // The widest the window leaves room for, or none while it has not said.
  int sidebarRoom() const;
  // Remembers the width chosen, 0 for the default.
  void chooseSidebarWidth(int width);
};
