#pragma once

#include <QObject>
#include <QPointer>
#include <QRect>
#include <QTimer>

#include "MacPlatform.h"

// The "drag HAL-C2 into the list" panel macOS needs beside System Settings
// when a permission can only be granted there by hand (upstream's
// MacPermissionHelper.ts). It sits at the bottom of Settings' list, closes
// once the permission is granted or Settings closes (bringing HAL-C2 back),
// and hides while another app is in front.
//
// `check` (the grant, every second) and `track` (Settings' window, twice a
// second) run on timers while it is open; tests call them directly.
class MacPermissionHelper : public QObject {
  Q_OBJECT

public:
  MacPermissionHelper(MacPlatform* platform, QObject* parent = nullptr);

  // Opens the panel for `permission`, unless it is already granted.
  void show(const QString& permission);
  // Closes it without bringing HAL-C2 back.
  void close();
  bool open() const { return !m_permission.isEmpty(); }
  QString permission() const { return m_permission; }
  bool visible() const { return m_visible; }
  QRect bounds() const { return m_bounds; }

  void check();
  void track();

  static inline const QString kText = QStringLiteral("↑ Drag HAL-C2 into the list above");
  // Where the panel goes over a Settings window at `settings`: centred under
  // its list, past the sidebar, along the bottom.
  static QRect boundsBeside(const QRect& settings);

private:
  bool granted() const;
  // Closes and brings HAL-C2 back.
  void finish();

  QPointer<MacPlatform> m_platform;
  QString m_permission;
  bool m_visible = false;
  // Settings' window was seen, so its going away closes the panel.
  bool m_found = false;
  QRect m_bounds;
  QTimer m_checks;
  QTimer m_tracking;
};
