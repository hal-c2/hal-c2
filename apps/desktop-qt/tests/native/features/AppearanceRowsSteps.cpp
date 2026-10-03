// The Settings → Appearance rows that change how the thread is drawn
// (features/navigation/appearance.feature): the composer's context strip
// after a thread starts, and word wrap in code, tables, diffs and file previews.

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
