// What the keymap's commands do once a key runs them
// (features/navigation/keybindings.feature, "What the commands do", and the
// contexts keybinding-customisation.feature names): undoing sidebar actions,
// the project a new thread asks for, what mod+w closes, steering with the
// first queued message, and terminal commands on a hidden drawer.

#include <QJsonArray>

#include "CommandPaletteController.h"
#include "Harness.h"
#include "Keymap.h"
#include "NavigationController.h"
#include "RightPanelController.h"
#include "SidebarController.h"
#include "Stream.h"
#include "TerminalController.h"
#include "ThreadList.h"
#include "Turn.h"
#include "World.h"

namespace {

struct ShortcutState {
  // The threads the scenario acted on, by key.
  QStringList threads;
  int closeRequests = 0;
  bool watchingWindow = false;
};

ShortcutState& shortcuts(World& world) {
  return world.mc.part<ShortcutState>();
}

const QString kProject = QStringLiteral("p1");

// Threads "Alpha", "Beta"... of one project on a connected MC whose rows
// follow the commands it accepts.
QStringList threadsOf(World& world, const QStringList& titles) {
  world.mc.projects.insert(kProject, {{QStringLiteral("id"), kProject},
                                        {QStringLiteral("title"), kProject},
                                        {QStringLiteral("workspaceRoot"), QStringLiteral("/work/p1")},
                                        {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                        {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                        {QStringLiteral("scripts"), QJsonArray()}});
  QStringList keys;
  for (const QString& title : titles) {
    const QString id = QStringLiteral("t-") + title.toLower();
    world.mc.threads.insert(id, {{QStringLiteral("id"), id},
                                   {QStringLiteral("projectId"), kProject},
                                   {QStringLiteral("title"), title},
                                   {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                                   {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}});
    keys.append(world.mc.environmentId + QLatin1Char(':') + id);
  }
  projectThreadCommands(world);
  const bool connected = world.shellSubscriptions() > 0;
  setKeyFocus(world, {});
  if (connected) {
    // Already connected: they arrive as rows.
    world.mc.sendRow(kProject, world.mc.projects.value(kProject), QStringLiteral("project"));
    for (const QString& key : std::as_const(keys)) {
      const QString id = key.mid(key.indexOf(QLatin1Char(':')) + 1);
      world.mc.sendRow(id, world.mc.threads.value(id));
    }
    world.sync();
  }
  world.waitFor([&] { return world.native().sidebar()->orderedKeys().size() >= titles.size(); }, QStringLiteral("the threads in the list"));
  shortcuts(world).threads = keys;
  return keys;
}

void waitForSection(World& world, const QString& key, const QString& section, bool in = true) {
  world.waitFor([&] { return (sidebarSectionOf(world, key) == section) == in; },
                [&] { return QStringLiteral("%1 %2 %3; it is in %4, the MC has %5").arg(key, in ? u"in"_qs : u"out of"_qs, section, sidebarSectionOf(world, key), world.describeCommands()); });
}

void settleFirst(World& world) {
  const QString key = threadsOf(world, {QStringLiteral("Alpha"), QStringLiteral("Beta")}).first();
  // The sidebar row's settle action.
  world.bridge().dispatch(QStringLiteral("thread.settle"), QVariantMap{{QStringLiteral("key"), key}});
  waitForSection(world, key, QStringLiteral("settled"));
  world.sync();
}

RightPanelController* panel(World& world) {
  return world.native().controller<RightPanelController>();
}

TerminalController* terminals(World& world) {
  return world.native().controller<TerminalController>();
}

// A thread shown in the window, its terminal drawer available.
QString showThread(World& world) {
  const QString key = threadsOf(world, {QStringLiteral("Alpha")}).first();
  world.bridge().dispatch(QStringLiteral("thread.open"), QVariantMap{{QStringLiteral("key"), key}});
  world.waitFor([&] { return terminals(world)->available(); }, QStringLiteral("the thread's terminal drawer"));
  return key;
}

void watchWindow(World& world) {
  ShortcutState& state = shortcuts(world);
  if (state.watchingWindow) return;
  state.watchingWindow = true;
  // ShellWindow closes its window on it.
  QObject::connect(&world.bridge(), &ShellBridge::windowCommandRequested, &world.bridge(), [&state](const QString& command) {
    if (command == QLatin1String("close")) ++state.closeRequests;
  });
}

void openFilesTab(World& world) {
  panel(world)->open(QStringLiteral("files"));
  world.waitFor([&] { return panel(world)->isOpen() && panel(world)->activeTab() == QLatin1String("files"); },
                [&] { return QStringLiteral("the Files tab; the panel is %1").arg(show(world.state(QStringLiteral("panel")))); });
}

QJsonObject lastCommand(World& world, const QString& type) {
  for (auto it = world.mc.commands.crbegin(); it != world.mc.commands.crend(); ++it) {
    if (it->value(QLatin1String("type")) == type) return *it;
  }
  return {};
}

int commandCount(World& world, const QString& type) {
  int count = 0;
  for (const QJsonObject& command : world.mc.commands) count += command.value(QLatin1String("type")) == type;
  return count;
}

QVariantList queue(World& world) {
  return world.state(QStringLiteral("turn")).toMap().value(QStringLiteral("queue")).toList();
}

const Steps steps([] {
  // Undo.
  step(QStringLiteral("the user settled a thread from the sidebar"), [](World& world, const Captures&, const Table&) { settleFirst(world); });
  step(QStringLiteral("the user presses ([^ ]+) within 5 seconds"), [](World& world, const Captures& c, const Table&) {
    world.setTime(world.now().addSecs(4));
    pressKey(world, c[0]);
  });
  step(QStringLiteral("the thread is no longer settled"), [](World& world, const Captures&, const Table&) {
    const QString key = shortcuts(world).threads.first();
    expect(keyRan(world, QStringLiteral("thread.undo")), describeKeyPress(world));
    waitForSection(world, key, QStringLiteral("settled"), false);
    expect(commandCount(world, QStringLiteral("thread.unsettle")) == 1, world.describeCommands());
  });
  step(QStringLiteral("the thread stays settled"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(sidebarSectionOf(world, shortcuts(world).threads.first()) == QLatin1String("settled") &&
               commandCount(world, QStringLiteral("thread.unsettle")) == 0,
           world.describeCommands());
  });
  step(QStringLiteral("the composer's own undo runs"), [](World& world, const Captures&, const Table&) {
    // The window stood down, so the key is the field's (its undo).
    expect(keyDeliveredTo(world) == QLatin1String("composer") && !keyRan(world, QStringLiteral("thread.undo")), describeKeyPress(world));
  });
  step(QStringLiteral("the user snoozed three threads one after another"), [](World& world, const Captures&, const Table&) {
    const QStringList keys = threadsOf(world, {QStringLiteral("Alpha"), QStringLiteral("Beta"), QStringLiteral("Gamma"), QStringLiteral("Delta")});
    const QString until = stream::iso(world.now().addDays(1));
    for (const QString& key : keys.mid(0, 3)) {
      // What picking a preset from the row's snooze menu does.
      world.native().sidebar()->snooze(key, until);
      waitForSection(world, key, QStringLiteral("snoozed"));
      world.sync();
      world.setTime(world.now().addSecs(1));
    }
    shortcuts(world).threads = keys.mid(0, 3);
  });
  step(QStringLiteral("all three threads are awake again"), [](World& world, const Captures&, const Table&) {
    expect(keyRan(world, QStringLiteral("thread.undo")), describeKeyPress(world));
    for (const QString& key : std::as_const(shortcuts(world).threads)) waitForSection(world, key, QStringLiteral("snoozed"), false);
    expect(commandCount(world, QStringLiteral("thread.unsnooze")) == 3, world.describeCommands());
  });
  step(QStringLiteral("the user pinned a thread 6 seconds ago"), [](World& world, const Captures&, const Table&) {
    const QString key = threadsOf(world, {QStringLiteral("Alpha"), QStringLiteral("Beta")}).first();
    world.bridge().dispatch(QStringLiteral("thread.open"), QVariantMap{{QStringLiteral("key"), key}});
    world.waitFor([&] { return world.native().controller<NavigationController>()->threadKey() == key; }, QStringLiteral("the thread to open"));
    setKeyFocus(world, {});
    pressKey(world, QStringLiteral("mod+shift+p"));
    waitForSection(world, key, QStringLiteral("pinned"));
    world.setTime(world.now().addSecs(6));
  });
  step(QStringLiteral("the thread stays pinned"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(sidebarSectionOf(world, shortcuts(world).threads.first()) == QLatin1String("pinned") &&
               commandCount(world, QStringLiteral("thread.unpin")) == 0,
           world.describeCommands());
  });

  // A new thread.
  step(QStringLiteral("the user has several projects and none is in scope"), [](World& world, const Captures&, const Table&) {
    threadsOf(world, {QStringLiteral("Alpha")});
    world.mc.projects.insert(QStringLiteral("p2"), {{QStringLiteral("id"), QStringLiteral("p2")},
                                                     {QStringLiteral("title"), QStringLiteral("p2")},
                                                     {QStringLiteral("workspaceRoot"), QStringLiteral("/work/p2")},
                                                     {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                     {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                     {QStringLiteral("scripts"), QJsonArray()}});
    world.mc.sendRow(QStringLiteral("p2"), world.mc.projects.value(QStringLiteral("p2")), QStringLiteral("project"));
    world.sync();
    world.waitFor([&] { return world.native().sidebar()->groups().size() == 2; }, QStringLiteral("two projects in the sidebar"));
    // The window shows no project (the usage page) and the list is not scoped.
    world.bridge().dispatch(QStringLiteral("usage.open"), {});
    expect(!world.native().sidebar()->scope().has_value(), QStringLiteral("the thread list is scoped"));
  });
  step(QStringLiteral("the user is asked to choose a project"), [](World& world, const Captures&, const Table&) {
    auto* palette = world.native().controller<CommandPaletteController>();
    expect(palette->isOpen() && palette->submenu() == QLatin1String("New thread in...") && palette->count() == 2,
           QStringLiteral("the palette is %1 on \"%2\" with %3 entries; the route is %4")
               .arg(palette->isOpen() ? u"open"_qs : u"closed"_qs, palette->submenu())
               .arg(palette->count())
               .arg(show(world.state(QStringLiteral("route")))));
    expect(world.state(QStringLiteral("route")).toMap().value(QStringLiteral("kind")) == QLatin1String("usage"),
           QStringLiteral("a thread started without asking: %1").arg(show(world.state(QStringLiteral("route")))));
  });

  // mod+w closes the innermost thing.
  step(QStringLiteral("a focused terminal and an open right panel tab"), [](World& world, const Captures&, const Table&) {
    showThread(world);
    watchWindow(world);
    openFilesTab(world);
    world.bridge().dispatch(QStringLiteral("terminal.toggle"));
    world.waitFor([&] { return terminals(world)->isOpen() && terminals(world)->tabs()->rowCount() == 1; }, QStringLiteral("the thread's first terminal"));
    setKeyFocus(world, {{QStringLiteral("terminal"), true}});
  });
  step(QStringLiteral("an active right panel tab and no focused terminal"), [](World& world, const Captures&, const Table&) {
    showThread(world);
    watchWindow(world);
    openFilesTab(world);
    setKeyFocus(world, {});
  });
  step(QStringLiteral("nothing but the window"), [](World& world, const Captures&, const Table&) {
    showThread(world);
    watchWindow(world);
    expect(!panel(world)->isOpen() && !terminals(world)->isOpen(), QStringLiteral("a panel or terminal is open"));
    setKeyFocus(world, {});
  });
  step(QStringLiteral("the active right panel tab closes"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(!panel(world)->isOpen() && panel(world)->activeTab() != QLatin1String("files") && shortcuts(world).closeRequests == 0,
           QStringLiteral("%1; the panel is %2").arg(describeKeyPress(world), show(world.state(QStringLiteral("panel")))));
  });
  step(QStringLiteral("the window closes"), [](World& world, const Captures&, const Table&) {
    expect(shortcuts(world).closeRequests == 1,
           QStringLiteral("%1; the window was asked to close %2 times").arg(describeKeyPress(world)).arg(shortcuts(world).closeRequests));
  });

  // Steering.
  step(QStringLiteral("a turn is running and two messages are queued"), [](World& world, const Captures&, const Table&) {
    startWorkingTurn(world);
    queueTurnMessage(world, QStringLiteral("check the logs"));
    queueTurnMessage(world, QStringLiteral("update the docs"));
    world.waitFor([&] { return queue(world).size() == 2; }, [&] { return QStringLiteral("two queued messages; the turn is %1").arg(show(world.state(QStringLiteral("turn")))); });
    setKeyFocus(world, {});
  });
  step(QStringLiteral("the first queued message is sent as a steer"), [](World& world, const Captures&, const Table&) {
    world.sync();
    const QJsonObject command = lastCommand(world, QStringLiteral("queued-message.promote-to-steer"));
    expect(command.value(QLatin1String("queuedRunId")) == QLatin1String("run-queued-check the logs"),
           QStringLiteral("%1; the MC was told %2").arg(describeKeyPress(world), world.describeCommands()));
  });
  step(QStringLiteral("the second stays queued"), [](World& world, const Captures&, const Table&) {
    expect(commandCount(world, QStringLiteral("queued-message.promote-to-steer")) == 1, world.describeCommands());
    bool queued = false;
    for (const QVariant& entry : queue(world)) queued |= entry.toMap().value(QStringLiteral("text")) == QLatin1String("update the docs");
    expect(queued, QStringLiteral("the queue is %1").arg(show(queue(world))));
  });

  // Terminal commands on a hidden drawer.
  step(QStringLiteral("the thread's terminal is shown with a new terminal"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return terminals(world)->isOpen() && terminals(world)->tabs()->rowCount() == 1; },
                  QStringLiteral("the drawer open on one terminal"));
  });
  step(QStringLiteral("the thread's terminal is shown with a second terminal (side by side|stacked below)"),
       [](World& world, const Captures& c, const Table&) {
         const bool stacked = c[0] == QLatin1String("stacked below");
         world.waitFor([&] {
           const QList<TerminalTabs::Row> rows = terminals(world)->tabs()->rows();
           return terminals(world)->isOpen() && rows.size() == 2 && rows.at(0).group == rows.at(1).group && rows.at(1).slot == 1 &&
                  rows.at(1).vertical == stacked;
         }, [&] { return QStringLiteral("two terminals in one group; there are %1").arg(terminals(world)->tabs()->rowCount()); });
       });

  // Where the keyboard is (the keymap's contexts).
  step(QStringLiteral("the user is outside text fields and terminals"), [](World& world, const Captures&, const Table&) { setKeyFocus(world, {}); });
  step(QStringLiteral("(?:the user is in the composer|a text field has focus)"), [](World& world, const Captures&, const Table&) {
    setKeyFocus(world, {{QStringLiteral("composer"), true}, {QStringLiteral("editable"), true}});
  });
  step(QStringLiteral("a terminal has focus"), [](World& world, const Captures&, const Table&) {
    setKeyFocus(world, {{QStringLiteral("terminal"), true}});
  });
  // The desktop's preview is the right panel's Previews tab.
  step(QStringLiteral("the preview is closed"), [](World& world, const Captures&, const Table&) {
    showThread(world);
    expect(!(panel(world)->isOpen() && panel(world)->activeTab() == QLatin1String("previews")), show(world.state(QStringLiteral("panel"))));
    setKeyFocus(world, {});
  });
  step(QStringLiteral("both the terminal and preview are open"), [](World& world, const Captures&, const Table&) {
    showThread(world);
    world.bridge().dispatch(QStringLiteral("terminal.toggle"));
    world.waitFor([&] { return terminals(world)->isOpen(); }, QStringLiteral("the terminal drawer"));
    setKeyFocus(world, {});
    pressKey(world, QStringLiteral("mod+shift+j"));
    world.waitFor([&] { return panel(world)->isOpen() && panel(world)->activeTab() == QLatin1String("previews"); },
                  [&] { return QStringLiteral("the Previews tab; the panel is %1").arg(show(world.state(QStringLiteral("panel")))); });
  });
  step(QStringLiteral("the user is in the composer while a turn runs"), [](World& world, const Captures&, const Table&) {
    startWorkingTurn(world);
    world.waitFor([&] { return world.state(QStringLiteral("turn")).toMap().value(QStringLiteral("running")).toBool(); },
                  [&] { return QStringLiteral("a running turn; the turn is %1").arg(show(world.state(QStringLiteral("turn")))); });
    setKeyFocus(world, {{QStringLiteral("composer"), true}, {QStringLiteral("editable"), true}});
  });
  step(QStringLiteral("the composer has focus and no turn is running"), [](World& world, const Captures&, const Table&) {
    openTurnThread(world);
    expect(!world.state(QStringLiteral("turn")).toMap().value(QStringLiteral("running")).toBool(), show(world.state(QStringLiteral("turn"))));
    setKeyFocus(world, {{QStringLiteral("composer"), true}, {QStringLiteral("editable"), true}});
  });
  step(QStringLiteral("the user is in the composer of a new thread"), [](World& world, const Captures&, const Table&) {
    threadsOf(world, {QStringLiteral("Alpha")});
    world.startNewThread(QVariantMap{{QStringLiteral("projectKey"), world.projectKey(kProject)}});
    expect(world.state(QStringLiteral("route")).toMap().value(QStringLiteral("kind")) == QLatin1String("draft"),
           show(world.state(QStringLiteral("route"))));
    setKeyFocus(world, {{QStringLiteral("composer"), true}, {QStringLiteral("editable"), true}});
  });
});

}  // namespace
