// The legacy sidebar (legacySidebarEnabled): one tree of threads per project,
// folded, trimmed to a few threads, sorted, dragged into place, and each
// project's menu (threads/sidebar-list.feature). The tree is `sidebar.tree`
// and Sidebar.qml's rows; a project's menu is the shell's `menu`.

#include <QJSValue>
#include <QJsonArray>
#include <QJsonObject>
#include <QSet>
#include <QTest>

#include <algorithm>
#include <functional>

#include "Brick.h"
#include "FakeProjects.h"
#include "Harness.h"
#include "McClient.h"
#include "SettingsController.h"
#include "SettingsRows.h"
#include "World.h"

namespace {

SettingsController* settings(World& world) {
  return world.native().controller<SettingsController>();
}

void writeDevice(World& world, const QString& key, const QVariant& value) {
  expect(settings(world)->writeDevice(key, value), QStringLiteral("%1 was not written").arg(key));
  world.sync();
}

QVariantList tree(World& world) {
  return at(world.state(QStringLiteral("sidebar")), QStringLiteral("tree")).toList();
}

QString mode(World& world) {
  return at(world.state(QStringLiteral("sidebar")), QStringLiteral("mode")).toString();
}

QString memberKey(World& world, const QString& projectId) {
  return world.mc.environmentId + QLatin1Char(':') + projectId;
}

// The tree's project the MC's project `projectId` is a folder of.
QVariantMap treeProject(World& world, const QString& projectId) {
  const QString member = memberKey(world, projectId);
  for (const QVariant& project : tree(world)) {
    if (at(project, QStringLiteral("memberKeys")).toStringList().contains(member)) return project.toMap();
  }
  fail(QStringLiteral("the tree lists no %1: %2").arg(projectId, show(tree(world))));
}

QStringList titles(const QVariantMap& project) {
  QStringList titles;
  for (const QVariant& row : project.value(QStringLiteral("threads")).toList()) titles.append(at(row, QStringLiteral("title")).toString());
  return titles;
}

QStringList treeNames(World& world) {
  QStringList names;
  for (const QVariant& project : tree(world)) names.append(at(project, QStringLiteral("displayName")).toString());
  return names;
}

void addThread(World& world, const QString& id, const QString& project, const QString& title, const QString& createdAt,
               const QString& lastWritten) {
  const QJsonObject row{
      {QStringLiteral("id"), id},
      {QStringLiteral("projectId"), project},
      {QStringLiteral("title"), title},
      {QStringLiteral("createdAt"), createdAt},
      {QStringLiteral("updatedAt"), lastWritten},
      {QStringLiteral("latestUserMessageAt"), lastWritten},
  };
  world.mc.threads.insert(id, row);
  world.mc.sendRow(id, row);
}

void addProject(World& world, const QString& id, const QString& root, const QJsonObject& identity = {}) {
  QJsonObject row{
      {QStringLiteral("id"), id},
      {QStringLiteral("title"), id},
      {QStringLiteral("workspaceRoot"), root},
      {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")},
      {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")},
      {QStringLiteral("scripts"), QJsonArray()},
  };
  if (!identity.isEmpty()) row.insert(QStringLiteral("repositoryIdentity"), identity);
  world.mc.projects.insert(id, row);
  world.mc.sendRow(id, row, QStringLiteral("project"));
}

// The thread list as the window draws it, its rows as Sidebar.qml builds them.
Brick& threadList(World& world) {
  if (!world.brick) {
    world.brick = std::make_unique<Brick>(world, QByteArrayLiteral("import QtQuick\nimport HalC2.Bricks\nSidebar { height: 900 }\n"), QSize(256, 900));
  }
  return *world.brick;
}

QVariantList listRows(Brick& brick) {
  QVariant rows = brick.root()->property("rows");
  if (rows.canConvert<QJSValue>()) rows = rows.value<QJSValue>().toVariant();
  return rows.toList();
}

// The titles of the thread rows the list draws under the project `projectId`.
QStringList drawnTitles(World& world, const QString& projectId) {
  world.sync();
  Brick& brick = threadList(world);
  const QString key = at(treeProject(world, projectId), QStringLiteral("key")).toString();
  QStringList titles;
  bool under = false;
  for (const QVariant& row : listRows(brick)) {
    const QString kind = at(row, QStringLiteral("kind")).toString();
    if (kind == QLatin1String("project")) under = at(row, QStringLiteral("item.key")).toString() == key;
    if (under && kind == QLatin1String("thread")) titles.append(at(row, QStringLiteral("item.title")).toString());
  }
  return titles;
}

void click(World& world, const QString& objectName) {
  world.sync();
  Brick& brick = threadList(world);
  brick.grab();
  QQuickItem* item = brick.item(objectName);
  QTest::mouseClick(&brick.window(), Qt::LeftButton, Qt::NoModifier, brick.at(item));
  world.sync();
}

// Picks the menu entry along `path`, each step an entry's label (a grouped
// project's folder entries are named by their folder, so a step may be the
// start of one).
void choose(World& world, const QStringList& path) {
  world.sync();
  const QVariant menu = world.state(QStringLiteral("menu"));
  expect(menu.typeId() == QMetaType::QVariantMap, QStringLiteral("no menu is open"));
  QVariantList items = at(menu, QStringLiteral("items")).toList();
  QString id;
  for (const QString& label : path) {
    const auto found = std::find_if(items.cbegin(), items.cend(), [&label](const QVariant& item) {
      return at(item, QStringLiteral("label")).toString() == label || at(item, QStringLiteral("label")).toString().startsWith(label + QLatin1Char(' '));
    });
    // A project of one folder has no folder entries to pass through.
    if (found == items.cend() && label.startsWith(QLatin1Char('/'))) continue;
    expect(found != items.cend(), QStringLiteral("the menu has no %1: %2").arg(label, show(items)));
    id = at(*found, QStringLiteral("id")).toString();
    items = at(*found, QStringLiteral("children")).toList();
  }
  expect(items.isEmpty(), QStringLiteral("%1 opens a further menu").arg(path.join(u" → ")));
  world.bridge().dispatch(QStringLiteral("menu.select"),
                          QVariantMap{{QStringLiteral("requestId"), at(menu, QStringLiteral("requestId"))}, {QStringLiteral("id"), id}});
  world.sync();
}

void openProjectMenu(World& world, const QString& projectId) {
  world.sync();
  world.bridge().dispatch(QStringLiteral("sidebar.project.menu"),
                          QVariantMap{{QStringLiteral("projectKey"), at(treeProject(world, projectId), QStringLiteral("key"))},
                                      {QStringLiteral("x"), 10}, {QStringLiteral("y"), 10}});
}

QString folderOf(World& world, const QString& projectId) {
  return world.mc.projects.value(projectId).value(QLatin1String("workspaceRoot")).toString();
}

QString sortValue(const QString& label) {
  if (label == QLatin1String("Last user message")) return QStringLiteral("updated_at");
  if (label == QLatin1String("Created at")) return QStringLiteral("created_at");
  if (label == QLatin1String("Manual")) return QStringLiteral("manual");
  fail(QStringLiteral("no sort order is called %1").arg(label));
}

void sortBy(World& world, const QString& what, const QString& label) {
  world.bridge().dispatch(QStringLiteral("sidebar.options"), QVariantMap{{QStringLiteral("x"), 10}, {QStringLiteral("y"), 10}});
  choose(world, {what == QLatin1String("projects") ? QStringLiteral("Sort projects") : QStringLiteral("Sort threads"), label});
  const QString key = what == QLatin1String("projects") ? QStringLiteral("sidebarProjectSortOrder") : QStringLiteral("sidebarThreadSortOrder");
  world.waitFor([&] { return settings(world)->deviceSettings().value(key).toString() == sortValue(label); },
                [&] { return QStringLiteral("%1 to be %2").arg(key, sortValue(label)); });
}

QVariantList toastItems(World& world) {
  return at(world.state(QStringLiteral("toasts")), QStringLiteral("items")).toList();
}

// The rows of Settings → General's "Legacy features", which starts folded:
// opened when `key`'s row is not shown yet.
void showLegacyRow(World& world, const QString& key) {
  if (rowShown(world, key)) return;
  Brick& page = generalPage(world);
  QQuickItem* fold = pageItem(world, QStringLiteral("settingsSection:Legacy features"), QStringLiteral("fold"));
  QTest::mouseClick(&page.window(), Qt::LeftButton, Qt::NoModifier, page.at(fold));
  world.waitFor([&] { return rowShown(world, key); }, [&] { return QStringLiteral("Settings to show %1").arg(key); });
}

QStringList arrangedOrder(World& world, const QStringList& names) {
  QStringList keys;
  for (const QString& name : names) keys.append(world.mc.environmentId + QStringLiteral(":/work/") + name);
  return keys;
}

const Steps steps([] {
  Brick::registerSingletons();
  const QString q = kQuoted;

  // The switch.
  step(QStringLiteral("the user has not turned on the legacy sidebar"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(!settings(world)->deviceSettings().value(QLatin1String("legacySidebarEnabled")).toBool(), QStringLiteral("the legacy sidebar is on"));
    expect(mode(world) == QLatin1String("attention"), QStringLiteral("the thread list is a %1").arg(mode(world)));
  });
  step(QStringLiteral("the user has turned on the legacy sidebar"), [](World& world, const Captures&, const Table&) {
    writeDevice(world, QStringLiteral("legacySidebarEnabled"), true);
    expect(mode(world) == QLatin1String("tree"), QStringLiteral("the thread list is a %1").arg(mode(world)));
  });
  // Settings → General's legacy Sidebar row, which the web labelled "Sidebar (legacy)".
  step(QStringLiteral("the user turns (on|off) \"Sidebar \\(legacy\\)\" in settings"), [](World& world, const Captures& c, const Table&) {
    showLegacyRow(world, QStringLiteral("legacySidebarEnabled"));
    turnRow(world, QStringLiteral("legacySidebarEnabled"), c[0] == QLatin1String("on"));
  });
  step(QStringLiteral("the thread list shows each project with its own threads beneath it"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return mode(world) == QLatin1String("tree"); }, [&] { return QStringLiteral("the tree; the list is a %1").arg(mode(world)); });
    const QVariantMap sections = world.state(QStringLiteral("sidebar")).toMap();
    for (const QString& section : {QStringLiteral("pinned"), QStringLiteral("active"), QStringLiteral("settled")}) {
      expect(sections.value(section).toList().isEmpty(), QStringLiteral("the %1 section is still listed").arg(section));
    }
    for (const QString& project : {QStringLiteral("shop"), QStringLiteral("docs")}) {
      const QVariantList rows = treeProject(world, project).value(QStringLiteral("threads")).toList();
      expect(rows.size() == 2, QStringLiteral("%1 lists %2").arg(project, show(rows)));
      // The threads "%1 has 2 threads" made for it.
      for (const QVariant& row : rows) {
        expect(at(row, QStringLiteral("key")).toString().section(QLatin1Char(':'), 1).startsWith(project + QLatin1Char('-')),
               QStringLiteral("%1 lists %2").arg(project, show(row)));
      }
    }
  });
  step(QStringLiteral("the thread list is grouped by attention again"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return mode(world) == QLatin1String("attention"); }, [&] { return QStringLiteral("the sections; the list is a %1").arg(mode(world)); });
    expect(tree(world).isEmpty(), QStringLiteral("the tree is still listed"));
    const QVariantList active = at(world.state(QStringLiteral("sidebar")), QStringLiteral("active")).toList();
    expect(active.size() == 4, QStringLiteral("Active lists %1").arg(show(active)));
  });

  // Folding, on the project's header.
  step(QStringLiteral("the user (?:folds|unfolds) %1(?: in the thread list)?").arg(q), [](World& world, const Captures& c, const Table&) {
    click(world, QStringLiteral("projectHeader:") + at(treeProject(world, c[0]), QStringLiteral("key")).toString());
  });
  step(QStringLiteral("the threads of %1 are hidden").arg(q), [](World& world, const Captures& c, const Table&) {
    const QStringList drawn = drawnTitles(world, c[0]);
    expect(drawn.isEmpty() && !treeProject(world, c[0]).value(QStringLiteral("expanded")).toBool(), QStringLiteral("%1 shows %2").arg(c[0], drawn.join(u", ")));
  });
  step(QStringLiteral("the threads of %1 are shown again").arg(q), [](World& world, const Captures& c, const Table&) {
    const QStringList drawn = drawnTitles(world, c[0]);
    expect(drawn.size() == 2, QStringLiteral("%1 shows %2").arg(c[0], drawn.join(u", ")));
  });

  // A few threads, and the rest on asking.
  step(QStringLiteral("%1 has (\\d+) threads and the list shows (\\d+) threads per project").arg(q), [](World& world, const Captures& c, const Table&) {
    // Thread n was written in last at minute n, so the highest are the most recent.
    for (int n = 1; n <= c[1].toInt(); ++n) {
      const QString at = QStringLiteral("2026-09-23T09:%1:00Z").arg(n, 2, 10, QLatin1Char('0'));
      addThread(world, QStringLiteral("%1-%2").arg(c[0]).arg(n), c[0], QStringLiteral("Thread %1").arg(n), QStringLiteral("2026-09-23T08:00:00Z"), at);
    }
    writeDevice(world, QStringLiteral("sidebarThreadPreviewCount"), c[2].toInt());
  });
  step(QStringLiteral("the user looks at %1 in the thread list").arg(q), [](World& world, const Captures& c, const Table&) {
    drawnTitles(world, c[0]);
  });
  step(QStringLiteral("the (\\d+) most recent threads of %1 are shown").arg(q), [](World& world, const Captures& c, const Table&) {
    const int count = c[0].toInt();
    const QStringList drawn = drawnTitles(world, c[1]);
    QStringList expected;
    const int all = int(world.mc.threads.size());
    for (int n = all; n > all - count; --n) expected.append(QStringLiteral("Thread %1").arg(n));
    expect(drawn == expected, QStringLiteral("%1 shows %2").arg(c[1], drawn.join(u", ")));
  });
  step(QStringLiteral("(?:all|only) (\\d+) threads of %1 are shown").arg(q), [](World& world, const Captures& c, const Table&) {
    const QStringList drawn = drawnTitles(world, c[1]);
    expect(drawn.size() == c[0].toInt(), QStringLiteral("%1 shows %2").arg(c[1], drawn.join(u", ")));
  });
  step(QStringLiteral("%1 offers to show (more|less)").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    Brick& brick = threadList(world);
    brick.grab();
    const QString key = at(treeProject(world, c[0]), QStringLiteral("key")).toString();
    QQuickItem* more = brick.item(QStringLiteral("projectMore:") + key);
    expect(more->isVisible() && brick.shows(c[1] == QLatin1String("more") ? QStringLiteral("Show more") : QStringLiteral("Show less")),
           QStringLiteral("%1 offers %2").arg(c[0], show(treeProject(world, c[0]).value(QStringLiteral("more")))));
  });
  step(QStringLiteral("the user asks to show (?:more|less)"), [](World& world, const Captures&, const Table&) {
    QString key;
    for (const QVariant& project : tree(world)) {
      if (!at(project, QStringLiteral("more")).isNull()) key = at(project, QStringLiteral("key")).toString();
    }
    expect(!key.isEmpty(), QStringLiteral("no project offers more or less"));
    click(world, QStringLiteral("projectMore:") + key);
  });

  // How many, typed into Settings → General.
  step(QStringLiteral("the user sets the visible thread count to (\\d+)"), [](World& world, const Captures& c, const Table&) {
    showLegacyRow(world, QStringLiteral("sidebarThreadPreviewCount"));
    QQuickItem* count = pageItem(world, QStringLiteral("settingsRow:sidebarThreadPreviewCount"), QStringLiteral("control"));
    count->setProperty("value", c[0].toInt());
    QMetaObject::invokeMethod(count, "valueModified");
    world.sync();
  });
  step(QStringLiteral("each project shows (\\d+) threads before offering more"), [](World& world, const Captures& c, const Table&) {
    world.sync();
    const QVariantMap shop = treeProject(world, QStringLiteral("shop"));
    expect(titles(shop).size() == c[0].toInt() && shop.value(QStringLiteral("more")) == QLatin1String("more"),
           QStringLiteral("shop shows %1, offering %2").arg(titles(shop).join(u", "), show(shop.value(QStringLiteral("more")))));
  });

  // Sorting, from the list's sort menu.
  step(QStringLiteral("%1, %1 and %1 have threads started and written at different times").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString blog = c[2];
    addProject(world, blog, QStringLiteral("/work/") + blog);
    const auto at = [](const char* time) { return QStringLiteral("2026-09-23T") + QLatin1String(time) + QStringLiteral(":00Z"); };
    // Written in last: shop, docs, blog. Started last: docs, shop, blog.
    addThread(world, QStringLiteral("cart"), c[0], QStringLiteral("Cart"), at("09:00"), at("09:50"));
    addThread(world, QStringLiteral("checkout"), c[0], QStringLiteral("Checkout"), at("09:30"), at("09:10"));
    addThread(world, QStringLiteral("guide"), c[1], QStringLiteral("Guide"), at("09:40"), at("09:20"));
    addThread(world, QStringLiteral("faq"), c[1], QStringLiteral("FAQ"), at("09:05"), at("09:45"));
    addThread(world, QStringLiteral("post"), blog, QStringLiteral("Post"), at("09:20"), at("09:30"));
    world.sync();
  });
  step(QStringLiteral("the user once arranged the projects %1, %1 and %1 by hand").arg(q), [](World& world, const Captures& c, const Table&) {
    writeDevice(world, QStringLiteral("sidebarProjectOrder"), arrangedOrder(world, c));
  });
  step(QStringLiteral("the user sorts (projects|threads) by %1").arg(q), [](World& world, const Captures& c, const Table&) {
    sortBy(world, c[0], c[1]);
  });
  step(QStringLiteral("projects are sorted %1").arg(q), [](World& world, const Captures& c, const Table&) {
    writeDevice(world, QStringLiteral("sidebarProjectSortOrder"), sortValue(c[0]));
  });
  const QHash<QString, QStringList> projectOrders{
      {QStringLiteral("by the latest message the user sent in each"), {QStringLiteral("shop"), QStringLiteral("docs"), QStringLiteral("blog")}},
      {QStringLiteral("by when each project's threads were started"), {QStringLiteral("docs"), QStringLiteral("shop"), QStringLiteral("blog")}},
      {QStringLiteral("in the order the user arranged them"), {QStringLiteral("blog"), QStringLiteral("shop"), QStringLiteral("docs")}},
  };
  for (auto it = projectOrders.cbegin(); it != projectOrders.cend(); ++it) {
    step(QStringLiteral("projects are listed ") + it.key(), [expected = it.value()](World& world, const Captures&, const Table&) {
      world.sync();
      expect(treeNames(world) == expected, QStringLiteral("the projects are %1").arg(treeNames(world).join(u", ")));
    });
  }
  const QHash<QString, QPair<QStringList, QStringList>> threadOrders{
      {QStringLiteral("by the latest message the user sent in each"), {{QStringLiteral("Cart"), QStringLiteral("Checkout")}, {QStringLiteral("FAQ"), QStringLiteral("Guide")}}},
      {QStringLiteral("by when each thread was started"), {{QStringLiteral("Checkout"), QStringLiteral("Cart")}, {QStringLiteral("Guide"), QStringLiteral("FAQ")}}},
  };
  for (auto it = threadOrders.cbegin(); it != threadOrders.cend(); ++it) {
    step(QStringLiteral("threads are listed ") + it.key(), [expected = it.value()](World& world, const Captures&, const Table&) {
      world.sync();
      const QStringList shop = titles(treeProject(world, QStringLiteral("shop")));
      const QStringList docs = titles(treeProject(world, QStringLiteral("docs")));
      expect(shop == expected.first && docs == expected.second,
             QStringLiteral("shop lists %1, docs %2").arg(shop.join(u", "), docs.join(u", ")));
    });
  }

  // Dragging a project's header onto another's.
  step(QStringLiteral("the user's order is remembered"), [](World& world, const Captures&, const Table&) {
    const QJsonValue order = settings(world)->deviceSettings().value(QLatin1String("sidebarProjectOrder"));
    const QStringList expected = arrangedOrder(world, treeNames(world));
    expect(order.toVariant().toStringList() == expected, QStringLiteral("the device keeps %1").arg(show(order.toVariant())));
  });
  step(QStringLiteral("dragging a project does not move it"), [](World& world, const Captures&, const Table&) {
    world.sync();
    const QStringList before = treeNames(world);
    const QJsonValue order = settings(world)->deviceSettings().value(QLatin1String("sidebarProjectOrder"));
    for (const QVariant& project : tree(world)) {
      expect(!at(project, QStringLiteral("draggable")).toBool(), QStringLiteral("%1 can be dragged").arg(at(project, QStringLiteral("displayName")).toString()));
    }
    world.bridge().dispatch(QStringLiteral("sidebar.project.drop"),
                            QVariantMap{{QStringLiteral("projectKey"), at(tree(world).last(), QStringLiteral("key"))},
                                        {QStringLiteral("targetKey"), at(tree(world).first(), QStringLiteral("key"))}});
    world.sync();
    expect(treeNames(world) == before && settings(world)->deviceSettings().value(QLatin1String("sidebarProjectOrder")) == order,
           QStringLiteral("the projects are %1").arg(treeNames(world).join(u", ")));
  });

  // Renaming, from the project's menu.
  step(QStringLiteral("the user renames %1 from its menu to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    openProjectMenu(world, c[0]);
    choose(world, {QStringLiteral("Rename")});
    const QVariant renaming = world.state(QStringLiteral("projectRename"));
    expect(at(renaming, QStringLiteral("title")) == c[0], QStringLiteral("the rename dialog is %1").arg(show(renaming)));
    world.bridge().dispatch(QStringLiteral("project.rename.submit"), QVariantMap{{QStringLiteral("title"), c[1]}});
    world.sync();
  });
  step(QStringLiteral("%1 is now called %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return treeNames(world).contains(c[1]) && world.state(QStringLiteral("projectRename")).isNull(); },
                  [&] { return QStringLiteral("the projects are %1").arg(treeNames(world).join(u", ")); });
    const QList<QJsonObject>& sent = world.mc.part<FakeProjects>().mutations;
    expect(sent.size() == 1 && sent.first().value(QLatin1String("projectId")) == c[0] && sent.first().value(QLatin1String("title")) == c[1],
           QStringLiteral("the MC was sent %1").arg(sent.size()));
  });
  step(QStringLiteral("nothing is sent and the dialog closes"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(world.mc.part<FakeProjects>().mutations.isEmpty(), QStringLiteral("a change was sent"));
    expect(world.state(QStringLiteral("projectRename")).isNull(), QStringLiteral("the rename dialog is still open"));
  });
  step(QStringLiteral("the environment refuses to rename %1").arg(q), [](World& world, const Captures&, const Table&) {
    world.mc.part<FakeProjects>().refusal = QStringLiteral("Project titles are locked.");
  });

  // Grouping, from the project's menu.
  step(QStringLiteral("%1 sits in the repository folder %1, as %1 does in another copy of it").arg(q), [](World& world, const Captures& c, const Table&) {
    const auto identity = [](const QString& root) {
      return QJsonObject{{QStringLiteral("canonicalKey"), QStringLiteral("github.com/acme/shop")}, {QStringLiteral("rootPath"), root}};
    };
    addProject(world, c[0], QStringLiteral("/work/acme/") + c[0], identity(QStringLiteral("/work/acme")));
    addProject(world, c[1], QStringLiteral("/work/acme"), identity(QStringLiteral("/work/acme")));
    addProject(world, c[2], QStringLiteral("/home/sam/acme/") + c[0], identity(QStringLiteral("/home/sam/acme")));
    world.sync();
  });
  step(QStringLiteral("the device groups projects by repository path"), [](World& world, const Captures&, const Table&) {
    writeDevice(world, QStringLiteral("sidebarProjectGroupingMode"), QStringLiteral("repository_path"));
  });
  step(QStringLiteral("the user groups %1 by %1 from its menu").arg(q), [](World& world, const Captures& c, const Table&) {
    openProjectMenu(world, c[0]);
    const QString choice = c[1] == QLatin1String("the device's default") ? QStringLiteral("Use global default") : c[1];
    choose(world, {QStringLiteral("Group into..."), folderOf(world, c[0]), choice});
  });
  const QHash<QString, QStringList> groupings{
      {QStringLiteral("with the other folders of its repository"), {QStringLiteral("shop"), QStringLiteral("acme")}},
      {QStringLiteral("with the folders of its repository path"), {QStringLiteral("shop"), QStringLiteral("shop-copy")}},
      {QStringLiteral("on its own"), {QStringLiteral("shop")}},
      // By repository path.
      {QStringLiteral("the way the device's default says"), {QStringLiteral("shop"), QStringLiteral("shop-copy")}},
  };
  for (auto it = groupings.cbegin(); it != groupings.cend(); ++it) {
    step(QStringLiteral("%1 is grouped ").arg(q) + it.key(), [expected = it.value()](World& world, const Captures& c, const Table&) {
      world.sync();
      QStringList members = at(treeProject(world, c[0]), QStringLiteral("memberKeys")).toStringList();
      QStringList wanted;
      for (const QString& project : expected) wanted.append(memberKey(world, project));
      members.sort();
      wanted.sort();
      expect(members == wanted, QStringLiteral("%1 is grouped with %2").arg(c[0], members.join(u", ")));
    });
  }

  // Removing, from the project's menu.
  step(QStringLiteral("the user removes %1 from its menu").arg(q), [](World& world, const Captures& c, const Table&) {
    openProjectMenu(world, c[0]);
    choose(world, {QStringLiteral("Remove")});
  });
  step(QStringLiteral("the user is offered %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    for (const QVariant& toast : toastItems(world)) {
      for (const QVariant& action : at(toast, QStringLiteral("actions")).toList()) {
        if (at(action, QStringLiteral("label")) == c[0]) return;
      }
    }
    fail(QStringLiteral("the toasts are %1").arg(show(toastItems(world))));
  });
  step(QStringLiteral("the user chooses %1 and confirms").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    for (const QVariant& toast : toastItems(world)) {
      for (const QVariant& action : at(toast, QStringLiteral("actions")).toList()) {
        if (at(action, QStringLiteral("label")) != c[0]) continue;
        world.bridge().dispatch(QStringLiteral("notification.action"),
                                QVariantMap{{QStringLiteral("id"), at(toast, QStringLiteral("id"))}, {QStringLiteral("actionId"), at(action, QStringLiteral("id"))}});
        world.sync();
        const QVariant removal = world.state(QStringLiteral("projectRemoval"));
        expect(removal.typeId() == QMetaType::QVariantMap, QStringLiteral("no removal is asked about"));
        world.bridge().dispatch(QStringLiteral("project.remove.confirm"), QVariantMap());
        world.sync();
        return;
      }
    }
    fail(QStringLiteral("the toasts are %1").arg(show(toastItems(world))));
  });
  step(QStringLiteral("%1 and its (\\d+) threads are removed").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return !treeNames(world).contains(c[0]); }, [&] { return QStringLiteral("the projects are %1").arg(treeNames(world).join(u", ")); });
    int left = 0;
    for (const QJsonObject& thread : std::as_const(world.mc.threads)) left += thread.value(QLatin1String("projectId")) == c[0];
    expect(!world.mc.projects.contains(c[0]) && left == 0, QStringLiteral("%1 threads of %2 are left").arg(left).arg(c[0]));
    const QList<QJsonObject>& sent = world.mc.part<FakeProjects>().mutations;
    expect(!sent.isEmpty() && sent.last().value(QLatin1String("force")).toBool(), QStringLiteral("the removal was not forced"));
  });
});

}  // namespace

// ThreadOrderSteps.cpp's "the user drags %1 above %1", when the two are the
// tree's projects: the first's header dropped on the second's.
bool dragProject(World& world, const QString& dragged, const QString& target) {
  world.sync();
  const QStringList before = treeNames(world);
  if (!before.contains(dragged) || !before.contains(target)) return false;
  expect(before.indexOf(dragged) > before.indexOf(target), QStringLiteral("%1 is already above %2").arg(dragged, target));
  world.bridge().dispatch(QStringLiteral("sidebar.project.drop"),
                          QVariantMap{{QStringLiteral("projectKey"), at(treeProject(world, dragged), QStringLiteral("key"))},
                                      {QStringLiteral("targetKey"), at(treeProject(world, target), QStringLiteral("key"))}});
  world.sync();
  return true;
}
