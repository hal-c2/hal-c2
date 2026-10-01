// The native settings pages' rows, driven as the rows drive SettingsController:
// setting, resetting and reading a row's value, wherever the row keeps it
// (features/settings/general.feature, navigation/appearance.feature).

#include <QMap>

#include "FakeConfig.h"
#include "Harness.h"
#include "SettingsController.h"
#include "World.h"

namespace {

SettingsController* settings(World& world) {
  return world.native().controller<SettingsController>();
}

// The rows the scenarios name, and a value off each one's default.
struct Row {
  QString key;
  QVariant changed;
};

const QMap<QString, Row>& rows() {
  static const QMap<QString, Row> map{
      {QStringLiteral("project grouping"), {QStringLiteral("sidebarProjectGroupingMode"), QStringLiteral("separate")}},
      {QStringLiteral("auto-settle on merge"), {QStringLiteral("sidebarAutoSettleOnMerge"), false}},
      {QStringLiteral("contrast"), {QStringLiteral("appearanceContrast"), 120}},
      {QStringLiteral("glass opacity"), {QStringLiteral("glassOpacity"), 60}},
      {QStringLiteral("environment identification"), {QStringLiteral("environmentIdentificationMode"), QStringLiteral("pill")}},
      {QStringLiteral("diff colors"), {QStringLiteral("diffColorScheme"), QStringLiteral("blue-orange")}},
      {QStringLiteral("composer context"), {QStringLiteral("persistComposerContextStrip"), true}},
      {QStringLiteral("panel animations"), {QStringLiteral("panelAnimationDurationMs"), 200}},
      {QStringLiteral("font smoothing"), {QStringLiteral("fontSmoothing"), false}},
      {QStringLiteral("word wrapping"), {QStringLiteral("wordWrap"), false}},
      {QStringLiteral("the interface font"), {QStringLiteral("fontFamilySans"), QString()}},
  };
  return map;
}

const QString kRows = QStringLiteral("(project grouping|auto-settle on merge|contrast|glass opacity|environment identification|"
                                     "diff colors|composer context|panel animations|font smoothing|word wrapping|the interface font)");

const QString kSettleDays = QStringLiteral("sidebarAutoSettleAfterDays");

QString describe(World& world, const QString& key) {
  return QStringLiteral("%1 is %2 (default %3); the MC holds %4")
      .arg(key, show(settings(world)->setting(key)), show(settings(world)->defaultOf(key)),
           show(fakeConfig(world.mc).settings.toVariantMap()));
}

void ready(World& world) {
  if (settings(world)->ready()) return;
  if (world.mc.connections.isEmpty()) world.connect();
  world.waitFor([&world] { return settings(world)->ready(); }, QStringLiteral("the shell to read the MC's settings"));
}

// Sets a row as its control does, and waits for the store that keeps it.
void set(World& world, const QString& key, const QVariant& value) {
  settings(world)->set(key, value);
  world.waitFor([&] { return settings(world)->setting(key) == value; }, [&] { return describe(world, key); });
  if (!settings(world)->onDevice(key)) {
    // The MC stores a default as its absence, and null as null.
    world.waitFor([&] {
      const QJsonObject& mc = fakeConfig(world.mc).settings;
      return settings(world)->isDefault(key) ? !mc.contains(key) || mc.value(key).toVariant() == value
                                             : mc.value(key).toVariant() == value;
    }, [&] { return describe(world, key); });
  }
}

void openSection(World& world, const QString& section) {
  ready(world);
  world.bridge().dispatch(QStringLiteral("settings.open"), {});
  world.bridge().dispatch(QStringLiteral("settings.navigate"), QVariantMap{{QStringLiteral("to"), section}});
  world.waitFor([&] { return at(world.state(QStringLiteral("route")), QStringLiteral("section")) == section; },
                [&] { return QStringLiteral("the route is %1").arg(show(world.state(QStringLiteral("route")))); });
}

void atDefault(World& world, const QString& key) {
  world.sync();
  expect(settings(world)->isDefault(key) && settings(world)->setting(key) == settings(world)->defaultOf(key), describe(world, key));
  if (settings(world)->onDevice(key)) {
    expect(!settings(world)->deviceSettings().contains(key), QStringLiteral("this device holds %1").arg(show(settings(world)->deviceSettings().toVariantMap())));
  }
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("the user has opened the General settings"), [](World& world, const Captures&, const Table&) {
    openSection(world, QStringLiteral("/settings/general"));
  });
  step(QStringLiteral("the user is in Settings → Appearance"), [](World& world, const Captures&, const Table&) {
    openSection(world, QStringLiteral("/settings/appearance"));
  });

  // Any row.
  step(QStringLiteral("the user (?:turned|changed) %1(?: off)?").arg(kRows), [](World& world, const Captures& c, const Table&) {
    const Row row = rows().value(c[0]);
    world.settingRow = row.key;
    set(world, row.key, row.changed);
    expect(!settings(world)->isDefault(row.key), describe(world, row.key));
  });
  step(QStringLiteral("the user set the interface font to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.settingRow = QStringLiteral("fontFamilySans");
    set(world, world.settingRow, c[0]);
  });
  step(QStringLiteral("the user resets %1").arg(kRows), [](World& world, const Captures& c, const Table&) {
    const QString key = rows().value(c[0]).key;
    settings(world)->reset(key);
    world.waitFor([&] { return settings(world)->isDefault(key); }, [&] { return describe(world, key); });
  });
  step(QStringLiteral("%1 is (?:back )?(?:at|to) its default").arg(kRows), [](World& world, const Captures& c, const Table&) {
    const QString key = rows().value(c[0]).key;
    world.settingRow = key;
    ready(world);
    atDefault(world, key);
  });
  step(QStringLiteral("the interface uses the system default font"), [](World& world, const Captures&, const Table&) {
    atDefault(world, QStringLiteral("fontFamilySans"));
    expect(settings(world)->setting(QStringLiteral("fontFamilySans")) == QString(), describe(world, QStringLiteral("fontFamilySans")));
  });
  step(QStringLiteral("the row (?:no longer offers a|offers no) reset"), [](World& world, const Captures&, const Table&) {
    expect(settings(world)->isDefault(world.settingRow), describe(world, world.settingRow));
  });

  // Inactive settling: a switch over the days, null being off.
  step(QStringLiteral("\"Auto-settle inactive threads\" is off"), [](World& world, const Captures&, const Table&) {
    set(world, kSettleDays, QVariant::fromValue(nullptr));
  });
  step(QStringLiteral("the user turns it on"), [](World& world, const Captures&, const Table&) {
    // What the row's switch does (js/settingsRows.js settleFromToggle).
    set(world, kSettleDays, settings(world)->defaultOf(kSettleDays));
  });
  step(QStringLiteral("the number of days before settling is shown with its default"), [](World& world, const Captures&, const Table&) {
    expect(settings(world)->setting(kSettleDays) == settings(world)->defaultOf(kSettleDays) &&
               settings(world)->defaultOf(kSettleDays) == QVariant(3),
           describe(world, kSettleDays));
  });
  step(QStringLiteral("the user can change the number of days"), [](World& world, const Captures&, const Table&) {
    set(world, kSettleDays, 7);
  });
});

}  // namespace
