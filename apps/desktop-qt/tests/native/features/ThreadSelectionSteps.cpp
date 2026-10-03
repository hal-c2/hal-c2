// Selecting several threads in the list and acting on all of them from the
// selection's menu (features/threads/menu-and-selection.feature, and the
// bulk scenarios of threads/archive-delete.feature, threads/snooze.feature,
// threads/titles.feature and threads/unread-and-status.feature). The clicks
// that select (Ctrl/Cmd and Shift) are SidebarThreadRow.qml's.

#include <QJsonArray>
#include <QJsonObject>
#include <QRegularExpression>

#include "Harness.h"
#include "ThreadList.h"
#include "World.h"

namespace {

struct Selection {
  // The threads the scenario selected, by title.
  QStringList titles;
  int made = 0;
};

Selection& scene(World& world) {
  return world.mc.part<Selection>();
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

// The project the Background's thread is in.
QString project(World& world) {
  return world.mc.threads.first().value(QLatin1String("projectId")).toString();
}

bool exists(World& world, const QString& title) {
  for (const QJsonObject& row : std::as_const(world.mc.threads)) {
    if (row.value(QLatin1String("title")) == title) return true;
  }
  return false;
}

// Threads newer than the Background's, the first of `titles` on top.
void addThreads(World& world, const QStringList& titles, const QJsonObject& fields = {}) {
  projectThreadCommands(world);
  const QString projectId = project(world);
  for (qsizetype index = 0; index < titles.size(); ++index) {
    if (exists(world, titles.at(index))) continue;
    const QString id = QStringLiteral("t-sel-%1").arg(++scene(world).made);
    const QString at = iso(world.now().addSecs(60 * int(titles.size() - index)));
    QJsonObject row = fields;
    row.insert(QStringLiteral("id"), id);
    row.insert(QStringLiteral("title"), titles.at(index));
    row.insert(QStringLiteral("projectId"), projectId);
    row.insert(QStringLiteral("createdAt"), at);
    row.insert(QStringLiteral("updatedAt"), at);
    world.mc.threads.insert(id, row);
    world.mc.sendRow(id, row);
  }
  world.sync();
}

void select(World& world, const QStringList& titles) {
  world.bridge().dispatch(QStringLiteral("thread.select.clear"), QVariantMap());
  for (const QString& title : titles) {
    world.bridge().dispatch(QStringLiteral("thread.select.toggle"), QVariantMap{{QStringLiteral("key"), threadKeyOf(world, title)}});
  }
  scene(world).titles = titles;
}

QStringList selectedTitles(World& world) {
  QStringList titles;
  for (const QVariant& key : sidebar(world).value(QStringLiteral("selectedKeys")).toList()) {
    const auto row = rowOf(world, key.toString());
    // The row says so too: SidebarThreadRow.qml highlights it.
    expect(row && row->value(QStringLiteral("selected")).toBool(), QStringLiteral("the row of %1 is %2").arg(key.toString(), show(row.value_or(QVariantMap()))));
    titles.append(row->value(QStringLiteral("title")).toString());
  }
  return titles;
}

QStringList quoted(const QString& text) {
  QStringList names;
  auto matches = QRegularExpression(kQuoted).globalMatch(text);
  while (matches.hasNext()) names.append(matches.next().captured(1));
  return names;
}

QVariantList menuItems(World& world) {
  const QVariant menu = world.state(QStringLiteral("menu"));
  return menu.typeId() == QMetaType::QVariantMap ? at(menu, QStringLiteral("items")).toList() : QVariantList();
}

std::optional<QVariantMap> menuItem(World& world, const QString& id) {
  for (const QVariant& entry : menuItems(world)) {
    if (entry.toMap().value(QStringLiteral("id")) == id) return entry.toMap();
  }
  return std::nullopt;
}

// The menu of one of the selected threads, which is the selection's.
void openMenu(World& world, const QString& title = {}) {
  world.sync();
  const QString key = threadKeyOf(world, title.isEmpty() ? scene(world).titles.first() : title);
  world.bridge().dispatch(QStringLiteral("thread.menu"), QVariantMap{{QStringLiteral("key"), key}, {QStringLiteral("x"), 40}, {QStringLiteral("y"), 120}});
  expect(!menuItems(world).isEmpty(), QStringLiteral("no menu opened"));
}

void pick(World& world, const QString& id) {
  const QVariant menu = world.state(QStringLiteral("menu"));
  world.bridge().dispatch(QStringLiteral("menu.select"),
                          QVariantMap{{QStringLiteral("requestId"), at(menu, QStringLiteral("requestId"))}, {QStringLiteral("id"), id}});
}

void answer(World& world, bool accepted) {
  const QVariant question = world.state(QStringLiteral("confirmation"));
  expect(question.typeId() == QMetaType::QVariantMap, QStringLiteral("no question is asked"));
  world.bridge().dispatch(QStringLiteral("confirmation.answer"),
                          QVariantMap{{QStringLiteral("requestId"), at(question, QStringLiteral("requestId"))}, {QStringLiteral("accepted"), accepted}});
}

// The selection's menu item `id` names `count` threads, as "Settle (2)".
void expectCounted(World& world, const QString& id, int count) {
  const auto item = menuItem(world, id);
  expect(item && item->value(QStringLiteral("enabled")).toBool() && item->value(QStringLiteral("label")).toString().endsWith(QStringLiteral(" (%1)").arg(count)),
         QStringLiteral("the menu is %1").arg(show(menuItems(world))));
}

const QStringList kThree{QStringLiteral("One"), QStringLiteral("Two"), QStringLiteral("Three")};

bool gone(World& world, const QString& title) {
  if (exists(world, title)) return false;
  for (const QString& section : {QStringLiteral("pinned"), QStringLiteral("active"), QStringLiteral("snoozed"), QStringLiteral("settled")}) {
    for (const QVariant& row : sidebar(world).value(section).toList()) {
      if (row.toMap().value(QStringLiteral("title")) == title) return false;
    }
  }
  return true;
}

const Steps steps([] {
  const QString q = kQuoted;

  // Selecting.
  step(QStringLiteral("the threads %1, %1, %1 and %1 are listed in that order").arg(q), [](World& world, const Captures& c, const Table&) {
    addThreads(world, {c[0], c[1], c[2], c[3]});
    QStringList top;
    for (const QVariant& row : sidebar(world).value(QStringLiteral("active")).toList().mid(0, 4)) top.append(row.toMap().value(QStringLiteral("title")).toString());
    expect(top == QStringList{c[0], c[1], c[2], c[3]}, QStringLiteral("the list starts %1").arg(top.join(QStringLiteral(", "))));
  });
  step(QStringLiteral("the user adds %1 and then %1 to the selection").arg(q), [](World& world, const Captures& c, const Table&) {
    for (const QString& title : {c[0], c[1]}) {
      world.bridge().dispatch(QStringLiteral("thread.select.toggle"), QVariantMap{{QStringLiteral("key"), threadKeyOf(world, title)}});
    }
  });
  step(QStringLiteral("the user selects %1 and then extends the range to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("thread.select.toggle"), QVariantMap{{QStringLiteral("key"), threadKeyOf(world, c[0])}});
    world.bridge().dispatch(QStringLiteral("thread.select.range"), QVariantMap{{QStringLiteral("key"), threadKeyOf(world, c[1])}});
  });
  // A Given selects them (among "A" to "D"); a Then checks the selection.
  step(QStringLiteral("(\"[^\"]*\"(?:, \"[^\"]*\")* and \"[^\"]*\") are selected"), [](World& world, const Captures& c, const Table&) {
    const QStringList titles = quoted(c[0]);
    if (!world.checking) {
      addThreads(world, {QStringLiteral("A"), QStringLiteral("B"), QStringLiteral("C"), QStringLiteral("D")});
      select(world, titles);
    }
    expect(selectedTitles(world) == titles, QStringLiteral("the selection is %1").arg(selectedTitles(world).join(QStringLiteral(", "))));
  });
  step(QStringLiteral("%1 and %1 are selected and only %1 is pinned").arg(q), [](World& world, const Captures& c, const Table&) {
    addThreads(world, {QStringLiteral("A"), QStringLiteral("B"), QStringLiteral("C"), QStringLiteral("D")});
    updateThreadRow(world, idOf(threadKeyOf(world, c[2])), [](QJsonObject& row) {
      row.insert(QStringLiteral("pinnedAt"), QStringLiteral("2026-09-23T09:30:00Z"));
      row.insert(QStringLiteral("pinOrderKey"), QStringLiteral("a0"));
    });
    select(world, {c[0], c[1]});
  });
  step(QStringLiteral("%1 and %1 are selected and the agent is working in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    addThreads(world, {QStringLiteral("A"), QStringLiteral("B"), QStringLiteral("C"), QStringLiteral("D")});
    updateThreadRow(world, idOf(threadKeyOf(world, c[2])), [](QJsonObject& row) {
      row.insert(QStringLiteral("latestRunId"), QStringLiteral("r1"));
      row.insert(QStringLiteral("activeRunId"), QStringLiteral("r1"));
      row.insert(QStringLiteral("status"), QStringLiteral("running"));
    });
    select(world, {c[0], c[1]});
  });
  step(QStringLiteral("the user clears the selection"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("thread.select.clear"), QVariantMap());
  });
  step(QStringLiteral("the user scopes the list to another project"), [](World& world, const Captures&, const Table&) {
    QString other;
    for (const QVariant& entry : sidebar(world).value(QStringLiteral("projects")).toList()) {
      if (entry.toMap().value(QStringLiteral("projectId")) != project(world)) other = entry.toMap().value(QStringLiteral("key")).toString();
    }
    expect(!other.isEmpty(), QStringLiteral("there is no other project"));
    world.bridge().dispatch(QStringLiteral("sidebar.scope"), QVariantMap{{QStringLiteral("projectKey"), other}});
  });
  step(QStringLiteral("no thread is selected"), [](World& world, const Captures&, const Table&) {
    expect(sidebar(world).value(QStringLiteral("selectedKeys")).toList().isEmpty(), QStringLiteral("the selection is %1").arg(selectedTitles(world).join(QStringLiteral(", "))));
  });
  step(QStringLiteral("%1 stays selected").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(selectedTitles(world) == QStringList{c[0]}, QStringLiteral("the selection is %1").arg(selectedTitles(world).join(QStringLiteral(", "))));
  });

  // The selection's menu.
  step(QStringLiteral("the user opens the menu for the selection"), [](World& world, const Captures&, const Table&) { openMenu(world); });
  step(QStringLiteral("unpinning is offered for (\\d+) threads?"), [](World& world, const Captures& c, const Table&) {
    expectCounted(world, QStringLiteral("unpin"), c[0].toInt());
  });
  step(QStringLiteral("settling, snoozing, marking unread and deleting are offered for (\\d+) threads"), [](World& world, const Captures& c, const Table&) {
    for (const QString& id : {QStringLiteral("settle"), QStringLiteral("snooze"), QStringLiteral("mark-unread"), QStringLiteral("delete")}) {
      expectCounted(world, id, c[0].toInt());
    }
  });
  step(QStringLiteral("archiving the selection is unavailable"), [](World& world, const Captures&, const Table&) {
    const auto archive = menuItem(world, QStringLiteral("archive"));
    expect(archive && !archive->value(QStringLiteral("enabled")).toBool() && archive->value(QStringLiteral("label")) == QLatin1String("Archive (2)"),
           QStringLiteral("the menu is %1").arg(show(menuItems(world))));
  });
  step(QStringLiteral("the user chooses to (settle|snooze|delete) from the menu of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    openMenu(world, c[1]);
    if (c[0] == QLatin1String("snooze")) {
      const auto snooze = menuItem(world, QStringLiteral("snooze"));
      expect(snooze.has_value(), QStringLiteral("the menu is %1").arg(show(menuItems(world))));
      pick(world, snooze->value(QStringLiteral("children")).toList().first().toMap().value(QStringLiteral("id")).toString());
      return;
    }
    pick(world, c[0]);
    if (c[0] == QLatin1String("delete")) answer(world, true);
  });
  step(QStringLiteral("%1 and %1 are (settled|snoozed|deleted)").arg(q), [](World& world, const Captures& c, const Table&) {
    for (const QString& title : {c[0], c[1]}) {
      if (c[2] == QLatin1String("deleted")) {
        world.waitFor([&] { return gone(world, title); }, [&] { return QStringLiteral("%1 to be deleted").arg(title); });
        continue;
      }
      const QString key = threadKeyOf(world, title);
      world.waitFor([&] { return sidebarSectionOf(world, key) == c[2]; },
                    [&] { return QStringLiteral("%1 %2; it is in \"%3\"").arg(title, c[2], sidebarSectionOf(world, key)); });
    }
  });

  // Deleting.
  step(QStringLiteral("deleting %1 fails").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.refusals.insert(QStringLiteral("thread.delete:") + idOf(threadKeyOf(world, c[0])), QStringLiteral("The thread is locked"));
  });
  step(QStringLiteral("the user deletes the selection"), [](World& world, const Captures&, const Table&) {
    openMenu(world);
    pick(world, QStringLiteral("delete"));
    // The question is the scenario's to answer when it asks about it.
    if (scene(world).titles != kThree) answer(world, true);
  });
  step(QStringLiteral("%1 is deleted").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return gone(world, c[0]); }, [&] { return QStringLiteral("%1 to be deleted").arg(c[0]); });
  });
  step(QStringLiteral("all three threads are deleted after confirming"), [](World& world, const Captures&, const Table&) {
    for (const QString& title : kThree) expect(exists(world, title), QStringLiteral("%1 was deleted before the user confirmed").arg(title));
    answer(world, true);
    for (const QString& title : kThree) {
      world.waitFor([&] { return gone(world, title); }, [&] { return QStringLiteral("%1 to be deleted").arg(title); });
    }
  });

  // Three threads, selected.
  step(QStringLiteral("the user has selected three threads"), [](World& world, const Captures&, const Table&) {
    addThreads(world, kThree);
    select(world, kThree);
  });
  step(QStringLiteral("the user has selected three threads and one cannot be snoozed"), [](World& world, const Captures&, const Table&) {
    addThreads(world, kThree);
    select(world, kThree);
    world.mc.refusals.insert(QStringLiteral("thread.snooze:") + idOf(threadKeyOf(world, kThree.last())), QStringLiteral("The thread has a queued run"));
  });
  step(QStringLiteral("the user has selected three threads, one of which is already regenerating"), [](World& world, const Captures&, const Table&) {
    addThreads(world, kThree);
    updateThreadRow(world, idOf(threadKeyOf(world, kThree.last())), [](QJsonObject& row) {
      row.insert(QStringLiteral("titleRegeneration"), QJsonObject{{QStringLiteral("requestId"), QStringLiteral("c1")}, {QStringLiteral("startedAt"), QStringLiteral("2026-09-23T09:59:00Z")}});
    });
    select(world, kThree);
  });
  step(QStringLiteral("the user has selected three read threads"), [](World& world, const Captures&, const Table&) {
    const QString completed = iso(world.now().addSecs(-600));
    addThreads(world, kThree, {{QStringLiteral("latestRunId"), QStringLiteral("r1")}, {QStringLiteral("status"), QStringLiteral("completed")},
                               {QStringLiteral("latestRunCompletedAt"), completed}, {QStringLiteral("lastVisitedAt"), iso(world.now().addSecs(-300))}});
    select(world, kThree);
    for (const QString& title : kThree) {
      expect(!rowOf(world, threadKeyOf(world, title))->value(QStringLiteral("unread")).toBool(), QStringLiteral("%1 is unread").arg(title));
    }
  });

  // Snoozing, titles, unread.
  step(QStringLiteral("the user snoozes the selection until tomorrow"), [](World& world, const Captures&, const Table&) {
    openMenu(world);
    const auto snooze = menuItem(world, QStringLiteral("snooze"));
    expect(snooze && snooze->value(QStringLiteral("label")) == QLatin1String("Snooze (3)"), QStringLiteral("the menu is %1").arg(show(menuItems(world))));
    pick(world, QStringLiteral("snooze:tomorrow"));
  });
  step(QStringLiteral("all three threads are snoozed until Thursday at 09:00"), [](World& world, const Captures&, const Table&) {
    const qint64 thursday = QDateTime(QDate(2026, 9, 24), QTime(9, 0)).toMSecsSinceEpoch();
    for (const QString& title : kThree) {
      const QString key = threadKeyOf(world, title);
      world.waitFor([&] {
        const auto row = rowOf(world, key);
        return row && sidebarSectionOf(world, key) == QLatin1String("snoozed") &&
               QDateTime::fromString(row->value(QStringLiteral("snoozedUntil")).toString(), Qt::ISODateWithMs).toMSecsSinceEpoch() == thursday;
      }, [&] { return QStringLiteral("%1 snoozed until Thursday; its row is %2").arg(title, show(rowOf(world, key).value_or(QVariantMap()))); });
    }
  });
  step(QStringLiteral("two threads are snoozed"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return sidebar(world).value(QStringLiteral("snoozed")).toList().size() == 2; },
                  [&] { return QStringLiteral("two snoozed threads; the list is %1").arg(show(sidebar(world).value(QStringLiteral("snoozed")))); });
    world.sync();
    expect(sidebarSectionOf(world, threadKeyOf(world, kThree.last())) == QLatin1String("active"), QStringLiteral("the refused thread is not active"));
  });
  step(QStringLiteral("the user regenerates titles for the selection"), [](World& world, const Captures&, const Table&) {
    openMenu(world);
    const auto regenerate = menuItem(world, QStringLiteral("regenerate-title"));
    expect(regenerate && regenerate->value(QStringLiteral("label")) == QLatin1String("Regenerate titles (2)"), QStringLiteral("the menu is %1").arg(show(menuItems(world))));
    pick(world, QStringLiteral("regenerate-title"));
  });
  step(QStringLiteral("titles are regenerated for the two eligible threads"), [](World& world, const Captures&, const Table&) {
    world.sync();
    QStringList asked;
    for (const QJsonObject& command : std::as_const(world.mc.commands)) {
      if (command.value(QLatin1String("type")) == QLatin1String("thread.metadata.update") && command.value(QLatin1String("regenerateTitle")).toBool()) {
        asked.append(command.value(QLatin1String("threadId")).toString());
      }
    }
    asked.sort();
    QStringList eligible{idOf(threadKeyOf(world, kThree.at(0))), idOf(threadKeyOf(world, kThree.at(1)))};
    eligible.sort();
    expect(asked == eligible, QStringLiteral("the MC has %1").arg(world.describeCommands()));
  });
  step(QStringLiteral("the user marks the selection unread"), [](World& world, const Captures&, const Table&) {
    openMenu(world);
    expectCounted(world, QStringLiteral("mark-unread"), 3);
    pick(world, QStringLiteral("mark-unread"));
  });
  step(QStringLiteral("all three threads are unread"), [](World& world, const Captures&, const Table&) {
    for (const QString& title : kThree) {
      const QString key = threadKeyOf(world, title);
      world.waitFor([&] { return rowOf(world, key).value_or(QVariantMap()).value(QStringLiteral("unread")).toBool(); },
                    [&] { return QStringLiteral("%1 to be unread; its row is %2").arg(title, show(rowOf(world, key).value_or(QVariantMap()))); });
    }
  });
});

}  // namespace
