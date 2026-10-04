#include "ClusterController.h"

#include <QClipboard>
#include <QGuiApplication>
#include <QJsonObject>
#include <QQmlPropertyMap>
#include <QSet>

#include "NativeShell.h"
#include "NavigationController.h"
#include "McClient.h"
#include "ShellBridge.h"
#include "ShellStore.h"

namespace {

// What the loopback hint tells the user to do instead (as the TUI's clusterState.ts).
const QString kLocalOnlyHint =
    QStringLiteral("Only this machine can open it: the MC listens on loopback. Invite over Tailscale instead.");

const NativeControllerRegistrar<ClusterController> registrar(QStringLiteral("cluster"), {QStringLiteral("cluster")});

}  // namespace

ClusterController::ClusterController(ShellBridge* bridge, McClient* client, QObject* parent)
    : QObject(parent),
      m_bridge(bridge),
      m_client(client),
      m_state{
          {QStringLiteral("busy"), false},
          {QStringLiteral("status"), QVariant::fromValue(nullptr)},
          {QStringLiteral("error"), QVariant::fromValue(nullptr)},
          {QStringLiteral("invite"), QVariant::fromValue(nullptr)},
          {QStringLiteral("notice"), QVariant::fromValue(nullptr)},
          {QStringLiteral("candidates"), QVariantList()},
      } {}

void ClusterController::activate() {
  if (m_active) return;
  m_active = true;
  connect(NativeShell::of(this)->shell()->store(), &ShellStore::changed, this, &ClusterController::updateCandidates);
  updateCandidates();
  publish();
  // Opening the page (NavigationController takes cluster.open) reads it afresh.
  auto* navigation = NativeShell::of(this)->controller<NavigationController>();
  auto opened = [navigation] { return navigation->route() == NavigationController::Route::settings(NavigationController::kClusterSection); };
  m_open = opened();
  if (m_open) refresh();
  connect(navigation, &NavigationController::changed, this, [this, opened] {
    const bool open = opened();
    if (open == m_open) return;
    m_open = open;
    if (!open) return;
    m_state.insert(QStringLiteral("notice"), QVariant::fromValue(nullptr));
    publish();
    refresh();
  });
}

bool ClusterController::handle(const QString& action, const QVariant& payload) {
  if (!m_active) return false;
  if (!action.startsWith(QLatin1String("cluster."))) return false;
  const QVariantMap input = payload.toMap();
  if (action == QLatin1String("cluster.refresh")) {
    refresh();
  } else if (action == QLatin1String("cluster.invite")) {
    invite(input.value(QStringLiteral("tailscale")).toBool());
  } else if (action == QLatin1String("cluster.invite.copy")) {
    const QString link = m_state.value(QStringLiteral("invite")).toMap().value(QStringLiteral("link")).toString();
    if (!link.isEmpty()) {
      QGuiApplication::clipboard()->setText(link);
      setNotice(QStringLiteral("success"), QStringLiteral("Invite link copied."));
    }
  } else if (action == QLatin1String("cluster.join")) {
    const QString link = input.value(QStringLiteral("link")).toString().trimmed();
    if (link.isEmpty()) {
      setNotice(QStringLiteral("error"), QStringLiteral("Paste the invite link from the other machine."));
    } else {
      change(QStringLiteral("cluster.join"), {{QStringLiteral("link"), link}}, QStringLiteral("Joined the cluster."),
             QStringLiteral("Join failed"));
    }
  } else if (action == QLatin1String("cluster.add")) {
    add(input.value(QStringLiteral("environmentId")).toString());
  } else if (action == QLatin1String("cluster.remove")) {
    const QString id = input.value(QStringLiteral("id")).toString();
    if (id.isEmpty()) return true;
    QString label = id;
    for (const QVariant& member : m_state.value(QStringLiteral("status")).toMap().value(QStringLiteral("members")).toList()) {
      if (member.toMap().value(QStringLiteral("id")) == id) label = member.toMap().value(QStringLiteral("label")).toString();
    }
    change(QStringLiteral("cluster.remove"), {{QStringLiteral("id"), id}},
           QStringLiteral("Removed %1 from the cluster.").arg(label), QStringLiteral("Remove failed"));
  } else {
    return false;
  }
  return true;
}

void ClusterController::refresh() {
  const quint64 generation = ++m_generation;
  call(QStringLiteral("cluster.status"), {}, [this, generation](const QJsonValue& result, const std::optional<QString>& error) {
    // RPCs answer concurrently: a read sent before a join or remove may land after it.
    if (generation != m_generation) return;
    if (error) {
      // What was read before may no longer hold; the page shows why instead.
      m_state.insert(QStringLiteral("status"), QVariant::fromValue(nullptr));
      set(QStringLiteral("error"), *error);
      return;
    }
    m_state.insert(QStringLiteral("error"), QVariant::fromValue(nullptr));
    m_state.insert(QStringLiteral("status"), result.toObject().toVariantMap());
    updateCandidates();
    publish();
  });
}

void ClusterController::invite(bool tailscale) {
  QJsonObject payload;
  if (tailscale) payload.insert(QStringLiteral("tailscale"), true);
  set(QStringLiteral("busy"), true);
  call(QStringLiteral("cluster.invite"), payload, [this](const QJsonValue& result, const std::optional<QString>& error) {
    m_state.insert(QStringLiteral("busy"), false);
    if (error) {
      setNotice(QStringLiteral("error"), QStringLiteral("Invite failed: %1").arg(*error));
      return;
    }
    const QVariantMap invite = result.toObject().toVariantMap();
    m_state.insert(QStringLiteral("invite"), invite);
    QGuiApplication::clipboard()->setText(invite.value(QStringLiteral("link")).toString());
    const bool localOnly = invite.value(QStringLiteral("localOnly")).toBool();
    QString text = QStringLiteral("Invite link copied; join with it on the other machine.");
    if (localOnly) text += QLatin1Char(' ') + kLocalOnlyHint;
    setNotice(localOnly ? QStringLiteral("error") : QStringLiteral("success"), text);
  });
}

// The environments the MC is linked to that are not members of its cluster.
void ClusterController::updateCandidates() {
  QSet<QString> members;
  for (const QVariant& member : m_state.value(QStringLiteral("status")).toMap().value(QStringLiteral("members")).toList()) {
    members.insert(member.toMap().value(QStringLiteral("id")).toString());
  }
  QVariantList candidates;
  for (const QJsonValue& value : NativeShell::of(this)->shell()->store()->links()) {
    const QJsonObject link = value.toObject();
    const QJsonObject environment = link.value(QLatin1String("environment")).toObject();
    const QString id = environment.value(QLatin1String("environmentId")).toString();
    if (id.isEmpty() || members.contains(id)) continue;
    candidates.append(QVariantMap{{QStringLiteral("environmentId"), id},
                                  {QStringLiteral("label"), environment.value(QLatin1String("label")).toString(id)},
                                  {QStringLiteral("online"), link.value(QLatin1String("online")).toBool()}});
  }
  if (candidates != m_state.value(QStringLiteral("candidates")).toList()) set(QStringLiteral("candidates"), candidates);
}

// This MC makes an invite, and the linked environment joins with it: the join
// is that environment's own `cluster.join`, sent through the link.
void ClusterController::add(const QString& environmentId) {
  if (environmentId.isEmpty()) return;
  QString label = environmentId;
  for (const QVariant& candidate : m_state.value(QStringLiteral("candidates")).toList()) {
    if (candidate.toMap().value(QStringLiteral("environmentId")) == environmentId) label = candidate.toMap().value(QStringLiteral("label")).toString();
  }
  ++m_generation;
  set(QStringLiteral("busy"), true);
  const auto fail = [this, label](const QString& why) {
    m_state.insert(QStringLiteral("busy"), false);
    setNotice(QStringLiteral("error"), QStringLiteral("Could not add %1: %2").arg(label, why));
    refresh();
  };
  call(QStringLiteral("cluster.invite"), {}, [this, environmentId, label, fail](const QJsonValue& result, const std::optional<QString>& error) {
    if (error) return fail(*error);
    const QJsonObject invite = result.toObject();
    // An invite only this machine can open is no use to another one.
    if (invite.value(QLatin1String("localOnly")).toBool()) return fail(kLocalOnlyHint);
    m_client->call(this, environmentId, QStringLiteral("cluster.join"), QJsonObject{{QStringLiteral("link"), invite.value(QLatin1String("link"))}},
                   [this, label, fail](const QJsonValue&, const std::optional<QString>& joinError) {
                     if (joinError) return fail(*joinError);
                     m_state.insert(QStringLiteral("busy"), false);
                     setNotice(QStringLiteral("success"), QStringLiteral("%1 joined this cluster.").arg(label));
                     refresh();
                   });
  });
}

// Join and remove answer with the cluster as it now is.
void ClusterController::change(const QString& method, const QJsonObject& payload, const QString& success,
                               const QString& failure) {
  ++m_generation;
  set(QStringLiteral("busy"), true);
  call(method, payload, [this, success, failure](const QJsonValue& result, const std::optional<QString>& error) {
    m_state.insert(QStringLiteral("busy"), false);
    if (error) {
      setNotice(QStringLiteral("error"), QStringLiteral("%1: %2").arg(failure, *error));
      refresh();  // in place of any read this change overtook
      return;
    }
    m_state.insert(QStringLiteral("status"), result.toObject().toVariantMap());
    m_state.insert(QStringLiteral("error"), QVariant::fromValue(nullptr));
    setNotice(QStringLiteral("success"), success);
  });
}

void ClusterController::call(const QString& method, const QJsonObject& payload,
                             std::function<void(const QJsonValue&, const std::optional<QString>&)> reply) {
  m_client->call(this, m_client->environment(), method, payload, std::move(reply));
}

void ClusterController::setNotice(const QString& kind, const QString& text) {
  set(QStringLiteral("notice"), QVariantMap{{QStringLiteral("kind"), kind}, {QStringLiteral("text"), text}});
}

void ClusterController::set(const QString& field, const QVariant& value) {
  m_state.insert(field, value);
  publish();
}

void ClusterController::publish() {
  if (m_active) m_bridge->publish(QStringLiteral("cluster"), m_state);
}
