#pragma once

#include <QHash>
#include <QJsonObject>
#include <QLocale>
#include <QObject>
#include <QPointer>
#include <QStringList>

#include <functional>

#include "NativeController.h"
#include "TimelineModel.h"

class McClient;
class ShellBridge;
class ShellStore;

// The threads the desktop has open, each followed through the MC's `stream`
// shape into a TimelineModel. The active thread plus a few recently active
// ones stay subscribed, so switching back is instant; older ones are dropped.
//
//   Threads.open("env-a:thread-1")   // makes it active and follows it
//   Threads.timeline                 // the active thread's rows
//   Threads.close("env-a:thread-1")  // stops following it
//
// A thread is addressed by its environment, which the MC routes to the
// cluster member serving it or through its link to it. It waits in `loading`
// until the shell lists it (ShellStore), whose MC says when it is online. The
// McClient sends the subscription again after a reconnect or `resync`, and
// the part-0 snapshot that follows replaces the thread's entities; the rows
// keep their ids. An MC that refuses the stream (offline, gone) leaves the
// thread `unreachable` with its rows until the MC is back.
class ThreadStore : public QObject, public NativeController {
  Q_OBJECT
  Q_PROPERTY(QString activeThread READ activeThread NOTIFY activeThreadChanged)
  Q_PROPERTY(TimelineModel* timeline READ activeTimeline NOTIFY activeThreadChanged)

public:
  // Threads kept following besides the active one.
  static constexpr int warmThreads = 3;

  ThreadStore(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent = nullptr);
  ~ThreadStore() override;

  void activate() override;
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
  // back; `loading` until the snapshot lands.
  Q_INVOKABLE void reload(const QString& threadKey);

  void setClock(std::function<QDateTime()> now);
  // The locale the timelines read times in (the system's by default).
  void setLocale(const QLocale& locale);

  // The one place a thread's stream is addressed.
  static QJsonObject streamShape(const QString& environmentId, const QString& threadId);

signals:
  void activeThreadChanged();

private:
  struct Followed {
    QPointer<TimelineModel> model;
    int subscription = 0;
    // Refused while its MC was offline: retried once the MC is online.
    bool waitOnline = false;
  };

  void follow(const QString& threadKey);
  void unfollow(Followed& followed);
  void onFrame(const QString& threadKey, const QJsonObject& frame);
  void retry();
  void evict();
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
  QString m_active;
  std::function<QDateTime()> m_now;
  QString m_timestampFormat = QStringLiteral("locale");
  QLocale m_locale;
};
