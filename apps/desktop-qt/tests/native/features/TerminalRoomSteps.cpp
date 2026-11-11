// The terminal drawer's room in a real shell (features/terminal/drawer.feature,
// "The drawer has its own room under the thread"): the built-in layout, or a
// custom shell's column with the drawer under its thread, and where the
// drawer's buttons, list and terminals land in the window.

#include <QQuickItem>
#include <QQuickWindow>

#include "ComputerNotices.h"
#include "FakeTerminals.h"
#include "Harness.h"
#include "TerminalController.h"
#include "World.h"

namespace {

const QByteArray kBuiltIn =
    "import QtQuick\nimport HalC2.Bricks\n"
    "ShellWindow { id: root; width: 1200; height: 800; "
    "DefaultLayout { anchors.fill: parent; window: root } }\n";

// A custom shell as examples/terminal/shell.qml lays one out: a sidebar's
// room on the left, the thread over the drawer beside it.
const QByteArray kOwnColumn =
    "import QtQuick\nimport QtQuick.Layouts\nimport HalC2.Bricks\n"
    "ShellWindow { id: root; width: 1200; height: 800\n"
    "  RowLayout { anchors.fill: parent; spacing: 0\n"
    "    Item { Layout.preferredWidth: 300; Layout.fillHeight: true }\n"
    "    ColumnLayout { Layout.fillWidth: true; Layout.fillHeight: true; spacing: 0\n"
    "      Item { objectName: \"threadArea\"; Layout.fillWidth: true; Layout.fillHeight: true }\n"
    "      TerminalDrawer { Layout.fillWidth: true }\n"
    "    }\n"
    "  }\n"
    "}\n";

struct Room {
  QByteArray shell;
};

QQuickWindow* shellWindow(World& world) {
  return computerNotices::window(world, world.mc.part<Room>().shell);
}

QRectF rect(const QQuickItem* item) {
  return {item->mapToScene(QPointF()), QSizeF(item->width(), item->height())};
}

bool inside(QQuickWindow* window, const QQuickItem* item) {
  const QRectF r = rect(item);
  return r.width() > 0 && r.left() >= -0.5 && r.top() >= -0.5 && r.right() <= window->width() + 0.5 &&
         r.bottom() <= window->height() + 0.5;
}

QString describeRect(const QRectF& r) {
  return QStringLiteral("%1,%2 %3x%4").arg(r.x()).arg(r.y()).arg(r.width()).arg(r.height());
}

QQuickItem* one(QQuickWindow* window, const QString& name) {
  const QList<QQuickItem*> found = computerNotices::shownNamed(window, name);
  return found.isEmpty() ? nullptr : found.constFirst();
}

// The thread's bottom, and the bottom of the column it shares with the drawer.
std::optional<std::pair<double, double>> threadRoom(QQuickWindow* window) {
  QQuickItem* thread = one(window, QStringLiteral("threadArea"));
  if (!thread || !thread->parentItem()) return std::nullopt;
  return std::pair{rect(thread).bottom(), rect(thread->parentItem()).bottom()};
}

bool drawerOpen(World& world) {
  return world.native().controller<TerminalController>()->isOpen();
}

QString describe(World& world, QQuickWindow* window) {
  const auto room = threadRoom(window);
  QQuickItem* splits = one(window, QStringLiteral("terminalDrawerSplits"));
  return QStringLiteral("the thread ends at %1 of a column ending at %2; the drawer is %3, its terminals at %4")
      .arg(room ? room->first : -1)
      .arg(room ? room->second : -1)
      .arg(drawerOpen(world) ? QStringLiteral("open") : QStringLiteral("closed"),
           splits ? describeRect(rect(splits)) : QStringLiteral("none"));
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("the user's shell has the drawer (in the built-in layout|under its thread in a column of its own)"),
       [](World& world, const Captures& c, const Table&) {
         terminalfake::ensureProject(world);
         world.mc.part<Room>().shell = c[0] == QLatin1String("in the built-in layout") ? kBuiltIn : kOwnColumn;
         shellWindow(world);
         world.sync();
       });
  step(QStringLiteral("the drawer's buttons are inside the window"), [](World& world, const Captures&, const Table&) {
    QQuickWindow* window = shellWindow(world);
    world.waitFor([&] { return one(window, QStringLiteral("terminalDrawerActions")) != nullptr; },
                  QStringLiteral("the drawer's buttons"));
    for (const QString name : {QStringLiteral("terminalSplit"), QStringLiteral("terminalSplitVertical"), QStringLiteral("terminalNew"),
                               QStringLiteral("terminalClose")}) {
      QQuickItem* button = one(window, name);
      expect(button && inside(window, button),
             QStringLiteral("%1 is at %2, outside the window").arg(name, button ? describeRect(rect(button)) : QStringLiteral("nowhere")));
    }
  });
  step(QStringLiteral("the drawer's list names %1 and %1 under %1 inside the window").arg(q),
       [](World& world, const Captures& c, const Table&) {
         QQuickWindow* window = shellWindow(world);
         world.waitFor([&] { return computerNotices::shownNamed(window, QStringLiteral("terminalTab")).size() == 2; },
                       QStringLiteral("the drawer's list"));
         const QList<QQuickItem*> tabs = computerNotices::shownNamed(window, QStringLiteral("terminalTab"));
         QStringList names;
         for (QQuickItem* tab : tabs) names.append(tab->property("text").toString());
         expect(names == QStringList{c[0], c[1]}, QStringLiteral("the list names %1").arg(names.join(QStringLiteral(", "))));
         for (QQuickItem* tab : tabs) {
           expect(inside(window, tab), QStringLiteral("%1 is at %2, outside the window")
                                           .arg(tab->property("text").toString(), describeRect(rect(tab))));
         }
         const QList<QQuickItem*> groups = computerNotices::shownNamed(window, QStringLiteral("terminalGroupLabel"));
         expect(groups.size() == tabs.size(), QStringLiteral("%1 group labels for %2 terminals").arg(groups.size()).arg(tabs.size()));
         for (QQuickItem* group : groups) {
           expect(group->property("text").toString() == c[2] && inside(window, group),
                  QStringLiteral("a group label says %1 at %2").arg(group->property("text").toString(), describeRect(rect(group))));
         }
       });
  step(QStringLiteral("the terminal drawer takes no room"), [](World& world, const Captures&, const Table&) {
    QQuickWindow* window = shellWindow(world);
    world.waitFor(
        [&] {
          const auto room = threadRoom(window);
          return !drawerOpen(world) && room && qAbs(room->first - room->second) < 0.5;
        },
        [&] { return describe(world, window); });
  });
  step(QStringLiteral("the terminal drawer is drawn under the thread with its terminals"), [](World& world, const Captures&, const Table&) {
    QQuickWindow* window = shellWindow(world);
    world.waitFor(
        [&] {
          QQuickItem* splits = one(window, QStringLiteral("terminalDrawerSplits"));
          const auto room = threadRoom(window);
          if (!splits || !room) return false;
          const QRectF drawn = rect(splits);
          return drawn.height() > 100 && room->first <= drawn.top() + 0.5 && drawn.bottom() <= room->second + 0.5 &&
                 one(window, QStringLiteral("terminalDrawerActions")) && one(window, QStringLiteral("HalC2Terminal"));
        },
        [&] { return describe(world, window); });
  });
});

}  // namespace
