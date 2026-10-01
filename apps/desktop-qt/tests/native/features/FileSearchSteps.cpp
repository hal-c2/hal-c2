// Finding files by name and text across a project from the command palette's
// go to file and project search modes (features/files/search.feature), against
// the files FakeFiles holds.

#include <QJsonObject>

#include "CommandPaletteController.h"
#include "FakeFiles.h"
#include "Harness.h"
#include "NavigationController.h"
#include "RightPanelController.h"
#include "Stream.h"
#include "WorkspaceFiles.h"
#include "World.h"

namespace {

using stream::lookAtThread;

// The content search's query, kept until the user searches.
struct PendingSearch {
  QString query;
  bool regex = false;
};

CommandPaletteController& palette(World& world) {
  auto* palette = world.native().controller<CommandPaletteController>();
  if (!palette) fail(QStringLiteral("the shell has no command palette"));
  return *palette;
}

// Waits for the palette's answers from the MC.
void settle(World& world) {
  world.sync();
  world.waitFor([&world] { return !palette(world).searching(); }, QStringLiteral("the palette's searches to be answered"));
}

QString describe(World& world) {
  CommandPaletteController& model = palette(world);
  QStringList rows;
  for (int row = 0; row < model.rowCount(); ++row) {
    rows << QStringLiteral("%1: %2 %3").arg(model.index(row).data(CommandPaletteController::GroupRole).toString(), model.kindAt(row), model.idAt(row));
  }
  return QStringLiteral("the palette (%1, query \"%2\", says \"%3\", status \"%4\") lists [%5]")
      .arg(model.mode(), model.query(), model.emptyText(), model.status(), rows.join(u"; "));
}

void searchIn(World& world, const QString& mode, const QString& query) {
  CommandPaletteController& model = palette(world);
  if (!model.isOpen() || model.mode() != mode) model.toggleMode(mode);
  model.setQuery(query);
  settle(world);
}

int rowOf(World& world, const QString& kind, const QString& id = {}) {
  CommandPaletteController& model = palette(world);
  for (int row = 0; row < model.rowCount(); ++row) {
    if (model.kindAt(row) == kind && (id.isEmpty() || model.idAt(row) == id || model.idAt(row).startsWith(id + u':'))) return row;
  }
  return -1;
}

WorkspaceFiles& files(World& world) {
  return *world.native().controller<RightPanelController>()->files();
}

void opens(World& world, const QString& path, int line) {
  world.waitFor([&] { return files(world).openPath() == path && (line < 0 || files(world).revealLine() == line); },
                [&] { return QStringLiteral("the viewer shows \"%1\" at line %2").arg(files(world).openPath()).arg(files(world).revealLine()); });
  expect(!palette(world).isOpen(), describe(world));
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("%1 holds %1, %1, %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    FakeFiles& fake = fakeFiles(world.mc);
    for (const QString& path : {c[1], c[2], c[3], c[4]}) fake.files.insert(path, QStringLiteral("// %1\n").arg(path));
    lookAtThread(world, c[0]);
  });
  step(QStringLiteral("%1 contains the line %1").arg(q), [](World& world, const Captures& c, const Table&) {
    fakeFiles(world.mc).files[c[0]].append(c[1] + QLatin1Char('\n'));
  });

  // Go to file.
  step(QStringLiteral("the user goes to a file and types %1").arg(q), [](World& world, const Captures& c, const Table&) {
    searchIn(world, QStringLiteral("files"), c[0]);
  });
  // "the user picks" a file is SidebarSteps' step, from the open palette.
  step(QStringLiteral("%1 opens in the viewer").arg(q), [](World& world, const Captures& c, const Table&) { opens(world, c[0], -1); });
  step(QStringLiteral("the user is told no files match"), [](World& world, const Captures&, const Table&) {
    settle(world);
    expect(palette(world).count() == 0 && palette(world).emptyText() == u"No matching files.", describe(world));
  });

  // Project search.
  step(QStringLiteral("the user searches the project contents for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    searchIn(world, QStringLiteral("content"), c[0]);
  });
  step(QStringLiteral("the user searched the project contents of %1 for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    searchIn(world, QStringLiteral("content"), c[1]);
    expect(palette(world).count() > 0, describe(world));
  });
  step(QStringLiteral("the matches are grouped under %1").arg(q), [](World& world, const Captures& c, const Table&) {
    CommandPaletteController& model = palette(world);
    const int row = rowOf(world, QStringLiteral("match"), c[0]);
    expect(row >= 0 && model.index(row).data(CommandPaletteController::GroupRole) == c[0], describe(world));
  });
  step(QStringLiteral("the user opens the match"), [](World& world, const Captures&, const Table&) {
    const int row = rowOf(world, QStringLiteral("match"));
    expect(row >= 0 && palette(world).run(row), describe(world));
    world.sync();
  });
  step(QStringLiteral("%1 opens at the matching line").arg(q), [](World& world, const Captures& c, const Table&) {
    const QStringList lines = fakeFiles(world.mc).files.value(c[0]).split(QLatin1Char('\n'));
    int line = -1;
    for (int n = 0; n < lines.size() && line < 0; ++n) {
      if (lines.at(n).contains(QLatin1String("Total"))) line = n + 1;
    }
    opens(world, c[0], line);
  });
  step(QStringLiteral("the user sees how many results were found in how many files"), [](World& world, const Captures&, const Table&) {
    CommandPaletteController& model = palette(world);
    QSet<QString> files;
    int matches = 0;
    for (int row = 0; row < model.rowCount(); ++row) {
      if (model.kindAt(row) != u"match") continue;
      ++matches;
      files.insert(model.index(row).data(CommandPaletteController::GroupRole).toString());
    }
    expect(matches > 0 && model.status() == QStringLiteral("%1 results in %2 files").arg(matches).arg(files.size()), describe(world));
  });
  step(QStringLiteral("the query is empty"), [](World& world, const Captures&, const Table&) {
    world.mc.part<PendingSearch>() = {};
  });
  step(QStringLiteral("nothing matches %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.part<PendingSearch>() = {c[0], false};
  });
  step(QStringLiteral("the query is the regular expression %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.part<PendingSearch>() = {c[0], true};
  });
  step(QStringLiteral("no project is open"), [](World& world, const Captures&, const Table&) {
    world.native().controller<NavigationController>()->open(NavigationController::Route::of(QStringLiteral("usage")));
    world.sync();
  });
  step(QStringLiteral("the user searches the project contents"), [](World& world, const Captures&, const Table&) {
    const PendingSearch pending = world.mc.part<PendingSearch>();
    palette(world).setUseRegex(pending.regex);
    searchIn(world, QStringLiteral("content"), pending.query);
  });
  step(QStringLiteral("the user switches to the project %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.projects.insert(c[0], {{QStringLiteral("id"), c[0]}, {QStringLiteral("title"), c[0]},
                                      {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + c[0]}, {QStringLiteral("scripts"), QJsonArray()}});
    world.mc.sendRow(c[0], world.mc.projects.value(c[0]), QStringLiteral("project"));
    lookAtThread(world, c[0]);
  });
  step(QStringLiteral("the content search is empty"), [](World& world, const Captures&, const Table&) {
    settle(world);
    CommandPaletteController& model = palette(world);
    expect(model.mode() == u"content" && model.query().isEmpty() && model.count() == 0 && model.status().isEmpty(), describe(world));
  });
});

}  // namespace
