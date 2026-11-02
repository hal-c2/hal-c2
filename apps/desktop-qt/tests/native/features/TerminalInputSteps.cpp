// How the desktop's terminal feels to type, select and scroll in
// (features/terminal/io.feature), and what hiding it costs
// (features/terminal/sessions.feature). Driven on the bricks with the mouse,
// wheel and keys the user has; the keys themselves are in TerminalMenuSteps.cpp.

#include <QCoreApplication>
#include <QFont>
#include <QFontMetricsF>
#include <QGlyphRun>
#include <QGuiApplication>
#include <QInputMethodEvent>
#include <QPointer>
#include <QQuickItem>
#include <QQuickWindow>
#include <QRawFont>
#include <QStyleHints>
#include <QTest>
#include <QTextLayout>
#include <QWheelEvent>

#include <cmath>
#include <memory>

#include "Brick.h"
#include "FakeTerminals.h"
#include "Harness.h"
#include "SettingsController.h"
#include "TerminalController.h"
#include "World.h"

namespace {

using namespace terminalfake;

const QString kTerminal = QStringLiteral("term-1");

struct InputWorld {
  // Frames the window has begun since the counter was connected.
  std::shared_ptr<int> frames;
  // Hidden, the terminal has no window to be found through.
  QPointer<QQuickItem> terminal;
  double scrollBefore = 0;
  int expectedOffset = 0;
  double wheelPixels = 0;
  // The line a held drag began on.
  QString draggedFrom;
  double promptY = 0;
  int resizeCalls = 0;
  QImage drawn;
};

TerminalController* terminals(World& world) {
  return world.native().controller<TerminalController>();
}

void printToShell(World& world, const QString& data) {
  print(world.mc, shownThread(world), kTerminal, data);
  world.sync();
}

QString call(QQuickItem* terminal, const char* method) {
  QString text;
  QMetaObject::invokeMethod(terminal, method, Q_RETURN_ARG(QString, text));
  return text;
}

double number(QQuickItem* item, const char* name) {
  return item->property(name).toDouble();
}

void scrollViewTo(QQuickItem* terminal, double offset) {
  QMetaObject::invokeMethod(terminal, "scrollTo", Q_ARG(qreal, offset));
}

QString writes(World& world) {
  return terminalWrites(world, kTerminal).join(QString());
}

// The middle of a cell of the screen, in window coordinates.
QPoint cellPoint(World& world, QQuickItem* terminal, int column, int row) {
  const QPoint origin = world.brick->at(terminal, 0, 0);
  const double padding = number(terminal, "padding");
  return origin + QPoint(int(padding + number(terminal, "cellWidth") * (column + 0.5)), int(padding + number(terminal, "cellHeight") * (row + 0.5)));
}

void drag(World& world, const QPoint& from, const QPoint& to, Qt::KeyboardModifiers modifiers = Qt::NoModifier) {
  QTest::mousePress(&world.brick->window(), Qt::LeftButton, modifiers, from);
  for (int step = 1; step <= 4; ++step) QTest::mouseMove(&world.brick->window(), from + (to - from) * step / 4);
  QTest::mouseRelease(&world.brick->window(), Qt::LeftButton, modifiers, to);
  world.sync();
}

void wheel(World& world, QQuickItem* terminal, const QPoint& pixels, const QPoint& angle) {
  const QPointF at = world.brick->at(terminal);
  QWheelEvent event(at, world.brick->window().mapToGlobal(at), pixels, angle, Qt::NoButton, Qt::NoModifier, Qt::NoScrollPhase, false);
  QCoreApplication::sendEvent(&world.brick->window(), &event);
  world.sync();
}

QQuickItem* terminalWithHistory(World& world, int lines = 300) {
  QQuickItem* terminal = drawnTerminal(world);
  QString output;
  for (int line = 0; line < lines; ++line) output += QStringLiteral("line %1\r\n").arg(line);
  printToShell(world, output);
  world.waitFor([&] { return number(terminal, "scrollTotal") > number(terminal, "rows") + lines / 4; },
                [&] { return QStringLiteral("history; the terminal has %1 rows").arg(number(terminal, "scrollTotal")); });
  return terminal;
}

void askForMouse(World& world) {
  QQuickItem* terminal = drawnTerminal(world);
  printToShell(world, QStringLiteral("\x1b[?1002h\x1b[?1006h"));
  world.waitFor([&] { return terminal->property("mouseTracking").toBool(); }, QStringLiteral("the Terminal to hand the mouse to the program"));
}

int differingPixels(const QImage& image, const QRect& area, QRgb from) {
  int count = 0;
  for (int y = area.top(); y <= area.bottom(); ++y) {
    for (int x = area.left(); x <= area.right(); ++x) {
      if (image.pixel(x, y) != from) ++count;
    }
  }
  return count;
}

QColor backgroundOf(QQuickItem* terminal) {
  return terminal->property("backgroundColor").value<QColor>();
}

QRect screenArea(World& world, QQuickItem* terminal) {
  const QPoint origin = world.brick->at(terminal, 0, 0);
  return QRect(origin, QSize(int(terminal->width()), int(terminal->height()))).adjusted(0, 0, -10, -1);
}

// The cursor's cell on a screen that printed the drawn terminal's two lines.
QRect cursorCell(World& world, QQuickItem* terminal) {
  const QPoint middle = cellPoint(world, terminal, 0, 2);
  const int width = int(number(terminal, "cellWidth"));
  const int height = int(number(terminal, "cellHeight"));
  return QRect(middle.x() - width / 2, middle.y() - height / 2, width, height);
}

// The rows the wheel's pixels add up to. A sum landing exactly on a row may
// round to just under it, and that row then comes with the next movement.
void expectRows(QQuickItem* terminal, const InputWorld& input) {
  const double cell = number(terminal, "cellHeight");
  const double rows = input.scrollBefore - number(terminal, "scrollOffset");
  expect(rows >= std::floor((input.wheelPixels - 1) / cell) && rows <= std::floor(input.wheelPixels / cell),
         QStringLiteral("%1 pixels of rows %2 tall moved %3 rows").arg(input.wheelPixels).arg(cell).arg(rows));
}

const Steps steps([] {
  Brick::registerSingletons();
  const QString q = kQuoted;

  // Keys that reach the shell through the terminal's chords.
  step(QStringLiteral("the shell prompt holds %1").arg(q), [](World& world, const Captures& c, const Table&) {
    drawnTerminal(world);
    printToShell(world, QStringLiteral("$ ") + c[0]);
  });
  step(QStringLiteral("the shell receives the command that deletes to the start of the line"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return terminalWrites(world, kTerminal).contains(QStringLiteral("\x15")); },
                  [&] { return QStringLiteral("Ctrl-U to be written; the MC got %1").arg(describeTerminalCalls(world)); });
  });
  step(QStringLiteral("the terminal's cursor moves (one word left|one word right|to the start of the line|to the end of the line)"), [](World& world, const Captures& c, const Table&) {
    const QString expected = c[0] == QLatin1String("one word left") ? QStringLiteral("\x1b" "b")
                             : c[0] == QLatin1String("one word right") ? QStringLiteral("\x1b" "f")
                             : c[0] == QLatin1String("to the start of the line") ? QStringLiteral("\x01") : QStringLiteral("\x05");
    world.waitFor([&] { return terminalWrites(world, kTerminal).contains(expected); },
                  [&] { return QStringLiteral("the movement to be written; the MC got %1").arg(describeTerminalCalls(world)); });
  });
  step(QStringLiteral("the shell receives the key as the terminal encodes it"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return writes(world).contains(QLatin1String("\x1b[1;4D")); },
                  [&] { return QStringLiteral("Shift+Alt+Left as CSI 1;4 D; the MC got %1").arg(describeTerminalCalls(world)); });
  });
  step(QStringLiteral("no word or line movement is sent"), [](World& world, const Captures&, const Table&) {
    const QStringList sent = terminalWrites(world, kTerminal);
    for (const QString& movement : {QStringLiteral("\x1b" "b"), QStringLiteral("\x1b" "f"), QStringLiteral("\x01"), QStringLiteral("\x05")}) {
      expect(!sent.contains(movement), QStringLiteral("the MC got %1").arg(describeTerminalCalls(world)));
    }
  });

  // Selecting with the mouse.
  step(QStringLiteral("the shell has printed %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    printToShell(world, c[0] + QStringLiteral("\r\n"));
    world.waitFor([&] { return call(terminal, "text").contains(c[0]); }, QStringLiteral("the line on screen"));
  });
  step(QStringLiteral("the user clicks (twice|3 times) in quick succession on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* terminal = world.brick->item(QStringLiteral("HalC2Terminal"));
    const QPoint at = cellPoint(world, terminal, QStringLiteral("git commit -m fix").indexOf(c[1]) + 1, 2);
    // However long a busy machine takes between them.
    QGuiApplication::styleHints()->setMouseDoubleClickInterval(60000);
    QTest::mouseDClick(&world.brick->window(), Qt::LeftButton, Qt::NoModifier, at);
    if (c[0] != QLatin1String("twice")) QTest::mouseClick(&world.brick->window(), Qt::LeftButton, Qt::NoModifier, at);
    QGuiApplication::styleHints()->setMouseDoubleClickInterval(-1);
    world.sync();
  });
  step(QStringLiteral("the terminal has scrolled-back output"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = terminalWithHistory(world);
    scrollViewTo(terminal, int((number(terminal, "scrollTotal") - number(terminal, "rows")) / 2));
    world.mc.part<InputWorld>().scrollBefore = number(terminal, "scrollOffset");
  });
  step(QStringLiteral("the user drags a selection past the top of the terminal and holds it there"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    QQuickWindow& window = world.brick->window();
    const QPoint end = cellPoint(world, terminal, 30, 3);
    const QPoint start(world.brick->at(terminal, 0, 0).x() + int(number(terminal, "padding")) + 1, end.y());
    QTest::mousePress(&window, Qt::LeftButton, Qt::NoModifier, end);
    QTest::mouseMove(&window, start);
    world.sync();
    // Backwards over the whole of a line, so it is the selection's last.
    world.mc.part<InputWorld>().draggedFrom = call(terminal, "selectedText").trimmed();
    expect(world.mc.part<InputWorld>().draggedFrom.startsWith(QLatin1String("line ")),
           QStringLiteral("the drag selected \"%1\"").arg(world.mc.part<InputWorld>().draggedFrom));
    const QPoint above(start.x(), world.brick->at(terminal, 0, 0).y() - 8);
    expect(above.y() >= 0, QStringLiteral("the terminal has no room above it"));
    QTest::mouseMove(&window, above);
  });
  step(QStringLiteral("the history keeps scrolling up"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    // More rows than any one move scrolls, with the pointer held still.
    const double target = world.mc.part<InputWorld>().scrollBefore - 5;
    world.waitFor([&] { return number(terminal, "scrollOffset") <= target; },
                  [&] { return QStringLiteral("the view to keep scrolling; it is at %1 of %2").arg(number(terminal, "scrollOffset")).arg(world.mc.part<InputWorld>().scrollBefore); });
  });
  step(QStringLiteral("the selection grows with it"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    const QStringList lines = call(terminal, "selectedText").split(QLatin1Char('\n'), Qt::SkipEmptyParts);
    QTest::mouseRelease(&world.brick->window(), Qt::LeftButton, Qt::NoModifier, QPoint(world.brick->at(terminal, 0, 0).x(), 0));
    // It still ends on the text it began on, and takes in the older lines.
    expect(lines.size() > 3 && lines.last().trimmed() == world.mc.part<InputWorld>().draggedFrom,
           QStringLiteral("the selection from \"%1\" is %2").arg(world.mc.part<InputWorld>().draggedFrom, lines.join(QLatin1Char('|'))));
  });
  step(QStringLiteral("%1 is selected in the terminal").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* terminal = world.brick->item(QStringLiteral("HalC2Terminal"));
    world.waitFor([&] { return call(terminal, "selectedText") == c[0]; }, [&] { return QStringLiteral("\"%1\" is selected").arg(call(terminal, "selectedText")); });
  });

  // A middle click where the button pastes nothing.
  step(QStringLiteral("the user middle-clicks the terminal"), [](World& world, const Captures&, const Table&) {
    QTest::mouseClick(&world.brick->window(), Qt::MiddleButton, Qt::NoModifier, world.brick->at(drawnTerminal(world)));
    world.sync();
  });
  step(QStringLiteral("nothing is sent to the shell"), [](World& world, const Captures&, const Table&) {
    expect(terminalWrites(world, kTerminal).isEmpty(), QStringLiteral("the MC got %1").arg(describeTerminalCalls(world)));
  });

  // Programs that take the mouse.
  step(QStringLiteral("a program in the terminal has asked to receive mouse events"), [](World& world, const Captures&, const Table&) {
    askForMouse(world);
  });
  step(QStringLiteral("the user clicks and drags in the terminal"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    drag(world, cellPoint(world, terminal, 1, 0), cellPoint(world, terminal, 6, 0));
  });
  step(QStringLiteral("the program receives the presses, motion and releases"), [](World& world, const Captures&, const Table&) {
    const QString sent = writes(world);
    expect(sent.contains(QLatin1String("\x1b[<0;2;1M")), QStringLiteral("no press: %1").arg(describeTerminalCalls(world)));
    expect(sent.contains(QLatin1String("\x1b[<32;")), QStringLiteral("no motion: %1").arg(describeTerminalCalls(world)));
    expect(sent.contains(QLatin1String("\x1b[<0;7;1m")), QStringLiteral("no release: %1").arg(describeTerminalCalls(world)));
  });
  step(QStringLiteral("no text is selected"), [](World& world, const Captures&, const Table&) {
    expect(!drawnTerminal(world)->property("hasSelection").toBool(), QStringLiteral("the terminal has a selection"));
  });
  step(QStringLiteral("the user drags in the terminal holding (Shift|Ctrl|Cmd)"), [](World& world, const Captures& c, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    // As Qt reports them off macOS, where Cmd is Meta.
    const Qt::KeyboardModifier modifier = c[0] == QLatin1String("Shift") ? Qt::ShiftModifier : c[0] == QLatin1String("Ctrl") ? Qt::ControlModifier : Qt::MetaModifier;
    drag(world, cellPoint(world, terminal, 0, 0), cellPoint(world, terminal, 6, 0), modifier);
  });
  step(QStringLiteral("the text is selected"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    world.waitFor([&] { return call(terminal, "selectedText").startsWith(QLatin1String("FAIL")); },
                  [&] { return QStringLiteral("the text selected; \"%1\" is").arg(call(terminal, "selectedText")); });
  });
  step(QStringLiteral("the program receives nothing"), [](World& world, const Captures&, const Table&) {
    expect(terminalWrites(world, kTerminal).isEmpty(), QStringLiteral("the MC got %1").arg(describeTerminalCalls(world)));
  });
  step(QStringLiteral("the user scrolls the wheel"), [](World& world, const Captures&, const Table&) {
    wheel(world, drawnTerminal(world), QPoint(), QPoint(0, 120));
  });
  step(QStringLiteral("the program receives wheel events"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return writes(world).contains(QLatin1String("\x1b[<64;")); }, [&] { return QStringLiteral("wheel presses; the MC got %1").arg(describeTerminalCalls(world)); });
  });

  // The wheel.
  step(QStringLiteral("a full-screen program such as an editor or pager is showing"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = terminalWithHistory(world);
    printToShell(world, QStringLiteral("\x1b[?1049h"));
    world.mc.part<InputWorld>().scrollBefore = number(terminal, "scrollOffset");
  });
  step(QStringLiteral("the user scrolls the wheel down three rows"), [](World& world, const Captures&, const Table&) {
    wheel(world, drawnTerminal(world), QPoint(), QPoint(0, -120));
  });
  step(QStringLiteral("the shell receives three down-arrow keys"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return writes(world) == QLatin1String("\x1b[B\x1b[B\x1b[B"); }, [&] { return QStringLiteral("three down-arrows; the MC got %1").arg(describeTerminalCalls(world)); });
  });
  step(QStringLiteral("the terminal's own history does not scroll"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    expect(number(terminal, "scrollOffset") == world.mc.part<InputWorld>().scrollBefore, QStringLiteral("the view moved to %1").arg(number(terminal, "scrollOffset")));
  });
  step(QStringLiteral("the terminal has history above what is on screen"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = terminalWithHistory(world);
    world.mc.part<InputWorld>().scrollBefore = number(terminal, "scrollOffset");
  });
  step(QStringLiteral("the user scrolls with a trackpad in many movements each smaller than a row"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    InputWorld& input = world.mc.part<InputWorld>();
    const double cell = number(terminal, "cellHeight");
    const int movement = qMax(1, int(cell / 3));
    for (int count = 1; count <= 20; ++count) {
      wheel(world, terminal, QPoint(0, movement), QPoint());
      input.wheelPixels += movement;
      expectRows(terminal, input);
    }
  });
  step(QStringLiteral("the terminal scrolls one row each time the movements add up to a row"), [](World& world, const Captures&, const Table&) {
    expect(number(drawnTerminal(world), "scrollOffset") < world.mc.part<InputWorld>().scrollBefore, QStringLiteral("the view did not move"));
  });
  step(QStringLiteral("no movement is lost"), [](World& world, const Captures&, const Table&) {
    expectRows(drawnTerminal(world), world.mc.part<InputWorld>());
  });
  step(QStringLiteral("the wheel reports three lines"), [](World& world, const Captures&, const Table&) {
    wheel(world, drawnTerminal(world), QPoint(), QPoint(0, 120));
  });
  step(QStringLiteral("the terminal scrolls three rows"), [](World& world, const Captures&, const Table&) {
    const double moved = world.mc.part<InputWorld>().scrollBefore - number(drawnTerminal(world), "scrollOffset");
    expect(moved == 3, QStringLiteral("it moved %1 rows").arg(moved));
  });
  step(QStringLiteral("the wheel reports pixels"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    wheel(world, terminal, QPoint(0, int(number(terminal, "cellHeight") * 2.5)), QPoint());
  });
  step(QStringLiteral("the terminal scrolls by that many pixels, rounded down to rows"), [](World& world, const Captures&, const Table&) {
    const double moved = world.mc.part<InputWorld>().scrollBefore - number(drawnTerminal(world), "scrollOffset");
    expect(moved == 2, QStringLiteral("2.5 rows of pixels moved %1 rows").arg(moved));
  });

  // The scrollbar.
  step(QStringLiteral("the terminal has more output than fits on screen"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = terminalWithHistory(world);
    terminal->forceActiveFocus();
    // In the middle of the history, so every gesture has somewhere to go.
    const int middle = int((number(terminal, "scrollTotal") - number(terminal, "rows")) / 2);
    scrollViewTo(terminal, middle);
    world.mc.part<InputWorld>().scrollBefore = number(terminal, "scrollOffset");
    expect(number(terminal, "scrollOffset") == middle, QStringLiteral("the view is at %1").arg(number(terminal, "scrollOffset")));
  });
  step(QStringLiteral("a scrollbar shows where the view sits in the history"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    QQuickItem* bar = world.brick->item(QStringLiteral("terminalScrollbar"));
    QQuickItem* thumb = world.brick->item(QStringLiteral("terminalScrollbarThumb"));
    expect(bar->isVisible(), QStringLiteral("no scrollbar"));
    scrollViewTo(terminal, 0);
    expect(thumb->y() == 0, QStringLiteral("at the oldest output the thumb is at %1").arg(thumb->y()));
    QMetaObject::invokeMethod(terminal, "scrollToBottom");
    expect(std::abs(thumb->y() + thumb->height() - bar->height()) < 1, QStringLiteral("at the newest output the thumb ends at %1 of %2").arg(thumb->y() + thumb->height()).arg(bar->height()));
  });
  step(QStringLiteral("the scrollbar is hidden while everything fits"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    QMetaObject::invokeMethod(terminal, "reset");
    QQuickItem* bar = world.brick->item(QStringLiteral("terminalScrollbar"));
    world.waitFor([&] { return !bar->isVisible(); }, QStringLiteral("the scrollbar to hide"));
  });
  step(QStringLiteral("the user drags the scrollbar's thumb"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    QQuickItem* bar = world.brick->item(QStringLiteral("terminalScrollbar"));
    QQuickItem* thumb = world.brick->item(QStringLiteral("terminalScrollbarThumb"));
    const double maxOffset = number(terminal, "scrollTotal") - number(terminal, "rows");
    const double travel = bar->height() - thumb->height();
    const double startTop = thumb->y();
    const QPoint from = world.brick->at(thumb);
    QTest::mousePress(&world.brick->window(), Qt::LeftButton, Qt::NoModifier, from);
    for (int moved = -10; moved >= -30; moved -= 10) {
      QTest::mouseMove(&world.brick->window(), from + QPoint(0, moved));
      const int expected = int(std::lround((startTop + moved) / travel * maxOffset));
      expect(std::abs(number(terminal, "scrollOffset") - expected) <= 1, QStringLiteral("%1 pixels up the view is at %2, not %3").arg(-moved).arg(number(terminal, "scrollOffset")).arg(expected));
      world.mc.part<InputWorld>().expectedOffset = expected;
    }
    QTest::mouseRelease(&world.brick->window(), Qt::LeftButton, Qt::NoModifier, from + QPoint(0, -30));
    world.sync();
  });
  step(QStringLiteral("the view follows the thumb row for row"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    const int expected = world.mc.part<InputWorld>().expectedOffset;
    expect(std::abs(number(terminal, "scrollOffset") - expected) <= 1 && number(terminal, "scrollOffset") < world.mc.part<InputWorld>().scrollBefore,
           QStringLiteral("the view is at %1, not %2").arg(number(terminal, "scrollOffset")).arg(expected));
    expect(terminal->hasActiveFocus(), QStringLiteral("the terminal lost the keyboard"));
  });
  step(QStringLiteral("the user clicks the scrollbar's track"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    QQuickItem* bar = world.brick->item(QStringLiteral("terminalScrollbar"));
    QQuickItem* thumb = world.brick->item(QStringLiteral("terminalScrollbarThumb"));
    const int y = int(thumb->height() / 2) + 3;
    world.mc.part<InputWorld>().expectedOffset =
        int(std::lround(3 / (bar->height() - thumb->height()) * (number(terminal, "scrollTotal") - number(terminal, "rows"))));
    QTest::mouseClick(&world.brick->window(), Qt::LeftButton, Qt::NoModifier, world.brick->at(bar, 0.5, double(y) / bar->height()));
    world.sync();
  });
  step(QStringLiteral("the view jumps to that place in the history"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    const int expected = world.mc.part<InputWorld>().expectedOffset;
    expect(std::abs(number(terminal, "scrollOffset") - expected) <= 1, QStringLiteral("the view is at %1, not %2").arg(number(terminal, "scrollOffset")).arg(expected));
  });
  step(QStringLiteral("the user presses (Page Up|Page Down|Home|End|an arrow key) on the scrollbar"), [](World& world, const Captures& c, const Table&) {
    drawnTerminal(world);
    QQuickItem* bar = world.brick->item(QStringLiteral("terminalScrollbar"));
    bar->forceActiveFocus();
    world.waitFor([&] { return bar->hasActiveFocus(); }, QStringLiteral("the scrollbar to take the keyboard"));
    const Qt::Key key = c[0] == QLatin1String("Page Up") ? Qt::Key_PageUp : c[0] == QLatin1String("Page Down") ? Qt::Key_PageDown
                        : c[0] == QLatin1String("Home") ? Qt::Key_Home : c[0] == QLatin1String("End") ? Qt::Key_End : Qt::Key_Up;
    QTest::keyClick(&world.brick->window(), key);
    world.sync();
  });
  step(QStringLiteral("the view (moves up a screenful|moves down a screenful|moves to the oldest output|moves to the newest output|moves one row)"), [](World& world, const Captures& c, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    const double before = world.mc.part<InputWorld>().scrollBefore;
    const double rows = number(terminal, "rows");
    const double expected = c[0] == QLatin1String("moves up a screenful") ? before - rows
                            : c[0] == QLatin1String("moves down a screenful") ? before + rows
                            : c[0] == QLatin1String("moves to the oldest output") ? 0
                            : c[0] == QLatin1String("moves to the newest output") ? number(terminal, "scrollTotal") - rows : before - 1;
    expect(number(terminal, "scrollOffset") == expected, QStringLiteral("the view is at %1, not %2").arg(number(terminal, "scrollOffset")).arg(expected));
    expect(writes(world).isEmpty(), QStringLiteral("the shell got %1").arg(describeTerminalCalls(world)));
  });
  step(QStringLiteral("the terminal has a very long history"), [](World& world, const Captures&, const Table&) {
    terminalWithHistory(world, 2000);
  });
  step(QStringLiteral("the scrollbar's thumb is never smaller than a small grab target"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    QQuickItem* bar = world.brick->item(QStringLiteral("terminalScrollbar"));
    QQuickItem* thumb = world.brick->item(QStringLiteral("terminalScrollbarThumb"));
    const double proportional = bar->height() * number(terminal, "rows") / number(terminal, "scrollTotal");
    expect(proportional < 18, QStringLiteral("the history is too short to show it: %1").arg(proportional));
    expect(thumb->height() >= 18, QStringLiteral("the thumb is %1 tall").arg(thumb->height()));
  });

  // The prompt on the bottom edge.
  step(QStringLiteral("the terminal has history and its height is not a whole number of rows"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = terminalWithHistory(world);
    // One pixel over a whole number of rows, wherever the drawer's height left it.
    const double cell = number(terminal, "cellHeight");
    const int rows = int(number(terminal, "rows"));
    const int height = terminals(world)->height() + 1 + int(rows * cell + 2 * number(terminal, "padding") - terminal->height());
    world.bridge().dispatch(QStringLiteral("terminal.resize"), QVariantMap{{QStringLiteral("height"), height}});
    world.waitFor([&] { return terminals(world)->height() == height; }, QStringLiteral("the terminal to take its height"));
    world.sync();
  });
  step(QStringLiteral("the leftover space is above the first row and not below the prompt"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    QQuickItem* drawer = world.brick->item(QStringLiteral("drawer"));
    const double padding = number(terminal, "padding");
    expect(terminal->parentItem()->y() > 0, QStringLiteral("no space is left over above the first row"));
    const auto promptBottom = [&] {
      return terminal->mapToScene(QPointF(0, padding + number(terminal, "rows") * number(terminal, "cellHeight"))).y();
    };
    const double edge = drawer->mapToScene(QPointF(0, drawer->height())).y();
    world.waitFor([&] { const double below = edge - padding - promptBottom(); return below >= 0 && below < 1; },
                  [&] { return QStringLiteral("the prompt ends %1 pixels above the padding").arg(edge - padding - promptBottom()); });
    world.mc.part<InputWorld>().promptY = promptBottom();
  });
  step(QStringLiteral("the prompt does not shift while the user drags a selection across rows"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    const double padding = number(terminal, "padding");
    drag(world, cellPoint(world, terminal, 1, 1), cellPoint(world, terminal, 3, 4));
    expect(terminal->property("hasSelection").toBool(), QStringLiteral("nothing was selected"));
    const double bottom = terminal->mapToScene(QPointF(0, padding + number(terminal, "rows") * number(terminal, "cellHeight"))).y();
    expect(bottom == world.mc.part<InputWorld>().promptY, QStringLiteral("the prompt moved to %1").arg(bottom));
  });

  // Input methods and AltGr.
  step(QStringLiteral("the user composes %1 with an input method in the terminal").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    terminal->forceActiveFocus();
    QInputMethodEvent composing(QStringLiteral("にほ"), {});
    QCoreApplication::sendEvent(terminal, &composing);
    world.sync();
    expect(terminalWrites(world, kTerminal).isEmpty(), QStringLiteral("the composition reached the shell: %1").arg(describeTerminalCalls(world)));
    QInputMethodEvent committed;
    committed.setCommitString(c[0]);
    QCoreApplication::sendEvent(terminal, &committed);
    world.sync();
  });
  step(QStringLiteral("the user is composing with an input method in the terminal"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    terminal->forceActiveFocus();
    world.waitFor([&] { return terminal->hasActiveFocus(); }, QStringLiteral("the terminal to take the keyboard"));
    QInputMethodEvent composing(QStringLiteral("にほ"), {});
    QCoreApplication::sendEvent(terminal, &composing);
  });
  // A blank cell beside the cursor, which only the composition draws over.
  const auto besideTheCursor = [](World& world, QQuickItem* terminal) {
    const QRect cell = cursorCell(world, terminal).translated(int(number(terminal, "cellWidth")) * 2, 0);
    const QImage image = world.brick->grab().copy(cell);
    const QRgb background = backgroundOf(terminal).rgb();
    for (int y = 0; y < image.height(); ++y) {
      for (int x = 0; x < image.width(); ++x) {
        if (image.pixel(x, y) != background) return true;
      }
    }
    return false;
  };
  step(QStringLiteral("what is being composed is drawn at the cursor"), [besideTheCursor](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    world.waitFor([&] { return besideTheCursor(world, terminal); }, QStringLiteral("the composition to be drawn"));
    expect(terminalWrites(world, kTerminal).isEmpty(), QStringLiteral("the composition reached the shell: %1").arg(describeTerminalCalls(world)));
  });
  step(QStringLiteral("the user cancels the composition"), [](World& world, const Captures&, const Table&) {
    QInputMethodEvent cancelled;
    QCoreApplication::sendEvent(drawnTerminal(world), &cancelled);
  });
  step(QStringLiteral("nothing is drawn in its place"), [besideTheCursor](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    world.waitFor([&] { return !besideTheCursor(world, terminal); }, QStringLiteral("the composition to go"));
  });
  step(QStringLiteral("the shell receives %1 once the composition is committed").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return writes(world) == c[0]; }, [&] { return QStringLiteral("\"%1\" once; the MC got %2").arg(c[0], describeTerminalCalls(world)); });
  });
  step(QStringLiteral("the keys pressed during the composition are not sent separately"), [](World& world, const Captures&, const Table&) {
    expect(terminalWrites(world, kTerminal).size() == 1, QStringLiteral("the MC got %1").arg(describeTerminalCalls(world)));
  });
  step(QStringLiteral("the user's keyboard layout types %1 with AltGr").arg(q), [](World& world, const Captures&, const Table&) {
    drawnTerminal(world)->forceActiveFocus();
  });
  step(QStringLiteral("the user types %1 with AltGr in the terminal").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    world.waitFor([&] { return terminal->hasActiveFocus(); }, QStringLiteral("the terminal to take the keyboard"));
    // As Windows reports it, Ctrl+Alt, and as X11's Mode_switch does.
    for (const Qt::KeyboardModifiers modifiers : {Qt::KeyboardModifiers(Qt::ControlModifier | Qt::AltModifier), Qt::KeyboardModifiers(Qt::GroupSwitchModifier)}) {
      QKeyEvent press(QEvent::KeyPress, Qt::Key_At, modifiers, c[0]);
      QCoreApplication::sendEvent(terminal, &press);
    }
    world.sync();
  });
  step(QStringLiteral("the shell receives %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return terminalWrites(world, kTerminal) == QStringList{c[0], c[0]}; },
                  [&] { return QStringLiteral("\"%1\" for each way of typing it; the MC got %2").arg(c[0], describeTerminalCalls(world)); });
  });

  // Prompt symbols. A machine can't be made to lack a font here, so this asks
  // what the terminal's font picks: the bundled font comes before any installed.
  step(QStringLiteral("the machine has no Nerd Font installed"), [](World& world, const Captures&, const Table&) {
    drawnTerminal(world);
  });
  step(QStringLiteral("the shell prints a prompt with powerline separators and file-type icons"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    QMetaObject::invokeMethod(terminal, "reset");
    printToShell(world, QString::fromUtf8("\x1b[H\xee\x82\xb0 \xef\x80\x95"));
  });
  step(QStringLiteral("the terminal draws those symbols"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    const QFont font = terminal->property("font").value<QFont>();
    // Where the terminal's own font has them, that is the installed font winning.
    if (!QRawFont::fromFont(font).supportsCharacter(0xE0B0)) {
      QTextLayout layout(QString::fromUtf8("\xee\x82\xb0\xef\x80\x95"), font);
      layout.beginLayout();
      layout.createLine();
      layout.endLayout();
      const QList<QGlyphRun> runs = layout.glyphRuns();
      expect(!runs.isEmpty(), QStringLiteral("the symbols lay out to nothing"));
      for (const QGlyphRun& run : runs) {
        expect(run.rawFont().familyName() == QLatin1String("Symbols Nerd Font Mono"), QStringLiteral("the symbols come from %1").arg(run.rawFont().familyName()));
      }
    }
    const QPoint cell = cellPoint(world, terminal, 0, 0);
    const QRect area(cell.x() - int(number(terminal, "cellWidth") / 2), cell.y() - int(number(terminal, "cellHeight") / 2), int(number(terminal, "cellWidth")), int(number(terminal, "cellHeight")));
    world.waitFor([&] { return differingPixels(world.brick->grab(), area, backgroundOf(terminal).rgb()) > 0; }, QStringLiteral("the separator to be drawn"));
  });
  step(QStringLiteral("the text keeps its own font and cell size"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    const QFont font = terminal->property("font").value<QFont>();
    QFont own(font.family());
    own.setPixelSize(font.pixelSize());
    const QFontMetricsF metrics(own);
    expect(number(terminal, "cellWidth") == std::ceil(metrics.horizontalAdvance(QLatin1Char('M'))), QStringLiteral("cells are %1 wide").arg(number(terminal, "cellWidth")));
    expect(number(terminal, "cellHeight") == std::ceil(metrics.height()), QStringLiteral("cells are %1 tall").arg(number(terminal, "cellHeight")));
  });

  // The cursor.
  step(QStringLiteral("the shell asked for a blinking cursor"), [](World& world, const Captures&, const Table&) {
    drawnTerminal(world);
    printToShell(world, QStringLiteral("\x1b[1 q"));
  });
  step(QStringLiteral("the user prefers reduced motion"), [](World& world, const Captures&, const Table&) {
    auto* settings = world.native().controller<SettingsController>();
    settings->set(QStringLiteral("reduceMotion"), true);
    world.waitFor([&] { return settings->setting(QStringLiteral("reduceMotion")).toBool(); }, QStringLiteral("the preference to be saved"));
  });
  step(QStringLiteral("the terminal has focus"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    terminal->forceActiveFocus();
    world.waitFor([&] { return terminal->hasActiveFocus(); }, QStringLiteral("the terminal to take the keyboard"));
  });
  step(QStringLiteral("the cursor blinks"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    const QRect cell = cursorCell(world, terminal);
    const QImage first = world.brick->grab().copy(cell);
    world.waitFor([&] { return world.brick->grab().copy(cell) != first; }, QStringLiteral("the cursor to change"));
  });
  step(QStringLiteral("the cursor does not blink"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    const QRect cell = cursorCell(world, terminal);
    world.waitFor([&] { return world.brick->grab().pixel(cell.center()) != backgroundOf(terminal).rgb(); }, QStringLiteral("the cursor to be drawn"));
    const QImage steady = world.brick->grab().copy(cell);
    // Through a whole blink, off half included.
    for (int sample = 0; sample < 6; ++sample) {
      QTest::qWait(QGuiApplication::styleHints()->cursorFlashTime() / 4);
      expect(world.brick->grab().copy(cell) == steady, QStringLiteral("the cursor changed"));
    }
  });
  step(QStringLiteral("the terminal loses focus"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    world.brick->root()->forceActiveFocus();
    world.waitFor([&] { return !terminal->hasActiveFocus(); }, QStringLiteral("the terminal to lose the keyboard"));
    world.sync();
  });
  step(QStringLiteral("the cursor is drawn as an outline and does not blink"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    const QRect cell = cursorCell(world, terminal);
    const QRgb background = backgroundOf(terminal).rgb();
    QImage image;
    world.waitFor([&] {
      image = world.brick->grab();
      return image.pixel(cell.center()) == background && image.pixel(cell.left(), cell.center().y()) != background;
    }, QStringLiteral("a hollow cursor"));
    const QImage outline = image.copy(cell);
    // Longer than a blink, and nothing is asked to draw it.
    QTest::qWait(QGuiApplication::styleHints()->cursorFlashTime());
    expect(world.brick->grab().copy(cell) == outline, QStringLiteral("the unfocused cursor changed"));
  });

  // Hiding the terminal (terminal/sessions.feature).
  step(QStringLiteral("the terminal is running a build that prints continuously"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    InputWorld& input = world.mc.part<InputWorld>();
    input.frames = std::make_shared<int>(0);
    input.terminal = terminal;
    QObject::connect(&world.brick->window(), &QQuickWindow::beforeSynchronizing, &world.brick->window(), [frames = input.frames] { ++*frames; }, Qt::DirectConnection);
    printToShell(world, QStringLiteral("building 1\r\n"));
    // Showing, its output wakes frames: what the hidden terminal must not do.
    world.waitFor([&] { return *input.frames > 0; }, QStringLiteral("the output to be drawn"));
  });
  step(QStringLiteral("the terminal does no drawing work"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !terminals(world)->isOpen(); }, QStringLiteral("the terminal to hide"));
    world.sync();
    // Whatever hiding it asked of the window is done with.
    QTest::qWait(100);
    InputWorld& input = world.mc.part<InputWorld>();
    *input.frames = 0;
    printToShell(world, QStringLiteral("building 2\r\nbuilding 3\r\n"));
    QTest::qWait(100);
    expect(*input.frames == 0, QStringLiteral("the hidden terminal woke %1 frames").arg(*input.frames));
  });
  step(QStringLiteral("the shell's output keeps being read and its replies keep being sent"), [](World& world, const Captures&, const Table&) {
    // A program asks for the terminal's status while nothing shows it.
    printToShell(world, QStringLiteral("\x1b[5n"));
    world.waitFor([&] { return writes(world).contains(QLatin1String("\x1b[0n")); }, [&] { return QStringLiteral("the status reply; the MC got %1").arg(describeTerminalCalls(world)); });
    expect(call(world.mc.part<InputWorld>().terminal, "text").contains(QLatin1String("building 3")), QStringLiteral("the output was not read"));
  });
  step(QStringLiteral("the user shows the terminal again"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("terminal.toggle"));
    world.waitFor([&] { return terminals(world)->isOpen(); }, QStringLiteral("the terminal to show"));
    world.sync();
  });
  step(QStringLiteral("the terminal is drawn in full and shows the latest output"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = world.brick->item(QStringLiteral("HalC2Terminal"));
    world.waitFor([&] { return terminal->isVisible(); }, QStringLiteral("the terminal to be visible"));
    expect(call(terminal, "text").contains(QLatin1String("building 3")), QStringLiteral("it shows \"%1\"").arg(call(terminal, "text")));
    // Row 4 is "building 3": kOutput's two lines come first.
    const QPoint middle = cellPoint(world, terminal, 0, 4);
    const QRect row(middle.x(), middle.y() - int(number(terminal, "cellHeight") / 2), int(number(terminal, "cellWidth")) * 10, int(number(terminal, "cellHeight")));
    world.waitFor([&] { return differingPixels(world.brick->grab(), row, backgroundOf(terminal).rgb()) > 0; }, QStringLiteral("the latest row to be drawn"));
  });
  step(QStringLiteral("the shell is running at 120 columns and 30 rows"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    const double padding = number(terminal, "padding");
    Brick& brick = *world.brick;
    const int width = int(std::ceil(120 * number(terminal, "cellWidth") + 2 * padding));
    brick.window().resize(width, 1000);
    brick.root()->setSize(QSizeF(width, 1000));
    const int height = terminals(world)->height() + int(std::ceil((30 - number(terminal, "rows")) * number(terminal, "cellHeight")));
    world.bridge().dispatch(QStringLiteral("terminal.resize"), QVariantMap{{QStringLiteral("height"), height}});
    world.waitFor([&] {
      const auto resize = lastTerminalCall(world, QStringLiteral("terminal.resize"), shownThread(world), kTerminal);
      return terminal->property("columns").toInt() == 120 && terminal->property("rows").toInt() == 30 && resize &&
             resize->value(QLatin1String("cols")).toInt() == 120 && resize->value(QLatin1String("rows")).toInt() == 30;
    }, [&] { return QStringLiteral("120x30; it is %1x%2 and the MC got %3").arg(terminal->property("columns").toInt()).arg(terminal->property("rows").toInt()).arg(describeTerminalCalls(world)); });
    world.sync();
    int calls = 0;
    for (const QJsonObject& made : world.mc.part<FakeTerminals>().calls) {
      if (made.value(QLatin1String("method")) == QLatin1String("terminal.resize")) ++calls;
    }
    world.mc.part<InputWorld>().resizeCalls = calls;
    world.mc.part<InputWorld>().terminal = terminal;
  });
  const auto noResize = [](World& world) {
    int calls = 0;
    for (const QJsonObject& made : world.mc.part<FakeTerminals>().calls) {
      if (made.value(QLatin1String("method")) == QLatin1String("terminal.resize")) ++calls;
    }
    QQuickItem* terminal = world.mc.part<InputWorld>().terminal;
    expect(calls == world.mc.part<InputWorld>().resizeCalls, QStringLiteral("the shell was resized: %1").arg(describeTerminalCalls(world)));
    expect(terminal->property("columns").toInt() == 120 && terminal->property("rows").toInt() == 30,
           QStringLiteral("the screen is %1x%2").arg(terminal->property("columns").toInt()).arg(terminal->property("rows").toInt()));
  };
  step(QStringLiteral("the user hides the terminal so that it has no size"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("terminal.toggle"));
    QQuickItem* drawer = world.brick->item(QStringLiteral("drawer"));
    world.waitFor([&] { return drawer->height() == 0; }, QStringLiteral("the drawer to have no size"));
    world.sync();
  });
  step(QStringLiteral("the shell is not resized"), [noResize](World& world, const Captures&, const Table&) { noResize(world); });
  step(QStringLiteral("the user shows the terminal at the same size again"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("terminal.toggle"));
    QQuickItem* drawer = world.brick->item(QStringLiteral("drawer"));
    world.waitFor([&] { return drawer->height() > 0; }, QStringLiteral("the drawer to show"));
    world.sync();
  });
  step(QStringLiteral("it is drawn again without a resize"), [noResize](World& world, const Captures&, const Table&) {
    noResize(world);
    QQuickItem* terminal = world.brick->item(QStringLiteral("HalC2Terminal"));
    world.waitFor([&] { return differingPixels(world.brick->grab(), screenArea(world, terminal), backgroundOf(terminal).rgb()) > 0; }, QStringLiteral("the terminal to draw"));
  });
});

}  // namespace
