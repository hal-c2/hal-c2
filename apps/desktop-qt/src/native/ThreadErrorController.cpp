// The open thread's error, as the web's ThreadErrorBanner showed it over the
// timeline (features/timeline/runs-and-queue.feature): what this client could
// not do on the thread (report()), else the thread's last error from its row
// (`lastError`). A usage limit the thread's failed run stopped on is left to
// the timeline, whose warning line names when to retry. Dismissing hides that
// error on that thread until the app restarts; a different one shows.
//
// Publishes `threadError`: null, or {threadKey, message, warning}; warning
// for a usage limit.
//
// Action: `threadError.dismiss` hides the open thread's error.

#include "ThreadErrorController.h"

#include <QJsonObject>
#include <QVariantMap>

#include "NativeShell.h"
#include "NavigationController.h"
#include "ShellBridge.h"
#include "ShellStore.h"

ThreadErrorController::ThreadErrorController(ShellBridge* bridge, McClient*, ShellStore* store, QObject* parent)
    : QObject(parent), m_bridge(bridge), m_store(store) {}

void ThreadErrorController::activate() {
  if (m_active) return;
  m_active = true;
  connect(NativeShell::of(this)->controller<NavigationController>(), &NavigationController::changed, this, &ThreadErrorController::publish);
  connect(m_store, &ShellStore::changed, this, &ThreadErrorController::publish);
  publish();
}

bool ThreadErrorController::handle(const QString& action, const QVariant&) {
  if (!m_active || action != QLatin1String("threadError.dismiss")) return false;
  const QString key = openKey();
  const Shown error = shown(key);
  if (error.message.isEmpty()) return true;
  m_local.remove(key);
  m_dismissed.insert(key + QChar(0) + error.message);
  publish();
  return true;
}

void ThreadErrorController::report(const QString& threadKey, const QString& message) {
  if (threadKey.isEmpty() || message.isEmpty()) return;
  m_local.insert(threadKey, message);
  publish();
}

QString ThreadErrorController::openKey() const {
  return NativeShell::of(this)->controller<NavigationController>()->threadKey();
}

ThreadErrorController::Shown ThreadErrorController::shown(const QString& key) const {
  if (key.isEmpty()) return {};
  const QJsonObject row = m_store->threadRow(key);
  const QString last = row.value(QLatin1String("lastError")).toString();
  const QString message = m_local.value(key, last);
  if (message.isEmpty() || m_dismissed.contains(key + QChar(0) + message)) return {};
  const bool fromRow = !m_local.contains(key);
  const bool limit = fromRow && row.value(QLatin1String("lastErrorClass")).toString() == QLatin1String("usage_limit");
  // The run that stopped on the limit says so in the timeline.
  if (limit && row.value(QLatin1String("status")).toString() == QLatin1String("failed") &&
      !row.value(QLatin1String("latestRunId")).toString().isEmpty()) {
    return {};
  }
  return {message, limit};
}

void ThreadErrorController::publish() {
  if (!m_active) return;
  const QString key = openKey();
  const Shown error = shown(key);
  if (error.message.isEmpty()) {
    m_bridge->publish(QStringLiteral("threadError"), QVariant::fromValue(nullptr));
    return;
  }
  m_bridge->publish(QStringLiteral("threadError"), QVariantMap{{QStringLiteral("threadKey"), key},
                                                                 {QStringLiteral("message"), error.message},
                                                                 {QStringLiteral("warning"), error.warning}});
}

namespace {
const NativeControllerRegistrar<ThreadErrorController> registrar(QStringLiteral("threadError"), {QStringLiteral("threadError")});
}  // namespace
