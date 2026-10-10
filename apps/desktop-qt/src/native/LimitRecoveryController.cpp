// What the user can do about the open thread once its agent stopped on a
// usage limit: continue on its own when
// the limit resets, or snooze the thread until then. The MC arms both
// (`thread.metadata.update` with `limitRecovery`, HalC2.Orchestration.
// LimitRecovery); the row says what is armed.
//
// Publishes `limitRecovery`: null unless the open thread is limited, else
// {threadKey, title, description ("Resets <when>", or "Reset time
// unavailable; retry manually"), canSchedule (the agent said when the limit
// resets), scheduled (it resumes at the reset), snoozed (it is snoozed until
// the reset), canSnooze (the reset is still ahead), error}.
//
// Actions: `limitRecovery.resume` and `limitRecovery.snooze` turn each on, or
// off again.

#include <QJsonObject>
#include <QLocale>
#include <QVariantMap>

#include "McClient.h"
#include "NativeController.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "SidebarController.h"
#include "SidebarModel.h"
#include "ThreadStore.h"

class LimitRecoveryController : public QObject, public NativeController {
public:
  LimitRecoveryController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent)
      : QObject(parent), m_bridge(bridge), m_client(client), m_store(store) {}

  void activate() override {
    if (m_active) return;
    m_active = true;
    connect(NativeShell::of(this)->controller<NavigationController>(), &NavigationController::changed, this, [this] {
      m_error.clear();
      publish();
    });
    connect(m_store, &ShellStore::changed, this, &LimitRecoveryController::publish);
    // The reset reads in the device's time format.
    if (auto* threads = NativeShell::of(this)->controller<ThreadStore>()) {
      connect(threads, &ThreadStore::timesChanged, this, &LimitRecoveryController::publish);
    }
    publish();
  }

  bool handle(const QString& action, const QVariant&) override {
    if (!m_active || !action.startsWith(QLatin1String("limitRecovery."))) return false;
    const Reading now = read();
    if (!now.limited || !now.canSchedule) return true;
    QJsonObject update{{QStringLiteral("runId"), now.runId}, {QStringLiteral("resetAt"), now.resetAt}};
    if (action == QLatin1String("limitRecovery.resume")) {
      update.insert(QStringLiteral("autoResume"), !now.scheduled);
    } else if (action == QLatin1String("limitRecovery.snooze")) {
      if (!now.snoozed && !now.canSnooze) {
        m_error = QStringLiteral("The reset time has passed. Retry the thread manually.");
        publish();
        return true;
      }
      update.insert(QStringLiteral("snooze"), !now.snoozed);
    } else {
      return true;
    }
    m_error.clear();
    m_client->dispatchCommand(this, now.key.left(now.key.indexOf(QLatin1Char(':'))),
                              {{QStringLiteral("type"), QStringLiteral("thread.metadata.update")},
                               {QStringLiteral("threadId"), now.key.mid(now.key.indexOf(QLatin1Char(':')) + 1)},
                               {QStringLiteral("limitRecovery"), update}},
                              [this](const QJsonValue&, const std::optional<QString>& error) {
                                m_error = error.value_or(QString());
                                publish();
                              });
    return true;
  }

private:
  struct Reading {
    bool limited = false;
    QString key;
    QString runId;
    QString resetAt;
    bool canSchedule = false;
    bool scheduled = false;
    bool snoozed = false;
    bool canSnooze = false;
  };

  Reading read() const {
    Reading reading;
    reading.key = NativeShell::of(this)->controller<NavigationController>()->threadKey();
    const auto thread = reading.key.isEmpty() ? std::nullopt : m_store->thread(reading.key);
    if (!thread || !thread->latestRun || sidebar::status(*thread) != QLatin1String("limited")) return reading;
    const QJsonObject row = m_store->threadRow(reading.key);
    reading.limited = true;
    reading.runId = thread->latestRun->runId;
    reading.resetAt = row.value(QLatin1String("usageLimitResetAt")).toString();
    const auto reset = sidebar::parseIso(reading.resetAt);
    const auto stopped = sidebar::parseIso(thread->latestRun->completedAt ? thread->latestRun->completedAt : sidebar::Nullable(thread->updatedAt));
    reading.canSchedule = reset && stopped && *reset > *stopped;
    const QJsonObject recovery = row.value(QLatin1String("limitRecovery")).toObject();
    const bool same = recovery.value(QLatin1String("runId")).toString() == reading.runId &&
                      recovery.value(QLatin1String("resetAt")).toString() == reading.resetAt;
    reading.scheduled = same && recovery.value(QLatin1String("autoResume")).toBool();
    const auto snoozedUntil = sidebar::parseIso(thread->snoozedUntil);
    reading.snoozed = same && recovery.value(QLatin1String("snooze")).toBool() && reset && snoozedUntil && *snoozedUntil == *reset;
    reading.canSnooze = reset && *reset > NativeShell::of(this)->sidebar()->now().toMSecsSinceEpoch();
    return reading;
  }

  // The reset as the timeline's usage-limit row reads it.
  QString upcoming(const QDateTime& at) const {
    const auto* threads = NativeShell::of(this)->controller<ThreadStore>();
    return threads ? threads->upcoming(at) : at.toString(Qt::ISODate);
  }

  void publish() {
    if (!m_active) return;
    const Reading now = read();
    if (!now.limited) {
      m_bridge->publish(QStringLiteral("limitRecovery"), QVariant::fromValue(nullptr));
      return;
    }
    const auto reset = sidebar::parseIso(now.resetAt);
    m_bridge->publish(QStringLiteral("limitRecovery"),
                      QVariantMap{{QStringLiteral("threadKey"), now.key},
                                  {QStringLiteral("title"), QStringLiteral("Usage limit reached")},
                                  {QStringLiteral("description"),
                                   reset ? QStringLiteral("Resets %1").arg(upcoming(QDateTime::fromMSecsSinceEpoch(*reset)))
                                         : QStringLiteral("Reset time unavailable; retry manually")},
                                  {QStringLiteral("canSchedule"), now.canSchedule},
                                  {QStringLiteral("scheduled"), now.scheduled},
                                  {QStringLiteral("snoozed"), now.snoozed},
                                  {QStringLiteral("canSnooze"), now.canSnooze},
                                  {QStringLiteral("error"), m_error}});
  }

  ShellBridge* m_bridge;
  McClient* m_client;
  ShellStore* m_store;
  bool m_active = false;
  QString m_error;
};

namespace {
const NativeControllerRegistrar<LimitRecoveryController> registrar(QStringLiteral("limitRecovery"), {QStringLiteral("limitRecovery")});
}  // namespace
