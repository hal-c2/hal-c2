// The header strip as the desktop draws it (qml/HalC2/Bricks/Workspace.qml)
// over the scenario's shell (navigation/layout.feature's header): the brick is
// loaded into an offscreen window, laid out at a width and read, then thrown
// away, so nothing QML outlives a step.

#include <QCoreApplication>
#include <QJsonObject>

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
  step(QStringLiteral("the window is wide"), [](World&, const Captures&, const Table&) { headerWidth = 1600; });
  step(QStringLiteral("the header is narrow"), [](World&, const Captures&, const Table&) { headerWidth = 480; });
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
