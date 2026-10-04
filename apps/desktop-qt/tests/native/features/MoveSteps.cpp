// Moving a thread between the machines of a cluster
// (features/threads/moving-between-machines.feature): the move from the
// thread menu and the palette (ThreadMenuController), and what the shell does
// with a thread whose rows say it is moving or has moved (ShellStore::located).
// The cluster is machines known by one name each, the MC's own among them,
// whose rows change as the real MCs' do during a move (thread_move.ex).

#include <QJsonArray>
#include <QJsonObject>

#include "Alerts.h"
#include "CommandPaletteController.h"
#include "ComposerController.h"
#include "FilesIdentity.h"
#include "Harness.h"
#include "LoadBalancing.h"
#include "Move.h"
#include "NavigationController.h"
#include "ShellStore.h"
#include "Stream.h"
#include "ThreadMenuController.h"
#include "World.h"

namespace {

using stream::iso;

// A machine the palette offered a move to.
struct Choice {
  QString title;
  QString description;
  bool enabled = false;
};

struct FakeMove {
  bool cluster = false;  // the scenario built the machines' cluster
  bool carries = true;   // the thread's provider can carry its session
  // Every `hal-c2.moveThread` asked, and the answer to each that moved.
  QList<QJsonObject> asked;
  QList<QJsonObject> moved;
  // What the user holds from before a move: a thread's key, and the one a
  // system notification named.
  QString link;
  QString notified;
  // The shell's subscriptions and connections before a move made elsewhere.
  int subscriptions = 0;
  qsizetype connections = 0;
  QString message;  // what the user wrote
  // The machines the palette offered, and the thread it named.
  QList<Choice> choices;
  QString paletteThread;
};

const QString kAt = QStringLiteral("2026-09-23T10:00:00Z");
const QString kProject = QStringLiteral("shop");

QStringList machines(const FakeMc& mc) {
  return QStringList{mc.environmentId} + mc.members;
}

QJsonObject rowOn(const FakeMc& mc, const QString& machine, const QString& id) {
  if (machine == mc.environmentId) return mc.threads.value(id);
  return mc.peerRows.value(machine).value(id).at(2).toObject();
}

void putRow(FakeMc& mc, const QString& machine, const QString& id, const QJsonObject& row) {
  if (machine != mc.environmentId) return mc.sendPeerRow(machine, id, row);
  mc.threads.insert(id, row);
  mc.sendRow(id, row);
}

// The machine the thread lives on: the one whose row is not a forwarding record.
QString homeOf(const FakeMc& mc, const QString& id) {
  for (const QString& machine : machines(mc)) {
    const QJsonObject row = rowOn(mc, machine, id);
    if (!row.isEmpty() && !row.contains(QLatin1String("movedTo"))) return machine;
  }
  return {};
}

QJsonObject whereabouts(const QString& machine) {
  return {{QStringLiteral("label"), machine},
          {QStringLiteral("environmentId"), machine},
          {QStringLiteral("mc"), QStringLiteral("mc-") + machine},
          {QStringLiteral("at"), kAt}};
}

// The source says the thread is on its way.
void start(FakeMc& mc, const QString& id, const QString& to) {
  const QString from = homeOf(mc, id);
  QJsonObject row = rowOn(mc, from, id);
  row.insert(QStringLiteral("moving"), whereabouts(to));
  putRow(mc, from, id, row);
}

// The destination has the thread, then the source keeps only where it went.
void finish(FakeMc& mc, const QString& id, const QString& to) {
  const QString from = homeOf(mc, id);
  QJsonObject row = rowOn(mc, from, id);
  row.remove(QStringLiteral("moving"));
  putRow(mc, to, id, row);
  QJsonObject movedTo = whereabouts(to);
  movedTo.insert(QStringLiteral("projectId"), row.value(QLatin1String("projectId")));
  row.insert(QStringLiteral("movedTo"), movedTo);
  row.insert(QStringLiteral("worktreePath"), QJsonValue::Null);
  putRow(mc, from, id, row);
}

QJsonObject project() {
  return {{QStringLiteral("id"), kProject},
          {QStringLiteral("title"), kProject},
          {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")},
          {QStringLiteral("repositoryIdentity"), QJsonObject{{QStringLiteral("canonicalKey"), QStringLiteral("github.com/acme/shop")}}},
          {QStringLiteral("scripts"), QJsonArray()},
          {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
          {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")}};
}

// A stopped run leaves its thread free to move.
const FakeMc::Extension interrupts([](FakeMc& mc) {
  mc.effects.append([&mc](const QJsonObject& command) {
    if (!mc.part<FakeMove>().cluster || command.value(QLatin1String("type")) != QLatin1String("run.interrupt")) return;
    const QString id = command.value(QLatin1String("threadId")).toString();
    const QString machine = homeOf(mc, id);
    QJsonObject row = rowOn(mc, machine, id);
    row.remove(QStringLiteral("activeRunId"));
    row.insert(QStringLiteral("status"), QStringLiteral("interrupted"));
    putRow(mc, machine, id, row);
  });
});

FakeMove& fake(World& world) {
  return world.mc.part<FakeMove>();
}

QString idOf(World& world, const QString& title) {
  const FakeMc& mc = world.mc;
  for (auto row = mc.threads.cbegin(); row != mc.threads.cend(); ++row) {
    if (row->value(QLatin1String("title")) == title) return row.key();
  }
  for (const QString& machine : mc.members) {
    for (const QJsonArray& entry : mc.peerRows.value(machine)) {
      if (entry.at(1) == QLatin1String("thread") && entry.at(2).toObject().value(QLatin1String("title")) == title) {
        return entry.at(0).toString();
      }
    }
  }
  fail(QStringLiteral("no thread is titled \"%1\"").arg(title));
}

QString keyOn(const QString& machine, const QString& id) {
  return machine + QLatin1Char(':') + id;
}

// The thread's key where it lives now.
QString keyOf(World& world, const QString& title) {
  const QString id = idOf(world, title);
  return keyOn(homeOf(world.mc, id), id);
}

QVariantMap sidebarRow(World& world, const QString& key) {
  const QVariant sidebar = world.state(QStringLiteral("sidebar"));
  for (const char* section : {"pinned", "active", "snoozed", "settled"}) {
    for (const QVariant& row : at(sidebar, QString::fromLatin1(section)).toList()) {
      if (row.toMap().value(QStringLiteral("key")) == key) return row.toMap();
    }
  }
  return {};
}

QString sidebar(World& world) {
  return QStringLiteral("the sidebar is %1").arg(show(world.state(QStringLiteral("sidebar"))));
}

// The thread is listed on `machine` and on no other.
void waitForListed(World& world, const QString& title, const QString& machine) {
  const QString id = idOf(world, title);
  world.waitFor(
      [&] {
        for (const QString& other : machines(world.mc)) {
          if (sidebarRow(world, keyOn(other, id)).isEmpty() == (other == machine)) return false;
        }
        return true;
      },
      [&] { return QStringLiteral("%1 to be listed only under %2; %3").arg(title, machine, sidebar(world)); });
}

QString shownKey(World& world) {
  return at(world.state(QStringLiteral("workspace")), QStringLiteral("threadKey")).toString();
}

void view(World& world, const QString& key) {
  world.native().controller<NavigationController>()->open(NavigationController::Route::thread(key));
  world.waitFor([&] { return shownKey(world) == key; }, [&] { return QStringLiteral("the header to show %1").arg(key); });
}

// The window shows the thread on `machine`, in the route and in the header.
void waitForShown(World& world, const QString& title, const QString& machine) {
  const QString key = keyOn(machine, idOf(world, title));
  world.waitFor(
      [&] {
        return world.native().controller<NavigationController>()->threadKey() == key && shownKey(world) == key &&
               at(world.state(QStringLiteral("workspace")), QStringLiteral("threadTitle")) == title;
      },
      [&] {
        return QStringLiteral("the window to show %1; it shows %2").arg(key, show(world.state(QStringLiteral("workspace"))));
      });
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

void pick(World& world, const QString& id) {
  const QVariant menu = world.state(QStringLiteral("menu"));
  expect(item(world, id).has_value(), QStringLiteral("the menu has no \"%1\": %2").arg(id, show(items(world))));
  world.bridge().dispatch(QStringLiteral("menu.select"),
                          QVariantMap{{QStringLiteral("requestId"), at(menu, QStringLiteral("requestId"))}, {QStringLiteral("id"), id}});
}

// The thread's menu, then its Move: the machines the MC lists.
void chooseMachine(World& world, const QString& title) {
  world.sync();
  world.bridge().dispatch(QStringLiteral("thread.menu"),
                          QVariantMap{{QStringLiteral("key"), keyOf(world, title)}, {QStringLiteral("x"), 40}, {QStringLiteral("y"), 120}});
  pick(world, QStringLiteral("move"));
  world.waitFor(
      [&] {
        const QVariantList shown = items(world);
        return !shown.isEmpty() && shown.first().toMap().value(QStringLiteral("id")).toString().startsWith(QLatin1String("machine:"));
      },
      [&] { return QStringLiteral("the machines to be listed; the menu is %1").arg(show(items(world))); });
}

void moveFromMenu(World& world, const QString& title, const QString& machine) {
  chooseMachine(world, title);
  pick(world, QStringLiteral("machine:") + machine);
  world.sync();
}

// A move the client under test did not ask for: only the rows tell it.
void moveElsewhere(World& world, const QString& title, const QString& machine) {
  const QString id = idOf(world, title);
  start(world.mc, id, machine);
  finish(world.mc, id, machine);
  world.sync();
}

// Opens the palette's Move on the shown thread; its rows are then the machines.
void askPalette(World& world) {
  auto* palette = world.native().controller<CommandPaletteController>();
  palette->show();
  palette->setQuery(QStringLiteral("Move to another machine"));
  world.waitFor([palette] { return !palette->searching(); }, QStringLiteral("the palette to settle"));
  QStringList titles;
  for (int row = 0; row < palette->count(); ++row) {
    titles.append(palette->data(palette->index(row), CommandPaletteController::TitleRole).toString());
    if (palette->idAt(row) != ThreadMenuController::kMove) continue;
    fake(world).paletteThread = palette->data(palette->index(row), CommandPaletteController::DescriptionRole).toString();
    palette->run(row);
    fake(world).choices.clear();
    for (int choice = 0; choice < palette->count(); ++choice) {
      const QModelIndex index = palette->index(choice);
      fake(world).choices.append({palette->data(index, CommandPaletteController::TitleRole).toString(),
                                  palette->data(index, CommandPaletteController::DescriptionRole).toString(),
                                  palette->data(index, CommandPaletteController::EnabledRole).toBool()});
    }
    return;
  }
  fail(QStringLiteral("the palette offers no move: %1").arg(titles.join(QStringLiteral(", "))));
}

std::optional<Choice> choice(World& world, const QString& machine) {
  for (const Choice& offered : std::as_const(fake(world).choices)) {
    if (offered.title == machine) return offered;
  }
  return std::nullopt;
}

QString offered(World& world) {
  QStringList palette;
  for (const Choice& entry : std::as_const(fake(world).choices)) {
    palette.append(entry.enabled ? entry.title : entry.title + QStringLiteral(" (") + entry.description + QLatin1Char(')'));
  }
  return QStringLiteral("the menu offers %1, the palette %2").arg(show(items(world)), palette.join(QStringLiteral(", ")));
}

// The `message.dispatch` the MC got for the thread, with the machine it was sent to.
std::optional<std::pair<QJsonObject, QString>> sent(World& world, const QString& id) {
  for (qsizetype index = world.mc.commands.size() - 1; index >= 0; --index) {
    const QJsonObject& command = world.mc.commands.at(index);
    if (command.value(QLatin1String("type")) == QLatin1String("message.dispatch") && command.value(QLatin1String("threadId")) == id) {
      return std::pair{command, world.mc.commandEnvironments.at(index)};
    }
  }
  return std::nullopt;
}

void submit(World& world, const QVariantMap& payload) {
  QVariantMap submitted = payload;
  submitted.insert(QStringLiteral("intent"), QStringLiteral("foreground"));
  world.bridge().dispatch(QStringLiteral("composer.submit"), submitted);
}

bool toastTitled(World& world, const QString& title) {
  for (const QVariant& toast : world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList()) {
    if (toast.toMap().value(QStringLiteral("title")) == title) return true;
  }
  return false;
}

const Steps steps([] {
  const QString q = kQuoted;

  // The Background: the MC is the first machine, the others its cluster's.
  step(QStringLiteral("a cluster of the machines %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    fake(world).cluster = true;
    world.mc.environmentId = c[0];
    world.mc.name = QStringLiteral("mc-") + c[0];
    world.mc.label = c[0];
    world.mc.join(c[1]);
  });
  step(QStringLiteral("the project %1 on each machine is a checkout of the same repository").arg(q),
       [](World& world, const Captures& c, const Table&) {
         // Any other project is one a new thread is placed in (LoadBalancing.h).
         if (c[0] != kProject) return shareProject(world.mc, c[0]);
         world.mc.projects.insert(kProject, project());
         for (const QString& machine : std::as_const(world.mc.members)) {
           world.mc.sendPeerRow(machine, kProject, project(), QStringLiteral("project"));
         }
       });
  step(QStringLiteral("the thread %1 lives on %1 in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString id = c[0].toLower();
    putRow(world.mc, c[1], id,
           {{QStringLiteral("id"), id},
            {QStringLiteral("title"), c[0]},
            {QStringLiteral("projectId"), c[2]},
            {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")},
            {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}});
    world.connect();
    world.sync();
  });
  step(QStringLiteral("the cluster also has the machine %1, which is offline").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.offline.insert(c[0]);
    world.mc.sendPeerRow(c[0], kProject, project(), QStringLiteral("project"));
    world.mc.join(c[0]);
    world.sync();
  });
  // Its environment is its own; only the name is shared.
  step(QStringLiteral("the cluster also has a second machine called %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString environment = c[0] + QStringLiteral("-2");
    world.mc.sendPeerRow(environment, kProject, project(), QStringLiteral("project"));
    world.mc.peerLabels.insert(environment, c[0]);
    world.mc.join(QStringLiteral("mc-") + environment, environment);
    world.sync();
  });
  step(QStringLiteral("%1 runs on an agent whose provider (can|cannot) carry its session").arg(q),
       [](World& world, const Captures& c, const Table&) { fake(world).carries = c[1] == QLatin1String("can"); });

  // Moving, by the user here and by somebody else.
  step(QStringLiteral("the user moves %1 to %1( and chooses to stop it first)?").arg(q), [](World& world, const Captures& c, const Table&) {
    moveFromMenu(world, c[0], c[1]);
    if (c.value(2).isEmpty()) return;
    const QVariant question = world.state(QStringLiteral("confirmation"));
    expect(at(question, QStringLiteral("title")) == QStringLiteral("Stop \"%1\" and move it to %2?").arg(c[0], c[1]),
           QStringLiteral("the user is asked %1").arg(show(question)));
    world.bridge().dispatch(QStringLiteral("confirmation.answer"),
                            QVariantMap{{QStringLiteral("requestId"), at(question, QStringLiteral("requestId"))}, {QStringLiteral("accepted"), true}});
  });
  step(QStringLiteral("%1 was moved from %1 to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(homeOf(world.mc, idOf(world, c[0])) == c[1], QStringLiteral("%1 does not live on %2").arg(c[0], c[1]));
    moveElsewhere(world, c[0], c[2]);
  });
  step(QStringLiteral("%1 has since moved to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    moveElsewhere(world, c[0], c[1]);
  });
  step(QStringLiteral("%1 is moved to %1 from another client").arg(q), [](World& world, const Captures& c, const Table&) {
    moveElsewhere(world, c[0], c[1]);
  });
  step(QStringLiteral("the user moves %1 to %1 from the desktop app").arg(q), [](World& world, const Captures& c, const Table&) {
    moveElsewhere(world, c[0], c[1]);
  });
  step(QStringLiteral("%1 (?:starts|is) moving to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    start(world.mc, idOf(world, c[0]), c[1]);
    world.sync();
  });
  step(QStringLiteral("the user worked in %1 on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString id = idOf(world, c[0]);
    expect(homeOf(world.mc, id) == c[1], QStringLiteral("%1 does not live on %2").arg(c[0], c[1]));
    world.setTime(world.now().addSecs(600));
    QJsonObject row = rowOn(world.mc, c[1], id);
    row.insert(QStringLiteral("latestRunId"), QStringLiteral("run-") + c[1]);
    row.insert(QStringLiteral("status"), QStringLiteral("completed"));
    row.insert(QStringLiteral("latestRunCompletedAt"), iso(world.now()));
    row.insert(QStringLiteral("updatedAt"), iso(world.now()));
    putRow(world.mc, c[1], id, row);
    world.sync();
  });

  // Where the thread is listed and shown.
  step(QStringLiteral("%1 is listed under %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString key = keyOn(c[1], idOf(world, c[0]));
    world.waitFor([&] { return sidebarRow(world, key).value(QStringLiteral("environmentId")) == c[1]; },
                  [&] { return QStringLiteral("%1 to be listed under %2; %3").arg(c[0], c[1], sidebar(world)); });
  });
  step(QStringLiteral("%1 is no longer listed under %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(sidebarRow(world, keyOn(c[1], idOf(world, c[0]))).isEmpty(), sidebar(world));
  });
  step(QStringLiteral("%1 is listed under %1 with the work done on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForListed(world, c[0], c[1]);
    const QJsonObject row = world.native().store()->threadRow(keyOn(c[1], idOf(world, c[0])));
    expect(row.value(QLatin1String("latestRunId")) == QStringLiteral("run-") + c[2],
           QStringLiteral("the thread's row is %1").arg(show(row.toVariantMap())));
  });
  step(QStringLiteral("the user is looking at %1 on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForShown(world, c[0], c[1]);
  });
  step(QStringLiteral("%1 opens on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForShown(world, c[0], c[1]);
  });
  step(QStringLiteral("%1 moves to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString id = idOf(world, c[0]);
    world.waitFor(
        [&] {
          const QList<QJsonObject>& moved = fake(world).moved;
          return std::any_of(moved.cbegin(), moved.cend(), [&](const QJsonObject& answer) {
            return answer.value(QLatin1String("threadId")) == id && answer.value(QLatin1String("machine")) == c[1];
          });
        },
        [&] { return QStringLiteral("the MC to be asked to move %1 to %2; it got %3").arg(c[0], c[1], world.describeCommands()); });
    waitForListed(world, c[0], c[1]);
  });
  step(QStringLiteral("the agent on %1 continues the session as it was on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(!fake(world).moved.isEmpty(), QStringLiteral("no thread was moved"));
    const QJsonObject answer = fake(world).moved.last();
    expect(answer.value(QLatin1String("machine")) == c[0] && answer.value(QLatin1String("from")) == c[1] &&
               answer.value(QLatin1String("sessionCarried")).toBool(),
           QStringLiteral("the move was answered %1").arg(show(answer.toVariantMap())));
    expect(toastTitled(world, answer.value(QLatin1String("message")).toString()),
           QStringLiteral("the user is told %1").arg(show(world.state(QStringLiteral("toasts")))));
  });

  // Choosing the machine.
  step(QStringLiteral("the user chooses where to move %1").arg(q), [](World& world, const Captures& c, const Table&) {
    view(world, keyOf(world, c[0]));
    askPalette(world);
    world.native().controller<CommandPaletteController>()->dismiss();
    chooseMachine(world, c[0]);
  });
  step(QStringLiteral("%1 is offered").arg(q), [](World& world, const Captures& c, const Table&) {
    // The project icon picker's images are offered in the same words (FilesIdentitySteps).
    if (checkIconImageOffered(world, c[0], true)) return;
    const auto entry = item(world, QStringLiteral("machine:") + c[0]);
    const auto listed = choice(world, c[0]);
    expect(entry && entry->value(QStringLiteral("enabled")).toBool() && listed && listed->enabled, offered(world));
  });
  step(QStringLiteral("%1 is shown as offline and cannot be chosen").arg(q), [](World& world, const Captures& c, const Table&) {
    const auto entry = item(world, QStringLiteral("machine:") + c[0]);
    const auto listed = choice(world, c[0]);
    expect(entry && entry->value(QStringLiteral("label")) == c[0] + QStringLiteral(" (offline)") &&
               !entry->value(QStringLiteral("enabled")).toBool() && listed && !listed->enabled &&
               listed->description == QLatin1String("Offline"),
           offered(world));
  });
  step(QStringLiteral("both machines called %1 are offered, each with its environment id").arg(q),
       [](World& world, const Captures& c, const Table&) {
         for (const QString& environment : {c[0], c[0] + QStringLiteral("-2")}) {
           const QString name = QStringLiteral("%1 · %2").arg(c[0], environment);
           const auto entry = item(world, QStringLiteral("machine:") + environment);
           const auto listed = choice(world, name);
           expect(entry && entry->value(QStringLiteral("label")) == name && listed && listed->enabled, offered(world));
         }
       });
  step(QStringLiteral("moving to another machine is offered"), [](World& world, const Captures&, const Table&) {
    const auto entry = item(world, QStringLiteral("move"));
    expect(entry && entry->value(QStringLiteral("enabled")).toBool(), QStringLiteral("the menu is %1").arg(show(items(world))));
  });
  step(QStringLiteral("the user asks the command palette to move the thread to another machine"),
       [](World& world, const Captures&, const Table&) { askPalette(world); });
  step(QStringLiteral("the user is asked which machine to move %1 to").arg(q), [](World& world, const Captures& c, const Table&) {
    auto* palette = world.native().controller<CommandPaletteController>();
    QStringList wanted = machines(world.mc);
    wanted.removeAll(homeOf(world.mc, idOf(world, c[0])));
    QStringList listed;
    for (const Choice& entry : std::as_const(fake(world).choices)) listed.append(entry.title);
    expect(palette->isOpen() && palette->submenu() == QLatin1String("Move to another machine") &&
               fake(world).paletteThread == c[0] && listed == wanted,
           QStringLiteral("the palette shows \"%1\" for \"%2\": %3")
               .arg(palette->submenu(), fake(world).paletteThread, listed.join(QStringLiteral(", "))));
  });

  // A thread found from before it moved.
  step(QStringLiteral("the user copied a link to %1 while it lived on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    fake(world).link = keyOf(world, c[0]);
    expect(fake(world).link == keyOn(c[1], idOf(world, c[0])), QStringLiteral("%1 does not live on %2").arg(c[0], c[1]));
  });
  step(QStringLiteral("the user follows the link"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("thread.open"), QVariantMap{{QStringLiteral("key"), fake(world).link}});
  });
  step(QStringLiteral("the user was notified that %1 finished while it lived on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString id = idOf(world, c[0]);
    awaitSystemNotifications(world);
    QJsonObject row = rowOn(world.mc, c[1], id);
    row.insert(QStringLiteral("latestRunId"), QStringLiteral("run-1"));
    row.insert(QStringLiteral("latestRunStartedAt"), iso(world.now()));
    row.insert(QStringLiteral("status"), QStringLiteral("running"));
    putRow(world.mc, c[1], id, row);
    world.sync();
    world.setTime(world.now().addSecs(60));
    row.insert(QStringLiteral("status"), QStringLiteral("completed"));
    row.insert(QStringLiteral("latestRunCompletedAt"), iso(world.now()));
    row.insert(QStringLiteral("updatedAt"), iso(world.now()));
    putRow(world.mc, c[1], id, row);
    world.sync();
    fake(world).notified = keyOn(c[1], id);
    expect(systemNotifications(world) == QStringList{fake(world).notified},
           QStringLiteral("the user was notified of %1").arg(systemNotifications(world).join(QStringLiteral(", "))));
  });
  step(QStringLiteral("the user opens the notification"), [](World& world, const Captures&, const Table&) {
    expect(clickSystemNotification(world, fake(world).notified), QStringLiteral("the notification opened nothing"));
  });

  // A client that did not make the move. The client under test is the one
  // watching: the move is made elsewhere and reaches it as rows.
  step(QStringLiteral("a phone and the desktop app both follow the cluster's threads"), [](World& world, const Captures&, const Table&) {
    world.sync();
    fake(world).subscriptions = world.shellSubscriptions();
    fake(world).connections = world.mc.connections.size();
  });
  step(QStringLiteral("the phone lists %1 under %1 and no longer under %1").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForListed(world, c[0], c[1]);
    expect(sidebarRow(world, keyOn(c[2], idOf(world, c[0]))).isEmpty(), sidebar(world));
  });
  step(QStringLiteral("the phone did not have to reconnect"), [](World& world, const Captures&, const Table&) {
    expect(world.shellSubscriptions() == fake(world).subscriptions && world.mc.connections.size() == fake(world).connections,
           QStringLiteral("the client subscribed %1 times over %2 connections")
               .arg(world.shellSubscriptions())
               .arg(world.mc.connections.size()));
  });
  step(QStringLiteral("the phone is showing %1").arg(q), [](World& world, const Captures& c, const Table&) {
    view(world, keyOf(world, c[0]));
  });
  step(QStringLiteral("the phone keeps showing %1").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForShown(world, c[0], homeOf(world.mc, idOf(world, c[0])));
  });
  step(QStringLiteral("a message sent from the phone reaches %1 on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString id = idOf(world, c[0]);
    submit(world, {{QStringLiteral("text"), QStringLiteral("Carry on")}});
    world.waitFor([&] { return sent(world, id).has_value(); },
                  [&] { return QStringLiteral("the message to be sent; the MC got %1").arg(world.describeCommands()); });
    expect(sent(world, id)->second == c[1], QStringLiteral("the message went to \"%1\"").arg(sent(world, id)->second));
  });
  step(QStringLiteral("the phone lists %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString key = keyOf(world, c[0]);
    world.waitFor([&] { return !sidebarRow(world, key).isEmpty(); }, [&] { return sidebar(world); });
  });
  step(QStringLiteral("the phone shows %1 as moving to %1 until it arrives").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString id = idOf(world, c[0]);
    const QString from = keyOf(world, c[0]);
    world.waitFor([&] { return sidebarRow(world, from).value(QStringLiteral("movingTo")) == c[1]; }, [&] { return sidebar(world); });
    finish(world.mc, id, c[1]);
    waitForListed(world, c[0], c[1]);
    const QVariantMap arrived = sidebarRow(world, keyOn(c[1], id));
    expect(arrived.value(QStringLiteral("movingTo")).toString().isEmpty(), QStringLiteral("the row is %1").arg(show(arrived)));
  });

  // Stopping first, and writing while the thread is on its way.
  step(QStringLiteral("the running turn of %1 is interrupted").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString id = idOf(world, c[0]);
    world.waitFor(
        [&] {
          return std::any_of(world.mc.commands.cbegin(), world.mc.commands.cend(), [&](const QJsonObject& command) {
            return command.value(QLatin1String("type")) == QLatin1String("run.interrupt") &&
                   command.value(QLatin1String("threadId")) == id && command.value(QLatin1String("runId")) == QLatin1String("r1");
          });
        },
        [&] { return QStringLiteral("the run to be interrupted; the MC got %1").arg(world.describeCommands()); });
  });
  step(QStringLiteral("the user writes a message in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    view(world, keyOf(world, c[0]));
    fake(world).message = QStringLiteral("Carry on from here");
    submit(world, {{QStringLiteral("text"), fake(world).message}});
    world.sync();
  });
  step(QStringLiteral("the message is kept as a draft"), [](World& world, const Captures&, const Table&) {
    const QString key = world.native().controller<NavigationController>()->threadKey();
    const QString id = key.mid(key.indexOf(QLatin1Char(':')) + 1);
    const QJsonObject row = world.native().store()->threadRow(key);
    expect(!sent(world, id), QStringLiteral("the message was sent: %1").arg(world.describeCommands()));
    const QString draft = world.native().controller<ComposerController>()->draft(key);
    expect(draft == fake(world).message, QStringLiteral("the draft is \"%1\"").arg(draft));
    const QString told = QStringLiteral("%1 is moving to %2")
                             .arg(row.value(QLatin1String("title")).toString(),
                                  row.value(QLatin1String("moving")).toObject().value(QLatin1String("label")).toString());
    expect(toastTitled(world, told), QStringLiteral("the user is told %1").arg(show(world.state(QStringLiteral("toasts")))));
  });
  step(QStringLiteral("it can be sent once %1 has arrived on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString id = idOf(world, c[0]);
    finish(world.mc, id, c[1]);
    waitForShown(world, c[0], c[1]);
    const QString draft = world.native().controller<ComposerController>()->draft(keyOn(c[1], id));
    expect(draft == fake(world).message, QStringLiteral("the draft on %1 is \"%2\"").arg(c[1], draft));
    submit(world, {});
    world.waitFor([&] { return sent(world, id).has_value(); },
                  [&] { return QStringLiteral("the message to be sent; the MC got %1").arg(world.describeCommands()); });
    const auto [command, machine] = *sent(world, id);
    expect(command.value(QLatin1String("text")) == fake(world).message && machine == c[1],
           QStringLiteral("\"%1\" went to \"%2\"").arg(command.value(QLatin1String("text")).toString(), machine));
  });
});

}  // namespace

bool answerMachineMove(FakeMc& mc, const FakeMc::Rpc& rpc) {
  FakeMove& fake = mc.part<FakeMove>();
  if (!fake.cluster) return false;
  const QString from = rpc.environment.isEmpty() ? mc.environmentId : rpc.environment;
  if (rpc.method == QLatin1String("hal-c2.moveDestinations")) {
    QJsonArray destinations;
    for (const QString& machine : machines(mc)) {
      if (machine == from) continue;
      destinations.append(QJsonObject{{QStringLiteral("machine"), mc.peerLabels.value(machine, machine)},
                                      {QStringLiteral("environmentId"), machine},
                                      {QStringLiteral("online"), !mc.offline.contains(machine)},
                                      {QStringLiteral("projects"), QJsonArray{project()}}});
    }
    mc.reply(rpc, destinations);
    return true;
  }

  fake.asked.append(rpc.payload);
  const QString id = rpc.payload.value(QLatin1String("threadId")).toString();
  const QString to = rpc.payload.value(QLatin1String("machine")).toString();
  const QJsonObject row = rowOn(mc, from, id);
  const QString title = row.value(QLatin1String("title")).toString();
  // What thread_move.ex refuses before anything is copied.
  QString refusal;
  if (row.contains(QLatin1String("movedTo"))) {
    refusal = QStringLiteral("%1 has already moved to %2.")
                  .arg(title, row.value(QLatin1String("movedTo")).toObject().value(QLatin1String("label")).toString());
  } else if (row.contains(QLatin1String("moving"))) {
    refusal = QStringLiteral("%1 is already moving to %2.")
                  .arg(title, row.value(QLatin1String("moving")).toObject().value(QLatin1String("label")).toString());
  } else if (row.contains(QLatin1String("activeRunId"))) {
    refusal = QStringLiteral("%1 is running. Stop it or wait for it to finish before moving it.").arg(title);
  } else if (mc.offline.contains(to)) {
    refusal = QStringLiteral("%1 is offline. %2 was not moved.").arg(to, title);
  }
  if (!refusal.isEmpty()) {
    mc.refuse(rpc, refusal);
    return true;
  }

  start(mc, id, to);
  finish(mc, id, to);
  QJsonObject answer{{QStringLiteral("status"), QStringLiteral("moved")},
                     {QStringLiteral("threadId"), id},
                     {QStringLiteral("machine"), to},
                     {QStringLiteral("environmentId"), to},
                     {QStringLiteral("projectId"), row.value(QLatin1String("projectId"))},
                     {QStringLiteral("sessionCarried"), fake.carries},
                     {QStringLiteral("message"),
                      fake.carries ? QStringLiteral("%1 moved to %2. The agent continues its own session there.").arg(title, to)
                                   : QStringLiteral("%1 moved to %2. The agent there will get a summary of the conversation.").arg(title, to)},
                     {QStringLiteral("notes"), QJsonArray()}};
  mc.reply(rpc, answer);
  answer.insert(QStringLiteral("from"), from);
  fake.moved.append(answer);
  return true;
}

bool showMachineThread(World& world, const QString& title) {
  if (!fake(world).cluster) return false;
  view(world, keyOf(world, title));
  return true;
}

bool machineNotOffered(World& world, const QString& machine) {
  if (!fake(world).cluster) return false;
  expect(!item(world, QStringLiteral("machine:") + machine) && !choice(world, machine), offered(world));
  return true;
}
