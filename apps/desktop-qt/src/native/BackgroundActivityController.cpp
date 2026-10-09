// Settings → General, Background activity (the web's background activity row
// and its Advanced dialog): the profile the selected environments' MCs gate
// their background work by (`backgroundActivity`, HalC2.BackgroundPolicy), and
// with Advanced chosen the Git fetch interval and whether work pauses while
// the host is locked, kept as a custom profile's overrides on the profile it
// started from. Environment-wide: a project has none of its own.
//
// Publishes `backgroundActivity`: {open, profile (balanced | performance |
// battery-saver | custom), mixed, advanced (profile is custom),
// fetchSeconds, pauseWhenLocked, profiles: [{value, label}]}.
//
// Actions: `backgroundActivity.profile {value}` (custom keeps the current
// profile as its base), `backgroundActivity.set {fetchSeconds?,
// pauseWhenLocked?}` (a custom profile's overrides).

#include <QJsonObject>
#include <QObject>

#include <algorithm>
#include <cmath>

#include "JsonNumbers.h"
#include "NativeController.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "SettingsScopeController.h"
#include "ShellBridge.h"

namespace {

const QString kKey = QStringLiteral("backgroundActivity");
const QString kFetch = QStringLiteral("automaticGitFetchInterval");
const QString kLocked = QStringLiteral("pauseWhenHostLocked");
const QString kCustom = QStringLiteral("custom");

struct Profile {
  const char* value;
  const char* label;
  int fetchSeconds;  // HalC2.BackgroundPolicy's presets
};
const Profile kProfiles[] = {{"balanced", "Balanced", 30}, {"performance", "Performance", 15}, {"battery-saver", "Battery saver", 0}};

QString baseOf(const QJsonObject& activity) {
  const QString profile = activity.value(QLatin1String("profile")).toString();
  const QString base = profile == kCustom ? activity.value(QLatin1String("baseProfile")).toString() : profile;
  return base == QLatin1String("performance") || base == QLatin1String("battery-saver") ? base : QStringLiteral("balanced");
}

int presetFetch(const QString& profile) {
  for (const Profile& entry : kProfiles) {
    if (profile == QLatin1String(entry.value)) return entry.fetchSeconds;
  }
  return 30;
}

class BackgroundActivityController : public QObject, public NativeController {
public:
  BackgroundActivityController(ShellBridge* bridge, McClient*, QObject* parent) : QObject(parent), m_bridge(bridge) {}

  void activate() override {
    if (m_active) return;
    m_active = true;
    auto* navigation = NativeShell::of(this)->controller<NavigationController>();
    const auto follow = [this, navigation] {
      const NavigationController::Route& route = navigation->route();
      m_open = route.kind == QLatin1String("settings") &&
               (route.section.isEmpty() || route.section == QLatin1String("/settings") || route.section == QLatin1String("/settings/general"));
      publish();
    };
    connect(navigation, &NavigationController::changed, this, follow);
    connect(scope(), &SettingsScopeController::changed, this, &BackgroundActivityController::publish);
    follow();
  }

  bool handle(const QString& action, const QVariant& payload) override {
    if (!m_active || !action.startsWith(QLatin1String("backgroundActivity."))) return false;
    const QVariantMap input = payload.toMap();
    if (action == QLatin1String("backgroundActivity.profile")) {
      const QString value = input.value(QStringLiteral("value")).toString();
      const bool preset = std::any_of(std::begin(kProfiles), std::end(kProfiles), [&value](const Profile& entry) { return value == QLatin1String(entry.value); });
      if (!preset && value != kCustom) return true;
      write([value](const QJsonObject& activity) {
        if (value != kCustom) return QJsonObject{{QStringLiteral("schemaVersion"), 1}, {QStringLiteral("profile"), value}, {QStringLiteral("overrides"), QJsonObject()}};
        // Advanced starts from the profile it was on, with nothing changed yet.
        return QJsonObject{{QStringLiteral("schemaVersion"), 1},
                           {QStringLiteral("profile"), kCustom},
                           {QStringLiteral("baseProfile"), baseOf(activity)},
                           {QStringLiteral("overrides"), activity.value(QLatin1String("profile")) == kCustom ? activity.value(QLatin1String("overrides")).toObject() : QJsonObject()}};
      });
    } else if (action == QLatin1String("backgroundActivity.set")) {
      write([input](const QJsonObject& activity) {
        QJsonObject overrides = activity.value(QLatin1String("profile")) == kCustom ? activity.value(QLatin1String("overrides")).toObject() : QJsonObject();
        if (input.contains(QStringLiteral("fetchSeconds"))) {
          overrides.insert(kFetch, qint64(std::clamp(input.value(QStringLiteral("fetchSeconds")).toInt(), 0, 86400)) * 1000);
        }
        if (input.contains(QStringLiteral("pauseWhenLocked"))) overrides.insert(kLocked, input.value(QStringLiteral("pauseWhenLocked")).toBool());
        return QJsonObject{{QStringLiteral("schemaVersion"), 1}, {QStringLiteral("profile"), kCustom}, {QStringLiteral("baseProfile"), baseOf(activity)},
                           {QStringLiteral("overrides"), overrides}};
      });
    }
    return true;
  }

private:
  SettingsScopeController* scope() const { return NativeShell::of(this)->controller<SettingsScopeController>(); }

  void write(const std::function<QJsonObject(const QJsonObject& activity)>& edit) {
    scope()->write([edit](QJsonObject settings, const QString&) {
      settings.insert(kKey, edit(settings.value(kKey).toObject()));
      return settings;
    });
  }

  void publish() {
    if (!m_active) return;
    if (!m_open) {
      m_bridge->publish(kKey, QVariantMap{{QStringLiteral("open"), false}});
      return;
    }
    const auto reading = scope()->read([](const QJsonObject& settings, const QString&) { return QJsonValue(settings.value(kKey).toObject()); });
    const QJsonObject activity = reading.value.toObject();
    const QString profile = activity.value(QLatin1String("profile")).toString(QStringLiteral("balanced"));
    const bool custom = profile == kCustom;
    const QJsonObject overrides = custom ? activity.value(QLatin1String("overrides")).toObject() : QJsonObject();
    QVariantList profiles;
    for (const Profile& entry : kProfiles) {
      profiles.append(QVariantMap{{QStringLiteral("value"), QString::fromLatin1(entry.value)}, {QStringLiteral("label"), QString::fromLatin1(entry.label)}});
    }
    profiles.append(QVariantMap{{QStringLiteral("value"), kCustom}, {QStringLiteral("label"), QStringLiteral("Advanced")}});
    m_bridge->publish(kKey, QVariantMap{{QStringLiteral("open"), true},
                                        {QStringLiteral("profile"), profile},
                                        {QStringLiteral("mixed"), reading.mixed},
                                        {QStringLiteral("advanced"), custom && !reading.mixed},
                                        {QStringLiteral("fetchSeconds"), overrides.value(kFetch).isDouble() ? jsonnumbers::saturate<int>(std::round(overrides.value(kFetch).toDouble() / 1000))
                                                                                                         : presetFetch(baseOf(activity))},
                                        // Every preset pauses while the host is locked.
                                        {QStringLiteral("pauseWhenLocked"), overrides.value(kLocked).toBool(true)},
                                        {QStringLiteral("profiles"), profiles}});
  }

  ShellBridge* m_bridge;
  bool m_active = false;
  bool m_open = false;
};

const NativeControllerRegistrar<BackgroundActivityController> registrar(QStringLiteral("backgroundActivity"), {kKey});

}  // namespace
