#include "AlertController.h"

#include <QGuiApplication>

#include "NativeShell.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "ShellStore.h"
#include "SidebarModel.h"
#include "ToastController.h"

namespace {

const NativeControllerRegistrar<AlertController> registrar(QStringLiteral("alerts"));

}  // namespace

AlertController::AlertController(ShellBridge*, NodeClient* client, ShellStore* store, QObject* parent)
    : QObject(parent), m_client(client), m_store(store) {
  if (qGuiApp) {
    m_focused = qGuiApp->applicationState() == Qt::ApplicationActive;
    connect(qGuiApp, &QGuiApplication::applicationStateChanged, this,
            [this](Qt::ApplicationState state) { setFocused(state == Qt::ApplicationActive); });
  }
  connect(store, &ShellStore::changed, this, &AlertController::evaluate);
  // A reconnect's snapshot is a new baseline: what finished meanwhile is quiet.
  connect(client, &NodeClient::readyChanged, this, [this](bool ready) {
    if (!ready) m_seen.clear();
  });
}

void AlertController::activate() {
  if (auto* settings = NativeShell::of(this)->controller<SettingsController>()) {
    connect(settings, &SettingsController::deviceChanged, this, &AlertController::readSettings, Qt::UniqueConnection);
  }
  readSettings();
  evaluate();
}

void AlertController::setPresenter(Presenter presenter) {
  m_presenter = std::move(presenter);
  if (m_presenter.setEnabled) m_presenter.setEnabled(hasSystemNotifications(m_mode));
}

void AlertController::setFocused(bool focused) {
  if (m_focused == focused) return;
  m_focused = focused;
  // Back at the window, the system notifications have done their job.
  if (focused && m_presenter.clear) m_presenter.clear();
}

bool AlertController::openThread(const QString& key) {
  if (!hasSystemNotifications(m_mode) || !m_store->thread(key)) return false;
  auto* navigation = NativeShell::of(this)->controller<NavigationController>();
  if (!navigation) return false;
  navigation->open(NavigationController::Route::thread(key));
  return true;
}

void AlertController::readSettings() {
  const auto* settings = NativeShell::of(this)->controller<SettingsController>();
  if (!settings) return;
  const QString mode = settings->setting(QStringLiteral("notificationMode")).toString();
  m_inApp = settings->setting(QStringLiteral("inAppNotificationsEnabled")).toBool();
  if (mode == m_mode) return;
  m_mode = mode;
  if (m_presenter.clear) m_presenter.clear();
  if (m_presenter.setEnabled) m_presenter.setEnabled(hasSystemNotifications(m_mode));
}

void AlertController::evaluate() {
  if (!m_client->isReady() || !m_store->synchronized()) return;
  // With every alert off nothing is followed; turning one on starts afresh.
  if (m_mode == QLatin1String("off") && !m_inApp) {
    m_seen.clear();
    return;
  }
  auto* shell = NativeShell::of(this);
  auto* navigation = shell->controller<NavigationController>();
  auto* toasts = shell->controller<ToastController>();
  const QString shown = navigation ? navigation->threadKey() : QString();

  QHash<QString, Seen> next;
  for (const sidebar::Thread& thread : m_store->threads()) {
    if (thread.subagent) continue;
    const QString key = thread.key();
    QString status = sidebar::status(thread);
    if (status == QLatin1String("ready") && thread.latestRun && thread.latestRun->status == QLatin1String("failed")) {
      status = QStringLiteral("failed");
    }
    const auto prior = m_seen.constFind(key);
    Seen seen;
    if (status == QLatin1String("input") || status == QLatin1String("approval") ||
        status == QLatin1String("failed") || status == QLatin1String("limited")) {
      seen.attention = (thread.latestRun ? thread.latestRun->runId : QString()) + QLatin1Char(':') + status;
    }
    const auto completedAt = thread.latestRun ? sidebar::parseIso(thread.latestRun->completedAt) : std::nullopt;
    if (status == QLatin1String("ready") && thread.latestRun && thread.latestRun->status == QLatin1String("completed") &&
        completedAt) {
      seen.completion = completedAt;
    } else if (prior != m_seen.constEnd()) {
      seen.completion = prior->completion;
    }
    next.insert(key, seen);
    if (prior == m_seen.constEnd() || thread.archivedAt) continue;

    QString kind;
    if (!seen.attention.isEmpty() && seen.attention != prior->attention) {
      kind = QStringLiteral("input");
    } else if (seen.completion && (!prior->completion || *seen.completion > *prior->completion)) {
      kind = QStringLiteral("completion");
    } else {
      continue;
    }
    const QString title = kind == QLatin1String("completion") ? tr("Thread completed")
                          : status == QLatin1String("approval") ? tr("Approval needed")
                          : status == QLatin1String("limited")  ? tr("Usage limit reached")
                          : status == QLatin1String("failed")   ? tr("Thread failed")
                                                                : tr("Input needed");
    if (hasSound(m_mode) && m_presenter.play) m_presenter.play(kind);
    if (m_inApp && m_focused && key != shown) {
      if (!toasts) continue;
      const QString type = kind == QLatin1String("completion") ? QStringLiteral("success")
                           : status == QLatin1String("failed") ? QStringLiteral("error")
                                                               : QStringLiteral("warning");
      toasts->show(type, title, thread.title,
                   ToastController::Action{tr("Open thread"), [this, key] {
                                             if (auto* navigation = NativeShell::of(this)->controller<NavigationController>()) {
                                               navigation->open(NavigationController::Route::thread(key));
                                             }
                                           }});
      continue;
    }
    if (!hasSystemNotifications(m_mode) || m_focused || !m_presenter.show) continue;
    // The sound, when there is one, is the mode's own, not the system's.
    m_presenter.show(key, title, thread.title, true);
  }
  m_seen = std::move(next);
}
