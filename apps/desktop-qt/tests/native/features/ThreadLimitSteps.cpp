// A thread whose agent stopped on a usage limit
// (features/threads/limited-threads.feature): what its conversation keeps,
// and waiting for the reset from the banner (LimitRecoveryController). The MC
// arms the recovery (`thread.metadata.update` with `limitRecovery`), snoozes
// the thread until the reset when asked, and resumes it then: the fake's rows
// follow as HalC2.Orchestration does.

#include <QJsonArray>
#include <QJsonObject>

#include "FakeConfig.h"
#include "Harness.h"
#include "NavigationController.h"
#include "Stream.h"
#include "ThreadList.h"
#include "World.h"

namespace {

struct Limits {
  // The MC arms the recovery itself (the user's settings say so).
  bool automatic = false;
  QString resetAt;
};

QString iso(const QDateTime& time) {
  return time.toUTC().toString(Qt::ISODateWithMs);
}

QString idOf(const QString& key) {
  return key.mid(key.indexOf(QLatin1Char(':')) + 1);
}

const FakeMc::Extension limitRecovery([](FakeMc& mc) {
  mc.effects.append([&mc](const QJsonObject& command) {
    if (command.value(QLatin1String("type")) != QLatin1String("thread.metadata.update") || !command.contains(QLatin1String("limitRecovery"))) return;
    const QString id = command.value(QLatin1String("threadId")).toString();
    if (!mc.threads.contains(id)) return;
    QJsonObject& row = mc.threads[id];
    const QJsonObject update = command.value(QLatin1String("limitRecovery")).toObject();
    const QJsonObject previous = row.value(QLatin1String("limitRecovery")).toObject();
    const bool same = previous.value(QLatin1String("runId")) == update.value(QLatin1String("runId")) &&
                      previous.value(QLatin1String("resetAt")) == update.value(QLatin1String("resetAt"));
    // A choice the update leaves out keeps the one made for the same run and reset.
    const auto choice = [&](const char* key) {
      const QJsonValue value = update.value(QLatin1String(key));
      return value.isBool() ? value.toBool() : same && previous.value(QLatin1String(key)).toBool();
    };
    QJsonObject recovery = update;
    recovery.insert(QStringLiteral("autoResume"), choice("autoResume"));
    recovery.insert(QStringLiteral("snooze"), choice("snooze"));
    if (recovery.value(QLatin1String("snooze")).toBool()) {
      row.insert(QStringLiteral("snoozedUntil"), recovery.value(QLatin1String("resetAt")));
      row.insert(QStringLiteral("snoozedAt"), QStringLiteral("2026-09-23T10:00:00Z"));
    } else if (previous.value(QLatin1String("snooze")).toBool()) {
      row.remove(QStringLiteral("snoozedUntil"));
      row.remove(QStringLiteral("snoozedAt"));
    }
    row.insert(QStringLiteral("limitRecovery"), recovery);
    mc.sendRow(id, row);
  });
});

QDateTime today(World& world, int hour, int minute) {
  return QDateTime(world.now().date(), QTime(hour, minute));
}

// The row of a thread whose latest run stopped on the limit five minutes ago.
void stop(World& world, const QString& title, const QString& resetAt) {
  world.mc.part<Limits>().resetAt = resetAt;
  updateThreadRow(world, idOf(threadKeyOf(world, title)), [&](QJsonObject& row) {
    const QString stopped = iso(world.now().addSecs(-300));
    row.insert(QStringLiteral("latestRunId"), QStringLiteral("r1"));
    row.insert(QStringLiteral("status"), QStringLiteral("failed"));
    row.insert(QStringLiteral("lastErrorClass"), QStringLiteral("usage_limit"));
    row.insert(QStringLiteral("latestRunStartedAt"), iso(world.now().addSecs(-900)));
    row.insert(QStringLiteral("latestRunCompletedAt"), stopped);
    row.insert(QStringLiteral("updatedAt"), stopped);
    if (resetAt.isEmpty()) {
      row.remove(QStringLiteral("usageLimitResetAt"));
    } else {
      row.insert(QStringLiteral("usageLimitResetAt"), resetAt);
    }
    if (world.mc.part<Limits>().automatic && !resetAt.isEmpty()) {
      row.insert(QStringLiteral("limitRecovery"), QJsonObject{{QStringLiteral("runId"), QStringLiteral("r1")}, {QStringLiteral("resetAt"), resetAt},
                                                              {QStringLiteral("autoResume"), true}, {QStringLiteral("snooze"), true}});
      row.insert(QStringLiteral("snoozedUntil"), resetAt);
      row.insert(QStringLiteral("snoozedAt"), stopped);
    }
  });
}

void view(World& world, const QString& title) {
  const QString key = threadKeyOf(world, title);
  world.native().controller<NavigationController>()->open(NavigationController::Route::thread(key));
  world.waitFor([&] { return world.state(QStringLiteral("limitRecovery")).toMap().value(QStringLiteral("threadKey")) == key; },
                [&] { return QStringLiteral("the limit banner of %1; it is %2").arg(title, show(world.state(QStringLiteral("limitRecovery")))); });
}

QVariantMap banner(World& world) {
  return world.state(QStringLiteral("limitRecovery")).toMap();
}

void waitSection(World& world, const QString& title, const QString& section) {
  const QString key = threadKeyOf(world, title);
  world.waitFor([&] { return sidebarSectionOf(world, key) == section; },
                [&] { return QStringLiteral("%1 in %2; it is in \"%3\"").arg(title, section, sidebarSectionOf(world, key)); });
}

qsizetype messagesSent(World& world) {
  qsizetype sent = 0;
  for (const QJsonObject& command : std::as_const(world.mc.commands)) sent += command.value(QLatin1String("type")) == QLatin1String("message.dispatch");
  return sent;
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("the conversation says the thread stopped on a usage limit"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      if (!stream::store(world)->activeTimeline()) return false;
      TimelineModel& model = stream::timeline(world);
      for (int row = 0; row < model.rowCount(); ++row) {
        if (stream::role(model, row, TimelineModel::KindRole) == QLatin1String("error") &&
            stream::role(model, row, TimelineModel::TitleRole).toString().startsWith(QLatin1String("Usage limit reached")) &&
            stream::role(model, row, TimelineModel::WarningRole).toBool()) {
          return true;
        }
      }
      return false;
    }, [&] { return QStringLiteral("the usage limit line; %1").arg(stream::store(world)->activeTimeline() ? stream::describe(stream::timeline(world)) : QStringLiteral("no thread is open")); });
  });

  step(QStringLiteral("(?:%1|Claude) (?:stopped|stops) (?:%1 )?on a usage limit that resets at (\\d+):(\\d+)").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString title = c[0].isEmpty() ? c[1] : c[0];
    projectThreadCommands(world);
    stop(world, title, iso(today(world, c[2].toInt(), c[3].toInt())));
  });
  step(QStringLiteral("the agent stopped %1 on a limit without saying when it resets").arg(q), [](World& world, const Captures& c, const Table&) {
    projectThreadCommands(world);
    stop(world, c[0], {});
  });
  step(QStringLiteral("the user snoozes %1 until the reset").arg(q), [](World& world, const Captures& c, const Table&) {
    view(world, c[0]);
    expect(banner(world).value(QStringLiteral("canSchedule")).toBool() && banner(world).value(QStringLiteral("canSnooze")).toBool(),
           QStringLiteral("the banner is %1").arg(show(banner(world))));
    world.bridge().dispatch(QStringLiteral("limitRecovery.snooze"), QVariantMap());
  });
  step(QStringLiteral("%1 is snoozed until (\\d+):(\\d+)").arg(q), [](World& world, const Captures& c, const Table&) {
    waitSection(world, c[0], QStringLiteral("snoozed"));
    const QJsonObject row = world.mc.threads.value(idOf(threadKeyOf(world, c[0])));
    expect(row.value(QLatin1String("snoozedUntil")).toString() == iso(today(world, c[1].toInt(), c[2].toInt())),
           QStringLiteral("the thread is snoozed until %1").arg(row.value(QLatin1String("snoozedUntil")).toString()));
  });
  step(QStringLiteral("it wakes without sending a message"), [](World& world, const Captures&, const Table&) {
    const QString key = world.mc.environmentId + QLatin1Char(':') + world.mc.threads.firstKey();
    world.setTime(QDateTime::fromString(world.mc.part<Limits>().resetAt, Qt::ISODateWithMs).addSecs(1));
    world.native().sidebar()->refresh();
    expect(sidebarSectionOf(world, key) == QLatin1String("active"), QStringLiteral("the thread is in \"%1\"").arg(sidebarSectionOf(world, key)));
    world.sync();
    expect(messagesSent(world) == 0 && !world.mc.threads.first().value(QLatin1String("limitRecovery")).toObject().value(QLatin1String("autoResume")).toBool(),
           QStringLiteral("the MC has %1").arg(world.describeCommands()));
  });

  step(QStringLiteral("the user turned on auto-resume and snoozing for limited threads"), [](World& world, const Captures&, const Table&) {
    saveElsewhere(world.mc, QStringLiteral("autoResumeLimitedThreads"), true);
    saveElsewhere(world.mc, QStringLiteral("snoozeLimitedThreads"), true);
    world.mc.part<Limits>().automatic = true;
    world.sync();
  });
  step(QStringLiteral("at (\\d+):(\\d+) %1 wakes and continues").arg(q), [](World& world, const Captures& c, const Table&) {
    // Until then it is shelved, and its banner says it continues on its own.
    waitSection(world, c[2], QStringLiteral("snoozed"));
    view(world, c[2]);
    expect(banner(world).value(QStringLiteral("scheduled")).toBool() && banner(world).value(QStringLiteral("snoozed")).toBool(),
           QStringLiteral("the banner is %1").arg(show(banner(world))));
    // At the reset the MC resumes the thread.
    world.setTime(today(world, c[0].toInt(), c[1].toInt()).addSecs(1));
    updateThreadRow(world, idOf(threadKeyOf(world, c[2])), [&](QJsonObject& row) {
      row.insert(QStringLiteral("latestRunId"), QStringLiteral("r2"));
      row.insert(QStringLiteral("activeRunId"), QStringLiteral("r2"));
      row.insert(QStringLiteral("status"), QStringLiteral("running"));
      row.insert(QStringLiteral("latestRunStartedAt"), iso(world.now()));
      row.insert(QStringLiteral("updatedAt"), iso(world.now()));
      for (const char* key : {"latestRunCompletedAt", "lastErrorClass", "usageLimitResetAt", "limitRecovery", "snoozedUntil", "snoozedAt"}) row.remove(QLatin1String(key));
    });
    waitSection(world, c[2], QStringLiteral("active"));
    const QString key = threadKeyOf(world, c[2]);
    for (const QVariant& row : at(world.state(QStringLiteral("sidebar")), QStringLiteral("active")).toList()) {
      if (row.toMap().value(QStringLiteral("key")) == key) {
        expect(row.toMap().value(QStringLiteral("status")) == QLatin1String("working"), QStringLiteral("the row is %1").arg(show(row)));
      }
    }
    expect(world.state(QStringLiteral("limitRecovery")).typeId() != QMetaType::QVariantMap && messagesSent(world) == 0,
           QStringLiteral("the banner is %1").arg(show(world.state(QStringLiteral("limitRecovery")))));
  });

  step(QStringLiteral("%1 is snoozed until its limit resets").arg(q), [](World& world, const Captures& c, const Table&) {
    projectThreadCommands(world);
    world.mc.part<Limits>().automatic = true;
    stop(world, c[0], iso(today(world, 14, 0)));
    waitSection(world, c[0], QStringLiteral("snoozed"));
  });
  step(QStringLiteral("the user wakes %1 now").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("thread.unsnooze"), QVariantMap{{QStringLiteral("key"), threadKeyOf(world, c[0])}});
  });
  step(QStringLiteral("%1 is active again").arg(q), [](World& world, const Captures& c, const Table&) {
    waitSection(world, c[0], QStringLiteral("active"));
    // The recovery's own snooze is ended there, so the MC does not snooze it again.
    const QJsonObject recovery = world.mc.threads.value(idOf(threadKeyOf(world, c[0]))).value(QLatin1String("limitRecovery")).toObject();
    expect(!recovery.value(QLatin1String("snooze")).toBool() && recovery.value(QLatin1String("autoResume")).toBool(),
           QStringLiteral("the recovery is %1").arg(show(recovery.toVariantMap())));
  });

  step(QStringLiteral("the user can retry by hand or snooze with the usual choices"), [](World& world, const Captures&, const Table&) {
    const QString key = world.native().controller<NavigationController>()->threadKey();
    world.waitFor([&] { return banner(world).value(QStringLiteral("threadKey")) == key; }, QStringLiteral("the limit banner"));
    expect(banner(world).value(QStringLiteral("description")) == QLatin1String("Reset time unavailable; retry manually") &&
               !banner(world).value(QStringLiteral("canSchedule")).toBool(),
           QStringLiteral("the banner is %1").arg(show(banner(world))));
    // The usual snooze choices.
    world.bridge().dispatch(QStringLiteral("thread.snoozeMenu"), QVariantMap{{QStringLiteral("key"), key}, {QStringLiteral("x"), 200}, {QStringLiteral("y"), 120}});
    QStringList choices;
    for (const QVariant& item : at(world.state(QStringLiteral("menu")), QStringLiteral("items")).toList()) choices.append(item.toMap().value(QStringLiteral("id")).toString());
    expect(choices.contains(QStringLiteral("snooze:hour")) && choices.contains(QStringLiteral("snooze:tomorrow")) && choices.contains(QStringLiteral("snooze:custom")),
           QStringLiteral("the snooze choices are %1").arg(choices.join(QStringLiteral(", "))));
    world.bridge().dispatch(QStringLiteral("menu.select"), QVariantMap{{QStringLiteral("requestId"), at(world.state(QStringLiteral("menu")), QStringLiteral("requestId"))},
                                                                       {QStringLiteral("id"), QVariant::fromValue(nullptr)}});
    // Retrying is sending again.
    world.bridge().dispatch(QStringLiteral("composer.submit"),
                            QVariantMap{{QStringLiteral("edit"), QVariantMap{{QStringLiteral("clientId"), QStringLiteral("qml")}, {QStringLiteral("revision"), world.nextEdit++}}},
                                        {QStringLiteral("text"), QStringLiteral("Try again")}, {QStringLiteral("intent"), QStringLiteral("foreground")}});
    world.sync();
    expect(messagesSent(world) == 1, QStringLiteral("the MC has %1").arg(world.describeCommands()));
  });
});

}  // namespace
