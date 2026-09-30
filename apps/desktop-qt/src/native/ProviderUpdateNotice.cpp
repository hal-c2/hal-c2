#include "ProviderUpdateNotice.h"

#include <QHash>
#include <QJsonObject>
#include <QMap>

#include <algorithm>
#include <memory>

#include "NativeShell.h"
#include "NavigationController.h"
#include "NodeClient.h"
#include "SettingsController.h"
#include "ToastController.h"

namespace {

const NativeControllerRegistrar<ProviderUpdateNotice> registrar(QStringLiteral("providerUpdateNotice"), {}, nullptr,
                                                                NativeControllerScope::Shared);

const QString kDismissedKey = QStringLiteral("dismissedProviderUpdateNotificationKeys");
// How long "Provider updated" stays (PROVIDER_UPDATE_SUCCESS_VISIBLE_MS).
constexpr int kSuccessMs = 3000;

// packages/contracts PROVIDER_DISPLAY_NAMES.
QString driverName(const QString& driver) {
  static const QHash<QString, QString> names{
      {QStringLiteral("antigravity"), QStringLiteral("Antigravity")},
      {QStringLiteral("codex"), QStringLiteral("Codex")},
      {QStringLiteral("claudeAgent"), QStringLiteral("Claude")},
      {QStringLiteral("cursor"), QStringLiteral("Cursor")},
      {QStringLiteral("grok"), QStringLiteral("Grok")},
      {QStringLiteral("acpRegistry"), QStringLiteral("ACP Registry")},
      {QStringLiteral("pi"), QStringLiteral("Pi")},
      {QStringLiteral("opencode"), QStringLiteral("OpenCode")},
  };
  return names.value(driver, driver);
}

QString version(const QString& value) {
  return value.startsWith(QLatin1Char('v')) ? value : QStringLiteral("v") + value;
}

QString text(const QJsonObject& object, QLatin1StringView path) {
  QJsonValue value = object;
  for (const QString& part : QString(path).split(QLatin1Char('.'))) value = value.toObject().value(part);
  return value.toString();
}

QString updateStatus(const QJsonObject& provider) {
  return text(provider, QLatin1StringView("updateState.status"));
}

bool updating(const QJsonObject& provider) {
  const QString status = updateStatus(provider);
  return status == QLatin1String("queued") || status == QLatin1String("running");
}

// ProviderUpdateLaunchNotification.logic.ts isProviderUpdateCandidate.
bool candidate(const QJsonObject& provider) {
  const QString compatibility = text(provider, QLatin1StringView("compatibilityAdvisory.latestVersionStatus"));
  return provider.value(QLatin1String("enabled")).toBool() && compatibility != QLatin1String("broken") &&
         compatibility != QLatin1String("unsupported") &&
         text(provider, QLatin1StringView("versionAdvisory.status")) == QLatin1String("behind_latest") &&
         !text(provider, QLatin1StringView("versionAdvisory.latestVersion")).isEmpty();
}

bool updatable(const QJsonObject& provider) {
  const QJsonObject advisory = provider.value(QLatin1String("versionAdvisory")).toObject();
  return advisory.value(QLatin1String("canUpdate")).toBool() &&
         !advisory.value(QLatin1String("updateCommand")).toString().isEmpty();
}

// One provider per driver: its default instance (named after the driver),
// else the one checked last.
QList<QJsonObject> byDriver(const QList<QJsonObject>& providers) {
  QMap<QString, QJsonObject> chosen;
  QStringList order;
  for (const QJsonObject& provider : providers) {
    const QString driver = provider.value(QLatin1String("driver")).toString();
    if (!chosen.contains(driver)) {
      chosen.insert(driver, provider);
      order.append(driver);
      continue;
    }
    const QJsonObject current = chosen.value(driver);
    if (provider.value(QLatin1String("instanceId")).toString() == driver) {
      chosen.insert(driver, provider);
    } else if (current.value(QLatin1String("instanceId")).toString() != driver &&
               provider.value(QLatin1String("checkedAt")).toString() >= current.value(QLatin1String("checkedAt")).toString()) {
      chosen.insert(driver, provider);
    }
  }
  QList<QJsonObject> result;
  for (const QString& driver : order) result.append(chosen.value(driver));
  return result;
}

QList<QJsonObject> candidates(const QJsonArray& providers) {
  QList<QJsonObject> found;
  for (const QJsonValue& value : providers) {
    if (candidate(value.toObject())) found.append(value.toObject());
  }
  return byDriver(found);
}

// canOneClickUpdateProviderCandidate: not already updating, and every
// outdated instance of its driver updates with the same command.
bool oneClick(const QJsonObject& provider, const QJsonArray& providers) {
  if (updating(provider) || !updatable(provider)) return false;
  QSet<QString> commands;
  const QString driver = provider.value(QLatin1String("driver")).toString();
  for (const QJsonValue& value : providers) {
    const QJsonObject other = value.toObject();
    if (other.value(QLatin1String("driver")).toString() != driver || !candidate(other)) continue;
    if (!updatable(other)) return false;
    commands.insert(text(other, QLatin1StringView("versionAdvisory.updateCommand")));
  }
  return commands.size() == 1;
}

// "Codex", "Codex and Claude", "Codex, Claude, and Cursor".
QString list(const QList<QJsonObject>& providers) {
  QStringList names;
  for (const QJsonObject& provider : providers) names.append(driverName(provider.value(QLatin1String("driver")).toString()));
  if (names.size() <= 2) return names.join(QStringLiteral(" and "));
  return names.mid(0, names.size() - 1).join(QStringLiteral(", ")) + QStringLiteral(", and ") + names.last();
}

}  // namespace

ProviderUpdateNotice::ProviderUpdateNotice(ShellBridge*, NodeClient* client, QObject* parent)
    : QObject(parent), m_client(client) {}

void ProviderUpdateNotice::activate() {
  if (m_active) return;
  m_active = true;
  if (auto* settings = this->settings()) connect(settings, &SettingsController::configChanged, this, &ProviderUpdateNotice::evaluate);
  evaluate();
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

void ProviderUpdateNotice::evaluate() {
  auto* settings = this->settings();
  if (!m_active || !settings) return;
  const QJsonArray providers = settings->config().value(QLatin1String("providers")).toArray();

  // An update the user started reports once the node says how it went.
  if (m_update) {
    QJsonArray followed;
    for (const QJsonValue& value : providers) {
      if (m_update->instanceIds.contains(value.toObject().value(QLatin1String("instanceId")).toString())) followed.append(value);
    }
    if (report(followed)) m_update.reset();
    return;
  }

  const QList<QJsonObject> outdated = candidates(providers);
  QStringList parts;
  for (const QJsonObject& provider : outdated) {
    parts.append(provider.value(QLatin1String("driver")).toString() + QLatin1Char(':') +
                 text(provider, QLatin1StringView("versionAdvisory.latestVersion")));
  }
  std::sort(parts.begin(), parts.end());
  const QString key = parts.join(QLatin1Char('|'));

  // Other versions than the prompt offers: it no longer says what is true.
  if (!m_promptId.isEmpty() && m_promptKey != key) {
    if (m_toasts) m_toasts->dismiss(m_promptId);
    m_promptId.clear();
    m_promptKey.clear();
  }
  if (key.isEmpty() || !m_promptId.isEmpty() || m_seen.contains(key) || dismissedKeys().contains(key)) return;
  ToastController* toasts = this->toasts();
  if (!toasts) return;
  m_seen.insert(key);

  QList<QJsonObject> oneClickProviders;
  for (const QJsonObject& provider : outdated) {
    if (oneClick(provider, providers)) oneClickProviders.append(provider);
  }
  const QString title =
      outdated.size() == 1
          ? QStringLiteral("Update Available: %1 %2")
                .arg(driverName(outdated.first().value(QLatin1String("driver")).toString()),
                     version(text(outdated.first(), QLatin1StringView("versionAdvisory.latestVersion"))))
          : QStringLiteral("Updates Available: %1 providers").arg(outdated.size());
  const QString description = oneClickProviders.isEmpty()
                                  ? QStringLiteral("%1 can be updated from provider settings.").arg(list(outdated))
                                  : QStringLiteral("Install the update now or review provider settings.");
  const ToastController::Action settingsAction{QStringLiteral("Settings"), [this] { openSettings(); }};
  QList<ToastController::Action> actions;
  if (oneClickProviders.isEmpty()) {
    actions.append(settingsAction);
  } else {
    QJsonArray chosen;
    for (const QJsonObject& provider : oneClickProviders) chosen.append(provider);
    actions.append({QStringLiteral("Update"), [this, chosen] { runUpdates(chosen); }});
    actions.append(settingsAction);
  }
  m_toasts = toasts;
  m_promptKey = key;
  m_promptId = toasts->showActions(QStringLiteral("warning"), title, description, actions, 0);
  disconnect(m_closed);
  m_closed = connect(toasts, &ToastController::closedByUser, this, [this, key](const QString& id) {
    if (id != m_promptId) return;
    m_promptId.clear();
    m_promptKey.clear();
    auto* settings = this->settings();
    if (!settings) return;
    QStringList dismissed = dismissedKeys();
    if (!dismissed.contains(key)) dismissed.append(key);
    settings->writeDevice(kDismissedKey, dismissed);
  });
}

void ProviderUpdateNotice::openSettings() {
  m_promptId.clear();
  m_promptKey.clear();
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
  for (const QJsonValue& value : providers) update.instanceIds.insert(value.toObject().value(QLatin1String("instanceId")).toString());
  update.count = int(providers.size());
  m_update = update;

  // One after another, as the web does; the first refusal ends it.
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
    const QJsonObject request{{QStringLiteral("provider"), provider.value(QLatin1String("driver"))},
                              {QStringLiteral("instanceId"), provider.value(QLatin1String("instanceId"))}};
    m_client->call(this, m_client->environment(), QStringLiteral("server.updateProvider"), request,
                   [this, run, step](const QJsonValue& result, const std::optional<QString>& error) {
                     if (!m_update) return;
                     if (error) {
                       const int count = m_update->count;
                       m_update.reset();
                       if (ToastController* toasts = this->toasts()) {
                         toasts->showActions(QStringLiteral("error"),
                                             count == 1 ? QStringLiteral("Provider update failed")
                                                        : QStringLiteral("Provider updates failed"),
                                             error->isEmpty() ? QStringLiteral("Provider update failed.") : *error,
                                             {{QStringLiteral("Settings"), [this] { openSettings(); }}}, 0);
                       }
                       return;
                     }
                     for (const QJsonValue& value : result.toObject().value(QLatin1String("providers")).toArray()) {
                       if (m_update->instanceIds.contains(value.toObject().value(QLatin1String("instanceId")).toString())) {
                         run->snapshots.append(value);
                       }
                     }
                     (*step)();
                   });
  };
  (*step)();
}

// getProviderUpdateProgressToastView: failed, then unchanged, then done once
// every provider reports it succeeded.
bool ProviderUpdateNotice::report(const QJsonArray& snapshots) {
  if (!m_update) return true;
  QList<QJsonObject> all;
  for (const QJsonValue& value : snapshots) all.append(value.toObject());
  const QList<QJsonObject> providers = byDriver(all);
  QList<QJsonObject> failed, unchanged;
  for (const QJsonObject& provider : providers) {
    if (updateStatus(provider) == QLatin1String("failed")) failed.append(provider);
    if (updateStatus(provider) == QLatin1String("unchanged")) unchanged.append(provider);
  }
  ToastController* toasts = this->toasts();
  const ToastController::Action settingsAction{QStringLiteral("Settings"), [this] { openSettings(); }};
  if (!failed.isEmpty()) {
    const QString message = text(failed.first(), QLatin1StringView("updateState.message"));
    const QString description =
        failed.size() == 1 && !message.isEmpty()
            ? message
            : QStringLiteral("%1 failed to update. Check provider settings for details.").arg(list(failed));
    if (toasts) {
      toasts->showActions(QStringLiteral("error"),
                          failed.size() == 1 ? QStringLiteral("Provider update failed") : QStringLiteral("Provider updates failed"),
                          description, {settingsAction}, 0);
    }
    return true;
  }
  if (!unchanged.isEmpty()) {
    if (toasts) {
      toasts->showActions(QStringLiteral("warning"),
                          unchanged.size() == 1 ? QStringLiteral("Provider still needs an update")
                                                : QStringLiteral("Providers still need updates"),
                          QStringLiteral("%1 %2 outdated. Check provider settings for details.")
                              .arg(list(unchanged), unchanged.size() == 1 ? QStringLiteral("still appears")
                                                                           : QStringLiteral("still appear")),
                          {settingsAction}, 0);
    }
    return true;
  }
  if (std::any_of(providers.cbegin(), providers.cend(), updating)) return false;
  const int count = m_update->count;
  const bool done = providers.size() >= count && std::all_of(providers.cbegin(), providers.cend(), [](const QJsonObject& provider) {
                      return updateStatus(provider) == QLatin1String("succeeded") || !candidate(provider);
                    });
  if (!done) return false;
  if (toasts) {
    toasts->show(QStringLiteral("success"), count == 1 ? QStringLiteral("Provider updated") : QStringLiteral("Provider updates finished"),
                 count == 1 ? QStringLiteral("New sessions will use the updated provider.")
                            : QStringLiteral("New sessions will use the updated providers."),
                 {}, kSuccessMs);
  }
  return true;
}
