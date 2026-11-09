#include "Browser.h"

#include <QImage>
#include <QJsonValue>
#include <QQmlEngine>
#include <QTimer>
#include <QtQml/qqml.h>

#include <algorithm>
#include <utility>

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
const QString kDevicesViewKey = QStringLiteral("browserDevicesView");
const QString kDevicesPresetIdsKey = QStringLiteral("browserDevicesPresetIds");
const QString kDevices3dKey = QStringLiteral("browserDevices3d");

void registerBrowser() {
  qmlRegisterSingletonType<Browser>("HalC2.Shell", 1, 0, "Browser", [](QQmlEngine*, QJSEngine*) -> QObject* {
    Browser* browser = Browser::instance();
    QQmlEngine::setObjectOwnership(browser, QQmlEngine::CppOwnership);
    return browser;
  });
  qmlRegisterType<BrowserPage>("HalC2.Shell", 1, 0, "BrowserPage");
  qmlRegisterUncreatableType<PagePermissions>("HalC2.Shell", 1, 0, "PagePermissions", QStringLiteral("Browser.permissions"));
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

void Browser::setDevicesView(bool shown) {
  if (shown == m_devicesView) return;
  m_devicesView = shown;
  if (m_write) m_write(kDevicesViewKey, m_devicesView);
  emit devicesViewChanged();
}

void Browser::setDevicesPresetIds(const QStringList& ids) {
  if (ids == m_devicesPresetIds) return;
  m_devicesPresetIds = ids;
  if (m_write) m_write(kDevicesPresetIdsKey, m_devicesPresetIds);
  emit devicesViewChanged();
}

void Browser::setDevices3d(bool shown) {
  if (shown == m_devices3d) return;
  m_devices3d = shown;
  if (m_write) m_write(kDevices3dKey, m_devices3d);
  emit devicesViewChanged();
}

void Browser::setStore(std::function<QVariant(const QString&)> read, std::function<void(const QString&, const QVariant&)> write) {
  m_write = nullptr;
  if (read) {
    const QVariant dock = read(kDockKey);
    const QVariant share = read(kShareKey);
    const QVariant devicesView = read(kDevicesViewKey);
    const QVariant devicesPresetIds = read(kDevicesPresetIdsKey);
    const QVariant devices3d = read(kDevices3dKey);
    if (dock.isValid()) setDevToolsDock(dock.toString());
    if (share.isValid()) setDevToolsShare(share.toDouble());
    if (devicesView.isValid()) setDevicesView(devicesView.toBool());
    if (devicesPresetIds.isValid()) setDevicesPresetIds(devicesPresetIds.toStringList());
    if (devices3d.isValid()) setDevices3d(devices3d.toBool());
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
  const bool resizing = this->resizing();
  m_tabId = tabId;
  m_lastReport = {};
  m_unsent = false;
  // A size picked for the old tab is not the new tab's, but its request is
  // still the MC's to answer: back on that tab, the wait is on.
  m_pendingViewport = {};
  if (resizing != this->resizing()) emit resizingChanged();
  follow();
  emit tabIdChanged();
}

void BrowserPage::follow() {
  // The reports on their way were another tab's.
  m_reporting = false;
  m_reportQueued = false;
  if (!m_enrolled.isEmpty()) Browser::instance()->leave(this, m_enrolled);
  m_enrolled = m_tabId;
  if (!m_enrolled.isEmpty()) Browser::instance()->enrol(this, m_enrolled);
  if (m_previews) {
    disconnect(m_previews, &ThreadPreviews::tabChanged, this, nullptr);
    connect(m_previews, &ThreadPreviews::tabChanged, this, [this](const QString& tabId) {
      if (tabId == m_tabId) refresh();
    });
    disconnect(m_previews, &ThreadPreviews::listed, this, nullptr);
    connect(m_previews, &ThreadPreviews::listed, this, [this] {
      // Back from a drop, the MC's tab still where it was: where the page went is news.
      if (!std::exchange(m_unsent, false) || m_lastReport.isEmpty() || m_tab.isEmpty()) return;
      // The report as the MC lists it, or not: its address, status, title and
      // history flags all come back (a load finished while away is news).
      const QString where = m_lastReport.value(QLatin1String("navStatus")).toObject().value(QLatin1String("url")).toString();
      const bool listed = m_tab.value(QLatin1String("navStatus")).toObject() == m_lastReport.value(QLatin1String("navStatus")).toObject() &&
                          m_tab.value(QLatin1String("canGoBack")).toBool() == m_lastReport.value(QLatin1String("canGoBack")).toBool() &&
                          m_tab.value(QLatin1String("canGoForward")).toBool() == m_lastReport.value(QLatin1String("canGoForward")).toBool();
      if (where == m_at && !listed) send();
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
  const QString was = url();
  m_tab = tab;
  emit tabChanged();
  // The tab showing the size picked ends the display of the pick, not the wait
  // on the MC's answer: a request is outstanding until it is answered (or the
  // wait times out), whatever else the tab shows meanwhile, or a second request
  // could be told from the first's events no better. Another size while the
  // pick is waiting (another window's) leaves the pick shown. Once answered, any
  // size the tab shows ends the display of the pick.
  const bool resized = m_tab.value(QLatin1String("viewport")) != before;
  const QJsonObject shown = m_tab.value(QLatin1String("viewport")).toObject();
  if (!m_pendingViewport.isEmpty() && (shown == m_pendingViewport || (resized && !resizing()))) {
    m_pendingViewport = {};
    emit viewportChanged();
  } else if (resized && m_pendingViewport.isEmpty()) {
    emit viewportChanged();
  }
  const QString at = url();
  // A tab gone: its page starts afresh when one comes. Not at a page yet (a
  // size, say, before the page's first report): where the page went stands.
  if (at.isEmpty()) {
    if (tab.isEmpty()) {
      m_at.clear();
      m_echoes.clear();
    }
    return;
  }
  // The MC saying back where the page went, in order (the page is where it
  // went last).
  // News that is not about the address (a size, whatever the viewport was) is
  // not the echo of a report still on its way: at the address the tab already
  // had, a resize event leaves the echoes for that one, even one that changed
  // nothing (the MC restamps it all the same).
  const bool sizeOnly = at == was && m_previews && m_previews->lastEvent(m_tabId) == QLatin1String("resized");
  const auto echoed = sizeOnly ? m_echoes.cend() : std::find_if(m_echoes.cbegin(), m_echoes.cend(), [&](const Echo& echo) { return echo.url == at; });
  if (const qsizetype echo = echoed - m_echoes.cbegin(); echoed != m_echoes.cend()) {
    m_echoes.remove(0, echo + 1);
    return;
  }
  // The tab changed but not its address (its size, say): not where the page
  // is, which may be somewhere the MC has not heard of yet.
  if (at == was) return;
  if (at == m_at) return;
  // Somewhere the page did not go by itself: an agent, or another window.
  m_at = at;
  m_unsent = false;
  emit loadRequested(at);
}

void BrowserPage::settle(const QString& tabId, int pick) {
  if (m_outstanding.value(tabId) != pick) return;
  m_outstanding.remove(tabId);
  if (tabId == m_tabId) emit resizingChanged();
}

void BrowserPage::went(const QString& url, quint64 owner) {
  m_at = url;
  if (!m_echoes.isEmpty() && m_echoes.constLast().url == url) {
    m_echoes.last().owners.append(owner);
    return;
  }
  m_echoes.append({url, {owner}});
  if (m_echoes.size() > kEchoes) m_echoes.removeFirst();
}

void BrowserPage::forget(const QString& url, quint64 owner) {
  for (qsizetype i = m_echoes.size() - 1; i >= 0; --i) {
    Echo& echo = m_echoes[i];
    if (echo.url != url) continue;
    echo.owners.removeAll(owner);
    if (echo.owners.isEmpty()) m_echoes.removeAt(i);
  }
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
  // The MC keeps web addresses of a bounded length; the start page,
  // engine-internal pages and a page's source are not news to it.
  if (!m_previews || m_tabId.isEmpty() || url.isEmpty() || url.size() > kMaxUrl || url.startsWith(QLatin1String("about:")) ||
      url.startsWith(QLatin1String("data:")) || url.startsWith(QLatin1String("chrome")) ||
      url.startsWith(QLatin1String("view-source:"))) {
    return;
  }
  QJsonObject navStatus{{QStringLiteral("url"), url}, {QStringLiteral("title"), title.left(kMaxTitle)}};
  if (phase == QLatin1String("failed")) {
    emit loadFailed(url, description);
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
  // One report at a time: the MC takes each call in a task of its own, so two
  // in flight can be applied in either order, leaving its tab at the older.
  // The newest waits for the answer to the last, and goes then.
  if (m_reporting) {
    m_reportQueued = true;
    m_at = url;
    return;
  }
  send();
}

// The last report to the MC.
void BrowserPage::send() {
  m_unsent = false;
  const QJsonObject navStatus = m_lastReport.value(QLatin1String("navStatus")).toObject();
  const QString url = navStatus.value(QLatin1String("url")).toString();
  const bool canGoBack = m_lastReport.value(QLatin1String("canGoBack")).toBool();
  const bool canGoForward = m_lastReport.value(QLatin1String("canGoForward")).toBool();
  const quint64 owner = ++m_reports;
  m_reporting = true;
  m_reportQueued = false;
  went(url, owner);
  const bool called = m_previews->report(m_tabId, navStatus, canGoBack, canGoForward, [this, url, owner, tabId = m_tabId, guard = QPointer<BrowserPage>(this)](ThreadPreviews::Unheard why) {
    if (!guard || tabId != m_tabId) return;
    if (owner == m_reports) m_reporting = false;
    if (why == ThreadPreviews::Unheard::Heard) {
      if (m_reportQueued) send();
      return;
    }
    // Dropped on the way, the MC may have taken it and say it back once
    // listed again: the echo stays. Otherwise the MC will not say it back
    // (and an earlier report's echo for the address is that report's).
    if (why != ThreadPreviews::Unheard::Dropped) forget(url, owner);
    if (why != ThreadPreviews::Unheard::Refused) {
      // It may not have heard: the page stays where it went, and says so on the way back.
      m_unsent = true;
      if (m_reportQueued) send();
      return;
    }
    // Refused: its tab is where the page is.
    m_reportQueued = false;
    m_lastReport = {};
    const QString at = this->url();
    if (at.isEmpty() || at == m_at) return;
    m_at = at;
    emit loadRequested(at);
  });
  if (!called) m_reporting = false;
}

void BrowserPage::navigate(const QString& url) {
  if (!m_previews || m_tabId.isEmpty() || url.isEmpty()) return;
  went(url, 0);
  m_previews->navigate(m_tabId, url);
}

void BrowserPage::setViewport(const QVariantMap& viewport) {
  // One size at a time: until the MC answers the last, the size it has (or the
  // one picked) is the size, and a second request could not be told from the
  // first's events.
  if (!m_previews || m_tabId.isEmpty() || resizing()) return;
  const QJsonObject next = QJsonObject::fromVariantMap(viewport);
  const int pick = ++m_viewportPick;
  const QString tabId = m_tabId;
  m_outstanding.insert(tabId, pick);
  m_pendingViewport = next;
  emit resizingChanged();
  emit viewportChanged();
  m_previews->resizeTab(tabId, next, [this, pick, tabId, guard = QPointer<BrowserPage>(this)](const std::optional<QString>& error) {
    // Answered, unless the wait timed out: refused, the MC's size is the size;
    // taken, the size picked stays shown until the MC's tab has it (its event
    // may come after the answer, or not at all).
    if (!guard || m_outstanding.value(tabId) != pick) return;
    if (tabId == m_tabId && error) m_pendingViewport = {};
    else if (tabId == m_tabId && m_tab.value(QLatin1String("viewport")).toObject() == m_pendingViewport) m_pendingViewport = {};
    settle(tabId, pick);
    if (tabId == m_tabId && error) emit viewportChanged();
  });
  QTimer::singleShot(kResizeTimeoutMs, this, [this, pick, tabId] {
    if (m_outstanding.value(tabId) != pick) return;
    if (tabId == m_tabId) m_pendingViewport = {};
    settle(tabId, pick);
    if (tabId == m_tabId) emit viewportChanged();
  });
}

void BrowserPage::evaluate(const QString& script, std::function<void(const QVariant&)> done, int world) {
  const int request = ++m_requests;
  m_evaluations.insert(request, std::move(done));
  emit evaluateRequested(request, script, world);
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

void BrowserPage::consoleMessage(int level, const QString& message, int line, const QString& source) {
  static const QString levels[] = {QStringLiteral("info"), QStringLiteral("warning"), QStringLiteral("error")};
  const QString at = source.isEmpty() ? QString() : source + QLatin1Char(':') + QString::number(line);
  emit logged(levels[std::clamp(level, 0, 2)], message, at);
}
