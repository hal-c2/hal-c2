// Settings → Connections' "Load balancing" group: whether new threads start on the machine
// with the most room, and how often each machine of the cluster gets them. Both are in
// the settings document of the MC this shell is connected to
// (`loadBalancingEnabled`, and `loadBalancingWeights` by environment id),
// because that MC is the one that chooses (HalC2.LoadBalancing, which
// ComposerController asks with `hal-c2.placeThread`).
//
// Publishes `loadBalancing`: null while the cluster has one machine (there is
// nothing to balance against), else {ready (the settings are read), enabled,
// summary (what the folded group says: "Off", or the machines not at Normal),
// preferences [{weight, label}], machines [{environmentId, label, weight}]},
// this machine first and the others by name. A machine's `weight` is the
// preference it shows as: one of `preferences`, whatever was saved.
//
// Actions: `loadBalancing.enable {enabled}` (the preferences stay as they
// are) and `loadBalancing.prefer {environmentId, weight}` (one of
// `preferences`).

#include <QJsonObject>
#include <QPointer>
#include <QVariantMap>

#include <algorithm>

#include "McClient.h"
#include "NativeController.h"
#include "NativeShell.h"
#include "SettingsController.h"
#include "SettingsScopeController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ToastController.h"

class LoadBalancingController : public QObject, public NativeController {
public:
  LoadBalancingController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent)
      : QObject(parent), m_bridge(bridge), m_client(client), m_store(store) {}

  void activate() override {
    if (m_active) return;
    m_active = true;
    connect(m_store, &ShellStore::changed, this, &LoadBalancingController::publish);
    connect(settings(), &SettingsController::settingsChanged, this, &LoadBalancingController::publish);
    publish();
  }

  bool handle(const QString& action, const QVariant& payload) override {
    if (!m_active || !action.startsWith(QLatin1String("loadBalancing."))) return false;
    const QVariantMap input = payload.toMap();
    if (action == QLatin1String("loadBalancing.enable")) {
      const bool enabled = input.value(QStringLiteral("enabled")).toBool();
      save([enabled](QJsonObject document) {
        document.insert(QStringLiteral("loadBalancingEnabled"), enabled);
        return document;
      });
    } else if (action == QLatin1String("loadBalancing.prefer")) {
      const QString environmentId = input.value(QStringLiteral("environmentId")).toString();
      const int weight = input.value(QStringLiteral("weight")).toInt();
      const bool offered = std::any_of(preferences().cbegin(), preferences().cend(),
                                       [weight](const Preference& preference) { return preference.weight == weight; });
      if (environmentId.isEmpty() || !offered) return true;
      save([environmentId, weight](QJsonObject document) {
        QJsonObject weights = document.value(QLatin1String("loadBalancingWeights")).toObject();
        weights.insert(environmentId, weight);
        document.insert(QStringLiteral("loadBalancingWeights"), weights);
        return document;
      });
    }
    return true;
  }

private:
  // How often a machine gets new threads, as the MC's weight for it.
  struct Preference {
    int weight;
    QString label;
  };

  static const QList<Preference>& preferences() {
    static const QList<Preference> list{
        {100, QStringLiteral("Prefer")},
        {50, QStringLiteral("Normal")},
        {25, QStringLiteral("Less often")},
        {0, QStringLiteral("Manual only")},
    };
    return list;
  }

  // The preference a saved weight shows as. A machine with none is at Normal;
  // a weight from an older build, which stored a slider's value, snaps to the
  // choice on its side of Normal, and only 0 is Manual only: any other weight
  // still gets threads.
  static const Preference& preferenceFor(const QJsonValue& saved) {
    const auto at = [](int weight) -> const Preference& {
      return *std::find_if(preferences().cbegin(), preferences().cend(),
                           [weight](const Preference& preference) { return preference.weight == weight; });
    };
    if (!saved.isDouble() || saved.toDouble() == 50) return at(50);
    if (saved.toDouble() == 0) return at(0);
    return at(saved.toDouble() < 50 ? 25 : 100);
  }

  SettingsController* settings() const { return NativeShell::of(this)->controller<SettingsController>(); }

  void save(SettingsController::Edit edit) {
    settings()->change(std::move(edit), [window = QPointer<NativeWindow>(NativeShell::of(this))](const std::optional<QString>& error) {
      if (error && window) {
        window->controller<ToastController>()->show(QStringLiteral("error"), QStringLiteral("Setting not saved"), *error);
      }
    });
  }

  void publish() {
    if (!m_active) return;
    auto* scope = NativeShell::of(this)->controller<SettingsScopeController>();
    const QString local = m_client->environment();
    QStringList machines = m_store->environments();
    machines.removeDuplicates();
    if (machines.size() < 2) {
      m_bridge->publish(QStringLiteral("loadBalancing"), QVariant::fromValue(nullptr));
      return;
    }
    std::sort(machines.begin(), machines.end(), [&](const QString& a, const QString& b) {
      if ((a == local) != (b == local)) return a == local;
      return QString::localeAwareCompare(scope->label(a).toLower(), scope->label(b).toLower()) < 0;
    });
    const QJsonObject document = settings()->settings();
    const bool enabled = document.value(QLatin1String("loadBalancingEnabled")).toBool();
    const QJsonObject weights = document.value(QLatin1String("loadBalancingWeights")).toObject();
    QVariantList rows;
    QStringList changed;
    for (const QString& environmentId : std::as_const(machines)) {
      const Preference& preference = preferenceFor(weights.value(environmentId));
      const QString label = scope->label(environmentId);
      rows.append(QVariantMap{{QStringLiteral("environmentId"), environmentId},
                              {QStringLiteral("label"), label},
                              {QStringLiteral("weight"), preference.weight}});
      if (preference.weight != 50) changed.append(label + QLatin1Char(' ') + preference.label.toLower());
    }
    QVariantList offered;
    for (const Preference& preference : preferences()) {
      offered.append(QVariantMap{{QStringLiteral("weight"), preference.weight}, {QStringLiteral("label"), preference.label}});
    }
    m_bridge->publish(QStringLiteral("loadBalancing"),
                      QVariantMap{{QStringLiteral("ready"), settings()->ready()},
                                  {QStringLiteral("enabled"), enabled},
                                  {QStringLiteral("summary"), enabled ? changed.join(QStringLiteral(" · ")) : QStringLiteral("Off")},
                                  {QStringLiteral("preferences"), offered},
                                  {QStringLiteral("machines"), rows}});
  }

  ShellBridge* m_bridge;
  McClient* m_client;
  ShellStore* m_store;
  bool m_active = false;
};

namespace {
const NativeControllerRegistrar<LoadBalancingController> registrar(QStringLiteral("loadBalancing"), {QStringLiteral("loadBalancing")});
}  // namespace
