#include "PreviewAutomationHost.h"

#include "McClient.h"
#include "PreviewAutomationPage.h"
#include "PreviewAutomationScript.h"

#include <QBuffer>
#include <QCryptographicHash>
#include <QDateTime>
#include <QDir>
#include <QHostInfo>
#include <QImage>
#include <QJsonDocument>
#include <QKeySequence>
#include <QSysInfo>
#include <QTimer>
#include <QUuid>

#include <cmath>

// The tags the MC passes on as they are, or names in its own words. Any other
// tag reaches the agent as an execution error carrying this host's message,
// which is why the desktop's own failures below have tags of their own.
namespace tag {
const auto TabNotFound = QStringLiteral("PreviewAutomationTabNotFoundError");
const auto Timeout = QStringLiteral("PreviewAutomationTimeoutError");
const auto Interrupted = QStringLiteral("PreviewAutomationControlInterruptedError");
const auto InvalidSelector = QStringLiteral("PreviewAutomationInvalidSelectorError");
const auto NotEditable = QStringLiteral("PreviewAutomationTargetNotEditableError");
const auto TooLarge = QStringLiteral("PreviewAutomationResultTooLargeError");
const auto DevTools = QStringLiteral("PreviewAutomationDevToolsOpenError");
const auto TargetNotFound = QStringLiteral("PreviewAutomationTargetNotFoundError");
const auto OutsideViewport = QStringLiteral("PreviewAutomationCoordinatesOutsideViewportError");
const auto Evaluation = QStringLiteral("PreviewAutomationEvaluationError");
const auto ConditionTimeout = QStringLiteral("PreviewAutomationConditionTimeoutError");
const auto NavigationTimeout = QStringLiteral("PreviewAutomationNavigationTimeoutError");
const auto RegistrationTimeout = QStringLiteral("PreviewAutomationWebviewRegistrationTimeoutError");
const auto ViewportNotRendered = QStringLiteral("PreviewAutomationViewportNotRenderedError");
const auto CaptureFailed = QStringLiteral("PreviewAutomationCaptureError");
const auto TabUnavailable = QStringLiteral("PreviewAutomationTabUnavailableError");
const auto InvalidInput = QStringLiteral("PreviewAutomationInvalidInputError");
const auto Script = QStringLiteral("PreviewAutomationScriptError");
const auto Unreachable = QStringLiteral("PreviewAutomationTargetUnreachableError");
const auto OpenFailed = QStringLiteral("PreviewAutomationOpenError");
}  // namespace tag

struct PreviewAutomationHost::Request {
  QString mc;
  QString environmentId;
  QString connectionId;
  QString requestId;
  QString threadId;
  QString tabId;
  QString operation;
  QString queue;
  bool tabExplicit = false;
  QJsonObject input;
  int timeoutMs = kDefaultWaitMs;
  QElapsedTimer clock;
  QPointer<PreviewAutomationPage> page;
  bool done = false;
  bool waitingForPage = false;
  QTimer* deadline = nullptr;
  QString timelineId;
};

namespace {

QString now() { return QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs); }

// Device sizes as Chrome's developer tools give them, portrait.
const QHash<QString, QSize>& presets() {
  static const QHash<QString, QSize> sizes{
      {QStringLiteral("iphone-se"), {375, 667}},
      {QStringLiteral("iphone-xr"), {414, 896}},
      {QStringLiteral("iphone-12-pro"), {390, 844}},
      {QStringLiteral("iphone-14-pro-max"), {430, 932}},
      {QStringLiteral("pixel-7"), {412, 915}},
      {QStringLiteral("samsung-galaxy-s8-plus"), {360, 740}},
      {QStringLiteral("samsung-galaxy-s20-ultra"), {412, 915}},
      {QStringLiteral("ipad-mini"), {768, 1024}},
      {QStringLiteral("ipad-air"), {820, 1180}},
      {QStringLiteral("ipad-pro"), {1024, 1366}},
      {QStringLiteral("surface-pro-7"), {912, 1368}},
      {QStringLiteral("surface-duo"), {540, 720}},
      {QStringLiteral("galaxy-z-fold-5"), {344, 882}},
      {QStringLiteral("asus-zenbook-fold"), {853, 1280}},
      {QStringLiteral("samsung-galaxy-a51-71"), {412, 914}},
      {QStringLiteral("nest-hub"), {1024, 600}},
      {QStringLiteral("nest-hub-max"), {1280, 800}},
  };
  return sizes;
}

// A key name as agents write it (Playwright's), as Qt's key and its text.
std::pair<int, QString> qtKey(const QString& name) {
  static const QHash<QString, int> named{
      {QStringLiteral("Enter"), Qt::Key_Return},      {QStringLiteral("Tab"), Qt::Key_Tab},
      {QStringLiteral("Escape"), Qt::Key_Escape},     {QStringLiteral("Backspace"), Qt::Key_Backspace},
      {QStringLiteral("Delete"), Qt::Key_Delete},     {QStringLiteral("ArrowLeft"), Qt::Key_Left},
      {QStringLiteral("ArrowRight"), Qt::Key_Right},  {QStringLiteral("ArrowUp"), Qt::Key_Up},
      {QStringLiteral("ArrowDown"), Qt::Key_Down},    {QStringLiteral("Home"), Qt::Key_Home},
      {QStringLiteral("End"), Qt::Key_End},           {QStringLiteral("PageUp"), Qt::Key_PageUp},
      {QStringLiteral("PageDown"), Qt::Key_PageDown}, {QStringLiteral("Space"), Qt::Key_Space},
      {QStringLiteral("Insert"), Qt::Key_Insert},
  };
  if (const auto it = named.constFind(name); it != named.constEnd()) {
    const QString text = *it == Qt::Key_Return ? QStringLiteral("\r")
                         : *it == Qt::Key_Tab  ? QStringLiteral("\t")
                         : *it == Qt::Key_Space ? QStringLiteral(" ")
                                                : QString();
    return {*it, text};
  }
  if (name.size() >= 2 && name.startsWith(QLatin1Char('F'))) {
    bool ok = false;
    const int n = name.mid(1).toInt(&ok);
    if (ok && n >= 1 && n <= 24) return {Qt::Key_F1 + n - 1, QString()};
  }
  if (name.size() == 1) return {QKeySequence(name)[0].key(), name};
  return {0, QString()};
}

}  // namespace

PreviewAutomationHost::PreviewAutomationHost(McClient* client, const QString& clientId, QObject* parent)
    : QObject(parent), m_client(client), m_clientId(clientId) {
  connect(m_client, &McClient::readyChanged, this, &PreviewAutomationHost::onReady);
}

PreviewAutomationHost::~PreviewAutomationHost() = default;

QStringList PreviewAutomationHost::operations() {
  // No recording: the MC tells an agent this desktop does not support it.
  return {QStringLiteral("status"), QStringLiteral("open"),   QStringLiteral("navigate"),
          QStringLiteral("snapshot"), QStringLiteral("click"), QStringLiteral("type"),
          QStringLiteral("press"),  QStringLiteral("scroll"), QStringLiteral("evaluate"),
          QStringLiteral("waitFor"), QStringLiteral("resize"), QStringLiteral("setColorScheme")};
}

QString PreviewAutomationHost::machineClientId(const QString& home) {
  QByteArray machine = QSysInfo::machineUniqueId();
  if (machine.isEmpty()) machine = QHostInfo::localHostName().toUtf8();
  // The MC keeps one host per id and drops the one it replaces: the installed
  // desktop and a dev build on one machine must not share one.
  const QByteArray hash =
      QCryptographicHash::hash("hal-c2-desktop:" + machine + '\n' + QDir::cleanPath(home).toUtf8(), QCryptographicHash::Sha256);
  return QStringLiteral("desktop-") + QString::fromLatin1(hash.toHex().left(24));
}

QString PreviewAutomationHost::connectionId(const QString& mc) const {
  return m_connections.value(mc).connectionId;
}

// Connections.

void PreviewAutomationHost::setMcs(const QList<Mc>& mcs) {
  QSet<QString> wanted;
  for (const Mc& mc : mcs) {
    wanted.insert(mc.mc);
    auto it = m_connections.find(mc.mc);
    if (it != m_connections.end() && it->environmentId == mc.environmentId) continue;
    if (it != m_connections.end()) m_client->unsubscribe(it->subscription);
    m_connections.insert(mc.mc, {mc.environmentId, -1, {}});
    subscribe(mc.mc);
  }
  for (auto it = m_connections.begin(); it != m_connections.end();) {
    if (wanted.contains(it.key())) {
      ++it;
      continue;
    }
    m_client->unsubscribe(it->subscription);
    it = m_connections.erase(it);
  }
}

void PreviewAutomationHost::subscribe(const QString& mc) {
  auto it = m_connections.find(mc);
  if (it == m_connections.end()) return;
  QJsonArray operations;
  for (const QString& op : PreviewAutomationHost::operations()) operations.append(op);
  const QJsonObject shape{
      {QStringLiteral("type"), QStringLiteral("previewAutomation")},
      {QStringLiteral("mc"), mc},
      {QStringLiteral("host"),
       QJsonObject{{QStringLiteral("clientId"), m_clientId},
                   {QStringLiteral("environmentId"), it->environmentId},
                   {QStringLiteral("supportedOperations"), operations}}},
  };
  it->connectionId.clear();
  it->subscription = m_client->subscribe(this, shape, [this, mc](const QJsonObject& frame) { onEvent(mc, frame); });
}

void PreviewAutomationHost::onEvent(const QString& mc, const QJsonObject& frame) {
  auto it = m_connections.find(mc);
  if (it == m_connections.end()) return;
  const QString type = frame.value(QLatin1String("t")).toString();
  if (type == QLatin1String("end")) {
    // The MC let this host go (it answered too late, or the MC restarted its
    // broker): offer it again, after a moment so a refusal cannot spin.
    const int subscription = it->subscription;
    it->connectionId.clear();
    QTimer::singleShot(500, this, [this, mc, subscription] {
      const auto again = m_connections.constFind(mc);
      if (again != m_connections.constEnd() && again->subscription == subscription) subscribe(mc);
    });
    return;
  }
  if (type != QLatin1String("previewAutomation")) return;
  const QJsonObject event = frame.value(QLatin1String("event")).toObject();
  const QString kind = event.value(QLatin1String("type")).toString();
  if (kind == QLatin1String("connected")) {
    it->connectionId = event.value(QLatin1String("connectionId")).toString();
    reportFocus(mc);
  } else if (kind == QLatin1String("request")) {
    QJsonObject request = event.value(QLatin1String("request")).toObject();
    request.insert(QStringLiteral("connectionId"), event.value(QLatin1String("connectionId")));
    onRequest(mc, request);
  }
}

void PreviewAutomationHost::onReady(bool ready) {
  // The client offers every subscription again once it is back, and each MC
  // answers with a new connection; until then requests cannot be answered.
  if (ready) return;
  for (auto& connection : m_connections) connection.connectionId.clear();
}

void PreviewAutomationHost::setFocused(bool focused) {
  if (m_focused == focused) return;
  m_focused = focused;
  for (auto it = m_connections.cbegin(); it != m_connections.cend(); ++it) reportFocus(it.key());
}

void PreviewAutomationHost::reportFocus(const QString& mc) {
  const Connection connection = m_connections.value(mc);
  if (connection.connectionId.isEmpty()) return;
  m_client->call(this, connection.environmentId, QStringLiteral("previewAutomation.focusHost"),
                 QJsonObject{{QStringLiteral("clientId"), m_clientId},
                             {QStringLiteral("environmentId"), connection.environmentId},
                             {QStringLiteral("connectionId"), connection.connectionId},
                             {QStringLiteral("focused"), m_focused}},
                 [](const QJsonValue&, const std::optional<QString>&) {});
}

// Pages.

void PreviewAutomationHost::attach(const QString& environmentId, const QString& threadId, const QString& tabId,
                                   PreviewAutomationPage* page) {
  if (!page || tabId.isEmpty()) return;
  if (m_pages.value(tabId).page == page) return;
  detach(page);
  if (const auto old = m_pages.value(tabId).page) detach(old);
  m_pages.insert(tabId, {page, page, environmentId, threadId});
  if (!m_currentTabs.contains(threadId)) m_currentTabs.insert(threadId, tabId);
  connect(page, &PreviewAutomationPage::humanInput, this, [this, page] { onHumanInput(page); });
  connect(page, &PreviewAutomationPage::urlChanged, this, [this, page] {
    // A new page: the pointer pointed at something of the old one.
    const QString tab = tabOf(page);
    QVariantMap entry = m_activity.value(tab).toMap();
    if (entry.remove(QStringLiteral("pointer"))) {
      m_activity.insert(tab, entry);
      emit activityChanged();
    }
  });
  connect(page, &QObject::destroyed, this, [this, page] { detach(page); });
  for (const auto& waiter : m_pageWaiters.take(tabId)) waiter();
}

void PreviewAutomationHost::detach(PreviewAutomationPage* page) {
  const QString tab = tabOf(page);
  if (tab.isEmpty()) return;
  m_pages.remove(tab);
  disconnect(page, nullptr, this, nullptr);
  QList<RequestPtr> lost;
  for (const auto& queue : std::as_const(m_queues)) {
    for (const RequestPtr& request : queue) {
      if (request->tabId == tab && !request->waitingForPage) lost.append(request);
    }
  }
  for (const RequestPtr& request : lost) {
    fail(request, tag::TabUnavailable, QStringLiteral("Preview tab %1 is no longer available.").arg(tab));
  }
  clearActivity(tab);
}

PreviewAutomationPage* PreviewAutomationHost::page(const QString& tabId) const {
  return m_pages.value(tabId).page;
}

QString PreviewAutomationHost::tabOf(const PreviewAutomationPage* page) const {
  for (auto it = m_pages.cbegin(); it != m_pages.cend(); ++it) {
    if (it->raw == page) return it.key();
  }
  return {};
}

QString PreviewAutomationHost::currentTab(const QString& threadId) const {
  return m_currentTabs.value(threadId);
}

// Requests.

void PreviewAutomationHost::onRequest(const QString& mc, const QJsonObject& json) {
  auto request = std::make_shared<Request>();
  request->mc = mc;
  request->environmentId = m_connections.value(mc).environmentId;
  request->connectionId = json.value(QLatin1String("connectionId")).toString();
  request->requestId = json.value(QLatin1String("requestId")).toString();
  request->threadId = json.value(QLatin1String("threadId")).toString();
  request->tabId = json.value(QLatin1String("tabId")).toString();
  request->tabExplicit = json.value(QLatin1String("tabIdExplicit")).toBool();
  request->operation = json.value(QLatin1String("operation")).toString();
  request->input = json.value(QLatin1String("input")).toObject();
  request->timeoutMs = json.value(QLatin1String("timeoutMs")).toInt(kDefaultWaitMs);
  request->clock.start();
  if (request->requestId.isEmpty()) return;

  if (request->operation == QLatin1String("status")) {
    // At once, whatever else the tab is doing: the MC reads it after every action.
    const QString tab = request->tabId.isEmpty() ? currentTab(request->threadId) : request->tabId;
    finish(request, true, status(tab));
    return;
  }
  // Answered by this host before the MC gives up on it, which would drop it.
  request->deadline = new QTimer(this);
  request->deadline->setSingleShot(true);
  connect(request->deadline, &QTimer::timeout, this, [this, weak = std::weak_ptr<Request>(request)] {
    const RequestPtr request = weak.lock();
    if (!request || request->done) return;
    if (request->waitingForPage) {
      fail(request, tag::RegistrationTimeout,
           QStringLiteral("Preview webview for request %1 on environment %2 thread %3 did not register within %4ms.")
               .arg(request->requestId, request->environmentId, request->threadId)
               .arg(request->timeoutMs));
      return;
    }
    fail(request, tag::Timeout,
         QStringLiteral("Preview automation %1 timed out after %2ms.").arg(request->operation).arg(request->timeoutMs));
  });
  request->deadline->start(std::max(50, request->timeoutMs - kAnswerMarginMs));
  schedule(request);
}

void PreviewAutomationHost::schedule(const RequestPtr& request) {
  // One page, one action at a time; requests that name no tab wait for the
  // thread's others, as they act on whatever tab is current when they start.
  request->queue = request->tabId.isEmpty() ? QStringLiteral("thread:") + request->threadId : request->tabId;
  QList<RequestPtr>& queue = m_queues[request->queue];
  queue.append(request);
  if (queue.size() == 1) start(request);
}

int PreviewAutomationHost::remainingMs(const RequestPtr& request) const {
  return std::max(0, request->timeoutMs - kAnswerMarginMs - int(request->clock.elapsed()));
}

void PreviewAutomationHost::start(const RequestPtr& request) {
  const QString& op = request->operation;
  if (op == QLatin1String("open")) {
    open(request);
    return;
  }
  if (request->tabId.isEmpty()) request->tabId = currentTab(request->threadId);
  if (request->tabId.isEmpty()) {
    fail(request, tag::TabNotFound, QStringLiteral("No active preview tab was found for %1.").arg(op));
    return;
  }
  const QString tab = request->tabId;
  if (!page(tab)) {
    // A tab of the thread this desktop has no page for yet: the browser makes
    // one, out of sight unless the user wants to see what agents do.
    emit reveal({request->environmentId, request->threadId, tab, m_hidden.contains(tab) ? 0 : -1});
  }
  waitForPage(request, tab, [this, request] {
    PreviewAutomationPage* page = request->page;
    if (page->devToolsOpen()) {
      fail(request, tag::DevTools,
           QStringLiteral("Preview automation %1 cannot control tab %2 while its developer tools are open; close the "
                          "preview's developer tools before using agent browser control.")
               .arg(request->operation, request->tabId));
      return;
    }
    const QString& op = request->operation;
    if (!m_hidden.contains(request->tabId) && op != QLatin1String("snapshot") && op != QLatin1String("evaluate")) {
      emit reveal({request->environmentId, request->threadId, request->tabId, -1});
    }
    m_currentTabs.insert(request->threadId, request->tabId);
    record(request, QStringLiteral("running"));
    setActivity(request->tabId, tr("Agent is using this tab"), op);
    if (op == QLatin1String("navigate")) navigate(request);
    else if (op == QLatin1String("snapshot")) snapshot(request);
    else if (op == QLatin1String("click")) click(request);
    else if (op == QLatin1String("type")) type(request);
    else if (op == QLatin1String("press")) press(request);
    else if (op == QLatin1String("scroll")) scroll(request);
    else if (op == QLatin1String("evaluate")) evaluate(request);
    else if (op == QLatin1String("waitFor")) waitFor(request);
    else if (op == QLatin1String("resize")) resize(request);
    else if (op == QLatin1String("setColorScheme")) setColorScheme(request);
    else fail(request, QStringLiteral("PreviewAutomationUnsupportedClientError"),
              QStringLiteral("Preview automation client %1 does not support %2.").arg(m_clientId, op));
  });
}

void PreviewAutomationHost::finish(const RequestPtr& request, bool ok, const QJsonValue& result,
                                   const QJsonObject& error) {
  if (request->done) return;
  request->done = true;
  request->waitingForPage = false;
  if (request->deadline) {
    request->deadline->stop();
    request->deadline->deleteLater();
    request->deadline = nullptr;
  }
  if (!request->timelineId.isEmpty()) {
    const QString message = error.value(QLatin1String("message")).toString();
    const bool interrupted = error.value(QLatin1String("_tag")).toString() == tag::Interrupted;
    record(request, ok ? QStringLiteral("succeeded") : interrupted ? QStringLiteral("interrupted") : QStringLiteral("failed"),
           message);
  }
  QJsonObject response{
      {QStringLiteral("clientId"), m_clientId},
      {QStringLiteral("connectionId"), request->connectionId},
      {QStringLiteral("requestId"), request->requestId},
      {QStringLiteral("ok"), ok},
  };
  if (ok) response.insert(QStringLiteral("result"), result);
  else response.insert(QStringLiteral("error"), error);
  m_client->call(this, request->environmentId, QStringLiteral("previewAutomation.respond"), response,
                 [](const QJsonValue&, const std::optional<QString>&) {});
  emit answered(request->requestId, ok);

  if (request->queue.isEmpty()) return;
  if (!request->tabId.isEmpty()) {
    // Fades the cue once the agent has been idle a moment.
    const QString tab = request->tabId;
    const int generation = ++m_activityGeneration[tab];
    QTimer::singleShot(1500, this, [this, tab, generation] {
      if (m_activityGeneration.value(tab) == generation) clearActivity(tab);
    });
  }
  auto queue = m_queues.find(request->queue);
  if (queue == m_queues.end()) return;
  const bool wasRunning = !queue->isEmpty() && queue->first() == request;
  queue->removeAll(request);
  if (queue->isEmpty()) {
    m_queues.erase(queue);
    return;
  }
  if (wasRunning) {
    const RequestPtr next = queue->first();
    QTimer::singleShot(0, this, [this, next] {
      if (!next->done) start(next);
    });
  }
}

void PreviewAutomationHost::fail(const RequestPtr& request, const QString& errorTag, const QString& message,
                                 const QJsonObject& detail) {
  QJsonObject error{{QStringLiteral("_tag"), errorTag}, {QStringLiteral("message"), message}};
  if (!detail.isEmpty()) error.insert(QStringLiteral("detail"), detail);
  finish(request, false, {}, error);
}

// Shared helpers.

void PreviewAutomationHost::waitForPage(const RequestPtr& request, const QString& tabId, std::function<void()> then) {
  if (PreviewAutomationPage* existing = page(tabId)) {
    request->page = existing;
    then();
    return;
  }
  request->waitingForPage = true;
  m_pageWaiters[tabId].append([this, request, tabId, then = std::move(then)] {
    if (request->done) return;
    request->waitingForPage = false;
    request->page = page(tabId);
    if (request->page) then();
  });
}

void PreviewAutomationHost::runtime(const RequestPtr& request, const QString& name, const QJsonObject& args,
                                    std::function<void(const QJsonObject& value)> then) {
  if (request->done || !request->page) return;
  request->page->runJavaScript(
      previewscript::call(name, args), PreviewAutomationPage::IsolatedWorld,
      [this, request, then = std::move(then)](const QVariant& result) {
        if (request->done || !request->page) return;
        const QJsonObject answer = previewscript::parse(result);
        if (!answer.value(QLatin1String("ok")).toBool()) {
          failTarget(request, answer);
          return;
        }
        then(answer.value(QLatin1String("value")).toObject());
      });
}

void PreviewAutomationHost::after(const RequestPtr& request, int ms, std::function<void()> then) {
  QTimer::singleShot(ms, this, [request, then = std::move(then)] {
    if (!request->done && request->page) then();
  });
}

void PreviewAutomationHost::poll(const RequestPtr& request, int waitMs,
                                 std::function<void(std::function<void(bool)> done)> check, std::function<void()> then,
                                 std::function<void()> timedOut) {
  auto clock = std::make_shared<QElapsedTimer>();
  clock->start();
  auto step = std::make_shared<std::function<void()>>();
  // The step holds itself only through the timers and callbacks in flight.
  std::weak_ptr<std::function<void()>> weakStep = step;
  *step = [this, request, waitMs, clock, check, then, timedOut, weakStep] {
    check([this, request, waitMs, clock, then, timedOut, step = weakStep.lock()](bool ok) {
      if (request->done || !request->page) return;
      if (ok) then();
      else if (clock->elapsed() >= waitMs) timedOut();
      else after(request, 100, [step] { (*step)(); });
    });
  };
  (*step)();
}

QJsonObject PreviewAutomationHost::renderedViewport(const PreviewAutomationPage* page) const {
  const QSize size = page->viewport();
  return {{QStringLiteral("width"), std::max(1, size.width())}, {QStringLiteral("height"), std::max(1, size.height())}};
}

QString PreviewAutomationHost::targetLabel(const QJsonObject& input) const {
  if (input.contains(QLatin1String("locator"))) {
    return QStringLiteral("locator (%1 characters)").arg(input.value(QLatin1String("locator")).toString().size());
  }
  if (input.contains(QLatin1String("selector"))) {
    return QStringLiteral("selector (%1 characters)").arg(input.value(QLatin1String("selector")).toString().size());
  }
  if (input.contains(QLatin1String("x"))) {
    return QStringLiteral("point (%1, %2)")
        .arg(input.value(QLatin1String("x")).toDouble())
        .arg(input.value(QLatin1String("y")).toDouble());
  }
  return QStringLiteral("the focused element");
}

void PreviewAutomationHost::failTarget(const RequestPtr& request, const QJsonObject& answer) {
  const QString kind = answer.value(QLatin1String("kind")).toString();
  const QString reason = answer.value(QLatin1String("reason")).toString();
  const QString target = targetLabel(request->input);
  const QString& op = request->operation;
  const QString& tab = request->tabId;
  if (kind == QLatin1String("invalid")) {
    fail(request, tag::InvalidSelector,
         QStringLiteral("Preview automation %1 rejected %2 in tab %3: %4").arg(op, target, tab, reason));
  } else if (kind == QLatin1String("missing")) {
    fail(request, tag::TargetNotFound,
         QStringLiteral("Preview automation %1 could not find %2 in tab %3").arg(op, target, tab));
  } else if (kind == QLatin1String("notEditable")) {
    if (request->input.contains(QLatin1String("selector")) || request->input.contains(QLatin1String("locator"))) {
      fail(request, tag::NotEditable,
           QStringLiteral("Preview automation %1 found %2, but it is not editable in tab %3").arg(op, target, tab));
    } else {
      fail(request, tag::NotEditable,
           QStringLiteral("Preview automation %1 needs an editable target in tab %2; the focused element is not editable")
               .arg(op, tab));
    }
  } else if (kind == QLatin1String("error")) {
    fail(request, tag::Script, QStringLiteral("Preview automation %1 failed in tab %2: %3").arg(op, tab, reason));
  } else {
    // No answer at all: the page went, or navigated away mid-script.
    fail(request, tag::TabUnavailable,
         QStringLiteral("Preview automation %1 lost tab %2's page before it answered.").arg(op, tab));
  }
}

// The operations.

QJsonObject PreviewAutomationHost::status(const QString& tabId) const {
  PreviewAutomationPage* page = this->page(tabId);
  QJsonObject result{
      {QStringLiteral("available"), page != nullptr},
      {QStringLiteral("visible"), page && page->onScreen()},
      {QStringLiteral("tabId"), tabId.isEmpty() ? QJsonValue() : QJsonValue(tabId)},
      {QStringLiteral("url"), page ? QJsonValue(page->url().toString()) : QJsonValue()},
      {QStringLiteral("title"), page ? QJsonValue(page->title()) : QJsonValue()},
      {QStringLiteral("loading"), page && page->loading()},
  };
  if (m_settings.contains(tabId)) result.insert(QStringLiteral("viewportSetting"), m_settings.value(tabId));
  if (page && !page->viewport().isEmpty()) result.insert(QStringLiteral("viewport"), renderedViewport(page));
  return result;
}

void PreviewAutomationHost::open(const RequestPtr& request) {
  const QJsonObject& input = request->input;
  const QJsonValue openValue = input.contains(QLatin1String("open")) ? input.value(QLatin1String("open"))
                                                                      : input.value(QLatin1String("show"));
  const int show = openValue.isBool() ? int(openValue.toBool()) : -1;
  const bool reuse = input.value(QLatin1String("reuseExistingTab")).toBool(true);
  const QUrl url = QUrl(input.value(QLatin1String("url")).toString());

  auto opened = [this, request, show, url](const QString& tab, bool load) {
    request->tabId = tab;
    m_currentTabs.insert(request->threadId, tab);
    if (show == 0) m_hidden.insert(tab);
    else if (show == 1) m_hidden.remove(tab);
    emit reveal({request->environmentId, request->threadId, tab, show});
    waitForPage(request, tab, [this, request, tab, load, url] {
      record(request, QStringLiteral("running"));
      if (load && url.isValid()) request->page->load(url);
      succeed(request, status(tab));
    });
  };

  const QString existing = reuse ? (request->tabId.isEmpty() ? currentTab(request->threadId) : request->tabId) : QString();
  if (!existing.isEmpty()) {
    opened(existing, true);
    return;
  }
  // A new tab of the thread: the MC makes it, so every client sees it, at
  // the size agents' tabs get.
  QJsonObject payload{{QStringLiteral("threadId"), request->threadId}};
  if (url.isValid()) payload.insert(QStringLiteral("url"), url.toString());
  m_client->call(this, request->environmentId, QStringLiteral("preview.open"), payload,
                 [this, request, opened](const QJsonValue& result, const std::optional<QString>& error) {
                   if (request->done) return;
                   const QString tab = result.toObject().value(QLatin1String("tabId")).toString();
                   if (error || tab.isEmpty()) {
                     fail(request, tag::OpenFailed,
                          QStringLiteral("Preview tab for thread %1 could not be opened: %2")
                              .arg(request->threadId, error.value_or(QStringLiteral("no tab came back"))));
                     return;
                   }
                   opened(tab, false);
                 });
}

void PreviewAutomationHost::navigate(const RequestPtr& request) {
  const QJsonObject& input = request->input;
  QUrl url;
  if (input.contains(QLatin1String("url"))) {
    url = QUrl(input.value(QLatin1String("url")).toString());
  } else {
    const QJsonObject target = input.value(QLatin1String("target")).toObject();
    if (target.value(QLatin1String("kind")).toString() == QLatin1String("url")) {
      url = QUrl(target.value(QLatin1String("url")).toString());
    } else {
      // A port of the environment's machine, which only this machine's own
      // MC is reached by name from here.
      if (request->environmentId != m_client->environment()) {
        fail(request, tag::Unreachable,
             QStringLiteral("Ports of environment %1 are not reachable from this desktop; navigate to a url instead.")
                 .arg(request->environmentId));
        return;
      }
      QString host = m_client->origin().host();
      if (host.isEmpty() || host == QLatin1String("127.0.0.1")) host = QStringLiteral("localhost");
      url.setScheme(target.value(QLatin1String("protocol")).toString(QStringLiteral("http")));
      url.setHost(host);
      url.setPort(target.value(QLatin1String("port")).toInt());
      url.setPath(target.value(QLatin1String("path")).toString(QStringLiteral("/")));
    }
  }
  if (!url.isValid() || url.scheme().isEmpty()) {
    fail(request, tag::InvalidInput, QStringLiteral("Preview navigation needs an absolute url, not %1.").arg(url.toString()));
    return;
  }
  const QString readiness = input.value(QLatin1String("readiness")).toString(QStringLiteral("load"));
  // Readiness counts from the new page: the old one is done loading already.
  auto started = std::make_shared<bool>(false);
  connect(request->page, &PreviewAutomationPage::loadingChanged, request->deadline, [started, page = request->page] {
    if (page && page->loading()) *started = true;
  });
  request->page->load(url);
  if (request->page->loading()) *started = true;
  if (readiness == QLatin1String("none")) {
    succeed(request, status(request->tabId));
    return;
  }
  const int waitMs = remainingMs(request);
  poll(
      request, waitMs,
      [this, request, readiness, started](std::function<void(bool)> done) {
        if (!*started) {
          done(false);
          return;
        }
        if (readiness == QLatin1String("load")) {
          if (request->page->loading()) {
            done(false);
            return;
          }
        }
        request->page->runJavaScript(previewscript::call(QStringLiteral("ready"), {}),
                                     PreviewAutomationPage::IsolatedWorld, [readiness, done](const QVariant& result) {
                                       const QString state = previewscript::parse(result)
                                                                 .value(QLatin1String("value"))
                                                                 .toObject()
                                                                 .value(QLatin1String("readyState"))
                                                                 .toString();
                                       done(readiness == QLatin1String("load") ? state == QLatin1String("complete")
                                                                               : state == QLatin1String("interactive") ||
                                                                                     state == QLatin1String("complete"));
                                     });
      },
      [this, request] { succeed(request, status(request->tabId)); },
      [this, request, readiness, waitMs] {
        fail(request, tag::NavigationTimeout,
             QStringLiteral("Preview navigation for request %1 on environment %2 thread %3 tab %4 did not reach %5 "
                            "readiness within %6ms.")
                 .arg(request->requestId, request->environmentId, request->threadId, request->tabId, readiness)
                 .arg(waitMs));
      });
}

void PreviewAutomationHost::capture(const RequestPtr& request, int attempt,
                                    std::function<void(const QJsonObject& shot)> then) {
  // Three tries, a second each: a page that was just shown may not have drawn.
  constexpr int kAttempts = 3;
  constexpr int kAttemptMs = 1000;
  auto settled = std::make_shared<bool>(false);
  auto retry = [this, request, attempt, then, settled] {
    if (*settled) return;
    *settled = true;
    if (attempt + 1 >= kAttempts) {
      fail(request, tag::CaptureFailed,
           QStringLiteral("Preview tab %1 could not be captured after %2 attempts.").arg(request->tabId).arg(kAttempts));
      return;
    }
    after(request, 100, [this, request, attempt, then] { capture(request, attempt + 1, then); });
  };
  after(request, kAttemptMs, retry);
  request->page->grab([request, then, settled, retry](const QImage& grabbed) {
    if (*settled || request->done) return;
    if (grabbed.isNull()) {
      retry();
      return;
    }
    *settled = true;
    QImage image = grabbed;
    if (image.width() > kMaxScreenshotWidth) image = image.scaledToWidth(kMaxScreenshotWidth, Qt::SmoothTransformation);
    QByteArray png;
    QBuffer buffer(&png);
    buffer.open(QIODevice::WriteOnly);
    image.save(&buffer, "PNG");
    then({{QStringLiteral("mimeType"), QStringLiteral("image/png")},
          {QStringLiteral("data"), QString::fromLatin1(png.toBase64())},
          {QStringLiteral("width"), image.width()},
          {QStringLiteral("height"), image.height()}});
  });
}

void PreviewAutomationHost::snapshot(const RequestPtr& request) {
  runtime(request, QStringLiteral("snapshot"), {}, [this, request](const QJsonObject& value) {
    capture(request, 0, [this, request, value](const QJsonObject& shot) {
      QJsonObject result = value;
      QJsonArray network = value.value(QLatin1String("networkEntries")).toArray();
      for (const QJsonValue& entry : request->page->failedLoads()) network.append(entry);
      while (network.size() > PreviewAutomationPage::kConsoleEntries) network.removeFirst();
      result.remove(QStringLiteral("viewport"));
      result.insert(QStringLiteral("tabId"), request->tabId);
      result.insert(QStringLiteral("networkEntries"), network);
      result.insert(QStringLiteral("consoleEntries"), request->page->consoleEntries());
      result.insert(QStringLiteral("actionTimeline"), m_timelines.value(request->tabId));
      result.insert(QStringLiteral("screenshot"), shot);
      succeed(request, result);
    });
  });
}

void PreviewAutomationHost::click(const RequestPtr& request) {
  QJsonObject args;
  for (const auto key : {QLatin1String("selector"), QLatin1String("locator"), QLatin1String("x"), QLatin1String("y")}) {
    if (request->input.contains(key)) args.insert(key, request->input.value(key));
  }
  if (args.contains(QLatin1String("x")) != args.contains(QLatin1String("y"))) {
    fail(request, tag::InvalidInput, QStringLiteral("A click at a point needs both x and y."));
    return;
  }
  if (args.isEmpty()) {
    fail(request, tag::InvalidInput, QStringLiteral("A click needs a locator, a selector, or x and y."));
    return;
  }
  if (args.contains(QLatin1String("x"))) {
    const double x = args.value(QLatin1String("x")).toDouble();
    const double y = args.value(QLatin1String("y")).toDouble();
    const QSize size = request->page->viewport();
    if (x < 0 || y < 0 || x >= size.width() || y >= size.height()) {
      fail(request, tag::OutsideViewport,
           QStringLiteral("Click coordinates (%1, %2) are outside the %3x%4 preview viewport for tab %5")
               .arg(x)
               .arg(y)
               .arg(size.width())
               .arg(size.height())
               .arg(request->tabId));
      return;
    }
  }
  runtime(request, QStringLiteral("clickTarget"), args, [this, request, args](const QJsonObject& target) {
    const QPointF point(target.value(QLatin1String("x")).toDouble(), target.value(QLatin1String("y")).toDouble());
    setPointer(request->tabId, point);
    auto byScript = [this, request, args] {
      runtime(request, QStringLiteral("clickScript"), args,
              [this, request](const QJsonObject&) { succeed(request, status(request->tabId)); });
    };
    // A real click where the page can take one, as a user's would land (on
    // whatever covers the element, too); a script's when it cannot, or when
    // the page never saw the real one.
    const int settle = target.value(QLatin1String("scrolled")).toBool() ? 60 : 0;
    after(request, settle, [this, request, point, byScript] {
      if (!request->page->onScreen() || !request->page->click(point)) {
        byScript();
        return;
      }
      poll(
          request, std::min(1000, remainingMs(request)),
          [this, request](std::function<void(bool)> done) {
            request->page->runJavaScript(previewscript::call(QStringLiteral("clicked"), {}),
                                         PreviewAutomationPage::IsolatedWorld, [done](const QVariant& result) {
                                           done(previewscript::parse(result).value(QLatin1String("value")).isObject());
                                         });
          },
          [this, request] { succeed(request, status(request->tabId)); }, byScript);
    });
  });
}

void PreviewAutomationHost::type(const RequestPtr& request) {
  QJsonObject args{{QStringLiteral("text"), request->input.value(QLatin1String("text")).toString()},
                   {QStringLiteral("clear"), request->input.value(QLatin1String("clear")).toBool()}};
  for (const auto key : {QLatin1String("selector"), QLatin1String("locator")}) {
    if (request->input.contains(key)) args.insert(key, request->input.value(key));
  }
  // Text goes in as the page's own editing would put it (insertText), not as
  // keystrokes: one undoable insertion, the same with any keyboard layout.
  runtime(request, QStringLiteral("type"), args, [this, request](const QJsonObject& value) {
    setPointer(request->tabId, {value.value(QLatin1String("x")).toDouble(), value.value(QLatin1String("y")).toDouble()});
    succeed(request, status(request->tabId));
  });
}

void PreviewAutomationHost::press(const RequestPtr& request) {
  const QString name = request->input.value(QLatin1String("key")).toString();
  const auto [key, text] = qtKey(name);
  QStringList held;
  for (const QJsonValue& modifier : request->input.value(QLatin1String("modifiers")).toArray()) held << modifier.toString();
  if (!key) {
    fail(request, tag::InvalidInput, QStringLiteral("Preview automation press does not know the key %1.").arg(name));
    return;
  }
  Qt::KeyboardModifiers modifiers;
  if (held.contains(QLatin1String("Alt"))) modifiers |= Qt::AltModifier;
  if (held.contains(QLatin1String("Control"))) modifiers |= Qt::ControlModifier;
  if (held.contains(QLatin1String("Meta"))) modifiers |= Qt::MetaModifier;
  if (held.contains(QLatin1String("Shift"))) modifiers |= Qt::ShiftModifier;
  const bool plain = !(modifiers & (Qt::ControlModifier | Qt::AltModifier | Qt::MetaModifier));
  const QJsonObject scriptArgs{{QStringLiteral("key"), name},
                               {QStringLiteral("alt"), held.contains(QLatin1String("Alt"))},
                               {QStringLiteral("control"), held.contains(QLatin1String("Control"))},
                               {QStringLiteral("meta"), held.contains(QLatin1String("Meta"))},
                               {QStringLiteral("shift"), held.contains(QLatin1String("Shift"))}};
  runtime(request, QStringLiteral("armKey"), {}, [this, request, key, text, plain, modifiers, scriptArgs](const QJsonObject&) {
    if (!request->page->onScreen() || !request->page->key(key, modifiers, plain ? text : QString())) {
      // Off screen the page takes no keys: the page's scripts see the press,
      // its editing does not.
      runtime(request, QStringLiteral("keyScript"), scriptArgs,
              [this, request](const QJsonObject&) { succeed(request, status(request->tabId)); });
      return;
    }
    const int waitMs = std::min(int(kPressConfirmMs), remainingMs(request));
    poll(
        request, waitMs,
        [this, request](std::function<void(bool)> done) {
          request->page->runJavaScript(previewscript::call(QStringLiteral("key"), {}), PreviewAutomationPage::IsolatedWorld,
                                       [done](const QVariant& result) {
                                         done(previewscript::parse(result).value(QLatin1String("value")).isObject());
                                       });
        },
        [this, request] { succeed(request, status(request->tabId)); },
        [this, request, waitMs] {
          fail(request, tag::ConditionTimeout,
               QStringLiteral("Preview condition did not match within %1ms in tab %2").arg(waitMs).arg(request->tabId));
        });
  });
}

void PreviewAutomationHost::scroll(const RequestPtr& request) {
  QJsonObject args;
  for (const auto key :
       {QLatin1String("selector"), QLatin1String("locator"), QLatin1String("deltaX"), QLatin1String("deltaY")}) {
    if (request->input.contains(key)) args.insert(key, request->input.value(key));
  }
  runtime(request, QStringLiteral("scroll"), args, [this, request](const QJsonObject& value) {
    if (value.contains(QLatin1String("x"))) {
      setPointer(request->tabId, {value.value(QLatin1String("x")).toDouble(), value.value(QLatin1String("y")).toDouble()});
    }
    QJsonObject result = status(request->tabId);
    result.insert(QStringLiteral("scrollX"), value.value(QLatin1String("scrollX")));
    result.insert(QStringLiteral("scrollY"), value.value(QLatin1String("scrollY")));
    succeed(request, result);
  });
}

void PreviewAutomationHost::evaluate(const RequestPtr& request) {
  const QString key = QStringLiteral("__halc2Evaluation%1_%2").arg(++m_evaluations).arg(QUuid::createUuid().toString(QUuid::Id128).left(8));
  const bool awaitPromise = request->input.value(QLatin1String("awaitPromise")).toBool(true);
  auto answer = [this, request](const QJsonObject& outcome) {
    if (outcome.contains(QLatin1String("error"))) {
      fail(request, tag::Evaluation,
           QStringLiteral("Preview JavaScript evaluation failed in tab %1: %2")
               .arg(request->tabId, outcome.value(QLatin1String("error")).toString()));
    } else if (outcome.contains(QLatin1String("tooLarge"))) {
      fail(request, tag::TooLarge,
           QStringLiteral("Preview evaluation result in tab %1 was %2 bytes; maximum is %3 bytes")
               .arg(request->tabId)
               .arg(outcome.value(QLatin1String("tooLarge")).toInteger())
               .arg(kMaxEvaluationBytes),
           {{QStringLiteral("maximumBytes"), kMaxEvaluationBytes}});
    } else if (outcome.contains(QLatin1String("value"))) {
      const QByteArray json = "[" + outcome.value(QLatin1String("value")).toString().toUtf8() + "]";
      succeed(request, QJsonDocument::fromJson(json).array().at(0));
    } else {
      succeed(request, QJsonValue::Null);
    }
  };
  request->page->runJavaScript(
      previewscript::evaluate(request->input.value(QLatin1String("expression")).toString(), key, kMaxEvaluationBytes),
      PreviewAutomationPage::PageWorld, [this, request, key, awaitPromise, answer](const QVariant& result) {
        if (request->done || !request->page) return;
        const QJsonObject outcome = previewscript::parse(result);
        if (outcome.isEmpty()) {
          // The page refused to run it at all (a policy against eval).
          fail(request, tag::Evaluation,
               QStringLiteral("Preview JavaScript evaluation failed in tab %1: the page did not run the script")
                   .arg(request->tabId));
          return;
        }
        if (!outcome.value(QLatin1String("pending")).toBool()) {
          answer(outcome);
          return;
        }
        if (!awaitPromise) {
          succeed(request, QJsonObject{});
          return;
        }
        auto settledOutcome = std::make_shared<QJsonObject>();
        poll(
            request, remainingMs(request),
            [request, key, settledOutcome](std::function<void(bool)> done) {
              request->page->runJavaScript(previewscript::settled(key), PreviewAutomationPage::PageWorld,
                                           [settledOutcome, done](const QVariant& result) {
                                             *settledOutcome = previewscript::parse(result);
                                             done(!settledOutcome->isEmpty());
                                           });
            },
            [answer, settledOutcome] { answer(*settledOutcome); },
            [this, request] {
              fail(request, tag::Timeout,
                   QStringLiteral("Preview automation evaluate timed out after %1ms.").arg(request->timeoutMs));
            });
      });
}

void PreviewAutomationHost::waitFor(const RequestPtr& request) {
  const QJsonObject& input = request->input;
  const int asked = input.value(QLatin1String("timeoutMs")).toInt(kDefaultWaitMs);
  if (asked > kMaxWaitMs) {
    fail(request, tag::InvalidInput,
         QStringLiteral("A wait may be at most %1 milliseconds, not %2.").arg(kMaxWaitMs).arg(asked));
    return;
  }
  QJsonObject args;
  for (const auto key :
       {QLatin1String("selector"), QLatin1String("locator"), QLatin1String("text"), QLatin1String("urlIncludes")}) {
    if (input.contains(key)) args.insert(key, input.value(key));
  }
  if (args.isEmpty()) {
    fail(request, tag::InvalidInput, QStringLiteral("Provide at least one wait condition."));
    return;
  }
  const int waitMs = std::min(asked, remainingMs(request));
  poll(
      request, waitMs,
      [this, request, args](std::function<void(bool)> done) {
        request->page->runJavaScript(
            previewscript::call(QStringLiteral("check"), args), PreviewAutomationPage::IsolatedWorld,
            [this, request, done](const QVariant& result) {
              if (request->done || !request->page) return;
              const QJsonObject answer = previewscript::parse(result);
              // A navigation in between drops the script's answer: try again.
              if (answer.isEmpty()) done(false);
              else if (!answer.value(QLatin1String("ok")).toBool()) failTarget(request, answer);
              else done(answer.value(QLatin1String("value")).toBool());
            });
      },
      [this, request] { succeed(request, status(request->tabId)); },
      [this, request, waitMs] {
        fail(request, tag::ConditionTimeout,
             QStringLiteral("Preview condition did not match within %1ms in tab %2").arg(waitMs).arg(request->tabId));
      });
}

void PreviewAutomationHost::resize(const RequestPtr& request) {
  const QJsonObject& input = request->input;
  const QString mode = input.value(QLatin1String("mode")).toString();
  QJsonObject setting;
  QSize size;
  if (mode == QLatin1String("fill")) {
    setting = {{QStringLiteral("_tag"), QStringLiteral("fill")}};
  } else if (mode == QLatin1String("freeform")) {
    size = QSize(input.value(QLatin1String("width")).toInt(), input.value(QLatin1String("height")).toInt());
    setting = {{QStringLiteral("_tag"), QStringLiteral("freeform")},
               {QStringLiteral("width"), size.width()},
               {QStringLiteral("height"), size.height()}};
  } else if (mode == QLatin1String("preset")) {
    const QString id = input.value(QLatin1String("preset")).toString();
    size = presets().value(id);
    if (size.isEmpty()) {
      fail(request, tag::InvalidInput, QStringLiteral("Unknown viewport preset %1.").arg(id));
      return;
    }
    const bool landscape = input.value(QLatin1String("orientation")).toString() == QLatin1String("landscape");
    if (landscape == (size.height() > size.width())) size.transpose();
    setting = {{QStringLiteral("_tag"), QStringLiteral("preset")},
               {QStringLiteral("presetId"), id},
               {QStringLiteral("width"), size.width()},
               {QStringLiteral("height"), size.height()}};
  }
  if (setting.isEmpty() || (mode != QLatin1String("fill") && size.isEmpty())) {
    fail(request, tag::InvalidInput, QStringLiteral("Viewport mode must be fill, freeform or preset."));
    return;
  }
  m_settings.insert(request->tabId, setting);
  request->page->setViewport(size);
  const int waitMs = remainingMs(request);
  // Within a pixel: a fractional device scale rounds the drawn size.
  poll(
      request, waitMs,
      [request, size](std::function<void(bool)> done) {
        const QSize drawn = request->page->viewport();
        done(size.isEmpty() ? !drawn.isEmpty()
                            : std::abs(drawn.width() - size.width()) <= 1 && std::abs(drawn.height() - size.height()) <= 1);
      },
      [this, request, setting] {
        succeed(request, QJsonObject{{QStringLiteral("tabId"), request->tabId},
                                     {QStringLiteral("setting"), setting},
                                     {QStringLiteral("viewport"), renderedViewport(request->page)}});
      },
      [this, request, size, waitMs] {
        fail(request, tag::ViewportNotRendered,
             QStringLiteral("Preview viewport for tab %1 was not rendered at %2x%3 within %4ms.")
                 .arg(request->tabId)
                 .arg(size.width())
                 .arg(size.height())
                 .arg(waitMs));
      });
}

void PreviewAutomationHost::setColorScheme(const RequestPtr& request) {
  const QString scheme = request->input.value(QLatin1String("colorScheme")).toString();
  if (scheme != QLatin1String("system") && scheme != QLatin1String("light") && scheme != QLatin1String("dark")) {
    fail(request, tag::InvalidInput, QStringLiteral("The color scheme must be system, light or dark."));
    return;
  }
  request->page->setColorScheme(scheme);
  succeed(request, QJsonObject{{QStringLiteral("tabId"), request->tabId}, {QStringLiteral("colorScheme"), scheme}});
}

// What the user sees.

void PreviewAutomationHost::record(const RequestPtr& request, const QString& status, const QString& error) {
  if (request->tabId.isEmpty()) return;
  QJsonArray& timeline = m_timelines[request->tabId];
  if (request->timelineId.isEmpty()) {
    request->timelineId = QStringLiteral("action-%1").arg(++m_timelineIds);
    timeline.append(QJsonObject{{QStringLiteral("id"), request->timelineId},
                                {QStringLiteral("action"), request->operation},
                                {QStringLiteral("status"), status},
                                {QStringLiteral("startedAt"), now()}});
    while (timeline.size() > kTimelineEntries) timeline.removeFirst();
    return;
  }
  for (qsizetype i = timeline.size() - 1; i >= 0; --i) {
    QJsonObject entry = timeline.at(i).toObject();
    if (entry.value(QLatin1String("id")).toString() != request->timelineId) continue;
    entry.insert(QStringLiteral("status"), status);
    if (status != QLatin1String("running")) entry.insert(QStringLiteral("completedAt"), now());
    if (!error.isEmpty()) entry.insert(QStringLiteral("error"), error);
    timeline.replace(i, entry);
    return;
  }
}

void PreviewAutomationHost::setActivity(const QString& tabId, const QString& label, const QString& operation) {
  ++m_activityGeneration[tabId];
  QVariantMap entry = m_activity.value(tabId).toMap();
  entry.insert(QStringLiteral("label"), label);
  entry.insert(QStringLiteral("operation"), operation);
  if (!entry.contains(QStringLiteral("actingSince"))) entry.insert(QStringLiteral("actingSince"), now());
  if (!entry.contains(QStringLiteral("userInControl"))) entry.insert(QStringLiteral("userInControl"), false);
  m_activity.insert(tabId, entry);
  emit activityChanged();
}

void PreviewAutomationHost::setPointer(const QString& tabId, const QPointF& point) {
  QVariantMap entry = m_activity.value(tabId).toMap();
  entry.insert(QStringLiteral("pointer"), QVariantMap{{QStringLiteral("x"), point.x()}, {QStringLiteral("y"), point.y()}});
  m_activity.insert(tabId, entry);
  emit activityChanged();
}

void PreviewAutomationHost::clearActivity(const QString& tabId) {
  if (!m_activity.contains(tabId)) return;
  // The pointer stays where the agent last acted, as the page shows it.
  QVariantMap entry = m_activity.value(tabId).toMap();
  const QVariant pointer = entry.value(QStringLiteral("pointer"));
  if (pointer.isValid() && page(tabId)) {
    m_activity.insert(tabId, QVariantMap{{QStringLiteral("pointer"), pointer},
                                         {QStringLiteral("userInControl"), entry.value(QStringLiteral("userInControl"))}});
  } else {
    m_activity.remove(tabId);
  }
  emit activityChanged();
}

void PreviewAutomationHost::onHumanInput(PreviewAutomationPage* page) {
  const QString tab = tabOf(page);
  if (tab.isEmpty()) return;
  const QList<RequestPtr> queue = m_queues.value(tab);
  if (!queue.isEmpty()) {
    const RequestPtr& running = queue.first();
    static const QSet<QString> acting{QStringLiteral("click"), QStringLiteral("type"), QStringLiteral("press"),
                                      QStringLiteral("scroll")};
    if (running->page == page && acting.contains(running->operation)) {
      fail(running, tag::Interrupted,
           QStringLiteral("Preview automation %1 was interrupted by human input in tab %2").arg(running->operation, tab));
    }
  }
  QVariantMap entry = m_activity.value(tab).toMap();
  entry.insert(QStringLiteral("userInControl"), true);
  m_activity.insert(tab, entry);
  emit activityChanged();
  const int generation = ++m_activityGeneration[tab];
  QTimer::singleShot(750, this, [this, tab, generation] {
    if (m_activityGeneration.value(tab) != generation || !m_activity.contains(tab)) return;
    QVariantMap entry = m_activity.value(tab).toMap();
    entry.insert(QStringLiteral("userInControl"), false);
    m_activity.insert(tab, entry);
    emit activityChanged();
    clearActivity(tab);
  });
}
