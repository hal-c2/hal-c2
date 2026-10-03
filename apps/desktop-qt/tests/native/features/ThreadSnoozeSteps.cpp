// Snoozing from the thread's menu and the list, what a row says of its wake
// time, and waking early (features/threads/snooze.feature), plus what the
// list says of a thread's state and order (threads/unread-and-status.feature,
// threads/settle.feature, threads/pinning-and-order.feature).

#include <QJsonArray>
#include <QJsonObject>
#include <QLocale>

#include "Harness.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "ThreadList.h"
#include "World.h"

namespace {

struct ThreadScene {
  // The thread the scenario's last step was about ("it").
  QString subject;
  // The active threads' titles before the scenario's change.
  QStringList orderBefore;
};

ThreadScene& scene(World& world) {
  return world.mc.part<ThreadScene>();
}

QString iso(const QDateTime& time) {
  return time.toUTC().toString(Qt::ISODateWithMs);
}

QString idOf(const QString& key) {
  return key.mid(key.indexOf(QLatin1Char(':')) + 1);
}

QVariantMap sidebar(World& world) {
  return world.state(QStringLiteral("sidebar")).toMap();
}

std::optional<QVariantMap> rowOf(World& world, const QString& key) {
  const QVariantMap state = sidebar(world);
  for (const QString& section : {QStringLiteral("pinned"), QStringLiteral("active"), QStringLiteral("snoozed"), QStringLiteral("settled")}) {
    for (const QVariant& row : state.value(section).toList()) {
      if (row.toMap().value(QStringLiteral("key")) == key) return row.toMap();
    }
  }
  return std::nullopt;
}

QStringList activeTitles(World& world) {
  QStringList titles;
  for (const QVariant& row : sidebar(world).value(QStringLiteral("active")).toList()) titles.append(row.toMap().value(QStringLiteral("title")).toString());
  return titles;
}

// The next time it is `hour:minute` on the day named `day`.
QDateTime nextOn(World& world, const QString& day, int hour, int minute) {
  QDate date = world.now().date();
  for (int step = 0; step < 8; ++step, date = date.addDays(1)) {
    const QDateTime at(date, QTime(hour, minute));
    if (QLocale::c().dayName(date.dayOfWeek()) == day && at > world.now()) return at;
  }
  fail(QStringLiteral("\"%1\" is not a day of the week").arg(day));
}

QVariantList menuItems(World& world) {
  const QVariant menu = world.state(QStringLiteral("menu"));
  expect(menu.typeId() == QMetaType::QVariantMap, QStringLiteral("no menu is open"));
  return at(menu, QStringLiteral("items")).toList();
}

std::optional<QVariantMap> menuItem(World& world, const QString& id) {
  for (const QVariant& entry : menuItems(world)) {
    if (entry.toMap().value(QStringLiteral("id")) == id) return entry.toMap();
  }
  return std::nullopt;
}

void openMenu(World& world, const QString& key) {
  world.sync();
  world.bridge().dispatch(QStringLiteral("thread.menu"), QVariantMap{{QStringLiteral("key"), key}, {QStringLiteral("x"), 40}, {QStringLiteral("y"), 120}});
}

void pick(World& world, const QString& id) {
  const QVariant menu = world.state(QStringLiteral("menu"));
  expect(menu.typeId() == QMetaType::QVariantMap, QStringLiteral("no menu is open"));
  world.bridge().dispatch(QStringLiteral("menu.select"),
                          QVariantMap{{QStringLiteral("requestId"), at(menu, QStringLiteral("requestId"))}, {QStringLiteral("id"), id}});
}

// Snoozes from the thread's menu with the choice the scenario names.
void snoozeWith(World& world, const QString& key, const QString& choice) {
  static const QHash<QString, QString> presets{
      {QStringLiteral("for 1 hour"), QStringLiteral("hour")},       {QStringLiteral("for 3 hours"), QStringLiteral("three-hours")},
      {QStringLiteral("this evening"), QStringLiteral("evening")},  {QStringLiteral("tomorrow"), QStringLiteral("tomorrow")},
      {QStringLiteral("until tomorrow"), QStringLiteral("tomorrow")}, {QStringLiteral("next week"), QStringLiteral("next-week")},
  };
  openMenu(world, key);
  const QString id = QStringLiteral("snooze:") + presets.value(choice);
  const auto snooze = menuItem(world, QStringLiteral("snooze"));
  expect(snooze && snooze->value(QStringLiteral("enabled")).toBool(), QStringLiteral("the menu is %1").arg(show(menuItems(world))));
  bool offered = false;
  for (const QVariant& child : snooze->value(QStringLiteral("children")).toList()) offered |= child.toMap().value(QStringLiteral("id")) == id;
  expect(offered, QStringLiteral("the snooze choices are %1").arg(show(snooze->value(QStringLiteral("children")))));
  pick(world, id);
}

void waitForSection(World& world, const QString& key, const QString& section) {
  world.waitFor([&] { return sidebarSectionOf(world, key) == section; },
                [&] { return QStringLiteral("%1 in %2; it is in \"%3\"").arg(key, section, sidebarSectionOf(world, key)); });
}

void setDevice(World& world, const QString& key, const QJsonValue& value) {
  auto* settings = world.native().controller<SettingsController>();
  QJsonObject device = settings->deviceSettings();
  device.insert(key, value);
  expect(settings->setDeviceSettings(device), QStringLiteral("the preferences were not saved"));
}

// The thread's run `status`, started a quarter of an hour ago.
void setRun(QJsonObject& row, const QString& status, const QDateTime& now) {
  row.insert(QStringLiteral("latestRunId"), QStringLiteral("r1"));
  row.insert(QStringLiteral("status"), status);
  row.insert(QStringLiteral("latestRunStartedAt"), iso(now.addSecs(-900)));
  row.insert(QStringLiteral("updatedAt"), iso(now));
}

QJsonObject request(const QString& kind, const QDateTime& now) {
  return {{QStringLiteral("id"), QStringLiteral("q1")}, {QStringLiteral("kind"), kind}, {QStringLiteral("createdAt"), iso(now)}};
}

const Steps steps([] {
  const QString q = kQuoted;

  // Snoozing.
  step(QStringLiteral("the user snoozes %1 (for 1 hour|for 3 hours|this evening|tomorrow|next week|until tomorrow)").arg(q),
       [](World& world, const Captures& c, const Table&) {
         const QString key = threadKeyOf(world, c[0]);
         scene(world).subject = key;
         // "The next thread in the list" needs one: an older thread beside the one the window shows.
         if (world.mc.threads.size() == 1 && world.native().controller<NavigationController>()->threadKey() == key) {
           QJsonObject next = world.mc.threads.first();
           next.insert(QStringLiteral("id"), QStringLiteral("t-next"));
           next.insert(QStringLiteral("title"), QStringLiteral("Next up"));
           next.insert(QStringLiteral("createdAt"), QStringLiteral("2026-09-23T08:00:00Z"));
           next.insert(QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T08:00:00Z"));
           world.mc.threads.insert(QStringLiteral("t-next"), next);
           world.mc.sendRow(QStringLiteral("t-next"), next);
         }
         snoozeWith(world, key, c[1]);
       });
  step(QStringLiteral("%1 wakes (\\w+day) at (\\d+):(\\d+)").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString key = threadKeyOf(world, c[0]);
    const qint64 expected = nextOn(world, c[1], c[2].toInt(), c[3].toInt()).toMSecsSinceEpoch();
    const auto until = [&] {
      const auto row = rowOf(world, key);
      return row ? QDateTime::fromString(row->value(QStringLiteral("snoozedUntil")).toString(), Qt::ISODateWithMs).toMSecsSinceEpoch() : 0;
    };
    world.waitFor([&] { return sidebarSectionOf(world, key) == QLatin1String("snoozed") && until() == expected; },
                  [&] { return QStringLiteral("%1 snoozed until %2; its row is %3").arg(c[0], iso(QDateTime::fromMSecsSinceEpoch(expected)), show(rowOf(world, key).value_or(QVariantMap()))); });
  });
  step(QStringLiteral("the user opens the snooze choices"), [](World& world, const Captures&, const Table&) {
    world.sync();
    const QString key = world.mc.environmentId + QLatin1Char(':') + world.mc.threads.firstKey();
    world.bridge().dispatch(QStringLiteral("thread.snoozeMenu"), QVariantMap{{QStringLiteral("key"), key}, {QStringLiteral("x"), 200}, {QStringLiteral("y"), 120}});
    expect(!menuItems(world).isEmpty(), QStringLiteral("no snooze choice is offered"));
  });
  step(QStringLiteral("only one choice wakes the thread on (\\w+day) at (\\d+):(\\d+)"), [](World& world, const Captures& c, const Table&) {
    const QDateTime wake = nextOn(world, c[0], c[1].toInt(), c[2].toInt());
    // Each choice names its wake time; the menu lists the presets in order.
    const auto presets = world.native().sidebar()->snoozePresets();
    const QVariantList items = menuItems(world);
    expect(items.size() == presets.size(), QStringLiteral("the menu is %1").arg(show(items)));
    int waking = 0;
    for (qsizetype index = 0; index < presets.size(); ++index) {
      expect(items.at(index).toMap().value(QStringLiteral("id")) == QStringLiteral("snooze:") + presets.at(index).id,
             QStringLiteral("the menu is %1").arg(show(items)));
      if (QDateTime::fromString(presets.at(index).snoozedUntil, Qt::ISODateWithMs).toMSecsSinceEpoch() == wake.toMSecsSinceEpoch()) ++waking;
    }
    expect(waking == 1, QStringLiteral("%1 choices wake the thread then: %2").arg(waking).arg(show(items)));
  });
  step(QStringLiteral("the user prefers a (24-hour|12-hour) clock"), [](World& world, const Captures& c, const Table&) {
    setDevice(world, QStringLiteral("timestampFormat"), c[0]);
  });
  step(QStringLiteral("%1 is snoozed until (\\w+day) (\\d+):(\\d+)").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString key = threadKeyOf(world, c[0]);
    scene(world).subject = key;
    const QString until = iso(nextOn(world, c[1], c[2].toInt(), c[3].toInt()));
    updateThreadRow(world, idOf(key), [&](QJsonObject& row) {
      row.insert(QStringLiteral("snoozedUntil"), until);
      row.insert(QStringLiteral("snoozedAt"), iso(world.now().addSecs(-60)));
    });
  });
  step(QStringLiteral("%1 is snoozed until 20 seconds from now").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString key = threadKeyOf(world, c[0]);
    scene(world).subject = key;
    updateThreadRow(world, idOf(key), [&](QJsonObject& row) {
      row.insert(QStringLiteral("snoozedUntil"), iso(world.now().addSecs(20)));
      row.insert(QStringLiteral("snoozedAt"), iso(world.now().addSecs(-60)));
    });
  });
  step(QStringLiteral("the user looks at the (?:snoozed )?thread"), [](World& world, const Captures&, const Table&) { world.sync(); });
  step(QStringLiteral("the wake time reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const auto row = rowOf(world, scene(world).subject);
    expect(row && row->value(QStringLiteral("wakeDescription")) == c[0], QStringLiteral("the row is %1").arg(show(row.value_or(QVariantMap()))));
  });
  step(QStringLiteral("its wake label reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const auto row = rowOf(world, scene(world).subject);
    expect(row && sidebarSectionOf(world, scene(world).subject) == QLatin1String("snoozed") && row->value(QStringLiteral("wakeLabel")) == c[0],
           QStringLiteral("the row is %1").arg(show(row.value_or(QVariantMap()))));
  });
  step(QStringLiteral("%1 has a turn queued that has not started").arg(q), [](World& world, const Captures& c, const Table&) {
    updateThreadRow(world, idOf(threadKeyOf(world, c[0])), [&](QJsonObject& row) {
      row.insert(QStringLiteral("latestRunId"), QStringLiteral("r1"));
      row.insert(QStringLiteral("status"), QStringLiteral("queued"));
      row.insert(QStringLiteral("latestRunRequestedAt"), iso(world.now()));
    });
  });
  step(QStringLiteral("the user tries to snooze %1").arg(q), [](World& world, const Captures& c, const Table&) {
    scene(world).subject = threadKeyOf(world, c[0]);
    openMenu(world, scene(world).subject);
  });
  step(QStringLiteral("snoozing is unavailable"), [](World& world, const Captures&, const Table&) {
    // Neither the menu nor the row's own action snoozes it.
    const auto snooze = menuItem(world, QStringLiteral("snooze"));
    const auto row = rowOf(world, scene(world).subject);
    expect(snooze && !snooze->value(QStringLiteral("enabled")).toBool(), QStringLiteral("the menu is %1").arg(show(menuItems(world))));
    expect(row && !row->value(QStringLiteral("canSnooze")).toBool(), QStringLiteral("the row is %1").arg(show(row.value_or(QVariantMap()))));
  });
  step(QStringLiteral("%1 is snoozed").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForSection(world, threadKeyOf(world, c[0]), QStringLiteral("snoozed"));
  });

  // Waking early: what the MC's row says once the thread needs the user.
  step(QStringLiteral("(the agent asks for an approval|the agent asks the user a question|the agent run fails|a run that started after the snooze finishes)"),
       [](World& world, const Captures& c, const Table&) {
         const QString id = world.mc.threads.firstKey();
         scene(world).subject = world.mc.environmentId + QLatin1Char(':') + id;
         const QDateTime now = world.now();
         updateThreadRow(world, id, [&](QJsonObject& row) {
           if (c[0].startsWith(QLatin1String("the agent asks"))) {
             setRun(row, QStringLiteral("running"), now);
             row.insert(QStringLiteral("activeRunId"), QStringLiteral("r1"));
             row.insert(QStringLiteral("pendingRuntimeRequest"),
                        request(c[0].endsWith(QLatin1String("question")) ? QStringLiteral("user_input") : QStringLiteral("command_approval"), now));
           } else if (c[0] == QLatin1String("the agent run fails")) {
             setRun(row, QStringLiteral("failed"), now);
           } else {
             setRun(row, QStringLiteral("completed"), now);
             row.insert(QStringLiteral("latestRunCompletedAt"), iso(now));
           }
         });
       });
  step(QStringLiteral("it is marked as woke"), [](World& world, const Captures&, const Table&) {
    const auto row = rowOf(world, scene(world).subject);
    expect(row && row->value(QStringLiteral("wokeAt")).typeId() == QMetaType::QString, QStringLiteral("the row is %1").arg(show(row.value_or(QVariantMap()))));
  });

  // Failures and where the window goes.
  step(QStringLiteral("the environment rejects the snooze"), [](World& world, const Captures&, const Table&) {
    world.mc.refusals.insert(QStringLiteral("thread.snooze"), QStringLiteral("The thread cannot be snoozed"));
  });
  step(QStringLiteral("%1 stays active").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    const QString section = sidebarSectionOf(world, threadKeyOf(world, c[0]));
    expect(section == QLatin1String("active"), QStringLiteral("%1 is in \"%2\"").arg(c[0], section));
  });
  step(QStringLiteral("the next thread in the list opens"), [](World& world, const Captures&, const Table&) {
    const QString snoozed = scene(world).subject;
    world.waitFor([&] {
      const QString open = world.native().controller<NavigationController>()->threadKey();
      return !open.isEmpty() && open != snoozed && sidebarSectionOf(world, open) == QLatin1String("active");
    }, [&] { return QStringLiteral("another thread to open; the route is %1").arg(show(world.state(QStringLiteral("route")))); });
  });
  step(QStringLiteral("the user can undo the snooze"), [](World& world, const Captures&, const Table&) {
    const QString snoozed = scene(world).subject;
    waitForSection(world, snoozed, QStringLiteral("snoozed"));
    QVariantMap toast;
    for (const QVariant& item : world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList()) {
      if (item.toMap().value(QStringLiteral("title")).toString().startsWith(QLatin1String("Snoozed until"))) toast = item.toMap();
    }
    const QVariantList actions = toast.value(QStringLiteral("actions")).toList();
    expect(actions.size() == 1 && actions.first().toMap().value(QStringLiteral("label")) == QLatin1String("Undo"),
           QStringLiteral("the shell shows %1").arg(show(world.state(QStringLiteral("toasts")))));
    world.bridge().dispatch(QStringLiteral("notification.action"),
                            QVariantMap{{QStringLiteral("id"), toast.value(QStringLiteral("id"))}, {QStringLiteral("actionId"), actions.first().toMap().value(QStringLiteral("id"))}});
    waitForSection(world, snoozed, QStringLiteral("active"));
  });

  // Settling.
  step(QStringLiteral("%1 is settled and no longer (pinned|snoozed)").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString key = threadKeyOf(world, c[0]);
    waitForSection(world, key, QStringLiteral("settled"));
    const auto row = rowOf(world, key);
    const bool cleared = c[1] == QLatin1String("pinned") ? !row->value(QStringLiteral("pinned")).toBool()
                                                         : row->value(QStringLiteral("snoozedUntil")).typeId() != QMetaType::QString;
    expect(cleared, QStringLiteral("the row is %1").arg(show(*row)));
  });

  // What a row and a project say.
  step(QStringLiteral("%1 has an agent working and is waiting for an approval").arg(q), [](World& world, const Captures& c, const Table&) {
    updateThreadRow(world, idOf(threadKeyOf(world, c[0])), [&](QJsonObject& row) {
      setRun(row, QStringLiteral("running"), world.now());
      row.insert(QStringLiteral("activeRunId"), QStringLiteral("r1"));
      row.insert(QStringLiteral("pendingRuntimeRequest"), request(QStringLiteral("command_approval"), world.now()));
    });
  });
  step(QStringLiteral("one thread in %1 is working and another is waiting for an approval").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString first = world.mc.threads.firstKey();
    expect(world.mc.threads.value(first).value(QLatin1String("projectId")) == c[0], QStringLiteral("the thread is not in %1").arg(c[0]));
    updateThreadRow(world, first, [&](QJsonObject& row) {
      setRun(row, QStringLiteral("running"), world.now());
      row.insert(QStringLiteral("activeRunId"), QStringLiteral("r1"));
    });
    QJsonObject other = world.mc.threads.value(first);
    other.insert(QStringLiteral("id"), QStringLiteral("t-approval"));
    other.insert(QStringLiteral("title"), QStringLiteral("Needs approval"));
    other.insert(QStringLiteral("pendingRuntimeRequest"), request(QStringLiteral("command_approval"), world.now()));
    world.mc.threads.insert(QStringLiteral("t-approval"), other);
    world.mc.sendRow(QStringLiteral("t-approval"), other);
    world.sync();
  });
  step(QStringLiteral("the user looks at the project %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    scene(world).subject = world.projectKey(c[0]);
  });
  step(QStringLiteral("the project shows that a thread needs an approval"), [](World& world, const Captures&, const Table&) {
    // Sidebar.qml names the state beside the project in its scope menu.
    for (const QVariant& project : sidebar(world).value(QStringLiteral("projects")).toList()) {
      if (project.toMap().value(QStringLiteral("key")) != scene(world).subject) continue;
      expect(project.toMap().value(QStringLiteral("status")) == QLatin1String("approval"), QStringLiteral("the project is %1").arg(show(project)));
      return;
    }
    fail(QStringLiteral("the projects are %1").arg(show(sidebar(world).value(QStringLiteral("projects")))));
  });
  step(QStringLiteral("the agent has been working in %1 for (\\d+) minutes").arg(q), [](World& world, const Captures& c, const Table&) {
    scene(world).subject = threadKeyOf(world, c[0]);
    updateThreadRow(world, idOf(scene(world).subject), [&](QJsonObject& row) {
      setRun(row, QStringLiteral("running"), world.now());
      row.insert(QStringLiteral("activeRunId"), QStringLiteral("r1"));
      row.insert(QStringLiteral("latestRunStartedAt"), iso(world.now().addSecs(-60 * c[1].toInt() - 20)));
    });
  });
  step(QStringLiteral("the thread shows it has been working for (\\d+) minutes"), [](World& world, const Captures& c, const Table&) {
    // SidebarThreadRow.qml reads "Working 3m".
    const auto row = rowOf(world, scene(world).subject);
    expect(row && row->value(QStringLiteral("status")) == QLatin1String("working") && row->value(QStringLiteral("workingLabel")) == c[0] + QLatin1Char('m'),
           QStringLiteral("the row is %1").arg(show(row.value_or(QVariantMap()))));
  });
  step(QStringLiteral("%1 is read").arg(q), [](World& world, const Captures& c, const Table&) {
    projectThreadCommands(world);
    updateThreadRow(world, idOf(threadKeyOf(world, c[0])), [&](QJsonObject& row) {
      setRun(row, QStringLiteral("completed"), world.now().addSecs(-600));
      row.insert(QStringLiteral("latestRunCompletedAt"), iso(world.now().addSecs(-600)));
      row.insert(QStringLiteral("lastVisitedAt"), iso(world.now().addSecs(-300)));
    });
    const auto row = rowOf(world, threadKeyOf(world, c[0]));
    expect(row && !row->value(QStringLiteral("unread")).toBool(), QStringLiteral("the row is %1").arg(show(row.value_or(QVariantMap()))));
  });

  // The order of the active threads.
  step(QStringLiteral("the user arranged the active threads by hand"), [](World& world, const Captures&, const Table&) {
    world.sync();
    int place = 0;
    for (const QVariant& row : sidebar(world).value(QStringLiteral("active")).toList()) {
      updateThreadRow(world, row.toMap().value(QStringLiteral("threadId")).toString(), [&](QJsonObject& fields) {
        fields.insert(QStringLiteral("activeOrderKey"), QStringLiteral("a%1").arg(place++));
      });
    }
    scene(world).orderBefore = activeTitles(world);
  });
  step(QStringLiteral("a new thread %1 is created").arg(q), [](World& world, const Captures& c, const Table&) {
    QJsonObject row{{QStringLiteral("id"), QStringLiteral("t-new")}, {QStringLiteral("title"), c[0]},
                    {QStringLiteral("projectId"), world.mc.threads.first().value(QLatin1String("projectId"))},
                    {QStringLiteral("createdAt"), iso(world.now())}, {QStringLiteral("updatedAt"), iso(world.now())}};
    world.mc.threads.insert(QStringLiteral("t-new"), row);
    world.mc.sendRow(QStringLiteral("t-new"), row);
    world.sync();
  });
  step(QStringLiteral("%1 is listed above the arranged threads").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(activeTitles(world) == QStringList{c[0]} + scene(world).orderBefore,
           QStringLiteral("the active threads are %1").arg(activeTitles(world).join(QStringLiteral(", "))));
  });
  step(QStringLiteral("the agent finishes work in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    scene(world).orderBefore = activeTitles(world);
    updateThreadRow(world, idOf(threadKeyOf(world, c[0])), [&](QJsonObject& row) {
      setRun(row, QStringLiteral("completed"), world.now());
      row.insert(QStringLiteral("latestRunCompletedAt"), iso(world.now()));
      row.insert(QStringLiteral("latestUserMessageAt"), iso(world.now().addSecs(-60)));
    });
  });
  step(QStringLiteral("the order of the active threads does not change"), [](World& world, const Captures&, const Table&) {
    expect(activeTitles(world) == scene(world).orderBefore,
           QStringLiteral("the active threads are %1").arg(activeTitles(world).join(QStringLiteral(", "))));
  });
  step(QStringLiteral("%1 is the second active thread( again)?").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return activeTitles(world).value(1) == c[0]; },
                  [&] { return QStringLiteral("%1 second; the active threads are %2").arg(c[0], activeTitles(world).join(QStringLiteral(", "))); });
  });
  step(QStringLiteral("the user pins and then unpins %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString key = threadKeyOf(world, c[0]);
    openMenu(world, key);
    pick(world, QStringLiteral("pin"));
    waitForSection(world, key, QStringLiteral("pinned"));
    openMenu(world, key);
    pick(world, QStringLiteral("unpin"));
  });
});

}  // namespace
