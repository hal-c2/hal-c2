// The scenarios desktop-qt runs against its shell test double
// (tests/tst_Scenarios.qml): the thread list, the header's terminal toggle
// and the notification cards (threads/qt-scenarios.feature,
// navigation/qt-scenarios.feature, timeline/notifications.feature). Here
// the bricks run over the real shell and the fake MC, so a step reads what
// the action did rather than which action the brick asked for.
// desktop-ljos's steps/qt_scenarios.rs, ported back.

#include <QJsonArray>
#include <QJsonObject>
#include <QPoint>
#include <QQuickItem>
#include <QTest>

#include <memory>

#include "Brick.h"
#include "Harness.h"
#include "NavigationController.h"
#include "QtScenarios.h"
#include "TerminalController.h"
#include "ThreadList.h"
#include "ToastController.h"
#include "World.h"

namespace {

const QString kProject = QStringLiteral("project");

struct QtScenario {
  // The centre of the row whose menu Shift+F10 asks for.
  QPoint rowCentre;
  // The list's rows that can be acted on, in order, and the one the
  // keyboard cursor was on, when a step put it there.
  QStringList rowKeys;
  QString focusedKey;
  bool terminalWasOpen = false;
  // The notification actions that ran, as "<title>/<label>".
  std::shared_ptr<QStringList> ran = std::make_shared<QStringList>();
  std::unique_ptr<Brick> notifications;
};

QtScenario& scenario(World& world) {
  return world.mc.part<QtScenario>();
}

// The thread list as the window draws it, taking the scenario's keys.
Brick& showSidebar(World& world) {
  world.sync();
  world.brick = std::make_unique<Brick>(world,
                                        "import QtQuick\nimport HalC2.Bricks\nSidebar { width: 272; height: 450; showFooter: false }\n",
                                        QSize(272, 450));
  world.brick->takesKeys = true;
  return *world.brick;
}

Brick& shown(World& world) {
  if (!world.brick) fail(QStringLiteral("no brick is shown"));
  return *world.brick;
}

QString titleId(const QString& title) {
  return QStringLiteral("t-") + title.toLower().replace(QLatin1Char(' '), QLatin1Char('-'));
}

void putThread(World& world, const QString& id, const QJsonObject& row) {
  world.mc.threads.insert(id, row);
  world.mc.sendRow(id, row);
  if (world.native().client()->isReady()) world.sync();
}

// The thread `title` in the project, made the first time a step names it;
// a later one is newer, so the list shows them in the order they are named
// from the bottom up.
QString threadTitled(World& world, const QString& title, QJsonObject fields) {
  for (auto it = world.mc.threads.cbegin(); it != world.mc.threads.cend(); ++it) {
    if (it.value().value(QLatin1String("title")) == title) return threadKeyOf(world, title);
  }
  const qsizetype minute = world.mc.threads.size();
  fields.insert(QStringLiteral("title"), title);
  // In the scenario's own project when the Background made one; otherwise
  // (threads/sidebar-list.feature) in the MC's first project.
  fields.insert(QStringLiteral("projectId"),
                world.mc.projects.contains(kProject) ? kProject : world.mc.projects.firstKey());
  if (!fields.contains(QLatin1String("createdAt"))) {
    fields.insert(QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:%1:00Z").arg(minute, 2, 10, QLatin1Char('0')));
  }
  fields.insert(QStringLiteral("id"), titleId(title));
  putThread(world, titleId(title), fields);
  world.sync();
  return threadKeyOf(world, title);
}

// The list's row for the thread `key`, once it is laid out.
QQuickItem* rowOfItem(World& world, Brick& brick, const QString& key) {
  const QString name = QStringLiteral("threadRow:") + key;
  world.waitFor([&] { return brick.find(name) != nullptr; }, QStringLiteral("the thread list to draw %1").arg(key));
  return brick.item(name);
}

// Puts the pointer over the thread's row, which shows its actions.
QQuickItem* hoverRow(World& world, Brick& brick, const QString& key) {
  QQuickItem* row = rowOfItem(world, brick, key);
  QTest::mouseMove(&brick.window(), brick.at(row, 0.4, 0.5) + QPoint(0, 4));
  QTest::mouseMove(&brick.window(), brick.at(row, 0.4, 0.5));
  world.waitFor([&] { return row->property("showActions").toBool(); },
                [&] {
                  const QPoint at = brick.at(row, 0.4, 0.5);
                  return QStringLiteral("%1 to show its actions; the row is %2x%3 at %4,%5, hasActions %6")
                      .arg(key)
                      .arg(row->width())
                      .arg(row->height())
                      .arg(at.x())
                      .arg(at.y())
                      .arg(row->property("hasActions").toBool());
                });
  return row;
}

// The shown item named `name` under `root` (a row lays its actions out
// twice, slim and card, and shows one).
QQuickItem* visibleIn(QQuickItem* root, const QString& name) {
  for (QQuickItem* item : root->findChildren<QQuickItem*>(name)) {
    if (item->isVisible()) return item;
  }
  return nullptr;
}

void clickItem(World& world, Brick& brick, QQuickItem* item) {
  QTest::mouseClick(&brick.window(), Qt::LeftButton, Qt::NoModifier, brick.at(item));
  world.sync();
}

// The list, focused as Tab or a click would focus it, with its keyboard
// cursor on a row.
QQuickItem* focusList(World& world, Brick& brick) {
  QQuickItem* list = brick.item(QStringLiteral("list"));
  list->forceActiveFocus();
  world.waitFor(
      [&] { return list->hasActiveFocus() && !list->property("cursorKey").toString().isEmpty(); },
      QStringLiteral("the thread list's keyboard cursor"));
  return list;
}

void waitForSection(World& world, const QString& title, const QString& section) {
  const QString key = threadKeyOf(world, title);
  world.waitFor([&] { return sidebarSectionOf(world, key) == section; },
                [&] { return QStringLiteral("%1 to be in \"%2\"; it is in \"%3\"").arg(title, section, sidebarSectionOf(world, key)); });
}

QVariantList toasts(World& world) {
  return world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList();
}

std::optional<QVariantMap> toastTitled(World& world, const QString& title) {
  for (const QVariant& item : toasts(world)) {
    if (item.toMap().value(QStringLiteral("title")) == title) return item.toMap();
  }
  return std::nullopt;
}

// Shows a toast that stays until it is dismissed, and the cards that draw
// it.
void notify(World& world, const QString& title, const std::optional<QString>& label) {
  const auto ran = scenario(world).ran;
  QList<ToastController::Action> actions;
  if (label) {
    const QString said = title + QLatin1Char('/') + *label;
    actions.append({*label, [ran, said] { ran->append(said); }});
  }
  auto* toastsController = world.native().controller<ToastController>();
  toastsController->showActions(label ? QStringLiteral("info") : QStringLiteral("success"), title, QString(), actions, 0);
  scenario(world).notifications =
      std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nNotifications {}\n", QSize(340, 200));
  Brick& brick = *scenario(world).notifications;
  const QString card = QStringLiteral("notification-") +
                       toastTitled(world, title).value_or(QVariantMap()).value(QStringLiteral("id")).toString();
  world.waitFor(
      [&] {
        QQuickItem* item = brick.find(card);
        return item && item->opacity() == 1.0;
      },
      [&] { return QStringLiteral("the card %1; the shell shows %2").arg(card, show(QVariant(toasts(world)))); });
}

Brick& notifications(World& world) {
  if (!scenario(world).notifications) fail(QStringLiteral("no notification is shown"));
  return *scenario(world).notifications;
}

TerminalController* terminals(World& world) {
  return world.native().controller<TerminalController>();
}

// The MC's project "p1" at /work/p1, connected, unless a Background set one
// up; then a thread of it on screen.
void ensureTerminalThread(World& world) {
  if (world.mc.projects.isEmpty()) {
    const QJsonObject row{{QStringLiteral("id"), QStringLiteral("p1")},
                          {QStringLiteral("title"), QStringLiteral("p1")},
                          {QStringLiteral("workspaceRoot"), QStringLiteral("/work/p1")},
                          {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                          {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                          {QStringLiteral("scripts"), QJsonArray()}};
    world.mc.projects.insert(QStringLiteral("p1"), row);
    world.mc.sendRow(QStringLiteral("p1"), row, QStringLiteral("project"));
  }
  if (world.shellSubscriptions() == 0) world.connect();
  world.sync();
  const QString shownThread = at(world.state(QStringLiteral("workspace")), QStringLiteral("threadKey")).toString();
  if (!shownThread.isEmpty() && at(world.state(QStringLiteral("route")), QStringLiteral("kind")) == QLatin1String("thread")) return;
  const QString project = world.mc.projects.firstKey();
  const QString threadId = QStringLiteral("thread-in-") + project;
  const QJsonObject row{{QStringLiteral("id"), threadId},
                        {QStringLiteral("title"), QStringLiteral("Cart")},
                        {QStringLiteral("projectId"), project},
                        {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                        {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}};
  world.mc.threads.insert(threadId, row);
  world.mc.sendRow(threadId, row);
  const QString key = world.mc.environmentId + QLatin1Char(':') + threadId;
  world.native().controller<NavigationController>()->open(NavigationController::Route::thread(key));
  world.waitFor([&] { return at(world.state(QStringLiteral("workspace")), QStringLiteral("threadKey")) == key; },
                [&] { return QStringLiteral("the header to show %1; it shows %2").arg(key, show(world.state(QStringLiteral("workspace")))); });
}

}  // namespace

bool notificationChooses(World& world, const QString& label) {
  if (!scenario(world).notifications) return false;
  Brick& brick = notifications(world);
  for (const QVariant& toast : toasts(world)) {
    const QVariantMap map = toast.toMap();
    for (const QVariant& action : map.value(QStringLiteral("actions")).toList()) {
      const QVariantMap entry = action.toMap();
      if (entry.value(QStringLiteral("label")) != label) continue;
      const QString name = QStringLiteral("notificationAction-%1-%2")
                               .arg(map.value(QStringLiteral("id")).toString(), entry.value(QStringLiteral("id")).toString());
      QQuickItem* button = brick.find(name);
      if (!button || !button->isVisible()) fail(QStringLiteral("the card shows no %1").arg(name));
      clickItem(world, brick, button);
      return true;
    }
  }
  return false;
}

namespace {

const Steps steps([] {
  const QString q = kQuoted;

  // The thread list.
  step(QStringLiteral("the project %1 is in the thread list").arg(q), [](World& world, const Captures& c, const Table&) {
    // The MC applies what the list asks of a thread.
    projectThreadCommands(world);
    const QJsonObject row{{QStringLiteral("id"), kProject},
                          {QStringLiteral("title"), c[0]},
                          {QStringLiteral("workspaceRoot"), QStringLiteral("/work/project")},
                          {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                          {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                          {QStringLiteral("scripts"), QJsonArray()}};
    world.mc.projects.insert(kProject, row);
    world.mc.sendRow(kProject, row, QStringLiteral("project"));
    if (world.shellSubscriptions() == 0) world.connect();
    world.sync();
  });
  step(QStringLiteral("the threads %1 and %1 with %1 open").arg(q), [](World& world, const Captures& c, const Table&) {
    // The first named is the newest, at the top.
    threadTitled(world, c[1], {});
    threadTitled(world, c[0], {});
    const QString key = threadKeyOf(world, c[2]);
    world.bridge().dispatch(QStringLiteral("thread.open"), QVariantMap{{QStringLiteral("key"), key}});
    world.sync();
  });
  step(QStringLiteral("the thread list has keyboard focus"), [](World& world, const Captures&, const Table&) {
    Brick& brick = showSidebar(world);
    focusList(world, brick);
  });
  step(QStringLiteral("the user moves down and presses Enter"), [](World& world, const Captures&, const Table&) {
    Brick& brick = shown(world);
    expect(brick.press(QStringLiteral("down")), QStringLiteral("the list did not take Down"));
    expect(brick.press(QStringLiteral("enter")), QStringLiteral("the list did not take Enter"));
    world.sync();
  });
  step(QStringLiteral("the thread list has keyboard focus on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    // Rows above and below, so the cursor has somewhere to go.
    threadTitled(world, QStringLiteral("Older neighbour"), {{QStringLiteral("createdAt"), QStringLiteral("2026-09-23T08:00:00Z")}});
    threadTitled(world, QStringLiteral("Newer neighbour"), {{QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:59:00Z")}});
    const QString key = threadTitled(world, c[0], {{QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:30:00Z")}});
    world.bridge().dispatch(QStringLiteral("thread.open"), QVariantMap{{QStringLiteral("key"), key}});
    world.sync();
    Brick& brick = showSidebar(world);
    QQuickItem* row = rowOfItem(world, brick, key);
    QQuickItem* list = focusList(world, brick);
    const QString cursor = list->property("cursorKey").toString();
    expect(cursor == key, QStringLiteral("the keyboard cursor is on %1").arg(cursor));
    scenario(world).rowCentre = brick.at(row);
    scenario(world).focusedKey = key;
    scenario(world).rowKeys.clear();
    for (const QVariant& entry : brick.root()->property("rows").toList()) {
      const QString rowKey = entry.toMap().value(QStringLiteral("rowKey")).toString();
      if (!rowKey.isEmpty()) scenario(world).rowKeys.append(rowKey);
    }
  });
  // Where the keyboard cursor went (threads/sidebar-list.feature).
  const auto focusedIs = [](World& world, const QString& expected, const QString& what) {
    Brick& brick = shown(world);
    QQuickItem* list = brick.item(QStringLiteral("list"));
    world.waitFor([&] { return list->property("cursorKey").toString() == expected; },
                  [&] { return QStringLiteral("%1; the cursor is on %2").arg(what, list->property("cursorKey").toString()); });
  };
  step(QStringLiteral("the next row is focused"), [focusedIs](World& world, const Captures&, const Table&) {
    const QStringList& keys = scenario(world).rowKeys;
    const qsizetype at = keys.indexOf(scenario(world).focusedKey);
    expect(at >= 0 && at + 1 < keys.size(), QStringLiteral("there is no row after %1 in [%2]").arg(scenario(world).focusedKey, keys.join(QStringLiteral(", "))));
    focusedIs(world, keys.at(at + 1), QStringLiteral("the next row to be focused"));
  });
  step(QStringLiteral("the previous row is focused"), [focusedIs](World& world, const Captures&, const Table&) {
    const QStringList& keys = scenario(world).rowKeys;
    const qsizetype at = keys.indexOf(scenario(world).focusedKey);
    expect(at > 0, QStringLiteral("there is no row before %1 in [%2]").arg(scenario(world).focusedKey, keys.join(QStringLiteral(", "))));
    focusedIs(world, keys.at(at - 1), QStringLiteral("the previous row to be focused"));
  });
  step(QStringLiteral("the first row is focused"), [focusedIs](World& world, const Captures&, const Table&) {
    expect(!scenario(world).rowKeys.isEmpty(), QStringLiteral("the list has no rows"));
    focusedIs(world, scenario(world).rowKeys.first(), QStringLiteral("the first row to be focused"));
  });
  step(QStringLiteral("the last row is focused"), [focusedIs](World& world, const Captures&, const Table&) {
    expect(!scenario(world).rowKeys.isEmpty(), QStringLiteral("the list has no rows"));
    focusedIs(world, scenario(world).rowKeys.last(), QStringLiteral("the last row to be focused"));
  });
  step(QStringLiteral("the thread list has keyboard focus on the settled section header"), [](World& world, const Captures&, const Table&) {
    const QString key = threadTitled(world, QStringLiteral("Settled neighbour"), {});
    updateThreadRow(world, key.mid(key.indexOf(QLatin1Char(':')) + 1), [](QJsonObject& row) {
      row.insert(QStringLiteral("settledOverride"), QStringLiteral("settled"));
      row.insert(QStringLiteral("settledAt"), QStringLiteral("2026-09-23T09:40:00Z"));
    });
    waitForSection(world, QStringLiteral("Settled neighbour"), QStringLiteral("settled"));
    Brick& brick = showSidebar(world);
    QQuickItem* list = focusList(world, brick);
    list->setProperty("cursorKey", QStringLiteral("header:settled"));
    world.waitFor([&] { return list->property("cursorKey").toString() == QLatin1String("header:settled"); },
                  QStringLiteral("the keyboard cursor on the settled section header"));
  });
  step(QStringLiteral("the settled section collapses"), [](World& world, const Captures&, const Table&) {
    Brick& brick = shown(world);
    world.waitFor(
        [&] {
          for (const QVariant& entry : brick.root()->property("rows").toList()) {
            const QVariantMap row = entry.toMap();
            if (row.value(QStringLiteral("kind")) == QLatin1String("header") && row.value(QStringLiteral("key")) == QLatin1String("settled")) {
              return !row.value(QStringLiteral("open")).toBool();
            }
          }
          return false;
        },
        QStringLiteral("the settled section to collapse"));
  });
  step(QStringLiteral("the menu for %1 opens").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor(
        [&] {
          const QVariant menu = world.state(QStringLiteral("menu"));
          return menu.typeId() == QMetaType::QVariantMap && !at(menu, QStringLiteral("items")).toList().isEmpty();
        },
        [&] { return QStringLiteral("a menu for %1; the shell shows %2").arg(c[0], show(world.state(QStringLiteral("menu")))); });
  });
  step(QStringLiteral("the menu for %1 is requested beside that thread").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariant menu = world.state(QStringLiteral("menu"));
    expect(menu.typeId() == QMetaType::QVariantMap && !at(menu, QStringLiteral("items")).toList().isEmpty(),
           QStringLiteral("no menu opened for %1").arg(c[0]));
    const QPoint centre = scenario(world).rowCentre;
    const double mx = at(menu, QStringLiteral("x")).toDouble();
    const double my = at(menu, QStringLiteral("y")).toDouble();
    expect(std::abs(mx - centre.x()) < 1.0 && std::abs(my - centre.y()) < 1.0,
           QStringLiteral("the menu is at %1, %2, not beside %3 at %4, %5").arg(mx).arg(my).arg(c[0]).arg(centre.x()).arg(centre.y()));
  });
  step(QStringLiteral("the thread %1 can be settled").arg(q), [](World& world, const Captures& c, const Table&) {
    threadTitled(world, c[0], {});
    waitForSection(world, c[0], QStringLiteral("active"));
  });
  step(QStringLiteral("the user (settles|wakes) %1 from the thread list").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString key = threadKeyOf(world, c[1]);
    Brick& brick = showSidebar(world);
    QQuickItem* row = hoverRow(world, brick, key);
    const QString name = c[0] == QLatin1String("settles") ? QStringLiteral("settleAction") : QStringLiteral("wakeAction");
    QQuickItem* button = visibleIn(row, name);
    if (!button) fail(QStringLiteral("%1 shows no %2").arg(c[1], name));
    clickItem(world, brick, button);
  });
  step(QStringLiteral("the thread %1 is snoozed").arg(q), [](World& world, const Captures& c, const Table&) {
    const QDateTime now = world.now();
    threadTitled(world, c[0],
                 {{QStringLiteral("snoozedUntil"), now.addDays(1).toUTC().toString(Qt::ISODateWithMs)},
                  {QStringLiteral("snoozedAt"), now.addSecs(-60).toUTC().toString(Qt::ISODateWithMs)}});
    waitForSection(world, c[0], QStringLiteral("snoozed"));
  });
  step(QStringLiteral("%1 offers to wake but not to settle").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString key = threadKeyOf(world, c[0]);
    Brick& brick = showSidebar(world);
    QQuickItem* row = hoverRow(world, brick, key);
    QQuickItem* wake = visibleIn(row, QStringLiteral("wakeAction"));
    QQuickItem* settle = visibleIn(row, QStringLiteral("settleAction"));
    expect(wake && !settle, QStringLiteral("%1 offers wake %2, settle %3").arg(c[0]).arg(wake != nullptr).arg(settle != nullptr));
  });
  step(QStringLiteral("%1 is no longer snoozed").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString key = threadKeyOf(world, c[0]);
    world.waitFor([&] { return sidebarSectionOf(world, key) != QLatin1String("snoozed") && !sidebarSectionOf(world, key).isEmpty(); },
                  [&] { return QStringLiteral("%1 to wake; it is in \"%2\"; the MC has %3").arg(key, sidebarSectionOf(world, key), world.describeCommands()); });
  });
  step(QStringLiteral("the thread list is scoped to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("sidebar.scope"), QVariantMap{{QStringLiteral("projectKey"), world.projectKey(c[0])}});
    world.sync();
  });
  step(QStringLiteral("the user starts a new thread from the thread list"), [](World& world, const Captures&, const Table&) {
    Brick& brick = showSidebar(world);
    brick.click(QStringLiteral("newThread"));
    world.sync();
  });

  // The header.
  step(QStringLiteral("the thread can open a terminal"), [](World& world, const Captures&, const Table&) {
    ensureTerminalThread(world);
    world.waitFor([&] { return terminals(world)->available(); }, QStringLiteral("the thread's terminal drawer"));
    scenario(world).terminalWasOpen = terminals(world)->isOpen();
  });
  step(QStringLiteral("the user toggles the terminal from the header"), [](World& world, const Captures&, const Table&) {
    world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nWorkspace { width: 900; height: 52 }\n", QSize(900, 52));
    Brick& brick = shown(world);
    world.waitFor(
        [&] {
          QQuickItem* toggle = brick.find(QStringLiteral("terminalToggle"));
          return toggle && toggle->isVisible();
        },
        QStringLiteral("the header's terminal toggle"));
    brick.click(QStringLiteral("terminalToggle"));
    world.sync();
  });
  step(QStringLiteral("the terminal drawer is toggled"), [](World& world, const Captures&, const Table&) {
    const bool was = scenario(world).terminalWasOpen;
    world.waitFor([&] { return terminals(world)->isOpen() != was; },
                  QStringLiteral("the terminal drawer to %1").arg(was ? QStringLiteral("close") : QStringLiteral("open")));
  });

  // The notification cards.
  step(QStringLiteral("the notification %1 offers %1").arg(q),
       [](World& world, const Captures& c, const Table&) { notify(world, c[0], c[1]); });
  step(QStringLiteral("the only notification is %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(toasts(world).isEmpty(), QStringLiteral("the shell already shows %1").arg(show(QVariant(toasts(world)))));
    notify(world, c[0], std::nullopt);
  });
  step(QStringLiteral("the %1 action of %1 runs").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString said = c[1] + QLatin1Char('/') + c[0];
    expect(scenario(world).ran->contains(said), QStringLiteral("the actions that ran are [%1]").arg(scenario(world).ran->join(QStringLiteral(", "))));
  });
  step(QStringLiteral("the user dismisses %1").arg(q), [](World& world, const Captures& c, const Table&) {
    Brick& brick = notifications(world);
    const auto toast = toastTitled(world, c[0]);
    if (!toast) fail(QStringLiteral("no notification is titled \"%1\"").arg(c[0]));
    const QString id = toast->value(QStringLiteral("id")).toString();
    // The close button shows on the card the pointer is over.
    QQuickItem* card = brick.item(QStringLiteral("notification-") + id);
    QTest::mouseMove(&brick.window(), brick.at(card));
    const QString name = QStringLiteral("notificationDismiss-") + id;
    QQuickItem* button = brick.find(name);
    if (!button || !button->isVisible()) fail(QStringLiteral("the card shows no %1").arg(name));
    clickItem(world, brick, button);
  });
  step(QStringLiteral("%1 is dismissed").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return !toastTitled(world, c[0]).has_value(); },
                  [&] { return QStringLiteral("the shell shows %1").arg(show(QVariant(toasts(world)))); });
  });
  step(QStringLiteral("no notifications are shown"), [](World& world, const Captures&, const Table&) {
    Brick& brick = notifications(world);
    QQuickItem* root = brick.root();
    if (!root) fail(QStringLiteral("the notifications did not load"));
    world.waitFor([&] { return !root->isVisible(); }, QStringLiteral("the notifications to hide"));
  });
});

}  // namespace
