#pragma once

#include <QDateTime>
#include <QHash>
#include <QObject>
#include <QSet>
#include <QStringList>
#include <QTimer>

#include <functional>

#include "NativeController.h"

class McClient;
class ShellBridge;
class ShellStore;

// What the open thread says above the composer (`threadNotice`;
// ThreadNoticeController.cpp).
class ThreadNoticeController : public QObject, public NativeController {
  Q_OBJECT

public:
  // How long an accepted stop waits for the work it stopped to end before
  // Stop is offered again.
  static constexpr qint64 kStopWaitMs = 10'000;

  ThreadNoticeController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent);

  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;

  // Tests pin the clock; the app uses the system's.
  void setClock(std::function<QDateTime()> now) { m_now = std::move(now); }
  // Stops that have waited kStopWaitMs give up; the timer calls it at the
  // next deadline.
  void expire();

private:
  // A stop of a thread's background work: the tasks it stopped, and once the
  // MC accepted it, until when it waits for them to end.
  struct Stopping {
    QSet<QString> tasks;
    qint64 deadline = 0;  // 0 while the MC has not answered
  };

  void stop(const QString& key);
  QStringList backgroundTasks(const QString& key) const;
  QSet<QString> pendingTaskIds(const QString& key) const;
  QString openKey() const;
  bool settled(const QString& key) const;
  // Forgets the accepted stops whose tasks have all ended or whose wait is
  // over, and arms the timer for the next deadline.
  void settleStops();
  void publish();

  ShellBridge* m_bridge;
  McClient* m_client;
  ShellStore* m_store;
  bool m_active = false;
  std::function<QDateTime()> m_now = [] { return QDateTime::currentDateTimeUtc(); };
  QTimer m_timer;
  // Threads whose un-settle the MC has not answered yet.
  QSet<QString> m_pending;
  // Threads whose background work is being stopped, by thread key.
  QHash<QString, Stopping> m_stopping;
};
