// The auto-settle rules of Settings → General, across the settings scope
// (SettingsScopeController): each environment settles its own threads, so the
// rules are read from and written to the environments the scope names, as the
// web's general panel does.
//
// Publishes `autoSettle`: {sidebarAutoSettleOnMerge: {value: bool, mixed},
// sidebarAutoSettleAfterDays: {value: days, or null for never, mixed},
// offline: [label] (environments of the scope that are out of reach and keep
// their rules)}.
//
// Action: `autoSettle.set {key, value}`. A change that leaves an offline
// environment behind says which.

#include <QJsonObject>
#include <QVariantMap>

#include <algorithm>
#include <cmath>

#include "NativeController.h"
#include "NativeShell.h"
#include "SettingsScopeController.h"
#include "ShellBridge.h"
#include "ToastController.h"

class AutoSettleController : public QObject, public NativeController {
public:
  AutoSettleController(ShellBridge* bridge, McClient*, QObject* parent) : QObject(parent), m_bridge(bridge) {}

  void activate() override {
    if (m_active) return;
    m_active = true;
    connect(scope(), &SettingsScopeController::changed, this, &AutoSettleController::publish);
    publish();
  }

  bool handle(const QString& action, const QVariant& payload) override {
    if (!m_active || action != QLatin1String("autoSettle.set")) return false;
    const QVariantMap input = payload.toMap();
    const QString key = input.value(QStringLiteral("key")).toString();
    QJsonValue value = QJsonValue::fromVariant(input.value(QStringLiteral("value")));
    if (key == kAfterDays) {
      value = value.isDouble() ? QJsonValue(std::clamp(int(std::lround(value.toDouble())), 1, 90)) : QJsonValue(QJsonValue::Null);
    } else if (key == kOnMerge) {
      value = value.toBool();
    } else {
      return true;
    }
    scope()->write([key, value](QJsonObject settings, const QString&) {
      settings.insert(key, value);
      return settings;
    });
    const QStringList skipped = offline();
    if (!skipped.isEmpty()) {
      NativeShell::of(this)->controller<ToastController>()->show(
          QStringLiteral("warning"), QStringLiteral("Not updated: %1").arg(skipped.join(QStringLiteral(", "))),
          QStringLiteral("An offline environment keeps its auto-settle rules until it is changed while connected."));
    }
    return true;
  }

private:
  static inline const QString kOnMerge = QStringLiteral("sidebarAutoSettleOnMerge");
  static inline const QString kAfterDays = QStringLiteral("sidebarAutoSettleAfterDays");

  SettingsScopeController* scope() const { return NativeShell::of(this)->controller<SettingsScopeController>(); }

  // The scope's environments that are out of reach.
  QStringList offline() const {
    const QVariantMap state = m_bridge->state()->value(QStringLiteral("settingsScope")).toMap();
    const QString only = state.value(QStringLiteral("environmentId")).toString();
    QStringList labels;
    for (const QVariant& entry : state.value(QStringLiteral("environments")).toList()) {
      const QVariantMap environment = entry.toMap();
      if (environment.value(QStringLiteral("online")).toBool()) continue;
      if (only.isEmpty() || only == environment.value(QStringLiteral("id")).toString()) labels.append(environment.value(QStringLiteral("label")).toString());
    }
    return labels;
  }

  void publish() {
    if (!m_active) return;
    // The defaults of packages/contracts settings.ts: on merge, and after three days.
    const auto onMerge = scope()->read([](const QJsonObject& settings, const QString&) {
      const QJsonValue value = settings.value(kOnMerge);
      return QJsonValue(value.isBool() ? value.toBool() : true);
    });
    const auto afterDays = scope()->read([](const QJsonObject& settings, const QString&) {
      const QJsonValue value = settings.value(kAfterDays);
      return value.isUndefined() ? QJsonValue(3) : value;
    });
    const auto entry = [](const EnvironmentSettings::Reading& reading) {
      return QVariantMap{{QStringLiteral("value"), reading.value.isUndefined() ? QVariant::fromValue(nullptr) : reading.value.toVariant()},
                         {QStringLiteral("mixed"), reading.mixed}};
    };
    m_bridge->publish(QStringLiteral("autoSettle"),
                      QVariantMap{{kOnMerge, entry(onMerge)}, {kAfterDays, entry(afterDays)}, {QStringLiteral("offline"), offline()}});
  }

  ShellBridge* m_bridge;
  bool m_active = false;
};

namespace {
const NativeControllerRegistrar<AutoSettleController> registrar(QStringLiteral("autoSettle"), {QStringLiteral("autoSettle")});
}  // namespace
