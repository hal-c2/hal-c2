// What the open thread says above the composer, most pressing first:
//
// - A finished turn that left background work running (subagents, watch
//   loops) says what it is waiting on and can stop it, as the web's
//   background-work banner did (features/timeline/runs-and-queue.feature).
//   Once the turn settles this is the only way left to stop that work. A stop
//   the MC accepts may not have ended the work yet, so it reads
//   "Stopping..." until the tasks it stopped end (work started since does not
//   count), for up to ThreadNoticeController::kStopWaitMs, then Stop is
//   offered again; one it refuses is the thread's error
//   (ThreadErrorController).
// - A settled thread says so, and can be un-settled from there, as the web's
//   parked-thread banner did (features/threads/settle.feature). Sending a
//   message un-settles it too; the MC does that.
//
// Publishes `threadNotice`: null, or {threadKey, kind ("background" or
// "settled"), title, description, actionLabel, busy}.
//
// Actions: `threadNotice.stop` stops the open thread's background work,
// reading "Stopping..." until that work ends or the wait is over. `threadNotice.unsettle`
// un-settles the open thread; while the MC answers, the notice reads
// "Un-settling..." for that thread only; a refusal is a toast, and the thread
// stays settled.

#include "ThreadNoticeController.h"

#include <QJsonArray>
#include <QJsonObject>
#include <QVariantMap>

#include "McClient.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ThreadErrorController.h"
#include "ToastController.h"

ThreadNoticeController::ThreadNoticeController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent)
    : QObject(parent), m_bridge(bridge), m_client(client), m_store(store) {
  m_timer.setSingleShot(true);
  connect(&m_timer, &QTimer::timeout, this, &ThreadNoticeController::expire);
}

void ThreadNoticeController::activate() {
  if (m_active) return;
  m_active = true;
  connect(NativeShell::of(this)->controller<NavigationController>(), &NavigationController::changed, this, &ThreadNoticeController::publish);
  connect(m_store, &ShellStore::changed, this, [this] {
    settleStops();
    publish();
  });
  publish();
}

bool ThreadNoticeController::handle(const QString& action, const QVariant&) {
  if (!m_active) return false;
  if (action == QLatin1String("threadNotice.stop")) {
    stop(openKey());
    return true;
  }
  if (action != QLatin1String("threadNotice.unsettle")) return false;
  const QString key = openKey();
  if (!settled(key) || m_pending.contains(key)) return true;
  m_pending.insert(key);
  publish();
  const qsizetype colon = key.indexOf(QLatin1Char(':'));
  m_client->dispatchCommand(this, key.left(colon),
                            {{QStringLiteral("type"), QStringLiteral("thread.unsettle")},
                             {QStringLiteral("threadId"), key.mid(colon + 1)},
                             {QStringLiteral("reason"), QStringLiteral("user")}},
                            [this, key](const QJsonValue&, const std::optional<QString>& error) {
                              m_pending.remove(key);
                              if (error) {
                                if (auto* toasts = NativeShell::of(this)->controller<ToastController>()) {
                                  toasts->error(QStringLiteral("Failed to un-settle thread"), *error);
                                }
                              }
                              publish();
                            });
  return true;
}

void ThreadNoticeController::expire() {
  settleStops();
  publish();
}

// Interrupts the thread, as the web did: with no run named, the MC stops
// what its provider session still has running.
void ThreadNoticeController::stop(const QString& key) {
  if (backgroundTasks(key).isEmpty() || m_stopping.contains(key)) return;
  const auto thread = m_store->thread(key);
  m_stopping.insert(key, {pendingTaskIds(key)});
  publish();
  const QJsonObject command{{QStringLiteral("type"), QStringLiteral("run.interrupt")}, {QStringLiteral("threadId"), thread->id}};
  m_client->dispatchCommand(this, thread->environmentId, command, [this, key](const QJsonValue&, const std::optional<QString>& error) {
    if (error) {
      m_stopping.remove(key);
      if (auto* errors = NativeShell::of(this)->controller<ThreadErrorController>()) {
        errors->report(key, error->isEmpty() ? QStringLiteral("Failed to stop background work.") : *error);
      }
    } else if (auto it = m_stopping.find(key); it != m_stopping.end()) {
      it->deadline = m_now().toMSecsSinceEpoch() + kStopWaitMs;
    }
    settleStops();
    publish();
  });
}

// What the thread's finished turn left running, by description (else its
// task id); none while a turn runs, when stopping the turn stops them.
QStringList ThreadNoticeController::backgroundTasks(const QString& key) const {
  if (key.isEmpty()) return {};
  const auto thread = m_store->thread(key);
  if (!thread || thread->activeRunId) return {};
  QStringList tasks;
  for (const QJsonValue& task : m_store->threadRow(key).value(QLatin1String("pendingBackgroundTasks")).toArray()) {
    const QString description = task[QLatin1String("description")].toString();
    tasks.append(description.isEmpty() ? task[QLatin1String("taskId")].toString() : description);
  }
  return tasks;
}

// The task ids the MC's row of the thread still lists as running.
QSet<QString> ThreadNoticeController::pendingTaskIds(const QString& key) const {
  QSet<QString> ids;
  for (const QJsonValue& task : m_store->threadRow(key).value(QLatin1String("pendingBackgroundTasks")).toArray()) {
    ids.insert(task[QLatin1String("taskId")].toString());
  }
  return ids;
}

QString ThreadNoticeController::openKey() const {
  return NativeShell::of(this)->controller<NavigationController>()->threadKey();
}

bool ThreadNoticeController::settled(const QString& key) const {
  if (key.isEmpty()) return false;
  const auto thread = m_store->thread(key);
  return thread && m_store->capabilities(thread->environmentId).settlement && thread->settledOverride.value_or(QString()) == QLatin1String("settled");
}

void ThreadNoticeController::settleStops() {
  const qint64 now = m_now().toMSecsSinceEpoch();
  qint64 next = 0;
  for (auto it = m_stopping.begin(); it != m_stopping.end();) {
    if (it->deadline == 0) {
      ++it;
      continue;
    }
    if (it->deadline <= now || !pendingTaskIds(it.key()).intersects(it->tasks)) {
      it = m_stopping.erase(it);
      continue;
    }
    if (next == 0 || it->deadline < next) next = it->deadline;
    ++it;
  }
  if (next == 0) m_timer.stop();
  else m_timer.start(int(next - now));
}

void ThreadNoticeController::publish() {
  if (!m_active) return;
  const QString key = openKey();
  if (const QStringList tasks = backgroundTasks(key); !tasks.isEmpty()) {
    const bool busy = m_stopping.contains(key);
    m_bridge->publish(QStringLiteral("threadNotice"),
                      QVariantMap{{QStringLiteral("threadKey"), key},
                                  {QStringLiteral("kind"), QStringLiteral("background")},
                                  {QStringLiteral("title"), tasks.size() == 1 ? QStringLiteral("Waiting on background task")
                                                                              : QStringLiteral("Waiting on %1 background tasks").arg(tasks.size())},
                                  {QStringLiteral("description"), tasks.join(QStringLiteral(", "))},
                                  {QStringLiteral("actionLabel"), busy ? QStringLiteral("Stopping...") : QStringLiteral("Stop")},
                                  {QStringLiteral("busy"), busy}});
    return;
  }
  if (!settled(key)) {
    m_bridge->publish(QStringLiteral("threadNotice"), QVariant::fromValue(nullptr));
    return;
  }
  const bool busy = m_pending.contains(key);
  m_bridge->publish(QStringLiteral("threadNotice"),
                    QVariantMap{{QStringLiteral("threadKey"), key},
                                {QStringLiteral("kind"), QStringLiteral("settled")},
                                {QStringLiteral("title"), QStringLiteral("This thread is settled")},
                                {QStringLiteral("description"), QStringLiteral("Send a message to unsettle")},
                                {QStringLiteral("actionLabel"), busy ? QStringLiteral("Un-settling...") : QStringLiteral("Un-settle")},
                                {QStringLiteral("busy"), busy}});
}

namespace {
const NativeControllerRegistrar<ThreadNoticeController> registrar(QStringLiteral("threadNotice"), {QStringLiteral("threadNotice")});
}  // namespace
