// What a settled thread says when it is open, un-settling it from there,
// settling dismissing the agent's background questions, and turning a
// thread's auto-settle off and on from its menu (features/threads/settle.feature).
// The fake MC's rows follow the commands (ThreadMenuSteps' projection).

#include <QJsonObject>

#include "Harness.h"
#include "ThreadList.h"
#include "ThreadSettle.h"
#include "World.h"

namespace {

QString idOf(const QString& key) {
  return key.mid(key.indexOf(QLatin1Char(':')) + 1);
}

QVariantMap notice(World& world) {
  return world.state(QStringLiteral("threadNotice")).toMap();
}

std::optional<QVariantMap> rowOf(World& world, const QString& key) {
  const QVariantMap state = world.state(QStringLiteral("sidebar")).toMap();
  for (const QString& section : {QStringLiteral("pinned"), QStringLiteral("active"), QStringLiteral("working"), QStringLiteral("snoozed"), QStringLiteral("settled")}) {
    for (const QVariant& row : state.value(section).toList()) {
      if (row.toMap().value(QStringLiteral("key")) == key) return row.toMap();
    }
  }
  return std::nullopt;
}

void open(World& world, const QString& key) {
  world.bridge().dispatch(QStringLiteral("thread.open"), QVariantMap{{QStringLiteral("key"), key}});
  world.sync();
}

void settle(World& world, const QString& key) {
  updateThreadRow(world, idOf(key), [](QJsonObject& row) {
    row.insert(QStringLiteral("settledOverride"), QStringLiteral("settled"));
    row.insert(QStringLiteral("settledAt"), QStringLiteral("2026-09-23T09:40:00Z"));
  });
}

void waitForNotice(World& world, const QString& key) {
  world.waitFor([&] { return notice(world).value(QStringLiteral("threadKey")) == key; },
                [&] { return QStringLiteral("the open thread to say it is settled; it says %1").arg(show(notice(world))); });
}

// The thread menu's auto-settle choice for `key`: "enabled" or "disabled".
QString autoSettleChecked(World& world, const QString& key) {
  world.sync();
  world.bridge().dispatch(QStringLiteral("thread.menu"), QVariantMap{{QStringLiteral("key"), key}, {QStringLiteral("x"), 40}, {QStringLiteral("y"), 120}});
  QString checked;
  const QVariant menu = world.state(QStringLiteral("menu"));
  for (const QVariant& item : at(menu, QStringLiteral("items")).toList()) {
    if (item.toMap().value(QStringLiteral("id")) != QLatin1String("auto-settle")) continue;
    for (const QVariant& child : item.toMap().value(QStringLiteral("children")).toList()) {
      if (child.toMap().value(QStringLiteral("checked")).toBool()) checked = child.toMap().value(QStringLiteral("id")).toString().mid(12);
    }
  }
  world.bridge().dispatch(QStringLiteral("menu.select"),
                          QVariantMap{{QStringLiteral("requestId"), at(menu, QStringLiteral("requestId"))}, {QStringLiteral("id"), QVariant::fromValue(nullptr)}});
  expect(!checked.isEmpty(), QStringLiteral("the thread menu has no auto-settle choice: %1").arg(show(menu)));
  return checked;
}

void turnAutoSettle(World& world, const QString& key, bool on) {
  world.sync();
  world.bridge().dispatch(QStringLiteral("thread.menu"), QVariantMap{{QStringLiteral("key"), key}, {QStringLiteral("x"), 40}, {QStringLiteral("y"), 120}});
  const QVariant menu = world.state(QStringLiteral("menu"));
  expect(menu.typeId() == QMetaType::QVariantMap, QStringLiteral("no menu is open"));
  world.bridge().dispatch(QStringLiteral("menu.select"),
                          QVariantMap{{QStringLiteral("requestId"), at(menu, QStringLiteral("requestId"))},
                                      {QStringLiteral("id"), on ? QStringLiteral("auto-settle:enabled") : QStringLiteral("auto-settle:disabled")}});
  world.sync();
}

// Whether the MC's row says auto-settle is off, once the shell has it.
void autoSettleIs(World& world, const QString& key, bool on) {
  world.waitFor([&] { return world.mc.threads.value(idOf(key)).contains(QLatin1String("autoSettleDisabledAt")) != on; },
                [&] { return QStringLiteral("the MC's row to have auto-settle %1: %2").arg(on ? QStringLiteral("on") : QStringLiteral("off"),
                                                                                           show(world.mc.threads.value(idOf(key)).toVariantMap())); });
  const QString checked = autoSettleChecked(world, key);
  expect(checked == (on ? QLatin1String("enabled") : QLatin1String("disabled")), QStringLiteral("the thread menu has auto-settle %1").arg(checked));
}

const Steps steps([] {
  const QString q = kQuoted;

  // The open thread's notice ("the user opens" is ThreadListSteps').
  step(QStringLiteral("the user has opened %1, which is settled").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString key = threadKeyOf(world, c[0]);
    settle(world, key);
    open(world, key);
    waitForNotice(world, key);
  });
  step(QStringLiteral("the thread says %1 and that sending a message un-settles it").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForNotice(world, world.state(QStringLiteral("route")).toMap().value(QStringLiteral("threadKey")).toString());
    const QVariantMap now = notice(world);
    expect(now.value(QStringLiteral("title")) == c[0] && now.value(QStringLiteral("description")) == QLatin1String("Send a message to unsettle") &&
               now.value(QStringLiteral("actionLabel")) == QLatin1String("Un-settle"),
           QStringLiteral("the thread says %1").arg(show(now)));
  });
  step(QStringLiteral("the environment rejects the un-settle"), [](World& world, const Captures&, const Table&) {
    world.mc.refusals.insert(QStringLiteral("thread.unsettle"), QStringLiteral("The thread cannot be un-settled"));
  });
  step(QStringLiteral("%1 stays settled").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    const QString key = threadKeyOf(world, c[0]);
    const QString section = sidebarSectionOf(world, key);
    expect(section == QLatin1String("settled"), QStringLiteral("%1 is in \"%2\"").arg(c[0], section));
    const QVariantMap now = notice(world);
    expect(now.value(QStringLiteral("threadKey")) == key && now.value(QStringLiteral("actionLabel")) == QLatin1String("Un-settle"),
           QStringLiteral("the thread says %1").arg(show(now)));
  });

  // A thread that woke, then was settled.
  step(QStringLiteral("%1 woke from a snooze and was then settled").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString key = threadKeyOf(world, c[0]);
    // Another thread is open, so the woke one is not visited yet.
    QJsonObject other = world.mc.threads.value(idOf(key));
    other.insert(QStringLiteral("id"), QStringLiteral("t-other"));
    other.insert(QStringLiteral("title"), QStringLiteral("Other work"));
    world.mc.threads.insert(QStringLiteral("t-other"), other);
    world.mc.sendRow(QStringLiteral("t-other"), other);
    world.sync();
    open(world, world.mc.environmentId + QStringLiteral(":t-other"));
    updateThreadRow(world, idOf(key), [&](QJsonObject& row) {
      row.insert(QStringLiteral("snoozedAt"), QStringLiteral("2026-09-23T07:00:00Z"));
      row.insert(QStringLiteral("snoozedUntil"), QStringLiteral("2026-09-23T09:00:00Z"));
      row.insert(QStringLiteral("lastVisitedAt"), QStringLiteral("2026-09-23T06:00:00Z"));
      row.insert(QStringLiteral("settledOverride"), QStringLiteral("settled"));
      row.insert(QStringLiteral("settledAt"), QStringLiteral("2026-09-23T09:40:00Z"));
    });
  });
  step(QStringLiteral("the thread says it is settled"), [](World& world, const Captures&, const Table&) {
    waitForNotice(world, world.state(QStringLiteral("route")).toMap().value(QStringLiteral("threadKey")).toString());
    const QVariantMap now = notice(world);
    expect(now.value(QStringLiteral("kind")) == QLatin1String("settled") && now.value(QStringLiteral("title")) == QLatin1String("This thread is settled"),
           QStringLiteral("the thread says %1").arg(show(now)));
  });
  step(QStringLiteral("it does not say it woke from a snooze"), [](World& world, const Captures&, const Table&) {
    const QVariantMap now = notice(world);
    for (const QString& field : {QStringLiteral("title"), QStringLiteral("description"), QStringLiteral("actionLabel")}) {
      expect(!now.value(field).toString().contains(QLatin1String("woke"), Qt::CaseInsensitive) &&
                 !now.value(field).toString().contains(QLatin1String("wake"), Qt::CaseInsensitive),
             QStringLiteral("the thread says %1").arg(show(now)));
    }
  });

  // Questions the agent is waiting on.
  step(QStringLiteral("the agent in %1 asked a question in the background").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString key = threadKeyOf(world, c[0]);
    updateThreadRow(world, idOf(key), [](QJsonObject& row) {
      row.insert(QStringLiteral("latestRunId"), QStringLiteral("r1"));
      row.insert(QStringLiteral("status"), QStringLiteral("completed"));
      row.insert(QStringLiteral("pendingRuntimeRequest"), QJsonObject{{QStringLiteral("id"), QStringLiteral("q1")},
                                                                       {QStringLiteral("kind"), QStringLiteral("user_input")},
                                                                       {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:50:00Z")}});
    });
    const auto row = rowOf(world, key);
    expect(row && row->value(QStringLiteral("status")) == QLatin1String("input"), QStringLiteral("the row is %1").arg(show(row.value_or(QVariantMap()))));
  });
  step(QStringLiteral("the question is dismissed"), [](World& world, const Captures&, const Table&) {
    const QString key = threadKeyOf(world, QStringLiteral("Ship checkout"));
    world.waitFor([&] {
      const auto row = rowOf(world, key);
      return row && sidebarSectionOf(world, key) == QLatin1String("settled") && row->value(QStringLiteral("status")) != QLatin1String("input");
    }, [&] { return QStringLiteral("the question to go; the row is %1").arg(show(rowOf(world, key).value_or(QVariantMap()))); });
  });

  // A thread's auto-settle.
  step(QStringLiteral("the user turns auto-settle (off|on) for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    turnAutoSettle(world, threadKeyOf(world, c[1]), c[0] == QLatin1String("on"));
  });
  step(QStringLiteral("%1 has auto-settle turned off").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString key = threadKeyOf(world, c[0]);
    turnAutoSettle(world, key, false);
    autoSettleIs(world, key, false);
  });
  step(QStringLiteral("%1 stays out of automatic settling").arg(q), [](World& world, const Captures& c, const Table&) {
    autoSettleIs(world, threadKeyOf(world, c[0]), false);
  });
  step(QStringLiteral("%1 settles automatically again after a quiet spell").arg(q), [](World& world, const Captures& c, const Table&) {
    autoSettleIs(world, threadKeyOf(world, c[0]), true);
  });
});

}  // namespace

bool threadNoticeChooses(World& world, const QString& choice) {
  const QVariantMap now = notice(world);
  if (now.isEmpty() || now.value(QStringLiteral("actionLabel")) != choice) return false;
  world.bridge().dispatch(QStringLiteral("threadNotice.unsettle"), {});
  world.sync();
  return true;
}
