// Settings → Integrations → Devices: the device hub and agent device access on the
// settings scope's environments (`device.configure` on each), and the device
// status of the scope's first connected environment, which says so when
// several are selected. That environment's DeviceServiceState is followed
// through the MC's `devices` shape when a cluster MC serves it, and read
// with `device.list` otherwise. At a project scope the hub is the
// environment's and only agent access changes, as the project's override.
// The built-in browser's defaults have no native page: the desktop has no
// embedded browser, and previews open in the user's own.
//
// Publishes `deviceSettings`: {open, projectScope, loaded, pending (hub |
// agent | check | update-hub | update-agent | retry, "" when idle), busy (the
// hub installing or starting), statusNote ("" unless several environments are
// selected), hub and agent: {on, mixed, enabled (whether it can be switched),
// version, status (what the switch is doing, or "" ), update ("Update to
// v<required>" when an update is offered, else "")}, canCheck, updateError:
// {tool, message} or null, platforms ([{platform, ready, message}] once the
// hub is ready, else empty), hosts: [{id, label, failed, message, canRetry}]
// (only hosts installing, starting or failed)}.
//
// Actions (`deviceSettings.`): `hub {enabled}` (turning it off turns agent
// access off too), `agent {enabled}`, `check` (tool versions, installing
// nothing), `refresh` (devices), `update {tool: hub | agent}`, `retry
// {hostId}`.

#include <QJsonArray>
#include <QJsonObject>
#include <QPointer>
#include <QVariantMap>

#include <algorithm>
#include <memory>

#include "NativeController.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "McClient.h"
#include "SettingsScopeController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ToastController.h"

namespace {

const QString kKey = QStringLiteral("deviceSettings");
const QString kSection = QStringLiteral("/settings/integrations");
const QString kHub = QStringLiteral("enableDeviceSupport");
const QString kAgent = QStringLiteral("enableAgentDeviceAccess");

QString platformName(const QString& platform) {
  return platform == QLatin1String("ios") ? QStringLiteral("iOS") : QStringLiteral("Android");
}

// DeviceToolVersions: the version running, else the required one when
// installed, else the newest installed.
QString versionLabel(const QJsonObject& tools, const QString& kind) {
  if (!tools.contains(kind)) return QStringLiteral("Version unknown");
  const QJsonObject tool = tools.value(kind).toObject();
  const QString running = tool.value(QLatin1String("runningVersion")).toString();
  if (!running.isEmpty()) return QLatin1Char('v') + running;
  QStringList installed;
  for (const QJsonValue& value : tool.value(QLatin1String("installedVersions")).toArray()) installed.append(value.toString());
  const QString required = tool.value(QLatin1String("requiredVersion")).toString();
  if (installed.contains(required)) return QLatin1Char('v') + required;
  if (installed.isEmpty()) return QStringLiteral("Not installed");
  std::sort(installed.begin(), installed.end(), [](const QString& a, const QString& b) {
    const QStringList left = a.split(QLatin1Char('.')), right = b.split(QLatin1Char('.'));
    for (qsizetype i = 0; i < std::min(left.size(), right.size()); ++i) {
      if (left[i].toInt() != right[i].toInt()) return left[i].toInt() < right[i].toInt();
    }
    return left.size() < right.size();
  });
  return QLatin1Char('v') + installed.last();
}

}  // namespace

class DeviceSettingsController : public QObject, public NativeController {
public:
  DeviceSettingsController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent)
      : QObject(parent), m_bridge(bridge), m_client(client), m_store(store) {}

  void activate() override {
    if (m_active) return;
    m_active = true;
    auto* navigation = NativeShell::of(this)->controller<NavigationController>();
    connect(navigation, &NavigationController::changed, this, [this, navigation] {
      const bool open = navigation->route().kind == QLatin1String("settings") && navigation->route().section == kSection;
      if (open == m_open) return;
      m_open = open;
      follow();
    });
    connect(scope(), &SettingsScopeController::changed, this, &DeviceSettingsController::follow);
    publish();
  }

  bool handle(const QString& action, const QVariant& payload) override {
    if (!m_active || !action.startsWith(kKey + QLatin1Char('.'))) return false;
    const QString name = action.mid(kKey.size() + 1);
    const QVariantMap input = payload.toMap();
    if (!m_open || !m_pending.isEmpty()) return true;
    const bool enabled = input.value(QStringLiteral("enabled")).toBool();
    if (name == QLatin1String("hub")) {
      if (scope()->projectScope() || busy()) return true;
      QJsonObject change{{QStringLiteral("enabled"), enabled}};
      if (enabled) change.insert(QStringLiteral("onboardingCompleted"), true);
      else change.insert(QStringLiteral("agentAccessEnabled"), false);
      configure(QStringLiteral("hub"), change);
    } else if (name == QLatin1String("agent")) {
      if (scope()->projectScope()) {
        scope()->write([enabled](QJsonObject settings, const QString& projectId) {
          return SettingsScopeController::withOverride(settings, projectId, kAgent, enabled);
        });
      } else {
        configure(QStringLiteral("agent"), {{QStringLiteral("agentAccessEnabled"), enabled}});
      }
    } else if (name == QLatin1String("check")) {
      list(QStringLiteral("check"), {{QStringLiteral("inspectOnly"), true}});
    } else if (name == QLatin1String("refresh")) {
      list(QStringLiteral("check"), {});
    } else if (name == QLatin1String("update")) {
      const QString tool = input.value(QStringLiteral("tool")).toString();
      if (tool != QLatin1String("hub") && tool != QLatin1String("agent")) return true;
      m_updateError = {};
      list(QStringLiteral("update-") + tool, {{QStringLiteral("updateTool"), tool}}, [this, tool] {
        m_updateError = {tool, QStringLiteral("Update failed. Check this host's network connection and try again.")};
      });
    } else if (name == QLatin1String("retry")) {
      list(QStringLiteral("retry"), {{QStringLiteral("retryHostId"), input.value(QStringLiteral("hostId")).toString()}});
    }
    return true;
  }

private:
  struct UpdateError {
    QString tool, message;
  };

  SettingsScopeController* scope() const { return NativeShell::of(this)->controller<SettingsScopeController>(); }

  // The environment whose device status shows: the scope's first connected one.
  QString inspected() const { return m_open ? scope()->targets().value(0) : QString(); }

  bool busy() const {
    const QString status = m_state.value(QLatin1String("hostStatus")).toString();
    return status == QLatin1String("installing") || status == QLatin1String("starting");
  }

  void follow() {
    const QString environmentId = inspected();
    if (environmentId != m_environmentId) {
      if (m_subscription >= 0) m_client->unsubscribe(m_subscription);
      m_subscription = -1;
      m_environmentId = environmentId;
      m_state = {};
      m_loaded = false;
      m_platformsShown = false;
      m_updateError = {};
      // A request in flight answers for the old environment: the switches are free again.
      m_pending.clear();
      ++m_generation;
      if (!environmentId.isEmpty()) {
        m_subscription = m_client->subscribe(
            this, {{QStringLiteral("type"), QStringLiteral("devices")}, {QStringLiteral("mc"), m_store->mcServing(environmentId)}},
            [this](const QJsonObject& frame) {
              if (frame.value(QLatin1String("t")) == QLatin1String("devices")) take(frame.value(QLatin1String("state")).toObject());
            });
      }
    }
    publish();
  }

  void take(const QJsonObject& state) {
    m_state = state;
    m_loaded = true;
    publish();
  }

  // `device.list` on the inspected environment; its answer is the new state.
  void list(const QString& pending, const QJsonObject& input, std::function<void()> failed = {}) {
    if (m_environmentId.isEmpty()) return;
    m_pending = pending;
    const QPointer<DeviceSettingsController> self(this);
    const int generation = m_generation;
    const int request = ++m_request;
    m_client->call(this, m_environmentId, QStringLiteral("device.list"), input,
                   [self, generation, request, failed](const QJsonValue& result, const std::optional<QString>& error) {
                     if (!self || self->m_generation != generation || self->m_request != request) return;
                     self->m_pending.clear();
                     if (error) {
                       if (failed) failed();
                     } else {
                       self->m_state = result.toObject();
                       self->m_loaded = true;
                     }
                     self->publish();
                   });
    publish();
  }

  // `device.configure` on every selected environment;
  // those that cannot be updated are named.
  void configure(const QString& pending, const QJsonObject& change) {
    const QStringList environments = scope()->environments();
    if (environments.isEmpty() || m_environmentId.isEmpty()) return;
    m_pending = pending;
    struct Round {
      int left = 0;
      QStringList failed;
    };
    auto round = std::make_shared<Round>();
    round->left = int(environments.size());
    const QPointer<DeviceSettingsController> self(this);
    const int request = ++m_request;
    const auto done = [self, round, environments, request](const QString& environmentId, bool ok) {
      if (!ok) round->failed.append(environmentId);
      if (--round->left > 0 || !self) return;
      // Only the latest request frees the switches (follow() already did for older ones).
      if (self->m_request == request) self->m_pending.clear();
      if (!round->failed.isEmpty()) {
        QStringList labels;
        for (const QString& id : environments) {
          if (round->failed.contains(id)) labels.append(self->scope()->label(id));
        }
        NativeShell::of(self)->controller<ToastController>()->error(QStringLiteral("Device settings not saved on all environments"),
                                                                    QStringLiteral("Could not update %1.").arg(labels.join(QStringLiteral(", "))));
      }
      self->publish();
    };
    const int generation = m_generation;
    for (const QString& environmentId : environments) {
      if (!scope()->online(environmentId)) {
        done(environmentId, false);
        continue;
      }
      m_client->call(this, environmentId, QStringLiteral("device.configure"), change,
                     [self, done, environmentId, generation](const QJsonValue& result, const std::optional<QString>& error) {
                       if (self && !error && environmentId == self->m_environmentId && generation == self->m_generation) {
                         self->m_state = result.toObject();
                         self->m_loaded = true;
                       }
                       done(environmentId, !error);
                     });
    }
    publish();
  }

  QVariantMap toggle(const QString& key, bool enabled, const QString& status, const QString& update) const {
    const auto reading = scope()->read([key](const QJsonObject& settings, const QString& projectId) {
      QJsonValue value = settings.value(key);
      if (!projectId.isEmpty()) {
        const QJsonValue own = SettingsScopeController::overrideOf(settings, projectId, key);
        if (!own.isUndefined()) value = own;
      }
      return QJsonValue(value.toBool());
    });
    return {{QStringLiteral("on"), reading.value.toBool()},
            {QStringLiteral("mixed"), reading.mixed},
            {QStringLiteral("enabled"), enabled && scope()->editable()},
            {QStringLiteral("status"), status},
            {QStringLiteral("update"), update}};
  }

  // The switch's progress while it is being changed (DeviceHubSetupStatus and
  // AgentDeviceSetupStatus, compact), or "".
  QString progress(const QString& pending) const {
    if (m_pending != pending) return {};
    const QString status = m_state.value(QLatin1String("hostStatus")).toString();
    if (status == QLatin1String("installing")) return QStringLiteral("Installing…");
    if (status == QLatin1String("starting")) return QStringLiteral("Starting…");
    return QStringLiteral("Updating…");
  }

  QJsonObject localHost() const {
    for (const QJsonValue& host : m_state.value(QLatin1String("hosts")).toArray()) {
      if (host.toObject().value(QLatin1String("kind")) == QLatin1String("local")) return host.toObject();
    }
    return {};
  }

  QString updateLabel(const QJsonObject& tools, const QString& kind) const {
    if (!m_state.value(QLatin1String("supportsToolUpdate")).toBool() || !tools.contains(kind)) return {};
    const QJsonObject tool = tools.value(kind).toObject();
    const QString required = tool.value(QLatin1String("requiredVersion")).toString();
    return tool.value(QLatin1String("installedVersions")).toArray().contains(required) ? QString() : QStringLiteral("Update to v%1").arg(required);
  }

  // platformSetupStatus.
  QVariantMap platform(const QString& platform) const {
    const QJsonArray hosts = m_state.value(QLatin1String("hosts")).toArray();
    QJsonObject availability;
    for (const QJsonValue& host : hosts) {
      for (const QJsonValue& entry : host.toObject().value(QLatin1String("platforms")).toArray()) {
        if (availability.isEmpty() && entry.toObject().value(QLatin1String("platform")) == platform) availability = entry.toObject();
      }
    }
    const QString name = platformName(platform);
    if (!availability.value(QLatin1String("available")).toBool()) {
      return {{QStringLiteral("platform"), name},
              {QStringLiteral("ready"), false},
              {QStringLiteral("message"), availability.value(QLatin1String("reason")).toString(QStringLiteral("%1 support was not detected.").arg(name))}};
    }
    const QJsonArray devices = m_state.value(QLatin1String("devices")).toArray();
    const bool any = std::any_of(devices.begin(), devices.end(), [&](const QJsonValue& device) {
      return device.toObject().value(QLatin1String("platform")) == platform;
    });
    if (m_state.value(QLatin1String("hostStatus")) == QLatin1String("ready") && !any) {
      return {{QStringLiteral("platform"), name},
              {QStringLiteral("ready"), false},
              {QStringLiteral("message"),
               platform == QLatin1String("ios")
                   ? QStringLiteral("Xcode is installed, but no iOS Simulator is available. Install a runtime in Xcode Settings → Components.")
                   : QStringLiteral("The Android SDK is installed, but no virtual device exists. Create one in Android Studio → Device Manager.")}};
    }
    return {{QStringLiteral("platform"), name},
            {QStringLiteral("ready"), true},
            {QStringLiteral("message"), platform == QLatin1String("ios") ? QStringLiteral("Xcode and iOS Simulator are available.")
                                                                          : QStringLiteral("The Android SDK and Emulator are available.")}};
  }

  // DeviceHostUpdates: the local host while its tools install, start or fail.
  QVariantList hosts() const {
    QVariantList rows;
    if (m_state.value(QLatin1String("hostStatus")) == QLatin1String("disabled")) return rows;
    const QJsonObject statuses = m_state.value(QLatin1String("hostStatuses")).toObject();
    const QJsonObject host = localHost();
    const QString id = host.value(QLatin1String("id")).toString();
    const QJsonObject status = statuses.value(id).toObject();
    const QString value = status.value(QLatin1String("status")).toString();
    if (host.isEmpty() || (value != QLatin1String("installing") && value != QLatin1String("starting") && value != QLatin1String("failed"))) return rows;
    const bool failed = value == QLatin1String("failed");
    const QString fallback = failed ? QStringLiteral("Device support could not start.")
                             : value == QLatin1String("installing") ? QStringLiteral("Installing device tools…")
                                                                    : QStringLiteral("Starting device tools…");
    rows.append(QVariantMap{{QStringLiteral("id"), id},
                            {QStringLiteral("label"), host.value(QLatin1String("label")).toString()},
                            {QStringLiteral("failed"), failed},
                            {QStringLiteral("message"), status.value(QLatin1String("detail")).toString(fallback)},
                            {QStringLiteral("canRetry"), failed && m_state.value(QLatin1String("supportsHostRetry")).toBool()}});
    return rows;
  }

  void publish() {
    if (!m_active) return;
    if (!m_open) {
      m_bridge->publish(kKey, QVariantMap{{QStringLiteral("open"), false}});
      return;
    }
    SettingsScopeController* scope = this->scope();
    const bool project = scope->projectScope();
    const bool hubOn = scope->read([](const QJsonObject& settings, const QString&) { return QJsonValue(settings.value(kHub).toBool()); }).value.toBool();
    // Diagnostics stay once the hub was ready, through later agent setup.
    if (!hubOn) m_platformsShown = false;
    else if (m_state.value(QLatin1String("hostStatus")) == QLatin1String("ready") && m_pending != QLatin1String("hub")) m_platformsShown = true;
    const QStringList targets = scope->targets();
    const bool anyHub = std::any_of(targets.begin(), targets.end(),
                                    [scope](const QString& id) { return scope->settings(id).value_or(QJsonObject()).value(kHub).toBool(); });
    const bool idle = m_pending.isEmpty();
    const bool connected = !m_environmentId.isEmpty();
    const QJsonObject tools = localHost().value(QLatin1String("tools")).toObject();

    QVariantMap hub = toggle(kHub, !project && m_loaded && connected && !busy() && idle, progress(QStringLiteral("hub")), updateLabel(tools, QStringLiteral("hub")));
    hub.insert(QStringLiteral("version"), versionLabel(tools, QStringLiteral("hub")));
    QVariantMap agent = toggle(kAgent, !targets.isEmpty() && (project || (m_loaded && anyHub && !busy())) && idle, progress(QStringLiteral("agent")),
                               updateLabel(tools, QStringLiteral("agent")));
    agent.insert(QStringLiteral("version"), versionLabel(tools, QStringLiteral("agent")));

    QVariantList platforms;
    if (m_platformsShown) platforms = {platform(QStringLiteral("ios")), platform(QStringLiteral("android"))};

    m_bridge->publish(
        kKey, QVariantMap{
                  {QStringLiteral("open"), true},
                  {QStringLiteral("projectScope"), project},
                  {QStringLiteral("loaded"), m_loaded},
                  {QStringLiteral("pending"), m_pending},
                  {QStringLiteral("busy"), busy()},
                  {QStringLiteral("statusNote"),
                   targets.size() > 1 ? QStringLiteral("Status for %1. Select an environment to inspect its simulator support.").arg(scope->label(m_environmentId))
                                      : QString()},
                  {QStringLiteral("hub"), hub},
                  {QStringLiteral("agent"), agent},
                  {QStringLiteral("canCheck"), connected && m_state.value(QLatin1String("supportsToolInspection")).toBool()},
                  {QStringLiteral("updateError"), m_updateError.tool.isEmpty() ? QVariant::fromValue(nullptr)
                                                                               : QVariant(QVariantMap{{QStringLiteral("tool"), m_updateError.tool},
                                                                                                      {QStringLiteral("message"), m_updateError.message}})},
                  {QStringLiteral("platforms"), platforms},
                  {QStringLiteral("hosts"), hosts()},
              });
  }

  ShellBridge* m_bridge;
  McClient* m_client;
  ShellStore* m_store;
  bool m_active = false;
  bool m_open = false;
  QString m_environmentId;
  int m_subscription = -1;
  // Bumped when the inspected environment changes, so older answers are dropped.
  int m_generation = 0;
  int m_request = 0;
  QJsonObject m_state;
  bool m_loaded = false;
  bool m_platformsShown = false;
  QString m_pending;
  UpdateError m_updateError;
};

namespace {
const NativeControllerRegistrar<DeviceSettingsController> registrar(QStringLiteral("deviceSettings"), {kKey});
}  // namespace
