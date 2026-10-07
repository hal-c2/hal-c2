#include "World.h"

#include <QCoreApplication>
#include <QDesktopServices>
#include <QGuiApplication>
#include <QJsonArray>
#include <QPointingDevice>
#include <QQuickItem>
#include <QQuickWindow>
#include <QTest>
#include <QThread>
#include <qpa/qwindowsysteminterface.h>

#include "ConnectionHealthController.h"
#include "Harness.h"
#include "NativeShell.h"
#include "ShellBridge.h"
#include "ShellRuntime.h"

namespace {

const pairing::Client kTestPhone{QStringLiteral("HAL-C2 on Test Phone"), QStringLiteral("mobile"), QStringLiteral("Android")};

// How many moves a drag is made of: enough for a handler to take it for one.
constexpr int kDragSteps = 8;

QPointingDevice* finger() {
  static QPointingDevice* device = QTest::createTouchDevice();
  return device;
}

// Popups and dialogs are the window's overlay's, beside the screens; a
// Repeater's delegates are only the item tree's children.
QQuickItem* search(QQuickItem* item, const std::function<bool(QQuickItem*)>& matches) {
  if (!item->isVisible()) return nullptr;
  if (matches(item)) return item;
  const QList<QQuickItem*> children = item->childItems();
  for (QQuickItem* child : children) {
    if (QQuickItem* found = search(child, matches)) return found;
  }
  return nullptr;
}

// The object named `objectName` among what `object` owns and, for an item,
// draws: an item or not. A Popup is a QObject, owned by the window, the item
// or the content of the popup it was declared in, and a closed popup's
// content is in no window.
QObject* searchObjects(QObject* object, const QString& objectName) {
  if (object->objectName() == objectName) return object;
  const auto* item = qobject_cast<QQuickItem*>(object);
  const QObjectList owned = object->children();
  for (QObject* child : owned) {
    if (qobject_cast<QQuickItem*>(child)) continue;
    if (QObject* found = searchObjects(child, objectName)) return found;
  }
  if (item) {
    const QList<QQuickItem*> children = item->childItems();
    for (QQuickItem* child : children) {
      if (QObject* found = searchObjects(child, objectName)) return found;
    }
  } else if (auto* content = object->property("contentItem").value<QQuickItem*>()) {
    if (QObject* found = searchObjects(content, objectName)) return found;
  }
  return nullptr;
}

void collectTexts(QQuickItem* item, QStringList& texts) {
  if (!item->isVisible()) return;
  const QString text = item->property("text").toString();
  if (!text.isEmpty()) texts.append(text);
  const QList<QQuickItem*> children = item->childItems();
  for (QQuickItem* child : children) collectTexts(child, texts);
}

}  // namespace

World::World() : environment(QStringLiteral("a"), QStringLiteral("My MacBook")), mc(environment.mc) {
  mc.projects.clear();
  mc.threads.clear();
  mc.projects.insert(QStringLiteral("shop"), {{QStringLiteral("id"), QStringLiteral("shop")},
                                             {QStringLiteral("title"), QStringLiteral("shop")},
                                             {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")},
                                             {QStringLiteral("scripts"), QJsonArray()},
                                             {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                             {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")}});
  mc.threads.insert(QStringLiteral("tax-line"), {{QStringLiteral("id"), QStringLiteral("tax-line")},
                                                 {QStringLiteral("title"), QStringLiteral("Tax line")},
                                                 {QStringLiteral("projectId"), QStringLiteral("shop")},
                                                 {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T08:00:00Z")},
                                                 {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T08:00:00Z")}});
}

World::~World() {
  close();
}

void World::open() {
  if (m_app) return;
  QWindowSystemInterface::handleApplicationStateChanged<QWindowSystemInterface::SynchronousDelivery>(Qt::ApplicationActive);
  m_app = std::make_unique<MobileApp>(
      MobileApp::Options{m_home.path(), QStringLiteral(HAL_C2_QML_DIR), QStringLiteral(HAL_C2_MOBILE_QML_DIR), kTestPhone, camera});
  // The scenarios' seams: a dropped connection is tried again at once, and
  // nothing leaves the test for the system's browser or clipboard.
  m_app->native().client()->setRetryDelays({20});
  m_app->bridge().setUrlOpener([this](const QUrl& url) { openedUrls.append(url); });
  m_app->native().shared<ConnectionHealthController>()->setClipboardWriter([this](const QString& text) {
    clipboard = text;
    return true;
  });
  m_app->start();
  QQuickWindow* shown = m_app->runtime().window();
  expect(shown != nullptr, QStringLiteral("the phone's window did not load: %1").arg(m_app->runtime().lastError()));
  expect(m_app->runtime().lastError().isEmpty(), QStringLiteral("the phone's root did not load: %1").arg(m_app->runtime().lastError()));
  if (m_size.isValid()) shown->resize(m_size);
  shown->requestActivate();
  expect(QTest::qWaitForWindowActive(shown), QStringLiteral("the phone's window did not take the keyboard"));
}

void World::background() {
  QWindowSystemInterface::handleApplicationStateChanged<QWindowSystemInterface::SynchronousDelivery>(Qt::ApplicationSuspended);
}

void World::foreground() {
  QWindowSystemInterface::handleApplicationStateChanged<QWindowSystemInterface::SynchronousDelivery>(Qt::ApplicationActive);
}

void World::followLink(const QString& link) {
  // With no handler for it, a real platform would hand the link to whatever
  // app this machine opens it with.
  expect(QGuiApplication::platformName() == QLatin1String("offscreen"), QStringLiteral("links are only followed on the offscreen platform"));
  const QUrl url(link);
  if (!m_app) {
    // The link a stopped app was started with comes on the app's own thread.
    open();
    QDesktopServices::openUrl(url);
    return;
  }
  // A running app's comes on Android's.
  const std::unique_ptr<QThread> android(QThread::create([url] { QDesktopServices::openUrl(url); }));
  android->start();
  expect(android->wait(5000), QStringLiteral("the link was not handed over"));
}

void World::close() {
  m_app.reset();
}

PairableMc& World::another(const QString& label) {
  if (!m_another) m_another = std::make_unique<PairableMc>(QStringLiteral("b"), label);
  expect(m_another->mc.label == label, QStringLiteral("the other environment is %1").arg(m_another->mc.label));
  return *m_another;
}

void World::resize(int width, int height) {
  m_size = QSize(width, height);
  if (!m_app) return;
  window().resize(m_size);
  waitFor([&] { return window().size() == m_size; },
          [&] { return QStringLiteral("a %1x%2 window; it is %3x%4").arg(width).arg(height).arg(window().width()).arg(window().height()); });
}

MobileApp& World::app() {
  open();
  return *m_app;
}

ShellBridge& World::bridge() {
  return app().bridge();
}

NativeShell& World::native() {
  return app().native();
}

QQuickWindow& World::window() {
  return *app().runtime().window();
}

QVariant World::state(const QString& key) {
  return bridge().state()->value(key);
}

QQuickItem* World::findWhere(const std::function<bool(QQuickItem*)>& matches) {
  return search(window().contentItem(), matches);
}

QQuickItem* World::find(const QString& objectName) {
  return findWhere([&](QQuickItem* candidate) { return candidate->objectName() == objectName; });
}

QQuickItem* World::item(const QString& objectName) {
  QQuickItem* found = nullptr;
  waitFor([&] { return (found = find(objectName)) != nullptr; },
          [&] { return QStringLiteral("%1 to be on screen, which shows: %2").arg(objectName, texts().join(QStringLiteral(" | "))); });
  return found;
}

bool World::popupShowing(const QString& objectName) {
  const QObject* popup = searchObjects(&window(), objectName);
  expect(popup != nullptr, QStringLiteral("the window has no %1").arg(objectName));
  return popup->property("visible").toBool();
}

void World::awaitPopup(const QString& objectName, bool open) {
  waitFor(
      [&] {
        const QObject* popup = searchObjects(&window(), objectName);
        return popup && (open ? popup->property("opened").toBool() : !popup->property("visible").toBool());
      },
      [&] { return QStringLiteral("%1 to %2; the screen says: %3").arg(objectName, open ? QStringLiteral("open") : QStringLiteral("close"), texts().join(QStringLiteral(" | "))); });
}

void World::snapshot(const QString& path) {
  if (m_app) window().grabWindow().save(path);
}

QStringList World::texts() {
  QStringList found;
  collectTexts(window().contentItem(), found);
  return found;
}

bool World::shows(const QString& text, bool whole) {
  return findWhere([&](QQuickItem* candidate) {
           const QString shown = candidate->property("text").toString();
           return whole ? shown == text : shown.contains(text);
         }) != nullptr;
}

QPoint World::middleOf(QQuickItem* target) {
  const QString name = target->objectName().isEmpty() ? QString::fromLatin1(target->metaObject()->className()) : target->objectName();
  waitFor([&] { return target->isVisible() && target->isEnabled(); },
          [&] { return QStringLiteral("%1 to be tappable (visible %2, enabled %3)").arg(name).arg(target->isVisible()).arg(target->isEnabled()); });
  // Positioners and anchors settle on the window's polish: drawing a frame
  // runs it, so the point is where the user sees the item now.
  window().grabWindow();
  const QPoint point = target->mapToScene(QPointF(target->width() / 2, target->height() / 2)).toPoint();
  expect(QRect(QPoint(0, 0), window().size()).contains(point),
         QStringLiteral("%1 is off the %2x%3 screen, at %4,%5").arg(name).arg(window().width()).arg(window().height()).arg(point.x()).arg(point.y()));
  return point;
}

void World::tap(QQuickItem* target) {
  const QPoint point = middleOf(target);
  QTest::touchEvent(&window(), finger()).press(0, point, &window());
  QTest::touchEvent(&window(), finger()).release(0, point, &window());
}

void World::hold(QQuickItem* target, const std::function<bool()>& until, const QString& what) {
  const QPoint point = middleOf(target);
  QTest::touchEvent(&window(), finger()).press(0, point, &window());
  const bool met = QTest::qWaitFor(until, 5000);
  QTest::touchEvent(&window(), finger()).release(0, point, &window());
  expect(met, QStringLiteral("timed out holding a finger down for ") + what);
}

void World::tap(const QString& objectName) {
  tap(item(objectName));
}

void World::swipe(QQuickItem* target, const QPoint& by, const std::function<void()>& during) {
  const QPoint from = middleOf(target);
  QTest::touchEvent(&window(), finger()).press(0, from, &window());
  for (int step = 1; step <= kDragSteps; ++step) QTest::touchEvent(&window(), finger()).move(0, from + by * step / kDragSteps, &window());
  if (during) during();
  QTest::touchEvent(&window(), finger()).release(0, from + by, &window());
}

void World::hover(QQuickItem* target) {
  // Onto the item from beside its middle: a pointer that arrives, as a real one does.
  const QPoint point = middleOf(target);
  QTest::mouseMove(&window(), point + QPoint(0, 4));
  QTest::mouseMove(&window(), point);
}

void World::click(QQuickItem* target, Qt::MouseButton button) {
  QTest::mouseClick(&window(), button, Qt::NoModifier, middleOf(target));
}

void World::drag(QQuickItem* target, const QPoint& by, const std::function<void()>& during) {
  const QPoint from = middleOf(target);
  QTest::mousePress(&window(), Qt::LeftButton, Qt::NoModifier, from);
  for (int step = 1; step <= kDragSteps; ++step) QTest::mouseMove(&window(), from + by * step / kDragSteps);
  if (during) during();
  QTest::mouseRelease(&window(), Qt::LeftButton, Qt::NoModifier, from + by);
}

void World::press(const QString& key) {
  QString chord = key;
  chord.replace(QLatin1String("mod"), QLatin1String("Ctrl"), Qt::CaseInsensitive);
  expect(app().runtime().pressKey(chord), QStringLiteral("%1 is not a key the window can be sent").arg(key));
}

void World::type(const QString& text) {
  for (const QChar character : text) QTest::keyClick(&window(), character.toLatin1());
}

void World::back() {
  QTest::keyClick(&window(), Qt::Key_Back);
}

void World::waitFor(const std::function<bool()>& condition, const std::function<QString()>& what) {
  if (!QTest::qWaitFor(condition, 5000)) fail(QStringLiteral("timed out waiting for ") + what());
}

void World::waitFor(const std::function<bool()>& condition, const QString& what) {
  waitFor(condition, [what] { return what; });
}

void World::sync() {
  bool done = false;
  native().client()->call(&native(), mc.environmentId, QStringLiteral("test.barrier"), QJsonValue::Null,
                          [&done](const QJsonValue&, const std::optional<QString>&) { done = true; });
  waitFor([&done] { return done; }, QStringLiteral("a round trip through the MC"));
}
