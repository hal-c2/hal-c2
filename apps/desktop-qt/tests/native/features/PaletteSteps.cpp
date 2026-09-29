// The command palette (CommandPaletteController,
// features/navigation/command-palette.feature, and opening it from the
// thread list in features/threads/search.feature): a project with more threads
// than the palette's recent list holds, threads on linked environments and
// other nodes of the cluster, and the palette driven as the CommandPalette
// brick drives it. The brick's own keys (mod+1..9) are in KeybindingSteps.cpp.

#include <QJSEngine>
#include <QJsonArray>

#include <memory>

#include "CommandPaletteController.h"
#include "DraftController.h"
#include "FakeFiles.h"
#include "Harness.h"
#include "KeybindingController.h"
#include "Keybindings.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "NodeClient.h"
#include "RightPanelController.h"
#include "SettingsController.h"
#include "Stream.h"
#include "ThemeController.h"
#include "ThreadPullRequests.h"
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
  // What runs "an action that will fail".
  std::unique_ptr<QJSEngine> engine;
};

// What each thread's messages say (by thread id, on this node), for
// `orchestration.searchThreads`; answers wait while the node holds "messages".
struct FakeMessages {
  QHash<QString, QString> text;
  int asked = 0;
};

const FakeNode::Extension messages([](FakeNode& node) {
  node.onRpc(QStringLiteral("orchestration.searchThreads"), [&node](const FakeNode::Rpc& rpc) {
    FakeMessages& fake = node.part<FakeMessages>();
    ++fake.asked;
    const auto answer = [&node, rpc] {
      const QString query = rpc.payload.value(QLatin1String("query")).toString();
      QJsonArray matches;
      if (rpc.environment.isEmpty() || rpc.environment == node.environmentId) {
        const FakeMessages& fake = node.part<FakeMessages>();
        for (auto it = fake.text.cbegin(); it != fake.text.cend(); ++it) {
          if (it->contains(query, Qt::CaseInsensitive)) {
            matches.append(QJsonObject{{QStringLiteral("threadId"), it.key()}, {QStringLiteral("snippet"), *it}});
          }
        }
      }
      node.reply(rpc, QJsonObject{{QStringLiteral("matches"), matches}});
    };
    if (node.holding(QStringLiteral("messages"))) {
      node.defer(answer);
    } else {
      answer();
    }
  });
});

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
  // What the palette lists once its searches against the node are answered.
  world.waitFor([&model] { return !model.searching(); }, QStringLiteral("the palette's searches to be answered"));
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

// A shortcut (mod+k by default), as the window's shortcut hands it to the shell.
void pressToggle(World& world, const QString& key = QStringLiteral("mod+k")) {
  palette(world);
  auto* keys = world.native().controller<KeybindingController>();
  const auto shortcut = keybindings::parseShortcut(key);
  keys->press(keybindings::sequence(*shortcut, false));
  world.sync();
}

// A mode as the scenarios name it, as the palette names it, and its key.
QString modeOf(const QString& name) {
  return name == u"go to file" ? QStringLiteral("files") : name == u"project search" ? QStringLiteral("content") : QStringLiteral("command");
}
QString shortcutOf(const QString& name) {
  return name == u"go to file" ? QStringLiteral("mod+p") : name == u"project search" ? QStringLiteral("mod+shift+f") : QStringLiteral("mod+k");
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

// This node's environment with `changes` to what it can do, as the node says
// when a capability changes.
void setCapabilities(World& world, const QJsonObject& changes) {
  QJsonObject capabilities = world.node.capabilities;
  for (auto it = changes.begin(); it != changes.end(); ++it) capabilities.insert(it.key(), it.value());
  world.node.send({{QStringLiteral("t"), QStringLiteral("shell.environment")},
                   {QStringLiteral("id"), world.node.subscribers(QStringLiteral("shell")).value(0)},
                   {QStringLiteral("node"), world.node.name},
                   {QStringLiteral("environment"), QJsonObject{{QStringLiteral("environmentId"), world.node.environmentId},
                                                               {QStringLiteral("capabilities"), capabilities}}}});
  world.sync();
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
    // Projects and a thread for a query to find besides actions and settings.
    addProject(world, QStringLiteral("theme-lab"));
    addProject(world, QStringLiteral("docs-site"));
    world.connect();
    world.sync();
    addThread(world, QStringLiteral("Tweak theme colors"));
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
  step(QStringLiteral("a thread titled %1").arg(q), [](World& world, const Captures& c, const Table&) { addThread(world, c[0]); });
  step(QStringLiteral("threads titled %1, %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    for (const QString& title : c) addThread(world, title);
  });
  step(QStringLiteral("two threads titled %1 and %1 with the second updated more recently").arg(q),
       [](World& world, const Captures& c, const Table&) {
         addThread(world, c[0]);
         addThread(world, c[1]);
       });
  step(QStringLiteral("a thread whose (title|linked pull request|project name|branch|id|message content) contains %1").arg(q),
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
         } else if (c[0] == QLatin1String("message content")) {
           addThread(world, QStringLiteral("Tidy"), {{QStringLiteral("id"), QStringLiteral("thread-talk")}});
           world.node.part<FakeMessages>().text.insert(QStringLiteral("thread-talk"), QStringLiteral("The %1 crossing is striped").arg(word));
         } else if (c[0] == QLatin1String("branch")) {
           addThread(world, QStringLiteral("Tidy"), {{QStringLiteral("branch"), QStringLiteral("feature/") + word}});
         } else {
           addThread(world, QStringLiteral("Tidy"), {{QStringLiteral("id"), QStringLiteral("thread-") + word}});
         }
       });

  // Opening and closing.
  step(QStringLiteral("the user presses the (command palette|command|go to file|project search) shortcut"),
       [](World& world, const Captures& c, const Table&) { pressToggle(world, shortcutOf(c[0])); });
  step(QStringLiteral("the command palette is open in (command|go to file|project search) mode"), [](World& world, const Captures& c, const Table&) {
    const QString mode = modeOf(c[0]);
    if (!world.checking) {
      open(world);
      if (palette(world).mode() != mode) palette(world).toggleMode(mode);
    }
    expect(palette(world).isOpen() && palette(world).mode() == mode, describe(world) + u" in " + palette(world).mode());
  });
  step(QStringLiteral("no other palette mode is open"), [](World& world, const Captures&, const Table&) {
    expect(palette(world).submenu().isEmpty(), QStringLiteral("the palette shows the submenu %1").arg(palette(world).submenu()));
  });
  step(QStringLiteral("the palette is in (go to file|project search) mode"), [](World& world, const Captures& c, const Table&) {
    expect(palette(world).isOpen() && palette(world).mode() == modeOf(c[0]), describe(world) + u" in " + palette(world).mode());
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
  // Entries by kind, where a setting and a thread share a title.
  step(QStringLiteral("the %1 setting is listed before the thread %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const int first = indexOf(world, c[0], QStringLiteral("setting"));
    const int second = indexOf(world, c[1], QStringLiteral("thread"));
    expect(first >= 0 && second >= 0 && first < second, describe(world));
  });
  step(QStringLiteral("%1 is listed before the %1 setting").arg(q), [](World& world, const Captures& c, const Table&) {
    const int first = indexOf(world, c[0]);
    const int second = indexOf(world, c[1], QStringLiteral("setting"));
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
    rows(world);
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
  // Groups and submenus.
  step(QStringLiteral("matching actions, projects, settings and threads are listed in their own groups"),
       [](World& world, const Captures&, const Table&) {
         QStringList groups;
         for (const Listed& row : rows(world)) {
           if (!groups.contains(row.group)) groups << row.group;
         }
         expect(groups == QStringList{QStringLiteral("Actions"), QStringLiteral("Projects"), QStringLiteral("Settings"), QStringLiteral("Threads")},
                describe(world));
       });
  step(QStringLiteral("the %1 group is hidden").arg(q), [](World& world, const Captures& c, const Table&) {
    const QList<Listed> listed = rows(world);
    expect(std::none_of(listed.cbegin(), listed.cend(), [&](const Listed& row) { return row.group == c[0]; }), describe(world));
  });
  step(QStringLiteral("the palette shows the %1 submenu").arg(q), [](World& world, const Captures& c, const Table&) {
    if (!world.checking) {
      if (c[0] == QLatin1String("Change theme")) {
        // A theme of this device's own to choose.
        auto* settings = world.native().controller<SettingsController>();
        QJsonArray custom = settings->deviceSettings().value(QLatin1String("customThemes")).toArray();
        custom.append(QJsonObject{{QStringLiteral("id"), QStringLiteral("Nord")},
                                  {QStringLiteral("label"), QStringLiteral("Nord")},
                                  {QStringLiteral("appearance"), QStringLiteral("dark")},
                                  {QStringLiteral("colors"), QJsonObject{{QStringLiteral("canvas"), QStringLiteral("#2e3440")},
                                                                         {QStringLiteral("accent"), QStringLiteral("#88c0d0")}}},
                                  {QStringLiteral("variants"),
                                   QJsonObject{{QStringLiteral("light"), QJsonObject{{QStringLiteral("canvas"), QStringLiteral("#eceff4")},
                                                                                    {QStringLiteral("accent"), QStringLiteral("#5e81ac")}}}}}});
        expect(settings->writeDevice(QStringLiteral("customThemes"), custom.toVariantList()), settings->deviceError());
      }
      open(world);
      const int row = indexOf(world, c[0], QStringLiteral("action"));
      expect(row >= 0 && palette(world).run(row), describe(world));
      world.sync();
    }
    expect(palette(world).isOpen() && palette(world).submenu() == c[0],
           QStringLiteral("the submenu is \"%1\"; %2").arg(palette(world).submenu(), describe(world)));
  });
  step(QStringLiteral("the palette shows the root list again"), [](World& world, const Captures&, const Table&) {
    const QList<Listed> listed = rows(world);
    expect(palette(world).isOpen() && palette(world).submenu().isEmpty() &&
               std::any_of(listed.cbegin(), listed.cend(), [](const Listed& row) { return row.group == u"Actions"; }),
           describe(world));
  });

  // Searching thread messages.
  step(QStringLiteral("the user searches for text that only appears inside messages"), [](World& world, const Captures&, const Table&) {
    world.node.hold(QStringLiteral("messages"));
    addThread(world, QStringLiteral("Tidy"), {{QStringLiteral("id"), QStringLiteral("thread-talk")}});
    world.node.part<FakeMessages>().text.insert(QStringLiteral("thread-talk"), QStringLiteral("The flamingo stands on one leg"));
    search(world, QStringLiteral("flamingo"));
  });
  step(QStringLiteral("the palette says %1 until the results arrive").arg(q), [](World& world, const Captures& c, const Table&) {
    CommandPaletteController& model = palette(world);
    world.waitFor([&world] { return world.node.part<FakeMessages>().asked > 0; }, QStringLiteral("the palette to search messages"));
    world.sync();
    expect(model.count() == 0 && model.emptyText() == c[0], QStringLiteral("the palette says \"%1\" with %2 rows").arg(model.emptyText()).arg(model.count()));
    world.node.answerHeld();
    const QList<Listed> listed = rows(world);
    expect(std::any_of(listed.cbegin(), listed.cend(), [&](const Listed& row) { return row.id == state(world).that; }), describe(world));
  });

  // A command that fails.
  step(QStringLiteral("an action that will fail"), [](World& world, const Captures&, const Table&) {
    PaletteState& fake = state(world);
    fake.engine = std::make_unique<QJSEngine>();
    const QJSValue fails = fake.engine->evaluate(QStringLiteral("(function () { throw new Error(\"The disk is full.\"); })"));
    world.native().controller<KeybindingController>()->commands()->add(QStringLiteral("test.explode"), QStringLiteral("Explode"), fails,
                                                                          fake.engine.get());
  });
  step(QStringLiteral("the user runs it from the palette"), [](World& world, const Captures&, const Table&) {
    search(world, QStringLiteral("Explode"));
    const int row = indexOf(world, QStringLiteral("Explode"));
    expect(row >= 0 && palette(world).run(row), describe(world));
    world.sync();
  });

  // What the palette's actions do.
  step(QStringLiteral("the user runs %1 from the palette").arg(q), [](World& world, const Captures& c, const Table&) {
    open(world);
    int row = indexOf(world, c[0]);
    if (row < 0) {
      palette(world).setQuery(c[0]);
      row = indexOf(world, c[0]);
    }
    expect(row >= 0 && palette(world).run(row), describe(world));
    world.sync();
  });
  step(QStringLiteral("the palette lists projects with the current project first"), [](World& world, const Captures&, const Table&) {
    QStringList titles;
    for (const Listed& row : rows(world)) titles << row.title;
    expect(palette(world).submenu() == u"New thread in..." && titles.value(0) == kProject &&
               titles.contains(QStringLiteral("theme-lab")) && titles.contains(QStringLiteral("docs-site")),
           describe(world));
  });
  step(QStringLiteral("the thread id is on the clipboard"), [](World& world, const Captures&, const Table&) {
    const QString key = world.native().controller<NavigationController>()->threadKey();
    expect(!key.isEmpty() && world.clipboard == key.mid(key.indexOf(QLatin1Char(':')) + 1),
           QStringLiteral("the clipboard holds \"%1\" for %2").arg(world.clipboard, key));
  });
  step(QStringLiteral("the user is asked which pull request to link to the thread"), [](World& world, const Captures&, const Table&) {
    auto* panel = world.native().controller<RightPanelController>();
    world.sync();
    expect(panel->pullRequests()->linkOpen() && panel->isOpen() && panel->activeTab() == u"pull-requests",
           show(world.state(QStringLiteral("panel"))));
  });
  step(QStringLiteral("the (?:command )?palette asks where the project comes from"), [](World& world, const Captures&, const Table&) {
    expect(palette(world).isOpen() && palette(world).submenu() == u"Add project" && indexOf(world, QStringLiteral("Local folder")) >= 0,
           QStringLiteral("the submenu is \"%1\"; %2").arg(palette(world).submenu(), describe(world)));
  });
  // The brick marks a current row "Current" (tst_CommandPalette.qml).
  step(QStringLiteral("the palette lists themes with the current one marked \"Current\""), [](World& world, const Captures&, const Table&) {
    world.sync();
    CommandPaletteController& model = palette(world);
    QStringList current;
    for (int row = 0; row < model.rowCount(); ++row) {
      if (model.index(row).data(CommandPaletteController::CurrentRole).toBool()) current << model.index(row).data(CommandPaletteController::TitleRole).toString();
    }
    // The standard look is the one drawn.
    expect(model.submenu() == u"Change theme" && current == QStringList{QStringLiteral("HAL-C2")},
           QStringLiteral("current: %1; %2").arg(current.join(u", "), describe(world)));
  });
  step(QStringLiteral("the palette offers System, Light and Dark"), [](World& world, const Captures&, const Table&) {
    QStringList titles;
    for (const Listed& row : rows(world)) titles << row.title;
    expect(palette(world).submenu() == u"Change appearance" &&
               titles == QStringList{QStringLiteral("System"), QStringLiteral("Light"), QStringLiteral("Dark")},
           describe(world));
  });
  step(QStringLiteral("the theme editor opens"), [](World& world, const Captures&, const Table&) {
    expect(world.native().controller<ThemeController>()->editorOpen(), QStringLiteral("the theme editor is closed"));
  });
  step(QStringLiteral("the pull request list opens"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(at(world.state(QStringLiteral("route")), QStringLiteral("kind")).toString() == u"pullRequests", show(world.state(QStringLiteral("route"))));
  });
  step(QStringLiteral("the current project's settings open"), [](World& world, const Captures&, const Table&) {
    world.sync();
    const QVariant route = world.state(QStringLiteral("route"));
    expect(at(route, QStringLiteral("kind")).toString() == u"settings" && at(route, QStringLiteral("projectKey")).toString().endsWith(kProject),
           show(route));
  });
  step(QStringLiteral("the app appearance is (dark|light|system)"), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(world.native().controller<ThemeController>()->mode() == c[0],
           QStringLiteral("the appearance is %1").arg(world.native().controller<ThemeController>()->mode()));
  });

  // Pull requests.
  step(QStringLiteral("the thread has a linked pull request"), [](World& world, const Captures&, const Table&) {
    const QString key = world.native().controller<NavigationController>()->threadKey();
    const QString id = key.mid(key.indexOf(QLatin1Char(':')) + 1);
    QJsonObject row = world.node.threads.value(id);
    row.insert(QStringLiteral("linkedPullRequest"), QJsonObject{{QStringLiteral("url"), QStringLiteral("https://github.com/acme/shop/pull/7")}});
    world.node.threads.insert(id, row);
    world.node.sendRow(id, row);
    world.sync();
  });
  step(QStringLiteral("the pull request URL is on the clipboard"), [](World& world, const Captures&, const Table&) {
    expect(world.clipboard == u"https://github.com/acme/shop/pull/7", QStringLiteral("the clipboard holds \"%1\"").arg(world.clipboard));
  });
  step(QStringLiteral("the thread has no linked pull request"), [](World& world, const Captures&, const Table&) {
    const QString key = world.native().controller<NavigationController>()->threadKey();
    expect(world.node.threads.value(key.mid(key.indexOf(QLatin1Char(':')) + 1)).value(QLatin1String("pullRequests")).toArray().isEmpty(),
           QStringLiteral("%1 has pull requests").arg(key));
  });
  step(QStringLiteral("%1 cannot be run").arg(q), [](World& world, const Captures& c, const Table&) {
    const int row = indexOf(world, c[0]);
    expect(row >= 0 && !palette(world).index(row).data(CommandPaletteController::EnabledRole).toBool(), describe(world));
  });
  step(QStringLiteral("the environment has no source control provider for pull requests"), [](World& world, const Captures&, const Table&) {
    setCapabilities(world, {{QStringLiteral("pullRequests"), false}});
  });
  step(QStringLiteral("the thread's environment cannot link pull requests to threads"), [](World& world, const Captures&, const Table&) {
    setCapabilities(world, {{QStringLiteral("threadPullRequests"), false}, {QStringLiteral("threadPullRequestLinking"), false}});
  });
  step(QStringLiteral("one connected environment supports pull requests and another does not"), [](World& world, const Captures&, const Table&) {
    world.node.join(stream::kPeer, stream::kPeerEnvironment);
    setCapabilities(world, {{QStringLiteral("pullRequests"), false}});
  });
  step(QStringLiteral("the user gives pull request (\\d+)"), [](World& world, const Captures& c, const Table&) {
    // The project's repository is on the host, so its pull requests can be read.
    QJsonObject project = world.node.projects.value(kProject);
    project.insert(QStringLiteral("repositoryIdentity"), QJsonObject{{QStringLiteral("canonicalKey"), QStringLiteral("github.com/acme/shop")}});
    world.node.projects.insert(kProject, project);
    world.node.sendRow(kProject, project, QStringLiteral("project"));
    world.sync();
    ThreadPullRequests* prs = world.native().controller<RightPanelController>()->pullRequests();
    expect(prs->linkOpen(), QStringLiteral("the link field is closed"));
    prs->link(QStringLiteral("https://github.com/acme/shop/pull/") + c[0]);
    world.sync();
  });
  step(QStringLiteral("pull request (\\d+) is linked to the thread"), [](World& world, const Captures& c, const Table&) {
    ThreadPullRequests* prs = world.native().controller<RightPanelController>()->pullRequests();
    world.waitFor([&] {
      for (int row = 0; row < prs->rowCount(); ++row) {
        if (prs->value(row, ThreadPullRequests::NumberRole).toInt() == c[0].toInt()) return true;
      }
      return false;
    }, [&] { return QStringLiteral("pull request %1 among %2 linked (%3)").arg(c[0]).arg(prs->rowCount()).arg(prs->problem()); });
  });

  // Add project.
  step(QStringLiteral("the user chooses a local folder %1").arg(q), [](World& world, const Captures& c, const Table&) {
    FakeFiles& files = fakeFiles(world.node);
    files.folders << files.home + QStringLiteral("/code") << files.home + QStringLiteral("/code/shop");
    const int row = indexOf(world, QStringLiteral("Local folder"));
    expect(row >= 0 && palette(world).run(row), describe(world));
    // Typed, then mod+Enter: the folder the path names.
    palette(world).setQuery(c[0]);
    rows(world);
    expect(palette(world).addBrowsedFolder(), describe(world));
    world.sync();
  });
  step(QStringLiteral("%1 is added as a project").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      for (const QJsonObject& project : std::as_const(world.node.projects)) {
        if (project.value(QLatin1String("title")) == c[0] && project.value(QLatin1String("workspaceRoot")) == fakeFiles(world.node).home + u"/code/" + c[0]) return true;
      }
      return false;
    }, QStringLiteral("the project %1").arg(c[0]));
  });
  step(QStringLiteral("the user can start a thread in it"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return at(world.state(QStringLiteral("route")), QStringLiteral("kind")) == QLatin1String("draft"); },
                  [&] { return show(world.state(QStringLiteral("route"))); });
    const auto draft = world.native().controller<DraftController>()->draft(at(world.state(QStringLiteral("route")), QStringLiteral("draftId")).toString());
    expect(draft && world.node.projects.value(draft->projectId).value(QLatin1String("title")) == QLatin1String("shop"), show(world.state(QStringLiteral("route"))));
  });
});

}  // namespace
