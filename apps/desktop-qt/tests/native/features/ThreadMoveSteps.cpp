// Moving a thread to another machine of the cluster
// (features/threads/moving-between-machines.feature): the machines the MC
// offers, the rows that follow a move (HalC2.ThreadMove: the source keeps a
// forwarding record, `movedTo`; a thread on its way is `moving`), and the
// window, alerts and drafts that follow the thread to where it lives now.
//
// The scenarios that name "the phone" are about a client that did not make
// the move; here the desktop shell is that client and the MC's rows say what
// the other client did.

#include <QJsonArray>
#include <QJsonObject>

#include "AlertController.h"
#include "CommandPaletteController.h"
#include "ComposerController.h"
#include "Harness.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "ThreadList.h"
#include "ThreadMenuController.h"
#include "World.h"

namespace {

const QString kAt = QStringLiteral("2026-09-23T09:00:00Z");

struct Moves {
  QStringList machines;
  QSet<QString> offline;
  // The machine each thread lives on, by thread id.
  QHash<QString, QString> home;
  // The live rows of threads on the other machines, by machine then id.
  QHash<QString, QHash<QString, QJsonObject>> elsewhere;
  // Whether the provider carries the agent's own session along.
  bool carries = true;
  int subscriptions = 0;
  QString alert;    // the id of the in-app alert the scenario opens
  QString message;  // what the user wrote
  QString worked;   // when the user last worked in the thread that moved
};

Moves& moves(World& world) {
  return world.mc.part<Moves>();
}

QString environmentOf(const QString& machine) {
  return QStringLiteral("env-") + machine;
}

QString idOf(const QString& title) {
  return QStringLiteral("thread-") + title.toLower().replace(QLatin1Char(' '), QLatin1Char('-'));
}

QString keyOn(const QString& title, const QString& machine) {
  return environmentOf(machine) + QLatin1Char(':') + idOf(title);
}

QString iso(const QDateTime& time) {
  return time.toUTC().toString(Qt::ISODateWithMs);
}

QString home(World& world, const QString& title) {
  const QString machine = moves(world).home.value(idOf(title));
  expect(!machine.isEmpty(), QStringLiteral("no thread \"%1\" lives in the cluster").arg(title));
  return machine;
}

QJsonObject liveRow(World& world, const QString& id) {
  const QString machine = moves(world).home.value(id);
  return machine == world.mc.name ? world.mc.threads.value(id) : moves(world).elsewhere.value(machine).value(id);
}

void put(World& world, const QString& machine, const QString& id, const QJsonObject& row, bool live) {
  if (machine == world.mc.name) {
    world.mc.threads.insert(id, row);
    world.mc.sendRow(id, row);
  } else {
    if (live) moves(world).elsewhere[machine].insert(id, row);
    world.mc.sendRows(machine, QJsonArray{QJsonValue(QJsonArray{id, QStringLiteral("thread"), row})});
  }
}

QJsonObject marker(const QString& machine, const QString& at) {
  return {{QStringLiteral("label"), machine}, {QStringLiteral("environmentId"), environmentOf(machine)},
          {QStringLiteral("mc"), machine}, {QStringLiteral("at"), at}};
}

// What HalC2.ThreadMove does to the cluster's rows: the machine the thread
// left keeps a forwarding record, the destination lists the thread.
void relocate(World& world, const QString& id, const QString& to) {
  Moves& state = moves(world);
  const QString from = state.home.value(id);
  QJsonObject row = liveRow(world, id);
  row.remove(QStringLiteral("moving"));
  row.remove(QStringLiteral("movedTo"));
  QJsonObject forward = row;
  forward.insert(QStringLiteral("movedTo"), marker(to, iso(world.now())));
  state.elsewhere[from].remove(id);
  put(world, from, id, forward, false);
  state.home.insert(id, to);
  put(world, to, id, row, true);
}

void setOnline(World& world, const QString& machine, bool online) {
  world.mc.send({{QStringLiteral("t"), QStringLiteral("shell.mc")}, {QStringLiteral("id"), world.mc.subscribers(QStringLiteral("shell")).value(0)},
                 {QStringLiteral("mc"), machine}, {QStringLiteral("online"), online}});
}

// The machines the MC offers for the thread: every other one, offline or not.
void offer(World& world, const QString& id) {
  QJsonArray destinations;
  for (const QString& machine : std::as_const(moves(world).machines)) {
    if (machine == moves(world).home.value(id)) continue;
    destinations.append(QJsonObject{{QStringLiteral("machine"), machine}, {QStringLiteral("environmentId"), environmentOf(machine)},
                                    {QStringLiteral("online"), !moves(world).offline.contains(machine)}, {QStringLiteral("projects"), QJsonArray()}});
  }
  offerMoveDestinations(world, destinations);
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

void pick(World& world, const QString& id) {
  const QVariant menu = world.state(QStringLiteral("menu"));
  expect(menuItem(world, id).has_value(), QStringLiteral("the menu is %1").arg(show(menuItems(world))));
  world.bridge().dispatch(QStringLiteral("menu.select"),
                          QVariantMap{{QStringLiteral("requestId"), at(menu, QStringLiteral("requestId"))}, {QStringLiteral("id"), id}});
}

// The thread's menu, then "Move to another machine…": the machines it offers.
void chooseWhere(World& world, const QString& title) {
  offer(world, idOf(title));
  world.sync();
  world.bridge().dispatch(QStringLiteral("thread.menu"),
                          QVariantMap{{QStringLiteral("key"), keyOn(title, home(world, title))}, {QStringLiteral("x"), 40}, {QStringLiteral("y"), 120}});
  pick(world, QStringLiteral("move"));
  world.sync();
}

std::optional<QVariantMap> rowOf(World& world, const QString& key) {
  const QVariantMap sidebar = world.state(QStringLiteral("sidebar")).toMap();
  for (const QString& section : {QStringLiteral("pinned"), QStringLiteral("active"), QStringLiteral("snoozed"), QStringLiteral("settled")}) {
    for (const QVariant& row : sidebar.value(section).toList()) {
      if (row.toMap().value(QStringLiteral("key")) == key) return row.toMap();
    }
  }
  return std::nullopt;
}

void waitListed(World& world, const QString& title, const QString& machine) {
  world.waitFor([&] { return rowOf(world, keyOn(title, machine)).has_value(); },
                [&] { return QStringLiteral("%1 listed under %2; the sidebar is %3").arg(title, machine, show(world.state(QStringLiteral("sidebar")))); });
}

QString shownThread(World& world) {
  return world.native().controller<NavigationController>()->threadKey();
}

void view(World& world, const QString& key) {
  world.native().controller<NavigationController>()->open(NavigationController::Route::thread(key));
  world.waitFor([&] { return at(world.state(QStringLiteral("workspace")), QStringLiteral("threadKey")) == key; },
                [&] { return QStringLiteral("the window to show %1").arg(key); });
}

void send(World& world, const QString& text) {
  world.bridge().dispatch(QStringLiteral("composer.submit"),
                          QVariantMap{{QStringLiteral("edit"), QVariantMap{{QStringLiteral("clientId"), QStringLiteral("qml")}, {QStringLiteral("revision"), world.nextEdit++}}},
                                      {QStringLiteral("text"), text}, {QStringLiteral("intent"), QStringLiteral("foreground")}});
  world.sync();
}

// The turn the MC was asked to start with `text`, and the environment it was sent to.
std::optional<QString> turnSentTo(World& world, const QString& text) {
  for (qsizetype index = 0; index < world.mc.commands.size(); ++index) {
    const QJsonObject command = world.mc.commands.at(index);
    if (command.value(QLatin1String("type")) == QLatin1String("message.dispatch") && command.value(QLatin1String("text")) == text) return world.mc.commandEnvironments.value(index);
  }
  return std::nullopt;
}

const FakeMc::Extension interrupts([](FakeMc& mc) {
  // An interrupted run ends, as the MC's row then says.
  mc.effects.append([&mc](const QJsonObject& command) {
    if (command.value(QLatin1String("type")) != QLatin1String("run.interrupt")) return;
    const QString id = command.value(QLatin1String("threadId")).toString();
    if (!mc.threads.contains(id)) return;
    QJsonObject& row = mc.threads[id];
    row.insert(QStringLiteral("status"), QStringLiteral("interrupted"));
    row.remove(QStringLiteral("activeRunId"));
    mc.sendRow(id, row);
  });
});

const Steps steps([] {
  const QString q = kQuoted;

  // The cluster.
  step(QStringLiteral("a cluster of the machines %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.name = c[0];
    world.mc.label = c[0];
    world.mc.environmentId = environmentOf(c[0]);
    moves(world).machines = {c[0], c[1]};
    world.connect();
    world.mc.join(c[1], environmentOf(c[1]));
    setOnline(world, c[1], true);
    world.sync();
    onThreadMoved(world, [&world](const QJsonObject& input, QJsonObject& answer) {
      const QString id = input.value(QLatin1String("threadId")).toString();
      const QString to = input.value(QLatin1String("machine")).toString();
      const QString title = liveRow(world, id).value(QLatin1String("title")).toString();
      relocate(world, id, to);
      answer.insert(QStringLiteral("environmentId"), environmentOf(to));
      answer.insert(QStringLiteral("sessionCarried"), moves(world).carries);
      answer.insert(QStringLiteral("message"),
                    moves(world).carries ? QStringLiteral("%1 moved to %2. The agent continues its own session there.").arg(title, to)
                                         : QStringLiteral("%1 moved to %2. The agent there will get a summary of the conversation.").arg(title, to));
    });
  });
  step(QStringLiteral("the project %1 on each machine is a checkout of the same repository").arg(q), [](World& world, const Captures& c, const Table&) {
    for (const QString& machine : std::as_const(moves(world).machines)) {
      const QJsonObject row{{QStringLiteral("id"), c[0]}, {QStringLiteral("title"), c[0]},
                            {QStringLiteral("workspaceRoot"), QStringLiteral("/home/") + machine + QLatin1Char('/') + c[0]},
                            {QStringLiteral("scripts"), QJsonArray()}, {QStringLiteral("createdAt"), kAt}, {QStringLiteral("updatedAt"), kAt},
                            {QStringLiteral("repositoryIdentity"), QJsonObject{{QStringLiteral("canonicalKey"), QStringLiteral("github.com/acme/") + c[0]}}}};
      if (machine == world.mc.name) {
        world.mc.projects.insert(c[0], row);
        world.mc.sendRow(c[0], row, QStringLiteral("project"));
      } else {
        world.mc.sendRows(machine, QJsonArray{QJsonValue(QJsonArray{c[0], QStringLiteral("project"), row})});
      }
    }
    world.sync();
  });
  step(QStringLiteral("the thread %1 lives on %1 in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString id = idOf(c[0]);
    moves(world).home.insert(id, c[1]);
    put(world, c[1], id, {{QStringLiteral("id"), id}, {QStringLiteral("title"), c[0]}, {QStringLiteral("projectId"), c[2]},
                          {QStringLiteral("createdAt"), kAt}, {QStringLiteral("updatedAt"), kAt}}, true);
    world.sync();
  });
  step(QStringLiteral("the cluster also has the machine %1, which is offline").arg(q), [](World& world, const Captures& c, const Table&) {
    moves(world).machines.append(c[0]);
    moves(world).offline.insert(c[0]);
    world.mc.join(c[0], environmentOf(c[0]));
    setOnline(world, c[0], false);
    world.sync();
  });
  step(QStringLiteral("%1 is not in a cluster").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(c[0] == world.mc.name, QStringLiteral("the desktop's MC is %1").arg(world.mc.name));
    // The MC's snapshot lists only itself.
    world.mc.peers.clear();
    moves(world).machines = {c[0]};
    world.mc.sendSnapshot();
    world.sync();
  });

  // Moving.
  step(QStringLiteral("the user moves %1 to %1( and chooses to stop it first)?").arg(q), [](World& world, const Captures& c, const Table&) {
    chooseWhere(world, c[0]);
    pick(world, QStringLiteral("machine:") + c[1]);
    world.sync();
    const QVariant question = world.state(QStringLiteral("confirmation"));
    if (c.value(2).isEmpty()) {
      expect(question.typeId() != QMetaType::QVariantMap, QStringLiteral("the user is asked %1").arg(show(question)));
      return;
    }
    expect(question.typeId() == QMetaType::QVariantMap && at(question, QStringLiteral("confirmLabel")) == QLatin1String("Stop and move"),
           QStringLiteral("the question is %1").arg(show(question)));
    world.bridge().dispatch(QStringLiteral("confirmation.answer"),
                            QVariantMap{{QStringLiteral("requestId"), at(question, QStringLiteral("requestId"))}, {QStringLiteral("accepted"), true}});
  });
  step(QStringLiteral("the user chooses where to move %1").arg(q), [](World& world, const Captures& c, const Table&) { chooseWhere(world, c[0]); });
  step(QStringLiteral("%1 is offered").arg(q), [](World& world, const Captures& c, const Table&) {
    const auto item = menuItem(world, QStringLiteral("machine:") + c[0]);
    expect(item && item->value(QStringLiteral("enabled")).toBool(), QStringLiteral("the menu is %1").arg(show(menuItems(world))));
  });
  step(QStringLiteral("%1 is shown as offline and cannot be chosen").arg(q), [](World& world, const Captures& c, const Table&) {
    const auto item = menuItem(world, QStringLiteral("machine:") + c[0]);
    expect(item && !item->value(QStringLiteral("enabled")).toBool() && item->value(QStringLiteral("label")).toString().contains(QLatin1String("offline")),
           QStringLiteral("the menu is %1").arg(show(menuItems(world))));
  });
  step(QStringLiteral("moving to another machine is (not )?offered"), [](World& world, const Captures& c, const Table&) {
    expect(!menuItems(world).isEmpty() && menuItem(world, QStringLiteral("move")).has_value() == c.value(0).isEmpty(),
           QStringLiteral("the menu is %1").arg(show(menuItems(world))));
  });
  step(QStringLiteral("%1 is listed under %1").arg(q), [](World& world, const Captures& c, const Table&) { waitListed(world, c[0], c[1]); });
  step(QStringLiteral("%1 is no longer listed under %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(!rowOf(world, keyOn(c[0], c[1])), QStringLiteral("the sidebar is %1").arg(show(world.state(QStringLiteral("sidebar")))));
  });
  step(QStringLiteral("(?:the user is looking at %1 on %1|%1 opens on %1)").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString key = c.value(0).isEmpty() ? keyOn(c[2], c[3]) : keyOn(c[0], c[1]);
    world.waitFor([&] { return shownThread(world) == key && at(world.state(QStringLiteral("workspace")), QStringLiteral("threadKey")) == key; },
                  [&] { return QStringLiteral("the window to show %1; the route is %2").arg(key, show(world.state(QStringLiteral("route")))); });
  });
  step(QStringLiteral("%1 runs on an agent whose provider (can|cannot) carry its session").arg(q), [](World& world, const Captures& c, const Table&) {
    moves(world).carries = c[1] == QLatin1String("can");
  });

  // Moving back.
  step(QStringLiteral("%1 was moved from %1 to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(home(world, c[0]) == c[1], QStringLiteral("%1 lives on %2").arg(c[0], home(world, c[0])));
    relocate(world, idOf(c[0]), c[2]);
    world.sync();
  });
  step(QStringLiteral("the user worked in %1 on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(home(world, c[0]) == c[1], QStringLiteral("%1 lives on %2").arg(c[0], home(world, c[0])));
    world.setTime(world.now().addSecs(600));
    moves(world).worked = iso(world.now());
    QJsonObject row = liveRow(world, idOf(c[0]));
    row.insert(QStringLiteral("latestRunId"), QStringLiteral("run-on-") + c[1]);
    row.insert(QStringLiteral("status"), QStringLiteral("completed"));
    row.insert(QStringLiteral("latestRunCompletedAt"), moves(world).worked);
    row.insert(QStringLiteral("updatedAt"), moves(world).worked);
    put(world, c[1], idOf(c[0]), row, true);
    world.sync();
  });
  step(QStringLiteral("%1 is listed under %1 with the work done on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    waitListed(world, c[0], c[1]);
    const QVariantMap row = *rowOf(world, keyOn(c[0], c[1]));
    expect(!moves(world).worked.isEmpty() && row.value(QStringLiteral("updatedAt")) == moves(world).worked,
           QStringLiteral("the row is %1").arg(show(row)));
    expect(!rowOf(world, keyOn(c[0], c[2])), QStringLiteral("%1 is still listed under %2").arg(c[0], c[2]));
  });
  step(QStringLiteral("the agent on %1 continues the session as it was on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    // The MC says whether the session came along; the shell tells the user.
    const QString told = QStringLiteral("moved to %1. The agent continues its own session there.").arg(c[0]);
    world.waitFor([&] {
      for (const QVariant& item : world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList()) {
        if (item.toMap().value(QStringLiteral("title")).toString().endsWith(told)) return true;
      }
      return false;
    }, [&] { return QStringLiteral("the user to be told; the shell shows %1").arg(show(world.state(QStringLiteral("toasts")))); });
  });

  // Alerts from before the move.
  step(QStringLiteral("the user was notified that %1 finished while it lived on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(home(world, c[0]) == c[1], QStringLiteral("%1 lives on %2").arg(c[0], home(world, c[0])));
    world.native().controller<SettingsController>()->set(QStringLiteral("inAppNotificationsEnabled"), true);
    world.native().controller<AlertController>()->setFocused(true);
    world.native().controller<NavigationController>()->open(NavigationController::Route::of(QStringLiteral("usage")));
    const QString id = idOf(c[0]);
    QJsonObject row = liveRow(world, id);
    row.insert(QStringLiteral("latestRunId"), QStringLiteral("r1"));
    row.insert(QStringLiteral("status"), QStringLiteral("running"));
    put(world, c[1], id, row, true);
    world.sync();
    world.setTime(world.now().addSecs(60));
    row.insert(QStringLiteral("status"), QStringLiteral("completed"));
    row.insert(QStringLiteral("latestRunCompletedAt"), iso(world.now()));
    row.insert(QStringLiteral("updatedAt"), iso(world.now()));
    put(world, c[1], id, row, true);
    world.sync();
    for (const QVariant& item : world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList()) {
      if (item.toMap().value(QStringLiteral("description")) == c[0]) moves(world).alert = item.toMap().value(QStringLiteral("id")).toString();
    }
    expect(!moves(world).alert.isEmpty(), QStringLiteral("no alert: %1").arg(show(world.state(QStringLiteral("toasts")))));
  });
  step(QStringLiteral("%1 has since moved to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    relocate(world, idOf(c[0]), c[1]);
    world.sync();
  });
  step(QStringLiteral("the user opens the notification"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("notification.action"), QVariantMap{{QStringLiteral("id"), moves(world).alert}});
  });

  // A client that did not make the move.
  step(QStringLiteral("the phone is showing %1").arg(q), [](World& world, const Captures& c, const Table&) {
    view(world, keyOn(c[0], home(world, c[0])));
    moves(world).subscriptions = world.shellSubscriptions();
  });
  step(QStringLiteral("the phone lists %1").arg(q), [](World& world, const Captures& c, const Table&) {
    waitListed(world, c[0], home(world, c[0]));
  });
  step(QStringLiteral("%1 is moved to %1 from another client").arg(q), [](World& world, const Captures& c, const Table&) {
    relocate(world, idOf(c[0]), c[1]);
    world.sync();
  });
  step(QStringLiteral("the phone keeps showing %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString key = keyOn(c[0], home(world, c[0]));
    world.waitFor([&] { return shownThread(world) == key && world.state(QStringLiteral("route")).toMap().value(QStringLiteral("title")) == c[0]; },
                  [&] { return QStringLiteral("the window to show %1; the route is %2").arg(key, show(world.state(QStringLiteral("route")))); });
    expect(world.shellSubscriptions() == moves(world).subscriptions, QStringLiteral("the shell subscribed again"));
  });
  step(QStringLiteral("a message sent from the phone reaches %1 on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    view(world, keyOn(c[0], c[1]));
    send(world, QStringLiteral("Carry on"));
    const auto environment = turnSentTo(world, QStringLiteral("Carry on"));
    expect(environment == environmentOf(c[1]), QStringLiteral("the MC has %1 for \"%2\"").arg(world.describeCommands(), environment.value_or(QStringLiteral("(not sent)"))));
  });
  step(QStringLiteral("%1 (?:starts|is) moving to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString id = idOf(c[0]);
    QJsonObject row = liveRow(world, id);
    row.insert(QStringLiteral("moving"), marker(c[1], iso(world.now())));
    put(world, home(world, c[0]), id, row, true);
    world.sync();
  });
  step(QStringLiteral("the phone shows %1 as moving to %1 until it arrives").arg(q), [](World& world, const Captures& c, const Table&) {
    // SidebarThreadRow.qml reads "Moving" for a row with `movingTo`.
    const auto leaving = rowOf(world, keyOn(c[0], home(world, c[0])));
    expect(leaving && leaving->value(QStringLiteral("movingTo")) == c[1], QStringLiteral("the row is %1").arg(show(leaving.value_or(QVariantMap()))));
    relocate(world, idOf(c[0]), c[1]);
    waitListed(world, c[0], c[1]);
    const QVariantMap arrived = *rowOf(world, keyOn(c[0], c[1]));
    expect(arrived.value(QStringLiteral("movingTo")).typeId() != QMetaType::QString, QStringLiteral("the row is %1").arg(show(arrived)));
  });

  // Stopping first, and writing while it moves.
  step(QStringLiteral("the running turn of %1 is interrupted").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      for (const QJsonObject& command : std::as_const(world.mc.commands)) {
        if (command.value(QLatin1String("type")) == QLatin1String("run.interrupt") && command.value(QLatin1String("threadId")) == idOf(c[0])) return true;
      }
      return false;
    }, [&] { return QStringLiteral("the turn to be interrupted; the MC has %1").arg(world.describeCommands()); });
  });
  step(QStringLiteral("%1 moves to %1").arg(q), [](World& world, const Captures& c, const Table&) { waitListed(world, c[0], c[1]); });
  step(QStringLiteral("the user writes a message in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    view(world, keyOn(c[0], home(world, c[0])));
    moves(world).message = QStringLiteral("Ship it when you arrive");
    send(world, moves(world).message);
  });
  step(QStringLiteral("the message is kept as a draft"), [](World& world, const Captures&, const Table&) {
    expect(!turnSentTo(world, moves(world).message), QStringLiteral("the MC has %1").arg(world.describeCommands()));
    const QString kept = world.native().controller<ComposerController>()->draft(shownThread(world));
    expect(kept == moves(world).message, QStringLiteral("the composer keeps \"%1\"").arg(kept));
  });
  step(QStringLiteral("it can be sent once %1 has arrived on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    relocate(world, idOf(c[0]), c[1]);
    const QString key = keyOn(c[0], c[1]);
    world.waitFor([&] { return shownThread(world) == key && world.state(QStringLiteral("composer")).toMap().value(QStringLiteral("text")) == moves(world).message; },
                  [&] { return QStringLiteral("the draft to follow the thread; the composer is %1").arg(show(world.state(QStringLiteral("composer")))); });
    send(world, moves(world).message);
    const auto environment = turnSentTo(world, moves(world).message);
    expect(environment == environmentOf(c[1]), QStringLiteral("the MC has %1").arg(world.describeCommands()));
  });

  // The command palette.
  step(QStringLiteral("the user asks the command palette to move the thread to another machine"), [](World& world, const Captures&, const Table&) {
    const QString key = shownThread(world);
    expect(!key.isEmpty(), QStringLiteral("no thread is open"));
    offer(world, key.mid(key.indexOf(QLatin1Char(':')) + 1));
    auto* palette = world.native().controller<CommandPaletteController>();
    palette->show();
    palette->setQuery(QStringLiteral("move thread"));
    world.sync();
    world.waitFor([palette] { return !palette->searching(); }, QStringLiteral("the palette to settle"));
    for (int row = 0; row < palette->count(); ++row) {
      if (palette->idAt(row) != ThreadMenuController::kMoveCommand) continue;
      expect(palette->run(row), QStringLiteral("the palette did not run the move"));
      world.sync();
      return;
    }
    fail(QStringLiteral("the palette does not offer to move the thread"));
  });
  step(QStringLiteral("the user is asked which machine to move %1 to").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    QStringList machines;
    for (const QVariant& entry : menuItems(world)) {
      const QString id = entry.toMap().value(QStringLiteral("id")).toString();
      if (id.startsWith(QLatin1String("machine:"))) machines.append(id.mid(8));
    }
    QStringList expected = moves(world).machines;
    expected.removeAll(home(world, c[0]));
    expect(!machines.isEmpty() && machines == expected, QStringLiteral("the menu is %1").arg(show(menuItems(world))));
  });
});

}  // namespace
