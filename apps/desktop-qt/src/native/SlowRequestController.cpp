#include "SlowRequestController.h"

#include <QJsonObject>
#include <QLocale>

#include "McClient.h"
#include "NativeShell.h"
#include "ShellStore.h"
#include "ToastController.h"

namespace {

// No state of its own: the warning is a toast.
const NativeControllerRegistrar<SlowRequestController> registrar(QStringLiteral("slowRequests"));

}  // namespace

SlowRequestController::SlowRequestController(ShellBridge*, McClient* client, ShellStore* store, QObject* parent)
    : QObject(parent), m_client(client), m_store(store) {
  m_timer.setSingleShot(true);
  connect(&m_timer, &QTimer::timeout, this, &SlowRequestController::expire);
  connect(client, &McClient::callStarted, this, [this](int id, const QString& environment, const QString& method) {
    const bool changed = m_requests.start(id, environment, method, nowMs());
    schedule();
    if (changed) publish();
  });
  connect(client, &McClient::callEnded, this, [this](int id) {
    const bool changed = m_requests.end(id);
    schedule();
    if (changed) publish();
  });
}

void SlowRequestController::expire() {
  const bool changed = m_requests.advance(nowMs());
  schedule();
  if (changed) publish();
}

void SlowRequestController::schedule() {
  const auto deadline = m_requests.nextDeadline();
  if (!deadline) {
    m_timer.stop();
    return;
  }
  m_timer.start(int(std::clamp<qint64>(*deadline - nowMs(), 0, 120'000)));
}

QString SlowRequestController::environmentLabel(const QString& environment) const {
  const QString label =
      m_store ? m_store->environment(environment).value(QLatin1String("label")).toString() : QString();
  return label.isEmpty() ? environment : label;
}

void SlowRequestController::publish() {
  auto* window = NativeShell::of(this);
  auto* toasts = window ? window->controller<ToastController>() : nullptr;
  if (!toasts) return;
  const QList<SlowRequests::Request>& slow = m_requests.slow();
  if (slow.isEmpty()) {
    if (!m_toast.isEmpty()) toasts->dismiss(std::exchange(m_toast, {}));
    m_shown = false;
    return;
  }
  const QString title = tr("Some requests are slow");
  ToastController::Action toggle{m_shown ? tr("Hide requests") : tr("Show requests"),
                                 [this] {
                                   m_shown = !m_shown;
                                   publish();
                                 },
                                 true};
  // Closed by the user: the next change shows it again.
  if (m_toast.isEmpty() ||
      !toasts->replace(m_toast, QStringLiteral("warning"), title, m_requests.description(), {toggle}, 0)) {
    m_shown = false;
    toggle.label = tr("Show requests");
    m_toast = toasts->show(QStringLiteral("warning"), title, m_requests.description(), toggle, 0);
  }
  QList<ToastController::Row> rows;
  if (m_shown) {
    const QLocale locale;
    for (const SlowRequests::Request& request : slow) {
      const QDateTime started = QDateTime::fromMSecsSinceEpoch(request.startedAtMs).toLocalTime();
      rows.append(
          {QString::number(request.id), request.method,
           tr("%1 · Started %2")
               .arg(environmentLabel(request.environment), locale.toString(started.time(), QLocale::ShortFormat)),
           QStringLiteral("idle"), QString()});
    }
  }
  toasts->setRows(m_toast, rows, nullptr);
}
