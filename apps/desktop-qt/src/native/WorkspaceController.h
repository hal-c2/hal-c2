#pragma once

#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QObject>
#include <QString>
#include <QVariantMap>

#include <functional>
#include <optional>

#include "NativeController.h"

class McClient;
class ShellBridge;
class ShellStore;

// The header and the composer's context strip for the route's thread (a
// draft too), from the MC: publishes `workspace` in the web's
// ShellWorkspaceState shape (packages/contracts shell.ts) less the terminal
// fields, which the Terminals singleton owns. The thread and its project are
// ShellStore rows, the checkout's git status the MC's `vcs` shape, the refs
// `vcs.listRefs`, the editors each environment's `config`.
//
// It takes every `workspace.*` action: `workspace.newThread` opens a draft
// in the header's project (`thread.new`), `workspace.openPullRequest` the
// checkout's pull request in the browser, `workspace.previousWorktree` points
// a draft at the worktree `previousWorktree` ({label} or null) offers. `workspace.titleMenu` is
// ThreadMenuController's, which sees it first.
//
// A draft's checkout (mode, start from origin, branch, worktree, the machine
// it runs on) lives here, keyed by draft id, and launch() turns it into the
// thread ComposerController launches.
class WorkspaceController : public QObject, public NativeController {
  Q_OBJECT

public:
  // Which thread a draft is, and where: DraftController's answer for an id.
  struct DraftPlace {
    QString environmentId;
    QString projectId;
    QString threadId;
  };
  // A new thread's checkout, or the mode picked for a server thread that has
  // not started yet.
  struct Checkout {
    QString envMode = QStringLiteral("local");
    bool startFromOrigin = false;
    std::optional<QString> branch;
    std::optional<QString> worktreePath;
    // "Run on" another machine's checkout; empty keeps the draft's own.
    QString environmentId;
    QString projectId;
  };
  // Where the route's thread is and what its terminals start in.
  struct Place {
    QString environmentId;
    QString threadId;
    QString projectId;
    QString draftId;  // empty for a server thread
    QString root;  // empty while the MC does not know the project
    QString worktreePath;  // empty without a worktree
    QJsonArray scripts;

    QString threadKey() const { return environmentId + QLatin1Char(':') + threadId; }
    QString cwd() const { return worktreePath.isEmpty() ? root : worktreePath; }
  };
  // The checkout's git status as the MC's `vcs` shape has it.
  struct Git {
    QJsonObject local;
    QJsonObject remote;  // empty while unknown
  };

  WorkspaceController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent = nullptr);
  ~WorkspaceController() override;

  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;

  const std::optional<Place>& place() const { return m_place; }
  // The route's checkout status; none while unknown or not followed (a linked
  // environment's, whose `vcs` the MC does not route).
  const std::optional<Git>& git() const { return m_git; }
  // Why the checkout's status could not be followed (a link that is down).
  const QString& gitError() const { return m_gitError; }
  // Asks the MC to read the checkout's status again.
  void refreshGit();
  // How drafts resolve; without one a draft route has no workspace.
  void setDraftResolver(std::function<std::optional<DraftPlace>(const QString& draftId)> resolve);
  // A draft's checkout as the user left it (defaults for one never touched).
  Checkout checkout(const QString& draftId) const { return m_checkouts.value(draftId); }
  // Sets a draft's checkout (a new thread on another thread's branch).
  void setCheckout(const QString& draftId, const Checkout& checkout);
  // Where a draft's first message starts its thread: the environment and
  // project it runs in, and the MC's `workspaceStrategy` for
  // `orchestration.launchThread` ({type: "root" | "existing_worktree" |
  // "worktree", ...}), or `problem` when it cannot start yet.
  struct Launch {
    QString environmentId;
    QString projectId;
    QJsonObject strategy;
    QString problem;
  };
  Launch launch(const QString& draftId) const;
  // The draft is gone (sent or discarded).
  void forgetDraft(const QString& draftId) { m_checkouts.remove(draftId); }
  // Resolves the route again (a draft moved, say).
  void refresh();
  // The ServerConfig of the route's environment: the shell's own
  // (SettingsController::config()), or the one watched on the linked
  // environment the route is on (empty until it arrives).
  QJsonObject environmentConfig() const;

signals:
  // The route's thread, its root or worktree changed.
  void placeChanged();
  // git() changed.
  void gitChanged();
  // environmentConfig() may have changed.
  void configChanged();

private:
  std::optional<Place> resolve() const;
  void follow(const QString& cwd);
  void watchConfig(const QString& environmentId);
  void loadRefs();
  void publish();
  QVariantMap build() const;
  QJsonObject threadRow() const;
  bool locked() const;
  QString envMode() const;
  bool envModeChangeable() const;
  QString currentBranch() const;
  QJsonArray editors() const;
  QString preferredEditor(const QJsonArray& editors) const;
  QVariantList environmentChoices() const;

  void rename(const QString& title);
  void openInEditor(const QString& editorId);
  // `path` of the route's checkout (or absolute) in the preferred editor: a
  // changed file from the diff or the commit review. Says so when there is
  // no editor to open it in.
  void openFileInEditor(const QString& path);
  void runScript(const QString& scriptId);
  void setEnvMode(const QString& mode);
  void setEnvironment(const QString& key);
  void selectBranch(const QString& name);
  void createBranch(const QString& name);
  void setThreadBranch(const std::optional<QString>& branch, const std::optional<QString>& worktreePath);
  // BranchToolbar.logic resolvePreviousWorktreeSeed: for a draft, the
  // worktree of the project's most recently updated unarchived thread that
  // the draft does not already point at.
  struct PreviousWorktree {
    std::optional<QString> branch;
    QString worktreePath;
  };
  std::optional<PreviousWorktree> previousWorktree() const;
  // The draft moves into it (composer.previousWorktree).
  void usePreviousWorktree();
  void updateCheckout(const std::function<void(Checkout&)>& edit);
  void openPullRequest();

  ShellBridge* m_bridge;
  McClient* m_client;
  ShellStore* m_store;
  bool m_active = false;
  std::function<std::optional<DraftPlace>(const QString&)> m_resolveDraft;
  std::optional<Place> m_place;
  std::optional<QVariantMap> m_published;

  QHash<QString, Checkout> m_checkouts;
  // Picked before an empty server thread's first message, by thread key.
  QHash<QString, Checkout> m_pending;
  // The branch a switch is taking the thread to, until the checkout says so.
  std::optional<QString> m_optimisticBranch;
  bool m_switching = false;

  // The checkout's git status (`vcs` shape).
  int m_vcs = 0;
  QString m_vcsKey;
  std::optional<Git> m_git;
  QString m_gitError;
  // Editors of environments other than the MC's own (`config` shape); the
  // MC's own come with SettingsController.
  int m_config = 0;
  QString m_configEnvironment;
  QJsonObject m_configElsewhere;

  // The ref list: loaded when the picker opens or its search changes.
  QString m_query;
  QString m_refsCwd;
  QJsonArray m_refs;
  int m_refsTotal = 0;
  bool m_refsLoading = false;
  quint64 m_refsGeneration = 0;

  // In memory until the shell has somewhere of its own to keep them.
  QHash<QString, QString> m_lastScript;  // by project ("env:projectId")
  int m_renameRequestId = 0;
  QString m_renameWanted;  // a thread asked to rename before it was shown
};
