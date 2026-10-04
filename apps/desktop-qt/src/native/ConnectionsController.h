#pragma once

#include <QJsonArray>
#include <QJsonObject>
#include <QObject>
#include <QVariantMap>

#include <functional>

#include "NativeController.h"

class McClient;
class ShellBridge;

// The Connections settings page, which the shell owns: who may reach this MC
// (`HalC2.Auth`: pairing links and paired clients, live through the
// `authAccess` shape while the page is open). Other machines join on the
// Cluster page (ClusterController).
// Publishes `connections`:
//   {access: {pairingLinks, clients} | null, accessError, busy, notice,
//    created: {id, label, url, code, expiresAt} | null, revealed (the clipboard
//    refused the link, which is shown to copy by hand)}
// The page shows while the route is the settings section
// "/settings/connections" (NavigationController takes connections.open and
// connections.close). Managing access needs an administrative session; the
// MC's refusal becomes `accessError` or the notice.
class ConnectionsController : public QObject, public NativeController {
  Q_OBJECT

public:
  ConnectionsController(ShellBridge* bridge, McClient* client, QObject* parent = nullptr);

  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;

  // Puts text on the clipboard, false when it could not; the system's unless tests say.
  void setClipboardWriter(std::function<bool(const QString& text)> write) { m_copy = std::move(write); }

private:
  void setOpen(bool open);
  void watchAccess();
  void onAccess(const QJsonObject& frame);
  void publishAccess();
  void createPairingLink(const QVariantMap& input);
  void change(const QString& method, const QJsonObject& payload,
              std::function<void(const QJsonObject& result)> done, const QString& failure);
  void setNotice(const QString& kind, const QString& text);
  void set(const QString& field, const QVariant& value);
  void publish();

  ShellBridge* m_bridge;
  McClient* m_client;
  QVariantMap m_state;
  // The access list as the MC last described it, while the page is open.
  QJsonArray m_pairingLinks;
  QJsonArray m_clients;
  int m_accessSubscription = -1;
  bool m_active = false;
  bool m_open = false;
  std::function<bool(const QString& text)> m_copy;
};
