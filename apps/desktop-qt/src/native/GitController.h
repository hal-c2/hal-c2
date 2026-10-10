#pragma once

#include <QJsonObject>
#include <QDateTime>
#include <QObject>
#include <QString>
#include <QStringList>
#include <QTimer>
#include <QVariant>

#include <optional>

#include "NativeController.h"

class McClient;
class ShellBridge;
class ShellStore;
class ToastController;
class WorkspaceController;

// The header's git pill for the route's checkout: publishes `git` in the
// ShellGitState shape (packages/contracts shell.ts) the GitActions brick
// draws, from WorkspaceController's `vcs` status, and runs what it sends.
//
// The recommended action and the menu follow the checkout as the TUI's
// gitActions.logic.ts decides them (features/source-control/git-actions.feature),
// named for the host's change requests. Commit, push and pull request run
// once each through the MC's `gitAction` shape, whose stages update one
// loading toast, and `git.progress` ({stage, elapsed, hookLine}: the stage,
// how long the action has run and the last line a hook printed) for the pill,
// republished once a second while it runs; anything that would land on the default branch waits for
// `git.defaultBranch`. Pull is `vcs.pull`, Initialize Git `vcs.init`, and
// Publish repository `sourceControl.publishRepository` from the brick's own
// dialog (`git.publish` opens it), which walks through the host (with whether
// it is installed and signed in, from `server.discoverSourceControl`), the
// repository and a summary to confirm. Actions on another machine of the
// cluster run there; one that is unreachable says why.
class GitController : public QObject, public NativeController {
  Q_OBJECT

public:
  GitController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent = nullptr);
  ~GitController() override;

  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;

private:
  // The checkout's local and remote status as one (VcsStatusResult); none
  // before the first local status.
  std::optional<QJsonObject> status() const;
  struct Quick {
    QString label;
    QString kind;  // run_action, run_pull, open_publish, open_pr, show_hint
    QString action;  // the stacked action of run_action
    QString hint;  // why it cannot run
  };
  Quick quick() const;
  QVariantList menu() const;
  QString menuReason(const QString& id) const;

  void publish();
  void runQuick();
  void runMenu(const QString& id);
  // A stacked action; asks first when it would land on the default branch.
  void run(const QString& action, const QString& message = {}, const std::optional<QStringList>& filePaths = {},
           bool featureBranch = false, bool confirmed = false);
  void pull();
  void init();
  // Opens the publish dialog and asks the MC which hosts are ready.
  void openPublish();
  void submitPublish(const QVariantMap& args);
  void openPullRequest();
  void onActionFrame(const QJsonObject& frame);
  void finishAction();
  void syncBranch(const QJsonObject& result);

  ToastController* toasts() const;
  WorkspaceController* workspace() const;

  ShellBridge* m_bridge;
  McClient* m_client;
  ShellStore* m_store;
  bool m_active = false;
  bool m_pulling = false;
  bool m_initPending = false;

  // The running stacked action: its `gitAction` subscription and the toast
  // that shows its stage.
  int m_action = 0;
  QString m_progressToast;
  QString m_stage;
  QDateTime m_startedAt;
  QString m_hookLine;
  // Redraws the elapsed time while an action runs.
  QTimer m_elapsedTick;

  struct Pending {
    QString action;
    QString branch;
    bool includesCommit = false;
    QString message;
    std::optional<QStringList> filePaths;
  };
  std::optional<Pending> m_pending;

  // The publish dialog, while open.
  struct Publishing {
    bool busy = false;
    QString error;
    // The hosts it can publish to: [{value, label, ready, hint, account}],
    // `hint` saying how to make a host ready. Until the MC answers, none is ready.
    QVariantList hosts;
  };
  std::optional<Publishing> m_publishing;
};
