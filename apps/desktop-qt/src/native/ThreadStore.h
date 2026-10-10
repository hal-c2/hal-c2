#pragma once

#include <QDateTime>
#include <QHash>
#include <QJsonObject>
#include <QLocale>
#include <QObject>
#include <QPointer>
#include <QStringList>
#include <QTimer>

#include <functional>

#include "NativeController.h"
#include "TimelineModel.h"

class LocalCache;
class McClient;
class ShellBridge;
class ShellStore;

// The threads the desktop has open, each followed through the MC's `stream`
// shape into a TimelineModel. The active thread plus a few recently active
// ones stay subscribed, so switching back is instant; older ones are dropped,
// and so is one the user left more than five minutes ago. Those bounds are on
// memory and on what the MC streams here, not on what opening costs: a
// thread's copy stays in the LocalCache, so one opened again (after an
// eviction or a restart) shows what was kept at once and is sent only what
// changed since.
//
//   Threads.open("env-a:thread-1")   // makes it active and follows it
//   Threads.timeline                 // the active thread's rows
//   Threads.close("env-a:thread-1")  // stops following it
//
// A thread is addressed by its environment, which the MC routes to the
// cluster member serving it. It waits in `loading` until the shell lists it
// (ShellStore), whose MC says when it is online. The
// McClient sends the subscription again after a reconnect or `resync`, from
// where the model says its copy stands; the MC answers with the events it
// lacks, or a part-0 snapshot that replaces the thread's entities when the
// copy is of no use (the thread moved). Either way the rows
// keep their ids. An MC that refuses the stream (offline, gone) leaves the
// thread `unreachable` with its rows until the MC is back, and so does a
// connection that drops or cannot be made: what was loaded or kept stays
// readable, not shown as live.
class ThreadStore : public QObject, public NativeController {
  Q_OBJECT
  Q_PROPERTY(QString activeThread READ activeThread NOTIFY activeThreadChanged)
  Q_PROPERTY(TimelineModel* timeline READ activeTimeline NOTIFY activeThreadChanged)

public:
  // Threads kept following besides the active one.
  static constexpr int warmThreads = 3;
  // How long a thread the user left stays followed.
  static constexpr int idleSeconds = 5 * 60;

  ThreadStore(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent = nullptr);
  ~ThreadStore() override;

  void activate() override;
  // Opens the thread the window was left on from the cache.
  void preview() override;
  bool handle(const QString&, const QVariant&) override { return false; }

  QString activeThread() const { return m_active; }
  TimelineModel* activeTimeline() const { return timeline(m_active); }
  TimelineModel* timeline(const QString& threadKey) const;
  // Most recently active first.
  QStringList openThreads() const { return m_recent; }

  // Makes the thread ("environmentId:threadId") active, following it if it
  // was not yet. Empty leaves no thread active; the warm ones stay.
  Q_INVOKABLE void open(const QString& threadKey);
  Q_INVOKABLE void close(const QString& threadKey);
  // Follows an unreachable thread again now, rather than when its MC is
  // back, from where its copy stands; `loading` until the MC says it is live.
  Q_INVOKABLE void reload(const QString& threadKey);

  void setClock(std::function<QDateTime()> now);
  // The locale the timelines read times in (the system's by default).
  void setLocale(const QLocale& locale);
  // A time that may be ahead (a usage limit's reset) as the timelines read it.
  QString upcoming(const QDateTime& at) const;

  // The one place a thread's stream is addressed.
  static QJsonObject streamShape(const QString& environmentId, const QString& threadId);

signals:
  void activeThreadChanged();
  // The timestampFormat or the locale changed.
  void timesChanged();

private:
  struct Followed {
    QPointer<TimelineModel> model;
    int subscription = 0;
    // Refused while its MC was offline: retried once the MC is online.
    bool waitOnline = false;
    // Its copy is being read from the cache: followed once it is in, so the
    // subscription resumes from it.
    bool restoring = false;
    // The shell listed it once: when its environment is no longer reached
    // (the user removed it), what was loaded of it goes too.
    bool listed = false;
  };

  void follow(const QString& threadKey);
  void unfollow(Followed& followed);
  LocalCache* cache() const;
  // Why the MC cannot be reached now, or empty while it can or is being tried.
  QString connectionProblem() const;
  // A thread that is not live says so while the MC cannot be reached.
  void showConnection();
  void onFrame(const QString& threadKey, const QJsonObject& frame);
  void retry();
  // Closes the threads the sidebar listed and no longer does (deleted, moved
  // to another machine, or of an environment the user removed): what was
  // loaded and kept of them goes too.
  void forgetRemoved();
  void evict();
  // Stops following the threads left for idleSeconds or longer.
  void evictIdle();
  QDateTime now() const;
  // Asks the thread's MC for an image's address (`assets.createUrl`) and
  // gives it to the model.
  void signAttachment(TimelineModel* model, const QString& threadKey, const QString& id);
  // The device's timestampFormat, for every timeline.
  void readSettings();
  void configure(TimelineModel* model) const;

  McClient* m_client;
  ShellStore* m_store;
  QHash<QString, Followed> m_threads;
  QStringList m_recent;
  // When the user left each followed thread that is not the active one.
  QHash<QString, QDateTime> m_leftAt;
  QTimer m_idleTimer;
  QString m_active;
  std::function<QDateTime()> m_now;
  QString m_timestampFormat = QStringLiteral("locale");
  QLocale m_locale;
};
