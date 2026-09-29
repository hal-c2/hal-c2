// The header strip as the desktop draws it (qml/HalC2/Bricks/Workspace.qml)
// over the scenario's shell (navigation/layout.feature's header): the brick is
// loaded into an offscreen window, laid out at a width and read, then thrown
// away, so nothing QML outlives a step.

#include <QJSEngine>
#include <QJsonObject>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickWindow>

#include "Harness.h"
#include "Stream.h"
#include "TerminalController.h"
#include "World.h"

namespace {

using namespace stream;

const QString kLongTitle = QStringLiteral("Move the checkout of every thread onto the node that owns its project, keeping the agent's session");

// The width the header is laid out at, set by the "When" steps.
int headerWidth = 0;

// What the brick's singletons (Shell, Theme, Terminals) resolve to: this
// step's shell. Registered once; each engine asks when it first needs them.
World* current = nullptr;

QObject* owned(QJSEngine* engine, QObject* object) {
  engine->setObjectOwnership(object, QJSEngine::CppOwnership);
  return object;
}

void registerSingletons() {
  static const bool registered = [] {
    qmlRegisterSingletonType<QObject>("HalC2.Shell", 1, 0, "Shell", [](QQmlEngine*, QJSEngine* engine) { return owned(engine, &current->bridge()); });
    qmlRegisterSingletonType<QObject>("HalC2.Shell", 1, 0, "Theme", [](QQmlEngine*, QJSEngine* engine) { return owned(engine, &current->theme()); });
    qmlRegisterSingletonType<QObject>("HalC2.Shell", 1, 0, "Terminals", [](QQmlEngine*, QJSEngine* engine) {
      return owned(engine, current->native().controller<TerminalController>());
    });
    return true;
  }();
  Q_UNUSED(registered);
}

// The header's thread title laid out at `headerWidth`: {text, truncated}.
struct Title {
  QString text;
  bool truncated = false;
};

Title layOutTitle(World& world) {
  current = &world;
  registerSingletons();
  QQmlEngine engine;
  engine.addImportPath(QStringLiteral(HAL_C2_QML_DIR));
  QQmlComponent component(&engine);
  component.setData("import QtQuick\nimport HalC2.Bricks\nWorkspace { height: 52 }\n", QUrl(QStringLiteral("file:///header.qml")));
  expect(component.isReady(), component.errorString());
  QQuickWindow window;
  window.resize(headerWidth, 52);
  std::unique_ptr<QQuickItem> header(qobject_cast<QQuickItem*>(component.create()));
  expect(header != nullptr, QStringLiteral("the header did not load: %1").arg(component.errorString()));
  header->setParentItem(window.contentItem());
  header->setWidth(headerWidth);
  window.show();
  QQuickItem* label = header->findChild<QQuickItem*>(QStringLiteral("threadLabel"));
  expect(label != nullptr, QStringLiteral("the header has no thread title"));
  // Layouts settle on the window's polish, before its next frame.
  world.waitFor([&] { return label->width() > 0 && label->property("text").toString() != QLatin1String("No thread"); },
                QStringLiteral("the header to lay out the thread title"));
  window.contentItem()->polish();
  QCoreApplication::processEvents();
  Title title{label->property("text").toString(), label->property("truncated").toBool()};
  header.reset();
  current = nullptr;
  return title;
}

const Steps steps([] {
  step(QStringLiteral("a long thread title"), [](World& world, const Captures&, const Table&) {
    // The thread the background looks at, renamed.
    QJsonObject row = world.node.threads.value(kThread);
    row.insert(QStringLiteral("title"), kLongTitle);
    world.node.threads.insert(kThread, row);
    world.node.sendRow(kThread, row);
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
});

}  // namespace
