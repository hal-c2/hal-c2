// What the user does inside a terminal the desktop draws: its right-click
// menu (TerminalMenu), clearing from the keyboard, its colours and font, and
// the keys a program asks for (features/terminal/composer-context.feature,
// io.feature, links-and-graphics.feature). Driven on the bricks themselves,
// with the mouse and keys the user has.

#include <QClipboard>
#include <QCoreApplication>
#include <QCursor>
#include <QMouseEvent>
#include <QFont>
#include <QGuiApplication>
#include <QHash>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QPointingDevice>
#include <QStyleHints>
#include <QTest>

#include "Brick.h"
#include "FakeConfig.h"
#include "FakeTerminals.h"
#include "Harness.h"
#include "SettingsController.h"
#include "TerminalController.h"
#include "ThemeController.h"
#include "World.h"

namespace {

using namespace terminalfake;

const QString kOutput = QStringLiteral("FAIL cart.test.ts\r\n  expected 3, got 2\r\n");
const QString kClipboard = QStringLiteral("bun test cart");

struct MenuWorld {
  QString selected;
  // The address the shell printed, and where the mouse went down on it.
  QString address;
  QPoint pressed;
  QString platform = QStringLiteral("linux");
  // The first output has been drawn; what the shell prints next may replace it.
  bool drawn = false;
  // What a double click and then a third click selected.
  QString word;
  QString line;
};

TerminalController* terminals(World& world) {
  return world.native().controller<TerminalController>();
}

QString call(QQuickItem* terminal, const char* method) {
  QString text;
  QMetaObject::invokeMethod(terminal, method, Q_RETURN_ARG(QString, text));
  return text;
}

}  // namespace

// The thread's drawer, open on a terminal that printed kOutput, drawn.
QQuickItem* terminalfake::drawnTerminal(World& world) {
  if (!world.brick) {
    ensureProject(world);
    ensureThread(world);
    world.waitFor([&] { return terminals(world)->available(); }, QStringLiteral("the thread's terminal drawer"));
    const QString threadId = shownThread(world);
    if (!terminals(world)->isOpen()) world.bridge().dispatch(QStringLiteral("terminal.toggle"));
    world.waitFor([&] { return terminalAttach(world, threadId, QStringLiteral("term-1")).has_value(); }, [&] { return describeRows(world); });
    world.sync();
    print(world.mc, threadId, QStringLiteral("term-1"), kOutput);
    world.brick = std::make_unique<Brick>(world,
                                          "import QtQuick\nimport HalC2.Bricks\nItem { TerminalDrawer { objectName: \"drawer\"; anchors.left: parent.left; "
                                          "anchors.right: parent.right; anchors.bottom: parent.bottom } }\n",
                                          QSize(900, 600));
  }
  QQuickItem* terminal = world.brick->item(QStringLiteral("HalC2Terminal"));
  terminal->setProperty("platform", world.mc.part<MenuWorld>().platform);
  if (!world.mc.part<MenuWorld>().drawn) {
    world.waitFor([&] { return call(terminal, "text").contains(QLatin1String("expected 3, got 2")); },
                  [&] { return QStringLiteral("the terminal to draw its output; it draws \"%1\"").arg(call(terminal, "text")); });
    world.mc.part<MenuWorld>().drawn = true;
  }
  return terminal;
}

void terminalfake::setTerminalPlatform(World& world, const QString& platform) {
  world.mc.part<MenuWorld>().platform = platform == QLatin1String("macOS") ? QStringLiteral("osx") : platform.toLower();
}

namespace {

// Drags the mouse over the terminal's first line, as the user selects it.
void selectFirstLine(World& world, QQuickItem* terminal) {
  Brick& brick = *world.brick;
  const double cell = terminal->property("cellWidth").toDouble();
  const double row = terminal->property("cellHeight").toDouble();
  const double padding = terminal->property("padding").toDouble();
  const QPoint origin = brick.at(terminal, 0, 0);
  const QPoint from(origin.x() + int(padding + cell * 0.5), origin.y() + int(padding + row * 0.5));
  const QPoint to(origin.x() + int(padding + cell * 16.9), from.y());
  QTest::mousePress(&brick.window(), Qt::LeftButton, Qt::NoModifier, from);
  for (int step = 1; step <= 4; ++step) QTest::mouseMove(&brick.window(), from + (to - from) * step / 4);
  QTest::mouseRelease(&brick.window(), Qt::LeftButton, Qt::NoModifier, to);
  world.waitFor([&] { return terminal->property("hasSelection").toBool(); }, QStringLiteral("the terminal to have a selection"));
  world.mc.part<MenuWorld>().selected = call(terminal, "selectedText");
  expect(world.mc.part<MenuWorld>().selected.contains(QLatin1String("FAIL cart.test.ts")),
         QStringLiteral("the selection is \"%1\"").arg(world.mc.part<MenuWorld>().selected));
}

// Right-clicks the terminal; its menu's items are then on screen.
void openMenu(World& world, QQuickItem* terminal) {
  Brick& brick = *world.brick;
  QTest::mouseClick(&brick.window(), Qt::RightButton, Qt::NoModifier, brick.at(terminal, 0.5, 0.6));
  world.waitFor([&] { return brick.item(QStringLiteral("terminalPaste"))->isVisible(); }, QStringLiteral("the terminal's menu to open"));
}

struct Offer {
  bool offered = false;
  bool enabled = false;
};

Offer offer(World& world, const QString& objectName) {
  QQuickItem* item = world.brick->item(objectName);
  return {item->isVisible() && item->height() > 0, item->isEnabled()};
}

// Presses a chord as "the user presses" spells it, with the modifiers Qt
// reports on that platform: on macOS it calls Cmd Control, and Ctrl Meta.
void pressChord(World& world, const QString& chord) {
  static const QHash<QString, Qt::Key> named{{QStringLiteral("Left"), Qt::Key_Left},
                                             {QStringLiteral("Right"), Qt::Key_Right},
                                             {QStringLiteral("Insert"), Qt::Key_Insert},
                                             {QStringLiteral("Backspace"), Qt::Key_Backspace}};
  const bool mac = world.mc.part<MenuWorld>().platform == QLatin1String("osx");
  QStringList parts = chord.split(QLatin1Char('+'));
  const QString keyName = parts.takeLast();
  const Qt::Key key = named.contains(keyName) ? named.value(keyName) : Qt::Key(Qt::Key_A + keyName.at(0).toLatin1() - 'A');
  Qt::KeyboardModifiers modifiers;
  for (const QString& part : parts) {
    if (part == QLatin1String("Shift")) modifiers |= Qt::ShiftModifier;
    else if (part == QLatin1String("Cmd")) modifiers |= Qt::ControlModifier;
    else if (part == QLatin1String("Ctrl")) modifiers |= mac ? Qt::MetaModifier : Qt::ControlModifier;
    else if (part == QLatin1String("Alt") || part == QLatin1String("Option")) modifiers |= Qt::AltModifier;
    else fail(QStringLiteral("no such modifier: ") + part);
  }
  QTest::keyClick(&world.brick->window(), key, modifiers);
}

const Steps steps([] {
  Brick::registerSingletons();
  const QString q = kQuoted;

  // A terminal with no draft beside it: a provider's sign-in terminal, as
  // Settings shows it.
  step(QStringLiteral("the terminal is shown somewhere without a message draft"), [](World& world, const Captures&, const Table&) {
    world.connect();
    world.sync();
    world.brick = std::make_unique<Brick>(world,
                                          "import QtQuick\nimport HalC2.Bricks\nItem { ProviderAuthTerminal { anchors.fill: parent; instanceId: \"codex\"; "
                                          "terminal: ({ output: \"FAIL cart.test.ts\\r\\n  expected 3, got 2\\r\\n\", offset: 40 }) } }\n",
                                          QSize(700, 300));
  });
  step(QStringLiteral("the user selects terminal output"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = world.brick->item(QStringLiteral("HalC2Terminal"));
    world.waitFor([&] { return call(terminal, "text").contains(QLatin1String("expected 3, got 2")); }, QStringLiteral("the terminal to draw its output"));
    selectFirstLine(world, terminal);
  });
  step(QStringLiteral("the user is offered to copy it but not to add it to the chat"), [](World& world, const Captures&, const Table&) {
    openMenu(world, world.brick->item(QStringLiteral("HalC2Terminal")));
    const Offer copy = offer(world, QStringLiteral("terminalCopy"));
    const Offer add = offer(world, QStringLiteral("terminalAddToChat"));
    expect(copy.offered && copy.enabled, QStringLiteral("Copy is offered %1, enabled %2").arg(copy.offered).arg(copy.enabled));
    expect(!add.offered, QStringLiteral("Add to chat is offered"));
    QGuiApplication::clipboard()->setText(QStringLiteral("something else"));
    world.brick->click(QStringLiteral("terminalCopy"));
    world.waitFor([&] { return QGuiApplication::clipboard()->text() == world.mc.part<MenuWorld>().selected; },
                  [&] { return QStringLiteral("the selection on the clipboard; it holds \"%1\"").arg(QGuiApplication::clipboard()->text()); });
  });

  step(QStringLiteral("nothing is selected in the terminal"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    expect(!terminal->property("hasSelection").toBool(), QStringLiteral("the terminal has a selection"));
  });
  step(QStringLiteral("the user opens the terminal's menu"), [](World& world, const Captures&, const Table&) {
    openMenu(world, drawnTerminal(world));
  });
  step(QStringLiteral("adding to chat and copying are unavailable"), [](World& world, const Captures&, const Table&) {
    const Offer copy = offer(world, QStringLiteral("terminalCopy"));
    const Offer add = offer(world, QStringLiteral("terminalAddToChat"));
    // Listed, since the thread has a draft, and greyed until something is selected.
    expect(add.offered && !add.enabled && copy.offered && !copy.enabled,
           QStringLiteral("Add to chat is offered %1, enabled %2; Copy is offered %3, enabled %4").arg(add.offered).arg(add.enabled).arg(copy.offered).arg(copy.enabled));
  });
  step(QStringLiteral("pasting is available"), [](World& world, const Captures&, const Table&) {
    const Offer paste = offer(world, QStringLiteral("terminalPaste"));
    expect(paste.offered && paste.enabled, QStringLiteral("Paste is offered %1, enabled %2").arg(paste.offered).arg(paste.enabled));
  });

  step(QStringLiteral("the terminal has a selection"), [](World& world, const Captures&, const Table&) {
    QGuiApplication::clipboard()->setText(kClipboard);
    selectFirstLine(world, drawnTerminal(world));
  });
  step(QStringLiteral("the user chooses %1 from the terminal's menu").arg(q), [](World& world, const Captures& c, const Table&) {
    openMenu(world, drawnTerminal(world));
    world.brick->click(c[0] == QLatin1String("Copy") ? QStringLiteral("terminalCopy") : QStringLiteral("terminalPaste"));
    world.sync();
  });
  step(QStringLiteral("the selected text is on the clipboard"), [](World& world, const Captures&, const Table&) {
    const QString selected = world.mc.part<MenuWorld>().selected;
    world.waitFor([&] { return QGuiApplication::clipboard()->text() == selected; },
                  [&] { return QStringLiteral("\"%1\" on the clipboard; it holds \"%2\"").arg(selected, QGuiApplication::clipboard()->text()); });
    expect(terminalWrites(world, QStringLiteral("term-1")).isEmpty(), QStringLiteral("the MC got %1").arg(describeTerminalCalls(world)));
  });
  step(QStringLiteral("the clipboard text is sent to the shell"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return terminalWrites(world, QStringLiteral("term-1")).join(QString()).contains(kClipboard); },
                  [&] { return QStringLiteral("\"%1\" to be written; the MC got %2").arg(kClipboard, describeTerminalCalls(world)); });
  });

  step(QStringLiteral("the user presses %1 in the terminal").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    terminal->forceActiveFocus();
    world.waitFor([&] { return terminal->hasActiveFocus(); }, QStringLiteral("the terminal to take the keyboard"));
    // A shell answers Ctrl-L by clearing the screen and drawing its prompt.
    world.mc.part<FakeTerminals>().replies.insert(QStringLiteral("\x0c"), QStringLiteral("\x1b[H\x1b[2J$ "));
    pressChord(world, c[0]);
    world.sync();
  });
  step(QStringLiteral("the selection (is cleared|stays)"), [](World& world, const Captures& c, const Table&) {
    const bool selected = world.brick->item(QStringLiteral("HalC2Terminal"))->property("hasSelection").toBool();
    expect(selected == (c[0] == QLatin1String("stays")), QStringLiteral("the terminal has a selection: %1").arg(selected));
  });
  step(QStringLiteral("the shell receives Ctrl-C"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return terminalWrites(world, QStringLiteral("term-1")).contains(QStringLiteral("\x03")); },
                  [&] { return QStringLiteral("Ctrl-C to be written; the MC got %1").arg(describeTerminalCalls(world)); });
  });

  step(QStringLiteral("the user clears the terminal from the keyboard"), [](World& world, const Captures&, const Table&) {
    // A shell answers Ctrl-L by clearing the screen and drawing its prompt.
    world.mc.part<FakeTerminals>().replies.insert(QStringLiteral("\x0c"), QStringLiteral("\x1b[H\x1b[2J$ "));
    QQuickItem* terminal = drawnTerminal(world);
    terminal->forceActiveFocus();
    world.waitFor([&] { return terminal->hasActiveFocus(); }, QStringLiteral("the terminal to take the keyboard"));
    // Qt's Control: the terminal item encodes it as Ctrl on every platform.
    QTest::keyClick(&world.brick->window(), Qt::Key_L, Qt::ControlModifier);
    world.sync();
  });
  step(QStringLiteral("the shell receives Ctrl-L and redraws its prompt at the top"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return terminalWrites(world, QStringLiteral("term-1")).contains(QStringLiteral("\x0c")); },
                  [&] { return QStringLiteral("Ctrl-L to be written; the MC got %1").arg(describeTerminalCalls(world)); });
    QQuickItem* terminal = world.brick->item(QStringLiteral("HalC2Terminal"));
    // The prompt is the screen's first line, and the old output is off it.
    world.waitFor([&] { return call(terminal, "text").trimmed() == QLatin1String("$"); },
                  [&] { return QStringLiteral("only the prompt; the terminal draws \"%1\"").arg(call(terminal, "text")); });
  });

  step(QStringLiteral("the user switches the app to a dark theme"), [](World& world, const Captures&, const Table&) {
    auto* themes = world.native().controller<ThemeController>();
    auto* settings = world.native().controller<SettingsController>();
    drawnTerminal(world);
    expect(themes->setMode(QStringLiteral("light")), settings->deviceError());
    world.waitFor([&] { return world.theme().appearance() == QLatin1String("light"); }, QStringLiteral("the app to be drawn light"));
    world.mc.part<MenuWorld>().selected = world.brick->item(QStringLiteral("HalC2Terminal"))->property("backgroundColor").value<QColor>().name();
    expect(settings->writeDevice(QStringLiteral("fontFamilyTerminal"), QStringLiteral("Courier")) && settings->writeDevice(QStringLiteral("fontSizeTerminal"), 15),
           settings->deviceError());
    expect(themes->setMode(QStringLiteral("dark")), settings->deviceError());
    world.waitFor([&] { return world.theme().appearance() == QLatin1String("dark"); }, QStringLiteral("the app to be drawn dark"));
  });
  step(QStringLiteral("the terminal's colours and selection follow the dark theme"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = world.brick->item(QStringLiteral("HalC2Terminal"));
    ThemeStore& theme = world.theme();
    const QColor canvas = theme.color(QStringLiteral("canvas"), QColor());
    const QColor text = theme.color(QStringLiteral("text"), QColor());
    QColor accent = theme.color(QStringLiteral("accent"), QColor());
    accent.setAlphaF(0.35f);
    const auto colour = [&](const char* name) { return terminal->property(name).value<QColor>(); };
    world.waitFor([&] { return colour("backgroundColor") == canvas && colour("foregroundColor") == text && colour("cursorColor") == text; },
                  [&] { return QStringLiteral("the terminal on %1 in %2; it is on %3 in %4").arg(canvas.name(), text.name(), colour("backgroundColor").name(), colour("foregroundColor").name()); });
    expect(colour("selectionColor").rgba() == accent.rgba(), QStringLiteral("the selection is %1, the accent %2").arg(colour("selectionColor").name(QColor::HexArgb), accent.name(QColor::HexArgb)));
    // It was light before: these are the dark theme's.
    expect(canvas.lightness() < 128 && canvas.name() != world.mc.part<MenuWorld>().selected, QStringLiteral("the canvas is %1").arg(canvas.name()));
  });
  step(QStringLiteral("the terminal uses the app's terminal font"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = world.brick->item(QStringLiteral("HalC2Terminal"));
    world.waitFor([&] {
      const QFont font = terminal->property("font").value<QFont>();
      return font.family() == QLatin1String("Courier") && font.pixelSize() == 15;
    }, [&] {
      const QFont font = terminal->property("font").value<QFont>();
      return QStringLiteral("the terminal in Courier at 15; it is in %1 at %2").arg(font.family()).arg(font.pixelSize());
    });
  });

  // Links in the output (TerminalSplits follows the one under a Ctrl-click).
  // Where `link` is drawn, on the last line that shows it.
  const auto pointOn = [](World& world, QQuickItem* terminal, const QString& link) {
    const QStringList lines = call(terminal, "text").split(QLatin1Char('\n'));
    int row = -1;
    for (int at = 0; at < lines.size(); ++at) {
      if (lines.at(at).contains(link)) row = at;
    }
    expect(row >= 0, QStringLiteral("the terminal draws \"%1\"").arg(link));
    const int column = int(lines.at(row).indexOf(link)) + int(link.size()) / 2;
    const double cell = terminal->property("cellWidth").toDouble();
    const double height = terminal->property("cellHeight").toDouble();
    const double padding = terminal->property("padding").toDouble();
    const QPoint origin = world.brick->at(terminal, 0, 0);
    return QPoint(origin.x() + int(padding + cell * (column + 0.5)), origin.y() + int(padding + height * (row + 0.5)));
  };
  // The shell prints a line with `link` in it; where the link is drawn.
  const auto showLink = [pointOn](World& world, const QString& printed, const QString& link) {
    QQuickItem* terminal = drawnTerminal(world);
    print(world.mc, shownThread(world), QStringLiteral("term-1"), printed + QStringLiteral("\r\n"));
    world.waitFor([&] { return call(terminal, "text").contains(link); }, [&] { return QStringLiteral("the terminal to draw \"%1\"").arg(printed); });
    return pointOn(world, terminal, link);
  };
  const auto follow = [showLink](World& world, const QString& printed, const QString& link, Qt::KeyboardModifiers modifiers) {
    QTest::mouseClick(&world.brick->window(), Qt::LeftButton, modifiers, showLink(world, printed, link));
    world.sync();
  };
  step(QStringLiteral("the user's links open in the system browser"), [](World& world, const Captures&, const Table&) {
    // The setting's default (BrowserLinkTarget "system").
    drawnTerminal(world);
    const QJsonObject settings = world.native().controller<SettingsController>()->settings();
    expect(settings.value(QLatin1String("browserLinkTarget")).toString(QStringLiteral("system")) == QLatin1String("system"),
           QStringLiteral("links open in %1").arg(settings.value(QLatin1String("browserLinkTarget")).toString()));
  });
  step(QStringLiteral("the user follows %1 in the terminal").arg(q), [follow](World& world, const Captures& c, const Table&) {
    follow(world, QStringLiteral("Server ready at %1 (press h for help)").arg(c[0]), c[0], Qt::ControlModifier);
  });
  step(QStringLiteral("the user clicks %1 in the terminal without holding Ctrl").arg(q), [follow](World& world, const Captures& c, const Table&) {
    follow(world, QStringLiteral("Server ready at %1 (press h for help)").arg(c[0]), c[0], Qt::NoModifier);
  });
  step(QStringLiteral("the user taps %1 in the terminal on a touch screen").arg(q), [showLink](World& world, const Captures& c, const Table&) {
    static QPointingDevice* const screen = QTest::createTouchDevice();
    const QPoint at = showLink(world, QStringLiteral("Server ready at %1 (press h for help)").arg(c[0]), c[0]);
    QQuickWindow* window = &world.brick->window();
    QTest::touchEvent(window, screen).press(0, at, window);
    QTest::touchEvent(window, screen).release(0, at, window);
    world.sync();
  });
  step(QStringLiteral("the address opens in the system browser"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.openedUrls == QList<QUrl>{QUrl(QStringLiteral("http://localhost:5173"))}; },
                  [&] { return QStringLiteral("the browser to open the address; it opened %1 addresses").arg(world.openedUrls.size()); });
    // The click went to the link, not the shell, and selected nothing.
    QQuickItem* terminal = world.brick->item(QStringLiteral("HalC2Terminal"));
    expect(terminalWrites(world, QStringLiteral("term-1")).isEmpty() && !terminal->property("hasSelection").toBool(),
           QStringLiteral("the MC got %1").arg(describeTerminalCalls(world)));
  });
  step(QStringLiteral("the shell prints %1").arg(q), [](World& world, const Captures& c, const Table&) {
    // An environment with an editor, and a thread in /work/p1.
    fakeConfig(world.mc).config.insert(QStringLiteral("availableEditors"), QJsonArray{QStringLiteral("zed")});
    QQuickItem* terminal = drawnTerminal(world);
    print(world.mc, shownThread(world), QStringLiteral("term-1"), QStringLiteral("error TS2322 at %1.\r\n").arg(c[0]));
    world.waitFor([&] { return call(terminal, "text").contains(c[0]); }, [&] { return QStringLiteral("the terminal to draw \"%1\"").arg(c[0]); });
  });
  step(QStringLiteral("the user follows that path"), [follow](World& world, const Captures&, const Table&) {
    follow(world, QStringLiteral("(1 error)"), QStringLiteral("src/app.ts:12:4"), Qt::ControlModifier);
  });
  step(QStringLiteral("the user's links open in the in-app browser"), [](World& world, const Captures&, const Table&) {
    // The desktop has no in-app browser (docs/internals/desktop-qt.md): the
    // setting another client chose changes nothing here.
    fakeConfig(world.mc).settings.insert(QStringLiteral("browserLinkTarget"), QStringLiteral("in-app"));
    drawnTerminal(world);
  });
  step(QStringLiteral("neither the in-app browser nor the system browser can open an address"), [](World& world, const Captures&, const Table&) {
    world.urlsRefused = true;
  });
  step(QStringLiteral("the user follows a web address in the terminal"), [follow](World& world, const Captures&, const Table&) {
    const QString address = QStringLiteral("http://localhost:5173");
    follow(world, QStringLiteral("Server ready at %1 (press h for help)").arg(address), address, Qt::ControlModifier);
  });
  step(QStringLiteral("the user chooses to open a link in the system browser from the terminal's menu"), [pointOn](World& world, const Captures&, const Table&) {
    const QString address = QStringLiteral("http://localhost:5173");
    QQuickItem* terminal = drawnTerminal(world);
    print(world.mc, shownThread(world), QStringLiteral("term-1"), QStringLiteral("Server ready at %1\r\n").arg(address));
    world.waitFor([&] { return call(terminal, "text").contains(address); }, QStringLiteral("the terminal to draw the address"));
    QTest::mouseClick(&world.brick->window(), Qt::RightButton, Qt::NoModifier, pointOn(world, terminal, address));
    world.waitFor([&] { return world.brick->item(QStringLiteral("terminalOpenLink"))->isVisible(); }, QStringLiteral("the terminal's menu to offer the link"));
    world.brick->click(QStringLiteral("terminalOpenLink"));
    world.sync();
  });

  // What pointer and output do around a link. The window's point of a cell.
  const auto cell = [](World& world, QQuickItem* terminal, int row, int column) {
    const double padding = terminal->property("padding").toDouble();
    const QPoint origin = world.brick->at(terminal, 0, 0);
    return QPoint(origin.x() + int(padding + terminal->property("cellWidth").toDouble() * (column + 0.5)),
                  origin.y() + int(padding + terminal->property("cellHeight").toDouble() * (row + 0.5)));
  };
  // The screen row the address starts on. The text joins soft wraps, so a line
  // takes a row per terminal width (terminalLinks.js).
  const auto rowOf = [](QQuickItem* terminal, const QString& address) {
    const int columns = terminal->property("columns").toInt();
    const QStringList lines = call(terminal, "text").split(QLatin1Char('\n'));
    int row = 0;
    int found = -1;
    for (const QString& line : lines) {
      if (line.contains(address)) found = row;
      row += qMax(1, int(line.size() + columns - 1) / columns);
    }
    expect(found >= 0, QStringLiteral("the terminal draws \"%1\"").arg(address));
    return found - qRound(terminal->property("scrollOffset").toDouble());
  };
  // QTest's own mouseMove carries no modifiers. Through the window system, as the
  // user's move: Qt Quick repeats a hover after a frame with the application's
  // modifiers, so a sent event's Ctrl would be let go at the next frame.
  const auto hover = [](World& world, const QPoint& point, Qt::KeyboardModifiers modifiers) {
    QTest::mouseEvent(QTest::MouseMove, &world.brick->window(), Qt::NoButton, modifiers, point);
    QCoreApplication::processEvents();
  };
  // An address too long for one row, on the screen's own rows.
  const auto printWrapping = [](World& world) {
    QQuickItem* terminal = drawnTerminal(world);
    const int columns = terminal->property("columns").toInt();
    QString address = QStringLiteral("http://localhost:5173/");
    address += QString(columns + 10 - address.size(), QLatin1Char('a'));
    world.mc.part<MenuWorld>().address = address;
    print(world.mc, shownThread(world), QStringLiteral("term-1"), address + QStringLiteral("\r\n"));
    world.waitFor([&] { return call(terminal, "text").contains(address); }, QStringLiteral("the terminal to draw the address"));
    return terminal;
  };
  const auto underlines = [](World& world) { return visibleItems(world, QStringLiteral("terminalLinkUnderline")); };
  const auto pointerIsHand = [](World& world) { return world.brick->window().cursor().shape() == Qt::PointingHandCursor; };

  step(QStringLiteral("the shell prints a web address that wraps across two lines"), [printWrapping](World& world, const Captures&, const Table&) {
    printWrapping(world);
  });
  step(QStringLiteral("the user holds Ctrl \\(Cmd on macOS\\) and moves the pointer over one piece of it"), [cell, rowOf, hover](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    hover(world, cell(world, terminal, rowOf(terminal, world.mc.part<MenuWorld>().address) + 1, 2), Qt::ControlModifier);
  });
  step(QStringLiteral("every piece of the address is underlined"), [underlines](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return underlines(world).size() == 2; }, [&] { return QStringLiteral("two underlines; there are %1").arg(underlines(world).size()); });
    double width = 0;
    for (QQuickItem* piece : underlines(world)) width += piece->width();
    const double wanted = world.mc.part<MenuWorld>().address.size() * drawnTerminal(world)->property("cellWidth").toDouble();
    expect(qAbs(width - wanted) < 1, QStringLiteral("the underlines are %1 wide, the address %2").arg(width).arg(wanted));
  });
  step(QStringLiteral("the pointer shows that it can be followed"), [pointerIsHand](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return pointerIsHand(world); }, QStringLiteral("the pointer to become a hand"));
  });
  step(QStringLiteral("the pointer moves off the address"), [cell, rowOf, hover](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    hover(world, cell(world, terminal, rowOf(terminal, world.mc.part<MenuWorld>().address) + 3, 2), Qt::ControlModifier);
  });
  step(QStringLiteral("the underline and the pointer go back to normal"), [underlines, pointerIsHand](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return underlines(world).isEmpty() && !pointerIsHand(world); }, QStringLiteral("the underline and the hand to go"));
  });

  step(QStringLiteral("the shell prints a web address"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    const QString address = QStringLiteral("http://localhost:5173");
    world.mc.part<MenuWorld>().address = address;
    print(world.mc, shownThread(world), QStringLiteral("term-1"), QStringLiteral("Server ready at %1 (press h for help)\r\n").arg(address));
    world.waitFor([&] { return call(terminal, "text").contains(address); }, QStringLiteral("the terminal to draw the address"));
  });
  const auto printAddress = [](World& world) {
    QQuickItem* terminal = drawnTerminal(world);
    const QString address = QStringLiteral("http://localhost:5173");
    world.mc.part<MenuWorld>().address = address;
    print(world.mc, shownThread(world), QStringLiteral("term-1"), QStringLiteral("Server ready at %1 (press h for help)\r\n").arg(address));
    world.waitFor([&] { return call(terminal, "text").contains(address); }, QStringLiteral("the terminal to draw the address"));
    return terminal;
  };
  // What the Terminal has sent the program, mouse reports among it.
  const auto mouseSent = [](World& world) { return terminalWrites(world, QStringLiteral("term-1")).join(QString()); };
  step(QStringLiteral("the user moves the pointer over a web address in the output"), [printAddress, pointOn, hover](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = printAddress(world);
    hover(world, pointOn(world, terminal, world.mc.part<MenuWorld>().address), Qt::NoModifier);
  });
  step(QStringLiteral("the address is not underlined"), [underlines, pointerIsHand](World& world, const Captures&, const Table&) {
    world.sync();
    expect(underlines(world).isEmpty() && !pointerIsHand(world), QStringLiteral("the address is offered"));
  });
  step(QStringLiteral("pressing on it goes to the program"), [pointOn, mouseSent](World& world, const Captures&, const Table&) {
    QTest::mouseClick(&world.brick->window(), Qt::LeftButton, Qt::NoModifier, pointOn(world, drawnTerminal(world), world.mc.part<MenuWorld>().address));
    world.waitFor([&] { return mouseSent(world).contains(QLatin1String("\x1b[<0;")); }, [&] { return QStringLiteral("the program to get the press; the MC got %1").arg(describeTerminalCalls(world)); });
    expect(world.openedUrls.isEmpty(), QStringLiteral("the address was followed"));
  });
  step(QStringLiteral("the terminal's menu on it offers no link"), [pointOn](World& world, const Captures&, const Table&) {
    QTest::mouseClick(&world.brick->window(), Qt::RightButton, Qt::NoModifier, pointOn(world, drawnTerminal(world), world.mc.part<MenuWorld>().address));
    world.waitFor([&] { return world.brick->item(QStringLiteral("terminalPaste"))->isVisible(); }, QStringLiteral("the terminal's menu to open"));
    expect(!world.brick->item(QStringLiteral("terminalOpenLink"))->isVisible() && !world.brick->item(QStringLiteral("terminalCopyLink"))->isVisible(),
           QStringLiteral("the menu offers the link"));
  });
  step(QStringLiteral("the user holds Ctrl and moves the pointer over the address"), [pointOn, hover](World& world, const Captures&, const Table&) {
    // From elsewhere: Qt drops a move to where the pointer already is, which an
    // earlier scenario may have left it.
    const QPoint point = pointOn(world, drawnTerminal(world), world.mc.part<MenuWorld>().address);
    hover(world, point + QPoint(0, 100), Qt::ControlModifier);
    hover(world, point, Qt::ControlModifier);
  });
  step(QStringLiteral("the address is underlined"), [underlines, pointerIsHand](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return underlines(world).size() == 1 && pointerIsHand(world); }, [&] { return QStringLiteral("an underline and a hand; there are %1 underlines").arg(underlines(world).size()); });
  });
  step(QStringLiteral("the user holds Ctrl and clicks the address"), [pointOn](World& world, const Captures&, const Table&) {
    QTest::mouseClick(&world.brick->window(), Qt::LeftButton, Qt::ControlModifier, pointOn(world, drawnTerminal(world), world.mc.part<MenuWorld>().address));
    world.sync();
  });
  step(QStringLiteral("the program receives no click"), [mouseSent](World& world, const Captures&, const Table&) {
    world.sync();
    expect(!mouseSent(world).contains(QLatin1String("\x1b[<")), QStringLiteral("the MC got %1").arg(describeTerminalCalls(world)));
  });
  step(QStringLiteral("the user double-clicks and then triple-clicks on the address"), [pointOn](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    const QPoint point = pointOn(world, terminal, world.mc.part<MenuWorld>().address);
    // However long a busy machine takes between them.
    QGuiApplication::styleHints()->setMouseDoubleClickInterval(60000);
    QTest::mouseDClick(&world.brick->window(), Qt::LeftButton, Qt::NoModifier, point);
    world.mc.part<MenuWorld>().word = call(terminal, "selectedText");
    QTest::mouseClick(&world.brick->window(), Qt::LeftButton, Qt::NoModifier, point);
    world.mc.part<MenuWorld>().line = call(terminal, "selectedText");
    QGuiApplication::styleHints()->setMouseDoubleClickInterval(-1);
    world.sync();
  });
  step(QStringLiteral("the word is selected and then the whole line"), [](World& world, const Captures&, const Table&) {
    const MenuWorld& menu = world.mc.part<MenuWorld>();
    expect(!menu.word.isEmpty() && menu.address.contains(menu.word), QStringLiteral("a double click selected \"%1\"").arg(menu.word));
    expect(menu.line.trimmed() == QStringLiteral("Server ready at %1 (press h for help)").arg(menu.address), QStringLiteral("a third click selected \"%1\"").arg(menu.line));
  });
  step(QStringLiteral("the user holds Ctrl, presses on the address and releases a few pixels away"), [pointOn](World& world, const Captures&, const Table&) {
    const QPoint point = pointOn(world, drawnTerminal(world), world.mc.part<MenuWorld>().address);
    QTest::mousePress(&world.brick->window(), Qt::LeftButton, Qt::ControlModifier, point);
    QTest::mouseRelease(&world.brick->window(), Qt::LeftButton, Qt::ControlModifier, point + QPoint(3, 1));
    world.sync();
  });
  step(QStringLiteral("the address is followed"), [](World& world, const Captures&, const Table&) {
    const QUrl address(world.mc.part<MenuWorld>().address);
    world.waitFor([&] { return world.openedUrls == QList<QUrl>{address}; },
                  [&] { return QStringLiteral("the browser to open the address; it opened %1 addresses").arg(world.openedUrls.size()); });
  });
  step(QStringLiteral("the user presses on the address and drags well away before releasing"), [pointOn](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    const QPoint point = pointOn(world, terminal, world.mc.part<MenuWorld>().address);
    const QPoint away = point + QPoint(0, int(terminal->property("cellHeight").toDouble() * 3));
    QTest::mousePress(&world.brick->window(), Qt::LeftButton, Qt::NoModifier, point);
    QTest::mouseMove(&world.brick->window(), point + QPoint(0, int(terminal->property("cellHeight").toDouble())));
    QTest::mouseMove(&world.brick->window(), away);
    QTest::mouseRelease(&world.brick->window(), Qt::LeftButton, Qt::NoModifier, away);
    world.sync();
  });
  step(QStringLiteral("the text between the press and the release is selected"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    world.waitFor([&] { return terminal->property("hasSelection").toBool(); }, QStringLiteral("a selection"));
    const QString selected = call(terminal, "selectedText");
    // From the press, inside the address, on past its end; the rows below are blank.
    const bool fromThePress = !selected.startsWith(QLatin1String("Server")) && !selected.startsWith(QLatin1String("http"));
    expect(fromThePress && selected.contains(QLatin1String("(press h for help)")), QStringLiteral("selected \"%1\"").arg(selected));
  });
  step(QStringLiteral("the address is not followed"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(world.openedUrls.isEmpty(), QStringLiteral("the browser opened %1 addresses").arg(world.openedUrls.size()));
  });
  step(QStringLiteral("the user pressed on a link"), [pointOn](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    const QString address = QStringLiteral("http://localhost:5173");
    world.mc.part<MenuWorld>().address = address;
    print(world.mc, shownThread(world), QStringLiteral("term-1"), QStringLiteral("Server ready at %1 (press h for help)\r\n").arg(address));
    world.waitFor([&] { return call(terminal, "text").contains(address); }, QStringLiteral("the terminal to draw the address"));
    world.mc.part<MenuWorld>().pressed = pointOn(world, terminal, address);
    QTest::mousePress(&world.brick->window(), Qt::LeftButton, Qt::ControlModifier, world.mc.part<MenuWorld>().pressed);
  });
  step(QStringLiteral("the output changes so that another address is under the pointer before release"), [rowOf](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    const int row = rowOf(terminal, world.mc.part<MenuWorld>().address);
    const QString other = QStringLiteral("http://localhost:9999/other");
    print(world.mc, shownThread(world), QStringLiteral("term-1"), QStringLiteral("\x1b[%1;1HServer ready at %2\x1b[K").arg(row + 1).arg(other));
    world.waitFor([&] { return call(terminal, "text").contains(other); }, QStringLiteral("the terminal to draw the other address"));
    QTest::mouseRelease(&world.brick->window(), Qt::LeftButton, Qt::ControlModifier, world.mc.part<MenuWorld>().pressed);
    world.sync();
  });
  step(QStringLiteral("nothing is followed"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(world.openedUrls.isEmpty(), QStringLiteral("the browser opened %1").arg(world.openedUrls.isEmpty() ? QString() : world.openedUrls.first().toString()));
  });
  step(QStringLiteral("a web address wraps so that its start has scrolled above the top of the screen"), [printWrapping, cell, rowOf, hover, underlines](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = printWrapping(world);
    const int row = rowOf(terminal, world.mc.part<MenuWorld>().address);
    // While all of it shows, it is a link.
    hover(world, cell(world, terminal, row + 1, 2), Qt::ControlModifier);
    world.waitFor([&] { return underlines(world).size() == 2; }, QStringLiteral("the whole address to be a link"));
    hover(world, cell(world, terminal, 0, terminal->property("columns").toInt() - 1), Qt::ControlModifier);
    // The cursor is on the row after it: a screen's worth of new lines, less
    // that row and the one left showing, leave only its second row on screen.
    const int top = qRound(terminal->property("scrollOffset").toDouble());
    const int screen = terminal->property("rows").toInt();
    print(world.mc, shownThread(world), QStringLiteral("term-1"), QStringLiteral("\r\n").repeated(screen - 2));
    world.waitFor([&] { return qRound(terminal->property("scrollOffset").toDouble()) == top + row + 1; },
                  [&] { return QStringLiteral("its second row on top; the screen starts at %1, from %2 and row %3").arg(terminal->property("scrollOffset").toDouble()).arg(top).arg(row); });
  });
  step(QStringLiteral("the part still on screen is not a link"), [cell, hover, underlines, pointerIsHand](World& world, const Captures&, const Table&) {
    hover(world, cell(world, drawnTerminal(world), 0, 2), Qt::ControlModifier);
    world.sync();
    expect(underlines(world).isEmpty() && !pointerIsHand(world), QStringLiteral("the half-seen address is offered"));
  });
  step(QStringLiteral("nothing is opened for a half-seen address"), [cell](World& world, const Captures&, const Table&) {
    QTest::mouseClick(&world.brick->window(), Qt::LeftButton, Qt::ControlModifier, cell(world, drawnTerminal(world), 0, 2));
    world.sync();
    expect(world.openedUrls.isEmpty(), QStringLiteral("the browser was opened"));
  });

  // What a terminal says when something it was asked to do fails.
  step(QStringLiteral("the terminal shows a running shell"), [](World& world, const Captures&, const Table&) {
    drawnTerminal(world);
  });
  step(QStringLiteral("(sending what the user typed|moving the cursor by word or line|deleting to the start of the line|clearing from the keyboard) fails with %1").arg(q),
       [](World& world, const Captures& c, const Table&) {
    world.mc.part<FakeTerminals>().refuseWrite = c[1];
    const QString data = c[0].startsWith(QLatin1String("sending")) ? QStringLiteral("ls\r")
                         : c[0].startsWith(QLatin1String("moving")) ? QStringLiteral("\x01")
                         : c[0].startsWith(QLatin1String("deleting")) ? QStringLiteral("\x15")
                                                                      : QStringLiteral("\x0c");
    terminalSession(world, QStringLiteral("term-1"))->write(data);
    world.sync();
  });
  step(QStringLiteral("opening a file path from the output fails with %1").arg(q), [follow](World& world, const Captures&, const Table&) {
    // An environment with no editor to open it in.
    follow(world, QStringLiteral("src/app.ts:12:4"), QStringLiteral("src/app.ts:12:4"), Qt::ControlModifier);
  });
  step(QStringLiteral("copying the selection fails with %1").arg(q), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    selectFirstLine(world, terminal);
    // A clipboard that another application takes straight back: the engine reads back something else.
    QClipboard* clipboard = QGuiApplication::clipboard();
    bool taking = false;
    const QMetaObject::Connection taken = QObject::connect(clipboard, &QClipboard::dataChanged, clipboard, [&] {
      if (taking) return;
      taking = true;
      clipboard->setText(QStringLiteral("someone else's"));
      taking = false;
    });
    QTest::keyClick(&world.brick->window(), Qt::Key_C, Qt::ControlModifier);
    QObject::disconnect(taken);
    world.sync();
    expect(terminal->property("hasSelection").toBool(), QStringLiteral("a failed copy cleared the selection"));
  });
  step(QStringLiteral("the terminal shows %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    world.waitFor([&] { return call(terminal, "text").contains(c[0]); }, [&] { return QStringLiteral("the terminal to say \"%1\"; it shows \"%2\"").arg(c[0], call(terminal, "text")); });
  });
  step(QStringLiteral("the terminal keeps working"), [](World& world, const Captures&, const Table&) {
    world.mc.part<FakeTerminals>().refuseWrite.reset();
    terminalSession(world, QStringLiteral("term-1"))->write(QStringLiteral("pwd\r"));
    world.waitFor([&] { return terminalWrites(world, QStringLiteral("term-1")).join(QString()).contains(QLatin1String("pwd")); },
                  [&] { return QStringLiteral("the write; the MC got %1").arg(describeTerminalCalls(world)); });
    expect(terminals(world)->isOpen() && terminals(world)->tabs()->indexOf(QStringLiteral("term-1")) >= 0, describeRows(world));
  });

  step(QStringLiteral("the user opens the terminal's menu on %1").arg(q), [pointOn](World& world, const Captures& c, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    QTest::mouseClick(&world.brick->window(), Qt::RightButton, Qt::NoModifier, pointOn(world, terminal, c[0]));
    world.waitFor([&] { return world.brick->item(QStringLiteral("terminalPaste"))->isVisible(); }, QStringLiteral("the terminal's menu to open"));
  });
  const auto editorCall = [](World& world) -> QJsonObject {
    for (const FakeMc::Rpc& rpc : world.mc.calls) {
      if (rpc.method == QLatin1String("shell.openInEditor")) return rpc.payload;
    }
    return {};
  };
  step(QStringLiteral("\"src/app.ts\" opens in the user's editor at line 12, column 4"), [editorCall](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !editorCall(world).isEmpty(); }, QStringLiteral("the editor to be asked for the file"));
    const QJsonObject asked = editorCall(world);
    expect(asked.value(QLatin1String("editor")) == QLatin1String("zed") && asked.value(QLatin1String("cwd")).toString().endsWith(QLatin1String("/src/app.ts:12:4")),
           QStringLiteral("the editor was asked for %1").arg(QString::fromUtf8(QJsonDocument(asked).toJson(QJsonDocument::Compact))));
    expect(world.openedUrls.isEmpty(), QStringLiteral("the browser was opened"));
  });
  step(QStringLiteral("the path is resolved against the terminal's folder"), [editorCall](World& world, const Captures&, const Table&) {
    const QString folder = terminalAttach(world, shownThread(world), QStringLiteral("term-1"))->value(QLatin1String("cwd")).toString();
    expect(!folder.isEmpty() && editorCall(world).value(QLatin1String("cwd")) == folder + QStringLiteral("/src/app.ts:12:4"),
           QStringLiteral("the terminal runs in %1; the editor was asked for %2").arg(folder, editorCall(world).value(QLatin1String("cwd")).toString()));
  });

  step(QStringLiteral("a program turns on the Kitty keyboard protocol"), [](World& world, const Captures&, const Table&) {
    QQuickItem* terminal = drawnTerminal(world);
    // CSI > 1 u: disambiguate escape codes.
    print(world.mc, shownThread(world), QStringLiteral("term-1"), QStringLiteral("\x1b[>1u"));
    world.sync();
    terminal->forceActiveFocus();
    world.waitFor([&] { return terminal->hasActiveFocus(); }, QStringLiteral("the terminal to take the keyboard"));
  });
  step(QStringLiteral("the user presses a key with modifiers"), [](World& world, const Captures&, const Table&) {
    // Shift+Enter: plain terminals cannot tell it from Enter.
    QTest::keyClick(&world.brick->window(), Qt::Key_Return, Qt::ShiftModifier);
    world.sync();
  });
  step(QStringLiteral("the program receives Ctrl\\+A in the enhanced report"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return terminalWrites(world, QStringLiteral("term-1")).contains(QStringLiteral("\x1b[97;5u")); },
                  [&] { return QStringLiteral("CSI 97;5u to be written; the MC got %1").arg(describeTerminalCalls(world)); });
  });
  step(QStringLiteral("the program receives the enhanced key report"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return terminalWrites(world, QStringLiteral("term-1")).contains(QStringLiteral("\x1b[13;2u")); },
                  [&] { return QStringLiteral("CSI 13;2u to be written; the MC got %1").arg(describeTerminalCalls(world)); });
  });
});

}  // namespace
