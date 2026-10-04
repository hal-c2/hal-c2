// The thread menu (ThreadMenuController) and the MC's side of its actions:
// features/threads/menu-actions.feature, and the thread menu's
// scenarios in threads/menu-and-selection.feature, threads/archive-delete.feature,
// threads/pinning-and-order.feature, threads/titles.feature and
// threads/creating.feature.

#include <QJsonArray>
#include <QJsonObject>

#include "FilesViewer.h"
#include "Harness.h"
#include "MenuController.h"
#include "Move.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "ThreadList.h"
#include "ThreadMenuController.h"
#include "Turn.h"
#include "World.h"
#include "WorkspaceController.h"

namespace {

// What the MC does with the menu's commands and moves.
struct FakeThreadMenu {
  // Whether the MC's rows follow the thread commands it accepts, as the real
  // projection does; scenarios about the list turn it on.
  bool project = false;
  // hal-c2.moveDestinations' answer, and how hal-c2.moveThread answers.
  QJsonArray destinations;
  QString confirmNote;  // asked once before a move that is not confirmed
  QString refusal;
  QList<QJsonObject> moves;
  // The section each thread was in before the scenario's change.
  QHash<QString, QString> sectionBefore;
  bool confirmAsked = false;  // the scenario turned the question on itself
};

void projectCommand(FakeMc& mc, const QJsonObject& command) {
  if (!mc.part<FakeThreadMenu>().project) return;
  const QString type = command.value(QLatin1String("type")).toString();
  const QString id = command.value(QLatin1String("threadId")).toString();
  if (!mc.threads.contains(id)) return;
  QJsonObject& row = mc.threads[id];
  const QString now = QStringLiteral("2026-09-23T10:00:00Z");
  if (type == QLatin1String("thread.pin")) {
    row.insert(QStringLiteral("pinnedAt"), now);
    row.insert(QStringLiteral("pinOrderKey"), command.value(QLatin1String("orderKey")).toString(QStringLiteral("a0")));
  } else if (type == QLatin1String("thread.unpin")) {
    row.remove(QStringLiteral("pinnedAt"));
    row.remove(QStringLiteral("pinOrderKey"));
  } else if (type == QLatin1String("thread.settle")) {
    row.insert(QStringLiteral("settledOverride"), QStringLiteral("settled"));
    row.insert(QStringLiteral("settledAt"), now);
    // Settling clears the thread's pinned and active places (orchestration.ex),
    // and its snooze, as the Node server's projector does.
    for (const char* key : {"pinnedAt", "pinOrderKey", "activeOrderKey", "snoozedUntil", "snoozedAt"}) row.remove(QLatin1String(key));
  } else if (type == QLatin1String("thread.mark-unread")) {
    // Just before the latest run completed, as the Node server's projector.
    const QDateTime completed = QDateTime::fromString(row.value(QLatin1String("latestRunCompletedAt")).toString(), Qt::ISODateWithMs);
    row.insert(QStringLiteral("lastVisitedAt"), completed.addMSecs(-1).toUTC().toString(Qt::ISODateWithMs));
  } else if (type == QLatin1String("thread.active.reorder")) {
    row.insert(QStringLiteral("activeOrderKey"), command.value(QLatin1String("orderKey")));
  } else if (type == QLatin1String("thread.pin.reorder")) {
    row.insert(QStringLiteral("pinOrderKey"), command.value(QLatin1String("orderKey")));
  } else if (type == QLatin1String("thread.unsettle")) {
    row.remove(QStringLiteral("settledOverride"));
    row.remove(QStringLiteral("settledAt"));
    row.insert(QStringLiteral("unsettledAt"), now);
  } else if (type == QLatin1String("thread.visit")) {
    row.insert(QStringLiteral("lastVisitedAt"), command.value(QLatin1String("visitedAt")).toString(now));
  } else if (type == QLatin1String("thread.snooze")) {
    row.insert(QStringLiteral("snoozedUntil"), command.value(QLatin1String("snoozedUntil")));
    row.insert(QStringLiteral("snoozedAt"), now);
  } else if (type == QLatin1String("thread.unsnooze")) {
    row.remove(QStringLiteral("snoozedUntil"));
  } else if (type == QLatin1String("thread.archive")) {
    row.insert(QStringLiteral("archivedAt"), now);
  } else if (type == QLatin1String("thread.unarchive")) {
    row.remove(QStringLiteral("archivedAt"));
  } else if (type == QLatin1String("thread.delete")) {
    QJsonObject gone = mc.threads.take(id);
    gone.insert(QStringLiteral("deletedAt"), now);
    mc.sendRow(id, gone);
    return;
  } else {
    return;
  }
  mc.sendRow(id, row);
}

const FakeMc::Extension threadMenu([](FakeMc& mc) {
  mc.effects.append([&mc](const QJsonObject& command) { projectCommand(mc, command); });
  // threads/moving-between-machines.feature's cluster answers for itself.
  mc.onRpc(QStringLiteral("hal-c2.moveDestinations"), [&mc](const FakeMc::Rpc& rpc) {
    if (answerMachineMove(mc, rpc)) return;
    mc.reply(rpc, mc.part<FakeThreadMenu>().destinations);
  });
  mc.onRpc(QStringLiteral("hal-c2.moveThread"), [&mc](const FakeMc::Rpc& rpc) {
    if (answerMachineMove(mc, rpc)) return;
    FakeThreadMenu& fake = mc.part<FakeThreadMenu>();
    fake.moves.append(rpc.payload);
    if (!fake.refusal.isEmpty()) return mc.refuse(rpc, fake.refusal);
    if (!fake.confirmNote.isEmpty() && !rpc.payload.value(QLatin1String("confirmed")).toBool()) {
      return mc.reply(rpc, QJsonObject{{QStringLiteral("status"), QStringLiteral("confirm")},
                                         {QStringLiteral("message"), QStringLiteral("Confirm the move")},
                                         {QStringLiteral("notes"), QJsonArray{fake.confirmNote}}});
    }
    const QString id = rpc.payload.value(QLatin1String("threadId")).toString();
    // A move names its destination by environment id; the MC answers with the machine's label.
    const QString environment = rpc.payload.value(QLatin1String("machine")).toString();
    const QString machine = mc.peers.value(environment, environment);
    const QString title = mc.threads.value(id).value(QLatin1String("title")).toString();
    mc.reply(rpc, QJsonObject{{QStringLiteral("status"), QStringLiteral("moved")},
                                {QStringLiteral("threadId"), id},
                                {QStringLiteral("machine"), machine},
                                {QStringLiteral("environmentId"), environment},
                                {QStringLiteral("message"), QStringLiteral("%1 moved to %2.").arg(title, machine)}});
  });
});

FakeThreadMenu& fake(World& world) {
  return world.mc.part<FakeThreadMenu>();
}

QHash<QString, std::function<void(World&)>>& provided() {
  static QHash<QString, std::function<void(World&)>> makers;
  return makers;
}

std::optional<QString> titled(World& world, const QString& title) {
  for (auto row = world.mc.threads.cbegin(); row != world.mc.threads.cend(); ++row) {
    if (row.value().value(QLatin1String("title")).toString() == title) return world.mc.environmentId + QLatin1Char(':') + row.key();
  }
  return std::nullopt;
}

// A thread by key (`env-a:t1`) or by title.
QString keyOf(World& world, const QString& thread) {
  if (thread.contains(QLatin1Char(':'))) return thread;
  if (const auto key = titled(world, thread)) return *key;
  if (provided().contains(thread)) {
    provided().value(thread)(world);
    if (const auto key = titled(world, thread)) return *key;
  }
  fail(QStringLiteral("no thread is titled \"%1\"").arg(thread));
}

QString idOf(World& world, const QString& thread) {
  const QString key = keyOf(world, thread);
  return key.mid(key.indexOf(QLatin1Char(':')) + 1);
}

QVariantList items(World& world) {
  return at(world.state(QStringLiteral("menu")), QStringLiteral("items")).toList();
}

std::optional<QVariantMap> item(World& world, const QString& id) {
  for (const QVariant& entry : items(world)) {
    if (entry.toMap().value(QStringLiteral("id")) == id) return entry.toMap();
  }
  return std::nullopt;
}

void openMenu(World& world, const QString& thread, double x = 40, double y = 120) {
  world.sync();
  world.bridge().dispatch(QStringLiteral("thread.menu"),
                          QVariantMap{{QStringLiteral("key"), keyOf(world, thread)}, {QStringLiteral("x"), x}, {QStringLiteral("y"), y}});
  expect(world.state(QStringLiteral("menu")).typeId() == QMetaType::QVariantMap, QStringLiteral("no menu opened for %1").arg(thread));
}

void pick(World& world, const QString& id) {
  const QVariant menu = world.state(QStringLiteral("menu"));
  expect(menu.typeId() == QMetaType::QVariantMap, QStringLiteral("no menu is open"));
  world.bridge().dispatch(QStringLiteral("menu.select"),
                          QVariantMap{{QStringLiteral("requestId"), at(menu, QStringLiteral("requestId"))}, {QStringLiteral("id"), id}});
}

void answer(World& world, bool accepted) {
  world.sync();  // the MC's answer can ask it
  const QVariant question = world.state(QStringLiteral("confirmation"));
  expect(question.typeId() == QMetaType::QVariantMap, QStringLiteral("no question is asked"));
  world.bridge().dispatch(QStringLiteral("confirmation.answer"),
                          QVariantMap{{QStringLiteral("requestId"), at(question, QStringLiteral("requestId"))}, {QStringLiteral("accepted"), accepted}});
}

void setDevice(World& world, const QString& key, const QJsonValue& value) {
  auto* settings = world.native().controller<SettingsController>();
  QJsonObject device = settings->deviceSettings();
  device.insert(key, value);
  expect(settings->setDeviceSettings(device), QStringLiteral("the preferences were not saved"));
}

void view(World& world, const QString& key) {
  world.native().controller<NavigationController>()->open(NavigationController::Route::thread(key));
  world.waitFor([&] { return at(world.state(QStringLiteral("workspace")), QStringLiteral("threadKey")) == key; },
                [&] { return QStringLiteral("the header to show %1").arg(key); });
}

// The sidebar section listing the thread `key`, empty when none does.
QString sectionOf(World& world, const QString& key) {
  const QVariantMap sidebar = world.state(QStringLiteral("sidebar")).toMap();
  for (const QString& section : {QStringLiteral("pinned"), QStringLiteral("active"), QStringLiteral("settled"), QStringLiteral("snoozed")}) {
    for (const QVariant& row : sidebar.value(section).toList()) {
      if (row.toMap().value(QStringLiteral("key")) == key) return section;
    }
  }
  return {};
}

QJsonObject thread(const QString& id, const QString& title, const QString& project, const QString& createdAt) {
  return {{QStringLiteral("id"), id}, {QStringLiteral("title"), title}, {QStringLiteral("projectId"), project},
          {QStringLiteral("createdAt"), createdAt}, {QStringLiteral("updatedAt"), createdAt}};
}

QJsonObject project(const QString& id) {
  return {{QStringLiteral("id"), id}, {QStringLiteral("title"), id}, {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + id},
          {QStringLiteral("scripts"), QJsonArray()}, {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
          {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")}};
}

void updateRow(World& world, const QString& id, const std::function<void(QJsonObject&)>& change) {
  QJsonObject& row = world.mc.threads[id];
  change(row);
  world.mc.sendRow(id, row);
  world.sync();
}

// The web menu's names for its items, as the ledger reads them.
QString itemId(const QString& phrase) {
  static const QHash<QString, QString> ids{
      {QStringLiteral("pin"), QStringLiteral("pin")},
      {QStringLiteral("settle"), QStringLiteral("settle")},
      {QStringLiteral("snooze"), QStringLiteral("snooze")},
      {QStringLiteral("rename"), QStringLiteral("rename")},
      {QStringLiteral("regenerate title"), QStringLiteral("regenerate-title")},
      {QStringLiteral("mark unread"), QStringLiteral("mark-unread")},
      {QStringLiteral("copy"), QStringLiteral("copy")},
      {QStringLiteral("project settings"), QStringLiteral("project-settings")},
      {QStringLiteral("archive"), QStringLiteral("archive")},
      {QStringLiteral("delete"), QStringLiteral("delete")},
  };
  if (phrase.startsWith(QLatin1String("new thread on"))) return QStringLiteral("new-thread-on-branch");
  if (phrase.startsWith(QLatin1String("filter by"))) return QStringLiteral("filter-by-project");
  return ids.value(phrase, phrase);
}

const Steps steps([] {
  const QString q = kQuoted;

  // Backgrounds.
  step(QStringLiteral("a connected environment with the thread %1 on the branch %1 in the project %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.projects.insert(c[2], project(c[2]));
    world.mc.projects.insert(QStringLiteral("docs"), project(QStringLiteral("docs")));
    QJsonObject row = thread(QStringLiteral("t1"), c[0], c[2], QStringLiteral("2026-09-23T09:00:00Z"));
    row.insert(QStringLiteral("branch"), c[1]);
    world.mc.threads.insert(QStringLiteral("t1"), row);
    world.mc.threads.insert(QStringLiteral("t9"), thread(QStringLiteral("t9"), QStringLiteral("Write docs"), QStringLiteral("docs"), QStringLiteral("2026-09-23T08:00:00Z")));
    world.connect();
    view(world, keyOf(world, QStringLiteral("t1").prepend(world.mc.environmentId + QLatin1Char(':'))));
  });
  step(QStringLiteral("a connected environment with the idle thread %1(?: in the project %1)?").arg(q), [](World& world, const Captures& c, const Table&) {
    fake(world).project = true;
    const QString projectId = c.value(1).isEmpty() ? QStringLiteral("shop") : c[1];
    world.mc.projects.insert(projectId, project(projectId));
    world.mc.threads.insert(QStringLiteral("t1"), thread(QStringLiteral("t1"), c[0], projectId, QStringLiteral("2026-09-23T09:00:00Z")));
    world.connect();
    view(world, world.mc.environmentId + QStringLiteral(":t1"));
  });
  step(QStringLiteral("a connected environment with the active threads %1, %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    fake(world).project = true;
    world.mc.projects.insert(QStringLiteral("shop"), project(QStringLiteral("shop")));
    for (int index = 0; index < 3; ++index) {
      const QString id = QStringLiteral("t%1").arg(index + 1);
      world.mc.threads.insert(id, thread(id, c[index], QStringLiteral("shop"), QStringLiteral("2026-09-23T09:0%1:00Z").arg(5 - index)));
    }
    world.connect();
    world.sync();
  });

  // The menu.
  step(QStringLiteral("the user opens the (?:thread )?menu for %1(?: at (\\d+), (\\d+))?").arg(q), [](World& world, const Captures& c, const Table&) {
    if (c.value(1).isEmpty()) return openMenu(world, c[0]);
    openMenu(world, c[0], c[1].toDouble(), c[2].toDouble());
  });
  step(QStringLiteral("the user opens the thread(?:'s)? menu"), [](World& world, const Captures&, const Table&) {
    openMenu(world, world.native().controller<NavigationController>()->threadKey());
  });
  step(QStringLiteral("the user opens the header's title menu at (\\d+), (\\d+)"), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("workspace.titleMenu"), QVariantMap{{QStringLiteral("x"), c[0].toDouble()}, {QStringLiteral("y"), c[1].toDouble()}});
  });
  step(QStringLiteral("the actions for %1 are offered").arg(q), [](World& world, const Captures&, const Table&) {
    expect(item(world, QStringLiteral("archive")).has_value(), QStringLiteral("the menu is %1").arg(show(items(world))));
  });
  step(QStringLiteral("the menu (offers|does not offer) %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(item(world, c[1]).has_value() == (c[0] == QLatin1String("offers")), QStringLiteral("the menu is %1").arg(show(items(world))));
  });
  step(QStringLiteral("only these of the menu's actions can be chosen: %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QStringList enabled;
    for (const QVariant& entry : items(world)) {
      if (entry.toMap().value(QStringLiteral("enabled")).toBool()) enabled.append(entry.toMap().value(QStringLiteral("id")).toString());
    }
    expect(enabled.join(QStringLiteral(", ")) == c[0], QStringLiteral("the menu can choose \"%1\"").arg(enabled.join(QStringLiteral(", "))));
  });
  // Fork and Move are the fork's additions, specified in the native feature;
  // moving a thread up or down is threads/pinning-and-order.feature's.
  step(QStringLiteral("the actions read, in order: (.+)"), [](World& world, const Captures& c, const Table&) {
    QStringList expected;
    for (const QString& phrase : c[0].split(QStringLiteral(", "))) expected.append(itemId(phrase));
    QStringList actual;
    for (const QVariant& entry : items(world)) {
      const QString id = entry.toMap().value(QStringLiteral("id")).toString();
      if (id != QLatin1String("fork") && !id.startsWith(QLatin1String("move"))) actual.append(id);
    }
    expect(actual == expected, QStringLiteral("the menu reads %1").arg(actual.join(QStringLiteral(", "))));
    const auto branch = item(world, QStringLiteral("new-thread-on-branch"));
    const QRegularExpression quoted(kQuoted);
    const QString named = quoted.match(c[0]).captured(1);
    expect(branch && branch->value(QStringLiteral("label")) == QStringLiteral("New thread on ") + named,
           QStringLiteral("the menu is %1").arg(show(items(world))));
  });
  step(QStringLiteral("the environment does not support (snoozing or pinning|title regeneration)"), [](World& world, const Captures& c, const Table&) {
    if (c[0] == QLatin1String("title regeneration")) {
      world.mc.capabilities.insert(QStringLiteral("threadTitleRegeneration"), false);
    } else {
      world.mc.capabilities.insert(QStringLiteral("threadSnooze"), false);
      world.mc.capabilities.insert(QStringLiteral("threadPinning"), false);
    }
    world.mc.sendSnapshot();
    world.sync();
  });
  step(QStringLiteral("snoozing and pinning are not offered"), [](World& world, const Captures&, const Table&) {
    expect(!item(world, QStringLiteral("snooze")) && !item(world, QStringLiteral("pin")), QStringLiteral("the menu is %1").arg(show(items(world))));
  });
  step(QStringLiteral("archiving is still offered"), [](World& world, const Captures&, const Table&) {
    expect(item(world, QStringLiteral("archive")).has_value(), QStringLiteral("the menu is %1").arg(show(items(world))));
  });
  step(QStringLiteral("(archiving|regenerating the title) is unavailable( and shows it is in progress)?"), [](World& world, const Captures& c, const Table&) {
    const auto entry = item(world, c[0] == QLatin1String("archiving") ? QStringLiteral("archive") : QStringLiteral("regenerate-title"));
    if (c[0] == QLatin1String("regenerating the title") && c.value(1).isEmpty()) {
      expect(!entry || !entry->value(QStringLiteral("enabled")).toBool(), QStringLiteral("the menu is %1").arg(show(items(world))));
      return;
    }
    expect(entry && !entry->value(QStringLiteral("enabled")).toBool(), QStringLiteral("the menu is %1").arg(show(items(world))));
    if (!c.value(1).isEmpty()) {
      expect(entry->value(QStringLiteral("label")) == QStringLiteral("Regenerating…"), QStringLiteral("the item is %1").arg(show(*entry)));
    }
  });
  step(QStringLiteral("a new title is already being generated for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    updateRow(world, idOf(world, c[0]), [](QJsonObject& row) {
      row.insert(QStringLiteral("titleRegeneration"), QJsonObject{{QStringLiteral("requestId"), QStringLiteral("c1")}, {QStringLiteral("startedAt"), QStringLiteral("2026-09-23T09:59:00Z")}});
    });
  });
  step(QStringLiteral("the agent is working in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    updateRow(world, idOf(world, c[0]), [](QJsonObject& row) {
      row.insert(QStringLiteral("latestRunId"), QStringLiteral("r1"));
      row.insert(QStringLiteral("activeRunId"), QStringLiteral("r1"));
      row.insert(QStringLiteral("status"), QStringLiteral("running"));
    });
  });

  // Copying.
  step(QStringLiteral("the user copies the (path|branch|thread id) of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    openMenu(world, c[1]);
    pick(world, c[0] == QLatin1String("path") ? QStringLiteral("copy-path")
                : c[0] == QLatin1String("branch") ? QStringLiteral("copy-branch")
                                                  : QStringLiteral("copy-thread-id"));
  });
  step(QStringLiteral("the user copies a reference to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    world.native().controller<ThreadMenuController>()->copyReference(keyOf(world, c[0]));
  });
  step(QStringLiteral("the clipboard holds (.+)"), [](World& world, const Captures& c, const Table&) {
    QString expected = c[0];
    if (expected == QLatin1String("the thread's workspace path")) expected = QStringLiteral("/work/shop");
    else if (expected == QLatin1String("the pull request address")) expected = QStringLiteral("https://github.com/acme/shop/pull/7");
    else if (expected == QLatin1String("the thread id")) expected = QStringLiteral("t1");
    else if (expected.startsWith(QLatin1String("the id of "))) expected = idOf(world, expected.mid(11).chopped(1));
    else if (expected.startsWith(QLatin1Char('"'))) expected = expected.mid(1).chopped(1);
    world.sync();
    expect(world.clipboard == expected, QStringLiteral("the clipboard holds \"%1\"").arg(world.clipboard));
  });
  step(QStringLiteral("%1 has no workspace path").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString projectId = world.mc.threads.value(idOf(world, c[0])).value(QLatin1String("projectId")).toString();
    QJsonObject row = world.mc.projects.value(projectId);
    row.insert(QStringLiteral("workspaceRoot"), QString());
    world.mc.projects.insert(projectId, row);
    world.mc.sendRow(projectId, row, QStringLiteral("project"));
    world.sync();
  });
  step(QStringLiteral("the clipboard cannot be written"), [](World& world, const Captures&, const Table&) {
    world.clipboardFails = true;
  });
  step(QStringLiteral("%1 (is linked to a pull request|has no pull request)").arg(q), [](World& world, const Captures& c, const Table&) {
    if (c[1] == QLatin1String("has no pull request")) return;
    updateRow(world, idOf(world, c[0]), [](QJsonObject& row) {
      row.insert(QStringLiteral("linkedPullRequest"), QJsonObject{{QStringLiteral("projectId"), QStringLiteral("shop")},
                                                                  {QStringLiteral("repository"), QStringLiteral("acme/shop")},
                                                                  {QStringLiteral("number"), 7},
                                                                  {QStringLiteral("url"), QStringLiteral("https://github.com/acme/shop/pull/7")}});
    });
  });

  // Filtering and project settings.
  step(QStringLiteral("the user filters by the project of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    openMenu(world, c[0]);
    pick(world, QStringLiteral("filter-by-project"));
  });
  step(QStringLiteral("the user shows all projects again"), [](World& world, const Captures&, const Table&) {
    openMenu(world, QStringLiteral("env-a:t1").replace(QStringLiteral("env-a"), world.mc.environmentId));
    const auto entry = item(world, QStringLiteral("filter-by-project"));
    expect(entry && entry->value(QStringLiteral("label")) == QLatin1String("Show all projects"), QStringLiteral("the menu is %1").arg(show(items(world))));
    pick(world, QStringLiteral("filter-by-project"));
  });
  step(QStringLiteral("(only threads from %1|threads from every project) (?:are|is) listed").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    QSet<QString> projects;
    for (const QVariant& row : at(world.state(QStringLiteral("sidebar")), QStringLiteral("active")).toList()) {
      projects.insert(row.toMap().value(QStringLiteral("projectKey")).toString());
    }
    if (!c.value(1).isEmpty()) {
      expect(projects == QSet<QString>{world.projectKey(c.value(1))}, QStringLiteral("the list shows %1").arg(QStringList(projects.values()).join(QStringLiteral(", "))));
    } else {
      expect(projects.size() > 1, QStringLiteral("the list shows %1").arg(QStringList(projects.values()).join(QStringLiteral(", "))));
    }
  });
  step(QStringLiteral("the user opens the project settings from %1").arg(q), [](World& world, const Captures& c, const Table&) {
    openMenu(world, c[0]);
    pick(world, QStringLiteral("project-settings"));
  });
  step(QStringLiteral("the settings for %1 open").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    const QVariant route = world.state(QStringLiteral("route"));
    expect(at(route, QStringLiteral("kind")) == QLatin1String("settings") && at(route, QStringLiteral("projectKey")) == world.projectKey(c[0]),
           QStringLiteral("the route is %1").arg(show(route)));
  });

  // Archiving, deleting, pinning.
  step(QStringLiteral("the user asked to confirm before (archiving|deleting|unpinning)"), [](World& world, const Captures& c, const Table&) {
    const QString key = c[0] == QLatin1String("archiving") ? QStringLiteral("confirmThreadArchive")
                        : c[0] == QLatin1String("deleting") ? QStringLiteral("confirmThreadDelete")
                                                            : QStringLiteral("confirmThreadUnpin");
    setDevice(world, key, true);
    fake(world).confirmAsked = true;
  });
  // A scenario that did not ask for the question is about the delete: the
  // question deleting asks by default is answered yes.
  step(QStringLiteral("the user (archives|deletes|pins|unpins) %1").arg(q), [](World& world, const Captures& c, const Table&) {
    openMenu(world, c[1]);
    const QString id = c[0] == QLatin1String("archives") ? QStringLiteral("archive")
                       : c[0] == QLatin1String("deletes") ? QStringLiteral("delete")
                                                          : c[0].chopped(1);
    pick(world, id);
    if (id == QLatin1String("delete") && !fake(world).confirmAsked) answer(world, true);
  });
  step(QStringLiteral("the user is asked %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap question = world.state(QStringLiteral("confirmation")).toMap();
    QString asked = question.value(QStringLiteral("title")).toString();
    const QString description = question.value(QStringLiteral("description")).toString();
    const QString expected = QString(c[0]).replace(QLatin1Char('\''), QLatin1Char('"'));
    expect(asked == expected || asked + QLatin1Char(' ') + description == expected, QStringLiteral("the question is %1").arg(show(question)));
  });
  step(QStringLiteral("the user is warned that deleting clears the conversation history"), [](World& world, const Captures&, const Table&) {
    const QVariantMap question = world.state(QStringLiteral("confirmation")).toMap();
    expect(question.value(QStringLiteral("description")).toString().contains(QLatin1String("clears conversation history")) &&
               question.value(QStringLiteral("destructive")).toBool(),
           QStringLiteral("the question is %1").arg(show(question)));
  });
  step(QStringLiteral("the user (confirms|cancels) the question"), [](World& world, const Captures& c, const Table&) {
    answer(world, c[0] == QLatin1String("confirms"));
  });
  step(QStringLiteral("%1 stays pinned until the user confirms").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(world.mc.commands.isEmpty() && sectionOf(world, keyOf(world, c[0])) == QLatin1String("pinned"),
           QStringLiteral("the MC has %1").arg(world.describeCommands()));
    answer(world, true);
    world.waitFor([&] { return sectionOf(world, keyOf(world, c[0])) == QLatin1String("active"); }, QStringLiteral("the thread to be unpinned"));
  });
  step(QStringLiteral("%1 is pinned").arg(q), [](World& world, const Captures& c, const Table&) {
    if (world.checking) {
      world.waitFor([&] { return sectionOf(world, keyOf(world, c[0])) == QLatin1String("pinned"); },
                    [&] { return QStringLiteral("%1 pinned; it is in \"%2\"").arg(c[0], sectionOf(world, keyOf(world, c[0]))); });
      return;
    }
    updateRow(world, idOf(world, c[0]), [](QJsonObject& row) {
      row.insert(QStringLiteral("pinnedAt"), QStringLiteral("2026-09-23T09:30:00Z"));
      row.insert(QStringLiteral("pinOrderKey"), QStringLiteral("a0"));
    });
  });
  step(QStringLiteral("%1 (moves to the pinned section|returns to its place among the active threads)").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString section = c[1].startsWith(QLatin1String("moves")) ? QStringLiteral("pinned") : QStringLiteral("active");
    world.waitFor([&] { return sectionOf(world, keyOf(world, c[0])) == section; },
                  [&] { return QStringLiteral("%1 in %2; it is in \"%3\"").arg(c[0], section, sectionOf(world, keyOf(world, c[0]))); });
  });
  step(QStringLiteral("every connected device shows %1 as pinned").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(world.mc.threads.value(idOf(world, c[0])).contains(QLatin1String("pinnedAt")), QStringLiteral("the MC's row is not pinned"));
  });
  step(QStringLiteral("%1 is the top remaining thread in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString projectId = world.mc.threads.value(QStringLiteral("t1")).value(QLatin1String("projectId")).toString();
    const QJsonObject row = thread(QStringLiteral("t2"), c[0], projectId, QStringLiteral("2026-09-23T08:00:00Z"));
    world.mc.threads.insert(QStringLiteral("t2"), row);
    world.mc.sendRow(QStringLiteral("t2"), row);
    world.sync();
  });
  step(QStringLiteral("%1 is an older thread in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject row = thread(QStringLiteral("t3"), c[0], c[1], QStringLiteral("2026-09-23T07:00:00Z"));
    world.mc.threads.insert(QStringLiteral("t3"), row);
    world.mc.sendRow(QStringLiteral("t3"), row);
    world.sync();
  });
  step(QStringLiteral("%1 opens").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();  // a thread the MC just made is listed by now
    if (fileOpened(world, c[0])) return;
    const QString key = keyOf(world, c[0]);
    world.waitFor([&] { return world.native().controller<NavigationController>()->threadKey() == key; },
                  [&] { return QStringLiteral("%1 to open; the route is %2").arg(key, show(world.state(QStringLiteral("route")))); });
  });

  step(QStringLiteral("%1 is listed in the pinned section above %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(sectionOf(world, keyOf(world, c[0])) == QLatin1String("pinned") && sectionOf(world, keyOf(world, c[1])) == QLatin1String("active") &&
               sectionOf(world, keyOf(world, c[2])) == QLatin1String("active"),
           QStringLiteral("the list is %1").arg(show(world.state(QStringLiteral("sidebar")))));
  });

  // Undo.
  step(QStringLiteral("the user just (unpinned|settled|snoozed|archived) %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString key = keyOf(world, c[1]);
    if (c[0] == QLatin1String("unpinned")) {
      updateRow(world, idOf(world, c[1]), [](QJsonObject& row) {
        row.insert(QStringLiteral("pinnedAt"), QStringLiteral("2026-09-23T09:30:00Z"));
        row.insert(QStringLiteral("pinOrderKey"), QStringLiteral("a0"));
      });
    }
    world.sync();
    fake(world).sectionBefore.insert(key, sectionOf(world, key));
    openMenu(world, key);
    if (c[0] == QLatin1String("snoozed")) {
      const auto snooze = item(world, QStringLiteral("snooze"));
      expect(snooze.has_value(), QStringLiteral("the menu is %1").arg(show(items(world))));
      pick(world, snooze->value(QStringLiteral("children")).toList().first().toMap().value(QStringLiteral("id")).toString());
    } else {
      pick(world, c[0] == QLatin1String("unpinned") ? QStringLiteral("unpin") : c[0] == QLatin1String("settled") ? QStringLiteral("settle") : QStringLiteral("archive"));
    }
    world.waitFor([&] { return sectionOf(world, key) != fake(world).sectionBefore.value(key); }, QStringLiteral("the change to land"));
  });
  step(QStringLiteral("the user undoes the change(?: within five seconds)?"), [](World& world, const Captures&, const Table&) {
    world.sync();
    world.native().controller<ThreadMenuController>()->undo();
  });
  step(QStringLiteral("%1 is back where it was before").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString key = keyOf(world, c[0]);
    world.waitFor([&] { return sectionOf(world, key) == fake(world).sectionBefore.value(key); },
                  [&] { return QStringLiteral("%1 in \"%2\"; it is in \"%3\"").arg(c[0], fake(world).sectionBefore.value(key), sectionOf(world, key)); });
  });
  step(QStringLiteral("%1 is restored and opened again").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString key = keyOf(world, c[0]);
    world.waitFor([&] { return !sectionOf(world, key).isEmpty() && world.native().controller<NavigationController>()->threadKey() == key; },
                  [&] { return QStringLiteral("%1 back and open; the route is %2").arg(key, show(world.state(QStringLiteral("route")))); });
  });
  step(QStringLiteral("five seconds pass"), [](World& world, const Captures&, const Table&) {
    world.setTime(world.now().addSecs(5));
  });
  step(QStringLiteral("the change can no longer be undone"), [](World& world, const Captures&, const Table&) {
    const qsizetype before = world.mc.commands.size();
    world.native().controller<ThreadMenuController>()->undo();
    world.sync();
    expect(world.mc.commands.size() == before, QStringLiteral("the MC has %1").arg(world.describeCommands()));
  });

  // Viewing, renaming, forking.
  step(QStringLiteral("the user is viewing %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    view(world, keyOf(world, c[0]));
  });
  step(QStringLiteral("the header is renaming %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      const QVariantMap state = world.state(QStringLiteral("workspace")).toMap();
      return state.value(QStringLiteral("threadTitle")) == c[0] && state.value(QStringLiteral("renameRequestId")).toInt() > 0;
    }, [&] { return QStringLiteral("the header is %1").arg(show(world.state(QStringLiteral("workspace")))); });
  });
  step(QStringLiteral("the MC is asked to fork %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    for (const QJsonObject& command : std::as_const(world.mc.commands)) {
      if (command.value(QLatin1String("type")) == QLatin1String("thread.fork") &&
          command.value(QLatin1String("sourceThreadId")) == c[0] &&
          at(command.toVariantMap(), QStringLiteral("sourcePoint.type")) == QLatin1String("latest_stable")) {
        return;
      }
    }
    fail(QStringLiteral("the MC has %1").arg(world.describeCommands()));
  });
  step(QStringLiteral("the window shows the fork"), [](World& world, const Captures&, const Table&) {
    world.sync();
    QString target;
    for (const QJsonObject& command : std::as_const(world.mc.commands)) {
      if (command.value(QLatin1String("type")) == QLatin1String("thread.fork")) target = command.value(QLatin1String("targetThreadId")).toString();
    }
    const QString key = world.mc.environmentId + QLatin1Char(':') + target;
    expect(!target.isEmpty() && world.native().controller<NavigationController>()->threadKey() == key,
           QStringLiteral("the route is %1").arg(show(world.state(QStringLiteral("route")))));
  });
  step(QStringLiteral("the window shows the thread %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return world.native().controller<NavigationController>()->threadKey() == c[0]; },
                  [&] { return QStringLiteral("the route is %1").arg(show(world.state(QStringLiteral("route")))); });
  });

  // Starting a thread on another thread's branch.
  step(QStringLiteral("the current thread is on the branch %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    const QString key = world.native().controller<NavigationController>()->threadKey();
    expect(!key.isEmpty(), QStringLiteral("no thread is open"));
    updateRow(world, key.mid(key.indexOf(QLatin1Char(':')) + 1), [&](QJsonObject& row) {
      row.insert(QStringLiteral("branch"), c[0]);
      row.insert(QStringLiteral("worktreePath"), QStringLiteral("/work/wt-") + QString(c[0]).replace(QLatin1Char('/'), QLatin1Char('-')));
    });
  });
  step(QStringLiteral("the user starts a new thread on that branch from the thread menu"), [](World& world, const Captures&, const Table&) {
    openMenu(world, world.native().controller<NavigationController>()->threadKey());
    pick(world, QStringLiteral("new-thread-on-branch"));
  });
  step(QStringLiteral("a draft opens in the same worktree as the current thread"), [](World& world, const Captures&, const Table&) {
    world.sync();
    const QVariant route = world.state(QStringLiteral("route"));
    expect(at(route, QStringLiteral("kind")) == QLatin1String("draft"), QStringLiteral("the route is %1").arg(show(route)));
    const auto checkout = world.native().controller<WorkspaceController>()->checkout(at(route, QStringLiteral("draftId")).toString());
    expect(checkout.envMode == QLatin1String("worktree") && checkout.worktreePath == QStringLiteral("/work/wt-feature-cart") &&
               checkout.branch == QStringLiteral("feature/cart"),
           QStringLiteral("the draft is in %1 on %2").arg(checkout.worktreePath.value_or(checkout.envMode), checkout.branch.value_or(QString())));
  });

  // Moving.
  step(QStringLiteral("the MC can move %1 to %1(?: and to %1, which is offline)?(?: once told %1)?(?: but refuses with %1)?").arg(q), [](World& world, const Captures& c, const Table&) {
    FakeThreadMenu& move = fake(world);
    move.destinations.append(QJsonObject{{QStringLiteral("machine"), c[1]}, {QStringLiteral("environmentId"), world.mc.peers.key(c[1])},
                                         {QStringLiteral("online"), true}, {QStringLiteral("projects"), QJsonArray()}});
    if (!c.value(2).isEmpty()) {
      move.destinations.append(QJsonObject{{QStringLiteral("machine"), c[2]}, {QStringLiteral("environmentId"), QStringLiteral("env-c")},
                                           {QStringLiteral("online"), false}, {QStringLiteral("projects"), QJsonArray()}});
    }
    move.confirmNote = c.value(3);
    move.refusal = c.value(4);
  });
  step(QStringLiteral("the MC is asked to move %1 to %1( confirmed)?").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      for (const QJsonObject& move : std::as_const(fake(world).moves)) {
        if (move.value(QLatin1String("threadId")) == c[0] && move.value(QLatin1String("machine")) == world.mc.peers.key(c[1]) &&
            move.value(QLatin1String("confirmed")).toBool() == !c.value(2).isEmpty()) {
          return true;
        }
      }
      return false;
    }, [&] { return QStringLiteral("the moves asked are %1").arg(show(QVariant::fromValue(fake(world).moves.size()))); });
  });
});

}  // namespace

QString threadKeyOf(World& world, const QString& thread) {
  return keyOf(world, thread);
}

QString sidebarSectionOf(World& world, const QString& key) {
  return sectionOf(world, key);
}

void updateThreadRow(World& world, const QString& id, const std::function<void(QJsonObject&)>& change) {
  updateRow(world, id, change);
}

void projectThreadCommands(World& world) {
  fake(world).project = true;
}

void provideThread(const QString& title, std::function<void(World& world)> make) {
  provided().insert(title, std::move(make));
}
