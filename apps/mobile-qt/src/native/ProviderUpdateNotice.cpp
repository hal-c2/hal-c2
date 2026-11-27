#include "ProviderUpdateNotice.h"

#include <QJsonObject>
#include <QVariantMap>

#include <algorithm>
#include <limits>
#include <memory>

#include "EnvironmentSettings.h"
#include "McClient.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ToastController.h"

using namespace providerUpdates;

namespace {

const NativeControllerRegistrar<ProviderUpdateNotice> registrar(QStringLiteral("providerUpdateNotice"),
                                                                {QStringLiteral("providerUpdates")}, nullptr,
                                                                NativeControllerScope::Shared);

const QString kDismissedKey = QStringLiteral("dismissedProviderUpdateNotificationKeys");
// How long "Provider updated" stays (PROVIDER_UPDATE_SUCCESS_VISIBLE_MS).
constexpr int kSuccessMs = 3000;
const QString kNotConnected = QStringLiteral("This environment isn’t connected — try again once it reconnects.");

QString instanceOf(const QJsonObject& provider) { return provider.value(QLatin1String("instanceId")).toString(); }

QJsonObject request(const QJsonObject& provider) {
  return {{QStringLiteral("provider"), provider.value(QLatin1String("driver"))},
          {QStringLiteral("instanceId"), provider.value(QLatin1String("instanceId"))}};
}

}  // namespace

ProviderUpdateNotice::ProviderUpdateNotice(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent)
    : QObject(parent), m_bridge(bridge), m_client(client), m_store(store), m_scope(new EnvironmentSettings(client, this)) {
  m_timer.setSingleShot(true);
  connect(&m_timer, &QTimer::timeout, this, &ProviderUpdateNotice::expire);
  connect(m_scope, &EnvironmentSettings::frame, this, [this](const QString& environmentId, const QJsonObject& frame) {
    const QString type = frame.value(QLatin1String("t")).toString();
    if (type == QLatin1String("config")) {
      m_remote.insert(environmentId, frame.value(QLatin1String("config")).toObject().value(QLatin1String("providers")).toArray());
    } else if (type == QLatin1String("config.providers")) {
      m_remote.insert(environmentId, frame.value(QLatin1String("providers")).toArray());
    } else {
      return;
    }
    evaluate();
  });
}

void ProviderUpdateNotice::activate() {
  if (m_active) return;
  m_active = true;
  if (auto* settings = this->settings()) connect(settings, &SettingsController::configChanged, this, &ProviderUpdateNotice::evaluate);
  connect(m_store, &ShellStore::changed, this, &ProviderUpdateNotice::evaluate);
  publish();
  evaluate();
}

bool ProviderUpdateNotice::handle(const QString& action, const QVariant&) {
  if (action == QLatin1String("providerUpdates.dismissNotice")) {
    if (m_sidebar.dismiss(m_now())) publish();
    schedule();
    return true;
  }
  if (action == QLatin1String("providerUpdates.openNotice")) {
    openSettings();
    return true;
  }
  return false;
}

ToastController* ProviderUpdateNotice::toasts() const {
  NativeWindow* window = NativeShell::of(this);
  return window ? window->controller<ToastController>() : nullptr;
}

SettingsController* ProviderUpdateNotice::settings() const {
  auto* shell = qobject_cast<NativeShell*>(parent());
  return shell ? shell->shared<SettingsController>() : nullptr;
}

QStringList ProviderUpdateNotice::dismissedKeys() const {
  auto* settings = this->settings();
  return settings ? settings->deviceValue(kDismissedKey).toStringList() : QStringList();
}

void ProviderUpdateNotice::dismissKey(const QString& key) {
  auto* settings = this->settings();
  if (!settings || key.isEmpty()) return;
  QStringList dismissed = dismissedKeys();
  if (!dismissed.contains(key)) dismissed.append(key);
  settings->writeDevice(kDismissedKey, dismissed);
}

void ProviderUpdateNotice::publish() {
  QVariant notice;
  if (const std::optional<Notice>& current = m_sidebar.current()) {
    notice = QVariantMap{{QStringLiteral("key"), current->key},
                         {QStringLiteral("tone"), current->tone},
                         {QStringLiteral("title"), current->title},
                         {QStringLiteral("description"), current->description},
                         {QStringLiteral("dismissible"), current->dismissible}};
  } else {
    notice = QVariant::fromValue(nullptr);
  }
  m_bridge->publish(QStringLiteral("providerUpdates"), QVariantMap{{QStringLiteral("notice"), notice}});
}

void ProviderUpdateNotice::schedule() {
  std::optional<QDateTime> next = m_sidebar.deadline();
  const auto sooner = [&next](const std::optional<QDateTime>& at) {
    if (at && (!next || *at < *next)) next = at;
  };
  sooner(m_rows.deadline());
  // The wait for a connecting environment, while it lasts.
  if (m_settlingSince && m_settlingSince->addMSecs(kSettlingMs) > m_now()) sooner(m_settlingSince->addMSecs(kSettlingMs));
  if (!next) {
    m_timer.stop();
    return;
  }
  m_timer.start(int(std::clamp<qint64>(m_now().msecsTo(*next), 0, std::numeric_limits<int>::max())));
}

void ProviderUpdateNotice::expire() {
  if (!m_active) return;
  const QDateTime now = m_now();
  if (m_sidebar.expire(now)) publish();
  m_rows.expire(now);
  evaluate();
}

void ProviderUpdateNotice::evaluate() {
  auto* settings = this->settings();
  if (!m_active || !settings) return;
  const QJsonArray local = settings->config().value(QLatin1String("providers")).toArray();
  if (m_sidebar.setProviders(local, m_now())) publish();

  // Offers wait for the cluster's members, so one machine is not offered
  // alone and then again with the others.
  if (m_store->synchronized()) {
    const QString here = m_client->environment();
    QStringList environments{here};
    for (const QString& environmentId : m_store->environments()) {
      if (environmentId != here && !environmentId.isEmpty()) environments.append(environmentId);
    }
    for (auto it = m_remote.begin(); it != m_remote.end();) {
      it = environments.contains(it.key()) ? std::next(it) : m_remote.erase(it);
    }
    if (environments.size() > 1) {
      if (!m_rowsMode) {
        closePrompt();
        m_rowsMode = true;
      }
      m_scope->setTargets(environments.mid(1));
      evaluateRows(environments, local);
    } else {
      if (m_rowsMode) {
        closePrompt();
        m_rowsMode = false;
        m_settlingSince.reset();
        m_scope->setTargets({});
      }
      evaluateSingle(local);
    }
  }
  schedule();
}

void ProviderUpdateNotice::closePrompt() {
  if (!m_promptId.isEmpty() && m_toasts) m_toasts->dismiss(m_promptId);
  m_promptId.clear();
  m_promptKey.clear();
  m_rows.clear();
  m_interacted = false;
}

void ProviderUpdateNotice::evaluateSingle(const QJsonArray& providers) {
  // An update the user started reports once the MC says how it went.
  if (m_update) {
    QJsonArray followed;
    for (const QJsonValue& value : providers) {
      if (m_update->instanceIds.contains(instanceOf(value.toObject()))) followed.append(value);
    }
    if (report(followed)) m_update.reset();
    return;
  }

  const QList<QJsonObject> outdated = candidates(providers);
  const QString key = providerUpdates::key(outdated);

  // Other versions than the prompt offers: it no longer says what is true.
  if (!m_promptId.isEmpty() && m_promptKey != key) closePrompt();
  if (key.isEmpty() || !m_promptId.isEmpty() || m_seen.contains(key) || dismissedKeys().contains(key)) return;
  ToastController* toasts = this->toasts();
  if (!toasts) return;
  m_seen.insert(key);

  QJsonArray oneClickProviders;
  for (const QJsonObject& provider : outdated) {
    if (oneClick(provider, providers)) oneClickProviders.append(provider);
  }
  const View view = offer(outdated, !oneClickProviders.isEmpty());
  const ToastController::Action settingsAction{QStringLiteral("Settings"), [this] {
                                                 m_promptId.clear();
                                                 m_promptKey.clear();
                                                 openSettings();
                                               }};
  QList<ToastController::Action> actions;
  if (!oneClickProviders.isEmpty()) {
    actions.append({QStringLiteral("Update"), [this, oneClickProviders] { runUpdates(oneClickProviders); }});
  }
  actions.append(settingsAction);
  m_toasts = toasts;
  m_promptKey = key;
  m_promptId = toasts->showActions(view.type, view.title, view.description, actions, 0);
  disconnect(m_closed);
  m_closed = connect(toasts, &ToastController::closedByUser, this, [this, key](const QString& id) {
    if (id != m_promptId) return;
    m_promptId.clear();
    m_promptKey.clear();
    dismissKey(key);
  });
}

QList<Group> ProviderUpdateNotice::groups(const QStringList& environments, const QJsonArray& local) const {
  QList<Group> result;
  for (const QString& environmentId : environments) {
    const bool here = environmentId == m_client->environment();
    QString label = m_store->environment(environmentId).value(QLatin1String("label")).toString();
    if (label.isEmpty()) label = here ? QStringLiteral("This machine") : environmentId;
    // An online environment whose providers have not come is still connecting.
    const bool settling = !here && !m_remote.contains(environmentId) && m_store->environmentOnline(environmentId);
    result.append(group(environmentId, label, here ? local : m_remote.value(environmentId), settling));
  }
  return result;
}

void ProviderUpdateNotice::evaluateRows(const QStringList& environments, const QJsonArray& local) {
  m_groups = groups(environments, local);
  const QDateTime now = m_now();
  const bool settling = std::any_of(m_groups.cbegin(), m_groups.cend(), [](const Group& group) { return group.settling; });
  if (!settling) {
    m_settlingSince.reset();
  } else if (!m_settlingSince) {
    m_settlingSince = now;
  }
  const bool gated = settling && now < m_settlingSince->addMSecs(kSettlingMs);
  const QString key = providerUpdates::key(m_groups);
  m_liveKey = key;

  // A prompt the user has not acted on gives way to a changed set, unless
  // that set is only an environment reconnecting.
  if (!m_promptId.isEmpty() && m_promptKey != key && !m_interacted && (key.isEmpty() || !gated)) closePrompt();

  ToastController* toasts = this->toasts();
  if (m_promptId.isEmpty() && !key.isEmpty() && !gated && !m_seen.contains(key) && !dismissedKeys().contains(key) && toasts) {
    m_seen.insert(key);
    m_rows.clear();
    m_interacted = false;
    m_openedAt = iso(now);
    QList<QJsonObject> offered;
    for (const Group& group : std::as_const(m_groups)) offered += group.candidates;
    m_toasts = toasts;
    m_promptKey = key;
    m_promptId = toasts->showActions(QStringLiteral("warning"), offer(byDriver(offered), true).title, {},
                                     {{QStringLiteral("Settings"),
                                       [this] {
                                         m_promptId.clear();
                                         m_promptKey.clear();
                                         openSettings();
                                       }}},
                                     0);
    disconnect(m_closed);
    m_closed = connect(toasts, &ToastController::closedByUser, this, [this](const QString& id) {
      if (id != m_promptId) return;
      m_promptId.clear();
      m_promptKey.clear();
      // What is on offer as it closes, not as it opened.
      dismissKey(m_liveKey);
    });
  }
  if (!m_promptId.isEmpty()) showRows();
}

void ProviderUpdateNotice::showRows() {
  if (m_promptId.isEmpty() || !m_toasts) return;
  QList<ToastController::Row> rows;
  for (const Group& group : std::as_const(m_groups)) {
    const RowStatus status = m_rows.status(group, m_openedAt);
    if (group.candidates.isEmpty() && status.kind == QLatin1String("idle")) continue;
    const QString action = status.kind == QLatin1String("idle")                                                  ? QStringLiteral("Update")
                           : status.kind == QLatin1String("failed") || status.kind == QLatin1String("unchanged") ? QStringLiteral("Retry")
                                                                                                                 : QString();
    rows.append({group.environmentId, group.label, status.text, status.kind, action});
  }
  if (!m_toasts->setRows(m_promptId, rows, [this](const QString& environmentId) { startRow(environmentId); })) {
    m_promptId.clear();
    m_promptKey.clear();
  }
}

void ProviderUpdateNotice::startRow(const QString& environmentId) {
  const auto found = std::find_if(m_groups.cbegin(), m_groups.cend(),
                                  [&environmentId](const Group& group) { return group.environmentId == environmentId; });
  if (found == m_groups.cend() || found->candidates.isEmpty()) return;
  m_interacted = true;
  if (!m_store->environmentOnline(environmentId)) {
    m_rows.refuse(environmentId, kNotConnected);
    showRows();
    return;
  }
  const std::optional<int> version = m_rows.start(environmentId, m_now());
  if (!version) return;
  showRows();
  schedule();

  // Every candidate of the environment at once; the row says how the worst went.
  struct Run {
    qsizetype remaining = 0;
    int count = 0;
    std::optional<QString> rejected;
    QList<QJsonObject> snapshots;
  };
  auto run = std::make_shared<Run>();
  run->remaining = found->candidates.size();
  run->count = int(found->candidates.size());
  for (const QJsonObject& candidate : found->candidates) {
    const QString instanceId = instanceOf(candidate);
    m_client->call(this, environmentId, QStringLiteral("server.updateProvider"), request(candidate),
                   [this, run, environmentId, instanceId, version](const QJsonValue& result, const std::optional<QString>& error) {
                     if (error) {
                       if (!run->rejected) run->rejected = error->isEmpty() ? QStringLiteral("Provider update failed.") : *error;
                     } else {
                       for (const QJsonValue& value : result.toObject().value(QLatin1String("providers")).toArray()) {
                         if (instanceOf(value.toObject()) == instanceId) run->snapshots.append(value.toObject());
                       }
                     }
                     if (--run->remaining > 0) return;
                     if (run->rejected) {
                       m_rows.settle(environmentId, *version, *run->rejected);
                     } else {
                       m_rows.settle(environmentId, *version, {}, progress(worstByDriver(run->snapshots), run->count));
                     }
                     showRows();
                     schedule();
                   });
  }
}

void ProviderUpdateNotice::openSettings() {
  if (NativeWindow* window = NativeShell::of(this)) {
    if (auto* navigation = window->controller<NavigationController>()) {
      navigation->open(NavigationController::Route::settings(NavigationController::kProvidersSection));
    }
  }
}

void ProviderUpdateNotice::runUpdates(const QJsonArray& providers) {
  m_promptId.clear();
  m_promptKey.clear();
  Update update;
  for (const QJsonValue& value : providers) update.instanceIds.insert(instanceOf(value.toObject()));
  update.count = int(providers.size());
  const View view = running(update.count);
  if (ToastController* toasts = this->toasts()) update.toastId = toasts->showActions(view.type, view.title, view.description, {}, 0);
  m_update = update;

  // One after another; the first refusal ends it.
  struct Run {
    QJsonArray providers;
    qsizetype next = 0;
    QJsonArray snapshots;
  };
  auto run = std::make_shared<Run>(Run{providers, 0, {}});
  auto step = std::make_shared<std::function<void()>>();
  *step = [this, run, step] {
    if (!m_update) return;
    if (run->next >= run->providers.size()) {
      // The answers' snapshots of the updated instances; a later
      // `config.providers` reports it if these do not settle it.
      if (report(run->snapshots)) m_update.reset();
      return;
    }
    const QJsonObject provider = run->providers.at(run->next++).toObject();
    m_client->call(this, m_client->environment(), QStringLiteral("server.updateProvider"), request(provider),
                   [this, run, step](const QJsonValue& result, const std::optional<QString>& error) {
                     if (!m_update) return;
                     if (error) {
                       const Update update = *m_update;
                       m_update.reset();
                       const View view = rejected(update.count, error->isEmpty() ? QStringLiteral("Provider update failed.") : *error);
                       const QList<ToastController::Action> actions{{QStringLiteral("Settings"), [this] { openSettings(); }}};
                       if (ToastController* toasts = this->toasts();
                           toasts && !toasts->replace(update.toastId, view.type, view.title, view.description, actions, 0)) {
                         toasts->showActions(view.type, view.title, view.description, actions, 0);
                       }
                       return;
                     }
                     for (const QJsonValue& value : result.toObject().value(QLatin1String("providers")).toArray()) {
                       if (m_update->instanceIds.contains(instanceOf(value.toObject()))) run->snapshots.append(value);
                     }
                     (*step)();
                   });
  };
  (*step)();
}

// The update's toast turns into how it went once the snapshots settle it.
bool ProviderUpdateNotice::report(const QJsonArray& snapshots) {
  if (!m_update) return true;
  QList<QJsonObject> all;
  for (const QJsonValue& value : snapshots) all.append(value.toObject());
  const View view = progress(all, m_update->count);
  if (!view.terminal()) return false;
  QList<ToastController::Action> actions;
  if (view.phase != QLatin1String("succeeded")) actions.append({QStringLiteral("Settings"), [this] { openSettings(); }});
  const int timeout = view.phase == QLatin1String("succeeded") ? kSuccessMs : 0;
  if (ToastController* toasts = this->toasts();
      toasts && !toasts->replace(m_update->toastId, view.type, view.title, view.description, actions, timeout)) {
    toasts->showActions(view.type, view.title, view.description, actions, timeout);
  }
  return true;
}
