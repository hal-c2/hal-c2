#pragma once

#include <QJsonValue>
#include <QObject>
#include <QVariantMap>

#include <functional>

class NodeClient;
class ShellBridge;

// This machine's cluster, a settings page the shell owns (apps/server-ex
// `HalC2.Cluster`): the node does the work of status, invite, join and remove
// over the shell's own connection (`cluster.*` RPCs). Publishes `cluster`:
// {open, busy, status, error, invite, notice}; `open` puts the window in
// settings with this page showing (ShellWindow.settingsPage).
class ClusterController : public QObject {
  Q_OBJECT

public:
  ClusterController(ShellBridge* bridge, NodeClient* client, QObject* parent = nullptr);

  // Once the shell has its node: publishes `cluster`, so the settings nav
  // offers the page.
  void activate();
  bool isActive() const { return m_active; }

  // The ShellBridge interceptor: true when the action was handled here.
  bool handle(const QString& action, const QVariant& payload);

private:
  void refresh();
  void invite(bool tailscale);
  void change(const QString& method, const QJsonObject& payload, const QString& success, const QString& failure);
  void call(const QString& method, const QJsonObject& payload,
            std::function<void(const QJsonValue& result, const std::optional<QString>& error)> reply);
  void setNotice(const QString& kind, const QString& text);
  void set(const QString& field, const QVariant& value);
  void publish();

  ShellBridge* m_bridge;
  NodeClient* m_client;
  QVariantMap m_state;
  bool m_active = false;
};
