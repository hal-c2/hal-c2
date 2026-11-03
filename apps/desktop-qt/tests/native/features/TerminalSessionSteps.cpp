// Showing, hiding and sizing the thread's terminal, and where a new one
// starts (features/terminal/sessions.feature's desktop scenarios): the
// TerminalController behind the drawer, and the TerminalDrawer and Workspace
// bricks the user reaches it through.

#include <QJsonObject>
#include <QPointer>
#include <QTest>

// Nothing makes the real engine fail and its `error` is read-only, while Qt
// resolves `Terminal` to this registered type ahead of the test double: only
// what createTerminal() does when it fails can stand in for the failure.
#define private public
#include <GhosttyTerminal.h>
#undef private

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
  // The window shrank: the drawer is pulled in, and the height the user chose stays.
  bool windowShrunk = false;
  int resizes = 0;
};

const QString kWorktree = QStringLiteral("/work/p1-wt");
const QString kTerm = QStringLiteral("term-1");

struct AckWorld {
  // The acks heard before what a step counts.
  qsizetype marked = 0;
  // The terminal looked at, and its thread if the user has left it.
  QString key;
  QString thread;
  // The Terminal whose engine failed.
  QPointer<QQuickItem> engine;
  ~AckWorld() { TerminalSession::setAckDelay(); }
};

QString shownOrLeft(World& world) {
  const QString key = world.mc.part<AckWorld>().key;
  return key.isEmpty() ? shownThread(world) + QLatin1Char('/') + kTerm : key;
}
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
    const bool shrunk = world.mc.part<SessionWorld>().windowShrunk;
    world.waitFor([&] { return int(drawer->height()) == c[0].toInt() && (shrunk || terminals(world)->height() == c[0].toInt()); },
                  [&] { return QStringLiteral("the drawer to be %1 tall; it is %2 and the shell keeps %3").arg(c[0]).arg(drawer->height()).arg(terminals(world)->height()); });
  });

  step(QStringLiteral("the terminal is showing (\\d+) pixels tall in a window (\\d+) pixels tall"), [](World& world, const Captures& c, const Table&) {
    openDrawer(world);
    world.bridge().dispatch(QStringLiteral("terminal.resize"), QVariantMap{{QStringLiteral("height"), c[0].toInt()}});
    world.waitFor([&] { return terminals(world)->height() == c[0].toInt(); }, QStringLiteral("the terminal's height to be kept"));
    QQuickItem* drawer = drawerBrick(world, c[1].toInt()).item(QStringLiteral("drawer"));
    world.waitFor([&] { return int(drawer->height()) == c[0].toInt(); }, [&] { return QStringLiteral("the drawer is %1 tall").arg(drawer->height()); });
    QQuickItem* terminal = world.brick->item(QStringLiteral("HalC2Terminal"));
    const int rows = terminal->property("rows").toInt();
    world.waitFor([&] {
      const auto resize = lastTerminalCall(world, QStringLiteral("terminal.resize"), shownThread(world), QStringLiteral("term-1"));
      return resize && resize->value(QLatin1String("rows")).toInt() == rows;
    }, [&] { return QStringLiteral("the shell at %1 rows; the MC got %2").arg(rows).arg(describeTerminalCalls(world)); });
    world.mc.part<SessionWorld>().resizes = rows;
  });
  step(QStringLiteral("the user shrinks the window to (\\d+) pixels tall"), [](World& world, const Captures& c, const Table&) {
    world.mc.part<SessionWorld>().windowShrunk = true;
    Brick& brick = *world.brick;
    brick.window().resize(brick.window().width(), c[0].toInt());
    brick.root()->setHeight(c[0].toInt());
    world.sync();
  });
  step(QStringLiteral("the terminal's shell is resized to match"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = world.brick->item(QStringLiteral("HalC2Terminal"));
    world.waitFor([&] {
      const auto resize = lastTerminalCall(world, QStringLiteral("terminal.resize"), shownThread(world), QStringLiteral("term-1"));
      const int rows = terminal->property("rows").toInt();
      return rows < world.mc.part<SessionWorld>().resizes && resize && resize->value(QLatin1String("rows")).toInt() == rows;
    }, [&] { return QStringLiteral("the shell at %1 rows; the MC got %2").arg(terminal->property("rows").toInt()).arg(describeTerminalCalls(world)); });
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

  // Saying what was read (terminal/io.feature): the fake MC's output window.
  const auto ackedAll = [](World& world) {
    const QString key = shownOrLeft(world);
    const FakeTerminals& fake = world.mc.part<FakeTerminals>();
    const FakeTerminals::Window* window = terminalWindow(world.mc, key);
    return window && window->pending.isEmpty() && !fake.acks.isEmpty();
  };
  step(QStringLiteral("saying what was read waits as long as it can"), [](World& world, const Captures&, const Table&) {
    const QString key = shownThread(world) + QLatin1Char('/') + kTerm;
    world.waitFor([&] { return terminalWindow(world.mc, key)->pending.isEmpty(); }, QStringLiteral("the MC to hear of the output so far"));
    world.mc.part<AckWorld>().marked = world.mc.part<FakeTerminals>().acks.size();
    TerminalSession::setAckDelay(3600000);
  });
  step(QStringLiteral("the shell prints a little, five times"), [](World& world, const Captures&, const Table&) {
    for (int chunk = 0; chunk < 5; ++chunk) print(world.mc, shownThread(world), kTerm, QStringLiteral("chunk %1\r\n").arg(chunk));
    world.waitFor([&] { return terminalSession(world, kTerm)->transcript().contains(QLatin1String("chunk 4")); }, QStringLiteral("the output to arrive"));
  });
  step(QStringLiteral("the shell prints a little"), [](World& world, const Captures&, const Table&) {
    world.sync();
    world.mc.part<AckWorld>().key = shownThread(world) + QLatin1Char('/') + kTerm;
    print(world.mc, shownThread(world), kTerm, QStringLiteral("a little\r\n"));
  });
  step(QStringLiteral("the MC has heard nothing about that output yet"), [](World& world, const Captures&, const Table&) {
    world.sync();
    const qsizetype acks = world.mc.part<FakeTerminals>().acks.size() - world.mc.part<AckWorld>().marked;
    expect(acks == 0, QStringLiteral("the MC heard %1 times").arg(acks));
  });
  step(QStringLiteral("the shell prints 20 KiB more"), [](World& world, const Captures&, const Table&) {
    print(world.mc, shownThread(world), kTerm, QString(20 * 1024, QLatin1Char('x')) + QStringLiteral("\r\n"));
  });
  step(QStringLiteral("the MC hears once that all of it has been read"), [ackedAll](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return ackedAll(world); }, QStringLiteral("the MC to hear"));
    world.sync();
    const FakeTerminals& fake = world.mc.part<FakeTerminals>();
    expect(fake.acks.size() - world.mc.part<AckWorld>().marked == 1, QStringLiteral("the MC heard %1 times").arg(fake.acks.size() - world.mc.part<AckWorld>().marked));
    const qint64 printed = fake.terminals.value(shownOrLeft(world)).sequence;
    expect(fake.acks.last().value(QLatin1String("sequence")).toInteger() == printed, QStringLiteral("the MC heard of an earlier chunk than %1").arg(printed));
  });
  step(QStringLiteral("the MC hears that all of it has been read"), [ackedAll](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return ackedAll(world); }, [&] { return QStringLiteral("the MC to hear; it has heard %1 times").arg(world.mc.part<FakeTerminals>().acks.size()); });
  });
  step(QStringLiteral("the user hides the terminal drawer"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("terminal.toggle"));
    world.sync();
    expect(!world.native().controller<TerminalController>()->isOpen(), QStringLiteral("the drawer is still open"));
  });
  step(QStringLiteral("the connection to the MC drops and comes back"), [](World& world, const Captures&, const Table&) {
    world.sync();
    world.mc.part<AckWorld>().marked = world.mc.part<FakeTerminals>().acks.size();
    const qsizetype subscribed = world.mc.subscriptions.size();
    world.mc.drop();
    world.waitFor([&] { return world.mc.subscriptions.size() > subscribed && !attached(world.mc).isEmpty(); }, QStringLiteral("the terminal to attach again"));
    world.sync();
  });
  step(QStringLiteral("the terminal asks again to say what it has read"), [](World& world, const Captures&, const Table&) {
    expect(terminalWindow(world.mc, shownThread(world) + QLatin1Char('/') + kTerm) != nullptr, QStringLiteral("the attach asked for no window"));
  });
  step(QStringLiteral("the MC hears once, of the new snapshot"), [](World& world, const Captures&, const Table&) {
    const QString key = shownThread(world) + QLatin1Char('/') + kTerm;
    world.waitFor([&] { return terminalWindow(world.mc, key)->pending.isEmpty(); }, QStringLiteral("the MC to hear of the snapshot"));
    world.sync();
    const FakeTerminals& fake = world.mc.part<FakeTerminals>();
    expect(fake.acks.size() - world.mc.part<AckWorld>().marked == 1, QStringLiteral("the MC heard %1 times").arg(fake.acks.size() - world.mc.part<AckWorld>().marked));
  });
  step(QStringLiteral("the user goes to another thread"), [](World& world, const Captures&, const Table&) {
    AckWorld& acks = world.mc.part<AckWorld>();
    acks.key = shownThread(world) + QLatin1Char('/') + kTerm;
    acks.thread = shownThread(world);
    world.waitFor([&] { return terminalWindow(world.mc, acks.key)->pending.isEmpty(); }, QStringLiteral("the MC to hear of the output so far"));
    const QString other = QStringLiteral("elsewhere");
    QJsonObject row = world.mc.threads.value(acks.thread);
    row.insert(QStringLiteral("id"), other);
    world.mc.threads.insert(other, row);
    world.mc.sendRow(other, row);
    world.native().controller<NavigationController>()->open(NavigationController::Route::thread(world.mc.environmentId + QLatin1Char(':') + other));
    world.waitFor([&] { return shownThread(world) == other; }, QStringLiteral("the other thread to show"));
    world.sync();
  });
  step(QStringLiteral("the shell prints more than the MC sends a client that has not read it"), [](World& world, const Captures&, const Table&) {
    AckWorld& acks = world.mc.part<AckWorld>();
    world.sync();
    acks.marked = world.mc.part<FakeTerminals>().acks.size();
    for (int chunk = 0; chunk < 5; ++chunk) print(world.mc, acks.thread, kTerm, QString(20 * 1024, QLatin1Char('x')) + QStringLiteral("\r\n"));
    print(world.mc, acks.thread, kTerm, QStringLiteral("the very last line\r\n"));
    world.sync();
  });
  step(QStringLiteral("the MC holds the rest back"), [](World& world, const Captures&, const Table&) {
    AckWorld& acks = world.mc.part<AckWorld>();
    expect(terminalWindow(world.mc, acks.key)->behind, QStringLiteral("everything went out: the parked terminal said it had read it"));
    expect(world.mc.part<FakeTerminals>().acks.size() == acks.marked, QStringLiteral("the parked terminal said what it read"));
  });
  step(QStringLiteral("the terminal stays attached"), [](World& world, const Captures&, const Table&) {
    expect(attached(world.mc).contains(world.mc.part<AckWorld>().key), attached(world.mc).join(QLatin1Char(' ')));
  });
  step(QStringLiteral("the user returns to the terminal's thread"), [](World& world, const Captures&, const Table&) {
    const QString thread = world.mc.part<AckWorld>().thread;
    world.native().controller<NavigationController>()->open(NavigationController::Route::thread(world.mc.environmentId + QLatin1Char(':') + thread));
    world.waitFor([&] { return shownThread(world) == thread; }, QStringLiteral("the thread to show again"));
  });
  step(QStringLiteral("the terminal has everything the shell printed"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return terminalSession(world, kTerm)->transcript().contains(QLatin1String("the very last line")); },
                  QStringLiteral("what the MC held back"));
  });
  step(QStringLiteral("the MC holds nothing back"), [](World& world, const Captures&, const Table&) {
    const QString key = world.mc.part<AckWorld>().key;
    world.waitFor([&] { return !terminalWindow(world.mc, key)->behind && terminalWindow(world.mc, key)->pending.isEmpty(); }, QStringLiteral("the MC to hear of the snapshot"));
  });

  step(QStringLiteral("the terminal's rendering engine cannot start"), [](World& world, const Captures&, const Table&) {
    ensureProject(world);
    ensureThread(world);
  });
  step(QStringLiteral("the user opens a terminal"), [](World& world, const Captures&, const Table&) {
    auto* terminal = qobject_cast<GhosttyTerminalItem*>(drawnTerminal(world));
    expect(terminal != nullptr, QStringLiteral("the drawer has no Terminal"));
    world.mc.part<AckWorld>().engine = terminal;
    terminal->setError(QStringLiteral("Could not create a terminal"));
  });
  step(QStringLiteral("the terminal says why, followed by %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    QQuickItem* said = world.brick->item(QStringLiteral("terminalEngineError"));
    const QString text = said->property("text").toString();
    expect(said->isVisible() && text == QStringLiteral("Could not create a terminal: ") + c[0], QStringLiteral("the terminal says \"%1\"").arg(text));
  });
  step(QStringLiteral("the user closes the terminal and opens it again"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("terminal.close"));
    confirmTerminalClose(world);
    world.waitFor([&] { return world.mc.part<AckWorld>().engine.isNull(); }, QStringLiteral("the failed engine to go"));
    world.bridge().dispatch(QStringLiteral("terminal.toggle"));
    world.waitFor([&] { return !visibleItems(world, QStringLiteral("HalC2Terminal")).isEmpty(); }, [&] { return describeRows(world); });
  });
  step(QStringLiteral("the terminal tries to start the engine again"), [](World& world, const Captures&, const Table&) {
    expect(!world.brick->item(QStringLiteral("terminalEngineError"))->isVisible(), QStringLiteral("the new Terminal still says it failed"));
  });
});

}  // namespace
