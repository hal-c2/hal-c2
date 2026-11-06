#pragma once

#include <QDateTime>
#include <QObject>
#include <QTimer>

#include <functional>

#include "NativeController.h"
#include "SlowRequests.h"

class McClient;
class ShellBridge;
class ShellStore;

// The "Some requests are slow" warning: a toast of the window's that stays
// while any of the MC's calls has waited too long for its answer
// (SlowRequests holds the rules), and closes once none does. Its "Show
// requests" lists each by its method and environment and when it started.
class SlowRequestController : public QObject, public NativeController {
  Q_OBJECT

public:
  SlowRequestController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent = nullptr);

  void activate() override {}
  bool handle(const QString&, const QVariant&) override { return false; }

  // Tests pin the clock; the app uses the system's.
  void setClock(std::function<QDateTime()> now) { m_now = std::move(now); }
  // The calls that have waited their threshold become slow; the timer calls
  // it at the next deadline.
  void expire();

  const SlowRequests& requests() const { return m_requests; }

private:
  qint64 nowMs() const { return m_now().toMSecsSinceEpoch(); }
  void schedule();
  void publish();
  QString environmentLabel(const QString& environment) const;

  McClient* m_client;
  ShellStore* m_store;
  std::function<QDateTime()> m_now = [] { return QDateTime::currentDateTimeUtc(); };
  SlowRequests m_requests;
  QTimer m_timer;
  QString m_toast;
  bool m_shown = false;
};
