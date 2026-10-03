#include "GitController.h"

#include <QJsonArray>
#include <QUrl>
#include <QUuid>

#include "NativeShell.h"
#include "McClient.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ToastController.h"
#include "WorkspaceController.h"

namespace {

const NativeControllerRegistrar<GitController> registrar(QStringLiteral("git"), {QStringLiteral("git")});

// How long a finished action's result stays (GIT_ACTION_SUCCESS_VISIBLE_MS).
constexpr int kResultMs = 10000;

QString text(const QJsonObject& row, const char* key) {
  return row.value(QLatin1String(key)).toString();
}

QVariant nullable(const QString& value) {
  return value.isNull() ? QVariant::fromValue(nullptr) : QVariant(value);
}

// What the checkout's host calls a change request (packages/shared sourceControl.ts).
struct Terms {
  QString shortLabel;
  QString singular;
};

Terms terms(const QJsonObject& status) {
  const QString kind = text(status.value(QLatin1String("sourceControlProvider")).toObject(), "kind");
  if (kind == QLatin1String("gitlab")) return {QStringLiteral("MR"), QStringLiteral("merge request")};
  if (kind == QLatin1String("unknown")) return {QStringLiteral("change request"), QStringLiteral("change request")};
  return {QStringLiteral("PR"), QStringLiteral("pull request")};
}

bool openPr(const QJsonObject& status) {
  return text(status.value(QLatin1String("pr")).toObject(), "state") == QLatin1String("open");
}

bool hasBranch(const QJsonObject& status) {
  return !status.value(QLatin1String("refName")).toString().isEmpty();
}

int count(const QJsonObject& status, const char* key) {
  return status.value(QLatin1String(key)).toInt();
}

bool flag(const QJsonObject& status, const char* key) {
  return status.value(QLatin1String(key)).toBool();
}

int aheadOfDefault(const QJsonObject& status) {
  const QJsonValue value = status.value(QLatin1String("aheadOfDefaultCount"));
  return value.isDouble() ? value.toInt() : count(status, "aheadCount");
}

bool includesCommitStep(const QString& action) {
  return action == QLatin1String("commit") || action == QLatin1String("commit_push") ||
         action == QLatin1String("commit_push_pr");
}

// The default-branch question (resolveDefaultBranchActionDialogCopy).
QVariantMap defaultBranchCopy(const QString& action, const QString& branch, bool includesCommit, const Terms& terms) {
  const QString suffix = QStringLiteral(
                             " on \"%1\". You can continue on this ref or create a feature ref and run the same "
                             "action there.")
                             .arg(branch);
  QString title;
  QString description;
  QString continueLabel;
  if (action == QLatin1String("push") || action == QLatin1String("commit_push")) {
    if (includesCommit) {
      title = QStringLiteral("Commit & push to default ref?");
      description = QStringLiteral("This action will commit and push changes") + suffix;
      continueLabel = QStringLiteral("Commit & push to %1").arg(branch);
    } else {
      title = QStringLiteral("Push to default ref?");
      description = QStringLiteral("This action will push local commits") + suffix;
      continueLabel = QStringLiteral("Push to %1").arg(branch);
    }
  } else if (includesCommit) {
    title = QStringLiteral("Commit, push & create %1 from default ref?").arg(terms.shortLabel);
    description = QStringLiteral("This action will commit, push, and create a %1").arg(terms.singular) + suffix;
    continueLabel = QStringLiteral("Commit, push & create %1").arg(terms.shortLabel);
  } else {
    title = QStringLiteral("Push & create %1 from default ref?").arg(terms.shortLabel);
    description = QStringLiteral("This action will push local commits and create a %1").arg(terms.singular) + suffix;
    continueLabel = QStringLiteral("Push & create %1").arg(terms.shortLabel);
  }
  return {
      {QStringLiteral("title"), title},
      {QStringLiteral("description"), description},
      {QStringLiteral("continueLabel"), continueLabel},
      {QStringLiteral("featureBranchLabel"), QStringLiteral("Checkout feature branch & continue")},
  };
}

}  // namespace

GitController::GitController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent)
    : QObject(parent), m_bridge(bridge), m_client(client), m_store(store) {
  m_elapsedTick.setInterval(1000);
  connect(&m_elapsedTick, &QTimer::timeout, this, &GitController::publish);
}

GitController::~GitController() {
  if (m_action) m_client->unsubscribe(m_action);
}

ToastController* GitController::toasts() const {
  return NativeShell::of(this)->controller<ToastController>();
}

WorkspaceController* GitController::workspace() const {
  return NativeShell::of(this)->controller<WorkspaceController>();
}

void GitController::activate() {
  if (m_active) return;
  m_active = true;
  WorkspaceController* header = workspace();
  connect(header, &WorkspaceController::gitChanged, this, &GitController::publish);
  connect(header, &WorkspaceController::placeChanged, this, [this] {
    // A question or dialog about another checkout does not follow the route.
    m_pending.reset();
    m_publishing.reset();
    publish();
  });
  // A stacked action that lost its connection is not resent: the MC would
  // run it a second time.
  connect(m_client, &McClient::readyChanged, this, [this](bool ready) {
    if (ready || !m_action) return;
    finishAction();
    toasts()->show(QStringLiteral("error"), QStringLiteral("Action failed"),
                   QStringLiteral("The connection to the MC dropped while the action ran."), {}, 0);
  });
  publish();
}

std::optional<QJsonObject> GitController::status() const {
  const auto& git = workspace()->git();
  if (!git || git->local.isEmpty()) return std::nullopt;
  QJsonObject status = git->local;
  const QJsonObject& remote = git->remote;
  status.insert(QStringLiteral("hasUpstream"), remote.value(QLatin1String("hasUpstream")).toBool());
  status.insert(QStringLiteral("aheadCount"), remote.value(QLatin1String("aheadCount")).toInt());
  status.insert(QStringLiteral("behindCount"), remote.value(QLatin1String("behindCount")).toInt());
  status.insert(QStringLiteral("pr"), remote.value(QLatin1String("pr")).isObject() ? remote.value(QLatin1String("pr")) : QJsonValue());
  if (remote.contains(QLatin1String("aheadOfDefaultCount"))) {
    status.insert(QStringLiteral("aheadOfDefaultCount"), remote.value(QLatin1String("aheadOfDefaultCount")));
  }
  return status;
}

// resolveGitQuickAction (apps/tui/src/gitActions.logic.ts), in the host's terms.
GitController::Quick GitController::quick() const {
  const bool busy = m_action || m_pulling;
  if (busy) return {QStringLiteral("Commit"), QStringLiteral("show_hint"), {}, QStringLiteral("Git action in progress.")};
  const auto current = status();
  if (!current) return {QStringLiteral("Commit"), QStringLiteral("show_hint"), {}, QStringLiteral("Git status is unavailable.")};
  const QJsonObject& s = *current;
  const Terms t = terms(s);
  const bool changes = flag(s, "hasWorkingTreeChanges");
  const bool pr = openPr(s);
  const bool ahead = count(s, "aheadCount") > 0;
  const bool behind = count(s, "behindCount") > 0;
  const bool upstream = flag(s, "hasUpstream");
  const bool remote = flag(s, "hasPrimaryRemote");
  const bool defaultRef = flag(s, "isDefaultRef");
  const auto runAction = [](const QString& label, const QString& action) {
    return Quick{label, QStringLiteral("run_action"), action, {}};
  };
  const Quick viewPr{QStringLiteral("View %1").arg(t.shortLabel), QStringLiteral("open_pr"), {}, {}};
  const Quick pushAndCreate = runAction(QStringLiteral("Push & create %1").arg(t.shortLabel), QStringLiteral("create_pr"));
  const Quick upToDate{QStringLiteral("Commit"), QStringLiteral("show_hint"), {}, QStringLiteral("Branch is up to date. No action needed.")};

  if (!hasBranch(s)) {
    return {QStringLiteral("Commit"), QStringLiteral("show_hint"), {},
            QStringLiteral("Create and checkout a ref before pushing or opening a %1.").arg(t.singular)};
  }
  if (changes) {
    if (!upstream && !remote) return runAction(QStringLiteral("Commit"), QStringLiteral("commit"));
    if (pr || defaultRef) return runAction(QStringLiteral("Commit & push"), QStringLiteral("commit_push"));
    return runAction(QStringLiteral("Commit, push & %1").arg(t.shortLabel), QStringLiteral("commit_push_pr"));
  }
  if (!upstream) {
    if (!remote) {
      if (pr && !ahead) return viewPr;
      return {QStringLiteral("Publish repository"), QStringLiteral("open_publish"), {}, {}};
    }
    if (!ahead) {
      if (pr) return viewPr;
      return {QStringLiteral("Push"), QStringLiteral("show_hint"), {}, QStringLiteral("No local commits to push.")};
    }
    if (pr || defaultRef) return runAction(QStringLiteral("Push"), QStringLiteral("push"));
    return pushAndCreate;
  }
  if (ahead && behind) {
    return {QStringLiteral("Sync ref"), QStringLiteral("show_hint"), {},
            QStringLiteral("Branch has diverged from upstream. Rebase/merge first.")};
  }
  if (behind) return {QStringLiteral("Pull"), QStringLiteral("run_pull"), {}, {}};
  if (ahead) {
    if (pr || defaultRef) return runAction(QStringLiteral("Push"), QStringLiteral("push"));
    return pushAndCreate;
  }
  if (pr) return viewPr;
  if (aheadOfDefault(s) > 0 && !defaultRef) {
    return runAction(QStringLiteral("Create %1").arg(t.shortLabel), QStringLiteral("create_pr"));
  }
  return upToDate;
}

// buildGitMenuItems (apps/tui/src/gitActions.logic.ts): commit, push, and
// creating or viewing the change request; only commit without a remote.
QVariantList GitController::menu() const {
  const auto current = status();
  if (!current) return {};
  const QJsonObject& s = *current;
  const Terms t = terms(s);
  const bool busy = m_action || m_pulling;
  const bool changes = flag(s, "hasWorkingTreeChanges");
  const bool pr = openPr(s);
  const bool behind = count(s, "behindCount") > 0;
  const bool remoteReady = flag(s, "hasUpstream") || flag(s, "hasPrimaryRemote");
  const bool canCommit = !busy && changes;
  const bool canPush = !busy && hasBranch(s) && !behind && count(s, "aheadCount") > 0 && remoteReady;
  const bool canCreatePr = !busy && hasBranch(s) && !changes && !pr && aheadOfDefault(s) > 0 && !behind && remoteReady;

  const auto item = [this](const QString& id, const QString& label, bool enabled) {
    return QVariantMap{{QStringLiteral("id"), id},
                       {QStringLiteral("label"), label},
                       {QStringLiteral("disabledReason"), enabled ? QVariant::fromValue(nullptr) : QVariant(menuReason(id))}};
  };
  QVariantList items{item(QStringLiteral("commit"), QStringLiteral("Commit"), canCommit)};
  if (!flag(s, "hasPrimaryRemote")) return items;
  items.append(item(QStringLiteral("push"), QStringLiteral("Push"), canPush));
  items.append(pr ? item(QStringLiteral("pr"), QStringLiteral("View %1").arg(t.shortLabel), !busy)
                  : item(QStringLiteral("pr"), QStringLiteral("Create %1").arg(t.shortLabel), canCreatePr));
  return items;
}

// Why a menu entry cannot run (menuItemDisabledHint).
QString GitController::menuReason(const QString& id) const {
  if (m_action || m_pulling) return QStringLiteral("Git action in progress.");
  const QJsonObject s = status().value_or(QJsonObject{});
  const Terms t = terms(s);
  if (id == QLatin1String("commit")) return QStringLiteral("No uncommitted changes.");
  const bool behind = count(s, "behindCount") > 0;
  if (id == QLatin1String("push")) {
    if (behind) return QStringLiteral("Pull or rebase before pushing.");
    if (!hasBranch(s)) return QStringLiteral("Checkout a branch before pushing.");
    if (!flag(s, "hasPrimaryRemote")) return QStringLiteral("Publish the repository before pushing.");
    return QStringLiteral("No local commits to push.");
  }
  if (behind) return QStringLiteral("Pull or rebase before creating a %1.").arg(t.shortLabel);
  if (!hasBranch(s)) return QStringLiteral("Checkout a branch before creating a %1.").arg(t.shortLabel);
  if (flag(s, "hasWorkingTreeChanges")) return QStringLiteral("Commit changes before creating a %1.").arg(t.shortLabel);
  return QStringLiteral("No commits are ready for a %1.").arg(t.shortLabel);
}

void GitController::publish() {
  if (!m_active) return;
  const auto& place = workspace()->place();
  // A link that is down says why when the checkout's status is followed.
  const QString unreachable = workspace()->gitError();
  if (place && (!m_store->environmentOnline(place->environmentId) || !unreachable.isEmpty())) {
    QVariantMap git{{QStringLiteral("available"), false}};
    if (!unreachable.isEmpty()) git.insert(QStringLiteral("unavailableReason"), unreachable);
    m_bridge->publish(QStringLiteral("git"), git);
    return;
  }
  if (!place || place->cwd().isEmpty()) {
    m_bridge->publish(QStringLiteral("git"), QVariantMap{{QStringLiteral("available"), false}});
    return;
  }
  const auto current = status();
  const QJsonObject s = current.value_or(QJsonObject{});
  const Quick action = quick();
  QStringList hints;
  if (current && flag(s, "isRepo") && !hasBranch(s)) {
    hints.append(QStringLiteral("Detached HEAD: check out a branch to push or open a %1.").arg(terms(s).singular));
  }
  if (count(s, "behindCount") > 0) {
    hints.append(QStringLiteral("Behind upstream by %1 — pull or rebase before pushing.").arg(count(s, "behindCount")));
  }
  QVariantList files;
  for (const QJsonValue& value : s.value(QLatin1String("workingTree")).toObject().value(QLatin1String("files")).toArray()) {
    const QJsonObject file = value.toObject();
    files.append(QVariantMap{{QStringLiteral("path"), text(file, "path")},
                             {QStringLiteral("insertions"), file.value(QLatin1String("insertions")).toInt()},
                             {QStringLiteral("deletions"), file.value(QLatin1String("deletions")).toInt()}});
  }
  QVariant pending = QVariant::fromValue(nullptr);
  if (m_pending) pending = defaultBranchCopy(m_pending->action, m_pending->branch, m_pending->includesCommit, terms(s));
  // The web's formatGitActionElapsed.
  QVariant progress = QVariant::fromValue(nullptr);
  if (m_action != 0 && m_startedAt.isValid()) {
    const qint64 seconds = std::max<qint64>(0, m_startedAt.secsTo(toasts()->now()));
    progress = QVariantMap{{QStringLiteral("stage"), m_stage},
                           {QStringLiteral("elapsed"), seconds < 60 ? QStringLiteral("%1s").arg(seconds)
                                                                    : QStringLiteral("%1m %2s").arg(seconds / 60).arg(seconds % 60)},
                           {QStringLiteral("hookLine"), nullable(m_hookLine)}};
  }
  QVariant publishing = QVariant::fromValue(nullptr);
  if (m_publishing) {
    publishing = QVariantMap{{QStringLiteral("busy"), m_publishing->busy}, {QStringLiteral("error"), nullable(m_publishing->error)}};
  }
  m_bridge->publish(
      QStringLiteral("git"),
      QVariantMap{
          {QStringLiteral("available"), true},
          // Taken for a repository until the MC says otherwise, so Initialize Git does not flash.
          {QStringLiteral("isRepo"), current ? flag(s, "isRepo") : true},
          {QStringLiteral("busy"), m_action != 0 || m_pulling},
          {QStringLiteral("initPending"), m_initPending},
          {QStringLiteral("quickAction"),
           QVariantMap{{QStringLiteral("label"), action.label},
                       {QStringLiteral("disabledReason"), action.kind == QLatin1String("show_hint") ? QVariant(action.hint) : QVariant::fromValue(nullptr)},
                       {QStringLiteral("kind"), action.kind}}},
          {QStringLiteral("menu"), menu()},
          {QStringLiteral("canPublish"), current && flag(s, "isRepo") && !flag(s, "hasPrimaryRemote")},
          {QStringLiteral("hints"), hints},
          {QStringLiteral("branch"), current && hasBranch(s) ? QVariant(text(s, "refName")) : QVariant::fromValue(nullptr)},
          {QStringLiteral("isDefaultRef"), flag(s, "isDefaultRef")},
          {QStringLiteral("files"), files},
          {QStringLiteral("pendingDefaultBranch"), pending},
          {QStringLiteral("publishing"), publishing},
          {QStringLiteral("progress"), progress},
      });
}

bool GitController::handle(const QString& action, const QVariant& payload) {
  if (!m_active || !action.startsWith(QLatin1String("git."))) return false;
  const QVariantMap args = payload.toMap();
  const auto& place = workspace()->place();
  const bool ready = place && !place->cwd().isEmpty() && m_store->environmentOnline(place->environmentId);
  if (!ready) return true;
  if (action == QLatin1String("git.quick")) {
    runQuick();
  } else if (action == QLatin1String("git.menu")) {
    runMenu(args.value(QStringLiteral("id")).toString());
  } else if (action == QLatin1String("git.commit")) {
    const QVariant paths = args.value(QStringLiteral("filePaths"));
    std::optional<QStringList> filePaths;
    if (paths.isValid() && !paths.isNull()) filePaths = paths.toStringList();
    const bool featureBranch = args.value(QStringLiteral("featureBranch")).toBool();
    run(QStringLiteral("commit"), args.value(QStringLiteral("message")).toString().trimmed(), filePaths, featureBranch,
        featureBranch);
  } else if (action == QLatin1String("git.defaultBranch")) {
    if (!m_pending) return true;
    const Pending pending = *std::exchange(m_pending, std::nullopt);
    const QString choice = args.value(QStringLiteral("choice")).toString();
    if (choice == QLatin1String("continue")) {
      run(pending.action, pending.message, pending.filePaths, false, true);
    } else if (choice == QLatin1String("featureBranch")) {
      run(pending.action, pending.message, pending.filePaths, true, true);
    } else {
      publish();
    }
  } else if (action == QLatin1String("git.init")) {
    init();
  } else if (action == QLatin1String("git.publish")) {
    m_publishing = Publishing{};
    publish();
  } else if (action == QLatin1String("git.publish.cancel")) {
    if (m_publishing && !m_publishing->busy) m_publishing.reset();
    publish();
  } else if (action == QLatin1String("git.publish.submit")) {
    submitPublish(args);
  } else if (action == QLatin1String("git.refresh")) {
    workspace()->refreshGit();
  }
  return true;
}

void GitController::runQuick() {
  const Quick action = quick();
  if (action.kind == QLatin1String("run_action")) {
    run(action.action);
  } else if (action.kind == QLatin1String("run_pull")) {
    pull();
  } else if (action.kind == QLatin1String("open_publish")) {
    m_publishing = Publishing{};
    publish();
  } else if (action.kind == QLatin1String("open_pr")) {
    openPullRequest();
  } else {
    toasts()->show(QStringLiteral("info"), action.label, action.hint);
  }
}

// "commit" opens the brick's dialog, which comes back as `git.commit`.
void GitController::runMenu(const QString& id) {
  for (const QVariant& value : menu()) {
    const QVariantMap item = value.toMap();
    if (item.value(QStringLiteral("id")) != id || !item.value(QStringLiteral("disabledReason")).isNull()) continue;
    if (id == QLatin1String("push")) {
      run(QStringLiteral("push"));
    } else if (id == QLatin1String("pr")) {
      if (status() && openPr(*status())) {
        openPullRequest();
      } else {
        run(QStringLiteral("create_pr"));
      }
    }
    return;
  }
}

void GitController::openPullRequest() {
  const auto current = status();
  const QString url = current ? text(current->value(QLatin1String("pr")).toObject(), "url") : QString();
  if (!url.isEmpty()) m_bridge->openExternal(QUrl(url));
}

void GitController::run(const QString& action, const QString& message, const std::optional<QStringList>& filePaths,
                        bool featureBranch, bool confirmed) {
  if (m_action || m_pulling) return;
  const auto current = status();
  const QString branch = current && hasBranch(*current) ? text(*current, "refName") : QString();
  const bool defaultRef = !featureBranch && current && flag(*current, "isDefaultRef");
  const bool landsOnDefault = action == QLatin1String("push") || action == QLatin1String("create_pr") ||
                              action == QLatin1String("commit_push") || action == QLatin1String("commit_push_pr");
  if (!confirmed && defaultRef && landsOnDefault && !branch.isEmpty()) {
    const bool includesCommit = includesCommitStep(action) &&
                                (action == QLatin1String("commit") || (current && flag(*current, "hasWorkingTreeChanges")));
    m_pending = Pending{action, branch, includesCommit, message, filePaths};
    publish();
    return;
  }
  const WorkspaceController::Place place = *workspace()->place();
  QJsonObject input{
      {QStringLiteral("actionId"), QUuid::createUuid().toString(QUuid::WithoutBraces)},
      {QStringLiteral("cwd"), place.cwd()},
      {QStringLiteral("action"), action},
  };
  if (!message.isEmpty()) input.insert(QStringLiteral("commitMessage"), message);
  if (featureBranch) input.insert(QStringLiteral("featureBranch"), true);
  if (filePaths) input.insert(QStringLiteral("filePaths"), QJsonArray::fromStringList(*filePaths));
  // A pull request the action opens is linked to the thread it ran beside;
  // a draft has no thread on the MC yet.
  if (place.draftId.isEmpty()) {
    input.insert(QStringLiteral("threadId"), place.threadId);
  } else {
    input.insert(QStringLiteral("projectId"), place.projectId);
  }
  m_stage = QStringLiteral("Starting source control action...");
  m_startedAt = toasts()->now();
  m_hookLine.clear();
  m_elapsedTick.start();
  m_progressToast = toasts()->show(QStringLiteral("loading"), m_stage, {}, {}, 0);
  m_action = m_client->subscribe(this, 
      {
          {QStringLiteral("type"), QStringLiteral("gitAction")},
          {QStringLiteral("environment"), place.environmentId},
          {QStringLiteral("input"), input},
      },
      [this](const QJsonObject& frame) { onActionFrame(frame); });
  publish();
}

void GitController::onActionFrame(const QJsonObject& frame) {
  const QString type = text(frame, "t");
  if (type == QLatin1String("error")) {
    finishAction();
    toasts()->show(QStringLiteral("error"), QStringLiteral("Action failed"),
                   frame.value(QLatin1String("reason")).toVariant().toString(), {}, 0);
    return;
  }
  if (type != QLatin1String("gitAction")) return;
  const QJsonObject event = frame.value(QLatin1String("event")).toObject();
  const QString kind = text(event, "kind");
  if (kind == QLatin1String("phase_started")) {
    const QString label = text(event, "label");
    if (!label.isEmpty() && label != QLatin1String("Running source control action")) m_stage = label;
    toasts()->update(m_progressToast, m_stage);
    publish();
  } else if (kind == QLatin1String("hook_output")) {
    const QStringList lines = text(event, "text").split(QLatin1Char('\n'), Qt::SkipEmptyParts);
    if (!lines.isEmpty()) {
      m_hookLine = lines.last().trimmed();
      toasts()->update(m_progressToast, m_stage, m_hookLine);
      publish();
    }
  } else if (kind == QLatin1String("action_failed")) {
    finishAction();
    toasts()->show(QStringLiteral("error"), QStringLiteral("Action failed"), text(event, "message"), {}, 0);
  } else if (kind == QLatin1String("action_finished")) {
    const QJsonObject result = event.value(QLatin1String("result")).toObject();
    finishAction();
    syncBranch(result);
    const QJsonObject toast = result.value(QLatin1String("toast")).toObject();
    const QJsonObject cta = toast.value(QLatin1String("cta")).toObject();
    std::optional<ToastController::Action> next;
    if (text(cta, "kind") == QLatin1String("open_pr")) {
      const QUrl url(text(cta, "url"));
      next = ToastController::Action{text(cta, "label"), [this, url] { m_bridge->openExternal(url); }};
    } else if (text(cta, "kind") == QLatin1String("run_action")) {
      const QString nextAction = text(cta.value(QLatin1String("action")).toObject(), "kind");
      next = ToastController::Action{text(cta, "label"), [this, nextAction] { run(nextAction); }};
    }
    toasts()->show(QStringLiteral("success"), text(toast, "title"), text(toast, "description"), next, kResultMs);
  }
}

void GitController::finishAction() {
  if (m_action) m_client->unsubscribe(m_action);
  m_action = 0;
  m_elapsedTick.stop();
  m_startedAt = {};
  if (!m_progressToast.isEmpty()) toasts()->dismiss(m_progressToast);
  m_progressToast.clear();
  workspace()->refreshGit();
  publish();
}

// A branch the action made is the thread's (or the draft's) from now on.
void GitController::syncBranch(const QJsonObject& result) {
  const QJsonObject branch = result.value(QLatin1String("branch")).toObject();
  const QString name = text(branch, "name");
  if (text(branch, "status") != QLatin1String("created") || name.isEmpty()) return;
  const auto& place = workspace()->place();
  if (!place) return;
  if (!place->draftId.isEmpty()) {
    WorkspaceController::Checkout checkout = workspace()->checkout(place->draftId);
    checkout.branch = name;
    workspace()->setCheckout(place->draftId, checkout);
    return;
  }
  m_client->dispatchCommand(this, place->environmentId,
                            {
                                {QStringLiteral("type"), QStringLiteral("thread.metadata.update")},
                                {QStringLiteral("threadId"), place->threadId},
                                {QStringLiteral("branch"), name},
                            },
                            [](const QJsonValue&, const std::optional<QString>&) {});
}

void GitController::pull() {
  if (m_action || m_pulling) return;
  m_pulling = true;
  const QString toast = toasts()->show(QStringLiteral("loading"), QStringLiteral("Pulling latest changes..."), {}, {}, 0);
  publish();
  const auto& place = workspace()->place();
  m_client->call(this, place->environmentId, QStringLiteral("vcs.pull"), QJsonObject{{QStringLiteral("cwd"), place->cwd()}},
                 [this, toast](const QJsonValue& result, const std::optional<QString>& error) {
                   m_pulling = false;
                   toasts()->dismiss(toast);
                   if (error) {
                     toasts()->show(QStringLiteral("error"), QStringLiteral("Pull failed"),
                                    error->isEmpty() ? QStringLiteral("An error occurred.") : *error, {}, 0);
                   } else {
                     const QJsonObject pulled = result.toObject();
                     const QString ref = text(pulled, "refName");
                     if (text(pulled, "status") == QLatin1String("pulled")) {
                       const QString upstream = text(pulled, "upstreamRef");
                       toasts()->show(QStringLiteral("success"), QStringLiteral("Pulled"),
                                      QStringLiteral("Updated %1 from %2").arg(ref, upstream.isEmpty() ? QStringLiteral("upstream") : upstream),
                                      {}, kResultMs);
                     } else {
                       toasts()->show(QStringLiteral("success"), QStringLiteral("Already up to date"),
                                      QStringLiteral("%1 is already synchronized.").arg(ref), {}, kResultMs);
                     }
                   }
                   workspace()->refreshGit();
                   publish();
                 });
}

void GitController::init() {
  if (m_initPending) return;
  m_initPending = true;
  publish();
  const auto& place = workspace()->place();
  m_client->call(this, place->environmentId, QStringLiteral("vcs.init"), QJsonObject{{QStringLiteral("cwd"), place->cwd()}},
                 [this](const QJsonValue&, const std::optional<QString>& error) {
                   m_initPending = false;
                   if (error) toasts()->error(QStringLiteral("Git initialization failed"), *error);
                   workspace()->refreshGit();
                   publish();
                 });
}

// The dialog stays open with the MC's reason when publishing fails.
void GitController::submitPublish(const QVariantMap& args) {
  if (!m_publishing || m_publishing->busy) return;
  const QString repository = args.value(QStringLiteral("repository")).toString().trimmed();
  const qsizetype slash = repository.indexOf(QLatin1Char('/'));
  if (slash <= 0 || repository.mid(slash + 1).trimmed().isEmpty()) {
    m_publishing->error = QStringLiteral("Name the repository as owner/name.");
    publish();
    return;
  }
  QString remoteName = args.value(QStringLiteral("remoteName")).toString().trimmed();
  if (remoteName.isEmpty()) remoteName = QStringLiteral("origin");
  m_publishing = Publishing{true, {}};
  publish();
  const auto& place = workspace()->place();
  m_client->call(this, place->environmentId, QStringLiteral("sourceControl.publishRepository"),
                 QJsonObject{
                     {QStringLiteral("cwd"), place->cwd()},
                     {QStringLiteral("provider"), args.value(QStringLiteral("provider"), QStringLiteral("github")).toString()},
                     {QStringLiteral("repository"), repository},
                     {QStringLiteral("visibility"), args.value(QStringLiteral("visibility"), QStringLiteral("private")).toString()},
                     {QStringLiteral("remoteName"), remoteName},
                     {QStringLiteral("protocol"), args.value(QStringLiteral("protocol"), QStringLiteral("ssh")).toString()},
                 },
                 [this](const QJsonValue& result, const std::optional<QString>& error) {
                   if (!m_publishing) return;
                   if (error) {
                     m_publishing = Publishing{false, error->isEmpty() ? QStringLiteral("An error occurred.") : *error};
                     publish();
                     return;
                   }
                   m_publishing.reset();
                   const QJsonObject published = result.toObject();
                   const QJsonObject repository = published.value(QLatin1String("repository")).toObject();
                   const QString name = text(repository, "nameWithOwner");
                   const QString description =
                       text(published, "status") == QLatin1String("pushed")
                           ? QStringLiteral("Pushed %1 to %2.").arg(text(published, "branch"), text(published, "remoteName"))
                           : QStringLiteral("Added the remote %1.").arg(text(published, "remoteName"));
                   const QUrl url(text(repository, "url"));
                   std::optional<ToastController::Action> open;
                   if (url.isValid() && !url.isEmpty()) {
                     open = ToastController::Action{QStringLiteral("Open repository"), [this, url] { m_bridge->openExternal(url); }};
                   }
                   toasts()->show(QStringLiteral("success"),
                                  QStringLiteral("Published %1").arg(name.isEmpty() ? QStringLiteral("the repository") : name),
                                  description, open, kResultMs);
                   workspace()->refreshGit();
                   publish();
                 });
}
