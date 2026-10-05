// Searching threads (features/threads/search.feature). The desktop searches
// threads in the command palette, which the thread list's Search opens
// (PaletteSteps.cpp): every environment's threads by title, and the messages
// of the environments that are online.

#include <QJsonArray>
#include <QJsonObject>

#include "CommandPaletteController.h"
#include "Harness.h"
#include "NavigationController.h"
#include "World.h"

namespace {

struct ThreadSearch {
  // The key of the result the user chose.
  QString chosen;
};

CommandPaletteController& palette(World& world) {
  return *world.native().controller<CommandPaletteController>();
}

void search(World& world, const QString& query) {
  world.sync();
  if (!palette(world).isOpen()) palette(world).show();
  palette(world).setQuery(query);
  world.sync();
  world.waitFor([&] { return !palette(world).searching(); }, QStringLiteral("the palette's searches to be answered"));
}

// The threads the palette lists, in order.
QStringList found(World& world) {
  QStringList titles;
  for (int row = 0; row < palette(world).count(); ++row) {
    if (palette(world).kindAt(row) == QLatin1String("thread")) {
      titles.append(palette(world).data(palette(world).index(row), CommandPaletteController::TitleRole).toString());
    }
  }
  return titles;
}

// The search is over: the palette is closed, and starts empty the next time.
bool cleared(World& world) {
  if (palette(world).isOpen()) return false;
  palette(world).show();
  const bool empty = palette(world).query().isEmpty();
  palette(world).dismiss();
  return empty;
}

QJsonObject thread(const QString& id, const QString& title, const QString& project) {
  const QString at = QStringLiteral("2026-09-23T09:30:00Z");
  return {{QStringLiteral("id"), id}, {QStringLiteral("title"), title}, {QStringLiteral("projectId"), project},
          {QStringLiteral("createdAt"), at}, {QStringLiteral("updatedAt"), at}};
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("the environment %1 has the thread %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.join(c[0]);
    world.mc.sendPeerRow(c[0], QStringLiteral("thread-linked"), thread(QStringLiteral("thread-linked"), c[1], QStringLiteral("admin")));
    world.sync();
  });
  step(QStringLiteral("the user searches threads for %1").arg(q), [](World& world, const Captures& c, const Table&) { search(world, c[0]); });
  step(QStringLiteral("%1 and %1 are both found").arg(q), [](World& world, const Captures& c, const Table&) {
    const QStringList titles = found(world);
    expect(titles.contains(c[0]) && titles.contains(c[1]), QStringLiteral("the search finds %1").arg(titles.join(QStringLiteral(", "))));
  });
  step(QStringLiteral("results from the reachable environments are shown"), [](World& world, const Captures&, const Table&) {
    expect(found(world).contains(QStringLiteral("Add dark mode")), QStringLiteral("the search finds %1").arg(found(world).join(QStringLiteral(", "))));
  });
  step(QStringLiteral("the user can tell %1 was not searched").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(palette(world).status() == QStringLiteral("Not searched (offline): %1").arg(c[0]),
           QStringLiteral("the palette says \"%1\"").arg(palette(world).status()));
  });

  // The keyboard.
  step(QStringLiteral("the thread search shows three results"), [](World& world, const Captures&, const Table&) {
    const QString project = world.mc.projects.firstKey();
    for (const QString& name : {QStringLiteral("one"), QStringLiteral("two"), QStringLiteral("three")}) {
      const QString id = QStringLiteral("thread-quokka-") + name;
      world.mc.threads.insert(id, thread(id, QStringLiteral("Quokka ") + name, project));
      world.mc.sendRow(id, world.mc.threads.value(id));
    }
    search(world, QStringLiteral("quokka"));
    expect(palette(world).count() == 3 && found(world).size() == 3, QStringLiteral("the search finds %1").arg(found(world).join(QStringLiteral(", "))));
    palette(world).setHighlighted(0);
  });
  step(QStringLiteral("the user moves down past the last result"), [](World& world, const Captures&, const Table&) {
    for (int press = 0; press < palette(world).count(); ++press) palette(world).move(1);
  });
  step(QStringLiteral("the first result is highlighted again"), [](World& world, const Captures&, const Table&) {
    expect(palette(world).highlighted() == 0, QStringLiteral("row %1 is highlighted").arg(palette(world).highlighted()));
  });
  step(QStringLiteral("the user chooses the highlighted result"), [](World& world, const Captures&, const Table&) {
    world.mc.part<ThreadSearch>().chosen = palette(world).idAt(palette(world).highlighted());
    expect(palette(world).runHighlighted(), QStringLiteral("nothing ran"));
  });
  step(QStringLiteral("that thread opens and the search is cleared"), [](World& world, const Captures&, const Table&) {
    const QString chosen = world.mc.part<ThreadSearch>().chosen;
    world.waitFor([&] { return world.native().controller<NavigationController>()->threadKey() == chosen; },
                  [&] { return QStringLiteral("%1 to open; the route is %2").arg(chosen, show(world.state(QStringLiteral("route")))); });
    expect(!chosen.isEmpty() && cleared(world), QStringLiteral("the search is still there: \"%1\"").arg(palette(world).query()));
  });

  // Leaving.
  step(QStringLiteral("the user is searching threads"), [](World& world, const Captures&, const Table&) {
    search(world, QStringLiteral("dark"));
    expect(found(world) == QStringList{QStringLiteral("Add dark mode")}, QStringLiteral("the search finds %1").arg(found(world).join(QStringLiteral(", "))));
  });
  step(QStringLiteral("the user dismisses the search"), [](World& world, const Captures&, const Table&) { palette(world).dismiss(); });
  step(QStringLiteral("the full thread list is shown again"), [](World& world, const Captures&, const Table&) {
    // The search never narrows the list itself: both threads are still there.
    QStringList titles;
    for (const QVariant& row : at(world.state(QStringLiteral("sidebar")), QStringLiteral("active")).toList()) titles.append(row.toMap().value(QStringLiteral("title")).toString());
    titles.sort();
    expect(cleared(world) && titles == QStringList{QStringLiteral("Add dark mode"), QStringLiteral("Fix OAuth loop")},
           QStringLiteral("the list shows %1").arg(titles.join(QStringLiteral(", "))));
  });
});

}  // namespace
