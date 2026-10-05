#include "Brick.h"

#include <QCoreApplication>
#include <QJSEngine>
#include <QKeyEvent>
#include <QQmlComponent>
#include <QTest>

#include "Harness.h"
#include "SettingsController.h"
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
  // The controllers' own (Settings, Terminals, Keybindings, Themes...), as main.cpp does.
  world.native().registerQmlSingletons();
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
  // From the window: a popup's items are the overlay's, beside the brick.
  QQuickItem* found = findItem(m_window.contentItem(), objectName);
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

namespace {

bool showsText(const QQuickItem* item, const QString& text) {
  if (!item->isVisible()) return false;
  if (item->property("text").toString() == text) return true;
  for (const QQuickItem* child : item->childItems()) {
    if (showsText(child, text)) return true;
  }
  return false;
}

}  // namespace

bool Brick::shows(const QString& text) const {
  // Popups and dialogs are the overlay's, beside the brick.
  return showsText(m_window.contentItem(), text);
}

bool Brick::press(const QString& key) {
  static const QHash<QString, Qt::Key> named{
      {QStringLiteral("escape"), Qt::Key_Escape}, {QStringLiteral("esc"), Qt::Key_Escape},
      {QStringLiteral("enter"), Qt::Key_Return},  {QStringLiteral("space"), Qt::Key_Space},
      {QStringLiteral("tab"), Qt::Key_Tab},       {QStringLiteral("backspace"), Qt::Key_Backspace},
      {QStringLiteral("up"), Qt::Key_Up},         {QStringLiteral("arrowup"), Qt::Key_Up},
      {QStringLiteral("down"), Qt::Key_Down},     {QStringLiteral("arrowdown"), Qt::Key_Down},
      {QStringLiteral("left"), Qt::Key_Left},     {QStringLiteral("arrowleft"), Qt::Key_Left},
      {QStringLiteral("right"), Qt::Key_Right},   {QStringLiteral("arrowright"), Qt::Key_Right},
      {QStringLiteral("home"), Qt::Key_Home},     {QStringLiteral("end"), Qt::Key_End},
  };
  Qt::KeyboardModifiers modifiers;
  int code = 0;
  // A key the scenario quotes ("/") is the key itself.
  const bool quoted = key.size() == 3 && key.startsWith(QLatin1Char('"')) && key.endsWith(QLatin1Char('"'));
  for (const QString& token : quoted ? QStringList{key.mid(1, 1)} : key.toLower().split(QLatin1Char('+'))) {
    if (token == QLatin1String("mod")) {
      modifiers |= Qt::ControlModifier;
    } else if (token == QLatin1String("ctrl")) {
#ifdef Q_OS_MACOS
      modifiers |= Qt::MetaModifier;
#else
      modifiers |= Qt::ControlModifier;
#endif
    } else if (token == QLatin1String("alt")) {
      modifiers |= Qt::AltModifier;
    } else if (token == QLatin1String("shift")) {
      modifiers |= Qt::ShiftModifier;
    } else if (named.contains(token)) {
      code = named.value(token);
    } else if (token.size() == 1) {
      code = token.at(0).toUpper().unicode();
    } else {
      fail(QStringLiteral("%1 is not a key").arg(key));
    }
  }
  // Shift+Tab arrives as Backtab.
  if (code == Qt::Key_Tab && modifiers.testFlag(Qt::ShiftModifier)) code = Qt::Key_Backtab;
  // As the platform sends it: whether an item accepted the press says who took it.
  const QString text = modifiers == Qt::NoModifier && code < 0x80 ? QString(QChar(code)).toLower() : QString();
  // A chord is the window shortcuts' unless the focused item claims it first.
  if (modifiers & (Qt::ControlModifier | Qt::AltModifier | Qt::MetaModifier)) {
    QKeyEvent claim(QEvent::ShortcutOverride, code, modifiers, text);
    claim.ignore();
    QCoreApplication::sendEvent(&m_window, &claim);
    if (!claim.isAccepted()) return false;
  }
  QKeyEvent press(QEvent::KeyPress, code, modifiers, text);
  QCoreApplication::sendEvent(&m_window, &press);
  const bool taken = press.isAccepted();
  QKeyEvent release(QEvent::KeyRelease, code, modifiers, text);
  QCoreApplication::sendEvent(&m_window, &release);
  return taken;
}

QImage Brick::grab() {
  return m_window.grabWindow();
}
