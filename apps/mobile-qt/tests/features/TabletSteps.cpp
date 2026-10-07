// Windows with room for the desktop's layout, and hardware keyboards
// (features/mobile/tablet-and-hardware-keyboard.feature): the window at a
// tablet's or a phone's size, resized and rotated while the app runs, and the
// keys of a keyboard pressed as the window receives them.

#include <QJsonObject>
#include <QQuickItem>
#include <QQuickWindow>
#include <QSize>

#include "CommandPaletteController.h"
#include "CommandRegistry.h"
#include "Harness.h"
#include "KeybindingController.h"
#include "NativeShell.h"
#include "Phone.h"
#include "ShellBridge.h"
#include "TerminalController.h"
#include "World.h"

namespace {

// A small tablet on its side: wide enough for the desktop's layout that way,
// and not when it is turned upright.
const QSize kTablet(960, 600);
const QSize kPhone(412, 915);

QString screenTexts(World& world) {
  return world.texts().join(QStringLiteral(" | "));
}

// The rows of the thread list on screen, top to bottom, by title.
QStringList listedThreads(World& world) {
  QList<std::pair<qreal, QString>> rows;
  world.findWhere([&](QQuickItem* candidate) {
    if (candidate->objectName().startsWith(QLatin1String("threadRow:"))) {
      rows.append({candidate->mapToScene(QPointF(0, 0)).y(), candidate->property("item").toMap().value(QStringLiteral("title")).toString()});
    }
    return false;
  });
  std::sort(rows.begin(), rows.end());
  QStringList titles;
  for (const auto& row : std::as_const(rows)) titles.append(row.second);
  return titles;
}

// The thread list is on screen with the conversation of `title` to its right.
bool sideBySide(World& world, const QString& title) {
  QQuickItem* list = world.find(QStringLiteral("threadSidebar"));
  QQuickItem* thread = world.find(QStringLiteral("centreHost"));
  if (!list || !thread || shownThread(world) != title || !listedThreads(world).contains(title)) return false;
  return list->mapToScene(QPointF(list->width(), 0)).x() <= thread->mapToScene(QPointF(0, 0)).x() && thread->width() > 0;
}

// The conversation of `title` has the window to itself: no thread list beside it.
bool oneAtATime(World& world, const QString& title) {
  return world.find(QStringLiteral("threadScreen")) != nullptr && shownThread(world) == title && listedThreads(world).isEmpty();
}

// The paired window at `size`, reading the thread `title`.
void readThread(World& world, const QSize& size, const QString& title) {
  world.resize(size.width(), size.height());
  pairWithEnvironment(world);
  world.thread = haveThread(world, title);
  openThread(world, title);
}

// The button that draws the icon `name`, which the bricks' own buttons carry no other name for.
QQuickItem* iconButton(World& world, const QString& name) {
  QQuickItem* button = nullptr;
  world.waitFor([&] { return (button = world.findWhere([&](QQuickItem* candidate) { return candidate->property("iconName").toString() == name; })) != nullptr; },
                [&] { return QStringLiteral("a %1 button; the screen says: %2").arg(name, screenTexts(world)); });
  return button;
}

CommandPaletteController* palette(World& world) {
  return world.native().controller<CommandPaletteController>();
}

// What the palette's second entry was when the user ran it, and the commands run since.
struct PaletteRun {
  QString kind;
  QString id;
  QStringList commands;
};

// What the scenario's pointer did: the window's size before it narrowed,
// where a menu was asked for, and the row the list had picked up to arrange
// when a drag ended.
struct Pointer {
  QSize wide;
  QPointF asked;
  QString pickedUp;
  qsizetype commands = 0;
};

// A build without the terminal, for the scenario's length: what the build really has comes back with it.
struct NoTerminal {
  bool built = TerminalController::supported();
  ~NoTerminal() { TerminalController::setSupported(built); }
};

// The thread list's own list, which scrolls and arranges.
QQuickItem* rowList(World& world) {
  QQuickItem* list = nullptr;
  world.waitFor([&] { return (list = world.findWhere([](QQuickItem* candidate) { return candidate->objectName() == QLatin1String("list") && candidate->property("dragKey").isValid(); })) != nullptr; },
                [&] { return QStringLiteral("the thread list; the screen says: %1").arg(screenTexts(world)); });
  return list;
}

const Steps steps([] {
  using S = QString;

  step(S("the app window is (\\d+) wide and (\\d+) tall"), [](World& world, const Captures& c, const Table&) {
    readThread(world, QSize(c[0].toInt(), c[1].toInt()), S("Tax line"));
  });

  step(S("the thread list and the thread are shown (side by side|one at a time)"), [](World& world, const Captures& c, const Table&) {
    const bool split = c[0] == QLatin1String("side by side");
    world.waitFor([&] { return split ? sideBySide(world, S("Tax line")) : oneAtATime(world, S("Tax line")); },
                  [&] { return S("the list and the thread %1 in a %2x%3 window; the screen says: %4").arg(c[0]).arg(world.window().width()).arg(world.window().height()).arg(screenTexts(world)); });
  });

  step(S("the layout is split"), [](World& world, const Captures&, const Table&) {
    readThread(world, kTablet, S("Tax line"));
    world.waitFor([&] { return sideBySide(world, S("Tax line")); }, [&] { return S("the list beside the thread; the screen says: %1").arg(screenTexts(world)); });
  });

  // The list's own button hides it, and the header's brings it back.
  step(S("the user maximizes the content"), [](World& world, const Captures&, const Table&) { world.tap(iconButton(world, S("panel-left-close"))); });

  step(S("the user shows the thread sidebar"), [](World& world, const Captures&, const Table&) { world.tap(iconButton(world, S("panel-left"))); });

  step(S("the thread sidebar is (hidden|shown)"), [](World& world, const Captures& c, const Table&) {
    const bool shown = c[0] == QLatin1String("shown");
    world.waitFor([&] { return shown ? sideBySide(world, S("Tax line")) : world.find(S("threadSidebar")) == nullptr && listedThreads(world).isEmpty(); },
                  [&] { return S("the thread sidebar to be %1; the screen says: %2").arg(c[0], screenTexts(world)); });
    // The thread keeps the window either way.
    expect(shownThread(world) == S("Tax line"), S("the thread is no longer shown; the screen says: %1").arg(screenTexts(world)));
  });

  step(S("the user is reading %1 side by side with the list").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    readThread(world, kTablet, c[0]);
    world.waitFor([&] { return sideBySide(world, c[0]); }, [&] { return S("the list beside %1; the screen says: %2").arg(c[0], screenTexts(world)); });
  });

  step(S("the user rotates the tablet to a narrow window"), [](World& world, const Captures&, const Table&) {
    world.resize(kTablet.height(), kTablet.width());
  });

  step(S("the window narrows to a phone's width"), [](World& world, const Captures&, const Table&) {
    world.mc.part<Pointer>().wide = world.window().size();
    world.resize(400, world.window().height());
  });

  step(S("the window widens again"), [](World& world, const Captures&, const Table&) {
    const QSize wide = world.mc.part<Pointer>().wide;
    world.resize(wide.width(), wide.height());
  });

  step(S("%1 is still shown").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return oneAtATime(world, c[0]); }, [&] { return S("%1 alone in the narrow window; the screen says: %2").arg(c[0], screenTexts(world)); });
    const QVariantMap route = world.state(S("route")).toMap();
    expect(route.value(S("kind")) == QLatin1String("thread") && route.value(S("threadKey")).toString().endsWith(QLatin1Char(':') + world.thread),
           S("the route is %1").arg(show(route)));
  });

  step(S("%1 is shown side by side with the list").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return sideBySide(world, c[0]); }, [&] { return S("the list beside %1; the screen says: %2").arg(c[0], screenTexts(world)); });
  });

  step(S("%1 is shown").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return shownThread(world) == c[0]; }, [&] { return S("%1; the screen shows %2 and says: %3").arg(c[0], shownThread(world), screenTexts(world)); });
  });

  // Enough threads that the list does not fit the tablet's height.
  step(S("the thread list is longer than the window"), [](World& world, const Captures&, const Table&) {
    for (int index = 0; index < 24; ++index) haveThread(world, S("Chore %1").arg(index + 1));
    QQuickItem* list = rowList(world);
    world.waitFor([&] { return list->property("contentHeight").toReal() > list->height() + 200; },
                  [&] { return S("a list taller than its %1 pixels; it is %2").arg(list->height()).arg(list->property("contentHeight").toReal()); });
  });

  step(S("the user drags (a finger|the mouse) up the thread list"), [](World& world, const Captures& c, const Table&) {
    Pointer& pointer = world.mc.part<Pointer>();
    QQuickItem* list = rowList(world);
    world.sync();
    pointer.commands = world.mc.commands.size();
    const auto look = [&] { pointer.pickedUp = list->property("dragKey").toString(); };
    QQuickItem* row = threadRow(world, S("Chore 12"));
    if (c[0] == QLatin1String("a finger")) world.swipe(row, QPoint(0, -160), look);
    else world.drag(row, QPoint(0, -160), look);
  });

  step(S("the list scrolls"), [](World& world, const Captures&, const Table&) {
    QQuickItem* list = rowList(world);
    world.waitFor([&] { return list->property("contentY").toReal() > 0; }, S("the list to scroll; it is still at its top"));
    expect(world.mc.part<Pointer>().pickedUp.isEmpty(), S("the drag picked up %1 to arrange").arg(world.mc.part<Pointer>().pickedUp));
    world.sync();
    expect(world.mc.commands.size() == world.mc.part<Pointer>().commands, S("the drag changed something on the environment"));
  });

  step(S("the thread is picked up to be arranged"), [](World& world, const Captures&, const Table&) {
    expect(world.mc.part<Pointer>().pickedUp.endsWith(S(":") + haveThread(world, S("Chore 12"))), S("the list picked up \"%1\"").arg(world.mc.part<Pointer>().pickedUp));
    expect(rowList(world)->property("contentY").toReal() == 0, S("the list scrolled instead"));
  });

  step(S("the user holds a finger on %1 in the list").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    QQuickItem* row = threadRow(world, c[0]);
    world.mc.part<Pointer>().asked = row->mapToScene(QPointF(row->width() / 2, row->height() / 2));
    world.hold(row, [&] { return world.state(S("menu")).isValid() && !world.state(S("menu")).isNull(); }, S("the thread's menu"));
  });

  step(S("the user right-clicks %1 in the list").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    QQuickItem* row = threadRow(world, c[0]);
    world.mc.part<Pointer>().asked = row->mapToScene(QPointF(row->width() / 2, row->height() / 2));
    world.click(row, Qt::RightButton);
  });

  step(S("the user rests the mouse on %1 in the list").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    expect(world.find(S("settleAction")) == nullptr, S("the row's actions show before the pointer is on it"));
    world.hover(threadRow(world, c[0]));
  });

  step(S("the thread's actions are offered on its row"), [](World& world, const Captures&, const Table&) {
    QQuickItem* row = threadRow(world, S("Tax line"));
    world.waitFor([&] { return world.find(S("settleAction")) != nullptr && world.find(S("snoozeAction")) != nullptr; },
                  [&] { return S("the row to offer to settle and snooze; its thread is %1 and it shows actions: %2").arg(show(row->property("item"))).arg(row->property("showActions").toBool()); });
  });

  // The desktop's popup, its corner at the finger or the pointer, and not the phone layout's sheet.
  step(S("the thread's menu opens where it was asked for"), [](World& world, const Captures&, const Table&) {
    world.awaitPopup(S("contextMenu"));
    const QVariantMap menu = world.state(S("menu")).toMap();
    const QPointF asked = world.mc.part<Pointer>().asked;
    expect(!menu.value(S("items")).toList().isEmpty(), S("the menu offers nothing: %1").arg(show(menu)));
    expect(qAbs(menu.value(S("x")).toReal() - asked.x()) <= 2 && qAbs(menu.value(S("y")).toReal() - asked.y()) <= 2,
           S("the menu was asked for at %1,%2, not %3,%4").arg(menu.value(S("x")).toReal()).arg(menu.value(S("y")).toReal()).arg(asked.x()).arg(asked.y()));
    expect(world.find(S("phoneLayout")) == nullptr, S("the phone layout is showing"));
    const QString first = menu.value(S("items")).toList().constFirst().toMap().value(S("label")).toString();
    expect(world.shows(first), S("the menu's %1 is not on screen, which says: %2").arg(first, screenTexts(world)));
  });

  // In the field on screen and in what the app keeps of it.
  step(S("the composer still reads %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return world.item(S("input"))->property("text").toString() == c[0]; },
                  [&] { return S("the composer to read %1; it reads %2").arg(c[0], world.item(S("input"))->property("text").toString()); });
    expect(world.state(S("composer")).toMap().value(S("text")).toString() == c[0], S("the app keeps %1").arg(show(world.state(S("composer")).toMap().value(S("text")))));
  });

  step(S("a hardware keyboard is attached to a (tablet|phone)"), [](World& world, const Captures& c, const Table&) {
    const QSize size = c[0] == QLatin1String("tablet") ? kTablet : kPhone;
    world.resize(size.width(), size.height());
    pairWithEnvironment(world);
  });

  // What MobileApp does where HAL_C2_HAS_TERMINAL is not defined.
  step(S("the app was built without the terminal"), [](World& world, const Captures&, const Table&) {
    expect(!world.isOpen(), S("the app is already open"));
    world.mc.part<NoTerminal>();
    TerminalController::setSupported(false);
  });

  step(S("the thread has no terminal to open"), [](World& world, const Captures&, const Table&) {
    world.item(S("workspace"));
    expect(world.find(S("terminalToggle")) == nullptr, S("the header offers a terminal"));
    expect(!world.native().controller<TerminalController>()->available(), S("the thread has a place for terminals"));
  });

  // What a project action's key and its header button both dispatch.
  step(S("the user asks for a project action"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(S("workspace.runScript"), QVariantMap{{S("scriptId"), S("test")}});
    world.sync();
  });

  step(S("the user is told a screen this small has no terminal for it"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return show(world.state(S("toasts"))).contains(S("No terminal on a screen this small")); },
                  [&] { return S("the notice; the toasts are %1").arg(show(world.state(S("toasts")))); });
    for (const FakeMc::Rpc& call : std::as_const(world.mc.calls)) {
      expect(!call.method.startsWith(QLatin1String("terminal.")), S("the environment was asked for %1").arg(call.method));
    }
  });

  step(S("the terminal's key does nothing"), [](World& world, const Captures&, const Table&) {
    world.press(S("mod+j"));
    world.sync();
    expect(!world.native().controller<TerminalController>()->isOpen(), S("the terminal drawer counts as open"));
    expect(world.find(S("terminalTab")) == nullptr && world.find(S("HalC2Terminal")) == nullptr, S("a terminal is on screen, which says: %1").arg(screenTexts(world)));
    for (const FakeMc::Rpc& call : std::as_const(world.mc.calls)) {
      expect(!call.method.startsWith(QLatin1String("terminal.")), S("the environment was asked for %1").arg(call.method));
    }
    for (const QJsonObject& asked : std::as_const(world.mc.subscriptions)) {
      expect(!show(asked.toVariantMap()).contains(S("terminal")), S("the environment was asked to follow %1").arg(show(asked.toVariantMap())));
    }
  });

  step(S("the command palette lists no terminal command"), [](World& world, const Captures&, const Table&) {
    world.press(S("mod+k"));
    world.awaitPopup(S("commandPalette"));
    world.type(S(">terminal"));
    world.waitFor([&] { return palette(world)->query() == S(">terminal"); }, S("the palette to take the query"));
    for (int row = 0; row < palette(world)->count(); ++row) {
      expect(!palette(world)->idAt(row).startsWith(QLatin1String("terminal.")), S("the palette offers %1").arg(palette(world)->idAt(row)));
    }
  });

  step(S("the environment has no projects yet"), [](World& world, const Captures&, const Table&) {
    expect(!world.isOpen(), S("the app is already open"));
    world.mc.projects.clear();
    world.mc.threads.clear();
  });

  step(S("the user pairs a (tablet|phone) with it"), [](World& world, const Captures& c, const Table&) {
    const QSize size = c[0] == QLatin1String("tablet") ? kTablet : kPhone;
    world.resize(size.width(), size.height());
    pairWithEnvironment(world);
    world.sync();
  });

  // The desktop's first-run wizard, on its first step, with the environment to set up.
  step(S("the user is walked through setting it up"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.find(S("welcomeWizard")) != nullptr && world.shows(S("Connect your computers")); },
                  [&] { return S("the wizard; onboarding is %1 and the screen says: %2").arg(show(world.state(S("onboarding")).toMap().value(S("gate"))), screenTexts(world)); });
    expect(world.shows(world.mc.label), S("the wizard does not offer %1; the screen says: %2").arg(world.mc.label, screenTexts(world)));
  });

  step(S("the user is told projects are added on the environment's machine"), [](World& world, const Captures&, const Table&) {
    expect(world.item(S("noProjectsHint"))->property("text").toString().contains(S("Add a project in HAL-C2 on the environment's machine")),
           S("the screen says: %1").arg(screenTexts(world)));
    expect(world.find(S("welcomeWizard")) == nullptr, S("the desktop's wizard covers the phone layout"));
  });

  step(S("the user presses Cmd-([A-Za-z0-9])"), [](World& world, const Captures& c, const Table&) { world.press(S("mod+") + c[0].toLower()); });

  step(S("the command palette opens"), [](World& world, const Captures&, const Table&) {
    world.awaitPopup(S("commandPalette"));
    expect(world.item(S("commandPaletteSearch"))->hasActiveFocus(), S("the palette's field does not have the keyboard"));
  });

  // The palette is the search: a thread's title typed there finds it, and Return opens it.
  step(S("the user can search the thread list"), [](World& world, const Captures&, const Table&) {
    world.awaitPopup(S("commandPalette"));
    expect(world.item(S("commandPaletteSearch"))->hasActiveFocus(), S("the palette's field does not have the keyboard"));
    world.type(S("Tax"));
    const auto found = [&] { return palette(world)->count() > 0 && palette(world)->kindAt(palette(world)->highlighted()) == QLatin1String("thread"); };
    world.waitFor(found, [&] { return S("the thread among the results; the screen says: %1").arg(screenTexts(world)); });
    world.press(S("Return"));
    world.waitFor([&] { return shownThread(world) == S("Tax line"); }, [&] { return S("the thread found to open; the screen says: %1").arg(screenTexts(world)); });
  });

  step(S("the command palette is open"), [](World& world, const Captures&, const Table&) {
    pairWithEnvironment(world);
    world.press(S("mod+k"));
    world.awaitPopup(S("commandPalette"));
  });

  step(S("the user presses Down and then Return"), [](World& world, const Captures&, const Table&) {
    PaletteRun& run = world.mc.part<PaletteRun>();
    expect(palette(world)->count() > 1 && palette(world)->highlighted() == 0, S("the palette lists %1 entries").arg(palette(world)->count()));
    run.kind = palette(world)->kindAt(1);
    run.id = palette(world)->idAt(1);
    QObject::connect(world.native().controller<KeybindingController>()->commands(), &CommandRegistry::ran, &world.native(),
                     [&run](const QString& command) { run.commands.append(command); });
    world.press(S("Down"));
    expect(palette(world)->highlighted() == 1, S("Down highlighted entry %1").arg(palette(world)->highlighted()));
    world.press(S("Return"));
  });

  step(S("the second entry runs"), [](World& world, const Captures&, const Table&) {
    const PaletteRun& run = world.mc.part<PaletteRun>();
    if (run.kind == QLatin1String("action")) {
      world.waitFor([&] { return run.commands.contains(run.id); }, [&] { return S("the command %1 to run; ran: %2").arg(run.id, run.commands.join(S(", "))); });
    } else if (run.kind == QLatin1String("thread")) {
      world.waitFor([&] { return world.state(S("route")).toMap().value(S("threadKey")) == run.id; }, [&] { return S("the thread %1 to open").arg(run.id); });
    } else {
      fail(S("the second entry is a %1, which this step cannot tell ran").arg(run.kind));
    }
  });

  step(S("the user opens the palette again and presses Escape"), [](World& world, const Captures&, const Table&) {
    // An entry with choices of its own left the palette up, on them: its key puts it away first.
    if (palette(world)->isOpen()) {
      world.press(S("mod+k"));
      world.awaitPopup(S("commandPalette"), false);
    }
    world.press(S("mod+k"));
    world.awaitPopup(S("commandPalette"));
    world.press(S("Escape"));
  });

  step(S("the command palette is closed"), [](World& world, const Captures&, const Table&) {
    world.awaitPopup(S("commandPalette"), false);
    expect(!palette(world)->isOpen(), S("the palette still counts as open"));
  });

  step(S("the user types %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) { world.type(c[0]); });

  step(S("only actions are listed"), [](World& world, const Captures&, const Table&) {
    expect(world.item(S("commandPaletteSearch"))->property("text").toString() == S(">"), S("the field reads %1").arg(world.item(S("commandPaletteSearch"))->property("text").toString()));
    const auto kinds = [&] {
      QStringList found;
      for (int row = 0; row < palette(world)->count(); ++row) found.append(palette(world)->kindAt(row));
      found.removeDuplicates();
      return found;
    };
    world.waitFor([&] { return kinds() == QStringList{S("action")}; }, [&] { return S("only actions; the palette lists %1").arg(kinds().join(S(", "))); });
    // And none of the threads it listed before the sign.
    expect(!world.findWhere([](QQuickItem* candidate) { return candidate->property("runnable").isValid() && candidate->property("title").toString() == QLatin1String("Tax line"); }),
           S("a thread is still listed; the screen says: %1").arg(screenTexts(world)));
  });

  // Newest first is the list's order: each is made a minute older than the one before.
  step(S("the sidebar lists %1, %1 and %1 in that order").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    for (int index = 0; index < c.size(); ++index) {
      const QString id = S("ordered-%1").arg(index + 1);
      const QString at = S("2026-09-24T10:0%1:00Z").arg(9 - index);
      world.mc.threads.insert(id, {{S("id"), id}, {S("title"), c[index]}, {S("projectId"), S("shop")}, {S("createdAt"), at}, {S("updatedAt"), at}});
      world.mc.sendRow(id, world.mc.threads.value(id));
    }
    world.waitFor([&] { return listedThreads(world).mid(0, c.size()) == c; }, [&] { return S("%1 first in the list; it has %2").arg(c.join(S(", ")), listedThreads(world).join(S(", "))); });
  });
});

}  // namespace
