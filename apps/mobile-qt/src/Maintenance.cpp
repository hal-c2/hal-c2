#include "Maintenance.h"

#include <QClipboard>
#include <QCoreApplication>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QPointer>
#include <QRegularExpression>
#include <QTimer>

#include "ConnectionHealthController.h"
#include "McClient.h"
#include "NativeShell.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"

namespace {

const QString kKey = QStringLiteral("maintenance");
const QString kOperate = QStringLiteral("orchestration:operate");
const QString kReleaseIndex = QStringLiteral("https://api.github.com/repos/hal-c2/hal-c2/releases?per_page=100&page=%1");
const QString kTagPrefix = QStringLiteral("mc-v");
constexpr int kPageSize = 100;

QString text(const QJsonObject& object, QLatin1StringView path) {
  QJsonValue value = object;
  for (const QString& part : QString(path).split(QLatin1Char('.'))) value = value.toObject().value(part);
  return value.toString();
}

// packages/contracts PROVIDER_DISPLAY_NAMES.
QString providerName(const QJsonObject& provider) {
  static const QHash<QString, QString> names{
      {QStringLiteral("antigravity"), QStringLiteral("Antigravity")}, {QStringLiteral("codex"), QStringLiteral("Codex")},
      {QStringLiteral("claudeAgent"), QStringLiteral("Claude")},      {QStringLiteral("cursor"), QStringLiteral("Cursor")},
      {QStringLiteral("grok"), QStringLiteral("Grok")},               {QStringLiteral("acpRegistry"), QStringLiteral("ACP Registry")},
      {QStringLiteral("pi"), QStringLiteral("Pi")},                   {QStringLiteral("muse"), QStringLiteral("Muse Code")},
      {QStringLiteral("opencode"), QStringLiteral("OpenCode")},
  };
  const QString shown = provider.value(QLatin1String("displayName")).toString();
  if (!shown.isEmpty()) return shown;
  const QString driver = provider.value(QLatin1String("driver")).toString();
  return names.value(driver, driver);
}

bool updating(const QJsonObject& provider) {
  const QString status = text(provider, QLatin1StringView("updateState.status"));
  return status == QLatin1String("queued") || status == QLatin1String("running");
}

QString pathName(maintenance::Path path) {
  switch (path) {
    case maintenance::Path::Update:
      return QStringLiteral("update");
    case maintenance::Path::Desktop:
      return QStringLiteral("desktop");
    case maintenance::Path::DesktopManual:
      return QStringLiteral("desktop-manual");
    case maintenance::Path::Command:
      break;
  }
  return QStringLiteral("command");
}

QString providerKey(const QString& environmentId, const QString& instanceId) { return environmentId + QLatin1Char('\n') + instanceId; }

QString command(const QString& version) { return QStringLiteral("npx hal-c2@") + version; }

}  // namespace

namespace maintenance {

Path pathOf(const QJsonObject& capabilities) {
  const QJsonValue selfUpdate = capabilities.value(QLatin1String("serverSelfUpdate"));
  if (!selfUpdate.isString()) return Path::Command;
  if (selfUpdate.toString() != QLatin1String("desktop-managed")) return Path::Update;
  return capabilities.value(QLatin1String("desktopAppUpdate")).toBool() ? Path::Desktop : Path::DesktopManual;
}

QString channelOf(const QString& version) {
  static const QRegularExpression dated(QStringLiteral("^[^-+]+-(nightly|preview)\\.\\d{8}\\.\\d+$"));
  const QRegularExpressionMatch match = dated.match(version.trimmed());
  return match.hasMatch() ? match.captured(1) : QStringLiteral("stable");
}

std::optional<QString> newestOn(const QJsonArray& releases, const QString& channel) {
  for (const QJsonValue& value : releases) {
    const QJsonObject release = value.toObject();
    if (release.value(QLatin1String("draft")).toBool()) continue;
    const QString tag = release.value(QLatin1String("tag_name")).toString();
    if (!tag.startsWith(kTagPrefix)) continue;
    const QString version = tag.mid(kTagPrefix.size());
    if (channelOf(version) == channel) return version;
  }
  return std::nullopt;
}

bool canUpdateProvider(const QJsonObject& provider) {
  const QString compatibility = text(provider, QLatin1StringView("compatibilityAdvisory.latestVersionStatus"));
  const QJsonObject advisory = provider.value(QLatin1String("versionAdvisory")).toObject();
  return provider.value(QLatin1String("installed")).toBool(true) && provider.value(QLatin1String("availability")).toString() != QLatin1String("unavailable") &&
         advisory.value(QLatin1String("status")).toString() == QLatin1String("behind_latest") && advisory.value(QLatin1String("canUpdate")).toBool() &&
         !advisory.value(QLatin1String("latestVersion")).toString().isEmpty() && compatibility != QLatin1String("broken") &&
         compatibility != QLatin1String("unsupported") && !updating(provider);
}

QString providerOutcome(const QJsonObject& provider) {
  const QJsonObject state = provider.value(QLatin1String("updateState")).toObject();
  const QString status = state.value(QLatin1String("status")).toString();
  if (status == QLatin1String("succeeded")) return QCoreApplication::translate("Maintenance", "Updated");
  if (status == QLatin1String("unchanged")) return QCoreApplication::translate("Maintenance", "Already up to date");
  const QString message = state.value(QLatin1String("message")).toString();
  return QCoreApplication::translate("Maintenance", "Failed: %1")
      .arg(message.isEmpty() ? QCoreApplication::translate("Maintenance", "the update did not finish.") : message);
}

}  // namespace maintenance

Maintenance::Maintenance(ShellBridge* bridge, NativeShell* shell, QObject* parent)
    : QObject(parent),
      m_bridge(bridge),
      m_shell(shell),
      m_http(new QNetworkAccessManager(this)),
      m_appVersion(QCoreApplication::applicationVersion().trimmed()),
      m_releaseIndex(kReleaseIndex),
      m_writeClipboard([](const QString& text) {
        QGuiApplication::clipboard()->setText(text);
        return true;
      }) {
  bridge->declareKey(kKey);
  bridge->addInterceptor([self = QPointer<Maintenance>(this)](const QString& action, const QVariant& payload) {
    return self && self->handle(action, payload);
  });
  connect(shell->client(), &McClient::readyChanged, this, [this](bool ready) {
    // Another connection may be another session.
    m_session = Session::Unknown;
    if (ready && m_open) {
      readSession();
      readProviders();
    }
    publish();
  });
  connect(shell->store(), &ShellStore::changed, this, [this] {
    settle();
    publish();
  });
  if (auto* settings = shell->controller<SettingsController>()) connect(settings, &SettingsController::configChanged, this, &Maintenance::publish);
  publish();
}

void Maintenance::setAppVersion(const QString& version) {
  m_appVersion = version.trimmed();
  publish();
}

bool Maintenance::handle(const QString& action, const QVariant& payload) {
  if (!action.startsWith(QLatin1String("maintenance."))) return false;
  const QVariantMap map = payload.toMap();
  const std::optional<Machine> named = machine(map.value(QStringLiteral("environment")).toString());
  // Nothing is started where the phone cannot operate.
  const bool may = named && blocked(*named).isEmpty();
  if (action == QLatin1String("maintenance.open")) {
    m_open = true;
    m_message.reset();
    if (m_session == Session::Unknown || m_session == Session::Failed) readSession();
    readProviders();
  } else if (action == QLatin1String("maintenance.close")) {
    m_open = false;
    m_confirming.clear();
  } else if (action == QLatin1String("maintenance.check")) {
    if (may) check(*named);
  } else if (action == QLatin1String("maintenance.update")) {
    if (may) update({named->environmentId});
  } else if (action == QLatin1String("maintenance.updateAll")) {
    QStringList all;
    for (const Machine& each : updatable()) all.append(each.environmentId);
    update(all);
  } else if (action == QLatin1String("maintenance.confirm")) {
    const QStringList confirmed = std::exchange(m_confirming, {});
    for (const QString& environmentId : confirmed) {
      if (const std::optional<Machine> each = machine(environmentId); each && blocked(*each).isEmpty()) updateServer(*each);
    }
  } else if (action == QLatin1String("maintenance.cancel")) {
    m_confirming.clear();
  } else if (action == QLatin1String("maintenance.copyCommand")) {
    if (named) copyCommand(*named);
  } else if (action == QLatin1String("maintenance.refreshProviders")) {
    if (may) refreshProviders(named->environmentId, true);
  } else if (action == QLatin1String("maintenance.updateProvider")) {
    if (may) updateProvider(*named, map.value(QStringLiteral("instanceId")).toString());
  } else if (action == QLatin1String("maintenance.updateProviders")) {
    const QString driver = map.value(QStringLiteral("driver")).toString();
    for (const Machine& each : machines()) {
      if (!blocked(each).isEmpty()) continue;
      for (const QJsonValue& value : providersOf(each)) {
        const QJsonObject provider = value.toObject();
        if (provider.value(QLatin1String("driver")).toString() == driver && maintenance::canUpdateProvider(provider)) {
          updateProvider(each, provider.value(QLatin1String("instanceId")).toString());
        }
      }
    }
  } else {
    return false;
  }
  publish();
  return true;
}

QList<Maintenance::Machine> Maintenance::machines() const {
  const McClient* client = m_shell->client();
  const ShellStore* store = m_shell->store();
  const QString own = client->environment();
  QList<Machine> found;
  QStringList ids = store->environments();
  // The environment the phone is paired with first, before its MC's shell says it.
  ids.removeAll(own);
  if (!own.isEmpty()) ids.prepend(own);
  for (const QString& id : std::as_const(ids)) {
    const QJsonObject descriptor = store->environment(id);
    Machine machine{id,
                    descriptor.value(QLatin1String("label")).toString(),
                    descriptor.value(QLatin1String("serverVersion")).toString().trimmed(),
                    store->environmentOnline(id),
                    id == own,
                    descriptor.value(QLatin1String("capabilities")).toObject()};
    if (machine.local) {
      const QJsonObject paired = client->descriptor();
      if (machine.label.isEmpty()) machine.label = paired.value(QLatin1String("label")).toString();
      if (machine.version.isEmpty()) machine.version = paired.value(QLatin1String("serverVersion")).toString().trimmed();
      machine.online = client->isReady();
    }
    if (machine.label.isEmpty()) machine.label = id;
    found.append(machine);
  }
  return found;
}

std::optional<Maintenance::Machine> Maintenance::machine(const QString& environmentId) const {
  if (environmentId.isEmpty()) return std::nullopt;
  for (const Machine& each : machines()) {
    if (each.environmentId == environmentId) return each;
  }
  return std::nullopt;
}

QString Maintenance::blocked(const Machine& machine) const {
  if (!m_shell->client()->isReady() || !machine.online) return tr("Connect this environment to manage it.");
  switch (m_session) {
    case Session::May:
      return {};
    case Session::MayNot:
      return tr("This connection does not have permission to manage the environment.");
    case Session::Failed:
      return tr("Could not verify your permissions. Reconnect to try again.");
    case Session::Unknown:
    case Session::Reading:
      break;
  }
  return tr("Checking permissions…");
}

QString Maintenance::target(const Machine& machine) const {
  const Release release = m_releases.value(machine.environmentId);
  if (!release.available.isEmpty()) return release.available;
  if (ConnectionHealthController::serverBehind(m_appVersion, machine.version)) return m_appVersion;
  return {};
}

QJsonArray Maintenance::providersOf(const Machine& machine) const {
  QJsonArray all;
  if (machine.local) {
    if (const auto* settings = m_shell->controller<SettingsController>()) all = settings->config().value(QLatin1String("providers")).toArray();
  } else {
    all = m_providers.value(machine.environmentId);
  }
  // A provider turned off is not this environment's to update.
  QJsonArray enabled;
  for (const QJsonValue& value : std::as_const(all)) {
    if (value.toObject().value(QLatin1String("enabled")).toBool(true)) enabled.append(value);
  }
  return enabled;
}

QList<Maintenance::Machine> Maintenance::updatable() const {
  QList<Machine> found;
  for (const Machine& each : machines()) {
    const maintenance::Path path = maintenance::pathOf(each.capabilities);
    if (blocked(each).isEmpty() && !target(each).isEmpty() && !m_updating.contains(each.environmentId) &&
        !m_reconnecting.contains(each.environmentId) && (path == maintenance::Path::Update || path == maintenance::Path::Desktop)) {
      found.append(each);
    }
  }
  return found;
}

void Maintenance::readSession() {
  McClient* client = m_shell->client();
  if (!client->isReady()) return;
  m_session = Session::Reading;
  const quint64 generation = ++m_generation;
  QNetworkReply* reply = m_http->get(client->request(QStringLiteral("/api/auth/session")));
  connect(reply, &QNetworkReply::finished, this, [this, reply, generation] {
    reply->deleteLater();
    if (generation != m_generation) return;
    const QJsonObject session = QJsonDocument::fromJson(reply->readAll()).object();
    if (reply->error() != QNetworkReply::NoError || session.isEmpty()) {
      m_session = Session::Failed;
    } else {
      const QJsonValue scopes = session.value(QLatin1String("scopes"));
      // An MC that lists no scopes checks each request itself.
      const bool may = session.value(QLatin1String("authenticated")).toBool(true) && (!scopes.isArray() || scopes.toArray().contains(kOperate));
      m_session = may ? Session::May : Session::MayNot;
    }
    publish();
  });
}

void Maintenance::readProviders() {
  if (!m_shell->client()->isReady()) return;
  for (const Machine& each : machines()) {
    if (!each.local && each.online) refreshProviders(each.environmentId, false);
  }
}

void Maintenance::refreshProviders(const QString& environmentId, bool announce) {
  McClient* client = m_shell->client();
  client->call(this, environmentId, QStringLiteral("server.refreshProviders"), QJsonObject{},
               [this, environmentId, announce, local = environmentId == client->environment()](const QJsonValue& result,
                                                                                               const std::optional<QString>& error) {
                 if (error) {
                   m_providerErrors.insert(environmentId, *error);
                   if (announce) m_message = Outcome{false, *error};
                 } else {
                   m_providerErrors.remove(environmentId);
                   // The MC's own come with its config, as they change.
                   if (!local) m_providers.insert(environmentId, result.toObject().value(QLatin1String("providers")).toArray());
                   if (announce) m_message = Outcome{true, tr("Provider status refreshed.")};
                 }
                 publish();
               });
}

void Maintenance::check(const Machine& machine) {
  if (m_releases.value(machine.environmentId).checking) return;
  m_releases.insert(machine.environmentId, Release{true, {}, {}});
  checkPage(machine, maintenance::channelOf(machine.version), 1);
  publish();
}

void Maintenance::checkPage(const Machine& machine, const QString& channel, int page) {
  QNetworkRequest request(QUrl(m_releaseIndex.arg(page)));
  request.setRawHeader("Accept", "application/vnd.github+json");
  QNetworkReply* reply = m_http->get(request);
  connect(reply, &QNetworkReply::finished, this, [this, reply, machine, channel, page] {
    reply->deleteLater();
    Release release;
    const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    const QJsonArray releases = QJsonDocument::fromJson(reply->readAll()).array();
    if (reply->error() != QNetworkReply::NoError) {
      release.text = tr("Could not check releases (%1). Try again.").arg(status > 0 ? QString::number(status) : reply->errorString());
    } else if (const std::optional<QString> newest = maintenance::newestOn(releases, channel)) {
      // Never back: an environment ahead of the newest release stays where it is.
      if (ConnectionHealthController::serverBehind(*newest, machine.version)) {
        release.available = *newest;
        release.text = tr("Version %1 is available.").arg(*newest);
      } else {
        release.text = tr("You are up to date.");
      }
    } else if (releases.size() >= kPageSize) {
      checkPage(machine, channel, page + 1);
      return;
    } else {
      release.text = tr("No %1 release was found.").arg(channel);
    }
    m_releases.insert(machine.environmentId, release);
    publish();
  });
}

void Maintenance::update(const QStringList& environments) {
  QStringList desktops;
  QStringList labels;
  for (const QString& environmentId : environments) {
    const std::optional<Machine> each = machine(environmentId);
    if (!each || !blocked(*each).isEmpty() || target(*each).isEmpty()) continue;
    const maintenance::Path path = maintenance::pathOf(each->capabilities);
    if (path == maintenance::Path::Desktop) {
      desktops.append(environmentId);
      labels.append(each->label);
    } else if (path == maintenance::Path::Update) {
      updateServer(*each);
    }
  }
  if (desktops.isEmpty()) return;
  // A desktop app closes to update: the user says so first.
  m_confirming = desktops;
  m_confirmText = desktops.size() == 1
                      ? tr("Update the HAL-C2 desktop app that runs %1? It will close and relaunch on that machine.").arg(labels.first())
                      : tr("Update the HAL-C2 desktop apps on %1? They will close and relaunch on those machines.").arg(labels.join(QStringLiteral(", ")));
}

void Maintenance::updateServer(const Machine& machine) {
  if (m_updating.contains(machine.environmentId) || m_reconnecting.contains(machine.environmentId)) return;
  const QString version = target(machine);
  if (version.isEmpty()) return;
  m_updating.insert(machine.environmentId, machine.version);
  m_outcomes.remove(machine.environmentId);
  m_shell->client()->call(this, machine.environmentId, QStringLiteral("server.updateServer"), QJsonObject{{QStringLiteral("targetVersion"), version}},
                          [this, machine](const QJsonValue& result, const std::optional<QString>& error) {
                            const QString left = m_updating.take(machine.environmentId);
                            if (error) {
                              const Outcome outcome{false, tr("%1 update failed: %2").arg(machine.label, *error)};
                              m_outcomes.insert(machine.environmentId, outcome);
                              m_message = outcome;
                            } else {
                              awaitReconnect(machine, left, result.toObject().value(QLatin1String("desktopUpdateToken")).toString());
                              settle();
                            }
                            publish();
                          });
}

void Maintenance::settle() {
  for (auto it = m_reconnecting.begin(); it != m_reconnecting.end();) {
    const std::optional<Machine> now = machine(it.key());
    // Back on another version: the one it reconnected on.
    if (!now || !now->online || now->version.isEmpty() || now->version == it.value()) {
      ++it;
      continue;
    }
    const Outcome outcome{true, tr("%1 was updated and reconnected on %2.").arg(now->label, now->version)};
    m_outcomes.insert(it.key(), outcome);
    m_message = outcome;
    m_releases.remove(it.key());
    const QString environmentId = it.key();
    ++it;
    endReconnect(environmentId);
  }
}

void Maintenance::awaitReconnect(const Machine& machine, const QString& left, const QString& token) {
  const QString environmentId = machine.environmentId;
  m_reconnecting.insert(environmentId, left);
  Waiting waiting{++m_waitRun, -1};
  QTimer::singleShot(m_reconnectDeadline, this, [this, environmentId, run = waiting.run] {
    if (m_waiting.value(environmentId).run != run) return;
    reconnectFailed(environmentId, tr("it did not come back on a new version. Try again."));
  });
  // The reply to a desktop app's update only means ready to install: its MC tells
  // how an install that failed went, by the token it answered with.
  if (!token.isEmpty()) {
    waiting.subscription = m_shell->client()->subscribe(
        this, {{QStringLiteral("type"), QStringLiteral("config")}, {QStringLiteral("environment"), environmentId}},
        [this, environmentId, token](const QJsonObject& frame) {
          const QJsonObject outcome = frame.value(QLatin1String("updateOutcome")).toObject();
          if (outcome.value(QLatin1String("id")).toString() != token || outcome.value(QLatin1String("status")).toString() == QLatin1String("committed")) return;
          const QString reason = outcome.value(QLatin1String("reason")).toString();
          reconnectFailed(environmentId, reason.isEmpty() ? tr("the install failed.") : reason);
        });
  }
  m_waiting.insert(environmentId, waiting);
}

void Maintenance::reconnectFailed(const QString& environmentId, const QString& why) {
  if (!m_reconnecting.contains(environmentId)) return;
  const std::optional<Machine> now = machine(environmentId);
  const Outcome outcome{false, tr("%1 update failed: %2").arg(now ? now->label : environmentId, why)};
  m_outcomes.insert(environmentId, outcome);
  m_message = outcome;
  endReconnect(environmentId);
  publish();
}

void Maintenance::endReconnect(const QString& environmentId) {
  m_reconnecting.remove(environmentId);
  const Waiting waiting = m_waiting.take(environmentId);
  // Not from inside its own frame's handler.
  if (waiting.subscription >= 0) {
    QMetaObject::invokeMethod(this, [client = m_shell->client(), id = waiting.subscription] { client->unsubscribe(id); }, Qt::QueuedConnection);
  }
}

void Maintenance::copyCommand(const Machine& machine) {
  const QString version = target(machine);
  if (version.isEmpty()) return;
  const QString run = command(version);
  m_message = m_writeClipboard(run) ? Outcome{true, tr("Update command copied. Run `%1` on %2.").arg(run, machine.label)}
                                    : Outcome{false, tr("Run `%1` on %2.").arg(run, machine.label)};
}

void Maintenance::updateProvider(const Machine& machine, const QString& instanceId) {
  const QString key = providerKey(machine.environmentId, instanceId);
  if (m_providerUpdates.contains(key)) return;
  QJsonObject provider;
  for (const QJsonValue& value : providersOf(machine)) {
    if (value.toObject().value(QLatin1String("instanceId")).toString() == instanceId) provider = value.toObject();
  }
  if (!maintenance::canUpdateProvider(provider)) return;
  m_providerUpdates.insert(key);
  m_providerOutcomes.remove(key);
  const QJsonObject request{{QStringLiteral("provider"), provider.value(QLatin1String("driver"))}, {QStringLiteral("instanceId"), instanceId}};
  m_shell->client()->call(this, machine.environmentId, QStringLiteral("server.updateProvider"), request,
                          [this, key, machine, instanceId](const QJsonValue& result, const std::optional<QString>& error) {
                            m_providerUpdates.remove(key);
                            if (error) {
                              m_providerOutcomes.insert(key, Outcome{false, tr("Failed: %1").arg(*error)});
                              publish();
                              return;
                            }
                            const QJsonArray providers = result.toObject().value(QLatin1String("providers")).toArray();
                            if (!machine.local) m_providers.insert(machine.environmentId, providers);
                            QJsonObject updated;
                            for (const QJsonValue& value : providers) {
                              if (value.toObject().value(QLatin1String("instanceId")).toString() == instanceId) updated = value.toObject();
                            }
                            const QString status = text(updated, QLatin1StringView("updateState.status"));
                            m_providerOutcomes.insert(key, Outcome{status == QLatin1String("succeeded") || status == QLatin1String("unchanged"),
                                                                   maintenance::providerOutcome(updated)});
                            publish();
                          });
}

void Maintenance::publish() {
  QVariantList machines;
  QHash<QString, QVariantMap> groups;
  QStringList groupOrder;
  const QList<Machine> all = this->machines();
  for (const Machine& machine : all) {
    const QString why = blocked(machine);
    QVariantList providers;
    for (const QJsonValue& value : providersOf(machine)) {
      const QJsonObject provider = value.toObject();
      const QString instanceId = provider.value(QLatin1String("instanceId")).toString();
      const QString key = providerKey(machine.environmentId, instanceId);
      const bool running = m_providerUpdates.contains(key) || updating(provider);
      const bool canUpdate = why.isEmpty() && !running && maintenance::canUpdateProvider(provider);
      const QJsonObject state = provider.value(QLatin1String("updateState")).toObject();
      QString status = state.value(QLatin1String("message")).toString();
      if (status.isEmpty() && !state.value(QLatin1String("status")).toString().isEmpty()) {
        status = tr("Update %1").arg(state.value(QLatin1String("status")).toString());
      }
      providers.append(QVariantMap{
          {QStringLiteral("instanceId"), instanceId},
          {QStringLiteral("driver"), provider.value(QLatin1String("driver")).toString()},
          {QStringLiteral("name"), providerName(provider)},
          {QStringLiteral("version"), text(provider, QLatin1StringView("versionAdvisory.currentVersion"))},
          {QStringLiteral("latest"), text(provider, QLatin1StringView("versionAdvisory.latestVersion"))},
          {QStringLiteral("canUpdate"), canUpdate},
          {QStringLiteral("updating"), running},
          {QStringLiteral("status"), status},
          {QStringLiteral("outcome"), running ? QString() : m_providerOutcomes.value(key).text},
          {QStringLiteral("failed"), !running && m_providerOutcomes.contains(key) && !m_providerOutcomes.value(key).ok},
      });
      if (canUpdate) {
        const QString driver = provider.value(QLatin1String("driver")).toString();
        QVariantMap& group = groups[driver];
        if (group.isEmpty()) {
          groupOrder.append(driver);
          group = {{QStringLiteral("driver"), driver}, {QStringLiteral("name"), providerName(provider)}, {QStringLiteral("count"), 0}};
        }
        group[QStringLiteral("count")] = group.value(QStringLiteral("count")).toInt() + 1;
      }
    }
    const QString version = target(machine);
    const Release release = m_releases.value(machine.environmentId);
    const bool hasRelease = release.checking || !release.text.isEmpty();
    const auto outcome = m_outcomes.constFind(machine.environmentId);
    machines.append(QVariantMap{
        {QStringLiteral("environmentId"), machine.environmentId},
        {QStringLiteral("label"), machine.label},
        {QStringLiteral("version"), machine.version},
        {QStringLiteral("online"), machine.online},
        {QStringLiteral("local"), machine.local},
        {QStringLiteral("blocked"), why},
        {QStringLiteral("path"), pathName(maintenance::pathOf(machine.capabilities))},
        {QStringLiteral("target"), version},
        {QStringLiteral("command"), version.isEmpty() ? QString() : command(version)},
        {QStringLiteral("updating"), m_updating.contains(machine.environmentId) || m_reconnecting.contains(machine.environmentId)},
        {QStringLiteral("outcome"), outcome == m_outcomes.constEnd()
                                        ? QVariant::fromValue(nullptr)
                                        : QVariant(QVariantMap{{QStringLiteral("ok"), outcome->ok}, {QStringLiteral("text"), outcome->text}})},
        {QStringLiteral("release"), hasRelease ? QVariant(QVariantMap{{QStringLiteral("checking"), release.checking},
                                                                      {QStringLiteral("text"), release.text},
                                                                      {QStringLiteral("available"), release.available}})
                                               : QVariant::fromValue(nullptr)},
        {QStringLiteral("providers"), providers},
        {QStringLiteral("providersError"), m_providerErrors.value(machine.environmentId)},
    });
  }
  QVariantList several;
  for (const QString& driver : std::as_const(groupOrder)) {
    if (groups.value(driver).value(QStringLiteral("count")).toInt() > 1) several.append(groups.value(driver));
  }
  const QVariant confirm = m_confirming.isEmpty() ? QVariant::fromValue(nullptr) : QVariant(QVariantMap{{QStringLiteral("text"), m_confirmText}});
  const QVariant message = m_message ? QVariant(QVariantMap{{QStringLiteral("ok"), m_message->ok}, {QStringLiteral("text"), m_message->text}})
                                     : QVariant::fromValue(nullptr);
  const QVariantMap state{
      {QStringLiteral("appVersion"), m_appVersion}, {QStringLiteral("machines"), machines}, {QStringLiteral("updatable"), updatable().size()},
      {QStringLiteral("groups"), several},          {QStringLiteral("confirm"), confirm},   {QStringLiteral("message"), message},
  };

  // The shell's rows change far more often than anything here.
  if (state == m_published) return;
  m_published = state;
  m_bridge->publish(kKey, state);
}
