#pragma once

#include <QElapsedTimer>
#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QList>
#include <QObject>
#include <QPointer>
#include <QPointF>
#include <QSet>
#include <QStringList>
#include <QVariantMap>

#include <functional>
#include <memory>

class McClient;
class PreviewAutomationPage;

// This desktop as the browser agents drive (`previewAutomation`, apps/server-ex
// lib/hal_c2/preview_automation.ex; packages/contracts previewAutomation.ts).
//
// It offers itself to every online MC of the cluster as one host, under one
// client id that outlives restarts, and again whenever the MC ends the
// subscription (a replaced or timed-out host) or the connection comes back.
// Each MC sends requests for its threads' preview tabs; the page the browser
// brick attached for that tab carries them out, and the answer goes back with
// `previewAutomation.respond` before the request's own deadline, as the MC drops
// a host that answers late.
//
// A status is answered at once. Anything else waits for the tab's previous
// request: one page, one action at a time. The user's own input inside the
// page interrupts what the agent is doing there, and an agent keeps off a page
// whose developer tools are open.
class PreviewAutomationHost : public QObject {
  Q_OBJECT

public:
  // An MC of the cluster, and the environment it serves.
  struct Mc {
    QString mc;
    QString environmentId;
    bool operator==(const Mc&) const = default;
  };
  // A tab the MC asked for that has no page yet: the browser shows it, and
  // attaches its page. `show` is the agent's wish (-1: it said nothing).
  struct Reveal {
    QString environmentId;
    QString threadId;
    QString tabId;
    int show = -1;
  };

  PreviewAutomationHost(McClient* client, const QString& clientId, QObject* parent = nullptr);
  ~PreviewAutomationHost() override;

  // What this host can do, as it tells each MC.
  static QStringList operations();
  // A client id that is the same every run for the desktop on this machine
  // that keeps its state in `home`, and another for one that keeps it elsewhere.
  static QString machineClientId(const QString& home);

  QString clientId() const { return m_clientId; }
  // The MCs to offer this host to: new ones are subscribed, gone ones dropped.
  void setMcs(const QList<Mc>& mcs);
  // The app's window has the focus: the MCs prefer the focused desktop.
  void setFocused(bool focused);
  bool focused() const { return m_focused; }
  // The connection each MC gave this host, empty until it said `connected`.
  QString connectionId(const QString& mc) const;

  // The page the browser shows for a tab; a page is one tab's at a time.
  void attach(const QString& environmentId, const QString& threadId, const QString& tabId,
              PreviewAutomationPage* page);
  void detach(PreviewAutomationPage* page);
  PreviewAutomationPage* page(const QString& tabId) const;

  // What the agent is doing in each tab, for the cue over the page: by tab id,
  // {label, operation, pointer: {x, y}?, actingSince, userInControl}.
  QVariantMap activity() const { return m_activity; }

  // How long the browser has to attach a tab's page once asked (ms), and the
  // most a wait may ask for.
  static constexpr int kMaxWaitMs = 60'000;
  static constexpr int kDefaultWaitMs = 15'000;
  static constexpr int kMaxEvaluationBytes = 64'000;
  static constexpr int kMaxScreenshotWidth = 1280;
  static constexpr int kTimelineEntries = 200;
  static constexpr int kPressConfirmMs = 5'000;
  // An answer leaves this long before the MC's deadline.
  static constexpr int kAnswerMarginMs = 300;

signals:
  void reveal(const PreviewAutomationHost::Reveal& reveal);
  void activityChanged();
  // A request was answered (tests wait on this).
  void answered(const QString& requestId, bool ok);

private:
  struct Request;
  using RequestPtr = std::shared_ptr<Request>;
  struct Connection {
    QString environmentId;
    int subscription = -1;
    QString connectionId;
  };
  struct Attached {
    QPointer<PreviewAutomationPage> page;
    // To know the page in its `destroyed`, when the pointer above is cleared.
    const PreviewAutomationPage* raw = nullptr;
    QString environmentId;
    QString threadId;
  };

  void subscribe(const QString& mc);
  void onEvent(const QString& mc, const QJsonObject& frame);
  void reportFocus(const QString& mc);
  void onRequest(const QString& mc, const QJsonObject& request);

  // Runs `request` now, or once its tab's earlier requests are done.
  void schedule(const RequestPtr& request);
  // Puts `request` in `queue` and runs `then` once it is first there (at
  // once, when it already is).
  void enqueue(const RequestPtr& request, const QString& queue, std::function<void()> then);
  void start(const RequestPtr& request);
  // `request`'s action, on its tab's turn.
  void act(const RequestPtr& request, const QString& tab);
  void finish(const RequestPtr& request, bool ok, const QJsonValue& result, const QJsonObject& error = {});
  void succeed(const RequestPtr& request, const QJsonValue& result) { finish(request, true, result); }
  void fail(const RequestPtr& request, const QString& tag, const QString& message, const QJsonObject& detail = {});

  // The operations.
  QJsonObject status(const QString& tabId) const;
  void open(const RequestPtr& request);
  void navigate(const RequestPtr& request);
  void snapshot(const RequestPtr& request);
  void click(const RequestPtr& request);
  void type(const RequestPtr& request);
  void press(const RequestPtr& request);
  void scroll(const RequestPtr& request);
  void evaluate(const RequestPtr& request);
  void waitFor(const RequestPtr& request);
  void resize(const RequestPtr& request);
  void setColorScheme(const RequestPtr& request);

  // Helpers the operations share. Each continuation runs only while the
  // request is still unanswered and its page still there.
  void runtime(const RequestPtr& request, const QString& name, const QJsonObject& args,
               std::function<void(const QJsonObject& value)> then);
  void after(const RequestPtr& request, int ms, std::function<void()> then);
  // Calls `check` every 100 ms until it says true or `waitMs` pass (`timedOut`).
  void poll(const RequestPtr& request, int waitMs, std::function<void(std::function<void(bool)> done)> check,
            std::function<void()> then, std::function<void()> timedOut);
  void waitForPage(const RequestPtr& request, const QString& tabId, std::function<void()> then);
  void waitForReadiness(const RequestPtr& request, const QString& readiness, int waitMs, std::function<void()> then);
  void capture(const RequestPtr& request, int attempt, std::function<void(const QJsonObject& shot)> then);
  // The runtime's failure as the agent is told it.
  void failTarget(const RequestPtr& request, const QJsonObject& answer);
  int remainingMs(const RequestPtr& request) const;
  QString targetLabel(const QJsonObject& input) const;
  void record(const RequestPtr& request, const QString& status, const QString& error = {});
  void setActivity(const QString& tabId, const QString& label, const QString& operation);
  void setPointer(const QString& tabId, const QPointF& point);
  void clearActivity(const QString& tabId);
  void onHumanInput(PreviewAutomationPage* page);
  void onReady(bool ready);
  QString currentTab(const QString& threadId) const;
  QJsonObject renderedViewport(const PreviewAutomationPage* page) const;
  QString tabOf(const PreviewAutomationPage* page) const;

  McClient* m_client;
  QString m_clientId;
  bool m_focused = false;
  QHash<QString, Connection> m_connections;
  QHash<QString, Attached> m_pages;
  // Requests waiting for their tab, by tab id; the first is the one running.
  QHash<QString, QList<RequestPtr>> m_queues;
  QHash<QString, QList<std::function<void()>>> m_pageWaiters;
  QHash<QString, QJsonArray> m_timelines;
  // The tab each thread's agent last acted on, for requests that name none.
  QHash<QString, QString> m_currentTabs;
  // The size each tab was given, as a PreviewViewportSetting.
  QHash<QString, QJsonObject> m_settings;
  // Tabs an agent opened asking not to be shown: acting on them shows nothing.
  QSet<QString> m_hidden;
  QVariantMap m_activity;
  // Bumped by each change to a tab's activity, so a late fade leaves a newer one.
  QHash<QString, int> m_activityGeneration;
  int m_evaluations = 0;
  int m_timelineIds = 0;
};

Q_DECLARE_METATYPE(PreviewAutomationHost::Reveal)
