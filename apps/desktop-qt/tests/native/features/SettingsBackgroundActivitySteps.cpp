// Settings → General's background activity (BackgroundActivityController,
// features/settings/background-service.feature): the custom profile the MC is
// handed, which HalC2.BackgroundPolicy gates its Git fetches by.

#include <QJsonObject>
#include <QQuickItem>
#include <QTest>

#include "Brick.h"
#include "FakeConfig.h"
#include "Harness.h"
#include "SettingsRows.h"
#include "SettingsScopeController.h"
#include "World.h"

namespace {

const QString kRow = QStringLiteral("settingsRow:background-activity");

QJsonObject activity(World& world) {
  return fakeConfig(world.mc).settings.value(QLatin1String("backgroundActivity")).toObject();
}

QString describe(World& world) {
  return QStringLiteral("the MC holds %1; the row is %2").arg(show(activity(world).toVariantMap()), show(world.state(QStringLiteral("backgroundActivity"))));
}

const Steps steps([] {
  step(QStringLiteral("the user chooses advanced background activity for the environment"), [](World& world, const Captures&, const Table&) {
    if (world.shellSubscriptions() == 0) {
      world.connect();
      world.sync();
    }
    world.bridge().dispatch(QStringLiteral("settings.navigate"), QVariantMap{{QStringLiteral("to"), QStringLiteral("/settings/general")}});
    world.waitFor([&] { return world.state(QStringLiteral("backgroundActivity")).toMap().value(QStringLiteral("open")).toBool() &&
                               world.state(QStringLiteral("settingsScope")).toMap().value(QStringLiteral("editable")).toBool() &&
                               world.native().controller<SettingsScopeController>()->settings(world.mc.environmentId).has_value(); },
                  [&] { return describe(world); });
    QQuickItem* control = pageItem(world, kRow, QStringLiteral("control"));
    expect(control->property("displayText") == QLatin1String("Balanced"), QStringLiteral("the row reads \"%1\"").arg(control->property("displayText").toString()));
    // Advanced, the last of the list.
    QMetaObject::invokeMethod(control, "activated", Q_ARG(int, 3));
    world.waitFor([&] { return activity(world).value(QLatin1String("profile")) == QLatin1String("custom") && activity(world).value(QLatin1String("baseProfile")) == QLatin1String("balanced"); },
                  [&] { return describe(world); });
  });
  step(QStringLiteral("the user sets git fetch to every 2 minutes and turns off pausing when locked"), [](World& world, const Captures&, const Table&) {
    Brick& page = generalPage(world);
    QQuickItem* seconds = pageItem(world, kRow, QStringLiteral("fetchSeconds"));
    world.waitFor([&] { return seconds->isVisible(); }, [&] { return describe(world); });
    expect(seconds->property("value").toInt() == 30, QStringLiteral("the interval starts at %1").arg(seconds->property("value").toInt()));
    // Typed into the field, as the user does.
    seconds->setProperty("value", 120);
    QMetaObject::invokeMethod(seconds, "valueModified");
    QQuickItem* locked = pageItem(world, kRow, QStringLiteral("pauseWhenLocked"));
    expect(locked->property("checked").toBool(), QStringLiteral("pausing when locked starts off"));
    QTest::mouseClick(&page.window(), Qt::LeftButton, Qt::NoModifier, page.at(locked));
  });
  step(QStringLiteral("the MC fetches git every 2 minutes, even when locked"), [](World& world, const Captures&, const Table&) {
    // What HalC2.BackgroundPolicy reads: a custom profile's overrides over its base.
    world.waitFor([&] {
      const QJsonObject overrides = activity(world).value(QLatin1String("overrides")).toObject();
      return activity(world).value(QLatin1String("profile")) == QLatin1String("custom") &&
             overrides.value(QLatin1String("automaticGitFetchInterval")) == QJsonValue(120000) &&
             overrides.value(QLatin1String("pauseWhenHostLocked")) == QJsonValue(false);
    }, [&] { return describe(world); });
    expect(activity(world).value(QLatin1String("baseProfile")) == QLatin1String("balanced") && activity(world).value(QLatin1String("overrides")).toObject().size() == 2, describe(world));
  });
});

}  // namespace
