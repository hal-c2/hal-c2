// What the user does inside a terminal the desktop draws: its right-click
// menu (TerminalMenu), clearing from the keyboard, its colours and font, and
// the keys a program asks for (features/terminal/composer-context.feature,
// io.feature, links-and-graphics.feature). Driven on the bricks themselves,
// with the mouse and keys the user has.

#include <QClipboard>
#include <QFont>
#include <QGuiApplication>
#include <QJsonObject>
#include <QTest>

#include "Brick.h"
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
};

TerminalController* terminals(World& world) {
  return world.native().controller<TerminalController>();
}

QString call(QQuickItem* terminal, const char* method) {
  QString text;
  QMetaObject::invokeMethod(terminal, method, Q_RETURN_ARG(QString, text));
  return text;
}

// The thread's drawer, open on a terminal that printed kOutput, drawn.
QQuickItem* drawnTerminal(World& world) {
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
  world.waitFor([&] { return call(terminal, "text").contains(QLatin1String("expected 3, got 2")); },
                [&] { return QStringLiteral("the terminal to draw its output; it draws \"%1\"").arg(call(terminal, "text")); });
  return terminal;
}

// Drags the mouse over the terminal's first line, as the user selects it.
void selectFirstLine(World& world, QQuickItem* terminal) {
  Brick& brick = *world.brick;
  const double cell = terminal->property("cellWidth").toDouble();
  const double row = terminal->property("cellHeight").toDouble();
  const double padding = terminal->property("padding").toDouble();
  const QPoint origin = brick.at(terminal, 0, 0);
  const QPoint from(origin.x() + int(padding + cell * 0.5), origin.y() + int(padding + row * 0.5));
  const QPoint to(origin.x() + int(padding + cell * 16.5), from.y());
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
  step(QStringLiteral("the program receives the enhanced key report"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return terminalWrites(world, QStringLiteral("term-1")).contains(QStringLiteral("\x1b[13;2u")); },
                  [&] { return QStringLiteral("CSI 13;2u to be written; the MC got %1").arg(describeTerminalCalls(world)); });
  });
});

}  // namespace
