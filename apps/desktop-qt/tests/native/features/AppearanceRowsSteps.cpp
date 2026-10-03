// The Settings → Appearance rows that change how the thread is drawn
// (features/navigation/appearance.feature): the composer's context strip
// after a thread starts, and word wrap in code, tables, diffs and file previews.

#include <QFont>
#include <QJsonArray>
#include <QTest>

#include "Brick.h"
#include "Harness.h"
#include "NavigationController.h"
#include "RightPanelController.h"
#include "SettingsController.h"
#include "World.h"

namespace {

SettingsController* settings(World& world) {
  return world.native().controller<SettingsController>();
}

void set(World& world, const QString& key, const QVariant& value) {
  settings(world)->set(key, value);
  world.waitFor([&] { return settings(world)->setting(key) == value; }, QStringLiteral("%1 to be saved").arg(key));
}

QVariantMap composer(World& world) {
  return world.state(QStringLiteral("composer")).toMap();
}

const QString kContext = QStringLiteral("persistComposerContextStrip");
const QString kWrap = QStringLiteral("wordWrap");

// Whether the composer shows the strip, once the window is on the thread.
bool stripShown(World& world) {
  world.sync();
  expect(at(world.state(QStringLiteral("route")), QStringLiteral("kind")) == QLatin1String("thread") &&
             composer(world).value(QStringLiteral("routeKind")) == QLatin1String("server"),
         QStringLiteral("the route is %1, the composer %2").arg(show(world.state(QStringLiteral("route"))), show(composer(world).value(QStringLiteral("routeKind")))));
  return composer(world).value(QStringLiteral("showContextStrip")).toBool();
}

const Steps steps([] {
  Brick::registerSingletons();

  step(QStringLiteral("the user turned on composer context"), [](World& world, const Captures&, const Table&) { set(world, kContext, true); });
  step(QStringLiteral("composer context is off"), [](World& world, const Captures&, const Table&) {
    expect(!settings(world)->setting(kContext).toBool() && settings(world)->isDefault(kContext), QStringLiteral("composer context is on"));
  });
  step(QStringLiteral("the user sends the first message in a new thread"), [](World& world, const Captures&, const Table&) {
    world.mc.projects.insert(QStringLiteral("shop"), {{QStringLiteral("id"), QStringLiteral("shop")}, {QStringLiteral("title"), QStringLiteral("shop")},
                                                       {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")}, {QStringLiteral("scripts"), QJsonArray()}});
    world.mc.sendRow(QStringLiteral("shop"), world.mc.projects.value(QStringLiteral("shop")), QStringLiteral("project"));
    world.sync();
    auto* navigation = world.native().controller<NavigationController>();
    if (navigation->route().kind != QLatin1String("draft")) world.startNewThread(QVariantMap{{QStringLiteral("projectKey"), world.projectKey(QStringLiteral("shop"))}});
    world.waitFor([&] { return navigation->route().kind == QLatin1String("draft") && composer(world).value(QStringLiteral("routeKind")) == QLatin1String("draft"); },
                  [&] { return QStringLiteral("a new thread; the route is %1").arg(show(world.state(QStringLiteral("route")))); });
    // A new thread always shows where it will run.
    expect(composer(world).value(QStringLiteral("showContextStrip")).toBool(), show(composer(world)));
    world.bridge().dispatch(QStringLiteral("composer.submit"),
                            QVariantMap{{QStringLiteral("text"), QStringLiteral("Add tax to the cart")}, {QStringLiteral("intent"), QStringLiteral("foreground")}});
    world.waitFor([&] { return navigation->route().kind == QLatin1String("thread"); },
                  [&] { return QStringLiteral("the thread to start; the route is %1").arg(show(world.state(QStringLiteral("route")))); });
  });
  step(QStringLiteral("branch and worktree controls stay visible below the composer"), [](World& world, const Captures&, const Table&) {
    expect(stripShown(world), show(composer(world)));
  });
  step(QStringLiteral("branch and worktree controls are hidden"), [](World& world, const Captures&, const Table&) {
    expect(!stripShown(world), show(composer(world)));
  });

  // Fonts: each part of the app has its family and size.
  struct Font {
    const char* family;
    const char* size;
  };
  static const QHash<QString, Font> fonts{{QStringLiteral("interface"), {"fontFamilySans", "fontSizeInterface"}},
                                          {QStringLiteral("prompt"), {"fontFamilyComposer", "fontSizePrompt"}},
                                          {QStringLiteral("code"), {"fontFamilyCode", "fontSizeCode"}},
                                          {QStringLiteral("terminal"), {"fontFamilyTerminal", "fontSizeTerminal"}}};
  step(QStringLiteral("the user sets the (interface|prompt|code|terminal) font to %1 at (\\d+)").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    const Font font = fonts.value(c[0]);
    set(world, QLatin1String(font.family), c[1]);
    set(world, QLatin1String(font.size), c[2].toInt());
  });
  const auto fontOf = [](Brick& brick, const QString& objectName) { return brick.item(objectName)->property("font").value<QFont>(); };
  // The parts the row leaves alone keep the theme's fonts and their own sizes.
  const auto untouched = [](World& world, const QStringList& parts) {
    ThemeStore& theme = world.theme();
    const QString ui = theme.fontUi(), mono = theme.fontMono();
    for (const QString& part : parts) {
      const bool same = part == QLatin1String("interface") ? theme.fontScale() == 1.0 && ui != QLatin1String("Inter")
                        : part == QLatin1String("prompt")  ? theme.fontSizePrompt() == 14 && theme.fontPrompt() == ui
                        : part == QLatin1String("code")    ? theme.fontSizeCode() == 13 && mono != QLatin1String("JetBrains Mono")
                                                           : theme.fontSizeTerminal() == 12 && theme.fontTerminal() == mono;
      expect(same, QStringLiteral("the %1 font changed too").arg(part));
    }
  };
  step(QStringLiteral("everything outside code and the terminal uses %1 at (\\d+)").arg(kQuoted), [fontOf, untouched](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return world.theme().fontUi() == c[0]; }, QStringLiteral("the interface font"));
    expect(world.theme().fontScale() == c[1].toInt() / 16.0, QStringLiteral("the interface is scaled by %1").arg(world.theme().fontScale()));
    // A control and a message's prose, as the bricks draw them: their own size, scaled.
    Brick brick(world, "import QtQuick\nimport HalC2.Bricks\nItem { ShellTextField { objectName: \"field\" }\n"
                       "Markdown { objectName: \"message\"; y: 60; width: 400; text: \"Hello\" } }\n", QSize(400, 200));
    const QFont field = fontOf(brick, QStringLiteral("field"));
    expect(field.family() == c[0] && field.pixelSize() == qRound(13 * c[1].toInt() / 16.0),
           QStringLiteral("a field writes in %1 at %2").arg(field.family()).arg(field.pixelSize()));
    world.waitFor([&] { brick.grab(); return brick.item(QStringLiteral("message"))->property("segmentCount").toInt() >= 1; }, QStringLiteral("the message to be drawn"));
    const QFont prose = fontOf(brick, QStringLiteral("markdownProse"));
    expect(prose.family() == c[0] && prose.pixelSize() == qRound(14 * c[1].toInt() / 16.0),
           QStringLiteral("prose is in %1 at %2").arg(prose.family()).arg(prose.pixelSize()));
    untouched(world, {QStringLiteral("code"), QStringLiteral("terminal")});
  });
  step(QStringLiteral("the composer uses %1 at (\\d+)").arg(kQuoted), [fontOf, untouched](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return world.theme().fontPrompt() == c[0] && world.theme().fontSizePrompt() == c[1].toInt(); }, QStringLiteral("the prompt font"));
    Brick brick(world, "import QtQuick\nimport HalC2.Bricks\nComposer { width: 700 }\n", QSize(700, 400));
    const QFont input = fontOf(brick, QStringLiteral("input"));
    expect(input.family() == c[0] && input.pixelSize() == c[1].toInt(), QStringLiteral("the prompt is in %1 at %2").arg(input.family()).arg(input.pixelSize()));
    untouched(world, {QStringLiteral("interface"), QStringLiteral("code"), QStringLiteral("terminal")});
  });
  step(QStringLiteral("code blocks and diffs uses %1 at (\\d+)").arg(kQuoted), [fontOf, untouched](World& world, const Captures& c, const Table&) {
    // Diffs and file previews draw in Theme.fontMono at Theme.fontSizeCode.
    world.waitFor([&] { return world.theme().fontMono() == c[0] && world.theme().fontSizeCode() == c[1].toInt(); }, QStringLiteral("the code font"));
    Brick brick(world, "import QtQuick\nimport HalC2.Bricks\nMarkdown { width: 560; text: \"```\\nconst total = 1;\\n```\\n\" }\n", QSize(560, 300));
    world.waitFor([&] { brick.grab(); return brick.root()->property("segmentCount").toInt() >= 1; }, QStringLiteral("the code block to be drawn"));
    const QFont code = fontOf(brick, QStringLiteral("codeText"));
    expect(code.family() == c[0] && code.pixelSize() == c[1].toInt(), QStringLiteral("code is in %1 at %2").arg(code.family()).arg(code.pixelSize()));
    untouched(world, {QStringLiteral("interface"), QStringLiteral("prompt")});
    // The terminal follows the code font until it has its own.
    expect(world.theme().fontTerminal() == c[0], QStringLiteral("the terminal is in %1").arg(world.theme().fontTerminal()));
  });
  step(QStringLiteral("the terminal uses %1 at (\\d+)").arg(kQuoted), [untouched](World& world, const Captures& c, const Table&) {
    // The terminals (TerminalSplits and the sign-in ones) draw in Theme.fontTerminal at Theme.fontSizeTerminal.
    world.waitFor([&] { return world.theme().fontTerminal() == c[0] && world.theme().fontSizeTerminal() == c[1].toInt(); },
                  [&] { return QStringLiteral("the terminal font; it is %1 at %2").arg(world.theme().fontTerminal()).arg(world.theme().fontSizeTerminal()); });
    untouched(world, {QStringLiteral("interface"), QStringLiteral("prompt"), QStringLiteral("code")});
  });

  step(QStringLiteral("the user turns on word wrap"), [](World& world, const Captures&, const Table&) {
    set(world, kWrap, false);
    auto* panel = world.native().controller<RightPanelController>();
    expect(!panel->diff()->wrap() && !panel->files()->wrap(), QStringLiteral("diffs or file previews wrap with word wrap off"));
    set(world, kWrap, true);
  });
  step(QStringLiteral("long lines in code blocks, tables, diffs and file previews wrap instead of scrolling"), [](World& world, const Captures&, const Table&) {
    auto* panel = world.native().controller<RightPanelController>();
    expect(panel->diff()->wrap() && panel->files()->wrap(),
           QStringLiteral("diffs wrap: %1, file previews wrap: %2").arg(panel->diff()->wrap()).arg(panel->files()->wrap()));
    // Code blocks and tables, as the timeline draws a message.
    const QByteArray qml = "import QtQuick\nimport HalC2.Bricks\n"
                           "Markdown { width: 560; text: \"```\\nconst total = price + tax;\\n```\\n\\n| a | b |\\n| - | - |\\n| 1 | 2 |\\n\" }\n";
    Brick message(world, qml, QSize(560, 400));
    world.waitFor([&] { message.grab(); return message.root()->property("segmentCount").toInt() >= 2; }, QStringLiteral("the message to be drawn"));
    expect(message.item(QStringLiteral("markdownCode"))->property("wrapped").toBool() &&
               message.item(QStringLiteral("markdownTable"))->property("expanded").toBool(),
           QStringLiteral("the code block or the table does not wrap"));
    // And none of them with it off.
    set(world, kWrap, false);
    Brick unwrapped(world, qml, QSize(560, 400));
    world.waitFor([&] { unwrapped.grab(); return unwrapped.root()->property("segmentCount").toInt() >= 2; }, QStringLiteral("the message to be drawn"));
    expect(!unwrapped.item(QStringLiteral("markdownCode"))->property("wrapped").toBool() &&
               !unwrapped.item(QStringLiteral("markdownTable"))->property("expanded").toBool() && !panel->diff()->wrap() && !panel->files()->wrap(),
           QStringLiteral("something still wraps with word wrap off"));
  });
});

}  // namespace
