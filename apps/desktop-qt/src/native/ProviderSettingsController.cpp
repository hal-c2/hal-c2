#include "ProviderSettingsController.h"

#include <QClipboard>
#include <QPointer>
#include <QGuiApplication>
#include <QRegularExpression>
#include <QUrl>

#include <algorithm>
#include <cmath>

#include "CommandRegistry.h"
#include "EnvironmentSettings.h"
#include "KeybindingController.h"
#include "Keybindings.h"
#include "MenuController.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "NodeClient.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ToastController.h"

namespace {

const NativeControllerRegistrar<ProviderSettingsController> registrar(QStringLiteral("providerSettings"),
                                                                      {QStringLiteral("providerSettings")});

const QString kKey = QStringLiteral("providerSettings");
const QString kRegistry = QStringLiteral("acpRegistry");
const QString kHealthKey = QStringLiteral("providerHealthRefreshInterval");

// The node's background activity presets' provider health intervals
// (HalC2.BackgroundPolicy), in seconds.
int presetHealthSeconds(const QString& profile) {
  if (profile == QLatin1String("performance")) return 60;
  if (profile == QLatin1String("battery-saver")) return 900;
  return 300;
}

// The preset a `backgroundActivity` builds on: its profile, or for a custom
// one the profile it started from.
QString baseProfile(const QJsonObject& activity) {
  const QString profile = activity.value(QLatin1String("profile")).toString();
  const QString base = profile == QLatin1String("custom") ? activity.value(QLatin1String("baseProfile")).toString() : profile;
  return base == QLatin1String("performance") || base == QLatin1String("battery-saver") ? base : QStringLiteral("balanced");
}

// The provider health interval the node uses, in seconds (BackgroundPolicy.settings).
int healthSeconds(const QJsonObject& settings) {
  const QJsonObject activity = settings.value(QLatin1String("backgroundActivity")).toObject();
  const QJsonObject overrides = activity.value(QLatin1String("overrides")).toObject();
  if (activity.value(QLatin1String("profile")) == QLatin1String("custom") && overrides.value(kHealthKey).isDouble()) {
    return int(overrides.value(kHealthKey).toDouble() / 1000);
  }
  return presetHealthSeconds(baseProfile(activity));
}

// `settings` with the health interval overridden (`seconds`) or back to its
// preset (none), as the web's backgroundActivityOverrideSettings: a custom
// profile on the current base, keeping the overrides a custom profile had.
QJsonObject withHealthSeconds(QJsonObject settings, std::optional<int> seconds) {
  const QJsonObject activity = settings.value(QLatin1String("backgroundActivity")).toObject();
  QJsonObject overrides = activity.value(QLatin1String("profile")) == QLatin1String("custom")
                              ? activity.value(QLatin1String("overrides")).toObject()
                              : QJsonObject{};
  if (seconds) overrides.insert(kHealthKey, qint64(*seconds) * 1000);
  else overrides.remove(kHealthKey);
  settings.insert(QStringLiteral("backgroundActivity"), QJsonObject{{QStringLiteral("schemaVersion"), 1},
                                                                    {QStringLiteral("profile"), QStringLiteral("custom")},
                                                                    {QStringLiteral("baseProfile"), baseProfile(activity)},
                                                                    {QStringLiteral("overrides"), overrides}});
  return settings;
}

QVariant null() {
  return QVariant::fromValue(nullptr);
}

QString text(const QJsonValue& value) {
  return value.toString().trimmed();
}

// getProviderVersionLabel: bare versions get a `v`; Antigravity's release tag
// shows as its date and candidate.
QString versionLabel(const QString& version) {
  if (version.isEmpty()) return {};
  static const QRegularExpression antigravity(QStringLiteral("^agy_acp_server_(\\d{4})(\\d{2})(\\d{2})_\\d+(?:_(\\w+))?$"));
  if (const auto match = antigravity.match(version); match.hasMatch()) {
    const QString candidate = match.captured(4);
    return QStringLiteral("%1-%2-%3").arg(match.captured(1), match.captured(2), match.captured(3)) +
           (candidate.isEmpty() ? QString() : QStringLiteral(" ") + candidate);
  }
  return version.front().isDigit() ? QStringLiteral("v") + version : version;
}

// getProviderSummary: the line under a provider's name.
QPair<QString, QString> summary(const QJsonObject& provider) {
  const QJsonObject auth = provider.value(QLatin1String("auth")).toObject();
  const QString message = text(provider.value(QLatin1String("message")));
  const QString status = provider.value(QLatin1String("status")).toString();
  const QString authStatus = auth.value(QLatin1String("status")).toString();
  const QString authLabel = !text(auth.value(QLatin1String("label"))).isEmpty() ? text(auth.value(QLatin1String("label")))
                                                                                  : text(auth.value(QLatin1String("type")));
  const auto or_ = [&message](const QString& fallback) { return message.isEmpty() ? fallback : message; };
  if (!provider.value(QLatin1String("enabled")).toBool() || status == QLatin1String("disabled")) {
    return {QStringLiteral("Disabled"), or_(QStringLiteral("This provider is installed but disabled for new sessions in HAL-C2."))};
  }
  if (!provider.value(QLatin1String("installed")).toBool()) {
    return {QStringLiteral("Not found"), or_(QStringLiteral("CLI not detected on PATH."))};
  }
  if (authStatus == QLatin1String("unauthenticated")) {
    return {authLabel.isEmpty() ? QStringLiteral("Not authenticated") : QStringLiteral("Not authenticated · ") + authLabel, message};
  }
  if (status == QLatin1String("warning")) {
    return {QStringLiteral("Needs attention"),
            or_(QStringLiteral("The provider is installed, but the server could not fully verify it."))};
  }
  if (status == QLatin1String("error")) {
    return {QStringLiteral("Unavailable"), or_(QStringLiteral("The provider failed its startup checks."))};
  }
  if (authStatus == QLatin1String("authenticated")) {
    return {authLabel.isEmpty() ? QStringLiteral("Authenticated") : QStringLiteral("Authenticated · ") + authLabel, message};
  }
  return {QStringLiteral("Available"), message};
}

// getProviderVersionAdvisoryPresentation: a version outside the supported
// range first, else an update, else nothing.
QVariant advisory(const QJsonObject& provider) {
  const QJsonObject version = provider.value(QLatin1String("versionAdvisory")).toObject();
  const QJsonObject compatibility = provider.value(QLatin1String("compatibilityAdvisory")).toObject();
  const QString latestStatus = compatibility.value(QLatin1String("latestVersionStatus")).toString();
  const bool latestIncompatible = latestStatus == QLatin1String("broken") || latestStatus == QLatin1String("unsupported");
  const QVariant updateCommand = version.value(QLatin1String("updateCommand")).isString()
                                     ? QVariant(version.value(QLatin1String("updateCommand")).toString())
                                     : null();
  static const QHash<QString, QString> titles{{QStringLiteral("graceful"), QStringLiteral("Limited support")},
                                              {QStringLiteral("unsupported"), QStringLiteral("Unsupported version")},
                                              {QStringLiteral("broken"), QStringLiteral("Known broken version")}};
  const QString status = compatibility.value(QLatin1String("status")).toString();
  // A disabled provider's version does not matter until it is turned on.
  if (provider.value(QLatin1String("enabled")).toBool() && titles.contains(status)) {
    const QString target = text(compatibility.value(QLatin1String("recommendedVersion")));
    const QString recommendation = target.isEmpty() ? text(compatibility.value(QLatin1String("recommendedRange"))) : versionLabel(target);
    QString detail = text(compatibility.value(QLatin1String("message")));
    if (detail.isEmpty()) {
      detail = recommendation.isEmpty() ? QStringLiteral("Update for full support.")
                                        : QStringLiteral("Use %1 for full support.").arg(recommendation);
    }
    return QVariantMap{{QStringLiteral("title"), titles.value(status)},
                       {QStringLiteral("detail"), detail},
                       {QStringLiteral("updateCommand"), !target.isEmpty() || latestIncompatible ? null() : updateCommand},
                       {QStringLiteral("targetVersion"), target.isEmpty() ? null() : QVariant(target)},
                       {QStringLiteral("strong"), status != QLatin1String("graceful")}};
  }
  const QString versionStatus = version.value(QLatin1String("status")).toString();
  if (version.isEmpty() || versionStatus == QLatin1String("current") || versionStatus == QLatin1String("unknown") ||
      latestIncompatible) {
    return null();
  }
  const QString latest = versionLabel(text(version.value(QLatin1String("latestVersion"))));
  QString detail = text(version.value(QLatin1String("message")));
  if (detail.isEmpty()) {
    detail = latest.isEmpty() ? QStringLiteral("Update available: install the latest provider version.")
                              : QStringLiteral("Update available: install %1.").arg(latest);
  }
  return QVariantMap{{QStringLiteral("title"), QStringLiteral("Update available")},
                     {QStringLiteral("detail"), detail},
                     {QStringLiteral("updateCommand"), updateCommand},
                     {QStringLiteral("targetVersion"), null()},
                     {QStringLiteral("strong"), false}};
}

// isProviderSettingsUpdateCandidate: the environment can run the update itself.
bool updatable(const QJsonObject& provider) {
  const QJsonObject version = provider.value(QLatin1String("versionAdvisory")).toObject();
  const QString latestStatus =
      provider.value(QLatin1String("compatibilityAdvisory")).toObject().value(QLatin1String("latestVersionStatus")).toString();
  return provider.value(QLatin1String("enabled")).toBool() && latestStatus != QLatin1String("broken") &&
         latestStatus != QLatin1String("unsupported") && version.value(QLatin1String("status")) == QLatin1String("behind_latest") &&
         version.value(QLatin1String("canUpdate")).toBool() && version.value(QLatin1String("updateCommand")).isString();
}

// Whether the web offers the provider's Account section.
bool signsIn(const QJsonObject& provider) {
  return provider.value(QLatin1String("setup")).toObject().value(QLatin1String("canAuthenticate")).toBool() ||
         (provider.value(QLatin1String("driver")).toString() == kRegistry && provider.value(QLatin1String("installed")).toBool());
}

}  // namespace

ProviderSettingsController::ProviderSettingsController(ShellBridge* bridge, NodeClient* client, ShellStore* store,
                                                       QObject* parent)
    : QObject(parent), m_bridge(bridge), m_client(client), m_store(store), m_scope(new EnvironmentSettings(client, this)) {
  connect(m_scope, &EnvironmentSettings::frame, this, [this](const QString&, const QJsonObject& frame) {
    const QString type = frame.value(QLatin1String("t")).toString();
    if (type == QLatin1String("config")) {
      m_providers = frame.value(QLatin1String("config")).toObject().value(QLatin1String("providers")).toArray();
    } else if (type == QLatin1String("config.providers")) {
      m_providers = frame.value(QLatin1String("providers")).toArray();
    } else {
      return;
    }
    followAuth();
    publish();
  });
  connect(m_scope, &EnvironmentSettings::changed, this, &ProviderSettingsController::publish);
  m_writeClipboard = [](const QString& value) {
    QClipboard* clipboard = QGuiApplication::clipboard();
    if (!clipboard) return false;
    clipboard->setText(value);
    return true;
  };
}

void ProviderSettingsController::activate() {
  if (m_active) return;
  m_active = true;
  m_bridge->claimKey(kKey);
  auto* navigation = NativeShell::of(this)->controller<NavigationController>();
  const auto section = NavigationController::Route::settings(NavigationController::kProvidersSection);
  if (auto* keys = NativeShell::of(this)->controller<KeybindingController>()) {
    keys->commands()->add(QStringLiteral("providers.open"), tr("Open provider settings"),
                          [navigation, section] { navigation->open(section); });
  }
  connect(navigation, &NavigationController::changed, this,
          [this, navigation, section] { setOpen(navigation->route() == section); });
  // An environment that comes, goes, or drops changes what can be shown.
  connect(m_store, &ShellStore::changed, this, [this] {
    if (m_open) update();
  });
  setOpen(navigation->route() == section);
  publish();
}

bool ProviderSettingsController::handle(const QString& action, const QVariant& payload) {
  if (!m_active || !action.startsWith(QLatin1String("providerSettings."))) return false;
  const QVariantMap input = payload.toMap();
  const QString instanceId = input.value(QStringLiteral("instanceId")).toString();
  const QJsonObject entry = provider(instanceId);
  const QJsonObject auth = m_authState.value(instanceId);
  if (action == QLatin1String("providerSettings.environment")) {
    m_environment = input.value(QStringLiteral("id")).toString();
    update();
  } else if (action == QLatin1String("providerSettings.refresh")) {
    if (m_followed.isEmpty()) return true;
    ++m_refreshing;
    publish();
    m_client->call(m_followed, QStringLiteral("server.refreshProviders"), QJsonObject{{QStringLiteral("refreshModels"), true}},
                   [this](const QJsonValue&, const std::optional<QString>& error) {
                     --m_refreshing;
                     if (error) {
                       if (auto* toasts = NativeShell::of(this)->controller<ToastController>()) {
                         toasts->error(QStringLiteral("Could not refresh providers"), *error);
                       }
                     }
                     publish();
                   });
  } else if (action == QLatin1String("providerSettings.healthInterval")) {
    const int seconds = std::max(0, int(std::lround(input.value(QStringLiteral("seconds")).toDouble())));
    save([seconds](QJsonObject settings, const QString&) { return withHealthSeconds(settings, seconds); });
  } else if (action == QLatin1String("providerSettings.resetHealthInterval")) {
    save([](QJsonObject settings, const QString&) { return withHealthSeconds(settings, std::nullopt); });
  } else if (entry.isEmpty()) {
    return true;
  } else if (action == QLatin1String("providerSettings.enable")) {
    setEnabled(instanceId, input.value(QStringLiteral("enabled")).toBool());
  } else if (action == QLatin1String("providerSettings.signIn")) {
    call(instanceId, QStringLiteral("provider.auth.start"), {{QStringLiteral("instanceId"), instanceId}},
         QStringLiteral("Provider sign-in failed. Try again."));
  } else if (action == QLatin1String("providerSettings.cancelSignIn")) {
    const QString flowId = auth.value(QLatin1String("flowId")).toString();
    if (!flowId.isEmpty()) {
      call(instanceId, QStringLiteral("provider.auth.cancel"),
           {{QStringLiteral("instanceId"), instanceId}, {QStringLiteral("flowId"), flowId}},
           QStringLiteral("Provider sign-in failed. Try again."));
    }
  } else if (action == QLatin1String("providerSettings.openSignIn")) {
    const QJsonObject interaction = auth.value(QLatin1String("interaction")).toObject();
    const QString type = interaction.value(QLatin1String("type")).toString();
    const QString url = type == QLatin1String("browser") || type == QLatin1String("deviceCode")
                            ? interaction.value(QLatin1String("url")).toString()
                            : auth.value(QLatin1String("authorizationUrl")).toString();
    if (url.isEmpty()) return true;
    if (type == QLatin1String("browser") && interaction.value(QLatin1String("requiresConsent")).toBool()) {
      // The environment records consent before its provider's page opens here.
      const QString environmentId = m_followed;
      m_busy.insert(instanceId);
      publish();
      m_client->call(environmentId, QStringLiteral("provider.auth.respond"),
                     QJsonObject{{QStringLiteral("instanceId"), instanceId},
                                 {QStringLiteral("flowId"), auth.value(QLatin1String("flowId"))},
                                 {QStringLiteral("interactionId"), interaction.value(QLatin1String("id"))},
                                 {QStringLiteral("response"), QJsonObject{{QStringLiteral("type"), QStringLiteral("browser")},
                                                                          {QStringLiteral("action"), QStringLiteral("accept")}}}},
                     [this, instanceId, url](const QJsonValue&, const std::optional<QString>& error) {
                       m_busy.remove(instanceId);
                       if (error) m_authError.insert(instanceId, *error);
                       else m_bridge->openExternal(QUrl(url));
                       publish();
                     });
    } else {
      m_bridge->openExternal(QUrl(url));
    }
  } else if (action == QLatin1String("providerSettings.signOut")) {
    auto* menu = NativeShell::of(this)->controller<MenuController>();
    if (!menu) return true;
    const QString name = text(entry.value(QLatin1String("displayName"))).isEmpty() ? entry.value(QLatin1String("driver")).toString()
                                                                                  : text(entry.value(QLatin1String("displayName")));
    const QString environmentId = m_followed;
    menu->confirm(QStringLiteral("Sign out?"),
                  QStringLiteral("Sign out of %1 on %2? This stops running threads that share this sign-in. Thread history is kept.")
                      .arg(name, label(environmentId)),
                  QStringLiteral("Sign out"), true, [this, instanceId, environmentId] {
                    // The answer may come after the user moved on.
                    if (m_followed != environmentId) return;
                    call(instanceId, QStringLiteral("provider.auth.logout"), {{QStringLiteral("instanceId"), instanceId}},
                         QStringLiteral("Could not sign out."));
                  });
  } else if (action == QLatin1String("providerSettings.update")) {
    if (m_updating.contains(instanceId) || !updatable(entry)) return true;
    const QString driver = entry.value(QLatin1String("driver")).toString();
    const QString name = text(entry.value(QLatin1String("displayName"))).isEmpty() ? driver : text(entry.value(QLatin1String("displayName")));
    m_updating.insert(instanceId);
    publish();
    m_client->call(m_followed, QStringLiteral("server.updateProvider"), QJsonObject{{QStringLiteral("provider"), driver}, {QStringLiteral("instanceId"), instanceId}},
                   [this, instanceId, name](const QJsonValue&, const std::optional<QString>& error) {
                     m_updating.remove(instanceId);
                     if (error) {
                       if (auto* toasts = NativeShell::of(this)->controller<ToastController>()) {
                         toasts->error(QStringLiteral("Could not update %1").arg(name),
                                       error->isEmpty() ? QStringLiteral("The provider update command could not be started.") : *error);
                       }
                     }
                     publish();
                   });
  } else if (action == QLatin1String("providerSettings.copyUpdateCommand")) {
    const QString command = advisory(entry).toMap().value(QStringLiteral("updateCommand")).toString();
    auto* toasts = NativeShell::of(this)->controller<ToastController>();
    if (command.isEmpty()) return true;
    if (m_writeClipboard(command)) {
      if (toasts) toasts->show(QStringLiteral("success"), QStringLiteral("Update command copied"), QStringLiteral("Run it in a terminal when ready."));
    } else if (toasts) {
      toasts->error(QStringLiteral("Could not copy the update command"));
    }
  }
  return true;
}

void ProviderSettingsController::setOpen(bool open) {
  if (open == m_open) return;
  m_open = open;
  if (open) {
    update();
  } else {
    // Nothing is followed for a section nobody sees.
    unfollow();
    publish();
  }
}

// Follows the chosen environment while it can answer.
void ProviderSettingsController::update() {
  if (!m_open) return;
  const QString environmentId = chosen();
  if (!environmentId.isEmpty() && m_store->environmentOnline(environmentId)) {
    follow(environmentId);
  } else {
    unfollow();
  }
  publish();
}

void ProviderSettingsController::follow(const QString& environmentId) {
  if (m_followed == environmentId) {
    followAuth();
    return;
  }
  unfollow();
  m_followed = environmentId;
  m_scope->setTargets({environmentId});
}

void ProviderSettingsController::unfollow() {
  m_scope->setTargets({});
  m_followed.clear();
  m_providers.reset();
  for (const int id : std::as_const(m_auth)) m_client->unsubscribe(id);
  m_auth.clear();
  m_authState.clear();
  m_authError.clear();
  m_busy.clear();
}

// Follows the sign-in of each provider that signs in from HAL-C2; the shape
// is node-addressed, so only where a cluster node serves the environment.
void ProviderSettingsController::followAuth() {
  const QString node = m_store->nodeServing(m_followed);
  QSet<QString> wanted;
  if (!node.isEmpty() && m_providers) {
    for (const QJsonValue& value : *m_providers) {
      if (signsIn(value.toObject())) wanted.insert(value.toObject().value(QLatin1String("instanceId")).toString());
    }
  }
  for (auto it = m_auth.begin(); it != m_auth.end();) {
    if (wanted.contains(it.key())) {
      ++it;
      continue;
    }
    m_client->unsubscribe(it.value());
    m_authState.remove(it.key());
    it = m_auth.erase(it);
  }
  for (const QString& instanceId : std::as_const(wanted)) {
    if (m_auth.contains(instanceId)) continue;
    m_auth.insert(instanceId, m_client->subscribe({{QStringLiteral("type"), QStringLiteral("providerAuth")},
                                                   {QStringLiteral("node"), node},
                                                   {QStringLiteral("instanceId"), instanceId}},
                                                  [this, instanceId](const QJsonObject& frame) {
                                                    if (frame.value(QLatin1String("t")) != QLatin1String("providerAuth")) return;
                                                    m_authState.insert(instanceId, frame.value(QLatin1String("state")).toObject());
                                                    publish();
                                                  }));
  }
}

// The chosen environment, or this machine; one that went away falls back to
// this machine until it comes back.
QString ProviderSettingsController::chosen() const {
  const QStringList environments = m_store->environments();
  if (!m_environment.isEmpty() && environments.contains(m_environment) && m_store->reaches(m_environment)) return m_environment;
  const QString local = m_client->environment();
  return environments.contains(local) ? local : QString();
}

QString ProviderSettingsController::label(const QString& environmentId) const {
  const QString label = m_store->environment(environmentId).value(QLatin1String("label")).toString();
  if (!label.isEmpty()) return label;
  return environmentId == m_client->environment() ? QStringLiteral("This machine") : environmentId;
}

QJsonObject ProviderSettingsController::provider(const QString& instanceId) const {
  if (!m_providers || instanceId.isEmpty()) return {};
  for (const QJsonValue& value : *m_providers) {
    if (value.toObject().value(QLatin1String("instanceId")).toString() == instanceId) return value.toObject();
  }
  return {};
}

// Turns an instance on or off where the node reads it: its providerInstances
// entry when it has one, and a built-in driver's `providers` entry.
void ProviderSettingsController::setEnabled(const QString& instanceId, bool enabled) {
  const QString driver = provider(instanceId).value(QLatin1String("driver")).toString();
  save([instanceId, driver, enabled](QJsonObject settings, const QString&) {
    QJsonObject instances = settings.value(QLatin1String("providerInstances")).toObject();
    if (instances.contains(instanceId)) {
      QJsonObject instance = instances.value(instanceId).toObject();
      instance.insert(QStringLiteral("enabled"), enabled);
      instances.insert(instanceId, instance);
      settings.insert(QStringLiteral("providerInstances"), instances);
    }
    if (!instances.contains(instanceId) || instanceId == driver) {
      QJsonObject providers = settings.value(QLatin1String("providers")).toObject();
      QJsonObject entry = providers.value(instanceId).toObject();
      entry.insert(QStringLiteral("enabled"), enabled);
      providers.insert(instanceId, entry);
      settings.insert(QStringLiteral("providers"), providers);
    }
    return settings;
  });
}

// Edits the shown environment's settings document; `saved` runs once it is.
void ProviderSettingsController::save(const std::function<QJsonObject(QJsonObject, const QString&)>& edit,
                                      const std::function<void()>& saved, const QString& failure) {
  const QPointer<ProviderSettingsController> self(this);
  m_scope->change(edit, [self, saved, failure](const QHash<QString, QString>& failed, int) {
    if (!self) return;
    if (failed.isEmpty()) {
      if (saved) saved();
      return;
    }
    if (auto* toasts = NativeShell::of(self)->controller<ToastController>()) {
      toasts->error(failure.isEmpty() ? QStringLiteral("Could not save provider settings") : failure, failed.cbegin().value());
    }
  });
}

void ProviderSettingsController::call(const QString& instanceId, const QString& method, const QJsonObject& payload,
                                      const QString& failure) {
  if (m_busy.contains(instanceId) || m_followed.isEmpty()) return;
  m_busy.insert(instanceId);
  m_authError.remove(instanceId);
  publish();
  const QString environmentId = m_followed;
  m_client->call(environmentId, method, payload,
                 [this, instanceId, environmentId, failure](const QJsonValue&, const std::optional<QString>& error) {
                   if (m_followed != environmentId) return;
                   m_busy.remove(instanceId);
                   if (error) m_authError.insert(instanceId, error->isEmpty() ? failure : *error);
                   publish();
                 });
}

QVariantMap ProviderSettingsController::entry(const QJsonObject& provider) const {
  const QString instanceId = provider.value(QLatin1String("instanceId")).toString();
  const QString driver = provider.value(QLatin1String("driver")).toString();
  const QJsonObject auth = provider.value(QLatin1String("auth")).toObject();
  const auto [headline, detail] = summary(provider);
  QVariantList models;
  for (const QJsonValue& model : provider.value(QLatin1String("models")).toArray()) {
    models.append(QVariantMap{{QStringLiteral("slug"), model.toObject().value(QLatin1String("slug")).toString()},
                              {QStringLiteral("name"), model.toObject().value(QLatin1String("name")).toString()}});
  }
  const QVariant advice = advisory(provider);
  const QString updateStatus = provider.value(QLatin1String("updateState")).toObject().value(QLatin1String("status")).toString();
  const bool updating = m_updating.contains(instanceId) || updateStatus == QLatin1String("queued") ||
                        updateStatus == QLatin1String("running");
  const QString name = text(provider.value(QLatin1String("displayName")));
  QVariantMap result{
      {QStringLiteral("instanceId"), instanceId},
      {QStringLiteral("driver"), driver},
      {QStringLiteral("name"), name.isEmpty() ? driver : name},
      {QStringLiteral("version"), versionLabel(text(provider.value(QLatin1String("version"))))},
      {QStringLiteral("enabled"), provider.value(QLatin1String("enabled")).toBool()},
      {QStringLiteral("installed"), provider.value(QLatin1String("installed")).toBool()},
      {QStringLiteral("status"), provider.value(QLatin1String("status")).toString()},
      {QStringLiteral("headline"), headline},
      {QStringLiteral("detail"), detail},
      {QStringLiteral("email"), text(auth.value(QLatin1String("email")))},
      {QStringLiteral("models"), models},
      {QStringLiteral("advisory"), advice},
      {QStringLiteral("canUpdate"), updatable(provider)},
      {QStringLiteral("updating"), updating},
      {QStringLiteral("account"), null()},
  };
  if (!signsIn(provider)) return result;
  // ProviderAuthenticationSection, without the terminal and credential prompts.
  const bool served = !m_store->nodeServing(m_followed).isEmpty();
  const bool known = m_authState.contains(instanceId);
  const QJsonObject state = m_authState.value(instanceId);
  const QString phase = state.value(QLatin1String("phase")).toString();
  const QJsonObject interaction = state.value(QLatin1String("interaction")).toObject();
  const QString interactionType = interaction.value(QLatin1String("type")).toString();
  const bool active = phase == QLatin1String("starting") || phase == QLatin1String("waiting") || phase == QLatin1String("verifying");
  const QString authStatus = auth.value(QLatin1String("status")).toString();
  const bool signedIn = authStatus == QLatin1String("authenticated") ||
                        (authStatus == QLatin1String("unknown") && phase == QLatin1String("succeeded"));
  const bool registry = driver == kRegistry;
  const bool discovering = registry && known && !active && !signedIn && !state.contains(QLatin1String("methods"));
  const QJsonObject setup = provider.value(QLatin1String("setup")).toObject();
  const bool externalSetup = !active && !signedIn &&
                             ((setup.contains(QLatin1String("canAuthenticate")) && !setup.value(QLatin1String("canAuthenticate")).toBool()) ||
                              (registry && state.value(QLatin1String("methods")).isArray() &&
                               state.value(QLatin1String("methods")).toArray().isEmpty()));
  QString description;
  if (!served) {
    description = QStringLiteral("Sign in from a client paired with %1.").arg(label(m_followed));
  } else if (active) {
    description = phase == QLatin1String("starting")    ? QStringLiteral("Starting sign-in…")
                  : phase == QLatin1String("verifying") ? QStringLiteral("Checking your account…")
                  : interactionType == QLatin1String("terminal") || interactionType == QLatin1String("credentials")
                      ? QStringLiteral("This sign-in asks for input the desktop cannot show yet. Finish it from another client.")
                      : QStringLiteral("Finish signing in in your browser.");
  } else if (signedIn) {
    description = QStringLiteral("Signed in.");
  } else if (discovering) {
    description = QStringLiteral("Discovering sign-in methods…");
  } else if (externalSetup) {
    description = QStringLiteral("No in-app sign-in advertised. Follow the provider's docs to finish setup.");
  } else {
    description = QStringLiteral("Sign in on %1.").arg(label(m_followed));
  }
  const bool busy = m_busy.contains(instanceId);
  const bool canLogout = auth.contains(QLatin1String("canLogout")) ? auth.value(QLatin1String("canLogout")).toBool()
                                                                    : setup.value(QLatin1String("canAuthenticate")).toBool();
  const QString url = interactionType == QLatin1String("browser") || interactionType == QLatin1String("deviceCode")
                          ? interaction.value(QLatin1String("url")).toString()
                          : state.value(QLatin1String("authorizationUrl")).toString();
  QString error = m_authError.value(instanceId);
  if (error.isEmpty() && phase == QLatin1String("failed")) error = state.value(QLatin1String("message")).toString();
  result.insert(QStringLiteral("account"),
                QVariantMap{
                    {QStringLiteral("description"), description},
                    {QStringLiteral("canSignIn"), served && known && !busy && !active && !discovering && !externalSetup &&
                                                      setup.value(QLatin1String("canAuthenticate")).toBool(true) &&
                                                      provider.value(QLatin1String("enabled")).toBool() &&
                                                      provider.value(QLatin1String("installed")).toBool()},
                    {QStringLiteral("signInLabel"), signedIn ? QStringLiteral("Change account")
                                                    : phase == QLatin1String("failed") || phase == QLatin1String("cancelled")
                                                        ? QStringLiteral("Retry sign-in")
                                                        : QStringLiteral("Sign in")},
                    {QStringLiteral("canCancel"), served && !busy && active && !state.value(QLatin1String("flowId")).toString().isEmpty()},
                    {QStringLiteral("canSignOut"), served && known && !busy && !active && signedIn && canLogout},
                    {QStringLiteral("url"), active ? url : QString()},
                    {QStringLiteral("userCode"), interactionType == QLatin1String("deviceCode")
                                                     ? interaction.value(QLatin1String("userCode")).toString()
                                                     : QString()},
                    {QStringLiteral("error"), error},
                });
  return result;
}

// The provider health check row: the interval the node uses and its preset.
QVariant ProviderSettingsController::health() const {
  const std::optional<QJsonObject> settings = m_followed.isEmpty() ? std::nullopt : m_scope->settings(m_followed);
  if (!m_open || !settings) return null();
  const int seconds = healthSeconds(*settings);
  const int preset = presetHealthSeconds(baseProfile((*settings).value(QLatin1String("backgroundActivity")).toObject()));
  return QVariantMap{{QStringLiteral("seconds"), seconds}, {QStringLiteral("defaultSeconds"), preset}, {QStringLiteral("step"), 30}};
}

void ProviderSettingsController::publish() {
  if (!m_active) return;
  const QString local = m_client->environment();
  QStringList ids;
  for (const QString& environmentId : m_store->environments()) {
    if (environmentId == local || m_store->reaches(environmentId)) ids.append(environmentId);
  }
  ids.removeDuplicates();  // an environment several cluster nodes serve
  // This machine first, the others by name.
  std::sort(ids.begin(), ids.end(), [this, &local](const QString& a, const QString& b) {
    if ((a == local) != (b == local)) return a == local;
    return QString::localeAwareCompare(label(a).toLower(), label(b).toLower()) < 0;
  });
  QVariantList environments;
  for (const QString& id : std::as_const(ids)) {
    environments.append(QVariantMap{{QStringLiteral("id"), id},
                                    {QStringLiteral("label"), label(id)},
                                    {QStringLiteral("local"), id == local},
                                    {QStringLiteral("online"), m_store->environmentOnline(id)}});
  }
  const QString environmentId = chosen();
  QString status = QStringLiteral("ready");
  QString title;
  QString description;
  if (environmentId.isEmpty()) {
    status = QStringLiteral("none");
    title = QStringLiteral("No connected devices");
    description = QStringLiteral("Connect an execution environment before configuring providers.");
  } else if (!m_store->environmentOnline(environmentId)) {
    status = QStringLiteral("offline");
    title = QStringLiteral("Could not connect to this device");
    description = QStringLiteral("Reconnect this device to set up its provider, or select another device.");
  } else if (!m_providers) {
    status = QStringLiteral("loading");
    title = QStringLiteral("Loading provider settings");
    description = QStringLiteral("Waiting for %1's configuration.").arg(label(environmentId));
  } else if (m_providers->isEmpty()) {
    title = QStringLiteral("No providers");
    description = QStringLiteral("%1 reports no providers.").arg(label(environmentId));
  }
  QVariantList providers;
  if (m_open && m_providers && status == QLatin1String("ready")) {
    for (const QJsonValue& value : *m_providers) providers.append(entry(value.toObject()));
  }
  m_bridge->publish(kKey, QVariantMap{
                              {QStringLiteral("open"), m_open},
                              {QStringLiteral("environmentId"), environmentId},
                              {QStringLiteral("environments"), environments},
                              {QStringLiteral("status"), status},
                              {QStringLiteral("title"), title},
                              {QStringLiteral("description"), description},
                              {QStringLiteral("refreshing"), m_refreshing > 0},
                              {QStringLiteral("providers"), providers},
                              {QStringLiteral("health"), health()},
                          });
}
