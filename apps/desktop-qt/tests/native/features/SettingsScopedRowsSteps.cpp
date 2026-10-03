// Settings → General's rows of the MC across the settings scope: rows an
// environment cannot honour, and values the environments disagree on
// (features/settings/general.feature).

#include <QJsonObject>
#include <QQuickItem>

#include "Brick.h"
#include "FakeConfig.h"
#include "Harness.h"
#include "SettingsController.h"
#include "SettingsRows.h"
#include "SettingsScopeController.h"
#include "World.h"

namespace {

const QString kOther = QStringLiteral("Build box");
const QString kSettles = QStringLiteral("threadAutoSettlement");
const QString kContinues = QStringLiteral("threadRestartContinuation");
const QString kStreaming = QStringLiteral("responseStreamingMode");
const QString kContinue = QStringLiteral("continueThreadsAfterServerUpdate");

QJsonObject withCapabilities(QJsonObject config, const QJsonObject& capabilities) {
  QJsonObject environment = config.value(QLatin1String("environment")).toObject();
  environment.insert(QStringLiteral("capabilities"), capabilities);
  config.insert(QStringLiteral("environment"), environment);
  return config;
}

SettingsScopeController* scope(World& world) {
  return world.native().controller<SettingsScopeController>();
}

// This machine's MC says what it can do, as its `config` snapshot does.
void announceHere(World& world, const QJsonObject& capabilities) {
  FakeConfig& fake = fakeConfig(world.mc);
  fake.config = withCapabilities(fake.config, capabilities);
  QJsonObject config = fake.config;
  config.insert(QStringLiteral("settings"), fake.settings);
  for (const int id : world.mc.subscribers(QStringLiteral("config"))) {
    if (world.mc.shapeOf(id).value(QLatin1String("environment")) != world.mc.environmentId) continue;
    world.mc.send({{QStringLiteral("t"), QStringLiteral("config")}, {QStringLiteral("id"), id}, {QStringLiteral("mc"), world.mc.name}, {QStringLiteral("config"), config}});
  }
  world.sync();
}

// Another machine the MC is linked to, with its own settings: in the scope
// once its settings arrive.
void linkOther(World& world, const QJsonObject& capabilities, const QJsonObject& settings = {}) {
  FakeConfig& fake = fakeConfig(world.mc);
  fake.elsewhere.insert(kOther, withCapabilities({}, capabilities));
  documentOf(world.mc, kOther).settings = settings;
  world.mc.linkLabels.insert(kOther, kOther);
  world.mc.link(kOther);
  world.waitFor([&] { return scope(world)->targets().size() == 2 && scope(world)->settings(kOther).has_value(); },
                [&] { return QStringLiteral("both environments in the scope; it is %1").arg(show(world.state(QStringLiteral("settingsScope")))); });
}

const QJsonObject kEverything{{kSettles, true}, {kContinues, true}};

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("the settings scope includes an environment whose MC does not settle threads"), [](World& world, const Captures&, const Table&) {
    announceHere(world, kEverything);
    // While every environment settles threads the rows are there.
    world.waitFor([&] { return rowShown(world, QStringLiteral("sidebarAutoSettleOnMerge")) && rowShown(world, QStringLiteral("sidebarAutoSettleAfterDays")); },
                  QStringLiteral("the auto-settle rows to be shown"));
    linkOther(world, {{kContinues, true}});
  });
  step(QStringLiteral("the auto-settle rows are not shown"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !rowShown(world, QStringLiteral("sidebarAutoSettleOnMerge")) && !rowShown(world, QStringLiteral("sidebarAutoSettleAfterDays")); },
                  QStringLiteral("the auto-settle rows to go"));
    // The rest of the section stays.
    expect(rowShown(world, QStringLiteral("autoResumeLimitedThreads")), QStringLiteral("the other Organization rows went too"));
  });

  step(QStringLiteral("the settings scope includes an environment that cannot continue threads after restarts"), [](World& world, const Captures&, const Table&) {
    announceHere(world, kEverything);
    world.waitFor([&] { return pageItem(world, QStringLiteral("settingsRow:") + kContinue, QStringLiteral("control"))->isEnabled(); },
                  QStringLiteral("the continuation switch to be offered"));
    linkOther(world, {{kSettles, true}});
  });
  step(QStringLiteral("the continuation switch is disabled"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !pageItem(world, QStringLiteral("settingsRow:") + kContinue, QStringLiteral("control"))->isEnabled(); },
                  QStringLiteral("the continuation switch to be disabled"));
  });
  step(QStringLiteral("it explains that every selected environment must support restart continuation"), [](World& world, const Captures&, const Table&) {
    const QQuickItem* status = pageItem(world, QStringLiteral("settingsRow:") + kContinue, QStringLiteral("status"));
    expect(status->isVisible() && status->property("text") == QLatin1String("All selected connected environments must support restart continuation."),
           QStringLiteral("the row says \"%1\"").arg(status->property("text").toString()));
  });

  step(QStringLiteral("the settings scope covers two environments with different streaming modes"), [](World& world, const Captures&, const Table&) {
    announceHere(world, kEverything);
    linkOther(world, kEverything, {{kStreaming, QStringLiteral("turn")}});
  });
  step(QStringLiteral("the response streaming row reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QQuickItem* control = pageItem(world, QStringLiteral("settingsRow:") + kStreaming, QStringLiteral("control"));
    world.waitFor([&] { return control->property("displayText") == c[0]; },
                  [&] { return QStringLiteral("the row reads \"%1\"").arg(control->property("displayText").toString()); });
    expect(generalPage(world).shows(QStringLiteral("The selected targets use different streaming modes.")), QStringLiteral("the row does not say the modes differ"));
  });
  step(QStringLiteral("choosing a mode writes it to both environments"), [](World& world, const Captures&, const Table&) {
    chooseRow(world, kStreaming, QStringLiteral("Wait for the full response"));
    world.waitFor([&] {
      return fakeConfig(world.mc).settings.value(kStreaming) == QLatin1String("turn") &&
             documentOf(world.mc, kOther).settings.value(kStreaming) == QLatin1String("turn");
    }, [&] {
      return QStringLiteral("both to hold turn; this machine holds %1, %2 holds %3")
          .arg(show(fakeConfig(world.mc).settings.toVariantMap()), kOther, show(documentOf(world.mc, kOther).settings.toVariantMap()));
    });
    const QQuickItem* control = pageItem(world, QStringLiteral("settingsRow:") + kStreaming, QStringLiteral("control"));
    world.waitFor([&] { return control->property("displayText") == QLatin1String("Wait for the full response"); },
                  [&] { return QStringLiteral("the row reads \"%1\"").arg(control->property("displayText").toString()); });
  });
});

}  // namespace
