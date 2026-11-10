// The thread list's Working section (threads/sidebar-list.feature): busy
// threads fold into it, leave it after a grace the clock runs out, and the
// inbox above it keeps the order threads came back in. The grace is driven
// by World::setTime and a refresh, never by waiting.

#include <QJSValue>
#include <QJsonArray>
#include <QJsonObject>
#include <QQmlContext>
#include <QQmlExpression>
#include <QQuickItem>
#include <QTest>

#include <algorithm>

#include "Brick.h"
#include "Harness.h"
#include "SettingsController.h"
#include "SettingsRows.h"
#include "SidebarController.h"
#include "ThreadList.h"
#include "World.h"

namespace {

const QString kShelf = QStringLiteral("sidebarWorkingShelfEnabled");

QString iso(const QDateTime& time) {
  return time.toUTC().toString(Qt::ISODate);
}

QString idOf(const QString& title) {
  return QStringLiteral("t-") + title.toLower().replace(QLatin1Char(' '), QLatin1Char('-'));
}

// What the scenario saw: the section of the thread it follows after each change.
struct Scene {
  QString subject;
  QStringList seen;
  QList<QStringList> orders;
};

Scene& scene() {
  static Scene current;
  return current;
}

void putThread(World& world, const QString& title, QJsonObject row) {
  const QString id = idOf(title);
  row.insert(QStringLiteral("id"), id);
  row.insert(QStringLiteral("title"), title);
  if (!row.contains(QLatin1String("projectId"))) row.insert(QStringLiteral("projectId"), world.mc.projects.firstKey());
  if (!row.contains(QLatin1String("createdAt"))) row.insert(QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z"));
  if (!row.contains(QLatin1String("updatedAt"))) row.insert(QStringLiteral("updatedAt"), row.value(QLatin1String("createdAt")));
  world.mc.threads.insert(id, row);
  world.mc.sendRow(id, row);
  world.sync();
}

// A run the user asked for at `at`, going.
QJsonObject running(const QString& run, const QDateTime& at) {
  return {{QStringLiteral("latestRunId"), run},
          {QStringLiteral("activeRunId"), run},
          {QStringLiteral("status"), QStringLiteral("running")},
          {QStringLiteral("latestRunRequestedAt"), iso(at)},
          {QStringLiteral("latestRunStartedAt"), iso(at)},
          {QStringLiteral("latestUserMessageAt"), iso(at)},
          {QStringLiteral("latestUserAuthoredMessageAt"), iso(at)},
          {QStringLiteral("updatedAt"), iso(at)}};
}

void change(World& world, const QString& title, const std::function<void(QJsonObject&)>& edit) {
  updateThreadRow(world, idOf(title), [&](QJsonObject& row) {
    edit(row);
    row.insert(QStringLiteral("updatedAt"), iso(world.now()));
  });
}

void endRun(QJsonObject& row, const QDateTime& at) {
  row.insert(QStringLiteral("status"), QStringLiteral("idle"));
  row.remove(QStringLiteral("activeRunId"));
  row.insert(QStringLiteral("latestRunCompletedAt"), iso(at));
}

// The clock moves on and the list looks again, as the grace's timer has it do.
void advance(World& world, qint64 ms) {
  world.setTime(world.now().addMSecs(ms));
  world.native().sidebar()->refresh();
  world.sync();
}

QStringList titles(World& world, const QString& section) {
  QStringList out;
  for (const QVariant& row : at(world.state(QStringLiteral("sidebar")), section).toList()) {
    out.append(row.toMap().value(QStringLiteral("title")).toString());
  }
  return out;
}

QString sectionOf(World& world, const QString& title) {
  return sidebarSectionOf(world, threadKeyOf(world, title));
}

void see(World& world) {
  scene().seen.append(sectionOf(world, scene().subject));
}

// The thread list as the window draws it.
Brick& threadList(World& world) {
  if (!world.brick) {
    world.brick = std::make_unique<Brick>(world, QByteArrayLiteral("import QtQuick\nimport HalC2.Bricks\nSidebar { height: 600 }\n"), QSize(256, 600));
  }
  return *world.brick;
}

QVariantList listRows(Brick& brick) {
  QVariant rows = brick.root()->property("rows");
  if (rows.canConvert<QJSValue>()) rows = rows.value<QJSValue>().toVariant();
  return rows.toList();
}

// Where the list draws the row named `rowKey` (a thread's key, "header:working"), -1 when it does not.
qsizetype rowIndex(const QVariantList& rows, const QString& rowKey) {
  for (qsizetype index = 0; index < rows.size(); ++index) {
    if (rows.at(index).toMap().value(QStringLiteral("rowKey")).toString() == rowKey) return index;
  }
  return -1;
}

const Steps steps([] {
  Brick::registerSingletons();
  const QString q = kQuoted;

  // The setting.
  step(QStringLiteral("Working section is on in General settings"), [](World& world, const Captures&, const Table&) {
    turnRow(world, kShelf, true);
    world.brick.reset();
  });
  step(QStringLiteral("the Working section is on"), [](World& world, const Captures&, const Table&) {
    expect(settingOn(world, kShelf), QStringLiteral("the Working section is off"));
  });
  // For scenarios about the order the user arranges, which the section's inbox does not keep.
  step(QStringLiteral("the Working section is off"), [](World& world, const Captures&, const Table&) {
    world.native().controller<SettingsController>()->set(kShelf, false);
    world.native().sidebar()->refresh();
    world.sync();
  });
  step(QStringLiteral("the user never changed whether the Working section is on"), [](World& world, const Captures&, const Table&) {
    expect(!world.native().controller<SettingsController>()->deviceSettings().contains(kShelf), QStringLiteral("this device has a Working section setting"));
  });

  // Busy threads.
  step(QStringLiteral("threads are working, connecting or monitoring"), [](World& world, const Captures&, const Table&) {
    const QDateTime now = world.now();
    putThread(world, QStringLiteral("Idle"), {});
    putThread(world, QStringLiteral("Later"), {{QStringLiteral("snoozedUntil"), iso(now.addDays(1))}, {QStringLiteral("snoozedAt"), iso(now.addSecs(-3600))}});
    putThread(world, QStringLiteral("Done"), {{QStringLiteral("settledOverride"), QStringLiteral("settled")}, {QStringLiteral("settledAt"), iso(now.addSecs(-3600))}});
    putThread(world, QStringLiteral("Build"), running(QStringLiteral("r-build"), now.addSecs(-60)));
    QJsonObject connecting = running(QStringLiteral("r-connect"), now.addSecs(-50));
    connecting.insert(QStringLiteral("status"), QStringLiteral("starting"));
    putThread(world, QStringLiteral("Connect"), connecting);
    // Its run ended, and it waits on a command it left running.
    QJsonObject monitoring = running(QStringLiteral("r-monitor"), now.addSecs(-40));
    endRun(monitoring, now.addSecs(-30));
    monitoring.insert(QStringLiteral("pendingBackgroundTasks"), QJsonArray{QJsonObject{{QStringLiteral("id"), QStringLiteral("tests")}}});
    putThread(world, QStringLiteral("Monitor"), monitoring);
  });
  step(QStringLiteral("threads are working"), [](World& world, const Captures&, const Table&) {
    putThread(world, QStringLiteral("Build"), running(QStringLiteral("r-build"), world.now().addSecs(-60)));
  });
  step(QStringLiteral("they move into a collapsed Working section above Snoozed and Settled"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return titles(world, QStringLiteral("working")).size() == 3; },
                  [&] { return QStringLiteral("three working threads; Working lists %1").arg(titles(world, QStringLiteral("working")).join(QStringLiteral(", "))); });
    expect(titles(world, QStringLiteral("active")) == QStringList{QStringLiteral("Idle")},
           QStringLiteral("the inbox lists %1").arg(titles(world, QStringLiteral("active")).join(QStringLiteral(", "))));
    Brick& list = threadList(world);
    const QVariantList rows = listRows(list);
    const qsizetype working = rowIndex(rows, QStringLiteral("header:working"));
    const qsizetype snoozed = rowIndex(rows, QStringLiteral("header:snoozed"));
    const qsizetype settled = rowIndex(rows, QStringLiteral("header:settled"));
    expect(working >= 0 && working < snoozed && snoozed < settled, QStringLiteral("the headers are at %1, %2 and %3").arg(working).arg(snoozed).arg(settled));
    expect(!rows.at(working).toMap().value(QStringLiteral("open")).toBool(), QStringLiteral("the Working section is open"));
    for (const QString& title : {QStringLiteral("Build"), QStringLiteral("Connect"), QStringLiteral("Monitor")}) {
      expect(rowIndex(rows, threadKeyOf(world, title)) < 0, QStringLiteral("%1 is drawn in the folded section").arg(title));
    }
    // Opened, its rows are the inbox's cards, not a shelf's slim ones.
    QMetaObject::invokeMethod(list.root(), "toggleSection", Q_ARG(QVariant, QStringLiteral("working")));
    const QVariantList open = listRows(list);
    const qsizetype build = rowIndex(open, threadKeyOf(world, QStringLiteral("Build")));
    expect(build >= 0 && open.at(build).toMap().value(QStringLiteral("kind")) == QLatin1String("thread"),
           QStringLiteral("the open section draws %1").arg(show(build >= 0 ? open.at(build) : QVariant())));
  });
  step(QStringLiteral("they move into the Working section"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return sectionOf(world, QStringLiteral("Build")) == QLatin1String("working"); },
                  [&] { return QStringLiteral("Build in Working; it is in \"%1\"").arg(sectionOf(world, QStringLiteral("Build"))); });
  });
  step(QStringLiteral("a thread returns to the top of the inbox when it finishes, fails or asks for approval or an answer"), [](World& world, const Captures&, const Table&) {
    const auto top = [&](const QString& title) {
      const QStringList inbox = titles(world, QStringLiteral("active"));
      expect(!inbox.isEmpty() && inbox.first() == title, QStringLiteral("%1 at the top of the inbox; it lists %2").arg(title, inbox.join(QStringLiteral(", "))));
    };
    // Finishing: once the grace is up.
    advance(world, 1000);
    change(world, QStringLiteral("Build"), [&](QJsonObject& row) { endRun(row, world.now()); });
    advance(world, sidebar::kWorkingExitGraceMs);
    top(QStringLiteral("Build"));
    // Failing, at once.
    advance(world, 1000);
    change(world, QStringLiteral("Connect"), [&](QJsonObject& row) {
      endRun(row, world.now());
      row.insert(QStringLiteral("status"), QStringLiteral("failed"));
    });
    top(QStringLiteral("Connect"));
    // Asking for an answer, at once.
    advance(world, 1000);
    change(world, QStringLiteral("Monitor"), [](QJsonObject& row) {
      row.insert(QStringLiteral("pendingRuntimeRequest"), QJsonObject{{QStringLiteral("kind"), QStringLiteral("user_input")}});
    });
    top(QStringLiteral("Monitor"));
    // And for an approval.
    advance(world, 1000);
    putThread(world, QStringLiteral("Deploy"), running(QStringLiteral("r-deploy"), world.now()));
    expect(sectionOf(world, QStringLiteral("Deploy")) == QLatin1String("working"), QStringLiteral("Deploy is not working"));
    advance(world, 1000);
    change(world, QStringLiteral("Deploy"), [](QJsonObject& row) {
      row.insert(QStringLiteral("pendingRuntimeRequest"), QJsonObject{{QStringLiteral("kind"), QStringLiteral("command_approval")}});
    });
    top(QStringLiteral("Deploy"));
  });
  step(QStringLiteral("drag reordering in the inbox is off while it is on"), [](World& world, const Captures&, const Table&) {
    const QStringList before = titles(world, QStringLiteral("active"));
    expect(before.size() >= 2, QStringLiteral("the inbox lists %1").arg(before.join(QStringLiteral(", "))));
    const qsizetype sent = world.mc.commands.size();
    world.bridge().dispatch(QStringLiteral("thread.drop"), QVariantMap{{QStringLiteral("key"), threadKeyOf(world, before.last())},
                                                                       {QStringLiteral("section"), QStringLiteral("active")},
                                                                       {QStringLiteral("beforeKey"), threadKeyOf(world, before.first())}});
    world.sync();
    expect(titles(world, QStringLiteral("active")) == before && world.mc.commands.size() == sent,
           QStringLiteral("the drop moved the inbox to %1").arg(titles(world, QStringLiteral("active")).join(QStringLiteral(", "))));
    // Nor does its menu offer to move a row up or down.
    expect(!world.native().sidebar()->canMove(threadKeyOf(world, before.last()), true), QStringLiteral("the menu moves an inbox row"));
  });
  step(QStringLiteral("restoring the setting's default turns the Working section back on"), [](World& world, const Captures&, const Table&) {
    world.brick.reset();
    turnRow(world, kShelf, false);
    world.waitFor([&] { return sectionOf(world, QStringLiteral("Build")) == QLatin1String("active"); },
                  [&] { return QStringLiteral("Build in the inbox with the section off; it is in \"%1\"").arg(sectionOf(world, QStringLiteral("Build"))); });
    Brick& page = generalPage(world);
    QQuickItem* reset = pageItem(world, QStringLiteral("settingsRow:") + kShelf, QStringLiteral("reset"));
    QTest::mouseClick(&page.window(), Qt::LeftButton, Qt::NoModifier, page.at(reset));
    world.waitFor([&] { return settingOn(world, kShelf) && sectionOf(world, QStringLiteral("Build")) == QLatin1String("working"); },
                  [&] { return QStringLiteral("Build in Working again; it is in \"%1\"").arg(sectionOf(world, QStringLiteral("Build"))); });
  });

  // The Working section's order.
  step(QStringLiteral("several threads are in the Working section"), [](World& world, const Captures&, const Table&) {
    const QDateTime now = world.now();
    putThread(world, QStringLiteral("Alpha"), running(QStringLiteral("r-alpha"), now.addSecs(-30 * 60)));
    putThread(world, QStringLiteral("Bravo"), running(QStringLiteral("r-bravo"), now.addSecs(-20 * 60)));
    putThread(world, QStringLiteral("Charlie"), running(QStringLiteral("r-charlie"), now.addSecs(-10 * 60)));
    scene() = {};
    scene().orders.append(titles(world, QStringLiteral("working")));
    expect(scene().orders.first().size() == 3, QStringLiteral("Working lists %1").arg(scene().orders.first().join(QStringLiteral(", "))));
  });
  step(QStringLiteral("an agent run ends, or a subagent result or pull request watch wakes a thread"), [](World& world, const Captures&, const Table&) {
    const auto look = [&] { scene().orders.append(titles(world, QStringLiteral("working"))); };
    // Bravo's run ends, leaving a subagent it waits on.
    advance(world, 1000);
    change(world, QStringLiteral("Bravo"), [&](QJsonObject& row) {
      endRun(row, world.now());
      row.insert(QStringLiteral("pendingBackgroundTasks"), QJsonArray{QJsonObject{{QStringLiteral("id"), QStringLiteral("subagent")}}});
    });
    look();
    // The subagent's result wakes Alpha with a message sent as the user; the user typed nothing.
    advance(world, 1000);
    change(world, QStringLiteral("Alpha"), [&](QJsonObject& row) {
      row.insert(QStringLiteral("latestRunId"), QStringLiteral("r-alpha-2"));
      row.insert(QStringLiteral("activeRunId"), QStringLiteral("r-alpha-2"));
      row.insert(QStringLiteral("latestRunRequestedAt"), iso(world.now()));
      row.insert(QStringLiteral("latestUserMessageAt"), iso(world.now()));
    });
    look();
    // A pull request watch wakes Bravo the same way.
    advance(world, 1000);
    change(world, QStringLiteral("Bravo"), [&](QJsonObject& row) {
      row.remove(QStringLiteral("pendingBackgroundTasks"));
      row.insert(QStringLiteral("latestRunId"), QStringLiteral("r-bravo-2"));
      row.insert(QStringLiteral("activeRunId"), QStringLiteral("r-bravo-2"));
      row.insert(QStringLiteral("status"), QStringLiteral("running"));
      row.remove(QStringLiteral("latestRunCompletedAt"));
      row.insert(QStringLiteral("latestRunRequestedAt"), iso(world.now()));
      row.insert(QStringLiteral("latestUserMessageAt"), iso(world.now()));
    });
    look();
    advance(world, sidebar::kWorkingExitGraceMs);
    look();
  });
  step(QStringLiteral("the section is ordered by the last message the user sent, newest first, and no row moves"), [](World&, const Captures&, const Table&) {
    const QStringList expected{QStringLiteral("Charlie"), QStringLiteral("Bravo"), QStringLiteral("Alpha")};
    for (const QStringList& order : std::as_const(scene().orders)) {
      expect(order == expected, QStringLiteral("Working was %1").arg(order.join(QStringLiteral(", "))));
    }
  });

  // The grace.
  step(QStringLiteral("%1 is in the Working section").arg(q), [](World& world, const Captures& c, const Table&) {
    putThread(world, c[0], running(QStringLiteral("r1"), world.now().addSecs(-60)));
    scene() = {};
    scene().subject = c[0];
    expect(sectionOf(world, c[0]) == QLatin1String("working"), QStringLiteral("%1 is in \"%2\"").arg(c[0], sectionOf(world, c[0])));
  });
  step(QStringLiteral("its run ends and (its next run starts|the MC settles it|nothing else happens|it asks for approval) within two seconds"),
       [](World& world, const Captures& c, const Table&) {
         const QString title = scene().subject;
         if (c[0] == QLatin1String("it asks for approval")) {
           change(world, title, [&](QJsonObject& row) {
             endRun(row, world.now());
             row.insert(QStringLiteral("pendingRuntimeRequest"), QJsonObject{{QStringLiteral("kind"), QStringLiteral("command_approval")}});
           });
           see(world);
           return;
         }
         change(world, title, [&](QJsonObject& row) { endRun(row, world.now()); });
         see(world);
         advance(world, 1000);
         see(world);
         if (c[0] == QLatin1String("its next run starts")) {
           change(world, title, [&](QJsonObject& row) {
             const QJsonObject next = running(QStringLiteral("r2"), world.now());
             for (auto it = next.begin(); it != next.end(); ++it) row.insert(it.key(), it.value());
             row.remove(QStringLiteral("latestRunCompletedAt"));
           });
         } else if (c[0] == QLatin1String("the MC settles it")) {
           change(world, title, [&](QJsonObject& row) {
             row.insert(QStringLiteral("settledOverride"), QStringLiteral("settled"));
             row.insert(QStringLiteral("settledAt"), iso(world.now()));
           });
         } else {
           advance(world, sidebar::kWorkingExitGraceMs - 1000 - 1);
         }
         see(world);
         advance(world, sidebar::kWorkingExitGraceMs);
         see(world);
       });
  step(QStringLiteral("%1 (never leaves the Working section|moves straight to Settled, never to the inbox|moves to the inbox once the two seconds are up|moves to the inbox at once)").arg(q),
       [](World&, const Captures& c, const Table&) {
         const QStringList& seen = scene().seen;
         const QString shown = seen.join(QStringLiteral(" → "));
         if (c[1].startsWith(QLatin1String("never leaves"))) {
           expect(!seen.isEmpty() && std::all_of(seen.begin(), seen.end(), [](const QString& section) { return section == QLatin1String("working"); }),
                  QStringLiteral("%1 went %2").arg(c[0], shown));
         } else if (c[1].startsWith(QLatin1String("moves straight to Settled"))) {
           expect(!seen.contains(QStringLiteral("active")) && seen.last() == QLatin1String("settled"), QStringLiteral("%1 went %2").arg(c[0], shown));
         } else if (c[1].endsWith(QLatin1String("are up"))) {
           // Working at the end of the run, a second on, and a moment before the two are up.
           expect(seen == QStringList{QStringLiteral("working"), QStringLiteral("working"), QStringLiteral("working"), QStringLiteral("active")},
                  QStringLiteral("%1 went %2").arg(c[0], shown));
         } else {
           expect(seen == QStringList{QStringLiteral("active")}, QStringLiteral("%1 went %2").arg(c[0], shown));
         }
       });

  // The status marker's spoken name.
  step(QStringLiteral("a screen reader reaches a thread's status marker"), [](World& world, const Captures&, const Table&) {
    const QDateTime now = world.now();
    putThread(world, QStringLiteral("Build"), running(QStringLiteral("r-build"), now.addSecs(-60)));
    QJsonObject asking = running(QStringLiteral("r-ask"), now.addSecs(-50));
    asking.insert(QStringLiteral("pendingRuntimeRequest"), QJsonObject{{QStringLiteral("kind"), QStringLiteral("user_input")}});
    putThread(world, QStringLiteral("Ask"), asking);
    QJsonObject approving = running(QStringLiteral("r-approve"), now.addSecs(-40));
    approving.insert(QStringLiteral("pendingRuntimeRequest"), QJsonObject{{QStringLiteral("kind"), QStringLiteral("command_approval")}});
    putThread(world, QStringLiteral("Approve"), approving);
    Brick& list = threadList(world);
    QMetaObject::invokeMethod(list.root(), "toggleSection", Q_ARG(QVariant, QStringLiteral("working")));
  });
  step(QStringLiteral("it announces Working, Awaiting input or Pending approval"), [](World& world, const Captures&, const Table&) {
    Brick& list = threadList(world);
    const QList<std::pair<QString, QString>> expected{{QStringLiteral("Build"), QStringLiteral("Working")},
                                                      {QStringLiteral("Ask"), QStringLiteral("Awaiting input")},
                                                      {QStringLiteral("Approve"), QStringLiteral("Pending approval")}};
    for (const auto& [title, name] : expected) {
      const QString key = threadKeyOf(world, title);
      QString spoken;
      world.waitFor(
          [&] {
            list.grab();
            QQuickItem* row = list.find(QStringLiteral("threadRow:") + key);
            QQuickItem* icon = nullptr;
            if (row) {
              for (QQuickItem* item : row->findChildren<QQuickItem*>()) {
                if (item->objectName() == QLatin1String("statusIcon")) icon = item;
              }
            }
            if (!icon || !icon->isVisible()) return false;
            QQmlExpression expression(qmlContext(icon), icon, QStringLiteral("Accessible.name"));
            spoken = expression.evaluate().toString();
            return spoken == name;
          },
          [&] { return QStringLiteral("%1's status marker to say \"%2\"; it says \"%3\"").arg(title, name, spoken); });
    }
  });
});

}  // namespace
