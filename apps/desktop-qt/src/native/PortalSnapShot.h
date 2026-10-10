#pragma once

#ifdef HAL_C2_HAS_DBUS

#include <QDBusMessage>
#include <QDBusServiceWatcher>
#include <QObject>
#include <QPointer>
#include <QTimer>
#include <QVariantMap>

#include <utility>

#include <functional>

#include "SnapShotBackend.h"

// One xdg-desktop-portal Request: its Response, or a failure when the portal
// never answers. Deletes itself once it has answered.
class PortalRequest : public QObject {
  Q_OBJECT

public:
  using Done = std::function<void(uint status, const QVariantMap& results)>;
  PortalRequest(const QString& handle, int timeoutMs, Done done, QObject* parent);
  QString handle() const { return m_handle; }
  // The portal's handle, when it differs from the one expected.
  void moveTo(const QString& handle);
  void finish(uint status, const QVariantMap& results);

public slots:
  void response(uint status, const QVariantMap& results) { finish(status, results); }

private:
  void listen(bool on);

  QString m_handle;
  QTimer m_timeout;
  Done m_done;
};

// Snap Shot through xdg-desktop-portal on a Wayland desktop: the Screenshot portal
// takes the window in front where it offers that target (version 3 and
// AvailableTargets' window bit), else opens its picker; the GlobalShortcuts
// portal holds one session with the capture shortcut. Nothing is asked of
// the bus until `probe()` or `bind()`.
class PortalSnapShot : public SnapShotBackend {
  Q_OBJECT

public:
  PortalSnapShot(const Platform& platform, QObject* parent = nullptr);
  ~PortalSnapShot() override;

  Session session() const override { return m_session; }
  Shortcut shortcut() const override { return m_shortcut; }
  void probe() override;
  void bind(const QString& trigger) override;
  void release() override;
  void configure() override;
  void capture() override;

private slots:
  void onShortcutSignal(const QDBusMessage& message);
  void onSessionClosed(const QDBusMessage& message);
  void onOwnerChanged(const QString& service, const QString& oldOwner, const QString& newOwner);

private:
  // Calls a portal method that answers through a Request, with `options`
  // gaining its handle_token; `done` gets the Response.
  void request(const QString& interface, const QString& method, QVariantList arguments, QVariantMap options, int timeoutMs,
               PortalRequest::Done done);
  QString requestPrefix() const;
  void registerApp();
  void setShortcut(const Shortcut& shortcut);
  // Ends the session (letting the shortcut go) without saying so.
  void closeSession();
  void bound(const QVariant& shortcuts);
  void shortcutFailed(const QString& message);

  Session m_session;
  Shortcut m_shortcut;
  bool m_probing = false;
  bool m_registered = false;
  // The GlobalShortcuts portal's version; 0 until read.
  uint m_shortcutsVersion = 0;
  QString m_trigger;
  QString m_shortcutId;
  QString m_sessionHandle;
  // Bumped whenever the session is dropped, so a late answer for the one
  // before is ignored.
  quint64 m_generation = 0;
  QDBusServiceWatcher m_watcher;
  bool m_capturing = false;
};

#endif
