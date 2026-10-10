// Starting a thread on a pull request: the user names one (a URL, 42 or
// #42), sees what it is, and chooses where it is checked out.
//
// Publishes `pullRequestThread`: null while closed, else {step ("ask",
// "resolving", "choose" or "starting"), reference, error, pullRequest:
// {number, title, branches ("feature/tax → main"), state} once resolved}.
//
// Actions: `pullRequestThread.open` (also the palette's "Start a thread on a
// pull request…"), `pullRequestThread.resolve {reference}`
// (`git.resolvePullRequest` in the route's project; nothing is checked out),
// `pullRequestThread.start {mode: "local" | "worktree"}`
// (`git.preparePullRequestThread`, then a thread on what it prepared, which
// the window moves to) and `pullRequestThread.cancel`.

#include <QJsonArray>
#include <QJsonObject>
#include <QUuid>
#include <QVariantMap>

#include "KeybindingController.h"
#include "McClient.h"
#include "NativeController.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ToastController.h"
#include "WorkspaceController.h"

class PullRequestThreadController : public QObject, public NativeController {
public:
  PullRequestThreadController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent)
      : QObject(parent), m_bridge(bridge), m_client(client), m_store(store) {}

  void activate() override {
    if (m_active) return;
    m_active = true;
    if (auto* keys = NativeShell::of(this)->controller<KeybindingController>()) {
      keys->commands()->add(QStringLiteral("pullRequestThread.open"), tr("Start a thread on a pull request…"), [this] { open(); });
    }
    publish();
  }

  bool handle(const QString& action, const QVariant& payload) override {
    if (!m_active || !action.startsWith(QLatin1String("pullRequestThread."))) return false;
    const QVariantMap map = payload.toMap();
    if (action == QLatin1String("pullRequestThread.open")) {
      open();
    } else if (action == QLatin1String("pullRequestThread.cancel")) {
      if (m_step != QLatin1String("starting")) close();
    } else if (action == QLatin1String("pullRequestThread.resolve")) {
      resolve(map.value(QStringLiteral("reference")).toString());
    } else if (action == QLatin1String("pullRequestThread.start")) {
      start(map.value(QStringLiteral("mode")).toString());
    }
    return true;
  }

private:
  void open() {
    const auto& place = NativeShell::of(this)->controller<WorkspaceController>()->place();
    if (!place || place->root.isEmpty()) {
      NativeShell::of(this)->controller<ToastController>()->error(tr("Open a project to start a thread on one of its pull requests."));
      return;
    }
    m_environment = place->environmentId;
    m_project = place->projectId;
    m_cwd = place->root;
    m_step = QStringLiteral("ask");
    m_reference.clear();
    m_error.clear();
    m_pullRequest = {};
    ++m_generation;
    publish();
  }

  void close() {
    m_step.clear();
    ++m_generation;
    publish();
  }

  void resolve(const QString& reference) {
    const QString named = reference.trimmed();
    if (m_step.isEmpty() || m_step == QLatin1String("starting") || named.isEmpty()) return;
    m_reference = named;
    m_error.clear();
    m_pullRequest = {};
    m_step = QStringLiteral("resolving");
    publish();
    const quint64 generation = ++m_generation;
    m_client->call(this, m_environment, QStringLiteral("git.resolvePullRequest"), QJsonObject{{QStringLiteral("cwd"), m_cwd}, {QStringLiteral("reference"), named}},
                   [this, generation](const QJsonValue& result, const std::optional<QString>& error) {
                     if (generation != m_generation) return;
                     if (error) {
                       m_step = QStringLiteral("ask");
                       m_error = error->isEmpty() ? tr("The pull request was not found.") : *error;
                     } else {
                       m_pullRequest = result.toObject().value(QLatin1String("pullRequest")).toObject();
                       m_step = QStringLiteral("choose");
                     }
                     publish();
                   });
  }

  void start(const QString& mode) {
    if (m_step != QLatin1String("choose") || (mode != QLatin1String("local") && mode != QLatin1String("worktree"))) return;
    m_step = QStringLiteral("starting");
    m_error.clear();
    publish();
    const quint64 generation = ++m_generation;
    const QString threadId = QUuid::createUuid().toString(QUuid::WithoutBraces);
    const auto failed = [this, generation](const QString& reason) {
      if (generation != m_generation) return;
      m_step = QStringLiteral("choose");
      m_error = reason.isEmpty() ? tr("The pull request could not be checked out.") : reason;
      publish();
    };
    m_client->call(this, m_environment, QStringLiteral("git.preparePullRequestThread"),
                   QJsonObject{{QStringLiteral("cwd"), m_cwd}, {QStringLiteral("reference"), m_reference}, {QStringLiteral("mode"), mode}, {QStringLiteral("threadId"), threadId}},
                   [this, generation, threadId, failed](const QJsonValue& result, const std::optional<QString>& error) {
                     if (generation != m_generation) return;
                     if (error) return failed(*error);
                     const QJsonObject prepared = result.toObject();
                     const QString worktree = prepared.value(QLatin1String("worktreePath")).toString();
                     QJsonObject strategy{{QStringLiteral("type"), worktree.isEmpty() ? QStringLiteral("root") : QStringLiteral("existing_worktree")},
                                          {QStringLiteral("branch"), prepared.value(QLatin1String("branch"))}};
                     if (!worktree.isEmpty()) strategy.insert(QStringLiteral("worktreePath"), worktree);
                     QJsonObject launch{{QStringLiteral("commandId"), QUuid::createUuid().toString(QUuid::WithoutBraces)},
                                        {QStringLiteral("creationSource"), QStringLiteral("web")},
                                        {QStringLiteral("threadId"), threadId},
                                        {QStringLiteral("projectId"), m_project},
                                        {QStringLiteral("title"), QStringLiteral("#%1 %2").arg(m_pullRequest.value(QLatin1String("number")).toInt()).arg(
                                                                      m_pullRequest.value(QLatin1String("title")).toString())},
                                        {QStringLiteral("runtimeMode"), QStringLiteral("full-access")},
                                        {QStringLiteral("interactionMode"), QStringLiteral("default")},
                                        {QStringLiteral("workspaceStrategy"), strategy}};
                     // The project's default model, when it has one; the MC's otherwise.
                     const QJsonValue model = m_store->projectRow(m_environment, m_project).value(QLatin1String("defaultModelSelection"));
                     if (model.isObject()) launch.insert(QStringLiteral("modelSelection"), model);
                     const bool behind = !prepared.value(QLatin1String("isOnPullRequestHead")).toBool(true);
                     m_client->call(this, m_environment, QStringLiteral("orchestration.launchThread"), launch,
                                    [this, generation, threadId, failed, behind](const QJsonValue&, const std::optional<QString>& error) {
                                      if (generation != m_generation) return;
                                      if (error) return failed(*error);
                                      const QString environment = m_environment;
                                      close();
                                      if (behind) {
                                        NativeShell::of(this)->controller<ToastController>()->show(
                                            QStringLiteral("warning"), tr("The checkout is not on the pull request's head"), tr("Its local changes were kept."));
                                      }
                                      NativeShell::of(this)->controller<NavigationController>()->open(
                                          NavigationController::Route::thread(environment + QLatin1Char(':') + threadId));
                                    });
                   });
  }

  void publish() {
    if (m_step.isEmpty()) {
      m_bridge->publish(QStringLiteral("pullRequestThread"), QVariant::fromValue(nullptr));
      return;
    }
    QVariant pullRequest = QVariant::fromValue(nullptr);
    if (!m_pullRequest.isEmpty()) {
      pullRequest = QVariantMap{{QStringLiteral("number"), m_pullRequest.value(QLatin1String("number")).toInt()},
                                {QStringLiteral("title"), m_pullRequest.value(QLatin1String("title")).toString()},
                                {QStringLiteral("branches"), QStringLiteral("%1 → %2").arg(m_pullRequest.value(QLatin1String("headBranch")).toString(),
                                                                                           m_pullRequest.value(QLatin1String("baseBranch")).toString())},
                                {QStringLiteral("state"), m_pullRequest.value(QLatin1String("state")).toString()}};
    }
    m_bridge->publish(QStringLiteral("pullRequestThread"),
                      QVariantMap{{QStringLiteral("step"), m_step}, {QStringLiteral("reference"), m_reference}, {QStringLiteral("error"), m_error},
                                  {QStringLiteral("pullRequest"), pullRequest}});
  }

  ShellBridge* m_bridge;
  McClient* m_client;
  ShellStore* m_store;
  bool m_active = false;
  QString m_step;  // empty while closed
  QString m_environment;
  QString m_project;
  QString m_cwd;
  QString m_reference;
  QString m_error;
  QJsonObject m_pullRequest;
  quint64 m_generation = 0;
};

namespace {
const NativeControllerRegistrar<PullRequestThreadController> registrar(QStringLiteral("pullRequestThread"), {QStringLiteral("pullRequestThread")});
}  // namespace
