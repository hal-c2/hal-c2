#include "ConnectionsController.h"

#include <QClipboard>
#include <QGuiApplication>
#include <QUrl>

#include "NativeShell.h"
#include "NavigationController.h"
#include "NodeClient.h"
#include "ShellBridge.h"
#include "ShellStore.h"

namespace {

const NativeControllerRegistrar<ConnectionsController> registrar(QStringLiteral("connections"),
                                                                 {QStringLiteral("connections")});

// The node refuses access calls and the access list to a session without
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

// A pairing link as the page's own code field takes it: a host (with or
// without a scheme) and the code.
QString pairingUrl(const QString& host, const QString& code) {
  return host + QStringLiteral("/pair#token=") + code;
}

}  // namespace

ConnectionsController::ConnectionsController(ShellBridge* bridge, NodeClient* client, ShellStore* store, QObject* parent)
    : QObject(parent),
      m_bridge(bridge),
      m_client(client),
      m_store(store),
      m_state{
          {QStringLiteral("links"), QVariantList()},
          {QStringLiteral("access"), null()},
          {QStringLiteral("accessError"), null()},
          {QStringLiteral("busy"), false},
          {QStringLiteral("notice"), null()},
          {QStringLiteral("created"), null()},
          {QStringLiteral("removing"), null()},
      } {}

void ConnectionsController::activate() {
  if (m_active) return;
  m_active = true;
  m_bridge->claimKey(QStringLiteral("connections"));
  updateLinks();
  publish();
  connect(m_store, &ShellStore::changed, this, &ConnectionsController::updateLinks);
  auto* navigation = NativeShell::of(this)->controller<NavigationController>();
  auto opened = [navigation] {
    return navigation->route() == NavigationController::Route::settings(NavigationController::kConnectionsSection);
  };
  setOpen(opened());
  connect(navigation, &NavigationController::changed, this, [this, opened] { setOpen(opened()); });
}

bool ConnectionsController::handle(const QString& action, const QVariant& payload) {
  if (!m_active || !action.startsWith(QLatin1String("connections."))) return false;
  // Opening and closing the page are the route's (NavigationController).
  if (action == QLatin1String("connections.open") || action == QLatin1String("connections.close")) return false;
  const QVariantMap input = payload.toMap();
  if (action == QLatin1String("connections.refresh")) {
    watchAccess();
  } else if (action == QLatin1String("connections.link")) {
    const QString url = input.value(QStringLiteral("pairingUrl")).toString().trimmed();
    const QString host = input.value(QStringLiteral("host")).toString().trimmed();
    const QString code = input.value(QStringLiteral("code")).toString().trimmed();
    if (!url.isEmpty()) {
      link(url, {});
    } else if (host.isEmpty() || code.isEmpty()) {
      setNotice(QStringLiteral("error"), QStringLiteral("Enter a pairing link, or a host and its pairing code."));
    } else if (host.contains(QLatin1String("://"))) {
      link(pairingUrl(host, code), {});
    } else {
      // A host without a scheme: HTTPS first, then plain HTTP when that cannot connect.
      link(pairingUrl(QStringLiteral("https://") + host, code), pairingUrl(QStringLiteral("http://") + host, code));
    }
  } else if (action == QLatin1String("connections.unlink.request")) {
    set(QStringLiteral("removing"), input.value(QStringLiteral("environmentId")).toString());
  } else if (action == QLatin1String("connections.unlink.cancel")) {
    set(QStringLiteral("removing"), null());
  } else if (action == QLatin1String("connections.unlink")) {
    const QString id = input.value(QStringLiteral("environmentId")).toString();
    m_state.insert(QStringLiteral("removing"), null());
    if (!id.isEmpty()) unlink(id);
  } else if (action == QLatin1String("connections.pairingLink.create")) {
    createPairingLink(input);
  } else if (action == QLatin1String("connections.pairingLink.copy")) {
    const QVariantMap created = m_state.value(QStringLiteral("created")).toMap();
    const bool code = input.value(QStringLiteral("what")) == QLatin1String("code");
    const QString text = created.value(code ? QStringLiteral("code") : QStringLiteral("url")).toString();
    if (!text.isEmpty()) {
      QGuiApplication::clipboard()->setText(text);
      setNotice(QStringLiteral("success"), code ? QStringLiteral("Pairing code copied.") : QStringLiteral("Pairing link copied."));
    }
  } else if (action == QLatin1String("connections.pairingLink.revoke")) {
    const QString id = input.value(QStringLiteral("id")).toString();
    if (id.isEmpty()) return true;
    change(QStringLiteral("hal-c2.revokePairingLink"), {{QStringLiteral("id"), id}}, [this, id](const QJsonObject&) {
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
    change(QStringLiteral("hal-c2.revokeClient"), {{QStringLiteral("sessionId"), id}}, [this, label](const QJsonObject&) {
      setNotice(QStringLiteral("success"), QStringLiteral("%1 was signed out.").arg(label));
    }, QStringLiteral("Could not revoke the client"));
  } else if (action == QLatin1String("connections.clients.revokeOthers")) {
    change(QStringLiteral("hal-c2.revokeOtherClients"), {}, [this](const QJsonObject& result) {
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
  m_state.insert(QStringLiteral("removing"), null());
  if (open) {
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

void ConnectionsController::watchAccess() {
  if (m_accessSubscription >= 0) m_client->unsubscribe(m_accessSubscription);
  m_state.insert(QStringLiteral("accessError"), null());
  publish();
  m_accessSubscription = m_client->subscribe({{QStringLiteral("type"), QStringLiteral("authAccess")}},
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

// The node's links, from the shell shape, with what each row says.
void ConnectionsController::updateLinks() {
  QVariantList links;
  for (const QJsonValue& value : m_store->links()) {
    const QJsonObject link = value.toObject();
    const QJsonObject environment = link.value(QLatin1String("environment")).toObject();
    const QString id = environment.value(QLatin1String("environmentId")).toString();
    const QString problem = link.value(QLatin1String("problem")).toString();
    const bool online = link.value(QLatin1String("online")).toBool();
    QString status = QStringLiteral("Connecting");
    if (online) {
      status = QStringLiteral("Connected");
    } else if (problem == QLatin1String("refused")) {
      status = QStringLiteral("Access refused: pair it again");
    } else if (problem == QLatin1String("unreachable")) {
      status = QStringLiteral("Offline");
    }
    links.append(QVariantMap{
        {QStringLiteral("environmentId"), id},
        {QStringLiteral("label"), environment.value(QLatin1String("label")).toString(id)},
        {QStringLiteral("origin"), link.value(QLatin1String("origin")).toString()},
        {QStringLiteral("online"), online},
        {QStringLiteral("problem"), problem.isEmpty() ? null() : QVariant(problem)},
        {QStringLiteral("status"), status},
    });
  }
  if (links == m_state.value(QStringLiteral("links")).toList()) return;
  set(QStringLiteral("links"), links);
}

// Pairs the node with the environment behind `pairingUrl`, or behind
// `fallbackUrl` when the first cannot be reached.
void ConnectionsController::link(const QString& pairingUrl, const QString& fallbackUrl) {
  set(QStringLiteral("busy"), true);
  m_client->call(m_client->environment(), QStringLiteral("hal-c2.linkEnvironment"),
                 QJsonObject{{QStringLiteral("pairingUrl"), pairingUrl}},
                 [this, fallbackUrl](const QJsonValue& result, const std::optional<QString>& error) {
                   if (error && !fallbackUrl.isEmpty() && error->startsWith(QLatin1String("cannot reach"))) {
                     link(fallbackUrl, {});
                     return;
                   }
                   m_state.insert(QStringLiteral("busy"), false);
                   if (error) {
                     QString text = QStringLiteral("Could not add the environment: %1").arg(explain(*error));
                     if (error->contains(QLatin1String("invalid or expired"))) text += QStringLiteral(". Ask for a fresh link.");
                     setNotice(QStringLiteral("error"), text);
                     return;
                   }
                   const QJsonObject descriptor = result.toObject();
                   const QString label = descriptor.value(QLatin1String("label"))
                                             .toString(descriptor.value(QLatin1String("environmentId")).toString());
                   setNotice(QStringLiteral("success"), QStringLiteral("%1 is linked.").arg(label));
                 });
}

void ConnectionsController::unlink(const QString& environmentId) {
  const QString label = labelOf(environmentId);
  change(QStringLiteral("hal-c2.unlinkEnvironment"), {{QStringLiteral("environmentId"), environmentId}},
         [this, label](const QJsonObject&) { setNotice(QStringLiteral("success"), QStringLiteral("%1 was removed.").arg(label)); },
         QStringLiteral("Could not remove %1").arg(label));
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
  change(QStringLiteral("hal-c2.createPairingLink"), payload, [this](const QJsonObject& result) {
    const QString code = result.value(QLatin1String("credential")).toString();
    const QString origin = m_client->origin().adjusted(QUrl::RemovePath | QUrl::RemoveQuery | QUrl::RemoveFragment).toString();
    m_state.insert(QStringLiteral("created"), QVariantMap{
                                                   {QStringLiteral("id"), result.value(QLatin1String("id")).toString()},
                                                   {QStringLiteral("label"), result.value(QLatin1String("label")).toString()},
                                                   {QStringLiteral("code"), code},
                                                   {QStringLiteral("url"), pairingUrl(origin, code)},
                                                   {QStringLiteral("expiresAt"), result.value(QLatin1String("expiresAt")).toString()},
                                               });
    setNotice(QStringLiteral("success"), QStringLiteral("Pairing link created. Copy it now: it is shown only while this page is open."));
  }, QStringLiteral("Could not create the pairing URL"));
}

void ConnectionsController::change(const QString& method, const QJsonObject& payload,
                                   std::function<void(const QJsonObject& result)> done, const QString& failure) {
  set(QStringLiteral("busy"), true);
  m_client->call(m_client->environment(), method, payload,
                 [this, done = std::move(done), failure](const QJsonValue& result, const std::optional<QString>& error) {
                   m_state.insert(QStringLiteral("busy"), false);
                   if (error) {
                     setNotice(QStringLiteral("error"), QStringLiteral("%1: %2").arg(failure, explain(*error)));
                     return;
                   }
                   done(result.toObject());
                 });
}

QString ConnectionsController::labelOf(const QString& environmentId) const {
  for (const QVariant& link : m_state.value(QStringLiteral("links")).toList()) {
    if (link.toMap().value(QStringLiteral("environmentId")) == environmentId) {
      return link.toMap().value(QStringLiteral("label")).toString();
    }
  }
  return environmentId;
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
