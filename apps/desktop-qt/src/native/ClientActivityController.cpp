// Tells the MC what this window is looking at (`server.reportClientActivity`,
// packages/contracts background.ts), so its background work (git fetches,
// provider health checks) runs for what a client watches and pauses when
// nobody does. A report is a lease: it names the scopes watched (provider
// status always; the shown thread and its checkout's git status), lasts
// kLeaseMs, and is renewed every kReportMs and whenever what the window shows
// or the app's focus changes.

#include <QDateTime>
#include <QGuiApplication>
#include <QJsonArray>
#include <QJsonObject>
#include <QObject>
#include <QTimer>
#include <QUuid>

#include "McClient.h"
#include "NativeController.h"
#include "NativeShell.h"
#include "ShellBridge.h"
#include "WorkspaceController.h"

namespace {

constexpr int kReportMs = 25'000;
constexpr int kLeaseMs = 45'000;

class ClientActivityController : public QObject, public NativeController {
public:
  ClientActivityController(ShellBridge*, McClient* client, QObject* parent) : QObject(parent), m_client(client) {
    m_renew.setInterval(kReportMs);
    connect(&m_renew, &QTimer::timeout, this, &ClientActivityController::report);
  }

  void activate() override {
    if (m_active) return;
    m_active = true;
    auto* shell = NativeShell::of(this);
    if (auto* workspace = shell->controller<WorkspaceController>()) {
      connect(workspace, &WorkspaceController::placeChanged, this, &ClientActivityController::report);
    }
    if (qGuiApp) connect(qGuiApp, &QGuiApplication::applicationStateChanged, this, &ClientActivityController::report);
    // A new connection holds no lease of this client's.
    connect(m_client, &McClient::readyChanged, this, [this](bool ready) {
      if (ready) report();
    });
    m_renew.start();
    report();
  }

  bool handle(const QString&, const QVariant&) override { return false; }

private:
  // This run's id for its leases, one lease per window; a restarted app's old
  // leases run out on their own.
  QString clientId() const {
    static const QString process = QUuid::createUuid().toString(QUuid::WithoutBraces);
    return process + QLatin1Char(':') + NativeShell::of(this)->id();
  }

  void report() {
    if (!m_active || !m_client->isReady()) return;
    auto* workspace = NativeShell::of(this)->controller<WorkspaceController>();
    QJsonArray scopes{QJsonObject{{QStringLiteral("type"), QStringLiteral("provider-status")}}};
    QString environmentId = m_client->environment();
    if (workspace && workspace->place()) {
      const WorkspaceController::Place& place = *workspace->place();
      environmentId = place.environmentId;
      if (place.draftId.isEmpty()) scopes.append(QJsonObject{{QStringLiteral("type"), QStringLiteral("thread")}, {QStringLiteral("threadId"), place.threadId}});
      if (!place.cwd().isEmpty()) scopes.append(QJsonObject{{QStringLiteral("type"), QStringLiteral("vcs-status")}, {QStringLiteral("cwd"), place.cwd()}});
    }
    const bool focused = qGuiApp && QGuiApplication::applicationState() == Qt::ApplicationActive;
    m_client->call(this, environmentId, QStringLiteral("server.reportClientActivity"),
                   QJsonObject{{QStringLiteral("environmentId"), environmentId},
                               {QStringLiteral("clientId"), clientId()},
                               {QStringLiteral("clientKind"), QStringLiteral("desktop-renderer")},
                               {QStringLiteral("visible"), true},
                               {QStringLiteral("focused"), focused},
                               {QStringLiteral("recentlyInteracted"), focused},
                               {QStringLiteral("appState"), focused ? QStringLiteral("active") : QStringLiteral("inactive")},
                               {QStringLiteral("scopes"), scopes},
                               {QStringLiteral("ttlMs"), kLeaseMs},
                               {QStringLiteral("observedAt"), QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs)}},
                   [](const QJsonValue&, const std::optional<QString>&) {});
  }

  McClient* m_client;
  QTimer m_renew;
  bool m_active = false;
};

const NativeControllerRegistrar<ClientActivityController> registrar(QStringLiteral("clientActivity"));

}  // namespace
