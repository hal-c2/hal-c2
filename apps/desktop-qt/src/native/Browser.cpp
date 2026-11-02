#include "Browser.h"

#include <QImage>
#include <QJsonValue>
#include <QQmlEngine>
#include <QTimer>
#include <QtQml/qqml.h>

#include <algorithm>

namespace {

bool g_supported = false;
QPointer<QObject> g_profile;

// The contract's bounds on what the MC keeps of a page.
constexpr qsizetype kMaxUrl = 2048;
constexpr qsizetype kMaxTitle = 512;
// How many addresses the page went to may wait for the MC to say them back.
constexpr qsizetype kEchoes = 16;
// How long the MC has to confirm a device size before it is undone.
constexpr int kResizeTimeoutMs = 5000;

const QString kDockKey = QStringLiteral("browserDevToolsDock");
const QString kShareKey = QStringLiteral("browserDevToolsShare");

void registerBrowser() {
  qmlRegisterSingletonType<Browser>("HalC2.Shell", 1, 0, "Browser", [](QQmlEngine*, QJSEngine*) -> QObject* {
    Browser* browser = Browser::instance();
    QQmlEngine::setObjectOwnership(browser, QQmlEngine::CppOwnership);
    return browser;
  });
  qmlRegisterType<BrowserPage>("HalC2.Shell", 1, 0, "BrowserPage");
}

}  // namespace

Q_COREAPP_STARTUP_FUNCTION(registerBrowser)

// --- Browser -------------------------------------------------------------------------

Browser* Browser::instance() {
  static Browser* browser = new Browser();
  return browser;
}

void Browser::setSupported(bool supported) {
  g_supported = supported;
}

bool Browser::supported() {
  return g_supported;
}

void Browser::setProfile(QObject* profile) {
  g_profile = profile;
}

QObject* Browser::profile() const {
  return g_profile;
}

void Browser::setDevToolsDock(const QString& dock) {
  const QString next = dock == QLatin1String("right") ? dock : QStringLiteral("bottom");
  if (next == m_dock) return;
  m_dock = next;
  if (m_write) m_write(kDockKey, m_dock);
  emit devToolsChanged();
}

void Browser::setDevToolsShare(qreal share) {
  const qreal next = std::clamp(share, 0.2, 0.8);
  if (qFuzzyCompare(next, m_share)) return;
  m_share = next;
  if (m_write) m_write(kShareKey, m_share);
  emit devToolsChanged();
}

void Browser::setStore(std::function<QVariant(const QString&)> read, std::function<void(const QString&, const QVariant&)> write) {
  m_write = nullptr;
  if (read) {
    const QVariant dock = read(kDockKey);
    const QVariant share = read(kShareKey);
    if (dock.isValid()) setDevToolsDock(dock.toString());
    if (share.isValid()) setDevToolsShare(share.toDouble());
  }
  m_write = std::move(write);
}

BrowserPage* Browser::page(const QString& tabId) {
  return instance()->m_pages.value(tabId);
}

QList<BrowserPage*> Browser::pages() {
  QList<BrowserPage*> list;
  for (const auto& page : std::as_const(instance()->m_pages)) {
    if (page) list.append(page);
  }
  return list;
}

void Browser::enrol(BrowserPage* page, const QString& tabId) {
  m_pages.insert(tabId, page);
  emit pagesChanged();
}

void Browser::leave(BrowserPage* page, const QString& tabId) {
  if (m_pages.value(tabId) != page) return;
  m_pages.remove(tabId);
  emit pagesChanged();
}

// --- BrowserPage ---------------------------------------------------------------------

BrowserPage::BrowserPage(QObject* parent) : QObject(parent) {}

BrowserPage::~BrowserPage() {
  if (!m_enrolled.isEmpty()) Browser::instance()->leave(this, m_enrolled);
}

void BrowserPage::setPreviews(ThreadPreviews* previews) {
  if (previews == m_previews) return;
  if (m_previews) disconnect(m_previews, nullptr, this, nullptr);
  m_previews = previews;
  emit previewsChanged();
  follow();
}

void BrowserPage::setTabId(const QString& tabId) {
  if (tabId == m_tabId) return;
  m_tabId = tabId;
  m_lastReport = {};
  follow();
  emit tabIdChanged();
}

void BrowserPage::follow() {
  if (!m_enrolled.isEmpty()) Browser::instance()->leave(this, m_enrolled);
  m_enrolled = m_tabId;
  if (!m_enrolled.isEmpty()) Browser::instance()->enrol(this, m_enrolled);
  if (m_previews) {
    disconnect(m_previews, &ThreadPreviews::tabChanged, this, nullptr);
    connect(m_previews, &ThreadPreviews::tabChanged, this, [this](const QString& tabId) {
      if (tabId == m_tabId) refresh();
    });
  }
  // What the MC has now is where the page starts: the brick loads `url`.
  m_tab = m_previews && !m_tabId.isEmpty() ? m_previews->tab(m_tabId) : QJsonObject();
  m_at = url();
  m_echoes.clear();
  emit tabChanged();
  emit viewportChanged();
}

void BrowserPage::refresh() {
  const QJsonObject tab = m_previews ? m_previews->tab(m_tabId) : QJsonObject();
  if (tab == m_tab) return;
  const QJsonValue before = m_tab.value(QLatin1String("viewport"));
  m_tab = tab;
  emit tabChanged();
  // The MC confirming the size picked ends the pick.
  if (!m_pendingViewport.isEmpty() && m_tab.value(QLatin1String("viewport")).toObject() == m_pendingViewport) {
    m_pendingViewport = {};
  } else if (m_tab.value(QLatin1String("viewport")) != before && m_pendingViewport.isEmpty()) {
    emit viewportChanged();
  }
  const QString at = url();
  // A tab gone, or not at a page yet: its page starts afresh when one comes.
  if (at.isEmpty()) {
    m_at.clear();
    m_echoes.clear();
    return;
  }
  // The MC saying back where the page went, in order.
  if (const qsizetype echo = m_echoes.indexOf(at); echo >= 0) {
    m_echoes.remove(0, echo + 1);
    m_at = at;
    return;
  }
  if (at == m_at) return;
  // Somewhere the page did not go by itself: an agent, or another window.
  m_at = at;
  emit loadRequested(at);
}

void BrowserPage::went(const QString& url) {
  m_at = url;
  if (!m_echoes.isEmpty() && m_echoes.constLast() == url) return;
  m_echoes.append(url);
  if (m_echoes.size() > kEchoes) m_echoes.removeFirst();
}

QString BrowserPage::url() const {
  return m_tab.value(QLatin1String("navStatus")).toObject().value(QLatin1String("url")).toString();
}

QString BrowserPage::title() const {
  return m_tab.value(QLatin1String("navStatus")).toObject().value(QLatin1String("title")).toString();
}

QString BrowserPage::status() const {
  const QString tag = m_tab.value(QLatin1String("navStatus")).toObject().value(QLatin1String("_tag")).toString();
  if (tag == QLatin1String("Loading")) return QStringLiteral("loading");
  if (tag == QLatin1String("Success")) return QStringLiteral("loaded");
  if (tag == QLatin1String("LoadFailed")) return QStringLiteral("failed");
  return QStringLiteral("idle");
}

QVariantMap BrowserPage::viewport() const {
  if (!m_pendingViewport.isEmpty()) return m_pendingViewport.toVariantMap();
  const QJsonObject viewport = m_tab.value(QLatin1String("viewport")).toObject();
  // Older MCs say nothing: the page fills its space.
  return viewport.isEmpty() ? QVariantMap{{QStringLiteral("_tag"), QStringLiteral("fill")}} : viewport.toVariantMap();
}

void BrowserPage::setZoom(qreal zoom) {
  zoom = std::clamp(zoom, 0.25, 5.0);
  if (qFuzzyCompare(zoom, m_zoom)) return;
  m_zoom = zoom;
  emit zoomChanged();
}

void BrowserPage::setAppearance(const QString& appearance) {
  const QString next = appearance == QLatin1String("light") || appearance == QLatin1String("dark") ? appearance : QStringLiteral("system");
  if (next == m_appearance) return;
  m_appearance = next;
  emit appearanceChanged();
}

void BrowserPage::setMuted(bool muted) {
  if (muted == m_muted) return;
  m_muted = muted;
  emit mutedChanged();
}

void BrowserPage::setDevTools(bool open) {
  if (open == m_devTools) return;
  m_devTools = open;
  emit devToolsChanged();
}

void BrowserPage::setView(QQuickItem* view) {
  if (view == m_view) return;
  m_view = view;
  emit viewChanged();
}

void BrowserPage::report(const QString& phase, const QString& url, const QString& title, int code, const QString& description,
                         bool canGoBack, bool canGoForward) {
  // The MC keeps web addresses of a bounded length; the start page and
  // engine-internal pages are not news to it.
  if (!m_previews || m_tabId.isEmpty() || url.isEmpty() || url.size() > kMaxUrl || url.startsWith(QLatin1String("about:")) ||
      url.startsWith(QLatin1String("data:")) || url.startsWith(QLatin1String("chrome"))) {
    return;
  }
  QJsonObject navStatus{{QStringLiteral("url"), url}, {QStringLiteral("title"), title.left(kMaxTitle)}};
  if (phase == QLatin1String("failed")) {
    navStatus.insert(QStringLiteral("_tag"), QStringLiteral("LoadFailed"));
    navStatus.insert(QStringLiteral("code"), code);
    navStatus.insert(QStringLiteral("description"), description);
  } else {
    navStatus.insert(QStringLiteral("_tag"), phase == QLatin1String("loading") ? QStringLiteral("Loading") : QStringLiteral("Success"));
  }
  const QJsonObject report{{QStringLiteral("navStatus"), navStatus},
                           {QStringLiteral("canGoBack"), canGoBack},
                           {QStringLiteral("canGoForward"), canGoForward}};
  if (report == m_lastReport) return;
  m_lastReport = report;
  went(url);
  m_previews->report(m_tabId, navStatus, canGoBack, canGoForward);
}

void BrowserPage::navigate(const QString& url) {
  if (!m_previews || m_tabId.isEmpty() || url.isEmpty()) return;
  went(url);
  m_previews->navigate(m_tabId, url);
}

void BrowserPage::setViewport(const QVariantMap& viewport) {
  if (!m_previews || m_tabId.isEmpty()) return;
  const QJsonObject next = QJsonObject::fromVariantMap(viewport);
  m_pendingViewport = next;
  const int pick = ++m_viewportPick;
  emit viewportChanged();
  m_previews->resizeTab(m_tabId, next, [this, pick, guard = QPointer<BrowserPage>(this)](const QString&) {
    // Refused or timed out: the MC's size comes back, unless the user has
    // picked another since.
    if (!guard || pick != m_viewportPick) return;
    m_pendingViewport = {};
    emit viewportChanged();
  });
  QTimer::singleShot(kResizeTimeoutMs, this, [this, pick] {
    if (pick != m_viewportPick || m_pendingViewport.isEmpty()) return;
    m_pendingViewport = {};
    emit viewportChanged();
  });
}

void BrowserPage::evaluate(const QString& script, std::function<void(const QVariant&)> done) {
  const int request = ++m_requests;
  m_evaluations.insert(request, std::move(done));
  emit evaluateRequested(request, script);
}

void BrowserPage::grab(std::function<void(const QImage&)> done) {
  const int request = ++m_requests;
  m_grabs.insert(request, std::move(done));
  emit grabRequested(request);
}

void BrowserPage::evaluated(int request, const QVariant& result) {
  if (auto done = m_evaluations.take(request)) done(result);
}

void BrowserPage::grabbed(int request, const QImage& image) {
  if (auto done = m_grabs.take(request)) done(image);
}
