// How the desktop's terminals end and fail (features/terminal/tabs.feature,
// io.feature, errors.feature, reconnect.feature): the question a close asks,
// a shell that leaves on its own, a close the MC cannot do, a terminal that
// does not open, and how much output the client keeps.

#include <QJsonObject>

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
  step(QStringLiteral("the terminal says the folder does not exist"), [](World& world, const Captures&, const Table&) {
    TerminalSession* session = terminalSession(world, QStringLiteral("term-1"));
    world.waitFor([&] { return session->transcript().contains(QLatin1String("[Terminal cwd does not exist: /work/p1]")); },
                  [&] { return QStringLiteral("the terminal to say why; it shows \"%1\"").arg(session->transcript()); });
    // The drawer draws it where the shell would have been.
    Brick drawer(world, "import QtQuick\nimport HalC2.Bricks\nItem { TerminalDrawer { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom } }\n",
                 QSize(900, 700));
    QQuickItem* terminal = drawer.item(QStringLiteral("HalC2Terminal"));
    QString text;
    QMetaObject::invokeMethod(terminal, "text", Q_RETURN_ARG(QString, text));
    expect(text.contains(QLatin1String("Terminal cwd does not exist: /work/p1")), QStringLiteral("the drawer draws \"%1\"").arg(text));
  });
  step(QStringLiteral("the rest of the thread keeps working"), [](World& world, const Captures&, const Table&) {
    const QString key = world.native().controller<NavigationController>()->threadKey();
    expect(at(world.state(QStringLiteral("route")), QStringLiteral("kind")) == QLatin1String("thread") && world.state(QStringLiteral("backendError")).toString().isEmpty(),
           QStringLiteral("the window shows %1").arg(show(world.state(QStringLiteral("route")))));
    // The composer still takes the user's words, and the drawer still hides.
    world.bridge().dispatch(QStringLiteral("composer.text.set"),
                            QVariantMap{{QStringLiteral("target"), key}, {QStringLiteral("text"), QStringLiteral("try again")}, {QStringLiteral("cursor"), 9}});
    world.waitFor([&] { return at(world.state(QStringLiteral("composer")), QStringLiteral("text")) == QLatin1String("try again"); },
                  [&] { return QStringLiteral("the composer shows %1").arg(show(world.state(QStringLiteral("composer")))); });
    world.bridge().dispatch(QStringLiteral("terminal.toggle"));
    world.waitFor([&] { return !terminals(world)->isOpen(); }, QStringLiteral("the terminal drawer to hide"));
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
