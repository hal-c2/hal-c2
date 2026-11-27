#pragma once

#include <QJsonObject>
#include <QPointer>
#include <QTimer>

#include <optional>

#include "MacPermissionHelper.h"
#include "MacPlatform.h"
#include "SnapShotBackend.h"

// Snap Shot on macOS (upstream's DesktopSnapShot "direct" mode on darwin):
// capture needs Screen Recording, and Accessibility too when captures
// include the app's text. The shortcut is a key chord or both keys of one
// modifier (both Shift keys by default), watched in-process.
//
// `bind` takes the shortcut's JSON (SnapShotBackend::trigger). While
// a shortcut is asked for and a permission it needs is missing, the session
// says which and nothing is held; once the permission is back (a refresh),
// the shortcut is held again without a restart.
//
// Permissions are read on probe and refresh, and polled while setup shows
// them (`watchPermissions`); a read that fails keeps the last answer and
// says it will try again.
class MacSnapShot : public SnapShotBackend {
  Q_OBJECT

public:
  MacSnapShot(MacPlatform* platform, QObject* parent);
  ~MacSnapShot() override;

  Session session() const override;
  Shortcut shortcut() const override { return m_shortcut; }
  void probe() override;
  void refresh() override;
  void bind(const QString& trigger) override;
  void release() override;
  void configure() override;
  void capture() override;
  void setIncludeAccessibility(bool include) override;
  void watchPermissions(bool on) override;
  void checkShortcut(const QJsonObject& shortcut, std::function<void(const Check&)> done) override;
  // Sends the user to System Settings, with the panel beside it, for a
  // permission only Settings can grant.
  QString requestPermissions(bool includeAccessibility) override;
  void allow(const QString& permission) override;
  void test() override;

  MacPermissionHelper* helper() { return &m_helper; }
  MacPlatform* platform() const { return m_platform; }

  static inline const QString kCheckFailed = QStringLiteral("Could not check permissions. We'll try again automatically.");

private:
  void read();
  // Holds the asked-for shortcut when the permissions allow, else says why
  // not; `force` takes it again even if held.
  void apply(bool force = false);
  QString permissionMessage() const;
  QString captureError(const MacPlatform::Capture& capture) const;

  QPointer<MacPlatform> m_platform;
  MacPermissionHelper m_helper;
  QTimer m_poll;
  bool m_probed = false;
  bool m_includeAccessibility = true;
  std::optional<MacPlatform::Permissions> m_permissions;
  QString m_permissionsError;
  // The shortcut asked for, and whether the platform holds it now.
  std::optional<QJsonObject> m_asked;
  bool m_holding = false;
  QString m_message;
  Shortcut m_shortcut;
  // A capture is under way; a second press waits for it.
  bool m_capturing = false;
};
