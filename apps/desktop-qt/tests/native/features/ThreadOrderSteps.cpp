// Arranging the pinned and active threads by hand
// (features/threads/pinning-and-order.feature): moving a thread from its
// menu, and what a drag in the list does, as the Sidebar brick reports it
// (`thread.drop {key, section, beforeKey}`). The MC keeps the order
// (thread.pin.reorder, thread.active.reorder; ThreadMenuSteps projects them).

#include <QJsonArray>
#include <QJsonObject>

#include "FilesFolders.h"
#include "Harness.h"
#include "KeybindingController.h"
#include "Keybindings.h"
#include "ThreadList.h"
#include "World.h"

namespace {

struct Arrangement {
  QString dragged;
  qsizetype commandsBefore = 0;
  bool shortcutTaken = false;
};

Arrangement& scene(World& world) {
  return world.mc.part<Arrangement>();
}

QString idOf(const QString& key) {
  return key.mid(key.indexOf(QLatin1Char(':')) + 1);
}

QStringList titlesOf(World& world, const QString& section) {
  QStringList titles;
  for (const QVariant& row : at(world.state(QStringLiteral("sidebar")), section).toList()) titles.append(row.toMap().value(QStringLiteral("title")).toString());
  return titles;
}

void waitOrder(World& world, const QString& section, const QString& first, const QString& second) {
  world.waitFor([&] {
    const QStringList titles = titlesOf(world, section);
    return titles.contains(first) && titles.contains(second) && titles.indexOf(first) < titles.indexOf(second);
  }, [&] { return QStringLiteral("%1 above %2; the %3 threads are %4").arg(first, second, section, titlesOf(world, section).join(QStringLiteral(", "))); });
}

void drop(World& world, const QString& title, const QString& section, const QString& before = {}) {
  world.sync();
  Arrangement& state = scene(world);
  state.dragged = title;
  state.commandsBefore = world.mc.commands.size();
  world.bridge().dispatch(QStringLiteral("thread.drop"),
                          QVariantMap{{QStringLiteral("key"), threadKeyOf(world, title)}, {QStringLiteral("section"), section},
                                      {QStringLiteral("beforeKey"), before.isEmpty() ? QVariant::fromValue(nullptr) : QVariant(threadKeyOf(world, before))}});
}

void pickFromMenu(World& world, const QString& title, const QString& id) {
  world.sync();
  world.bridge().dispatch(QStringLiteral("thread.menu"), QVariantMap{{QStringLiteral("key"), threadKeyOf(world, title)}, {QStringLiteral("x"), 40}, {QStringLiteral("y"), 120}});
  const QVariant menu = world.state(QStringLiteral("menu"));
  bool offered = false;
  for (const QVariant& entry : at(menu, QStringLiteral("items")).toList()) {
    offered |= entry.toMap().value(QStringLiteral("id")) == id && entry.toMap().value(QStringLiteral("enabled")).toBool();
  }
  expect(offered, QStringLiteral("the menu is %1").arg(show(at(menu, QStringLiteral("items")))));
  world.bridge().dispatch(QStringLiteral("menu.select"), QVariantMap{{QStringLiteral("requestId"), at(menu, QStringLiteral("requestId"))}, {QStringLiteral("id"), id}});
}

void pin(World& world, const QString& title, const QString& orderKey) {
  updateThreadRow(world, idOf(threadKeyOf(world, title)), [&](QJsonObject& row) {
    row.insert(QStringLiteral("pinnedAt"), QStringLiteral("2026-09-23T09:30:00Z"));
    row.insert(QStringLiteral("pinOrderKey"), orderKey);
  });
}

QStringList commandsSince(World& world) {
  QStringList types;
  for (const QJsonObject& command : world.mc.commands.mid(scene(world).commandsBefore)) types.append(command.value(QLatin1String("type")).toString());
  return types;
}

void waitSection(World& world, const QString& title, const QString& section) {
  const QString key = threadKeyOf(world, title);
  world.waitFor([&] { return sidebarSectionOf(world, key) == section; },
                [&] { return QStringLiteral("%1 in %2; it is in \"%3\"").arg(title, section, sidebarSectionOf(world, key)); });
}

const Steps steps([] {
  const QString q = kQuoted;

  // From the menu.
  step(QStringLiteral("the user moves %1 (up|down)").arg(q), [](World& world, const Captures& c, const Table&) {
    pickFromMenu(world, c[0], QStringLiteral("move-") + c[1]);
  });
  step(QStringLiteral("the environment does not support reordering active threads"), [](World& world, const Captures&, const Table&) {
    world.mc.capabilities.insert(QStringLiteral("threadActiveReorder"), false);
    world.mc.sendSnapshot();
    world.sync();
  });
  step(QStringLiteral("the user tries to move %1").arg(q), [](World& world, const Captures& c, const Table&) {
    if (tryMoveManagedFolder(world, c[0])) return;
    scene(world).commandsBefore = world.mc.commands.size();
    pickFromMenu(world, c[0], QStringLiteral("move-up"));
    world.sync();
    expect(commandsSince(world).isEmpty(), QStringLiteral("the MC has %1").arg(world.describeCommands()));
  });

  // Dragging within a section.
  step(QStringLiteral("the (pinned|active) threads are %1 then %1").arg(q), [](World& world, const Captures& c, const Table&) {
    if (!world.checking && c[0] == QLatin1String("pinned")) {
      // Pinned before arranging existed: neither has a place of its own yet.
      for (const QString& title : {c[1], c[2]}) {
        updateThreadRow(world, idOf(threadKeyOf(world, title)), [](QJsonObject& row) { row.insert(QStringLiteral("pinnedAt"), QStringLiteral("2026-09-23T09:30:00Z")); });
      }
    }
    waitOrder(world, c[0], c[1], c[2]);
  });
  step(QStringLiteral("the user drags %1 above %1").arg(q), [](World& world, const Captures& c, const Table&) {
    drop(world, c[0], sidebarSectionOf(world, threadKeyOf(world, c[1])), c[1]);
  });
  step(QStringLiteral("the order is the same after a restart"), [](World& world, const Captures&, const Table&) {
    world.sync();
    const QStringList pinned = titlesOf(world, QStringLiteral("pinned"));
    const QStringList active = titlesOf(world, QStringLiteral("active"));
    world.restart();
    world.connect();
    world.waitFor([&] { return titlesOf(world, QStringLiteral("pinned")) == pinned && titlesOf(world, QStringLiteral("active")) == active; },
                  [&] { return QStringLiteral("the same order; the list is %1 then %2").arg(titlesOf(world, QStringLiteral("pinned")).join(QStringLiteral(", ")),
                                                                                           titlesOf(world, QStringLiteral("active")).join(QStringLiteral(", "))); });
  });

  // Dragging between sections.
  step(QStringLiteral("%1 is active").arg(q), [](World& world, const Captures& c, const Table&) { waitSection(world, c[0], QStringLiteral("active")); });
  step(QStringLiteral("the user drags %1 (into the pinned section|into the active section|onto the settled section header|onto the snoozed section|to the top of the list)").arg(q),
       [](World& world, const Captures& c, const Table&) {
         if (c[1] == QLatin1String("into the pinned section")) {
           // Above the thread already pinned there.
           const QString other = c[0] == QLatin1String("Alpha") ? QStringLiteral("Gamma") : QStringLiteral("Alpha");
           pin(world, other, QStringLiteral("n"));
           drop(world, c[0], QStringLiteral("pinned"), other);
         } else if (c[1] == QLatin1String("into the active section")) {
           drop(world, c[0], QStringLiteral("active"));
         } else if (c[1] == QLatin1String("onto the settled section header")) {
           drop(world, c[0], QStringLiteral("settled"));
         } else if (c[1] == QLatin1String("onto the snoozed section")) {
           drop(world, c[0], QStringLiteral("snoozed"));
         } else {
           drop(world, c[0], QStringLiteral("pinned"));
         }
       });
  step(QStringLiteral("%1 is pinned at the drop position").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return titlesOf(world, QStringLiteral("pinned")).value(0) == c[0] && titlesOf(world, QStringLiteral("pinned")).size() == 2; },
                  [&] { return QStringLiteral("%1 first among the pinned; they are %2").arg(c[0], titlesOf(world, QStringLiteral("pinned")).join(QStringLiteral(", "))); });
  });
  step(QStringLiteral("%1 is unpinned without confirmation").arg(q), [](World& world, const Captures& c, const Table&) {
    waitSection(world, c[0], QStringLiteral("active"));
    expect(world.state(QStringLiteral("confirmation")).typeId() != QMetaType::QVariantMap && commandsSince(world) == QStringList{QStringLiteral("thread.unpin")},
           QStringLiteral("the MC has %1").arg(world.describeCommands()));
  });
  step(QStringLiteral("%1 is (un-settled|woken)").arg(q), [](World& world, const Captures& c, const Table&) {
    waitSection(world, c[0], QStringLiteral("active"));
    const QString expected = c[1] == QLatin1String("woken") ? QStringLiteral("thread.unsnooze") : QStringLiteral("thread.unsettle");
    expect(commandsSince(world) == QStringList{expected}, QStringLiteral("the MC has %1").arg(world.describeCommands()));
  });
  step(QStringLiteral("nothing happens to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(commandsSince(world).isEmpty() && sidebarSectionOf(world, threadKeyOf(world, c[0])) == QLatin1String("active"),
           QStringLiteral("the MC has %1").arg(world.describeCommands()));
  });
  step(QStringLiteral("no thread is pinned"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(titlesOf(world, QStringLiteral("pinned")).isEmpty(), QStringLiteral("the pinned threads are %1").arg(titlesOf(world, QStringLiteral("pinned")).join(QStringLiteral(", "))));
  });

  // The undo shortcut.
  // "the user is typing in the composer" is TerminalSteps': it puts text in the open thread's composer.
  step(QStringLiteral("the user presses the undo shortcut"), [](World& world, const Captures&, const Table&) {
    world.sync();
    scene(world).commandsBefore = world.mc.commands.size();
    auto* keys = world.native().controller<KeybindingController>();
    const auto shortcut = keybindings::parseShortcut(QStringLiteral("mod+z"));
    // The keyboard is in the composer while it holds what the user is typing.
    const bool typing = !world.state(QStringLiteral("composer")).toMap().value(QStringLiteral("text")).toString().isEmpty();
    expect(typing, QStringLiteral("the composer is %1").arg(show(world.state(QStringLiteral("composer")))));
    const QVariantMap focus{{QStringLiteral("composer"), true}, {QStringLiteral("editable"), true}};
    scene(world).shortcutTaken = keys->press(keybindings::sequence(*shortcut, false), focus);
    world.sync();
  });
  step(QStringLiteral("the text edit is undone"), [](World& world, const Captures&, const Table&) {
    // The shell leaves the key to the text field, which undoes its own edit.
    expect(!scene(world).shortcutTaken, QStringLiteral("the shell took the shortcut"));
  });
  step(QStringLiteral("%1 stays unpinned").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(commandsSince(world).isEmpty() && sidebarSectionOf(world, threadKeyOf(world, c[0])) == QLatin1String("active"),
           QStringLiteral("the MC has %1").arg(world.describeCommands()));
  });
});

}  // namespace
