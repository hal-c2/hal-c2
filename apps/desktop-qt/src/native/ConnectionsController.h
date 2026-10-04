#pragma once

#include <QJsonArray>
#include <QJsonObject>
#include <QObject>
#include <QVariantMap>

#include <functional>

#include "NativeController.h"

class McClient;
class ShellBridge;
class ShellStore;

// The Connections settings page, which the shell owns: the environments the
// MC is linked to (apps/server-ex `HalC2.Links`, from the shell shape's
// links), and who may reach this MC (`HalC2.Auth`: pairing links and paired
// clients, live through the `authAccess` shape while the page is open).
// Publishes `connections`:
//   {links: [{environmentId, label, origin, online, problem, status}],
//    access: {pairingLinks, clients} | null, accessError, busy, notice,
//    created: {id, label, url, code, expiresAt} | null, revealed (the clipboard
//    refused the link, which is shown to copy by hand), removing,
//    balancing: null | {enabled, environments: [{environmentId, label, weight,
//    preference}]}}
// `balancing` is this device's load balancing (the web's LoadBalancingSettings),
// there once two machines can be balanced: whether new threads pick their
// machine, and how often each should get them (weight 100 "Prefer", 50
// "Normal", 25 "Less often", 0 "Manual only"; a weight an older build saved
// snaps to the nearest). `connections.balancing.enabled {enabled}` and
// `connections.balancing.preference {environmentId, weight}` change it; the
// preferences stay while it is off.
// The page shows while the route is the settings section
// "/settings/connections" (NavigationController takes connections.open and
// connections.close). Managing access needs an administrative session; the
// MC's refusal becomes `accessError` or the notice.
class ConnectionsController : public QObject, public NativeController {
  Q_OBJECT

public:
  ConnectionsController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent = nullptr);

  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;

  // Puts text on the clipboard, false when it could not; the system's unless tests say.
  void setClipboardWriter(std::function<bool(const QString& text)> write) { m_copy = std::move(write); }

private:
  void setOpen(bool open);
  void watchAccess();
  void onAccess(const QJsonObject& frame);
  void publishAccess();
  void updateLinks();
  void updateBalancing();
  void link(const QString& pairingUrl, const QString& fallbackUrl);
  void unlink(const QString& environmentId);
  void createPairingLink(const QVariantMap& input);
  void change(const QString& method, const QJsonObject& payload,
              std::function<void(const QJsonObject& result)> done, const QString& failure);
  QString labelOf(const QString& environmentId) const;
  void setNotice(const QString& kind, const QString& text);
  void set(const QString& field, const QVariant& value);
  void publish();

  ShellBridge* m_bridge;
  McClient* m_client;
  ShellStore* m_store;
  QVariantMap m_state;
  // The access list as the MC last described it, while the page is open.
  QJsonArray m_pairingLinks;
  QJsonArray m_clients;
  int m_accessSubscription = -1;
  bool m_active = false;
  bool m_open = false;
  std::function<bool(const QString& text)> m_copy;
};
