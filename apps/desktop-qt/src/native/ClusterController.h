#pragma once

#include <QJsonValue>
#include <QObject>
#include <QVariantMap>

#include <functional>

#include "NativeController.h"

class NodeClient;
class ShellBridge;

// This machine's cluster, a settings page the shell owns (apps/server-ex
// `HalC2.Cluster`): the node does the work of status, invite, join and remove
// over the shell's own connection (`cluster.*` RPCs). Publishes `cluster`:
// {busy, status, error, invite, notice}. The page shows while the route is
// the settings section "/settings/cluster" (NavigationController, which takes
// cluster.open and cluster.close).
class ClusterController : public QObject, public NativeController {
  Q_OBJECT

public:
  ClusterController(ShellBridge* bridge, NodeClient* client, QObject* parent = nullptr);

  // Once the shell has its node: publishes `cluster`, so the settings nav
  // offers the page.
  void activate() override;
  bool isActive() const { return m_active; }

  bool handle(const QString& action, const QVariant& payload) override;

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
  // Whether the route shows this page.
  bool m_open = false;
  // Bumped by every read and change; a read's answer lands only if nothing was asked since.
  quint64 m_generation = 0;
};
