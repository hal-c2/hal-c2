// The command palette (CommandPaletteController,
// features/navigation/command-palette.feature, and opening it from the
// thread list in features/threads/search.feature): a project with more threads
// than the palette's recent list holds, threads on linked environments and
// other nodes of the cluster, and the palette driven as the CommandPalette
// brick drives it. The brick's own keys (mod+1..9) are in KeybindingSteps.cpp.

#include <QJsonArray>

#include "CommandPaletteController.h"
#include "Harness.h"
#include "KeybindingController.h"
#include "Keybindings.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "NodeClient.h"
#include "Stream.h"
#include "World.h"

namespace {

using stream::iso;

const QString kProject = QStringLiteral("hal-c2");
constexpr int kBackgroundThreads = 14;

struct PaletteState {
  bool hooked = false;
  int minute = 0;
  // Thread keys by title, oldest first.
  QHash<QString, QStringList> keys;
  // The thread a scenario is about.
  QString that;
  // What the palette listed when it was opened, as "kind\nid".
  QStringList listed;
  QStringList ran;
};

PaletteState& state(World& world) {
  return world.node.part<PaletteState>();
}

CommandPaletteController& palette(World& world) {
  auto* palette = world.native().controller<CommandPaletteController>();
  if (!palette) fail(QStringLiteral("the shell has no command palette"));
  PaletteState& fake = state(world);
  if (!fake.hooked) {
    fake.hooked = true;
    QObject::connect(world.native().controller<KeybindingController>()->commands(), &CommandRegistry::ran, palette,
                     [&fake](const QString& command) { fake.ran.append(command); });
  }
  return *palette;
}

struct Listed {
  QString title;
  QString description;
  QString group;
  QString kind;
  QString id;
};

QList<Listed> rows(World& world) {
  world.sync();
  CommandPaletteController& model = palette(world);
  QList<Listed> out;
  for (int row = 0; row < model.rowCount(); ++row) {
    const QModelIndex index = model.index(row);
    out.append({index.data(CommandPaletteController::TitleRole).toString(),
                index.data(CommandPaletteController::DescriptionRole).toString(),
                index.data(CommandPaletteController::GroupRole).toString(), model.kindAt(row), model.idAt(row)});
  }
  return out;
}

QString describe(World& world) {
  QStringList lines;
  for (const Listed& row : rows(world)) lines << QStringLiteral("%1: %2 (%3)").arg(row.group, row.title, row.description);
  return QStringLiteral("the palette (%1, query \"%2\") lists [%3]")
      .arg(palette(world).isOpen() ? u"open"_qs : u"closed"_qs, palette(world).query(), lines.join(u"; "));
}

int indexOf(World& world, const QString& title, const QString& kind = {}) {
  const QList<Listed> listed = rows(world);
  for (int row = 0; row < listed.size(); ++row) {
    if (listed.at(row).title == title && (kind.isEmpty() || listed.at(row).kind == kind)) return row;
  }
  return -1;
}

// mod+k, as the window's shortcut hands it to the shell.
void pressToggle(World& world) {
  palette(world);
  auto* keys = world.native().controller<KeybindingController>();
  const auto shortcut = keybindings::parseShortcut(QStringLiteral("mod+k"));
  keys->press(keybindings::sequence(*shortcut, false));
  world.sync();
}

void open(World& world) {
  if (!world.native().client()->isReady()) {
    world.connect();
    world.waitFor([&world] { return world.state(QStringLiteral("native")).isValid(); }, QStringLiteral("the shell to take over"));
  }
  if (!palette(world).isOpen()) pressToggle(world);
  expect(palette(world).isOpen(), describe(world));
  PaletteState& fake = state(world);
  fake.listed.clear();
  for (const Listed& row : rows(world)) fake.listed << row.kind + QLatin1Char('\n') + row.id;
}

void search(World& world, const QString& query) {
  open(world);
  palette(world).setQuery(query);
}

void addProject(World& world, const QString& id) {
  const QJsonObject row{{QStringLiteral("id"), id},
                        {QStringLiteral("title"), id},
                        {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + id},
                        {QStringLiteral("createdAt"), iso(stream::now())},
                        {QStringLiteral("updatedAt"), iso(stream::now())},
                        {QStringLiteral("scripts"), QJsonArray()}};
  world.node.projects.insert(id, row);
  world.node.sendRow(id, row, QStringLiteral("project"));
}

// A thread newer than every one before it, on this node unless `environment`
// (a linked one) or `peer` (another node of the cluster) serves it.
QString addThread(World& world, const QString& title, QJsonObject row = {}, const QString& environment = {},
                  const QString& peer = {}) {
  PaletteState& fake = state(world);
  const QString at = iso(stream::now().addSecs(60 * ++fake.minute));
  const QString id = row.value(QLatin1String("id")).toString(QStringLiteral("thread-%1").arg(fake.minute));
  row.insert(QStringLiteral("id"), id);
  row.insert(QStringLiteral("title"), title);
  if (!row.contains(QLatin1String("projectId"))) row.insert(QStringLiteral("projectId"), kProject);
  row.insert(QStringLiteral("createdAt"), at);
  row.insert(QStringLiteral("updatedAt"), at);
  QString key;
  if (!environment.isEmpty()) {
    world.node.sendLinkRow(environment, id, row);
    key = environment + QLatin1Char(':') + id;
  } else if (!peer.isEmpty()) {
    world.node.sendRows(peer, QJsonArray{QJsonArray{id, QStringLiteral("thread"), row}});
    key = stream::kPeerEnvironment + QLatin1Char(':') + id;
  } else {
    world.node.threads.insert(id, row);
    world.node.sendRow(id, row);
    key = world.node.environmentId + QLatin1Char(':') + id;
  }
  world.sync();
  fake.keys[title].append(key);
  fake.that = key;
  return key;
}

QString keyOf(World& world, const QString& title) {
  const QStringList keys = state(world).keys.value(title);
  if (keys.isEmpty()) fail(QStringLiteral("no thread \"%1\"").arg(title));
  return keys.last();
}

const Steps steps([] {
  const QString q = kQuoted;

  // Background.
  step(QStringLiteral("the user has a project %1 with threads").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(c[0] == kProject, QStringLiteral("the palette's steps know the project \"%1\"").arg(kProject));
    addProject(world, kProject);
    world.connect();
    world.sync();
    // More than the recent list holds.
    for (int n = 1; n <= kBackgroundThreads; ++n) addThread(world, QStringLiteral("Chore %1").arg(n));
    // What the brick hands over from js/settingsPages.js.
    palette(world).setSettingsSections(
        {QVariantMap{{QStringLiteral("to"), QStringLiteral("/settings/general")},
                     {QStringLiteral("label"), QStringLiteral("General")},
                     {QStringLiteral("keywords"), QStringLiteral("time format diff layout")}},
         QVariantMap{{QStringLiteral("to"), QStringLiteral("/settings/appearance")},
                     {QStringLiteral("label"), QStringLiteral("Appearance")},
                     {QStringLiteral("keywords"), QStringLiteral("theme light dark font size word wrap")}}});
  });
  step(QStringLiteral("the user is looking at a thread in that project"), [](World& world, const Captures&, const Table&) {
    world.native().controller<NavigationController>()->open(
        NavigationController::Route::thread(keyOf(world, QStringLiteral("Chore %1").arg(kBackgroundThreads))));
    world.sync();
  });

  // features/threads/search.feature.
  step(QStringLiteral("a connected environment with the threads %1 and %1 in the project %1").arg(q),
       [](World& world, const Captures& c, const Table&) {
         addProject(world, c[2]);
         world.connect();
         world.sync();
         for (const QString& title : {c[0], c[1]}) addThread(world, title, {{QStringLiteral("projectId"), c[2]}});
       });
  // The sidebar's Search button (tst_Sidebar.qml).
  step(QStringLiteral("the user starts a search from the thread list"), [](World& world, const Captures&, const Table&) {
    palette(world).show();
  });
  step(QStringLiteral("the command palette opens ready to search threads"), [](World& world, const Captures&, const Table&) {
    QStringList recent;
    for (const Listed& row : rows(world)) {
      if (row.group == u"Recent Threads") recent << row.title;
    }
    expect(palette(world).isOpen() && palette(world).query().isEmpty() &&
               recent == QStringList{QStringLiteral("Add dark mode"), QStringLiteral("Fix OAuth loop")},
           describe(world));
  });

  // Threads.
  step(QStringLiteral("the thread %1 is archived").arg(q), [](World& world, const Captures& c, const Table&) {
    addThread(world, c[0], {{QStringLiteral("archivedAt"), iso(stream::now())}});
  });
  step(QStringLiteral("the thread %1 is on branch %1").arg(q), [](World& world, const Captures& c, const Table&) {
    addThread(world, c[0], {{QStringLiteral("branch"), c[1]}});
  });
  step(QStringLiteral("the thread %1 is on (a linked environment|another node of the cluster)").arg(q),
       [](World& world, const Captures& c, const Table&) {
         if (c[1] == QLatin1String("a linked environment")) {
           world.node.link(QStringLiteral("laptop"));
           world.sync();
           addThread(world, c[0], {}, QStringLiteral("laptop"));
         } else {
           world.node.join(stream::kPeer, stream::kPeerEnvironment);
           world.sync();
           addThread(world, c[0], {}, {}, stream::kPeer);
         }
       });
  step(QStringLiteral("threads titled %1, %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    for (const QString& title : c) addThread(world, title);
  });
  step(QStringLiteral("two threads titled %1 and %1 with the second updated more recently").arg(q),
       [](World& world, const Captures& c, const Table&) {
         addThread(world, c[0]);
         addThread(world, c[1]);
       });
  step(QStringLiteral("a thread whose (title|linked pull request|project name|branch|id) contains %1").arg(q),
       [](World& world, const Captures& c, const Table&) {
         const QString word = c[1];
         if (c[0] == QLatin1String("title")) {
           addThread(world, QStringLiteral("Paint the %1").arg(word));
         } else if (c[0] == QLatin1String("linked pull request")) {
           const QJsonObject link{{QStringLiteral("number"), 7},
                                  {QStringLiteral("repository"), QStringLiteral("acme/shop")},
                                  {QStringLiteral("url"), QStringLiteral("https://github.com/acme/shop/pull/7")},
                                  {QStringLiteral("source"), QStringLiteral("manual")},
                                  {QStringLiteral("snapshot"), QJsonObject{{QStringLiteral("title"), QStringLiteral("Add %1 stripes").arg(word)}}}};
           addThread(world, QStringLiteral("Tidy"), {{QStringLiteral("pullRequests"), QJsonArray{link}}});
         } else if (c[0] == QLatin1String("project name")) {
           addProject(world, word + QStringLiteral("-lab"));
           addThread(world, QStringLiteral("Tidy"), {{QStringLiteral("projectId"), word + QStringLiteral("-lab")}});
         } else if (c[0] == QLatin1String("branch")) {
           addThread(world, QStringLiteral("Tidy"), {{QStringLiteral("branch"), QStringLiteral("feature/") + word}});
         } else {
           addThread(world, QStringLiteral("Tidy"), {{QStringLiteral("id"), QStringLiteral("thread-") + word}});
         }
       });

  // Opening and closing.
  step(QStringLiteral("the user presses the command palette shortcut"), [](World& world, const Captures&, const Table&) {
    pressToggle(world);
  });
  step(QStringLiteral("the user opens the command palette"), [](World& world, const Captures&, const Table&) {
    open(world);
  });
  step(QStringLiteral("the command palette is (open|closed)"), [](World& world, const Captures& c, const Table&) {
    if (!world.checking && c[0] == QLatin1String("open")) open(world);
    expect(palette(world).isOpen() == (c[0] == QLatin1String("open")), describe(world));
  });
  step(QStringLiteral("the user dismisses the command palette"), [](World& world, const Captures&, const Table&) {
    palette(world).dismiss();
  });
  // The brick focuses its field whenever the palette opens (tst_CommandPalette.qml);
  // here the palette staying open, with what the user typed, is what counts.
  step(QStringLiteral("the (?:search field|command palette search still) has keyboard focus"), [](World& world, const Captures&, const Table&) {
    expect(palette(world).isOpen(), describe(world));
  });
  step(QStringLiteral("the search field is empty"), [](World& world, const Captures&, const Table&) {
    expect(palette(world).query().isEmpty(), describe(world));
  });
  step(QStringLiteral("a background update changes the thread list"), [](World& world, const Captures&, const Table&) {
    const QString before = palette(world).idAt(palette(world).highlighted());
    addThread(world, QStringLiteral("Arrived meanwhile"));
    expect(palette(world).idAt(palette(world).highlighted()) == before, QStringLiteral("the highlight moved off %1: %2").arg(before, describe(world)));
  });

  // Searching.
  step(QStringLiteral("the user types %1").arg(q), [](World& world, const Captures& c, const Table&) {
    open(world);
    palette(world).setQuery(palette(world).query() + c[0]);
  });
  step(QStringLiteral("the user searches the palette for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    search(world, c[0]);
  });

  // What it lists.
  step(QStringLiteral("the palette shows an? %1 group").arg(q), [](World& world, const Captures& c, const Table&) {
    const QList<Listed> listed = rows(world);
    expect(std::any_of(listed.cbegin(), listed.cend(), [&](const Listed& row) { return row.group == c[0]; }), describe(world));
  });
  step(QStringLiteral("the palette shows an? %1 group of at most (\\d+) threads").arg(q), [](World& world, const Captures& c, const Table&) {
    QStringList threads;
    for (const Listed& row : rows(world)) {
      if (row.group == c[0]) threads << row.title;
    }
    // The Background has more threads than fit, the newest first.
    expect(threads.size() == c[1].toInt() && threads.first() == QStringLiteral("Chore %1").arg(kBackgroundThreads),
           describe(world));
  });
  step(QStringLiteral("%1 is not listed").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(indexOf(world, c[0]) < 0, describe(world));
  });
  step(QStringLiteral("%1 is described with the project %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const int row = indexOf(world, c[0], QStringLiteral("thread"));
    expect(row >= 0 && rows(world).at(row).description == c[1] + u" · " + c[2], describe(world));
  });
  step(QStringLiteral("the thread the user is looking at is described as %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString current = world.native().controller<NavigationController>()->threadKey();
    const QList<Listed> listed = rows(world);
    const auto row = std::find_if(listed.cbegin(), listed.cend(), [&](const Listed& entry) { return entry.id == current; });
    expect(row != listed.cend() && row->description.endsWith(c[0]), describe(world));
    const int marked = static_cast<int>(std::count_if(listed.cbegin(), listed.cend(), [&](const Listed& entry) {
      return entry.description.endsWith(c[0]);
    }));
    expect(marked == 1, describe(world));
  });
  step(QStringLiteral("%1 is listed before %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const int first = indexOf(world, c[0]);
    const int second = indexOf(world, c[1]);
    expect(first >= 0 && second >= 0 && first < second, describe(world));
  });
  step(QStringLiteral("the more recently updated thread is listed first"), [](World& world, const Captures&, const Table&) {
    const int row = indexOf(world, QStringLiteral("Refactor"), QStringLiteral("thread"));
    expect(row >= 0 && palette(world).idAt(row) == keyOf(world, QStringLiteral("Refactor")), describe(world));
  });
  step(QStringLiteral("that thread is listed"), [](World& world, const Captures&, const Table&) {
    const QList<Listed> listed = rows(world);
    expect(std::any_of(listed.cbegin(), listed.cend(),
                       [&](const Listed& row) { return row.group == u"Threads" && row.id == state(world).that; }),
           describe(world));
  });
  step(QStringLiteral("only actions are listed"), [](World& world, const Captures&, const Table&) {
    const QList<Listed> listed = rows(world);
    expect(!listed.isEmpty() && std::all_of(listed.cbegin(), listed.cend(), [](const Listed& row) { return row.kind == u"action"; }),
           describe(world));
  });
  step(QStringLiteral("the palette says %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(palette(world).count() == 0 && palette(world).emptyText() == c[0], describe(world));
  });

  // Choosing entries.
  step(QStringLiteral("the command palette lists %1").arg(q), [](World& world, const Captures& c, const Table&) {
    open(world);
    expect(indexOf(world, c[0]) >= 0, describe(world));
  });
  step(QStringLiteral("the user moves the highlight to %1 and presses Enter").arg(q), [](World& world, const Captures& c, const Table&) {
    CommandPaletteController& model = palette(world);
    for (int moves = 0; moves < model.count() && model.data(model.index(model.highlighted()), CommandPaletteController::TitleRole) != c[0];
         ++moves) {
      model.move(1);
    }
    expect(model.runHighlighted(), describe(world));
    world.sync();
  });
  step(QStringLiteral("the third listed entry runs"), [](World& world, const Captures&, const Table&) {
    const PaletteState& fake = state(world);
    const QStringList entry = fake.listed.value(2).split(QLatin1Char('\n'));
    expect(entry.first() == u"action" && fake.ran.contains(entry.last()),
           QStringLiteral("listed %1, ran %2").arg(fake.listed.join(u", "), fake.ran.join(u", ")));
    expect(!palette(world).isOpen(), describe(world));
  });
  step(QStringLiteral("settings open"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(at(world.state(QStringLiteral("route")), QStringLiteral("kind")).toString() == u"settings", show(world.state(QStringLiteral("route"))));
  });
  step(QStringLiteral("the usage page opens"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(at(world.state(QStringLiteral("route")), QStringLiteral("kind")).toString() == u"usage", show(world.state(QStringLiteral("route"))));
  });
});

}  // namespace
