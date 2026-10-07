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

// The Connections settings page, which the shell owns: who may reach this MC
// (`HalC2.Auth`: pairing links and paired clients, live through the
// `authAccess` shape while the page is open). Other machines join on the
// Cluster page (ClusterController).
// Publishes `connections`:
//   {access: {pairingLinks, clients} | null, accessError, busy, notice,
//    machines: [{id, label}] (the cluster's machines that are online, a pairing
//    link can be for any of them; the shell's own MC first),
//    created: {id, label, url, code, expiresAt, environmentId, machine (its
//    label), elsewhere (not the shell's own MC: its link is not in `access`),
//    localOnly (only that machine can open the link), qr: {modules, path} |
//    null (the link as a QR code, qr::path; none for a local-only link)} | null,
//    revealed (the clipboard refused the link, which is shown to copy by hand)}
// `connections.pairingLink.create {label, scopes, environmentId, tailscale}`
// asks the machine named (the shell's own MC when none is) for the link, over
// Tailscale Serve when asked; the MC answers with the address it is reached at.
// A link that arrives after the page closed, or after another was asked for, is
// revoked on its machine instead of shown.
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
  void createPairingLink(const QVariantMap& input);
  // Revokes a link nobody can use on the machine that made it, saying nothing:
  // it is not left behind.
  void discard(const QString& environmentId, const QString& id);
  // Reads the machines a pairing link can be for; true when they changed.
  bool readMachines();
  // Calls `method` on the MC of `environmentId`.
  void change(const QString& environmentId, const QString& method, const QJsonObject& payload,
              std::function<void(const QJsonObject& result)> done, const QString& failure);
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
  // The pairing link the page last asked for, counted; closing the page counts
  // too, so the answer to any other request is discarded.
  quint64 m_linkRequest = 0;
  bool m_active = false;
  bool m_open = false;
  std::function<bool(const QString& text)> m_copy;
};
