// The header strip as the desktop draws it (qml/HalC2/Bricks/Workspace.qml)
// over the scenario's shell (navigation/layout.feature's header): the brick is
// loaded into an offscreen window, laid out at a width and read, then thrown
// away, so nothing QML outlives a step.

#include <QCoreApplication>
#include <QJsonObject>
#include <QQuickItem>
#include <cmath>

#include "LayoutController.h"

#include "Brick.h"
#include "Harness.h"
#include "Stream.h"
#include "World.h"

namespace {

using namespace stream;

const QString kLongTitle = QStringLiteral("Move the checkout of every thread onto the MC that owns its project, keeping the agent's session");

// The width the header is laid out at, set by the "When" steps.
int headerWidth = 0;

// The header's thread title laid out at `headerWidth`: {text, truncated, width}.
struct Title {
  QString text;
  bool truncated = false;
  qreal width = 0;
};

Title layOutTitle(World& world) {
  Brick header(world, "import QtQuick\nimport HalC2.Bricks\nWorkspace { height: 52 }\n", QSize(headerWidth, 52));
  QQuickItem* label = header.item(QStringLiteral("threadLabel"));
  // Layouts settle on the window's polish, before its next frame.
  world.waitFor([&] { return label->width() > 0 && label->property("text").toString() != QLatin1String("No thread"); },
                QStringLiteral("the header to lay out the thread title"));
  header.window().contentItem()->polish();
  QCoreApplication::processEvents();
  return {label->property("text").toString(), label->property("truncated").toBool(), label->width()};
}

// How much room the header has for its actions, set by the "When" steps:
// a width, or just too little for their labels or their icons.
enum class Fit { Width, NoLabels, NoIcons };
Fit headerFit = Fit::Width;

// The header's run and open actions laid out at `headerFit`.
struct Actions {
  QString run;
  QString open;
  bool pills = false;
  bool project = false;
  QStringList overflow;
};

Actions layOutActions(World& world) {
  Brick header(world, "import QtQuick\nimport HalC2.Bricks\nWorkspace { height: 52 }\n", QSize(1600, 52));
  QQuickItem* strip = header.root();
  world.waitFor([&] { return strip->property("hasScripts").toBool() && strip->property("hasEditors").toBool(); },
                [&] { return QStringLiteral("the header to have actions and editors: %1").arg(show(world.state(QStringLiteral("workspace")))); });
  // `room` is the strip less its margins; one pixel short of a level's need.
  const qreal margins = strip->width() - strip->property("room").toReal();
  if (headerFit == Fit::Width) strip->setWidth(headerWidth);
  if (headerFit == Fit::NoLabels) strip->setWidth(std::ceil(strip->property("labelledNeed").toReal() + margins) - 1);
  if (headerFit == Fit::NoIcons) strip->setWidth(std::ceil(strip->property("iconNeed").toReal() + margins) - 1);
  header.window().contentItem()->polish();
  QCoreApplication::processEvents();
  Actions actions;
  QQuickItem* run = header.item(QStringLiteral("runActionButton"));
  QQuickItem* open = header.item(QStringLiteral("openEditorButton"));
  actions.pills = run->isVisible() && open->isVisible();
  actions.project = header.item(QStringLiteral("projectLabel"))->isVisible();
  actions.run = run->findChild<QQuickItem*>(QStringLiteral("splitAction"))->property("text").toString();
  actions.open = open->findChild<QQuickItem*>(QStringLiteral("splitAction"))->property("text").toString();
  if (header.item(QStringLiteral("headerOverflow"))->isVisible()) {
    // A closed menu's entries are not visible: open it, as a click on the button does.
    QObject* menu = strip->findChild<QObject*>(QStringLiteral("headerOverflowMenu"));
    if (menu) QMetaObject::invokeMethod(menu, "open");
    QCoreApplication::processEvents();
    for (int i = 0; menu && i < menu->property("count").toInt(); ++i) {
      QQuickItem* entry = nullptr;
      QMetaObject::invokeMethod(menu, "itemAt", Q_RETURN_ARG(QQuickItem*, entry), Q_ARG(int, i));
      if (entry && entry->isVisible()) actions.overflow << entry->property("text").toString();
    }
    if (menu) QMetaObject::invokeMethod(menu, "close");
  }
  return actions;
}

QString describe(const Actions& actions) {
  return QStringLiteral("the header shows run \"%1\" and open \"%2\" (pills shown: %3, project shown: %4), its overflow menu [%5]")
      .arg(actions.run, actions.open)
      .arg(actions.pills)
      .arg(actions.project)
      .arg(actions.overflow.join(u", "));
}

const Steps steps([] {
  Brick::registerSingletons();
  step(QStringLiteral("a long thread title"), [](World& world, const Captures&, const Table&) {
    // The thread the background looks at, renamed.
    QJsonObject row = world.mc.threads.value(kThread);
    row.insert(QStringLiteral("title"), kLongTitle);
    world.mc.threads.insert(kThread, row);
    world.mc.sendRow(kThread, row);
    world.waitFor([&] { return at(world.state(QStringLiteral("workspace")), QStringLiteral("threadTitle")) == kLongTitle; },
                  [&] { return QStringLiteral("the header to show the long title; it shows %1").arg(show(world.state(QStringLiteral("workspace")))); });
  });
  step(QStringLiteral("the window is wide"), [](World&, const Captures&, const Table&) {
    headerFit = Fit::Width;
    headerWidth = 1600;
  });
  step(QStringLiteral("the header is as wide as a 900 pixel window leaves it"), [](World&, const Captures&, const Table&) {
    // Beside the sidebar at its default width and the border between them.
    headerFit = Fit::Width;
    headerWidth = 900 - LayoutController::kSidebarWidth - 1;
  });
  step(QStringLiteral("the header has no room for its actions' labels"), [](World&, const Captures&, const Table&) { headerFit = Fit::NoLabels; });
  step(QStringLiteral("the header has no room for its actions as icons"), [](World&, const Captures&, const Table&) { headerFit = Fit::NoIcons; });
  step(QStringLiteral("the header actions show with their labels"), [](World& world, const Captures&, const Table&) {
    const Actions actions = layOutActions(world);
    expect(actions.pills && actions.run.startsWith(QStringLiteral("Run ")) && actions.open == QStringLiteral("Open") && actions.overflow.isEmpty(), describe(actions));
  });
  step(QStringLiteral("the header actions show without their labels"), [](World& world, const Captures&, const Table&) {
    const Actions actions = layOutActions(world);
    expect(actions.pills && actions.run.isEmpty() && actions.open.isEmpty() && actions.overflow.isEmpty(), describe(actions));
  });
  step(QStringLiteral("the header shows the project's name"), [](World& world, const Captures&, const Table&) {
    const Actions actions = layOutActions(world);
    expect(actions.project, describe(actions));
  });
  step(QStringLiteral("the header leaves the project's name out"), [](World& world, const Captures&, const Table&) {
    const Actions actions = layOutActions(world);
    expect(!actions.project, describe(actions));
  });
  step(QStringLiteral("the header's %1 menu runs %1 and opens in %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    const Actions actions = layOutActions(world);
    expect(!actions.pills && actions.overflow.contains(QStringLiteral("Run %1").arg(c[1])) && actions.overflow.contains(QStringLiteral("Open in %1").arg(c[2])),
           describe(actions));
  });
  step(QStringLiteral("the header is narrow"), [](World&, const Captures&, const Table&) {
    headerFit = Fit::Width;
    headerWidth = 480;
  });
  step(QStringLiteral("the whole title is shown"), [](World& world, const Captures&, const Table&) {
    const Title title = layOutTitle(world);
    expect(title.text == kLongTitle && !title.truncated, QStringLiteral("the header shows \"%1\" (shortened: %2)").arg(title.text).arg(title.truncated));
  });
  step(QStringLiteral("the title is shortened with an ellipsis"), [](World& world, const Captures&, const Table&) {
    const Title title = layOutTitle(world);
    expect(title.text == kLongTitle && title.truncated, QStringLiteral("the header shows \"%1\" (shortened: %2)").arg(title.text).arg(title.truncated));
  });
  step(QStringLiteral("the start of the title still shows"), [](World& world, const Captures&, const Table&) {
    // Room for a few letters, not a bare ellipsis (40 px).
    const Title title = layOutTitle(world);
    expect(title.width >= 40, QStringLiteral("the title has %1 px").arg(title.width));
  });
});

}  // namespace
