#include "World.h"

#include <QCoreApplication>
#include <QJsonArray>
#include <QPointingDevice>
#include <QQuickItem>
#include <QQuickWindow>
#include <QTest>

#include "ConnectionHealthController.h"
#include "Harness.h"
#include "NativeShell.h"
#include "ShellBridge.h"
#include "ShellRuntime.h"

namespace {

const pairing::Client kTestPhone{QStringLiteral("HAL-C2 on Test Phone"), QStringLiteral("mobile"), QStringLiteral("Android")};

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
// draws: an item or not. A Popup is a QObject, owned by the item or by the
// content of the popup it was declared in, and a closed popup's content is in
// no window.
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
  m_app = std::make_unique<MobileApp>(MobileApp::Options{m_home.path(), QStringLiteral(HAL_C2_QML_DIR), QStringLiteral(HAL_C2_MOBILE_QML_DIR), kTestPhone});
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
  shown->requestActivate();
  expect(QTest::qWaitForWindowActive(shown), QStringLiteral("the phone's window did not take the keyboard"));
}

void World::close() {
  m_app.reset();
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
  const QObject* popup = searchObjects(window().contentItem(), objectName);
  expect(popup != nullptr, QStringLiteral("the phone has no %1").arg(objectName));
  return popup->property("visible").toBool();
}

void World::awaitPopup(const QString& objectName, bool open) {
  waitFor(
      [&] {
        const QObject* popup = searchObjects(window().contentItem(), objectName);
        return popup && (open ? popup->property("opened").toBool() : !popup->property("visible").toBool());
      },
      [&] { return QStringLiteral("%1 to %2; the screen says: %3").arg(objectName, open ? QStringLiteral("open") : QStringLiteral("close"), texts().join(QStringLiteral(" | "))); });
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
