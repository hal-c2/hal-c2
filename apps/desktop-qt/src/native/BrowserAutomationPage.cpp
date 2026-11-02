#include "BrowserAutomationPage.h"

#include <QCoreApplication>
#include <QKeyEvent>
#include <QMetaMethod>
#include <QMouseEvent>
#include <QPointingDevice>

#include <algorithm>
#include <cmath>

#include "Browser.h"

namespace {

// Connects the view's `signal` (any arguments) to `receiver`'s `slot`, which
// takes none: the view's signals carry web engine types this library does not know.
QMetaObject::Connection connectByName(QObject* view, const char* signal, QObject* receiver, const char* slot) {
  const QMetaObject* meta = view->metaObject();
  for (int i = 0; i < meta->methodCount(); ++i) {
    const QMetaMethod method = meta->method(i);
    if (method.methodType() == QMetaMethod::Signal && method.name() == signal) {
      const QMetaObject* target = receiver->metaObject();
      return QObject::connect(view, method, receiver, target->method(target->indexOfMethod(slot)));
    }
  }
  return {};
}

// Whether a press on `item` stops at it: a mouse area, a control, a pointer
// handler. Other items let it through to what is under them.
bool takesPress(const QQuickItem* item) {
  if (item->acceptedMouseButtons() & Qt::LeftButton) return true;
  const QObjectList& children = item->children();
  return std::any_of(children.begin(), children.end(),
                     [](const QObject* child) { return child->inherits("QQuickPointerHandler"); });
}

// The item a press at `scene` would land on under `item`, as the window
// delivers it: the topmost visible, enabled item there that takes a press, not
// one a clipping ancestor hides. `target` takes every press on it.
QQuickItem* pressTarget(QQuickItem* item, const QPointF& scene, const QQuickItem* target) {
  if (!item->isVisible() || !item->isEnabled()) return nullptr;
  const QPointF local = item->mapFromScene(scene);
  const bool inside = item->contains(local);
  if (item == target) return inside ? item : nullptr;
  if (item->clip() && !inside) return nullptr;
  QList<QQuickItem*> children = item->childItems();
  // Painted, and so hit, from the highest z down, the later sibling first.
  std::reverse(children.begin(), children.end());
  std::stable_sort(children.begin(), children.end(), [](QQuickItem* a, QQuickItem* b) { return a->z() > b->z(); });
  for (QQuickItem* child : std::as_const(children)) {
    if (QQuickItem* hit = pressTarget(child, scene, target)) return hit;
  }
  return inside && takesPress(item) ? item : nullptr;
}

}  // namespace

BrowserAutomationPage::BrowserAutomationPage(BrowserPage* page) : PreviewAutomationPage(page), m_page(page) {
  connect(page, &BrowserPage::viewChanged, this, &BrowserAutomationPage::follow);
  connect(page, &BrowserPage::devToolsChanged, this, &PreviewAutomationPage::devToolsChanged);
  connect(page, &BrowserPage::zoomChanged, this, &PreviewAutomationPage::viewportChanged);
  connect(page, &BrowserPage::logged, this, &BrowserAutomationPage::addConsoleEntry);
  connect(page, &BrowserPage::loadFailed, this,
          [this](const QString& url, const QString& description) { addFailedLoad(QUrl(url), description); });
  follow();
}

void BrowserAutomationPage::follow() {
  for (const auto& connection : std::as_const(m_viewConnections)) disconnect(connection);
  m_viewConnections.clear();
  m_view = m_page ? m_page->view() : nullptr;
  if (m_view) {
    m_viewConnections = {
        connectByName(m_view, "loadingChanged", this, "loadingChanged()"),
        connectByName(m_view, "urlChanged", this, "urlChanged()"),
        connect(m_view, &QQuickItem::widthChanged, this, &PreviewAutomationPage::viewportChanged),
        connect(m_view, &QQuickItem::heightChanged, this, &PreviewAutomationPage::viewportChanged),
        connect(m_view, &QQuickItem::windowChanged, this, &BrowserAutomationPage::watch),
    };
  }
  watch(m_view ? m_view->window() : nullptr);
  emit viewportChanged();
}

void BrowserAutomationPage::watch(QQuickWindow* window) {
  if (window == m_window) return;
  if (m_window) m_window->removeEventFilter(this);
  m_window = window;
  if (m_window) m_window->installEventFilter(this);
}

QQuickItem* BrowserAutomationPage::view() const {
  return m_view;
}

qreal BrowserAutomationPage::zoom() const {
  return m_page ? m_page->zoom() : 1.0;
}

void BrowserAutomationPage::runJavaScript(const QString& script, World world, ScriptDone done) {
  if (!m_page || !m_view) return;
  m_page->evaluate(script, std::move(done), world);
}

void BrowserAutomationPage::grab(ImageDone done) {
  if (!m_page || !m_view) {
    done({});
    return;
  }
  m_page->grab(std::move(done));
}

QUrl BrowserAutomationPage::url() const {
  return m_view ? m_view->property("url").toUrl() : QUrl();
}

QString BrowserAutomationPage::title() const {
  return m_view ? m_view->property("title").toString() : QString();
}

bool BrowserAutomationPage::loading() const {
  return m_view && m_view->property("loading").toBool();
}

void BrowserAutomationPage::load(const QUrl& url) {
  // The view reports the load to the MC as the user's would be.
  if (m_view) m_view->setProperty("url", url);
}

bool BrowserAutomationPage::devToolsOpen() const {
  return m_page && m_page->devTools();
}

bool BrowserAutomationPage::onScreen() const {
  return m_view && m_window && m_view->isVisible() && m_window->isVisible() && m_window->isExposed() &&
         m_view->width() > 0 && m_view->height() > 0;
}

QSize BrowserAutomationPage::viewport() const {
  if (!m_view) return {};
  return QSize(qRound(m_view->width() / zoom()), qRound(m_view->height() / zoom()));
}

void BrowserAutomationPage::setViewport(const QSize& size) {
  if (!m_page) return;
  if (size.isEmpty()) {
    m_page->setViewport({{QStringLiteral("_tag"), QStringLiteral("fill")}});
    return;
  }
  m_page->setViewport({{QStringLiteral("_tag"), QStringLiteral("freeform")},
                       {QStringLiteral("width"), size.width()},
                       {QStringLiteral("height"), size.height()}});
}

bool BrowserAutomationPage::click(const QPointF& point) {
  if (!onScreen()) return false;
  // The view draws the page's CSS pixels at its zoom, then scaled with the
  // view (a device frame, the app's zoom): the scene has both.
  const QPointF scene = m_view->mapToScene(point * zoom());
  // Only the page's: a menu, a dialog or a neighbouring pane over the point
  // is the app's, and the agent never clicks it.
  if (!onPage(scene)) return false;
  const QPointF global = m_window->mapToGlobal(scene);
  const QPointingDevice* mouse = QPointingDevice::primaryPointingDevice();
  QMouseEvent move(QEvent::MouseMove, scene, scene, global, Qt::NoButton, Qt::NoButton, Qt::NoModifier, mouse);
  QMouseEvent press(QEvent::MouseButtonPress, scene, scene, global, Qt::LeftButton, Qt::LeftButton, Qt::NoModifier, mouse);
  QMouseEvent release(QEvent::MouseButtonRelease, scene, scene, global, Qt::LeftButton, Qt::NoButton, Qt::NoModifier, mouse);
  QCoreApplication::sendEvent(m_window, &move);
  QCoreApplication::sendEvent(m_window, &press);
  QCoreApplication::sendEvent(m_window, &release);
  return true;
}

bool BrowserAutomationPage::key(int key, Qt::KeyboardModifiers modifiers, const QString& text) {
  if (!onScreen() || !pageHasFocus()) return false;
  QKeyEvent press(QEvent::KeyPress, key, modifiers, text);
  QKeyEvent release(QEvent::KeyRelease, key, modifiers, text);
  QCoreApplication::sendEvent(m_window, &press);
  QCoreApplication::sendEvent(m_window, &release);
  return true;
}

void BrowserAutomationPage::setColorScheme(const QString& scheme) {
  if (m_page) m_page->setAppearance(scheme);
}

bool BrowserAutomationPage::pageHasFocus() const {
  if (!m_view || !m_window) return false;
  QQuickItem* focus = m_window->activeFocusItem();
  return focus && (focus == m_view || m_view->isAncestorOf(focus));
}

bool BrowserAutomationPage::onPage(const QPointF& scene) const {
  if (!m_view || !m_window) return false;
  return pressTarget(m_window->contentItem(), scene, m_view) == m_view;
}

bool BrowserAutomationPage::eventFilter(QObject* watched, QEvent* event) {
  // Only what the platform delivers is the user's: the agent's own events are
  // sent, and the page's scripts never reach the window.
  if (watched == m_window && event->spontaneous()) {
    switch (event->type()) {
    case QEvent::MouseButtonPress:
    case QEvent::Wheel:
    case QEvent::TouchBegin:
      if (onPage(static_cast<QSinglePointEvent*>(event)->scenePosition())) emit humanInput();
      break;
    case QEvent::KeyPress:
      if (pageHasFocus()) emit humanInput();
      break;
    default:
      break;
    }
  }
  return PreviewAutomationPage::eventFilter(watched, event);
}
