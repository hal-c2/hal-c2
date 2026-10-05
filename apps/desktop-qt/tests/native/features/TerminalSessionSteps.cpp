// Showing, hiding and sizing the thread's terminal, and where a new one
// starts (features/terminal/sessions.feature's desktop scenarios): the
// TerminalController behind the drawer, and the TerminalDrawer and Workspace
// bricks the user reaches it through.

#include <QJsonObject>
#include <QTest>

#include "Brick.h"
#include "FakeTerminals.h"
#include "Harness.h"
#include "KeybindingController.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "TerminalController.h"
#include "World.h"

namespace {

using namespace terminalfake;

// What the scenario's terminal did: who was handed the keyboard, the session
// showing the build, and the launch a script's terminal was opened with.
struct SessionWorld {
  QStringList focused;
  TerminalSession* session = nullptr;
  int attaches = 0;
  QJsonObject scriptLaunch;
  int windowHeight = 0;
};

const QString kWorktree = QStringLiteral("/work/p1-wt");
const QString kBuild = QStringLiteral("building cart… 42 modules");

TerminalController* terminals(World& world) {
  return world.native().controller<TerminalController>();
}

int attachesOf(World& world, const QString& threadId, const QString& terminalId) {
  int count = 0;
  for (const QJsonObject& sub : world.mc.subscriptions) {
    const QJsonObject shape = sub.value(QLatin1String("shape")).toObject();
    const QJsonObject input = shape.value(QLatin1String("input")).toObject();
    if (shape.value(QLatin1String("type")) == QLatin1String("terminal") && input.value(QLatin1String("threadId")) == threadId &&
        input.value(QLatin1String("terminalId")) == terminalId) {
      ++count;
    }
  }
  return count;
}

void openDrawer(World& world) {
  ensureProject(world);
  ensureThread(world);
  world.waitFor([&] { return terminals(world)->available(); }, QStringLiteral("the thread's terminal drawer"));
  if (!terminals(world)->isOpen()) world.bridge().dispatch(QStringLiteral("terminal.toggle"));
  world.waitFor([&] { return terminals(world)->isOpen() && !rowsIn(world, false).isEmpty(); }, [&] { return describeRows(world); });
}

// The drawer under a thread, in a window `height` tall.
Brick& drawerBrick(World& world, int height) {
  world.brick = std::make_unique<Brick>(world,
                                        "import QtQuick\nimport HalC2.Bricks\n"
                                        "Item { TerminalDrawer { objectName: \"drawer\"; anchors.left: parent.left; anchors.right: parent.right; "
                                        "anchors.bottom: parent.bottom } }\n",
                                        QSize(900, height));
  return *world.brick;
}

const Steps steps([] {
  Brick::registerSingletons();

  step(QStringLiteral("a thread whose environment can run terminals"), [](World& world, const Captures&, const Table&) {
    ensureProject(world);
    ensureThread(world);
    world.waitFor([&] { return terminals(world)->available(); }, QStringLiteral("the thread's terminal drawer"));
    SessionWorld& session = world.mc.part<SessionWorld>();
    QObject::connect(terminals(world), &TerminalController::focusRequested, terminals(world),
                     [&session](const QString& id) { session.focused.append(id); });
  });
  step(QStringLiteral("the thread's terminal is visible and has focus"), [](World& world, const Captures&, const Table&) {
    const QString threadId = shownThread(world);
    world.waitFor([&] { return terminals(world)->isOpen() && rowsIn(world, false).size() == 1 &&
                               terminalAttach(world, threadId, QStringLiteral("term-1")).has_value(); },
                  [&] { return describeRows(world); });
    // The drawer brick draws it and hands it the keyboard, as the controller asked.
    Brick& brick = drawerBrick(world, 700);
    QQuickItem* drawer = brick.item(QStringLiteral("drawer"));
    expect(world.mc.part<SessionWorld>().focused == QStringList{QStringLiteral("term-1")},
           QStringLiteral("the keyboard was asked for %1").arg(world.mc.part<SessionWorld>().focused.join(QStringLiteral(", "))));
    QMetaObject::invokeMethod(drawer, "focusTerminal");
    world.waitFor([&] { return drawer->isVisible() && drawer->height() >= 180 && drawer->property("bodyFocused").toBool(); },
                  [&] { return QStringLiteral("the drawer to show the terminal with the keyboard: visible %1, %2 tall, focused %3")
                                   .arg(drawer->isVisible()).arg(drawer->height()).arg(drawer->property("bodyFocused").toBool()); });
  });
  step(QStringLiteral("its shell keeps running"), [](World& world, const Captures&, const Table&) {
    world.sync();
    const QString threadId = shownThread(world);
    if (world.brick) {
      QQuickItem* drawer = world.brick->item(QStringLiteral("drawer"));
      expect(!drawer->isVisible() && drawer->height() == 0, QStringLiteral("the drawer still shows, %1 tall").arg(drawer->height()));
    }
    expect(!terminalCall(world, QStringLiteral("terminal.close"), threadId, QStringLiteral("term-1")) &&
               attached(world.mc).contains(threadId + QStringLiteral("/term-1")),
           describeRows(world) + QStringLiteral("; the MC got ") + describeTerminalCalls(world));
  });

  step(QStringLiteral("the selected thread's environment cannot run terminals"), [](World& world, const Captures&, const Table&) {
    // A thread whose project the environment does not have: nowhere to start a shell.
    world.mc.threads.insert(QStringLiteral("lost"), {{QStringLiteral("id"), QStringLiteral("lost")}, {QStringLiteral("title"), QStringLiteral("Lost")},
                                                       {QStringLiteral("projectId"), QStringLiteral("gone")},
                                                       {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                                                       {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}});
    ensureProject(world);
    const QString key = world.mc.environmentId + QStringLiteral(":lost");
    world.native().controller<NavigationController>()->open(NavigationController::Route::thread(key));
    world.waitFor([&] { return at(world.state(QStringLiteral("route")), QStringLiteral("threadKey")) == key; },
                  [&] { return QStringLiteral("the route to be %1; it is %2").arg(key, show(world.state(QStringLiteral("route")))); });
    world.sync();
  });
  step(QStringLiteral("the user is not offered a way to show the terminal"), [](World& world, const Captures&, const Table&) {
    expect(!terminals(world)->available(), QStringLiteral("the terminal drawer is available"));
    // The header has no toggle, and the command and its chord do nothing.
    Brick header(world, "import QtQuick\nimport HalC2.Bricks\nWorkspace { height: 52 }\n", QSize(1200, 52));
    expect(!header.item(QStringLiteral("terminalToggle"))->isVisible(), QStringLiteral("the header offers the terminal toggle"));
    world.bridge().dispatch(QStringLiteral("terminal.toggle"));
    world.sync();
    expect(!terminals(world)->isOpen() && attached(world.mc).isEmpty(),
           QStringLiteral("the toggle opened a terminal: %1").arg(describeRows(world)));
  });

  step(QStringLiteral("the terminal is showing in a window (\\d+) pixels tall"), [](World& world, const Captures& c, const Table&) {
    openDrawer(world);
    world.mc.part<SessionWorld>().windowHeight = c[0].toInt();
    Brick& brick = drawerBrick(world, c[0].toInt());
    QQuickItem* drawer = brick.item(QStringLiteral("drawer"));
    world.waitFor([&] { return drawer->isVisible() && drawer->height() == terminals(world)->height(); },
                  [&] { return QStringLiteral("the drawer to show; it is %1 tall").arg(drawer->height()); });
  });
  step(QStringLiteral("the user drags the terminal to (\\d+) pixels tall"), [](World& world, const Captures& c, const Table&) {
    Brick& brick = *world.brick;
    QQuickItem* drawer = brick.item(QStringLiteral("drawer"));
    const int window = world.mc.part<SessionWorld>().windowHeight;
    // The drag edge is the drawer's top; the user takes it to where the
    // drawer would be the height asked for.
    const QPoint from = brick.at(drawer, 0.5, 0) + QPoint(0, 2);
    const QPoint to(from.x(), window - c[0].toInt() + 2);
    QTest::mousePress(&brick.window(), Qt::LeftButton, Qt::NoModifier, from);
    const int steps = 8;
    for (int step = 1; step <= steps; ++step) {
      QTest::mouseMove(&brick.window(), QPoint(from.x(), from.y() + (to.y() - from.y()) * step / steps));
    }
    QTest::mouseRelease(&brick.window(), Qt::LeftButton, Qt::NoModifier, to);
    world.sync();
  });
  step(QStringLiteral("the terminal is (\\d+) pixels tall"), [](World& world, const Captures& c, const Table&) {
    QQuickItem* drawer = world.brick->item(QStringLiteral("drawer"));
    world.waitFor([&] { return int(drawer->height()) == c[0].toInt() && terminals(world)->height() == c[0].toInt(); },
                  [&] { return QStringLiteral("the drawer to be %1 tall; it is %2 and the shell keeps %3").arg(c[0]).arg(drawer->height()).arg(terminals(world)->height()); });
  });

  step(QStringLiteral("the terminal shows the output of a running build"), [](World& world, const Captures&, const Table&) {
    openDrawer(world);
    const QString threadId = shownThread(world);
    world.waitFor([&] { return terminalAttach(world, threadId, QStringLiteral("term-1")).has_value(); }, [&] { return describeRows(world); });
    world.sync();
    print(world.mc, threadId, QStringLiteral("term-1"), kBuild);
    TerminalSession* session = terminalSession(world, QStringLiteral("term-1"));
    world.waitFor([&] { return session->transcript().contains(kBuild); }, [&] { return QStringLiteral("the build output; the terminal shows \"%1\"").arg(session->transcript()); });
    SessionWorld& kept = world.mc.part<SessionWorld>();
    kept.session = session;
    kept.attaches = attachesOf(world, threadId, QStringLiteral("term-1"));
  });
  step(QStringLiteral("the user hides the terminal and shows it again"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("terminal.toggle"));
    world.waitFor([&] { return !terminals(world)->isOpen(); }, QStringLiteral("the terminal drawer to hide"));
    world.sync();
    world.bridge().dispatch(QStringLiteral("terminal.toggle"));
    world.waitFor([&] { return terminals(world)->isOpen(); }, QStringLiteral("the terminal drawer to show"));
    world.sync();
  });
  step(QStringLiteral("the same output is still on screen without a reload"), [](World& world, const Captures&, const Table&) {
    const SessionWorld& kept = world.mc.part<SessionWorld>();
    const QString threadId = shownThread(world);
    TerminalSession* session = terminalSession(world, QStringLiteral("term-1"));
    expect(session == kept.session, QStringLiteral("the terminal was made again"));
    expect(session->transcript().contains(kBuild), QStringLiteral("the terminal shows \"%1\"").arg(session->transcript()));
    expect(attachesOf(world, threadId, QStringLiteral("term-1")) == kept.attaches,
           QStringLiteral("the terminal was attached %1 times, %2 before hiding").arg(attachesOf(world, threadId, QStringLiteral("term-1"))).arg(kept.attaches));
    // The drawer draws that screen: the Terminal item holds the build's output.
    Brick& brick = drawerBrick(world, 700);
    QQuickItem* terminal = brick.item(QStringLiteral("HalC2Terminal"));
    QString text;
    world.waitFor([&] {
      QMetaObject::invokeMethod(terminal, "text", Q_RETURN_ARG(QString, text));
      return text.contains(kBuild);
    }, [&] { return QStringLiteral("the drawer to draw the build output; it draws \"%1\"").arg(text); });
  });

  // The drawer's own chord and what it keeps across a restart (terminal/drawer.feature).
  step(QStringLiteral("the user bound %1 to %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    auto* keymap = world.native().controller<KeybindingController>();
    keymap->save(c[0], c[1], QString());
    world.waitFor([&] { return !keymap->saving() && keymap->shortcutLabel(c[0]) == keymap->keyLabel(c[1]); },
                  [&] { return QStringLiteral("%1 on %2; it is on %3").arg(c[0], keymap->keyLabel(c[1]), keymap->shortcutLabel(c[0])); });
  });
  step(QStringLiteral("the terminal drawer opens"), [](World& world, const Captures&, const Table&) {
    const QString threadId = shownThread(world);
    world.waitFor([&] { return terminals(world)->isOpen() && terminalAttach(world, threadId, QStringLiteral("term-1")).has_value(); },
                  [&] { return describeRows(world); });
  });
  step(QStringLiteral("the user dragged the drawer to (\\d+) pixels with %1 active").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    const QString threadId = shownThread(world);
    world.bridge().dispatch(QStringLiteral("terminal.toggle"));
    world.bridge().dispatch(QStringLiteral("terminal.new"));
    world.waitFor([&] { return terminalAttach(world, threadId, c[1]).has_value() && terminals(world)->activeTerminalId() == c[1]; },
                  [&] { return describeRows(world); });
    Brick& brick = drawerBrick(world, 900);
    QQuickItem* drawer = brick.item(QStringLiteral("drawer"));
    const QPoint from = brick.at(drawer, 0.5, 0) + QPoint(0, 2);
    const QPoint to(from.x(), 900 - c[0].toInt() + 2);
    QTest::mousePress(&brick.window(), Qt::LeftButton, Qt::NoModifier, from);
    for (int step = 1; step <= 8; ++step) QTest::mouseMove(&brick.window(), QPoint(from.x(), from.y() + (to.y() - from.y()) * step / 8));
    QTest::mouseRelease(&brick.window(), Qt::LeftButton, Qt::NoModifier, to);
    world.waitFor([&] { return terminals(world)->height() == c[0].toInt(); },
                  [&] { return QStringLiteral("the drawer to be %1 tall; it is %2").arg(c[0]).arg(terminals(world)->height()); });
    world.sync();
  });
  step(QStringLiteral("the desktop starts again"), [](World& world, const Captures&, const Table&) {
    const QString key = world.native().controller<NavigationController>()->threadKey();
    world.restart();
    world.connect();
    world.waitFor([&] { return world.native().controller<NavigationController>()->threadKey() == key && terminals(world)->available(); },
                  [&] { return QStringLiteral("the window to show %1 again; it shows %2").arg(key, show(world.state(QStringLiteral("route")))); });
  });
  step(QStringLiteral("the drawer is (\\d+) pixels tall with %1 active").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    const QString threadId = shownThread(world);
    world.waitFor([&] { return terminals(world)->isOpen() && terminals(world)->height() == c[0].toInt() && terminals(world)->activeTerminalId() == c[1]; },
                  [&] { return QStringLiteral("the drawer open at %1 on %2; it is %3 at %4 on %5; %6").arg(c[0], c[1], terminals(world)->isOpen() ? QStringLiteral("open") : QStringLiteral("closed"))
                                   .arg(terminals(world)->height()).arg(terminals(world)->activeTerminalId(), describeRows(world)); });
    // Both terminals are the MC's own, attached again, and drawn at that height.
    expect(tabLabels(world) == QLatin1String("Terminal 1, Terminal 2") && terminalAttach(world, threadId, c[1]).has_value(), describeRows(world));
    Brick& brick = drawerBrick(world, 900);
    QQuickItem* drawer = brick.item(QStringLiteral("drawer"));
    world.waitFor([&] { return int(drawer->height()) == c[0].toInt(); }, [&] { return QStringLiteral("the drawer drawn %1 tall").arg(drawer->height()); });
  });

  // Threads the user left keep their terminals attached (terminal/tabs.feature).
  step(QStringLiteral("the user has visited ten threads with open terminals"), [](World& world, const Captures&, const Table&) {
    ensureProject(world);
    const QString project = world.mc.projects.firstKey();
    for (int n = 1; n <= 10; ++n) {
      const QString threadId = QStringLiteral("visited-%1").arg(n);
      const QJsonObject row{{QStringLiteral("id"), threadId}, {QStringLiteral("title"), QStringLiteral("Visit %1").arg(n)}, {QStringLiteral("projectId"), project},
                            {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")}, {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}};
      world.mc.threads.insert(threadId, row);
      world.mc.sendRow(threadId, row);
      const QString key = world.mc.environmentId + QLatin1Char(':') + threadId;
      world.native().controller<NavigationController>()->open(NavigationController::Route::thread(key));
      world.waitFor([&] { return terminals(world)->threadKey() == key && terminals(world)->available(); },
                    [&] { return QStringLiteral("the drawer of %1; it is on %2").arg(key, terminals(world)->threadKey()); });
      world.bridge().dispatch(QStringLiteral("terminal.toggle"));
      world.waitFor([&] { return terminalAttach(world, threadId, QStringLiteral("term-1")).has_value() && !rowsIn(world, false).isEmpty(); },
                    [&] { return describeRows(world); });
      world.sync();
      print(world.mc, threadId, QStringLiteral("term-1"), QStringLiteral("started in %1\r\n").arg(threadId));
      world.sync();
      if (n == 1) {
        SessionWorld& kept = world.mc.part<SessionWorld>();
        kept.session = terminalSession(world, QStringLiteral("term-1"));
      }
    }
  });
  step(QStringLiteral("the user returns to one of them"), [](World& world, const Captures&, const Table&) {
    // The first one, whose build went on printing while the user was away.
    const QString threadId = QStringLiteral("visited-1");
    SessionWorld& kept = world.mc.part<SessionWorld>();
    kept.attaches = attachesOf(world, threadId, QStringLiteral("term-1"));
    expect(attached(world.mc).contains(threadId + QStringLiteral("/term-1")), QStringLiteral("%1's terminal is no longer attached").arg(threadId));
    print(world.mc, threadId, QStringLiteral("term-1"), kBuild);
    world.sync();
    const QString key = world.mc.environmentId + QLatin1Char(':') + threadId;
    world.native().controller<NavigationController>()->open(NavigationController::Route::thread(key));
    world.waitFor([&] { return terminals(world)->threadKey() == key && terminals(world)->isOpen() && !rowsIn(world, false).isEmpty(); },
                  [&] { return describeRows(world); });
    world.sync();
  });
  step(QStringLiteral("its terminals show their live output without replaying history"), [](World& world, const Captures&, const Table&) {
    const SessionWorld& kept = world.mc.part<SessionWorld>();
    const QString threadId = QStringLiteral("visited-1");
    TerminalSession* session = terminalSession(world, QStringLiteral("term-1"));
    expect(session == kept.session, QStringLiteral("the terminal was attached anew"));
    expect(attachesOf(world, threadId, QStringLiteral("term-1")) == kept.attaches && kept.attaches == 1,
           QStringLiteral("the terminal was attached %1 times").arg(attachesOf(world, threadId, QStringLiteral("term-1"))));
    expect(session->transcript().contains(kBuild) && session->transcript().contains(QLatin1String("started in visited-1")),
           QStringLiteral("the terminal shows \"%1\"").arg(session->transcript()));
    Brick& brick = drawerBrick(world, 700);
    QQuickItem* terminal = brick.item(QStringLiteral("HalC2Terminal"));
    QString text;
    world.waitFor([&] {
      QMetaObject::invokeMethod(terminal, "text", Q_RETURN_ARG(QString, text));
      return text.contains(kBuild);
    }, [&] { return QStringLiteral("the drawer to draw the live output; it draws \"%1\"").arg(text); });
  });

  step(QStringLiteral("a thread working in a worktree"), [](World& world, const Captures&, const Table&) {
    ensureProject(world);
    showThread(world, world.mc.projects.firstKey(), kWorktree);
    world.waitFor([&] { return terminals(world)->available(); }, QStringLiteral("the thread's terminal drawer"));
  });
  step(QStringLiteral("the user opens another terminal from the drawer"), [](World& world, const Captures&, const Table&) {
    const QString threadId = shownThread(world);
    world.bridge().dispatch(QStringLiteral("terminal.toggle"));
    world.waitFor([&] { return terminalAttach(world, threadId, QStringLiteral("term-1")).has_value(); }, [&] { return describeRows(world); });
    // The drawer's own "New terminal" button.
    Brick& brick = drawerBrick(world, 700);
    brick.click(QStringLiteral("terminalNew"));
    world.waitFor([&] { return terminalAttach(world, threadId, QStringLiteral("term-2")).has_value(); }, [&] { return describeRows(world); });
  });
  step(QStringLiteral("it starts in the same folder and worktree as the thread"), [](World& world, const Captures&, const Table&) {
    const QJsonObject launch = *terminalAttach(world, shownThread(world), QStringLiteral("term-2"));
    const QJsonObject env = launch.value(QLatin1String("env")).toObject();
    expect(launch.value(QLatin1String("cwd")) == kWorktree && launch.value(QLatin1String("worktreePath")) == kWorktree &&
               env.value(QLatin1String("HAL_C2_WORKTREE_PATH")) == kWorktree && env.value(QLatin1String("HAL_C2_PROJECT_ROOT")) == QLatin1String("/work/p1"),
           QStringLiteral("term-2 started with %1").arg(QString::fromUtf8(QJsonDocument(launch).toJson(QJsonDocument::Compact))));
  });

  step(QStringLiteral("a project script is running in a terminal"), [](World& world, const Captures&, const Table&) {
    ensureProject(world);
    const QString project = world.mc.projects.firstKey();
    addAction(world, project, QStringLiteral("Dev"), QStringLiteral("bun dev"));
    showThread(world, project, kWorktree);
    world.waitFor([&] { return terminals(world)->available(); }, QStringLiteral("the thread's terminal drawer"));
    const QString threadId = shownThread(world);
    world.bridge().dispatch(QStringLiteral("workspace.runScript"), QVariantMap{{QStringLiteral("scriptId"), QStringLiteral("dev")}});
    world.waitFor([&] { return terminalWrites(world, QStringLiteral("term-1")).contains(QStringLiteral("bun dev\r")); },
                  [&] { return QStringLiteral("the script to run; the MC got %1").arg(describeTerminalCalls(world)); });
    world.mc.part<SessionWorld>().scriptLaunch = *terminalCall(world, QStringLiteral("terminal.open"), threadId, QStringLiteral("term-1"));
  });
  step(QStringLiteral("the user opens another terminal next to it"), [](World& world, const Captures&, const Table&) {
    const QString threadId = shownThread(world);
    // The drawer's split button, on the script's terminal.
    Brick& brick = drawerBrick(world, 700);
    brick.click(QStringLiteral("terminalSplit"));
    world.waitFor([&] { return terminalAttach(world, threadId, QStringLiteral("term-2")).has_value(); }, [&] { return describeRows(world); });
  });
  step(QStringLiteral("the new terminal starts in the same folder and worktree as the script"), [](World& world, const Captures&, const Table&) {
    const QJsonObject script = world.mc.part<SessionWorld>().scriptLaunch;
    const QJsonObject launch = *terminalAttach(world, shownThread(world), QStringLiteral("term-2"));
    const QList<TerminalTabs::Row> rows = rowsIn(world, false);
    expect(rows.size() == 2 && rows.at(0).group == rows.at(1).group, describeRows(world));
    for (const QString& field : {QStringLiteral("cwd"), QStringLiteral("worktreePath"), QStringLiteral("env")}) {
      expect(launch.value(field) == script.value(field) && !script.value(field).isUndefined(),
             QStringLiteral("term-2 started with %1; the script's with %2")
                 .arg(QString::fromUtf8(QJsonDocument(launch).toJson(QJsonDocument::Compact)), QString::fromUtf8(QJsonDocument(script).toJson(QJsonDocument::Compact))));
    }
    expect(launch.value(QLatin1String("cwd")) == kWorktree, QStringLiteral("term-2 started in %1").arg(launch.value(QLatin1String("cwd")).toString()));
  });
});

}  // namespace
