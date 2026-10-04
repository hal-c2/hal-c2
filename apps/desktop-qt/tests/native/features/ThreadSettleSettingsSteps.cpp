// The auto-settle rules in Settings → General, per environment
// (features/threads/settle.feature): AutoSettleController over the settings
// scope, against the MC's settings documents (FakeConfig).

#include <QJsonObject>

#include "FakeConfig.h"
#include "Harness.h"
#include "NavigationController.h"
#include "SettingsScopeController.h"
#include "World.h"

namespace {

const QString kDays = QStringLiteral("sidebarAutoSettleAfterDays");
const QString kOnMerge = QStringLiteral("sidebarAutoSettleOnMerge");

struct SettleRules {
  QString key;
  QJsonValue value;
};

QVariantMap scope(World& world) {
  return world.state(QStringLiteral("settingsScope")).toMap();
}

QVariantMap rules(World& world) {
  return world.state(QStringLiteral("autoSettle")).toMap();
}

QJsonObject& documentFor(World& world, const QString& environment) {
  return environment.isEmpty() ? fakeConfig(world.mc).settings : documentOf(world.mc, environment).settings;
}

// Another environment the MC is linked to, settling after three days and not on merge.
void addEnvironment(World& world, const QString& name) {
  if (world.mc.linked.contains(name)) return;
  fakeConfig(world.mc).elsewhere.insert(name, fakeConfig(world.mc).elsewhere.value(name));
  documentOf(world.mc, name).settings.insert(kDays, 3);
  documentOf(world.mc, name).settings.insert(kOnMerge, false);
  world.mc.linkLabels.insert(name, name);
  world.mc.link(name);
}

// This machine settles after three days and not on merge, like the others.
void start(World& world) {
  if (world.shellSubscriptions() == 0) {
    world.connect();
    world.sync();
  }
  if (fakeConfig(world.mc).settings.contains(kOnMerge)) return;
  saveOn(world.mc, QString(), kDays, 3);
  saveOn(world.mc, QString(), kOnMerge, false);
  world.sync();
}

// Settings → General with the scope on `environment` ("" for all), ready on `targets` environments.
void open(World& world, const QString& environment, int targets) {
  world.native().controller<NavigationController>()->open(NavigationController::Route::settings(QStringLiteral("/settings/general")));
  QString id;
  if (!environment.isEmpty()) {
    world.waitFor([&] {
      for (const QVariant& row : scope(world).value(QStringLiteral("environments")).toList()) {
        if (row.toMap().value(QStringLiteral("label")) == environment) id = row.toMap().value(QStringLiteral("id")).toString();
      }
      return !id.isEmpty();
    }, [&] { return QStringLiteral("%1 to be offered; the scope is %2").arg(environment, show(scope(world))); });
  }
  world.bridge().dispatch(QStringLiteral("settingsScope.environment"), QVariantMap{{QStringLiteral("id"), id}});
  world.waitFor([&] {
    // Every environment's document has been read.
    auto* controller = world.native().controller<SettingsScopeController>();
    const int known = controller->read([](const QJsonObject& settings, const QString&) { return QJsonValue(settings); }).known;
    return scope(world).value(QStringLiteral("editable")).toBool() && controller->targets().size() == targets && known == targets;
  }, [&] { return QStringLiteral("the rules of %1 environments; the scope is %2, the rules %3").arg(targets).arg(show(scope(world)), show(rules(world))); });
}

void set(World& world, const QString& key, const QJsonValue& value) {
  world.mc.part<SettleRules>() = {key, value};
  world.bridge().dispatch(QStringLiteral("autoSettle.set"), QVariantMap{{QStringLiteral("key"), key}, {QStringLiteral("value"), value.toVariant()}});
  world.sync();
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("the user sets auto-settle to (after 7 days|never on inactivity|when the PR merges) for (the environment \"home\"|all environments)"),
       [](World& world, const Captures& c, const Table&) {
         start(world);
         for (const QString& name : {QStringLiteral("home"), QStringLiteral("work")}) addEnvironment(world, name);
         const bool all = c[1] == QLatin1String("all environments");
         open(world, all ? QString() : QStringLiteral("home"), all ? 3 : 1);
         if (c[0] == QLatin1String("after 7 days")) {
           set(world, kDays, 7);
         } else if (c[0] == QLatin1String("never on inactivity")) {
           set(world, kDays, QJsonValue(QJsonValue::Null));
         } else {
           set(world, kOnMerge, true);
         }
       });
  step(QStringLiteral("threads on (\"home\" only|every environment) follow the new rule"), [](World& world, const Captures& c, const Table&) {
    const SettleRules changed = world.mc.part<SettleRules>();
    const auto has = [&](const QString& environment) {
      const QJsonObject document = documentFor(world, environment);
      return document.contains(changed.key) && document.value(changed.key) == changed.value;
    };
    const bool everywhere = c[0] == QLatin1String("every environment");
    world.waitFor([&] { return has(QStringLiteral("home")); }, [&] {
      return QStringLiteral("home to take the rule; it has %1, the MC was asked %2 writes, the shell shows %3")
          .arg(show(documentFor(world, QStringLiteral("home")).toVariantMap())).arg(fakeConfig(world.mc).writes.size()).arg(show(world.state(QStringLiteral("toasts"))));
    });
    world.sync();
    expect(has(QStringLiteral("work")) == everywhere && has(QString()) == everywhere,
           QStringLiteral("work has %1, this machine %2").arg(show(documentFor(world, QStringLiteral("work")).toVariantMap()),
                                                           show(documentFor(world, QString()).toVariantMap())));
  });

  step(QStringLiteral("%1 settles after (\\d+) days and %1 settles after (\\d+) days").arg(q), [](World& world, const Captures& c, const Table&) {
    start(world);
    addEnvironment(world, c[0]);
    addEnvironment(world, c[2]);
    documentOf(world.mc, c[0]).settings.insert(kDays, c[1].toInt());
    documentOf(world.mc, c[2]).settings.insert(kDays, c[3].toInt());
  });
  step(QStringLiteral("the user looks at the auto-settle rules for all environments"), [](World& world, const Captures&, const Table&) { open(world, {}, 3); });
  step(QStringLiteral("the quiet spell is shown as mixed"), [](World& world, const Captures&, const Table&) {
    // SettingsRow.qml says "Mixed" for a rule whose environments differ.
    world.waitFor([&] { return rules(world).value(kDays).toMap().value(QStringLiteral("mixed")).toBool(); },
                  [&] { return QStringLiteral("a mixed quiet spell; the rules are %1").arg(show(rules(world))); });
    expect(!rules(world).value(kOnMerge).toMap().value(QStringLiteral("mixed")).toBool(), QStringLiteral("the rules are %1").arg(show(rules(world))));
  });

  step(QStringLiteral("the user changes the auto-settle rules for all environments"), [](World& world, const Captures&, const Table&) {
    start(world);
    addEnvironment(world, QStringLiteral("home"));
    // "work" is linked and out of reach: this machine and "home" take the change.
    open(world, {}, 2);
    set(world, kDays, 7);
  });
  step(QStringLiteral("%1 keeps its previous rules").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return documentFor(world, QStringLiteral("home")).value(kDays) == QJsonValue(7); }, QStringLiteral("home to take the rule"));
    world.sync();
    expect(!documentOf(world.mc, c[0]).settings.contains(kDays), QStringLiteral("%1 has %2").arg(c[0], show(documentOf(world.mc, c[0]).settings.toVariantMap())));
  });
  step(QStringLiteral("the user can see %1 was not updated").arg(q), [](World& world, const Captures& c, const Table&) {
    bool told = false;
    for (const QVariant& item : world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList()) {
      told |= item.toMap().value(QStringLiteral("title")) == QStringLiteral("Not updated: ") + c[0];
    }
    expect(told && rules(world).value(QStringLiteral("offline")).toStringList() == QStringList{c[0]},
           QStringLiteral("the shell shows %1, the rules %2").arg(show(world.state(QStringLiteral("toasts"))), show(rules(world))));
  });
});

}  // namespace
