// The palette's Add project beyond its sources (CloneSteps.cpp): which
// environment gets the project, one that goes away meanwhile, and the folder
// browser's paths (features/navigation/palette-add-project.feature).

#include <QJsonArray>

#include "CommandPaletteController.h"
#include "FakeFiles.h"
#include "Harness.h"
#include "KeybindingController.h"
#include "ShellStore.h"
#include "World.h"

namespace {

struct AddProject {
  QString highlighted;
};

CommandPaletteController& palette(World& world) {
  return *world.native().controller<CommandPaletteController>();
}

QString describe(World& world) {
  CommandPaletteController& model = palette(world);
  QStringList lines;
  for (int row = 0; row < model.count(); ++row) {
    lines.append(QStringLiteral("%1 (%2)%3").arg(model.index(row).data(CommandPaletteController::TitleRole).toString(),
                                                 model.index(row).data(CommandPaletteController::DescriptionRole).toString(),
                                                 model.index(row).data(CommandPaletteController::EnabledRole).toBool() ? QStringLiteral("") : QStringLiteral(" off")));
  }
  return QStringLiteral("the palette (%1 \"%2\", query \"%3\") lists [%4] and says \"%5\"")
      .arg(model.mode(), model.submenu(), model.query(), lines.join(QStringLiteral("; ")), model.emptyText());
}

int rowTitled(World& world, const QString& title) {
  CommandPaletteController& model = palette(world);
  for (int row = 0; row < model.count(); ++row) {
    if (model.index(row).data(CommandPaletteController::TitleRole) == title) return row;
  }
  return -1;
}

void choose(World& world, const QString& title) {
  const int row = rowTitled(world, title);
  expect(row >= 0 && palette(world).run(row), describe(world));
  world.sync();
}

// Add project, then Local folder, as the palette's entries.
void browse(World& world) {
  FakeFiles& files = fakeFiles(world.mc);
  for (const QString& folder : {QStringLiteral("/home/sam/code"), QStringLiteral("/home/sam/code/shop"), QStringLiteral("/home/sam/code/api")}) {
    files.folders.insert(folder);
  }
  CommandPaletteController& model = palette(world);
  if (!model.isOpen()) model.show();
  choose(world, QStringLiteral("Add project"));
  // With one environment it asks where the project comes from at once.
  if (rowTitled(world, QStringLiteral("Local folder")) < 0) choose(world, world.mc.environmentId);
  choose(world, QStringLiteral("Local folder"));
  expect(model.mode() == QLatin1String("browse"), describe(world));
}

void type(World& world, const QString& path) {
  palette(world).setQuery(path);
  world.waitFor([&] { return !palette(world).searching(); }, QStringLiteral("the folders to be listed"));
  world.sync();
}

QList<QJsonObject> created(World& world) {
  QList<QJsonObject> commands;
  for (const FakeMc::Rpc& rpc : std::as_const(world.mc.calls)) {
    if (rpc.method == QLatin1String("projects.mutate") && rpc.payload.value(QLatin1String("type")) == QLatin1String("project.create")) {
      commands.append(rpc.payload);
    }
  }
  return commands;
}

const Steps steps([] {
  const QString q = kQuoted;

  // Which environment.
  step(QStringLiteral("two environments are connected and one is disconnected"), [](World& world, const Captures&, const Table&) {
    world.mc.join(QStringLiteral("env-b"));
    world.mc.join(QStringLiteral("env-c"));
    world.mc.setOnline(QStringLiteral("env-c"), false);
    world.sync();
    auto* store = world.native().store();
    world.waitFor([&] { return store->environmentOnline(QStringLiteral("env-b")) && store->environments().contains(QStringLiteral("env-c")) &&
                               !store->environmentOnline(QStringLiteral("env-c")); },
                  QStringLiteral("the other environments"));
  });
  step(QStringLiteral("the palette lists \"This device\" and the other connected environment"), [](World& world, const Captures&, const Table&) {
    CommandPaletteController& model = palette(world);
    expect(model.submenu() == QLatin1String("Add project"), describe(world));
    const int own = rowTitled(world, world.mc.environmentId);
    const int other = rowTitled(world, QStringLiteral("env-b"));
    expect(own >= 0 && model.index(own).data(CommandPaletteController::DescriptionRole) == QLatin1String("This device") &&
               model.index(own).data(CommandPaletteController::EnabledRole).toBool() && other >= 0 &&
               model.index(other).data(CommandPaletteController::EnabledRole).toBool(),
           describe(world));
  });
  step(QStringLiteral("the disconnected environment cannot be chosen"), [](World& world, const Captures&, const Table&) {
    CommandPaletteController& model = palette(world);
    const int row = rowTitled(world, QStringLiteral("env-c"));
    expect(row >= 0 && !model.index(row).data(CommandPaletteController::EnabledRole).toBool() &&
               model.index(row).data(CommandPaletteController::DescriptionRole) == QLatin1String("Not connected") && !model.run(row) &&
               model.submenu() == QLatin1String("Add project"),
           describe(world));
  });
  step(QStringLiteral("the user chose an environment for a new project"), [](World& world, const Captures&, const Table&) {
    world.mc.join(QStringLiteral("env-b"));
    world.sync();
    world.waitFor([&] { return world.native().store()->environmentOnline(QStringLiteral("env-b")); }, QStringLiteral("the second environment"));
    fakeFiles(world.mc).folders.insert(QStringLiteral("/home/sam/code"));
    CommandPaletteController& model = palette(world);
    if (!model.isOpen()) model.show();
    choose(world, QStringLiteral("Add project"));
    choose(world, QStringLiteral("env-b"));
    choose(world, QStringLiteral("Local folder"));
    expect(model.mode() == QLatin1String("browse"), describe(world));
  });
  step(QStringLiteral("that environment disconnects before the project is added"), [](World& world, const Captures&, const Table&) {
    palette(world).setQuery(QStringLiteral("/srv/shop"));
    world.mc.setOnline(QStringLiteral("env-b"), false);
    world.sync();
    world.waitFor([&] { return !world.native().store()->environmentOnline(QStringLiteral("env-b")); }, QStringLiteral("the environment to go"));
    // The user adds the folder they typed.
    palette(world).addBrowsedFolder();
    world.sync();
    expect(created(world).isEmpty(), QStringLiteral("a project was created: %1").arg(show(QVariant::fromValue(created(world)))));
  });

  // The folder browser.
  step(QStringLiteral("the user is browsing for a project folder"), [](World& world, const Captures&, const Table&) { browse(world); });
  step(QStringLiteral("the user types a path that does not exist"), [](World& world, const Captures&, const Table&) {
    type(world, QStringLiteral("~/code/brand-new"));
    expect(palette(world).count() == 0, describe(world));
  });
  step(QStringLiteral("no project is active"), [](World& world, const Captures&, const Table&) {
    const QString kind = at(world.state(QStringLiteral("route")), QStringLiteral("kind")).toString();
    expect(kind != QLatin1String("thread") && kind != QLatin1String("draft"), show(world.state(QStringLiteral("route"))));
  });
  step(QStringLiteral("the user types a relative path while adding a project"), [](World& world, const Captures&, const Table&) {
    browse(world);
    type(world, QStringLiteral("code/shop"));
    // And it cannot be added.
    expect(!palette(world).addBrowsedFolder() && !palette(world).runHighlighted() && created(world).isEmpty(), describe(world));
  });
  step(QStringLiteral("a folder is highlighted"), [](World& world, const Captures&, const Table&) {
    type(world, QStringLiteral("~/code/"));
    CommandPaletteController& model = palette(world);
    const int row = rowTitled(world, QStringLiteral("api"));
    expect(row >= 0, describe(world));
    model.setHighlighted(row);
    world.mc.part<AddProject>().highlighted = model.idAt(row);
    expect(model.kindAt(row) == QLatin1String("folder") && world.mc.part<AddProject>().highlighted == QLatin1String("/home/sam/code/api"),
           describe(world));
  });
  // The brick's half, rows under a resting pointer, is tst_CommandPalette.qml's;
  // here the palette leaves them unhighlighted and Enter on what was typed.
  step(QStringLiteral("the pointer rests where the palette's entries appear"), [](World& world, const Captures&, const Table&) {
    browse(world);
  });
  step(QStringLiteral("the user types a folder path while adding a project"), [](World& world, const Captures&, const Table&) {
    type(world, QStringLiteral("/home/sam/code/shop"));
  });
  step(QStringLiteral("no entry is highlighted until the pointer moves"), [](World& world, const Captures&, const Table&) {
    expect(palette(world).count() > 0 && palette(world).highlighted() < 0, describe(world));
  });
  step(QStringLiteral("Enter adds the folder typed"), [](World& world, const Captures&, const Table&) {
    expect(palette(world).runHighlighted(), describe(world));
    world.sync();
    const QList<QJsonObject> commands = created(world);
    expect(commands.size() == 1 && commands.first().value(QLatin1String("workspaceRoot")) == QLatin1String("/home/sam/code/shop"),
           QStringLiteral("the MC was asked to create %1; %2").arg(show(QVariant::fromValue(commands)), describe(world)));
  });
  step(QStringLiteral("the highlighted folder is added as a project"), [](World& world, const Captures&, const Table&) {
    const QList<QJsonObject> commands = created(world);
    expect(commands.size() == 1 && commands.first().value(QLatin1String("workspaceRoot")) == world.mc.part<AddProject>().highlighted,
           QStringLiteral("the MC was asked to create %1; %2").arg(show(QVariant::fromValue(commands)), describe(world)));
    expect(!palette(world).isOpen(), describe(world));
  });
});

}  // namespace
