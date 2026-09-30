#include "Brick.h"

#include <QJSEngine>
#include <QQmlComponent>
#include <QTest>

#include "Harness.h"
#include "TerminalController.h"
#include "World.h"

namespace {

// What the bricks' singletons resolve to: the world that loaded the brick.
// Registered once; each engine asks when it first needs them.
World* current = nullptr;

QObject* owned(QJSEngine* engine, QObject* object) {
  if (object) engine->setObjectOwnership(object, QJSEngine::CppOwnership);
  return object;
}

}  // namespace

void Brick::registerSingletons() {
  static const bool registered = [] {
    // As ShellRuntime's: whichever registration QML uses, an engine's Shell
    // and Theme are the ones it names.
    qmlRegisterSingletonType<QObject>("HalC2.Shell", 1, 0, "Shell", [](QQmlEngine* qml, QJSEngine* engine) {
      return owned(engine, qml->property("halC2Bridge").value<QObject*>());
    });
    qmlRegisterSingletonType<QObject>("HalC2.Shell", 1, 0, "Theme", [](QQmlEngine* qml, QJSEngine* engine) {
      return owned(engine, qml->property("halC2Theme").value<QObject*>());
    });
    qmlRegisterSingletonType<QObject>("HalC2.Shell", 1, 0, "Terminals", [](QQmlEngine*, QJSEngine* engine) {
      return owned(engine, current->native().controller<TerminalController>());
    });
    return true;
  }();
  Q_UNUSED(registered);
}

namespace {

// Repeater's delegates are only the item tree's children, not QObject children.
QQuickItem* findItem(QQuickItem* item, const QString& objectName) {
  if (item->objectName() == objectName) return item;
  for (QQuickItem* child : item->childItems()) {
    if (QQuickItem* found = findItem(child, objectName)) return found;
  }
  return nullptr;
}

}  // namespace

Brick::Brick(World& world, const QByteArray& qml, const QSize& size) {
  current = &world;
  registerSingletons();
  m_engine.setProperty("halC2Bridge", QVariant::fromValue(static_cast<QObject*>(&world.bridge())));
  m_engine.setProperty("halC2Theme", QVariant::fromValue(static_cast<QObject*>(&world.theme())));
  m_engine.addImportPath(QStringLiteral(HAL_C2_QML_DIR));
  QQmlComponent component(&m_engine);
  component.setData(qml, QUrl(QStringLiteral("file:///brick.qml")));
  expect(component.isReady(), component.errorString());
  m_root.reset(qobject_cast<QQuickItem*>(component.create()));
  expect(m_root != nullptr, QStringLiteral("the brick did not load: %1").arg(component.errorString()));
  m_window.resize(size);
  m_root->setParentItem(m_window.contentItem());
  m_root->setSize(size);
  m_window.show();
  m_window.requestActivate();
}

Brick::~Brick() {
  m_root.reset();
  current = nullptr;
}

QQuickItem* Brick::item(const QString& objectName) const {
  QQuickItem* found = findItem(m_root.get(), objectName);
  expect(found != nullptr, QStringLiteral("the brick has no %1").arg(objectName));
  return found;
}

QPoint Brick::at(const QQuickItem* item, double fx, double fy) {
  // Positioners and anchors settle on the window's polish: drawing a frame
  // runs it, so the point is where the user would see the item now.
  m_window.grabWindow();
  return item->mapToScene(QPointF(item->width() * fx, item->height() * fy)).toPoint();
}

void Brick::click(const QString& objectName) {
  QQuickItem* button = item(objectName);
  expect(button->isVisible() && button->isEnabled(), QStringLiteral("%1 cannot be clicked (visible %2, enabled %3)")
                                                         .arg(objectName)
                                                         .arg(button->isVisible())
                                                         .arg(button->isEnabled()));
  QTest::mouseClick(&m_window, Qt::LeftButton, Qt::NoModifier, at(button));
}

QImage Brick::grab() {
  return m_window.grabWindow();
}
