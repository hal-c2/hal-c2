#pragma once

#ifdef HAL_C2_HAS_DBUS

#include <QByteArray>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusVirtualObject>
#include <QJsonObject>
#include <QJsonValue>
#include <QLocalSocket>
#include <QTemporaryDir>
#include <QTimer>

#include <functional>
#include <memory>

#include "SnapShotBackend.h"

// Niri outside a sandbox: capture over its IPC socket ($NIRI_SOCKET), which
// names the focused window without asking, and the shortcut from a binding in
// Niri's own config (CaptureShortcutConfig) that calls the D-Bus endpoint this
// class owns, `<app id>.SnapShot`.
//
// `shortcut().registered` is that endpoint being up: HAL-C2 cannot see whether
// the binding is in the config, so `bind` and `release` do nothing.
class NiriSnapShot : public SnapShotBackend {
  Q_OBJECT

public:
  NiriSnapShot(const Platform& platform, const QString& socket, QObject* parent = nullptr);
  ~NiriSnapShot() override;

  // $NIRI_SOCKET when it is usable, else empty.
  static QString socketPath(const QProcessEnvironment& env);

  Session session() const override { return m_session; }
  Shortcut shortcut() const override { return m_shortcut; }
  void probe() override;
  void capture() override;

  static constexpr int kTimeoutMs = 5'000;
  static constexpr qint64 kMaxMessage = 4 * 1024 * 1024;

private slots:
  void onNameLost(const QString& name);
  void onBusDisconnected();

private:
  class Endpoint;
  struct Capture;

  void startEndpoint();
  void endpointFailed();
  // Asks Niri `request` on a connection of its own: `done` gets the reply's
  // Ok, or the reason in `error`.
  void ask(const QJsonValue& request, std::function<void(const QJsonValue& ok, const QString& error)> done);
  void focused();
  void screenshot(const QJsonObject& window);
  void onEvent(const QJsonObject& event);
  void finish(const QString& failure);

  QString m_socket;
  QString m_name;
  Session m_session;
  Shortcut m_shortcut;
  bool m_probing = false;
  std::unique_ptr<Endpoint> m_endpoint;
  std::unique_ptr<Capture> m_capture;
};

#endif  // HAL_C2_HAS_DBUS
