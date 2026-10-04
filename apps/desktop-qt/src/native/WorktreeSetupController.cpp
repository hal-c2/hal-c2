// How the open thread's new worktree is being prepared (the web's
// WorktreeSetupCard): the MC's `worktreeSetup` shape for the thread
// (HalC2.WorktreeSetup; a WorktreeSetupSnapshot of packages/contracts, or
// null when none is tracked), followed while the window shows the thread.
//
// Publishes `worktreeSetup`: null without a setup, else {threadKey, phase
// (running | done | failed | cancelled), label ("Setting up worktree…",
// "Worktree ready", ...), error, branch, baseRef, worktreePath, script (the setup script's
// name), canCancel, detailsOpen, stages: [{id, label, status, detail, tail}]}.
//
// Actions: `worktreeSetup.details {open}` shows or hides the steps and why
// the setup failed; `worktreeSetup.cancel` stops a running setup
// (`worktreeSetup.cancel`), told when it cannot.

#include <QJsonArray>
#include <QJsonObject>
#include <QVariantMap>

#include "McClient.h"
#include "NativeController.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ToastController.h"

class WorktreeSetupController : public QObject, public NativeController {
public:
  WorktreeSetupController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent)
      : QObject(parent), m_bridge(bridge), m_client(client), m_store(store) {}

  void activate() override {
    if (m_active) return;
    m_active = true;
    connect(NativeShell::of(this)->controller<NavigationController>(), &NavigationController::changed, this, &WorktreeSetupController::follow);
    // The MC serving the thread's environment may arrive after the route.
    connect(m_store, &ShellStore::changed, this, &WorktreeSetupController::follow);
    follow();
  }

  bool handle(const QString& action, const QVariant& payload) override {
    if (!m_active || !action.startsWith(QLatin1String("worktreeSetup."))) return false;
    if (action == QLatin1String("worktreeSetup.details")) {
      m_detailsOpen = payload.toMap().value(QStringLiteral("open")).toBool();
      publish();
    } else if (action == QLatin1String("worktreeSetup.cancel") && !m_thread.isEmpty()) {
      m_client->call(this, environmentId(), QStringLiteral("worktreeSetup.cancel"), QJsonObject{{QStringLiteral("threadId"), threadId()}},
                     [this](const QJsonValue& result, const std::optional<QString>& error) {
                       if (error || !result.toObject().value(QLatin1String("cancelled")).toBool()) {
                         NativeShell::of(this)->controller<ToastController>()->error(
                             QStringLiteral("Could not cancel the worktree setup"), error.value_or(QStringLiteral("The agent has already started.")));
                       }
                     });
    }
    return true;
  }

private:
  QString environmentId() const { return m_thread.left(m_thread.indexOf(QLatin1Char(':'))); }
  QString threadId() const { return m_thread.mid(m_thread.indexOf(QLatin1Char(':')) + 1); }

  void follow() {
    const QString thread = NativeShell::of(this)->controller<NavigationController>()->threadKey();
    const QString mc = thread.isEmpty() ? QString() : m_store->mcServing(thread.left(thread.indexOf(QLatin1Char(':'))));
    if (thread == m_thread && mc == m_mc) return;
    if (m_subscription >= 0) m_client->unsubscribe(m_subscription);
    m_subscription = -1;
    m_thread = thread;
    m_mc = mc;
    m_snapshot = {};
    m_detailsOpen = false;
    if (!thread.isEmpty() && !mc.isEmpty()) {
      m_subscription = m_client->subscribe(
          this, {{QStringLiteral("type"), QStringLiteral("worktreeSetup")}, {QStringLiteral("mc"), mc}, {QStringLiteral("threadId"), threadId()}},
          [this, thread](const QJsonObject& frame) {
            if (thread != m_thread || frame.value(QLatin1String("t")) != QLatin1String("worktreeSetup")) return;
            m_snapshot = frame.value(QLatin1String("event")).toObject();
            publish();
          });
    }
    publish();
  }

  static QString stageLabel(const QString& id) {
    if (id == QLatin1String("fetch")) return QStringLiteral("Fetch base branch");
    if (id == QLatin1String("checkout")) return QStringLiteral("Check out files");
    if (id == QLatin1String("submodules")) return QStringLiteral("Init submodules");
    if (id == QLatin1String("setup-script")) return QStringLiteral("Run setup script");
    return QStringLiteral("Start agent");
  }

  void publish() {
    if (m_snapshot.isEmpty()) {
      m_bridge->publish(QStringLiteral("worktreeSetup"), QVariant::fromValue(nullptr));
      return;
    }
    const QString phase = m_snapshot.value(QLatin1String("phase")).toString();
    QVariantList stages;
    bool scriptFailed = false;
    for (const QJsonValue& value : m_snapshot.value(QLatin1String("stages")).toArray()) {
      const QJsonObject stage = value.toObject();
      const QString id = stage.value(QLatin1String("id")).toString();
      const QString status = stage.value(QLatin1String("status")).toString();
      scriptFailed = scriptFailed || status == QLatin1String("failed");
      stages.append(QVariantMap{{QStringLiteral("id"), id},
                                {QStringLiteral("label"), stageLabel(id)},
                                {QStringLiteral("status"), status},
                                {QStringLiteral("detail"), stage.value(QLatin1String("detail")).toString()},
                                {QStringLiteral("tail"), stage.value(QLatin1String("tail")).toVariant().toStringList()}});
    }
    // The web's headerLabel.
    const QString label = phase == QLatin1String("running")     ? QStringLiteral("Setting up worktree…")
                          : phase == QLatin1String("failed")    ? QStringLiteral("Worktree setup failed")
                          : phase == QLatin1String("cancelled") ? QStringLiteral("Worktree setup cancelled")
                          : scriptFailed                        ? QStringLiteral("Worktree ready, setup script failed")
                                                                : QStringLiteral("Worktree ready");
    m_bridge->publish(QStringLiteral("worktreeSetup"),
                      QVariantMap{{QStringLiteral("threadKey"), m_thread},
                                  {QStringLiteral("phase"), phase},
                                  {QStringLiteral("label"), label},
                                  {QStringLiteral("error"), m_snapshot.value(QLatin1String("error")).toString()},
                                  {QStringLiteral("branch"), m_snapshot.value(QLatin1String("branch")).toString()},
                                  {QStringLiteral("baseRef"), m_snapshot.value(QLatin1String("baseRef")).toString()},
                                  {QStringLiteral("worktreePath"), m_snapshot.value(QLatin1String("worktreePath")).toString()},
                                  {QStringLiteral("script"), m_snapshot.value(QLatin1String("setupScript")).toObject().value(QLatin1String("name")).toString()},
                                  {QStringLiteral("canCancel"), phase == QLatin1String("running")},
                                  {QStringLiteral("detailsOpen"), m_detailsOpen},
                                  {QStringLiteral("stages"), stages}});
  }

  ShellBridge* m_bridge;
  McClient* m_client;
  ShellStore* m_store;
  bool m_active = false;
  QString m_thread;
  QString m_mc;
  int m_subscription = -1;
  QJsonObject m_snapshot;
  bool m_detailsOpen = false;
};

namespace {
const NativeControllerRegistrar<WorktreeSetupController> registrar(QStringLiteral("worktreeSetup"), {QStringLiteral("worktreeSetup")});
}  // namespace
