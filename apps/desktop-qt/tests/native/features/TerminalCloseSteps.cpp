// How the desktop's terminals end and fail (features/terminal/tabs.feature,
// io.feature, errors.feature, reconnect.feature): the question a close asks,
// a shell that leaves on its own, a close the MC cannot do, a terminal that
// does not open, and how much output the client keeps.

#include <QJsonArray>
#include <QJsonObject>
#include <QTest>

#include "Brick.h"
#include "ComposerController.h"
#include "FakeTerminals.h"
#include "Harness.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "TerminalController.h"
#include "World.h"

namespace {

using namespace terminalfake;

struct CloseWorld {
  // The terminal the scenario is about ("it").
  QString terminal;
  // Every question the shell asked, in order.
  QList<QVariantMap> questions;
  // The active group when the last close was asked for.
  QString groupBefore;
  int printed = 0;
  QString firstChunk;
  QString lastChunk;
};

TerminalController* terminals(World& world) {
  return world.native().controller<TerminalController>();
}

void follow(World& world) {
  CloseWorld& close = world.mc.part<CloseWorld>();
  QObject::connect(&world.bridge(), &ShellBridge::stateEntryChanged, terminals(world), [&close](const QString& key, const QVariant& value) {
    if (key == QLatin1String("confirmation") && value.typeId() == QMetaType::QVariantMap) close.questions.append(value.toMap());
  });
}

// The drawer open on the thread with `count` terminals, the last one active.
void openTerminals(World& world, int count) {
  ensureProject(world);
  ensureThread(world);
  world.waitFor([&] { return terminals(world)->available(); }, QStringLiteral("the thread's terminal drawer"));
  follow(world);
  const QString threadId = shownThread(world);
  world.bridge().dispatch(QStringLiteral("terminal.toggle"));
  for (int n = 1; n <= count; ++n) {
    if (n > 1) world.bridge().dispatch(QStringLiteral("terminal.new"));
    const QString id = QStringLiteral("term-%1").arg(n);
    world.waitFor([&] { return terminalAttach(world, threadId, id).has_value() && terminals(world)->activeTerminalId() == id; },
                  [&] { return describeRows(world); });
  }
  world.sync();
}

// The drawer drawn, in the world's brick.
void drawDrawer(World& world) {
  if (world.brick) return;
  world.brick = std::make_unique<Brick>(world,
                                        "import QtQuick\nimport HalC2.Bricks\nItem { TerminalDrawer { anchors.left: parent.left; "
                                        "anchors.right: parent.right; anchors.bottom: parent.bottom } }\n",
                                        QSize(900, 600));
}

QVariant question(World& world) {
  return world.state(QStringLiteral("confirmation"));
}

void answer(World& world, bool accepted) {
  expect(question(world).typeId() == QMetaType::QVariantMap, QStringLiteral("no question is asked"));
  world.bridge().dispatch(QStringLiteral("confirmation.answer"),
                          QVariantMap{{QStringLiteral("requestId"), at(question(world), QStringLiteral("requestId"))}, {QStringLiteral("accepted"), accepted}});
  world.sync();
}

const Steps steps([] {
  Brick::registerSingletons();
  const QString q = kQuoted;

  step(QStringLiteral("the terminal \"Terminal (\\d+)\" is running"), [](World& world, const Captures& c, const Table&) {
    openTerminals(world, c[0].toInt());
    world.mc.part<CloseWorld>().terminal = QStringLiteral("term-") + c[0];
    print(world.mc, shownThread(world), QStringLiteral("term-") + c[0], QStringLiteral("bun dev\r\nlistening on 5173\r\n"));
    world.sync();
  });
  step(QStringLiteral("the user closes it"), [](World& world, const Captures&, const Table&) {
    // The drawer's own close button, on the active terminal.
    Brick drawer(world, "import QtQuick\nimport HalC2.Bricks\nItem { TerminalDrawer { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom } }\n",
                 QSize(900, 700));
    drawer.click(QStringLiteral("terminalClose"));
    world.sync();
    // A close the scenario does not ask about is confirmed.
    if (!world.mc.part<FakeTerminals>().refuseClose.isEmpty()) answer(world, true);
  });
  step(QStringLiteral("the user is asked 'Close terminal %1\\?' and warned its history is cleared").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap asked = question(world).toMap();
    expect(asked.value(QStringLiteral("title")) == QStringLiteral("Close terminal \"%1\"?").arg(c[0]) &&
               asked.value(QStringLiteral("description")) == QLatin1String("This stops the running process and clears its history.") &&
               asked.value(QStringLiteral("destructive")).toBool(),
           QStringLiteral("the shell asks %1").arg(show(asked)));
    // Nothing stops before the answer.
    const QString terminal = world.mc.part<CloseWorld>().terminal;
    expect(!terminalCall(world, QStringLiteral("terminal.close"), shownThread(world), terminal) && tabLabels(world).contains(c[0]),
           QStringLiteral("the MC got %1; the tabs are %2").arg(describeTerminalCalls(world), tabLabels(world)));
  });
  step(QStringLiteral("its process stops and its history is deleted"), [](World& world, const Captures&, const Table&) {
    const QString terminal = world.mc.part<CloseWorld>().terminal;
    world.waitFor([&] {
      const auto payload = terminalCall(world, QStringLiteral("terminal.close"), shownThread(world), terminal);
      return payload && payload->value(QLatin1String("deleteHistory")).toBool() && terminals(world)->tabs()->indexOf(terminal) < 0;
    }, [&] { return describeRows(world) + QStringLiteral("; the MC got ") + describeTerminalCalls(world); });
    expect(!world.mc.part<FakeTerminals>().terminals.contains(shownThread(world) + QLatin1Char('/') + terminal), QStringLiteral("the MC still runs %1").arg(terminal));
  });
  step(QStringLiteral("the user closes it and declines the confirmation"), [](World& world, const Captures&, const Table&) {
    // The terminal's own chord (terminal.close, mod+w with the keyboard in it).
    world.bridge().dispatch(QStringLiteral("terminal.close"));
    world.sync();
    expect(at(question(world), QStringLiteral("title")).toString().startsWith(QLatin1String("Close terminal")),
           QStringLiteral("the shell asks %1").arg(show(question(world))));
    answer(world, false);
  });
  step(QStringLiteral("\"Terminal (\\d+)\" keeps running with its history"), [](World& world, const Captures& c, const Table&) {
    const QString terminal = QStringLiteral("term-") + c[0];
    const QString threadId = shownThread(world);
    expect(question(world).isNull(), QStringLiteral("the question stays: %1").arg(show(question(world))));
    expect(!terminalCall(world, QStringLiteral("terminal.close"), threadId, terminal) && attached(world.mc).contains(threadId + QLatin1Char('/') + terminal) &&
               terminals(world)->activeTerminalId() == terminal,
           describeRows(world) + QStringLiteral("; the MC got ") + describeTerminalCalls(world));
    expect(terminalSession(world, terminal)->transcript().contains(QLatin1String("listening on 5173")),
           QStringLiteral("%1 shows \"%2\"").arg(terminal, terminalSession(world, terminal)->transcript()));
  });

  step(QStringLiteral("the user closes a split group of three terminals"), [](World& world, const Captures&, const Table&) {
    ensureProject(world);
    ensureThread(world);
    world.waitFor([&] { return terminals(world)->available(); }, QStringLiteral("the thread's terminal drawer"));
    follow(world);
    // A terminal tab of the right panel, split twice.
    world.bridge().dispatch(QStringLiteral("rightPanel.add"), QVariantMap{{QStringLiteral("kind"), QStringLiteral("terminal")}});
    world.waitFor([&] { return rowsIn(world, true).size() == 1; }, [&] { return describeRows(world); });
    for (int count = 2; count <= 3; ++count) {
      world.bridge().dispatch(QStringLiteral("terminal.split"), QVariantMap{{QStringLiteral("terminalId"), rowsIn(world, true).last().terminalId}});
      world.waitFor([&] { return rowsIn(world, true).size() == count; }, [&] { return describeRows(world); });
    }
    world.sync();
    world.bridge().dispatch(QStringLiteral("rightPanel.close"), QVariantMap{{QStringLiteral("id"), at(world.state(QStringLiteral("panel")), QStringLiteral("activeId"))}});
    world.sync();
  });
  step(QStringLiteral("the user is asked once to close 3 terminals, naming each of them"), [](World& world, const Captures&, const Table&) {
    const CloseWorld& close = world.mc.part<CloseWorld>();
    expect(close.questions.size() == 1, QStringLiteral("the shell asked %1 questions").arg(close.questions.size()));
    const QVariantMap asked = question(world).toMap();
    const QString description = asked.value(QStringLiteral("description")).toString();
    expect(asked.value(QStringLiteral("title")) == QLatin1String("Close 3 terminals?"), QStringLiteral("the shell asks %1").arg(show(asked)));
    for (const TerminalTabs::Row& row : rowsIn(world, true)) {
      expect(description.contains(QLatin1Char('"') + row.label + QLatin1Char('"')), QStringLiteral("%1 is not named in \"%2\"").arg(row.label, description));
    }
    expect(rowsIn(world, true).size() == 3, describeRows(world));
    // One yes closes all three, and no second question follows.
    answer(world, true);
    world.waitFor([&] { return rowsIn(world, true).isEmpty(); }, [&] { return describeRows(world); });
    expect(close.questions.size() == 1 && question(world).isNull(), QStringLiteral("the shell asked %1 questions").arg(close.questions.size()));
  });

  step(QStringLiteral("a terminal whose close request fails"), [](World& world, const Captures&, const Table&) {
    openTerminals(world, 2);
    world.mc.part<CloseWorld>().terminal = QStringLiteral("term-2");
    world.mc.part<FakeTerminals>().refuseClose = QStringLiteral("Unknown terminal");
  });
  step(QStringLiteral("the client sends \"exit\" to the shell instead"), [](World& world, const Captures&, const Table&) {
    const QString terminal = world.mc.part<CloseWorld>().terminal;
    world.waitFor([&] { return terminalWrites(world, terminal).contains(QStringLiteral("exit\n")); },
                  [&] { return QStringLiteral("\"exit\" to be written; the MC got %1").arg(describeTerminalCalls(world)); });
    world.sync();
    // And the terminal leaves the drawer without an error.
    expect(terminals(world)->tabs()->indexOf(terminal) < 0 && at(world.state(QStringLiteral("toasts")), QStringLiteral("items")).toList().isEmpty(),
           describeRows(world) + QStringLiteral("; the shell says ") + show(world.state(QStringLiteral("toasts"))));
  });

  step(QStringLiteral("the terminal's shell exits after the user types \"exit\""), [](World& world, const Captures&, const Table&) {
    openTerminals(world, 2);
    const QString threadId = shownThread(world);
    terminalSession(world, QStringLiteral("term-2"))->write(QStringLiteral("exit\r"));
    world.waitFor([&] { return terminalWrites(world, QStringLiteral("term-2")).contains(QStringLiteral("exit\r")); },
                  [&] { return describeTerminalCalls(world); });
    // The shell leaves: the MC says so to whoever is attached.
    sendTerminal(world.mc, threadId + QStringLiteral("/term-2"),
                 {{QStringLiteral("type"), QStringLiteral("exited")}, {QStringLiteral("exitCode"), 0}, {QStringLiteral("exitSignal"), QJsonValue::Null}});
    world.sync();
  });
  step(QStringLiteral("the terminal closes without a confirmation"), [](World& world, const Captures&, const Table&) {
    const QString threadId = shownThread(world);
    world.waitFor([&] {
      const auto payload = terminalCall(world, QStringLiteral("terminal.close"), threadId, QStringLiteral("term-2"));
      return payload && terminals(world)->tabs()->indexOf(QStringLiteral("term-2")) < 0;
    }, [&] { return describeRows(world) + QStringLiteral("; the MC got ") + describeTerminalCalls(world); });
    expect(world.mc.part<CloseWorld>().questions.isEmpty() && question(world).isNull(),
           QStringLiteral("the shell asked %1").arg(show(question(world))));
    expect(tabLabels(world) == QLatin1String("Terminal 1") && terminals(world)->isOpen(), QStringLiteral("the tabs are %1").arg(tabLabels(world)));
  });

  step(QStringLiteral("the user opens a terminal in a folder that no longer exists"), [](World& world, const Captures&, const Table&) {
    ensureProject(world);
    ensureThread(world);
    world.waitFor([&] { return terminals(world)->available(); }, QStringLiteral("the thread's terminal drawer"));
    // The MC's own words for it (apps/server-ex terminal.ex check_cwd).
    world.mc.part<FakeTerminals>().refuseOpen = QStringLiteral("Terminal cwd does not exist: /work/p1");
    world.bridge().dispatch(QStringLiteral("terminal.toggle"));
    world.sync();
  });
  step(QStringLiteral("the user is told the folder does not exist"), [](World& world, const Captures&, const Table&) {
    const auto told = [&] {
      for (const QVariant& item : at(world.state(QStringLiteral("toasts")), QStringLiteral("items")).toList()) {
        if (item.toMap().value(QStringLiteral("title")) == QLatin1String("Unable to open terminal")) return item.toMap().value(QStringLiteral("description")).toString();
      }
      return QString();
    };
    world.waitFor([&] { return told() == QLatin1String("Terminal cwd does not exist: /work/p1"); },
                  [&] { return QStringLiteral("the reason; the shell shows %1").arg(show(world.state(QStringLiteral("toasts")))); });
    expect(rowsIn(world, false).isEmpty() && !terminals(world)->isOpen(), describeRows(world));
  });
  step(QStringLiteral("the rest of the thread keeps working"), [](World& world, const Captures&, const Table&) {
    const QString key = world.native().controller<NavigationController>()->threadKey();
    expect(at(world.state(QStringLiteral("route")), QStringLiteral("kind")) == QLatin1String("thread") && world.state(QStringLiteral("backendError")).toString().isEmpty(),
           QStringLiteral("the window shows %1").arg(show(world.state(QStringLiteral("route")))));
    // The composer still takes the user's words.
    world.bridge().dispatch(QStringLiteral("composer.text.set"),
                            QVariantMap{{QStringLiteral("target"), key}, {QStringLiteral("text"), QStringLiteral("try again")}, {QStringLiteral("cursor"), 9}});
    world.waitFor([&] { return at(world.state(QStringLiteral("composer")), QStringLiteral("text")) == QLatin1String("try again"); },
                  [&] { return QStringLiteral("the composer shows %1").arg(show(world.state(QStringLiteral("composer")))); });
  });

  // Which terminal is active as terminals close and lists arrive
  // (terminal/tabs.feature).
  const auto active = [](World& world, int number) {
    const QString id = QStringLiteral("term-%1").arg(number);
    world.waitFor([&] { return terminals(world)->activeTerminalId() == id; },
                  [&] { return QStringLiteral("%1 active; %2 is. %3").arg(id, terminals(world)->activeTerminalId(), describeRows(world)); });
  };
  step(QStringLiteral("the thread has terminals 1, 2 and 3 with terminal 3 active"), [](World& world, const Captures&, const Table&) {
    openTerminals(world, 3);
  });
  step(QStringLiteral("terminal (\\d) is active"), [active](World& world, const Captures& c, const Table&) {
    world.sync();
    active(world, c[0].toInt());
  });
  step(QStringLiteral("terminal (\\d) is still active"), [active](World& world, const Captures& c, const Table&) {
    world.sync();
    active(world, c[0].toInt());
  });
  step(QStringLiteral("the user closes terminal (\\d)"), [](World& world, const Captures& c, const Table&) {
    world.mc.part<CloseWorld>().groupBefore = terminals(world)->activeGroup();
    world.bridge().dispatch(QStringLiteral("terminal.close"), QVariantMap{{QStringLiteral("terminalId"), QStringLiteral("term-") + c[0]}});
    confirmTerminalClose(world);
    world.sync();
  });
  step(QStringLiteral("its group and place in the row are unchanged"), [](World& world, const Captures&, const Table&) {
    const QList<TerminalTabs::Row> rows = rowsIn(world, false);
    expect(rows.size() == 2 && rows.last().terminalId == QLatin1String("term-3") && rows.last().group == world.mc.part<CloseWorld>().groupBefore &&
               terminals(world)->activeGroup() == world.mc.part<CloseWorld>().groupBefore,
           describeRows(world));
  });

  step(QStringLiteral("the thread has one terminal on its own, a group of two side by side, and a stacked group of three"), [](World& world, const Captures&, const Table&) {
    openTerminals(world, 1);
    const auto add = [&](const char* action, int number) {
      const QString id = QStringLiteral("term-%1").arg(number);
      world.bridge().dispatch(QString::fromLatin1(action), QVariantMap{{QStringLiteral("terminalId"), terminals(world)->activeTerminalId()}});
      world.waitFor([&] { return terminals(world)->activeTerminalId() == id; }, [&] { return describeRows(world); });
    };
    add("terminal.new", 2);
    add("terminal.split", 3);
    add("terminal.new", 4);
    add("terminal.splitVertical", 5);
    add("terminal.splitVertical", 6);
    world.sync();
  });
  step(QStringLiteral("the user looks at the terminal list"), [](World& world, const Captures&, const Table&) {
    drawDrawer(world);
    world.waitFor([&] { return visibleItems(world, QStringLiteral("terminalGroupLabel")).size() == 3; },
                  [&] { return QStringLiteral("three groups; %1 show").arg(visibleItems(world, QStringLiteral("terminalGroupLabel")).size()); });
  });
  step(QStringLiteral("the groups are labelled %1, %1 and %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    const QList<QQuickItem*> labels = visibleItems(world, QStringLiteral("terminalGroupLabel"));
    for (int at = 0; at < 3; ++at) {
      const QString text = labels.at(at)->property("text").toString();
      expect(text.startsWith(c[at]), QStringLiteral("group %1 says \"%2\"").arg(at + 1).arg(text));
    }
  });
  step(QStringLiteral("each label shows how many terminals the group holds"), [](World& world, const Captures&, const Table&) {
    const QList<QQuickItem*> labels = visibleItems(world, QStringLiteral("terminalGroupLabel"));
    for (int at = 0; at < 3; ++at) {
      const QString text = labels.at(at)->property("text").toString();
      expect(text.contains(QStringLiteral("(%1)").arg(at + 1)), QStringLiteral("group %1 says \"%2\"").arg(at + 1).arg(text));
    }
  });
  step(QStringLiteral("choosing a group's label makes that group's terminal active"), [active](World& world, const Captures&, const Table&) {
    QQuickItem* single = visibleItems(world, QStringLiteral("terminalGroupLabel")).first();
    QTest::mouseClick(&world.brick->window(), Qt::LeftButton, Qt::NoModifier, world.brick->at(single));
    active(world, 1);
  });

  step(QStringLiteral("the thread has one terminal"), [](World& world, const Captures&, const Table&) {
    openTerminals(world, 1);
    drawDrawer(world);
  });
  // Above the terminal's right half, never over its first line of output.
  step(QStringLiteral("the terminal offers split, new and close actions above its own corner"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = visibleItems(world, QStringLiteral("HalC2Terminal")).first();
    const QRectF drawn = terminal->mapRectToScene(terminal->boundingRect());
    for (const char* name : {"terminalSplit", "terminalSplitVertical", "terminalNew", "terminalClose"}) {
      QQuickItem* action = world.brick->item(QString::fromLatin1(name));
      const QPointF centre = action->mapToScene(QPointF(action->width() / 2, action->height() / 2));
      const QRectF box = action->mapRectToScene(action->boundingRect());
      expect(action->isVisible() && box.bottom() <= drawn.top() && centre.x() > drawn.center().x() && centre.x() < drawn.right(),
             QStringLiteral("%1 is at %2,%3 over a terminal of %4x%5").arg(QString::fromLatin1(name)).arg(centre.x()).arg(centre.y()).arg(drawn.width()).arg(drawn.height()));
    }
  });
  step(QStringLiteral("no terminal list is shown"), [](World& world, const Captures&, const Table&) {
    expect(!world.brick->item(QStringLiteral("terminalList"))->isVisible(), QStringLiteral("the list shows"));
  });
  step(QStringLiteral("the user opens a second terminal"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("terminal.new"));
    world.waitFor([&] { return terminals(world)->activeTerminalId() == QLatin1String("term-2"); }, [&] { return describeRows(world); });
    world.sync();
  });
  step(QStringLiteral("the terminal list appears beside the terminals with the same actions"), [](World& world, const Captures&, const Table&) {
    QQuickItem* list = world.brick->item(QStringLiteral("terminalList"));
    world.waitFor([&] { return list->isVisible(); }, QStringLiteral("the terminal list"));
    QQuickItem* terminal = visibleItems(world, QStringLiteral("HalC2Terminal")).first();
    const QRectF drawn = terminal->mapRectToScene(terminal->boundingRect());
    expect(drawn.right() <= list->mapRectToScene(list->boundingRect()).left(), QStringLiteral("the terminal runs under the list"));
    for (const char* name : {"terminalSplit", "terminalSplitVertical", "terminalNew", "terminalClose"}) {
      expect(world.brick->item(QString::fromLatin1(name))->isVisible(), QString::fromLatin1(name));
    }
  });

  step(QStringLiteral("the thread has two terminals side by side with the first active"), [active](World& world, const Captures&, const Table&) {
    openTerminals(world, 1);
    world.bridge().dispatch(QStringLiteral("terminal.split"), QVariantMap{{QStringLiteral("terminalId"), QStringLiteral("term-1")}});
    active(world, 2);
    drawDrawer(world);
    world.bridge().dispatch(QStringLiteral("terminal.select"), QVariantMap{{QStringLiteral("terminalId"), QStringLiteral("term-1")}});
    active(world, 1);
    world.sync();
  });
  step(QStringLiteral("the user clicks inside the second terminal"), [](World& world, const Captures&, const Table&) {
    QTest::mouseClick(&world.brick->window(), Qt::LeftButton, Qt::NoModifier, world.brick->at(world.brick->item(QStringLiteral("terminalCell-term-2"))));
    world.sync();
  });
  step(QStringLiteral("the second terminal is active and has the keyboard"), [active](World& world, const Captures&, const Table&) {
    active(world, 2);
    QQuickItem* cell = world.brick->item(QStringLiteral("terminalCell-term-2"));
    world.waitFor([&] { return cell->childItems().size() > 0 && cell->childItems().first()->hasActiveFocus(); }, QStringLiteral("the second terminal to have the keyboard"));
  });
  step(QStringLiteral("closing the active terminal now closes the second terminal"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("terminal.close"));
    confirmTerminalClose(world);
    const QString threadId = shownThread(world);
    world.waitFor([&] { return terminalCall(world, QStringLiteral("terminal.close"), threadId, QStringLiteral("term-2")).has_value(); },
                  [&] { return QStringLiteral("the second terminal to close; the MC got %1").arg(describeTerminalCalls(world)); });
    expect(terminals(world)->tabs()->indexOf(QStringLiteral("term-1")) >= 0, describeRows(world));
  });

  step(QStringLiteral("the thread has terminals 1 and 2"), [](World& world, const Captures&, const Table&) {
    openTerminals(world, 2);
    world.mc.part<FakeTerminals>().holdRemove = true;
  });
  step(QStringLiteral("the MC's list of terminals, sent before the close finished, still includes terminal 1"), [](World& world, const Captures&, const Table&) {
    const QString threadId = shownThread(world);
    expect(terminalCall(world, QStringLiteral("terminal.close"), threadId, QStringLiteral("term-1")).has_value(), describeTerminalCalls(world));
    sendTerminals(world.mc, {{QStringLiteral("type"), QStringLiteral("snapshot")},
                             {QStringLiteral("terminals"), QJsonArray{terminalSummary(threadId, QStringLiteral("term-1"), QStringLiteral("/work")),
                                                                      terminalSummary(threadId, QStringLiteral("term-2"), QStringLiteral("/work"))}}});
    world.sync();
  });
  step(QStringLiteral("terminal 1 does not return to the terminal list"), [](World& world, const Captures&, const Table&) {
    expect(terminals(world)->tabs()->indexOf(QStringLiteral("term-1")) < 0, describeRows(world));
    expect(!attached(world.mc).contains(shownThread(world) + QStringLiteral("/term-1")), QStringLiteral("it attached again"));
  });
  step(QStringLiteral("terminal 1 is opened again later"), [](World& world, const Captures&, const Table&) {
    FakeTerminals& fake = world.mc.part<FakeTerminals>();
    fake.holdRemove = false;
    for (const QJsonObject& remove : std::as_const(fake.heldRemoves)) sendTerminals(world.mc, remove);
    fake.heldRemoves.clear();
    addTerminal(world.mc, shownThread(world), QStringLiteral("term-1"), QString(), false);
    world.sync();
  });
  step(QStringLiteral("terminal 1 appears in the terminal list again"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return terminals(world)->tabs()->indexOf(QStringLiteral("term-1")) >= 0; }, [&] { return describeRows(world); });
  });

  step(QStringLiteral("the user opens a second terminal and the MC's list of terminals still shows only the first"), [active](World& world, const Captures&, const Table&) {
    openTerminals(world, 1);
    const QString threadId = shownThread(world);
    world.mc.part<FakeTerminals>().quietOpen = true;
    world.bridge().dispatch(QStringLiteral("terminal.split"), QVariantMap{{QStringLiteral("terminalId"), QStringLiteral("term-1")}});
    world.waitFor([&] { return terminalAttach(world, threadId, QStringLiteral("term-2")).has_value(); }, [&] { return describeRows(world); });
    sendTerminals(world.mc, {{QStringLiteral("type"), QStringLiteral("snapshot")},
                             {QStringLiteral("terminals"), QJsonArray{terminalSummary(threadId, QStringLiteral("term-1"), QStringLiteral("/work"))}}});
    world.sync();
  });
  step(QStringLiteral("the second terminal stays in the terminal list"), [](World& world, const Captures&, const Table&) {
    expect(terminals(world)->tabs()->indexOf(QStringLiteral("term-2")) >= 0, describeRows(world));
  });
  step(QStringLiteral("it stays in the split group it was opened in"), [](World& world, const Captures&, const Table&) {
    const QList<TerminalTabs::Row> rows = rowsIn(world, false);
    expect(rows.size() == 2 && rows.first().group == rows.last().group && rows.last().span == 2, describeRows(world));
  });

  // Terminals that do not start (terminal/errors.feature): nothing is left behind.
  const auto refuse = [](World& world) {
    world.mc.part<FakeTerminals>().refuseOpen = QStringLiteral("Terminal limit reached on this machine");
  };
  step(QStringLiteral("the thread has no terminals"), [](World& world, const Captures&, const Table&) {
    ensureProject(world);
    ensureThread(world);
    world.waitFor([&] { return terminals(world)->available(); }, QStringLiteral("the thread's terminal drawer"));
    expect(rowsIn(world, false).isEmpty(), describeRows(world));
  });
  step(QStringLiteral("the MC refuses to open the terminal"), [refuse](World& world, const Captures&, const Table&) { refuse(world); });
  step(QStringLiteral("the MC refuses to open another terminal"), [refuse](World& world, const Captures&, const Table&) { refuse(world); });
  step(QStringLiteral("the MC refuses to open it again"), [refuse](World& world, const Captures&, const Table&) { refuse(world); });
  step(QStringLiteral("the drawer does not stay open with a dead terminal"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !terminals(world)->isOpen() && rowsIn(world, false).isEmpty() && toastShown(world, QStringLiteral("Unable to open terminal")); },
                  [&] { return describeRows(world) + QStringLiteral("; the shell shows ") + show(world.state(QStringLiteral("toasts"))); });
  });
  step(QStringLiteral("the user shows the terminal again and the MC accepts"), [](World& world, const Captures&, const Table&) {
    world.mc.part<FakeTerminals>().refuseOpen.clear();
    world.bridge().dispatch(QStringLiteral("terminal.toggle"));
    world.sync();
  });
  step(QStringLiteral("the terminal opens and the drawer shows it"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return terminals(world)->isOpen() && rowsIn(world, false).size() == 1 && world.mc.part<FakeTerminals>().terminals.size() == 1; },
                  [&] { return describeRows(world); });
  });

  step(QStringLiteral("the thread has one running terminal that is active"), [](World& world, const Captures&, const Table&) {
    openTerminals(world, 1);
    // A script would rather not type into a busy one.
    addTerminal(world.mc, shownThread(world), QStringLiteral("term-1"), QString(), true);
    world.sync();
  });
  step(QStringLiteral("the user splits the terminal (side by side|stacked)"), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(c[0] == QLatin1String("stacked") ? QStringLiteral("terminal.splitVertical") : QStringLiteral("terminal.split"),
                            QVariantMap{{QStringLiteral("terminalId"), QStringLiteral("term-1")}});
    world.sync();
  });
  const auto runScript = [](World& world) {
    addAction(world, QStringLiteral("p1"), QStringLiteral("Dev"), QStringLiteral("bun dev"));
    world.bridge().dispatch(QStringLiteral("workspace.runScript"), QVariantMap{{QStringLiteral("scriptId"), QStringLiteral("dev")}});
    world.sync();
  };
  step(QStringLiteral("the user runs a project script that wants a new terminal"), [runScript](World& world, const Captures&, const Table&) { runScript(world); });
  step(QStringLiteral("a project script's terminal is already known to the thread"), [](World& world, const Captures&, const Table&) { openTerminals(world, 1); });
  step(QStringLiteral("the user runs the script"), [runScript](World& world, const Captures&, const Table&) { runScript(world); });
  const auto toldItFailed = [](World& world) {
    return toastShown(world, QStringLiteral("Unable to open terminal")) || toastShown(world, QStringLiteral("Failed to run script \"Dev\"."));
  };
  step(QStringLiteral("the thread still has only its first terminal and it is still active"), [toldItFailed](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      const QList<TerminalTabs::Row> rows = rowsIn(world, false);
      return toldItFailed(world) && rows.size() == 1 && rows.first().terminalId == QLatin1String("term-1") && rows.first().span == 1 &&
             terminals(world)->activeTerminalId() == QLatin1String("term-1");
    }, [&] { return describeRows(world) + QStringLiteral("; the shell shows ") + show(world.state(QStringLiteral("toasts"))); });
  });
  step(QStringLiteral("nothing is typed into any terminal"), [](World& world, const Captures&, const Table&) {
    for (const QJsonObject& call : world.mc.part<FakeTerminals>().calls) {
      expect(call.value(QLatin1String("method")) != QLatin1String("terminal.write"), describeTerminalCalls(world));
    }
  });
  step(QStringLiteral("the terminal stays in the thread"), [toldItFailed](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return toldItFailed(world) && rowsIn(world, false).size() == 1 && terminals(world)->tabs()->indexOf(QStringLiteral("term-1")) >= 0; },
                  [&] { return describeRows(world) + QStringLiteral("; the shell shows ") + show(world.state(QStringLiteral("toasts"))); });
  });
  step(QStringLiteral("the script's command is not typed"), [](World& world, const Captures&, const Table&) {
    expect(!terminalWrites(world, QStringLiteral("term-1")).join(QString()).contains(QLatin1String("bun dev")), describeTerminalCalls(world));
  });

  step(QStringLiteral("a terminal that has printed more than 512 KiB since the client attached"), [](World& world, const Captures&, const Table&) {
    openTerminals(world, 1);
    CloseWorld& close = world.mc.part<CloseWorld>();
    const QString threadId = shownThread(world);
    // 600 KiB, a numbered 8 KiB line at a time.
    for (int n = 0; n < 75; ++n) {
      const QString chunk = QStringLiteral("line-%1 ").arg(n, 4, 10, QLatin1Char('0')) + QString(8192 - 11, QLatin1Char('x')) + QStringLiteral("\r\n");
      if (n == 0) close.firstChunk = chunk.left(9);
      close.lastChunk = chunk.left(9);
      close.printed += int(chunk.size());
      // A client that reads as it goes: the MC would hold the rest back.
      const FakeTerminals::Window* window = terminalWindow(world.mc, threadId + QStringLiteral("/term-1"));
      world.waitFor([&] { return window->bytes < FakeTerminals::kWindowLimit - chunk.size(); }, QStringLiteral("the client to say what it has read"));
      print(world.mc, threadId, QStringLiteral("term-1"), chunk);
    }
    world.sync();
  });
  step(QStringLiteral("the client keeps the newest 512 KiB"), [](World& world, const Captures&, const Table&) {
    const CloseWorld& close = world.mc.part<CloseWorld>();
    const QString transcript = terminalSession(world, QStringLiteral("term-1"))->transcript();
    expect(close.printed > 512 * 1024, QStringLiteral("only %1 bytes were printed").arg(close.printed));
    expect(transcript.size() <= 512 * 1024 && transcript.size() > 512 * 1024 - 8192,
           QStringLiteral("the client keeps %1 bytes of %2").arg(transcript.size()).arg(close.printed));
    expect(transcript.contains(close.lastChunk) && !transcript.contains(close.firstChunk) && transcript.endsWith(QLatin1String("x\r\n")),
           QStringLiteral("the client keeps other output than the newest"));
  });
});

}  // namespace
