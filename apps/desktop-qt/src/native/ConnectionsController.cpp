#include "ConnectionsController.h"

#include <QClipboard>
#include <QGuiApplication>
#include <QUrl>

#include "NativeShell.h"
#include "NavigationController.h"
#include "McClient.h"
#include "QrCode.h"
#include "SettingsScopeController.h"
#include "ShellBridge.h"
#include "ShellStore.h"

namespace {

const NativeControllerRegistrar<ConnectionsController> registrar(QStringLiteral("connections"),
                                                                 {QStringLiteral("connections")});

// The MC refuses access calls and the access list to a session without
// access:read / access:write ("access:write is required").
const QString kNeedsAdmin =
    QStringLiteral("Managing this machine's access needs an administrator session. Pair this desktop with a link "
                   "that grants Manage access.");

QString explain(const QString& error) {
  if (error.startsWith(QLatin1String("access:")) && error.endsWith(QLatin1String(" is required"))) return kNeedsAdmin;
  return error;
}

QVariant null() {
  return QVariant::fromValue(nullptr);
}

// The link a client pairs with: the address its MC is reached at and the code.
// A phone's camera opens it as a page of that MC (`GET /pair`), and the app
// reads it scanned, pasted or handed over by that page.
QString pairingUrl(const QString& address, const QString& code) {
  return address + QStringLiteral("/pair#token=") + code;
}

bool loopback(const QUrl& address) {
  const QString host = address.host();
  return host == QLatin1String("localhost") || host == QLatin1String("127.0.0.1") || host == QLatin1String("::1");
}

}  // namespace

ConnectionsController::ConnectionsController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent)
    : QObject(parent),
      m_bridge(bridge),
      m_client(client),
      m_store(store),
      m_state{
          {QStringLiteral("access"), null()},
          {QStringLiteral("accessError"), null()},
          {QStringLiteral("busy"), false},
          {QStringLiteral("notice"), null()},
          {QStringLiteral("machines"), QVariantList()},
          {QStringLiteral("created"), null()},
      } {}

void ConnectionsController::activate() {
  if (m_active) return;
  m_active = true;
  publish();
  auto* navigation = NativeShell::of(this)->controller<NavigationController>();
  auto opened = [navigation] {
    return navigation->route() == NavigationController::Route::settings(NavigationController::kConnectionsSection);
  };
  setOpen(opened());
  connect(navigation, &NavigationController::changed, this, [this, opened] { setOpen(opened()); });
  // Machines that join, leave, sleep or wake change which ones a link can be for.
  const auto machinesChanged = [this] {
    if (m_open && readMachines()) publish();
  };
  connect(m_store, &ShellStore::changed, this, machinesChanged);
  connect(m_client, &McClient::readyChanged, this, machinesChanged);
}

bool ConnectionsController::handle(const QString& action, const QVariant& payload) {
  if (!m_active || !action.startsWith(QLatin1String("connections."))) return false;
  // Opening and closing the page are the route's (NavigationController).
  if (action == QLatin1String("connections.open") || action == QLatin1String("connections.close")) return false;
  const QVariantMap input = payload.toMap();
  if (action == QLatin1String("connections.refresh")) {
    watchAccess();
  } else if (action == QLatin1String("connections.pairingLink.create")) {
    createPairingLink(input);
  } else if (action == QLatin1String("connections.pairingLink.copy")) {
    const QVariantMap created = m_state.value(QStringLiteral("created")).toMap();
    const bool code = input.value(QStringLiteral("what")) == QLatin1String("code");
    const QString text = created.value(code ? QStringLiteral("code") : QStringLiteral("url")).toString();
    if (!text.isEmpty()) {
      QClipboard* clipboard = QGuiApplication::clipboard();
      const bool copied = m_copy ? m_copy(text) : clipboard != nullptr;
      if (copied && !m_copy) clipboard->setText(text);
      // A clipboard that refuses leaves the link on the page, selected to copy by hand.
      m_state.insert(QStringLiteral("revealed"), !copied);
      if (copied) {
        setNotice(QStringLiteral("success"), code ? QStringLiteral("Pairing code copied.") : QStringLiteral("Pairing link copied."));
      } else {
        setNotice(QStringLiteral("error"), QStringLiteral("Could not copy to the clipboard. Copy the link below by hand."));
      }
    }
  } else if (action == QLatin1String("connections.pairingLink.revoke")) {
    const QString id = input.value(QStringLiteral("id")).toString();
    if (id.isEmpty()) return true;
    // A link made on another machine is that machine's to revoke.
    const QVariantMap created = m_state.value(QStringLiteral("created")).toMap();
    const QString environmentId =
        created.value(QStringLiteral("id")) == id ? created.value(QStringLiteral("environmentId")).toString() : m_client->environment();
    change(environmentId, QStringLiteral("hal-c2.revokePairingLink"), {{QStringLiteral("id"), id}}, [this, id](const QJsonObject&) {
      if (m_state.value(QStringLiteral("created")).toMap().value(QStringLiteral("id")) == id) {
        m_state.insert(QStringLiteral("created"), null());
      }
      setNotice(QStringLiteral("success"), QStringLiteral("Pairing link revoked."));
    }, QStringLiteral("Could not revoke the pairing link"));
  } else if (action == QLatin1String("connections.client.revoke")) {
    const QString id = input.value(QStringLiteral("sessionId")).toString();
    if (id.isEmpty()) return true;
    QString label = QStringLiteral("The client");
    for (const QJsonValue& client : std::as_const(m_clients)) {
      const QJsonObject object = client.toObject();
      if (object.value(QLatin1String("sessionId")) != id) continue;
      const QJsonObject about = object.value(QLatin1String("client")).toObject();
      label = about.value(QLatin1String("label")).toString(about.value(QLatin1String("deviceType")).toString(label));
    }
    change(m_client->environment(), QStringLiteral("hal-c2.revokeClient"), {{QStringLiteral("sessionId"), id}}, [this, label](const QJsonObject&) {
      setNotice(QStringLiteral("success"), QStringLiteral("%1 was signed out.").arg(label));
    }, QStringLiteral("Could not revoke the client"));
  } else if (action == QLatin1String("connections.clients.revokeOthers")) {
    change(m_client->environment(), QStringLiteral("hal-c2.revokeOtherClients"), {}, [this](const QJsonObject& result) {
      const int count = result.value(QLatin1String("revokedCount")).toInt();
      setNotice(QStringLiteral("success"), count == 1 ? QStringLiteral("1 client was revoked.")
                                                      : QStringLiteral("%1 clients were revoked.").arg(count));
    }, QStringLiteral("Could not revoke the other clients"));
  } else {
    return false;
  }
  return true;
}

// Open, the page watches the access list; closed, it forgets it and the one
// pairing link it could still copy.
void ConnectionsController::setOpen(bool open) {
  if (open == m_open) return;
  m_open = open;
  m_state.insert(QStringLiteral("notice"), null());
  if (open) {
    readMachines();
    watchAccess();
    return;
  }
  if (m_accessSubscription >= 0) m_client->unsubscribe(std::exchange(m_accessSubscription, -1));
  m_pairingLinks = {};
  m_clients = {};
  m_state.insert(QStringLiteral("access"), null());
  m_state.insert(QStringLiteral("accessError"), null());
  m_state.insert(QStringLiteral("created"), null());
  publish();
}

bool ConnectionsController::readMachines() {
  auto* scope = NativeShell::of(this)->controller<SettingsScopeController>();
  QVariantList machines;
  for (const QString& id : scope->listed()) {
    if (scope->online(id)) machines.append(QVariantMap{{QStringLiteral("id"), id}, {QStringLiteral("label"), scope->label(id)}});
  }
  if (machines == m_state.value(QStringLiteral("machines")).toList()) return false;
  m_state.insert(QStringLiteral("machines"), machines);
  return true;
}

void ConnectionsController::watchAccess() {
  if (m_accessSubscription >= 0) m_client->unsubscribe(m_accessSubscription);
  m_state.insert(QStringLiteral("accessError"), null());
  publish();
  m_accessSubscription = m_client->subscribe(this, {{QStringLiteral("type"), QStringLiteral("authAccess")}},
                                             [this](const QJsonObject& frame) { onAccess(frame); });
}

void ConnectionsController::onAccess(const QJsonObject& frame) {
  const QString type = frame.value(QLatin1String("t")).toString();
  if (type == QLatin1String("error")) {
    m_client->unsubscribe(std::exchange(m_accessSubscription, -1));
    m_state.insert(QStringLiteral("access"), null());
    set(QStringLiteral("accessError"), explain(frame.value(QLatin1String("reason")).toString()));
    return;
  }
  if (type != QLatin1String("authAccess")) return;
  const QJsonObject event = frame.value(QLatin1String("event")).toObject();
  const QString kind = event.value(QLatin1String("type")).toString();
  const QJsonObject payload = event.value(QLatin1String("payload")).toObject();
  const auto upsert = [](QJsonArray& list, const QString& key, const QJsonObject& item) {
    for (qsizetype index = 0; index < list.size(); ++index) {
      if (list.at(index).toObject().value(key) == item.value(key)) {
        list.replace(index, item);
        return;
      }
    }
    list.append(item);
  };
  const auto remove = [](QJsonArray& list, const QString& key, const QJsonValue& value) {
    for (qsizetype index = list.size() - 1; index >= 0; --index) {
      if (list.at(index).toObject().value(key) == value) list.removeAt(index);
    }
  };
  if (kind == QLatin1String("snapshot")) {
    m_pairingLinks = payload.value(QLatin1String("pairingLinks")).toArray();
    m_clients = payload.value(QLatin1String("clientSessions")).toArray();
  } else if (kind == QLatin1String("pairingLinkUpserted")) {
    upsert(m_pairingLinks, QStringLiteral("id"), payload);
  } else if (kind == QLatin1String("pairingLinkRemoved")) {
    remove(m_pairingLinks, QStringLiteral("id"), payload.value(QLatin1String("id")));
  } else if (kind == QLatin1String("clientUpserted")) {
    upsert(m_clients, QStringLiteral("sessionId"), payload);
  } else if (kind == QLatin1String("clientRemoved")) {
    remove(m_clients, QStringLiteral("sessionId"), payload.value(QLatin1String("sessionId")));
  } else {
    return;
  }
  publishAccess();
}

void ConnectionsController::publishAccess() {
  set(QStringLiteral("access"), QVariantMap{{QStringLiteral("pairingLinks"), m_pairingLinks.toVariantList()},
                                            {QStringLiteral("clients"), m_clients.toVariantList()}});
}

void ConnectionsController::createPairingLink(const QVariantMap& input) {
  const QStringList scopes = input.value(QStringLiteral("scopes")).toStringList();
  if (scopes.isEmpty()) {
    setNotice(QStringLiteral("error"), QStringLiteral("Select at least one permission."));
    return;
  }
  QJsonObject payload{{QStringLiteral("scopes"), QJsonArray::fromStringList(scopes)}};
  const QString label = input.value(QStringLiteral("label")).toString().trimmed();
  if (!label.isEmpty()) payload.insert(QStringLiteral("label"), label);
  if (input.value(QStringLiteral("tailscale")).toBool()) payload.insert(QStringLiteral("tailscale"), true);
  const QString own = m_client->environment();
  const QString chosen = input.value(QStringLiteral("environmentId")).toString();
  const QString environmentId = chosen.isEmpty() ? own : chosen;
  // A machine this shell reached over the network is reached there by the
  // next device too, and the MC may only know the loopback it listens on (it
  // sits behind Tailscale Serve or a proxy): the shell names the address.
  const QUrl reached = m_client->origin().adjusted(QUrl::RemovePath | QUrl::RemoveQuery | QUrl::RemoveFragment);
  if (environmentId == own && !payload.contains(QLatin1String("tailscale")) && !loopback(reached)) {
    payload.insert(QStringLiteral("baseUrl"), reached.toString());
  }
  change(environmentId, QStringLiteral("hal-c2.createPairingLink"), payload, [this, environmentId, own](const QJsonObject& result) {
    const QString code = result.value(QLatin1String("credential")).toString();
    const QString id = result.value(QLatin1String("id")).toString();
    // The MC says where it is reached. One from before it did is reached where
    // this shell reached it, which says nothing of another machine.
    QString address = result.value(QLatin1String("address")).toString();
    bool localOnly = result.value(QLatin1String("localOnly")).toBool();
    if (address.isEmpty() && environmentId == own) {
      const QUrl origin = m_client->origin().adjusted(QUrl::RemovePath | QUrl::RemoveQuery | QUrl::RemoveFragment);
      address = origin.toString();
      localOnly = loopback(origin);
    }
    const QString machine = NativeShell::of(this)->controller<SettingsScopeController>()->label(environmentId);
    if (address.isEmpty()) {
      // No one can use a link with no address: it is not left behind.
      m_client->call(this, environmentId, QStringLiteral("hal-c2.revokePairingLink"), QJsonObject{{QStringLiteral("id"), id}},
                     [](const QJsonValue&, const std::optional<QString>&) {});
      setNotice(QStringLiteral("error"),
                QStringLiteral("Could not create the pairing URL: %1 did not say where it can be reached. Update HAL-C2 on it.").arg(machine));
      return;
    }
    const QString url = pairingUrl(address, code);
    const qr::Code code2d = localOnly ? qr::Code{} : qr::encode(url);
    m_state.insert(QStringLiteral("created"),
                   QVariantMap{
                       {QStringLiteral("id"), id},
                       {QStringLiteral("label"), result.value(QLatin1String("label")).toString()},
                       {QStringLiteral("code"), code},
                       {QStringLiteral("url"), url},
                       {QStringLiteral("expiresAt"), result.value(QLatin1String("expiresAt")).toString()},
                       {QStringLiteral("environmentId"), environmentId},
                       {QStringLiteral("machine"), machine},
                       {QStringLiteral("elsewhere"), environmentId != own},
                       {QStringLiteral("localOnly"), localOnly},
                       {QStringLiteral("qr"), code2d.isNull() ? null()
                                                              : QVariant(QVariantMap{{QStringLiteral("modules"), code2d.size},
                                                                                     {QStringLiteral("path"), qr::path(code2d)}})},
                   });
    setNotice(QStringLiteral("success"), QStringLiteral("Pairing link created. Copy it now: it is shown only while this page is open."));
  }, QStringLiteral("Could not create the pairing URL"));
}

void ConnectionsController::change(const QString& environmentId, const QString& method, const QJsonObject& payload,
                                   std::function<void(const QJsonObject& result)> done, const QString& failure) {
  set(QStringLiteral("busy"), true);
  m_client->call(this, environmentId, method, payload,
                 [this, done = std::move(done), failure](const QJsonValue& result, const std::optional<QString>& error) {
                   m_state.insert(QStringLiteral("busy"), false);
                   if (error) {
                     setNotice(QStringLiteral("error"), QStringLiteral("%1: %2").arg(failure, explain(*error)));
                     return;
                   }
                   done(result.toObject());
                 });
}

void ConnectionsController::setNotice(const QString& kind, const QString& text) {
  set(QStringLiteral("notice"), QVariantMap{{QStringLiteral("kind"), kind}, {QStringLiteral("text"), text}});
}

void ConnectionsController::set(const QString& field, const QVariant& value) {
  m_state.insert(field, value);
  publish();
}

void ConnectionsController::publish() {
  if (m_active) m_bridge->publish(QStringLiteral("connections"), m_state);
}
