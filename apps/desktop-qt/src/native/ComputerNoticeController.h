#pragma once

#include <QDateTime>
#include <QJsonObject>
#include <QObject>
#include <QSet>
#include <QTimer>

#include <functional>

#include "ComputerNotice.h"
#include "NativeController.h"

class McClient;
class ShellBridge;
class ShellStore;
class ThreadStore;

// The thread's notice about the computer it runs on, when that is another
// member of the cluster and it is down (ComputerNotice holds the rules). The
// computers come from ServerUpdateController's `serverUpdates`, which knows
// each one's label, whether it is online, its version and a running update;
// the thread from the window's ThreadStore.
//
// Publishes `threadComputer`: null | {kind, environmentId, title, detail,
// canReconnect, canDisconnect}. Takes `threadComputer.reconnect` (the cluster
// tries the computer again) and `threadComputer.disconnect` (switches it off
// in the cluster, which hides it and its threads, and goes home), each
// {environmentId}; a failure is a toast with the MC's reason.
class ComputerNoticeController : public QObject, public NativeController {
  Q_OBJECT

public:
  ComputerNoticeController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent = nullptr);

  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;

  // Tests pin the clock; the app uses the system's.
  void setClock(std::function<QDateTime()> now) { m_now = std::move(now); }
  // The grace of a computer that dropped may have run out; the timer calls it.
  void expire();

private:
  qint64 nowMs() const { return m_now().toMSecsSinceEpoch(); }
  void seeComputers(const QVariant& serverUpdates);
  void showThread();
  void changed(bool changed);
  // Asks the window's own MC `method` for the computer, toasting `failure` with
  // its reason.
  void ask(const QString& method, const QJsonObject& payload, const QString& failure, std::function<void()> done);

  ShellBridge* m_bridge;
  McClient* m_client;
  ShellStore* m_store;
  std::function<QDateTime()> m_now = [] { return QDateTime::currentDateTimeUtc(); };
  ComputerNotice m_notice;
  QSet<QString> m_seen;
  QTimer m_timer;
};
