// What General's usage-limit rows mean for a thread that stops on a limit
// (features/settings/general.feature): the MC arms the recovery its settings
// ask for (HalC2.Orchestration.LimitRecovery, faked here from the settings
// document the rows wrote), and the thread's banner shows and cancels it
// (LimitRecoveryController; ThreadLimitSteps' fake follows the cancel).

#include <QJsonObject>

#include "FakeConfig.h"
#include "Harness.h"
#include "NavigationController.h"
#include "SettingsRows.h"
#include "Stream.h"
#include "ThreadList.h"
#include "Turn.h"
#include "World.h"

namespace {

using namespace stream;

const QString kAutoResume = QStringLiteral("autoResumeLimitedThreads");
const QString kSnooze = QStringLiteral("snoozeLimitedThreads");

QString iso(const QDateTime& time) {
  return time.toUTC().toString(Qt::ISODateWithMs);
}

QString key(World& world) {
  return world.mc.environmentId + QLatin1Char(':') + kThread;
}

// The reported reset, four hours on.
QString resetAt(World& world) {
  return iso(world.now().addSecs(4 * 3600));
}

QVariantMap banner(World& world) {
  return world.state(QStringLiteral("limitRecovery")).toMap();
}

QJsonObject recovery(World& world) {
  return world.mc.threads.value(kThread).value(QLatin1String("limitRecovery")).toObject();
}

// The thread's latest run stops on the provider's limit, and the MC arms what its settings say.
void stopOnLimit(World& world) {
  projectThreadCommands(world);
  openTurnThread(world);
  const QJsonObject settings = fakeConfig(world.mc).settings;
  const bool resume = settings.value(kAutoResume).toBool();
  const bool snooze = settings.value(kSnooze).toBool();
  updateThreadRow(world, kThread, [&](QJsonObject& row) {
    const QString stopped = iso(world.now().addSecs(-300));
    row.insert(QStringLiteral("latestRunId"), QStringLiteral("r1"));
    row.insert(QStringLiteral("status"), QStringLiteral("failed"));
    row.insert(QStringLiteral("lastErrorClass"), QStringLiteral("usage_limit"));
    row.insert(QStringLiteral("latestRunStartedAt"), iso(world.now().addSecs(-900)));
    row.insert(QStringLiteral("latestRunCompletedAt"), stopped);
    row.insert(QStringLiteral("updatedAt"), stopped);
    row.insert(QStringLiteral("usageLimitResetAt"), resetAt(world));
    if (!resume && !snooze) return;
    row.insert(QStringLiteral("limitRecovery"), QJsonObject{{QStringLiteral("runId"), QStringLiteral("r1")}, {QStringLiteral("resetAt"), resetAt(world)},
                                                            {QStringLiteral("autoResume"), resume}, {QStringLiteral("snooze"), snooze}});
    if (snooze) {
      row.insert(QStringLiteral("snoozedUntil"), resetAt(world));
      row.insert(QStringLiteral("snoozedAt"), stopped);
    }
  });
  world.native().controller<NavigationController>()->open(NavigationController::Route::thread(key(world)));
  world.waitFor([&] { return banner(world).value(QStringLiteral("threadKey")) == key(world); },
                [&] { return QStringLiteral("the limit banner; it is %1").arg(show(world.state(QStringLiteral("limitRecovery")))); });
}

const Steps steps([] {
  step(QStringLiteral("\"(Auto-resume limited threads|Snooze limited threads)\" is on(?: for the environment)?"), [](World& world, const Captures& c, const Table&) {
    const QString row = c[0].startsWith(QLatin1String("Auto")) ? kAutoResume : kSnooze;
    turnRow(world, row, true);
    world.waitFor([&] { return fakeConfig(world.mc).settings.value(row) == QJsonValue(true); },
                  [&] { return QStringLiteral("the MC to hold %1; it holds %2").arg(row, show(fakeConfig(world.mc).settings.toVariantMap())); });
  });
  step(QStringLiteral("a thread stops because the provider's usage limit was reached"), [](World& world, const Captures&, const Table&) { stopOnLimit(world); });
  step(QStringLiteral("the thread is scheduled to continue at the reported reset time"), [](World& world, const Captures&, const Table&) {
    const QVariantMap shown = banner(world);
    expect(shown.value(QStringLiteral("scheduled")).toBool() && !shown.value(QStringLiteral("snoozed")).toBool() &&
               shown.value(QStringLiteral("description")).toString().startsWith(QLatin1String("Resets ")) &&
               recovery(world).value(QLatin1String("resetAt")) == resetAt(world) && sidebarSectionOf(world, key(world)) == QLatin1String("active"),
           QStringLiteral("the banner is %1; the thread is in \"%2\"").arg(show(shown), sidebarSectionOf(world, key(world))));
  });
  step(QStringLiteral("the thread is snoozed until it wakes at the reported reset time"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return sidebarSectionOf(world, key(world)) == QLatin1String("snoozed"); },
                  [&] { return QStringLiteral("the thread to be snoozed; it is in \"%1\"").arg(sidebarSectionOf(world, key(world))); });
    const QVariantMap shown = banner(world);
    expect(shown.value(QStringLiteral("snoozed")).toBool() && !shown.value(QStringLiteral("scheduled")).toBool() &&
               world.mc.threads.value(kThread).value(QLatin1String("snoozedUntil")) == resetAt(world),
           QStringLiteral("the banner is %1").arg(show(shown)));
    // At the reset it is back among the active threads.
    world.setTime(world.now().addSecs(4 * 3600 + 1));
    world.native().sidebar()->refresh();
    expect(sidebarSectionOf(world, key(world)) == QLatin1String("active"), QStringLiteral("the thread is in \"%1\" after the reset").arg(sidebarSectionOf(world, key(world))));
  });

  step(QStringLiteral("a limited thread is scheduled to continue at its reset time"), [](World& world, const Captures&, const Table&) {
    stopOnLimit(world);
    expect(banner(world).value(QStringLiteral("scheduled")).toBool(), QStringLiteral("the banner is %1").arg(show(banner(world))));
  });
  step(QStringLiteral("the user cancels the scheduled continuation in that thread"), [](World& world, const Captures&, const Table&) {
    // The banner's own control, on while it is scheduled.
    world.bridge().dispatch(QStringLiteral("limitRecovery.resume"), QVariantMap());
    world.sync();
  });
  step(QStringLiteral("the thread does not continue on its own"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !banner(world).value(QStringLiteral("scheduled"), true).toBool(); }, [&] { return QStringLiteral("the banner is %1").arg(show(banner(world))); });
    expect(recovery(world).value(QLatin1String("autoResume")) == QJsonValue(false) && recovery(world).value(QLatin1String("runId")) == QLatin1String("r1"),
           QStringLiteral("the MC holds %1").arg(show(recovery(world).toVariantMap())));
    // The setting itself is as the user left it: only this thread was taken off.
    expect(fakeConfig(world.mc).settings.value(kAutoResume) == QJsonValue(true), QStringLiteral("the setting was changed"));
  });
});

}  // namespace
