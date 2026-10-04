// The header's git actions (GitController) against the MC's source control:
// source-control/git-actions.feature, push-pull-and-default-branch.feature,
// and commit-and-generated-messages.feature.
//
// FakeCheckout is one checkout at /work/<project> as the MC reports it
// (`vcs` status) and changes it: `gitAction` runs commit, push and pull
// request the way git_actions.ex does, with its stages, hook lines and
// result toast; `vcs.pull`, `vcs.init`, `vcs.refreshStatus` and
// `sourceControl.publishRepository` answer as the MC does.

#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>
#include <QRegularExpression>
#include <QTest>
#include <QUrl>

#include <memory>
#include <optional>
#include <utility>

#include "Brick.h"
#include "CommandPaletteController.h"
#include "Harness.h"
#include "KeybindingController.h"
#include "NavigationController.h"
#include "World.h"

namespace {

const QString kThread = QStringLiteral("t1");
const QString kPrUrl = QStringLiteral("https://github.com/acme/shop/pull/42");

struct FakeCheckout {
  QString cwd;
  QString remoteName = QStringLiteral("origin");
  bool known = true;  // the MC has sent its status
  bool isRepo = true;
  std::optional<QString> branch = QStringLiteral("feature/tax");  // none on a detached HEAD
  QString defaultBranch = QStringLiteral("main");
  QString provider = QStringLiteral("github");
  bool hasRemote = true;
  bool upstream = true;
  QStringList ahead;  // local commits the upstream lacks, by subject
  int behind = 0;
  std::optional<int> aheadOfDefault;
  QStringList changed;
  bool pr = false;  // an open pull request for the branch

  struct Commit {
    QString subject;
    QStringList files;
    QString branch;
    QString sha;
  };
  QList<QJsonObject> inputs;  // every `gitAction` input
  QList<Commit> commits;
  QHash<QString, QStringList> remote;  // what each remote branch holds, by "origin/<branch>"
  int pulled = 0;  // commits a pull brought in
  QList<QJsonObject> publishes;
  bool initialized = false;
  QString generatedMessage = QStringLiteral("Add tax to the cart line");

  // What the next action does instead of finishing at once.
  QString hookLine;  // the pre-commit hook prints it
  bool waitAfterHook = false;  // the action waits there until released
  bool waitWhileWriting = false;  // the action waits while its message is written
  QString failPhase = QStringLiteral("commit");  // the stage a failing action fails in
  std::optional<int> held;
  QString failWith;
  QString refusePull;
  QString refuseInit;
  QString refusePublish;
  // A change made outside HAL-C2, seen when the MC next looks.
  bool outsideChange = false;
};

QJsonObject local(const FakeCheckout& git) {
  if (!git.known) return {};
  if (!git.isRepo) return {{QStringLiteral("isRepo"), false}};
  QJsonArray files;
  for (const QString& path : git.changed) {
    files.append(QJsonObject{{QStringLiteral("path"), path}, {QStringLiteral("insertions"), 3}, {QStringLiteral("deletions"), 1}});
  }
  QJsonObject status{
      {QStringLiteral("isRepo"), true},
      {QStringLiteral("isDefaultRef"), git.branch == git.defaultBranch},
      {QStringLiteral("hasWorkingTreeChanges"), !git.changed.isEmpty()},
      {QStringLiteral("hasPrimaryRemote"), git.hasRemote},
      {QStringLiteral("sourceControlProvider"), QJsonObject{{QStringLiteral("kind"), git.provider}}},
      {QStringLiteral("workingTree"), QJsonObject{{QStringLiteral("files"), files}}},
  };
  status.insert(QStringLiteral("refName"), git.branch ? QJsonValue(*git.branch) : QJsonValue());
  return status;
}

QJsonObject remote(const FakeCheckout& git) {
  if (!git.known || !git.isRepo) return {};
  QJsonObject status{
      {QStringLiteral("hasUpstream"), git.upstream},
      {QStringLiteral("aheadCount"), git.ahead.size()},
      {QStringLiteral("behindCount"), git.behind},
      {QStringLiteral("pr"), git.pr ? QJsonValue(QJsonObject{{QStringLiteral("number"), 42},
                                                              {QStringLiteral("title"), QStringLiteral("Tax line")},
                                                              {QStringLiteral("url"), kPrUrl},
                                                              {QStringLiteral("state"), QStringLiteral("open")}})
                                    : QJsonValue()},
  };
  if (git.aheadOfDefault) status.insert(QStringLiteral("aheadOfDefaultCount"), *git.aheadOfDefault);
  return status;
}

// The checkout's status, to whoever follows it.
void sendStatus(FakeMc& mc) {
  const FakeCheckout& git = mc.part<FakeCheckout>();
  for (const int id : mc.subscribers(QStringLiteral("vcs"))) {
    if (mc.shapeOf(id).value(QLatin1String("cwd")) != git.cwd) continue;
    mc.send({{QStringLiteral("t"), QStringLiteral("vcs")},
               {QStringLiteral("id"), id},
               {QStringLiteral("event"), QJsonObject{{QStringLiteral("_tag"), QStringLiteral("localUpdated")}, {QStringLiteral("local"), local(git)}}}});
    mc.send({{QStringLiteral("t"), QStringLiteral("vcs")},
               {QStringLiteral("id"), id},
               {QStringLiteral("event"), QJsonObject{{QStringLiteral("_tag"), QStringLiteral("remoteUpdated")}, {QStringLiteral("remote"), remote(git)}}}});
  }
}

void sendEvent(FakeMc& mc, int id, const QJsonObject& event) {
  mc.send({{QStringLiteral("t"), QStringLiteral("gitAction")}, {QStringLiteral("id"), id}, {QStringLiteral("event"), event}});
}

void phase(FakeMc& mc, int id, const QString& phase, const QString& label) {
  sendEvent(mc, id, {{QStringLiteral("kind"), QStringLiteral("phase_started")}, {QStringLiteral("phase"), phase}, {QStringLiteral("label"), label}});
}

QString slug(const QString& text) {
  return text.toLower().replace(QRegularExpression(QStringLiteral("[^a-z0-9]+")), QStringLiteral("-")).remove(QRegularExpression(QStringLiteral("^-|-$")));
}

// The rest of the action, after the pre-commit hook (git_actions.ex run/3 and toast/2).
void finish(FakeMc& mc, int id, const QJsonObject& input) {
  FakeCheckout& git = mc.part<FakeCheckout>();
  const QString action = input.value(QLatin1String("action")).toString();
  const bool commits = action.startsWith(QLatin1String("commit"));
  const bool pushes = action.contains(QLatin1String("push"));
  const bool opensPr = action.endsWith(QLatin1String("pr"));
  QString message = input.value(QLatin1String("commitMessage")).toString();
  if (message.isEmpty()) message = git.generatedMessage;

  QJsonObject branch{{QStringLiteral("status"), QStringLiteral("skipped_not_requested")}};
  if (input.value(QLatin1String("featureBranch")).toBool()) {
    git.branch = QStringLiteral("feature/") + slug(message);
    git.upstream = false;
    branch = {{QStringLiteral("status"), QStringLiteral("created")}, {QStringLiteral("name"), *git.branch}};
  }

  QJsonObject commit{{QStringLiteral("status"), QStringLiteral("skipped_not_requested")}};
  if (commits && !git.changed.isEmpty()) {
    QStringList files = git.changed;
    if (input.value(QLatin1String("filePaths")).isArray()) {
      files.clear();
      for (const QJsonValue& path : input.value(QLatin1String("filePaths")).toArray()) files.append(path.toString());
    }
    const QString sha = QStringLiteral("abc%1def0123456789").arg(git.commits.size() + 1, 4, 10, QLatin1Char('0'));
    for (const QString& file : std::as_const(files)) git.changed.removeAll(file);
    git.ahead.append(message);
    git.commits.append({message, files, git.branch.value_or(QString()), sha});
    commit = {{QStringLiteral("status"), QStringLiteral("created")}, {QStringLiteral("commitSha"), sha}, {QStringLiteral("subject"), message}};
  }

  QJsonObject push{{QStringLiteral("status"), QStringLiteral("skipped_not_requested")}};
  if (pushes || opensPr) {
    phase(mc, id, QStringLiteral("push"), QStringLiteral("Pushing..."));
    const QString target = git.remoteName + QLatin1Char('/') + git.branch.value_or(QString());
    git.remote[target].append(git.ahead);
    git.ahead.clear();
    git.upstream = true;
    push = {{QStringLiteral("status"), QStringLiteral("pushed")}, {QStringLiteral("branch"), git.branch.value_or(QString())}, {QStringLiteral("upstreamBranch"), target}};
  }

  QJsonObject pr{{QStringLiteral("status"), QStringLiteral("skipped_not_requested")}};
  if (opensPr) {
    phase(mc, id, QStringLiteral("pr"), QStringLiteral("Preparing PR..."));
    git.pr = true;
    pr = {{QStringLiteral("status"), QStringLiteral("created")}, {QStringLiteral("number"), 42}, {QStringLiteral("title"), message}, {QStringLiteral("url"), kPrUrl}};
  }

  const QString sha = commit.value(QLatin1String("commitSha")).toString().left(7);
  QJsonObject toast;
  if (opensPr) {
    toast = {{QStringLiteral("title"), QStringLiteral("Created PR #42")}, {QStringLiteral("description"), message}};
  } else if (push.value(QLatin1String("status")) == QLatin1String("pushed")) {
    toast = {{QStringLiteral("title"), QStringLiteral("Pushed%1 to %2").arg(sha.isEmpty() ? QString() : QLatin1Char(' ') + sha, push.value(QLatin1String("upstreamBranch")).toString())}};
    if (!sha.isEmpty()) toast.insert(QStringLiteral("description"), message);
  } else if (!sha.isEmpty()) {
    toast = {{QStringLiteral("title"), QStringLiteral("Committed ") + sha}, {QStringLiteral("description"), message}};
  } else {
    toast = {{QStringLiteral("title"), QStringLiteral("Done")}};
  }
  QJsonObject cta{{QStringLiteral("kind"), QStringLiteral("none")}};
  if (action == QLatin1String("commit") && !sha.isEmpty()) {
    cta = {{QStringLiteral("kind"), QStringLiteral("run_action")}, {QStringLiteral("label"), QStringLiteral("Push")}, {QStringLiteral("action"), QJsonObject{{QStringLiteral("kind"), QStringLiteral("push")}}}};
  } else if (opensPr) {
    cta = {{QStringLiteral("kind"), QStringLiteral("open_pr")}, {QStringLiteral("label"), QStringLiteral("View PR")}, {QStringLiteral("url"), kPrUrl}};
  } else if (pushes && git.branch != git.defaultBranch) {
    cta = {{QStringLiteral("kind"), QStringLiteral("run_action")}, {QStringLiteral("label"), QStringLiteral("Create PR")}, {QStringLiteral("action"), QJsonObject{{QStringLiteral("kind"), QStringLiteral("create_pr")}}}};
  }
  toast.insert(QStringLiteral("cta"), cta);

  sendStatus(mc);
  sendEvent(mc, id, {{QStringLiteral("kind"), QStringLiteral("action_finished")},
                  {QStringLiteral("result"), QJsonObject{{QStringLiteral("action"), action}, {QStringLiteral("branch"), branch}, {QStringLiteral("commit"), commit},
                                                         {QStringLiteral("push"), push}, {QStringLiteral("pr"), pr}, {QStringLiteral("toast"), toast}}}});
}

void run(FakeMc& mc, int id, const QJsonObject& input) {
  FakeCheckout& git = mc.part<FakeCheckout>();
  git.inputs.append(input);
  const QString action = input.value(QLatin1String("action")).toString();
  sendEvent(mc, id, {{QStringLiteral("kind"), QStringLiteral("action_started")}, {QStringLiteral("phases"), QJsonArray{action}}});
  if (action.startsWith(QLatin1String("commit"))) {
    if (!input.contains(QLatin1String("commitMessage"))) phase(mc, id, QStringLiteral("commit"), QStringLiteral("Generating commit message..."));
    if (git.waitWhileWriting) {
      git.held = id;
      return;
    }
    phase(mc, id, QStringLiteral("commit"), QStringLiteral("Committing..."));
    if (!git.hookLine.isEmpty()) {
      sendEvent(mc, id, {{QStringLiteral("kind"), QStringLiteral("hook_started")}, {QStringLiteral("hookName"), QStringLiteral("pre-commit")}});
      sendEvent(mc, id, {{QStringLiteral("kind"), QStringLiteral("hook_output")}, {QStringLiteral("hookName"), QStringLiteral("pre-commit")},
                      {QStringLiteral("stream"), QStringLiteral("stdout")}, {QStringLiteral("text"), git.hookLine + QLatin1Char('\n')}});
    }
  }
  if (!git.failWith.isEmpty()) {
    sendEvent(mc, id, {{QStringLiteral("kind"), QStringLiteral("action_failed")}, {QStringLiteral("phase"), git.failPhase}, {QStringLiteral("message"), git.failWith}});
    return;
  }
  if (git.waitAfterHook) {
    git.held = id;
    return;
  }
  if (!git.hookLine.isEmpty()) {
    sendEvent(mc, id, {{QStringLiteral("kind"), QStringLiteral("hook_finished")}, {QStringLiteral("hookName"), QStringLiteral("pre-commit")}, {QStringLiteral("exitCode"), 0}});
  }
  finish(mc, id, input);
}

const FakeMc::Extension extension([](FakeMc& mc) {
  mc.onShape(QStringLiteral("gitAction"), [&mc](int id, const QJsonObject& shape) { run(mc, id, shape.value(QLatin1String("input")).toObject()); });
  mc.onRpc(QStringLiteral("vcs.refreshStatus"), [&mc](const FakeMc::Rpc& rpc) {
    FakeCheckout& git = mc.part<FakeCheckout>();
    if (git.outsideChange) {
      git.outsideChange = false;
      git.changed.append(QStringLiteral("README.md"));
    }
    sendStatus(mc);
    mc.reply(rpc, QJsonValue::Null);
  });
  mc.onRpc(QStringLiteral("vcs.pull"), [&mc](const FakeMc::Rpc& rpc) {
    FakeCheckout& git = mc.part<FakeCheckout>();
    if (!git.refusePull.isEmpty()) {
      mc.refuse(rpc, git.refusePull);
      return;
    }
    const QString ref = git.branch.value_or(QString());
    const bool pulled = git.behind > 0;
    git.pulled += git.behind;
    git.behind = 0;
    sendStatus(mc);
    mc.reply(rpc, QJsonObject{{QStringLiteral("status"), pulled ? QStringLiteral("pulled") : QStringLiteral("skipped_up_to_date")},
                                {QStringLiteral("refName"), ref},
                                {QStringLiteral("upstreamRef"), git.remoteName + QLatin1Char('/') + ref}});
  });
  mc.onRpc(QStringLiteral("vcs.init"), [&mc](const FakeMc::Rpc& rpc) {
    FakeCheckout& git = mc.part<FakeCheckout>();
    if (!git.refuseInit.isEmpty()) {
      mc.refuse(rpc, git.refuseInit);
      return;
    }
    git.initialized = true;
    git.isRepo = true;
    git.hasRemote = false;
    git.upstream = false;
    sendStatus(mc);
    mc.reply(rpc, QJsonValue::Null);
  });
  mc.onRpc(QStringLiteral("sourceControl.publishRepository"), [&mc](const FakeMc::Rpc& rpc) {
    FakeCheckout& git = mc.part<FakeCheckout>();
    git.publishes.append(rpc.payload);
    if (!git.refusePublish.isEmpty()) {
      mc.refuse(rpc, git.refusePublish);
      return;
    }
    const QString repository = rpc.payload.value(QLatin1String("repository")).toString();
    const QString remoteName = rpc.payload.value(QLatin1String("remoteName")).toString();
    git.hasRemote = true;
    git.upstream = true;
    git.remoteName = remoteName;
    git.remote[remoteName + QLatin1Char('/') + git.branch.value_or(QString())].append(git.ahead);
    git.ahead.clear();
    sendStatus(mc);
    mc.reply(rpc, QJsonObject{{QStringLiteral("repository"), QJsonObject{{QStringLiteral("nameWithOwner"), repository},
                                                                           {QStringLiteral("url"), QStringLiteral("https://github.com/") + repository}}},
                                {QStringLiteral("remoteName"), remoteName},
                                {QStringLiteral("branch"), git.branch.value_or(QString())},
                                {QStringLiteral("status"), QStringLiteral("pushed")}});
  });
});

FakeCheckout& fake(World& world) {
  return world.mc.part<FakeCheckout>();
}

QVariantMap git(World& world) {
  return world.state(QStringLiteral("git")).toMap();
}

QVariantMap menuEntry(World& world, const QString& label) {
  for (const QVariant& item : git(world).value(QStringLiteral("menu")).toList()) {
    if (item.toMap().value(QStringLiteral("label")) == label) return item.toMap();
  }
  return {};
}

QVariantMap toastTitled(World& world, const QString& title) {
  for (const QVariant& item : world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList()) {
    if (item.toMap().value(QStringLiteral("title")) == title) return item.toMap();
  }
  return {};
}

void dispatch(World& world, const QString& action, const QVariantMap& payload = {}) {
  world.bridge().dispatch(action, payload);
  world.sync();
}

// The checkout as the MC now has it, once the header shows it.
void settle(World& world) {
  sendStatus(world.mc);
  world.sync();
}

// Waits for the actions sent so far to finish.
void awaitIdle(World& world) {
  world.waitFor([&] { return !git(world).value(QStringLiteral("busy")).toBool(); },
                [&] { return QStringLiteral("the git actions to finish; they are %1").arg(show(git(world))); });
  world.sync();
}

// A feature branch level with its upstream, nothing changed.
void clean(FakeCheckout& git) {
  git.known = true;
  git.isRepo = true;
  git.branch = QStringLiteral("feature/tax");
  git.hasRemote = true;
  git.upstream = true;
  git.ahead.clear();
  git.behind = 0;
  git.aheadOfDefault.reset();
  git.changed.clear();
  git.pr = false;
}

void onDefaultBranch(FakeCheckout& git, const QString& branch) {
  git.defaultBranch = branch;
  git.branch = branch;
  git.upstream = true;
  git.ahead = {QStringLiteral("Tidy the cart")};
  if (git.changed.isEmpty()) git.changed = {QStringLiteral("src/cart.ts")};
}

// The project's folder becomes the checkout the fake reports.
void checkoutOf(World& world, const QString& project) {
  FakeCheckout& checkout = fake(world);
  checkout.cwd = QStringLiteral("/work/") + project;
  world.mc.checkouts.insert(checkout.cwd, [&mc = world.mc] {
    const FakeCheckout& git = mc.part<FakeCheckout>();
    return QJsonObject{{QStringLiteral("local"), local(git)}, {QStringLiteral("remote"), remote(git)}};
  });
  world.mc.projects.insert(project, {{QStringLiteral("id"), project}, {QStringLiteral("title"), project}, {QStringLiteral("workspaceRoot"), checkout.cwd}, {QStringLiteral("scripts"), QJsonArray()}});
}

// A thread of `project` on the fake's checkout, open, on an MC that is
// connected (now, or already).
void openThreadIn(World& world, const QString& project) {
  checkoutOf(world, project);
  world.mc.threads.insert(kThread, {{QStringLiteral("id"), kThread}, {QStringLiteral("title"), QStringLiteral("Tax line")}, {QStringLiteral("projectId"), project},
                                      {QStringLiteral("branch"), QStringLiteral("feature/tax")},
                                      {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")}, {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}});
  if (world.shellSubscriptions() == 0) {
    world.connect();
  } else {
    world.mc.sendRow(project, world.mc.projects.value(project), QStringLiteral("project"));
    world.mc.sendRow(kThread, world.mc.threads.value(kThread));
    world.sync();
  }
  const QString key = world.mc.environmentId + QLatin1Char(':') + kThread;
  world.native().controller<NavigationController>()->open(NavigationController::Route::thread(key));
  world.waitFor([&] { return git(world).value(QStringLiteral("available")).toBool(); },
                [&] { return QStringLiteral("the git actions to show; they are %1").arg(show(git(world))); });
}

// The git actions as the GitActions brick draws them, with its dialogs.
Brick& gitBrick(World& world) {
  if (!world.brick) world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nGitActions {}\n", QSize(900, 700));
  return *world.brick;
}

const QString kNotAuthenticated = QStringLiteral("GitHub is not authenticated. Open Settings -> Source Control for setup guidance.");

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("a connected environment with a thread in the git project %1(?: with the remote %1)?").arg(q), [](World& world, const Captures& c, const Table&) {
    if (!c.value(1).isEmpty()) fake(world).remoteName = c.value(1);
    openThreadIn(world, c[0]);
  });
  // status-and-changes.feature and repository-discovery-clone-publish.feature.
  step(QStringLiteral("a connected environment with the project %1 in a git repository").arg(q), [](World& world, const Captures& c, const Table&) {
    checkoutOf(world, c[0]);
    world.connect();
    world.sync();
  });
  step(QStringLiteral("the agent's turn ends after editing a file"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return git(world).value(QStringLiteral("available")).toBool() && git(world).value(QStringLiteral("files")).toList().isEmpty(); },
                  [&] { return QStringLiteral("a clean checkout; the git actions are %1").arg(show(git(world))); });
    // The MC watches the checkout and says what changed (vcs/watch.ex).
    fake(world).changed = {QStringLiteral("src/cart.ts")};
    settle(world);
  });
  step(QStringLiteral("the thread's status shows the new change without the user asking for a refresh"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      const QVariantList files = git(world).value(QStringLiteral("files")).toList();
      return files.size() == 1 && files.first().toMap().value(QStringLiteral("path")) == QLatin1String("src/cart.ts");
    }, [&] { return QStringLiteral("the change to show; the git actions are %1").arg(show(git(world))); });
    expect(at(git(world), QStringLiteral("quickAction.label")).toString().startsWith(QLatin1String("Commit")), QStringLiteral("the git actions are %1").arg(show(git(world))));
    for (const FakeMc::Rpc& rpc : std::as_const(world.mc.calls)) {
      expect(rpc.method != QLatin1String("vcs.refreshStatus"), QStringLiteral("the shell asked the MC to refresh"));
    }
  });
  step(QStringLiteral("the project %1 is not in a git repository").arg(q), [](World& world, const Captures& c, const Table&) {
    clean(fake(world));
    fake(world).isRepo = false;
    openThreadIn(world, c[0]);
    world.waitFor([&] { return git(world).value(QStringLiteral("isRepo")) == false; },
                  [&] { return QStringLiteral("Initialize Git to be on offer; the git actions are %1").arg(show(git(world))); });
  });
  step(QStringLiteral("the user initializes Git for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(world.state(QStringLiteral("workspace")).toMap().value(QStringLiteral("projectTitle")) == c[0], QStringLiteral("the thread is not in %1").arg(c[0]));
    dispatch(world, QStringLiteral("git.init"));
  });
  step(QStringLiteral("%1 becomes a git repository").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return fake(world).initialized && git(world).value(QStringLiteral("isRepo")) == true && !git(world).value(QStringLiteral("initPending")).toBool(); },
                  [&] { return QStringLiteral("the git actions are %1").arg(show(git(world))); });
    bool asked = false;
    for (const FakeMc::Rpc& rpc : std::as_const(world.mc.calls)) {
      asked = asked || (rpc.method == QLatin1String("vcs.init") && rpc.payload.value(QLatin1String("cwd")) == QStringLiteral("/work/") + c[0]);
    }
    expect(asked, QStringLiteral("the MC was not asked to initialize %1").arg(c[0]));
  });
  step(QStringLiteral("the git actions for %1 become available").arg(q), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return git(world).value(QStringLiteral("available")).toBool() && !git(world).value(QStringLiteral("menu")).toList().isEmpty(); },
                  [&] { return QStringLiteral("the git actions; they are %1").arg(show(git(world))); });
    expect(!menuEntry(world, QStringLiteral("Commit")).isEmpty(), QStringLiteral("the git menu is %1").arg(show(git(world).value(QStringLiteral("menu")))));
  });

  // Publishing (repository-discovery-clone-publish.feature), through the brick's dialog.
  step(QStringLiteral("the project %1 has (?:commits and )?no remote").arg(q), [](World& world, const Captures& c, const Table&) {
    clean(fake(world));
    fake(world).hasRemote = false;
    fake(world).upstream = false;
    fake(world).ahead = {QStringLiteral("Add notes")};
    openThreadIn(world, c[0]);
    world.waitFor([&] { return at(git(world), QStringLiteral("quickAction.kind")) == QLatin1String("open_publish"); },
                  [&] { return QStringLiteral("Publish repository to be recommended; the git actions are %1").arg(show(git(world))); });
  });
  step(QStringLiteral("the user chooses to publish the repository"), [](World& world, const Captures&, const Table&) {
    dispatch(world, QStringLiteral("git.quick"));
  });
  step(QStringLiteral("publishing begins for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return git(world).value(QStringLiteral("publishing")).typeId() == QMetaType::QVariantMap; },
                  [&] { return QStringLiteral("the publish dialog to open; the git actions are %1").arg(show(git(world))); });
    expect(world.state(QStringLiteral("workspace")).toMap().value(QStringLiteral("projectTitle")) == c[0] && fake(world).publishes.isEmpty(),
           QStringLiteral("publishing is not for %1").arg(c[0]));
    Brick& brick = gitBrick(world);
    world.waitFor([&] { return brick.shows(QStringLiteral("Publish repository")) && brick.shows(QStringLiteral("Step 1 of 3 · Host")); },
                  QStringLiteral("the publish dialog to be drawn"));
  });
  step(QStringLiteral("the user publishes the repository"), [](World& world, const Captures&, const Table&) {
    gitBrick(world);
    dispatch(world, QStringLiteral("git.quick"));
    world.waitFor([&] { return at(git(world), QStringLiteral("publishing.hosts")).toList().value(0).toMap().value(QStringLiteral("ready")).toBool(); },
                  [&] { return QStringLiteral("the hosts to be known; the git actions are %1").arg(show(git(world))); });
  });
  step(QStringLiteral("the user picks a host, names the repository, picks its visibility and confirms a summary"), [](World& world, const Captures&, const Table&) {
    Brick& brick = gitBrick(world);
    const auto onStep = [&](const QString& label) {
      world.waitFor([&] { return brick.shows(label); }, QStringLiteral("the dialog to reach \"%1\"").arg(label));
    };
    // The host.
    onStep(QStringLiteral("Step 1 of 3 · Host"));
    expect(brick.item(QStringLiteral("publishHost"))->property("currentValue") == QLatin1String("github"), QStringLiteral("GitHub is not the host offered first"));
    brick.click(QStringLiteral("publishNext"));
    // The repository and its visibility: no name, no next step.
    onStep(QStringLiteral("Step 2 of 3 · Repository"));
    expect(!brick.item(QStringLiteral("publishNext"))->isEnabled(), QStringLiteral("a repository with no name can be published"));
    brick.click(QStringLiteral("publishRepository"));
    for (const QChar ch : QStringLiteral("acme/notes")) QTest::keyClick(&brick.window(), ch.toLatin1());
    brick.item(QStringLiteral("publishVisibility"))->setProperty("currentIndex", 1);
    brick.click(QStringLiteral("publishNext"));
    // The summary; nothing is published until it is confirmed.
    onStep(QStringLiteral("Step 3 of 3 · Summary"));
    const QString summary = brick.item(QStringLiteral("publishSummary"))->property("text").toString();
    expect(summary == QLatin1String("Create the public repository acme/notes on GitHub, add it as the remote origin and push feature/tax."),
           QStringLiteral("the summary reads \"%1\"").arg(summary));
    expect(fake(world).publishes.isEmpty(), QStringLiteral("the repository was published before the summary was confirmed"));
    // Back and forth keeps what was entered.
    brick.click(QStringLiteral("publishBack"));
    onStep(QStringLiteral("Step 2 of 3 · Repository"));
    brick.click(QStringLiteral("publishNext"));
    onStep(QStringLiteral("Step 3 of 3 · Summary"));
    brick.click(QStringLiteral("publishConfirm"));
    world.waitFor([&] { return git(world).value(QStringLiteral("publishing")).isNull(); },
                  [&] { return QStringLiteral("the publish dialog to close; the git actions are %1").arg(show(git(world))); });
    expect(fake(world).publishes.size() == 1, QStringLiteral("the MC was asked to publish %1 times").arg(fake(world).publishes.size()));
    const QJsonObject input = fake(world).publishes.first();
    expect(input.value(QLatin1String("repository")) == QLatin1String("acme/notes") && input.value(QLatin1String("visibility")) == QLatin1String("public") &&
               input.value(QLatin1String("provider")) == QLatin1String("github") && input.value(QLatin1String("cwd")) == QLatin1String("/work/notes"),
           QStringLiteral("the MC was asked %1").arg(show(input.toVariantMap())));
  });
  step(QStringLiteral("the GitHub CLI is not signed in"), [](World& world, const Captures&, const Table&) {
    // `gh` is installed and has no account (SourceControlProviderDiscoveryItem).
    world.mc.onRpc(QStringLiteral("server.discoverSourceControl"), [&mc = world.mc](const FakeMc::Rpc& rpc) {
      const QJsonObject none{{QStringLiteral("_tag"), QStringLiteral("None")}};
      mc.reply(rpc, QJsonObject{{QStringLiteral("versionControlSystems"), QJsonArray()},
                                {QStringLiteral("sourceControlProviders"),
                                 QJsonArray{QJsonObject{{QStringLiteral("kind"), QStringLiteral("github")}, {QStringLiteral("label"), QStringLiteral("GitHub")},
                                                        {QStringLiteral("executable"), QStringLiteral("gh")}, {QStringLiteral("status"), QStringLiteral("available")},
                                                        {QStringLiteral("installHint"), QStringLiteral("Install GitHub and make sure `gh` is on the PATH.")},
                                                        {QStringLiteral("version"), none},
                                                        {QStringLiteral("auth"), QJsonObject{{QStringLiteral("status"), QStringLiteral("unauthenticated")}, {QStringLiteral("account"), none},
                                                                                              {QStringLiteral("host"), none}, {QStringLiteral("detail"), none}}}}}}});
    });
  });
  step(QStringLiteral("the user picks GitHub to publish to"), [](World& world, const Captures&, const Table&) {
    // A repository with nothing published yet.
    clean(fake(world));
    fake(world).hasRemote = false;
    fake(world).upstream = false;
    fake(world).ahead = {QStringLiteral("Add notes")};
    openThreadIn(world, QStringLiteral("notes"));
    Brick& brick = gitBrick(world);
    dispatch(world, QStringLiteral("git.publish"));
    world.waitFor([&] { return brick.shows(QStringLiteral("Step 1 of 3 · Host")); }, QStringLiteral("the publish dialog to be drawn"));
    brick.item(QStringLiteral("publishHost"))->setProperty("currentIndex", 0);
    expect(brick.item(QStringLiteral("publishHost"))->property("currentText") == QLatin1String("GitHub"), QStringLiteral("GitHub is not offered"));
  });
  step(QStringLiteral("the user is told GitHub is not authenticated and how to fix it"), [](World& world, const Captures&, const Table&) {
    Brick& brick = gitBrick(world);
    world.waitFor([&] { return brick.shows(kNotAuthenticated); },
                  [&] { return QStringLiteral("the host's hint; the git actions are %1").arg(show(git(world))); });
    // And it goes no further.
    expect(!brick.item(QStringLiteral("publishNext"))->isEnabled(), QStringLiteral("a host that is not signed in can be published to"));
    expect(fake(world).publishes.isEmpty(), QStringLiteral("the MC was asked to publish"));
  });

  // The checkout's states.
  const QList<std::pair<QString, void (*)(FakeCheckout&)>> states{
      {QStringLiteral("has uncommitted changes and no remote"), [](FakeCheckout& g) { g.changed = {QStringLiteral("src/cart.ts")}; g.hasRemote = false; g.upstream = false; }},
      {QStringLiteral("has uncommitted changes on the default branch"), [](FakeCheckout& g) { g.changed = {QStringLiteral("src/cart.ts")}; g.branch = g.defaultBranch; }},
      {QStringLiteral("has uncommitted changes on a branch with an open pull request"), [](FakeCheckout& g) { g.changed = {QStringLiteral("src/cart.ts")}; g.pr = true; }},
      {QStringLiteral("has uncommitted changes on a feature branch with a remote"), [](FakeCheckout& g) { g.changed = {QStringLiteral("src/cart.ts")}; }},
      {QStringLiteral("has uncommitted changes"), [](FakeCheckout& g) { g.changed = {QStringLiteral("src/cart.ts")}; g.aheadOfDefault = 1; }},
      {QStringLiteral("has commits on a feature branch with no upstream"), [](FakeCheckout& g) { g.upstream = false; g.ahead = {QStringLiteral("Add tax")}; }},
      {QStringLiteral("is behind its upstream"), [](FakeCheckout& g) { g.behind = 2; g.aheadOfDefault = 1; }},
      {QStringLiteral("is ahead of its upstream with an open pull request"), [](FakeCheckout& g) { g.ahead = {QStringLiteral("Add tax")}; g.pr = true; }},
      {QStringLiteral("is pushed and ahead of the default branch with no pull request"), [](FakeCheckout& g) { g.aheadOfDefault = 2; }},
      {QStringLiteral("is up to date with an open pull request"), [](FakeCheckout& g) { g.pr = true; }},
      {QStringLiteral("has no status yet"), [](FakeCheckout& g) { g.known = false; }},
      {QStringLiteral("has diverged from its upstream"), [](FakeCheckout& g) { g.ahead = {QStringLiteral("Add tax")}; g.behind = 1; }},
      {QStringLiteral("is up to date with nothing to do"), [](FakeCheckout& g) { g.aheadOfDefault = 0; }},
      {QStringLiteral("has no upstream and no local commits"), [](FakeCheckout& g) { g.upstream = false; }},
      {QStringLiteral("has no uncommitted changes"), [](FakeCheckout&) {}},
      {QStringLiteral("is on a detached HEAD with changes"), [](FakeCheckout& g) { g.branch.reset(); g.changed = {QStringLiteral("src/cart.ts")}; }},
      {QStringLiteral("has commits and no remote"), [](FakeCheckout& g) { g.hasRemote = false; g.upstream = false; g.ahead = {QStringLiteral("Add tax")}; }},
      {QStringLiteral("'s branch has an open pull request"), [](FakeCheckout& g) { g.pr = true; }},
      {QStringLiteral(" is not a repository"), [](FakeCheckout& g) { g.isRepo = false; }},
  };
  for (const auto& [state, apply] : states) {
    const QString sep = state.startsWith(QLatin1Char('\'')) || state.startsWith(QLatin1Char(' ')) ? QString() : QStringLiteral(" ");
    step(QStringLiteral("the checkout") + sep + QRegularExpression::escape(state), [apply](World& world, const Captures&, const Table&) {
      clean(fake(world));
      apply(fake(world));
      settle(world);
    });
  }
  step(QStringLiteral("the checkout is running another git action"), [](World& world, const Captures&, const Table&) {
    clean(fake(world));
    fake(world).changed = {QStringLiteral("src/cart.ts")};
    fake(world).waitAfterHook = true;
    settle(world);
    dispatch(world, QStringLiteral("git.quick"));
  });
  step(QStringLiteral("the checkout changed outside HAL-C2 a moment ago"), [](World& world, const Captures&, const Table&) {
    clean(fake(world));
    settle(world);
    fake(world).outsideChange = true;
  });
  step(QStringLiteral("the project's primary remote is on (GitHub|GitLab)"), [](World& world, const Captures& c, const Table&) {
    clean(fake(world));
    fake(world).provider = c[0].toLower();
    fake(world).aheadOfDefault = 2;
    settle(world);
  });
  step(QStringLiteral("the checkout is on the default branch %1").arg(q), [](World& world, const Captures& c, const Table&) {
    onDefaultBranch(fake(world), c[0]);
    settle(world);
  });

  // Looking.
  step(QStringLiteral("the user looks at the thread's git actions"), [](World& world, const Captures&, const Table&) { world.sync(); });
  step(QStringLiteral("the recommended action is %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      const QVariantMap action = git(world).value(QStringLiteral("quickAction")).toMap();
      return action.value(QStringLiteral("label")) == c[0] && action.value(QStringLiteral("disabledReason")).isNull();
    }, [&] { return QStringLiteral("the recommended action to be %1; the git actions are %2").arg(c[0], show(git(world))); });
  });
  step(QStringLiteral("the recommended action is unavailable"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !at(git(world), QStringLiteral("quickAction.disabledReason")).isNull(); },
                  [&] { return QStringLiteral("the recommended action to be unavailable; the git actions are %1").arg(show(git(world))); });
  });
  step(QStringLiteral("the reason given is %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(at(git(world), QStringLiteral("quickAction.disabledReason")) == c[0], QStringLiteral("the git actions are %1").arg(show(git(world))));
  });
  step(QStringLiteral("pushing and opening a pull request are unavailable"), [](World& world, const Captures&, const Table&) {
    for (const QString& label : {QStringLiteral("Push"), QStringLiteral("Create PR")}) {
      const QVariantMap entry = menuEntry(world, label);
      expect(!entry.isEmpty() && !entry.value(QStringLiteral("disabledReason")).isNull(), QStringLiteral("the git menu is %1").arg(show(git(world).value(QStringLiteral("menu")))));
    }
  });
  step(QStringLiteral("the user is told to create and check out a branch first"), [](World& world, const Captures&, const Table&) {
    const QVariantMap state = git(world);
    expect(at(state, QStringLiteral("quickAction.disabledReason")) == QStringLiteral("Create and checkout a ref before pushing or opening a pull request.") &&
               state.value(QStringLiteral("hints")).toStringList().contains(QStringLiteral("Detached HEAD: check out a branch to push or open a pull request.")),
           QStringLiteral("the git actions are %1").arg(show(state)));
  });
  step(QStringLiteral("the git menu offers only committing and publishing"), [](World& world, const Captures&, const Table&) {
    const QVariantMap state = git(world);
    const QVariantList menu = state.value(QStringLiteral("menu")).toList();
    expect(menu.size() == 1 && menu.first().toMap().value(QStringLiteral("id")) == QStringLiteral("commit") && state.value(QStringLiteral("canPublish")).toBool(),
           QStringLiteral("the git actions are %1").arg(show(state)));
  });
  step(QStringLiteral("the user opens the git menu"), [](World& world, const Captures&, const Table&) {
    dispatch(world, QStringLiteral("git.refresh"));
  });
  step(QStringLiteral("the menu reflects the checkout as it is now"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return menuEntry(world, QStringLiteral("Commit")).value(QStringLiteral("disabledReason")).isNull() && !menuEntry(world, QStringLiteral("Commit")).isEmpty(); },
                  [&] { return QStringLiteral("Commit to be on offer; the git menu is %1").arg(show(git(world).value(QStringLiteral("menu")))); });
  });
  step(QStringLiteral("%1 is unavailable because %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap entry = menuEntry(world, c[0]);
    expect(entry.value(QStringLiteral("disabledReason")) == c[1], QStringLiteral("the git menu is %1").arg(show(git(world).value(QStringLiteral("menu")))));
  });
  step(QStringLiteral("the pull request entry is called %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return !menuEntry(world, c[0]).isEmpty(); },
                  [&] { return QStringLiteral("the git menu is %1").arg(show(git(world).value(QStringLiteral("menu")))); });
  });
  step(QStringLiteral("the user chooses to view the pull request"), [](World& world, const Captures&, const Table&) {
    dispatch(world, QStringLiteral("git.quick"));
  });
  step(QStringLiteral("the pull request opens on its host"), [](World& world, const Captures&, const Table&) {
    expect(world.openedUrls.contains(QUrl(kPrUrl)), QStringLiteral("the browser opened %1").arg(show(QVariant::fromValue(world.openedUrls))));
  });

  // Pushing and pulling.
  step(QStringLiteral("%1 tracks %1 and is (\\d+) commits? ahead").arg(q), [](World& world, const Captures& c, const Table&) {
    clean(fake(world));
    fake(world).branch = c[0];
    for (int n = 0; n < c[2].toInt(); ++n) fake(world).ahead.append(QStringLiteral("Commit %1").arg(n + 1));
    settle(world);
  });
  step(QStringLiteral("the user pushes"), [](World& world, const Captures&, const Table&) {
    dispatch(world, QStringLiteral("git.menu"), {{QStringLiteral("id"), QStringLiteral("push")}});
    awaitIdle(world);
  });
  step(QStringLiteral("%1 has the new commit").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(fake(world).remote.value(c[0]).size() == 1 && fake(world).ahead.isEmpty(), QStringLiteral("%1 holds %2").arg(c[0], fake(world).remote.value(c[0]).join(u", ")));
  });
  step(QStringLiteral("the user is told where the branch was pushed"), [](World& world, const Captures&, const Table&) {
    const QString title = QStringLiteral("Pushed to %1/%2").arg(fake(world).remoteName, fake(world).branch.value_or(QString()));
    world.waitFor([&] { return !toastTitled(world, title).isEmpty(); },
                  [&] { return QStringLiteral("the toast %1; the shell shows %2").arg(title, show(world.state(QStringLiteral("toasts")))); });
  });
  step(QStringLiteral("a push finishes"), [](World& world, const Captures&, const Table&) {
    clean(fake(world));
    fake(world).ahead = {QStringLiteral("Add tax")};
    settle(world);
    dispatch(world, QStringLiteral("git.menu"), {{QStringLiteral("id"), QStringLiteral("push")}});
    awaitIdle(world);
  });
  step(QStringLiteral("the user is told what was pushed"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return toastTitled(world, QStringLiteral("Pushed to origin/feature/tax")).value(QStringLiteral("type")) == QStringLiteral("success"); },
                  [&] { return QStringLiteral("the push's result; the shell shows %1").arg(show(world.state(QStringLiteral("toasts")))); });
  });
  step(QStringLiteral("the message goes away by itself after a while"), [](World& world, const Captures&, const Table&) {
    world.setTime(world.now().addSecs(11));
    world.sync();
    expect(toastTitled(world, QStringLiteral("Pushed to origin/feature/tax")).isEmpty(), QStringLiteral("the shell shows %1").arg(show(world.state(QStringLiteral("toasts")))));
  });
  step(QStringLiteral("%1 is (\\d+) commits behind its upstream and has no local commits").arg(q), [](World& world, const Captures& c, const Table&) {
    clean(fake(world));
    fake(world).branch = c[0];
    fake(world).behind = c[1].toInt();
    settle(world);
  });
  step(QStringLiteral("the user pulls"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return at(git(world), QStringLiteral("quickAction.label")) == QStringLiteral("Pull"); },
                  [&] { return QStringLiteral("Pull to be on offer; the git actions are %1").arg(show(git(world))); });
    dispatch(world, QStringLiteral("git.quick"));
    awaitIdle(world);
  });
  step(QStringLiteral("the branch has the (\\d+) new commits"), [](World& world, const Captures& c, const Table&) {
    expect(fake(world).pulled == c[0].toInt() && fake(world).behind == 0, QStringLiteral("the pull brought in %1").arg(fake(world).pulled));
    world.waitFor([&] { return !toastTitled(world, QStringLiteral("Pulled")).isEmpty(); },
                  [&] { return QStringLiteral("the toast Pulled; the shell shows %1").arg(show(world.state(QStringLiteral("toasts")))); });
  });

  // The default branch.
  step(QStringLiteral("the user runs %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    // From an open command palette: its entry of that title.
    if (auto* palette = world.native().controller<CommandPaletteController>(); palette && palette->isOpen()) {
      for (int row = 0; row < palette->rowCount(); ++row) {
        if (palette->index(row).data(CommandPaletteController::TitleRole) == c[0]) {
          palette->run(row);
          world.sync();
          return;
        }
      }
      fail(QStringLiteral("the command palette does not list \"%1\"").arg(c[0]));
    }
    // A keybinding command by its id ("terminal.new"), as a key or a rice runs it.
    if (auto* keys = world.native().controller<KeybindingController>(); keys && keys->commands()->contains(c[0])) {
      keys->commands()->run(c[0]);
      world.sync();
      return;
    }
    if (at(git(world), QStringLiteral("quickAction.label")) == c[0]) {
      dispatch(world, QStringLiteral("git.quick"));
      return;
    }
    // A pull request is offered for committed work only.
    if (c[0] == QLatin1String("Create PR") && !fake(world).changed.isEmpty()) {
      fake(world).changed.clear();
      settle(world);
    }
    const QVariantMap entry = menuEntry(world, c[0]);
    expect(!entry.isEmpty() && entry.value(QStringLiteral("disabledReason")).isNull(), QStringLiteral("the git actions are %1").arg(show(git(world))));
    dispatch(world, QStringLiteral("git.menu"), {{QStringLiteral("id"), entry.value(QStringLiteral("id"))}});
  });
  step(QStringLiteral("the user is asked to confirm before anything reaches %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap pending = git(world).value(QStringLiteral("pendingDefaultBranch")).toMap();
    expect(pending.value(QStringLiteral("description")).toString().contains(QLatin1Char('"') + c[0] + QLatin1Char('"')) && fake(world).inputs.isEmpty(),
           QStringLiteral("the git actions are %1, and the MC ran %2").arg(show(git(world))).arg(fake(world).inputs.size()));
  });
  step(QStringLiteral("the user was asked to confirm pushing to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    onDefaultBranch(fake(world), c[0]);
    fake(world).changed.clear();
    settle(world);
    dispatch(world, QStringLiteral("git.menu"), {{QStringLiteral("id"), QStringLiteral("push")}});
    expect(!git(world).value(QStringLiteral("pendingDefaultBranch")).isNull(), QStringLiteral("the git actions are %1").arg(show(git(world))));
  });
  step(QStringLiteral("the user was asked to confirm committing and pushing to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    onDefaultBranch(fake(world), c[0]);
    settle(world);
    dispatch(world, QStringLiteral("git.quick"));
    expect(at(git(world), QStringLiteral("pendingDefaultBranch.title")) == QStringLiteral("Commit & push to default ref?"), QStringLiteral("the git actions are %1").arg(show(git(world))));
  });
  const auto choose = [](World& world, const QString& choice) {
    dispatch(world, QStringLiteral("git.defaultBranch"), {{QStringLiteral("choice"), choice}});
    awaitIdle(world);
  };
  step(QStringLiteral("the user continues"), [choose](World& world, const Captures&, const Table&) { choose(world, QStringLiteral("continue")); });
  step(QStringLiteral("the user aborts"), [choose](World& world, const Captures&, const Table&) { choose(world, QStringLiteral("abort")); });
  step(QStringLiteral("the user chooses to create a feature branch and continue"), [choose](World& world, const Captures&, const Table&) { choose(world, QStringLiteral("featureBranch")); });
  step(QStringLiteral("the push runs against %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString target = fake(world).remoteName + QLatin1Char('/') + c[0];
    expect(fake(world).inputs.size() == 1 && fake(world).remote.value(target).size() == 1, QStringLiteral("%1 holds %2").arg(target, fake(world).remote.value(target).join(u", ")));
  });
  step(QStringLiteral("nothing is committed or pushed"), [](World& world, const Captures&, const Table&) {
    expect(fake(world).inputs.isEmpty() && git(world).value(QStringLiteral("pendingDefaultBranch")).isNull(),
           QStringLiteral("the MC ran %1 actions; the git actions are %2").arg(fake(world).inputs.size()).arg(show(git(world))));
  });
  step(QStringLiteral("the work is committed on a new branch and pushed there instead of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const FakeCheckout& checkout = fake(world);
    expect(!checkout.commits.isEmpty() && checkout.commits.last().branch.startsWith(QLatin1String("feature/")) &&
               checkout.remote.value(checkout.remoteName + QLatin1Char('/') + checkout.commits.last().branch).contains(checkout.commits.last().subject) &&
               !checkout.remote.contains(checkout.remoteName + QLatin1Char('/') + c[0]),
           QStringLiteral("the commit is on %1 and the remote holds %2").arg(checkout.commits.isEmpty() ? QString() : checkout.commits.last().branch,
                                                                            QStringList(checkout.remote.keys()).join(u", ")));
  });

  // Committing.
  step(QStringLiteral("the user has changed %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    fake(world).changed = {c[0], c[1]};
    settle(world);
  });
  const auto commit = [](World& world, const QVariantMap& payload) {
    world.waitFor([&] { return menuEntry(world, QStringLiteral("Commit")).value(QStringLiteral("disabledReason")).isNull(); },
                  [&] { return QStringLiteral("Commit to be on offer; the git actions are %1").arg(show(git(world))); });
    dispatch(world, QStringLiteral("git.commit"), payload);
    // A slow hook leaves the action running for the scenario to watch.
    if (!fake(world).waitWhileWriting) awaitIdle(world);
  };
  step(QStringLiteral("the user commits with the message %1").arg(q), [commit](World& world, const Captures& c, const Table&) {
    commit(world, {{QStringLiteral("message"), c[0]}, {QStringLiteral("filePaths"), QVariant::fromValue(nullptr)}});
  });
  step(QStringLiteral("the user commits without writing a message"), [commit](World& world, const Captures&, const Table&) {
    commit(world, {{QStringLiteral("message"), QStringLiteral("  ")}, {QStringLiteral("filePaths"), QVariant::fromValue(nullptr)}});
  });
  step(QStringLiteral("the user leaves %1 out of the commit and commits").arg(q), [commit](World& world, const Captures& c, const Table&) {
    QStringList picked = fake(world).changed;
    picked.removeAll(c[0]);
    commit(world, {{QStringLiteral("message"), QStringLiteral("Add the cart")}, {QStringLiteral("filePaths"), picked}});
  });
  step(QStringLiteral("the user commits on a new branch with the message %1").arg(q), [commit](World& world, const Captures& c, const Table&) {
    commit(world, {{QStringLiteral("message"), c[0]}, {QStringLiteral("filePaths"), QVariant::fromValue(nullptr)}, {QStringLiteral("featureBranch"), true}});
  });
  step(QStringLiteral("a commit %1 holds both files").arg(q), [](World& world, const Captures& c, const Table&) {
    const auto& commits = fake(world).commits;
    expect(commits.size() == 1 && commits.first().subject == c[0] && commits.first().files.size() == 2,
           QStringLiteral("the MC made %1 commits: %2").arg(commits.size()).arg(commits.isEmpty() ? QString() : commits.first().subject));
  });
  step(QStringLiteral("the user is told the commit was made with its short hash"), [](World& world, const Captures&, const Table&) {
    const QString title = QStringLiteral("Committed ") + fake(world).commits.last().sha.left(7);
    world.waitFor([&] { return toastTitled(world, title).value(QStringLiteral("type")) == QStringLiteral("success"); },
                  [&] { return QStringLiteral("the toast %1; the shell shows %2").arg(title, show(world.state(QStringLiteral("toasts")))); });
  });
  step(QStringLiteral("the writer model writes the commit message from the staged diff"), [](World& world, const Captures&, const Table&) {
    expect(!fake(world).inputs.isEmpty() && !fake(world).inputs.last().contains(QLatin1String("commitMessage")),
           QStringLiteral("the MC was asked %1").arg(show(fake(world).inputs.value(0).toVariantMap())));
  });
  step(QStringLiteral("the commit is made with that message"), [](World& world, const Captures&, const Table&) {
    expect(fake(world).commits.size() == 1 && fake(world).commits.first().subject == fake(world).generatedMessage, QStringLiteral("the MC made %1 commits").arg(fake(world).commits.size()));
  });
  step(QStringLiteral("the commit holds only %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(fake(world).commits.size() == 1 && fake(world).commits.first().files == QStringList{c[0]},
           QStringLiteral("the commit holds %1").arg(fake(world).commits.value(0).files.join(u", ")));
  });
  step(QStringLiteral("%1 is still changed in the working tree").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      const QVariantList files = git(world).value(QStringLiteral("files")).toList();
      return files.size() == 1 && files.first().toMap().value(QStringLiteral("path")) == c[0];
    }, [&] { return QStringLiteral("the changed files are %1").arg(show(git(world).value(QStringLiteral("files")))); });
  });
  step(QStringLiteral("a branch named after the message under %1 is created and checked out").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString branch = fake(world).branch.value_or(QString());
    expect(branch.startsWith(c[0]) && branch.contains(QLatin1String("add-tax")), QStringLiteral("the checkout is on %1").arg(branch));
    world.waitFor([&] { return world.mc.threads.value(kThread).value(QLatin1String("branch")).toString() == branch; },
                  [&] { return QStringLiteral("the thread to be on %1; it is on %2").arg(branch, world.mc.threads.value(kThread).value(QLatin1String("branch")).toString()); });
  });
  step(QStringLiteral("the commit is made on that branch"), [](World& world, const Captures&, const Table&) {
    expect(fake(world).commits.size() == 1 && fake(world).commits.first().branch == fake(world).branch.value_or(QString()),
           QStringLiteral("the commit is on %1").arg(fake(world).commits.value(0).branch));
  });

  // Progress, results, pulling, init, publishing and links.
  step(QStringLiteral("the pre-commit hook prints %1 and waits").arg(q), [](World& world, const Captures& c, const Table&) {
    fake(world).hookLine = c[0];
    fake(world).waitAfterHook = true;
  });
  step(QStringLiteral("the user starts committing with the message %1").arg(q), [](World& world, const Captures& c, const Table&) {
    dispatch(world, QStringLiteral("git.commit"), {{QStringLiteral("message"), c[0]}, {QStringLiteral("filePaths"), QVariant::fromValue(nullptr)}});
  });
  step(QStringLiteral("the hook finishes"), [](World& world, const Captures&, const Table&) {
    FakeCheckout& checkout = fake(world);
    expect(checkout.held.has_value(), QStringLiteral("no action is waiting"));
    checkout.waitAfterHook = false;
    finish(world.mc, *std::exchange(checkout.held, std::nullopt), checkout.inputs.last());
    awaitIdle(world);
  });
  // The commit review (GitActions' dialog), as the git menu's Commit opens it.
  const auto startCommit = [](World& world) -> QObject* {
    Brick& brick = gitBrick(world);
    QObject* dialog = brick.root()->findChild<QObject*>(QStringLiteral("commitDialog"));
    expect(dialog != nullptr, QStringLiteral("the git actions have no commit review"));
    world.waitFor([&] { return git(world).value(QStringLiteral("files")).toList().size() > 0; }, QStringLiteral("the changed files to be listed"));
    QMetaObject::invokeMethod(dialog, "reset");
    QMetaObject::invokeMethod(dialog, "open");
    world.waitFor([&] { return dialog->property("opened").toBool(); }, QStringLiteral("the commit review to open"));
    return dialog;
  };
  step(QStringLiteral("the user starts a commit"), [startCommit](World& world, const Captures&, const Table&) { startCommit(world); });
  step(QStringLiteral("the user leaves every file out of the commit"), [startCommit](World& world, const Captures&, const Table&) {
    startCommit(world);
    for (const QString& path : std::as_const(fake(world).changed)) world.brick->click(QStringLiteral("fileCheck-") + path);
  });
  step(QStringLiteral("neither committing nor committing on a new branch is possible"), [](World& world, const Captures&, const Table&) {
    Brick& brick = gitBrick(world);
    world.waitFor([&] { return !brick.item(QStringLiteral("commitSelected"))->isEnabled() && !brick.item(QStringLiteral("commitNewBranch"))->isEnabled(); },
                  QStringLiteral("Commit and Commit on new branch to be unavailable"));
    expect(fake(world).inputs.isEmpty(), QStringLiteral("the MC ran %1 actions").arg(fake(world).inputs.size()));
    // The reverse: a file put back makes committing possible again.
    brick.click(QStringLiteral("fileCheck-") + fake(world).changed.first());
    world.waitFor([&] { return brick.item(QStringLiteral("commitSelected"))->isEnabled(); }, QStringLiteral("Commit to be available again"));
  });
  step(QStringLiteral("the user starts a commit and then cancels it"), [startCommit](World& world, const Captures&, const Table&) {
    QObject* dialog = startCommit(world);
    world.brick->click(QStringLiteral("commitCancel"));
    world.waitFor([&] { return !dialog->property("opened").toBool(); }, QStringLiteral("the commit review to close"));
    world.sync();
  });
  step(QStringLiteral("nothing is committed and both files are still changed"), [](World& world, const Captures&, const Table&) {
    expect(fake(world).inputs.isEmpty() && fake(world).commits.isEmpty() && fake(world).changed.size() == 2 && git(world).value(QStringLiteral("files")).toList().size() == 2,
           QStringLiteral("the MC ran %1 actions; the git actions are %2").arg(fake(world).inputs.size()).arg(show(git(world))));
  });
  step(QStringLiteral("the user is warned that the commit lands on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString warning = QStringLiteral("Warning: committing on the default branch %1").arg(c[0]);
    world.waitFor([&] { return world.brick->shows(warning); }, QStringLiteral("the warning \"%1\"").arg(warning));
  });

  // A running action's stage, elapsed time and hook line (`git.progress`), as the pill draws them.
  step(QStringLiteral("the repository has a slow pre-commit hook"), [](World& world, const Captures&, const Table&) {
    fake(world).hookLine = QStringLiteral("lint: 12 files checked");
    fake(world).waitWhileWriting = true;
    fake(world).waitAfterHook = true;
  });
  step(QStringLiteral("the user sees %1 and then %1 with the elapsed time").arg(q), [](World& world, const Captures& c, const Table&) {
    const auto progress = [&world] { return git(world).value(QStringLiteral("progress")).toMap(); };
    world.waitFor([&] { return progress().value(QStringLiteral("stage")) == c[0] && progress().value(QStringLiteral("elapsed")) == QLatin1String("0s"); },
                  [&] { return QStringLiteral("the action to say %1; the git actions are %2").arg(c[0], show(git(world))); });
    world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nGitActions {}\n", QSize(900, 200));
    world.waitFor([&] { return world.brick->shows(c[0] + QStringLiteral(" 0s")); }, QStringLiteral("the pill to say \"%1 0s\"").arg(c[0]));
    // Five seconds on, the message is written and the hook runs.
    world.setTime(world.now().addSecs(5));
    FakeCheckout& checkout = fake(world);
    expect(checkout.held.has_value(), QStringLiteral("no action is waiting"));
    checkout.waitWhileWriting = false;
    const int id = *std::exchange(checkout.held, std::nullopt);
    const QJsonObject input = checkout.inputs.takeLast();
    // run() picks the action up where it waited.
    phase(world.mc, id, QStringLiteral("commit"), QStringLiteral("Committing..."));
    sendEvent(world.mc, id, {{QStringLiteral("kind"), QStringLiteral("hook_started")}, {QStringLiteral("hookName"), QStringLiteral("pre-commit")}});
    sendEvent(world.mc, id, {{QStringLiteral("kind"), QStringLiteral("hook_output")}, {QStringLiteral("hookName"), QStringLiteral("pre-commit")},
                             {QStringLiteral("stream"), QStringLiteral("stdout")}, {QStringLiteral("text"), QStringLiteral("lint: starting\n") + checkout.hookLine + QLatin1Char('\n')}});
    checkout.inputs.append(input);
    checkout.held = id;
    world.waitFor([&] { return progress().value(QStringLiteral("stage")) == c[1] && progress().value(QStringLiteral("elapsed")) == QLatin1String("5s"); },
                  [&] { return QStringLiteral("the action to say %1 after 5s; the git actions are %2").arg(c[1], show(git(world))); });
    world.waitFor([&] { return world.brick->shows(c[1] + QStringLiteral(" 5s")); }, QStringLiteral("the pill to say \"%1 5s\"").arg(c[1]));
  });
  step(QStringLiteral("the last line the hook printed"), [](World& world, const Captures&, const Table&) {
    const QString line = fake(world).hookLine;
    expect(at(git(world), QStringLiteral("progress.hookLine")) == line, QStringLiteral("the git actions are %1").arg(show(git(world))));
    expect(toastTitled(world, QStringLiteral("Committing...")).value(QStringLiteral("description")) == line,
           QStringLiteral("the shell shows %1").arg(show(world.state(QStringLiteral("toasts")))));
    // Once the hook is done the action finishes and the progress goes.
    FakeCheckout& checkout = fake(world);
    checkout.waitAfterHook = false;
    finish(world.mc, *std::exchange(checkout.held, std::nullopt), checkout.inputs.last());
    awaitIdle(world);
    expect(git(world).value(QStringLiteral("progress")).isNull(), QStringLiteral("the git actions are %1").arg(show(git(world))));
  });

  // A failure stays until the user closes it (errors.feature).
  step(QStringLiteral("the push will be rejected by the remote"), [](World& world, const Captures&, const Table&) {
    clean(fake(world));
    fake(world).ahead = {QStringLiteral("Add tax")};
    fake(world).failWith = QStringLiteral("remote: rejected (non-fast-forward)");
    fake(world).failPhase = QStringLiteral("push");
    settle(world);
  });
  step(QStringLiteral("the failure stays visible until the user dismisses it"), [](World& world, const Captures&, const Table&) {
    const auto failure = [&world] { return toastTitled(world, QStringLiteral("Action failed")); };
    world.waitFor([&] { return failure().value(QStringLiteral("type")) == QLatin1String("error"); },
                  [&] { return QStringLiteral("the failure; the shell shows %1").arg(show(world.state(QStringLiteral("toasts")))); });
    expect(failure().value(QStringLiteral("description")) == QLatin1String("remote: rejected (non-fast-forward)"), QStringLiteral("the failure reads %1").arg(show(failure())));
    // Long after a result would have gone away by itself.
    world.setTime(world.now().addSecs(3600));
    world.sync();
    expect(!failure().isEmpty(), QStringLiteral("the failure went away by itself"));
    dispatch(world, QStringLiteral("notification.dismiss"), {{QStringLiteral("id"), failure().value(QStringLiteral("id"))}});
    expect(failure().isEmpty(), QStringLiteral("the shell still shows %1").arg(show(world.state(QStringLiteral("toasts")))));
  });

  step(QStringLiteral("the MC fails the action with %1").arg(q), [](World& world, const Captures& c, const Table&) { fake(world).failWith = c[0]; });
  step(QStringLiteral("the MC refuses to pull with %1").arg(q), [](World& world, const Captures& c, const Table&) { fake(world).refusePull = c[0]; });
  step(QStringLiteral("the MC refuses to initialize Git with %1").arg(q), [](World& world, const Captures& c, const Table&) { fake(world).refuseInit = c[0]; });
  step(QStringLiteral("the MC refuses to publish with %1").arg(q), [](World& world, const Captures& c, const Table&) { fake(world).refusePublish = c[0]; });
  step(QStringLiteral("the user runs the recommended action"), [](World& world, const Captures&, const Table&) {
    dispatch(world, QStringLiteral("git.quick"));
    awaitIdle(world);
  });
  step(QStringLiteral("the git actions offer to initialize Git"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return git(world).value(QStringLiteral("isRepo")) == false; },
                  [&] { return QStringLiteral("Initialize Git to be on offer; the git actions are %1").arg(show(git(world))); });
  });
  step(QStringLiteral("the user initializes Git"), [](World& world, const Captures&, const Table&) {
    dispatch(world, QStringLiteral("git.init"));
  });
  step(QStringLiteral("the checkout is a repository"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return fake(world).initialized && git(world).value(QStringLiteral("isRepo")) == true && !git(world).value(QStringLiteral("initPending")).toBool(); },
                  [&] { return QStringLiteral("the git actions are %1").arg(show(git(world))); });
  });
  step(QStringLiteral("the publish dialog is open"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return git(world).value(QStringLiteral("publishing")).typeId() == QMetaType::QVariantMap; },
                  [&] { return QStringLiteral("the publish dialog to open; the git actions are %1").arg(show(git(world))); });
  });
  step(QStringLiteral("the publish dialog is closed"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return git(world).value(QStringLiteral("publishing")).isNull(); },
                  [&] { return QStringLiteral("the publish dialog to close; the git actions are %1").arg(show(git(world))); });
  });
  step(QStringLiteral("the user publishes %1 as a (private|public) (GitHub|GitLab) repository").arg(q), [](World& world, const Captures& c, const Table&) {
    dispatch(world, QStringLiteral("git.publish.submit"),
             {{QStringLiteral("repository"), c[0]}, {QStringLiteral("visibility"), c[1]}, {QStringLiteral("provider"), c[2].toLower()}});
  });
  step(QStringLiteral("the user cancels publishing"), [](World& world, const Captures&, const Table&) {
    dispatch(world, QStringLiteral("git.publish.cancel"));
  });
  step(QStringLiteral("the MC published %1 to %1 as (private|public) on (github|gitlab)").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(fake(world).publishes.size() == 1, QStringLiteral("the MC was asked to publish %1 times").arg(fake(world).publishes.size()));
    const QJsonObject input = fake(world).publishes.first();
    expect(input.value(QLatin1String("repository")) == c[0] && input.value(QLatin1String("remoteName")) == c[1] &&
               input.value(QLatin1String("visibility")) == c[2] && input.value(QLatin1String("provider")) == c[3],
           QStringLiteral("the MC was asked %1").arg(show(input.toVariantMap())));
  });
  step(QStringLiteral("nothing is published"), [](World& world, const Captures&, const Table&) {
    expect(fake(world).publishes.isEmpty(), QStringLiteral("the MC was asked to publish"));
  });
  step(QStringLiteral("the publish dialog says %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return at(git(world), QStringLiteral("publishing.error")) == c[0] && !at(git(world), QStringLiteral("publishing.busy")).toBool(); },
                  [&] { return QStringLiteral("the git actions are %1").arg(show(git(world))); });
  });
  step(QStringLiteral("the MC is asked to push"), [](World& world, const Captures&, const Table&) {
    awaitIdle(world);
    expect(!fake(world).inputs.isEmpty() && fake(world).inputs.last().value(QLatin1String("action")) == QStringLiteral("push"),
           QStringLiteral("the MC was asked %1").arg(show(fake(world).inputs.value(fake(world).inputs.size() - 1).toVariantMap())));
  });
  // Threads on another machine of the cluster.
  step(QStringLiteral("the action ran on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QString environment;
    for (const QJsonObject& sub : std::as_const(world.mc.subscriptions)) {
      const QJsonObject shape = sub.value(QLatin1String("shape")).toObject();
      if (shape.value(QLatin1String("type")) == QLatin1String("gitAction")) environment = shape.value(QLatin1String("environment")).toString();
    }
    expect(environment == c[0], QStringLiteral("the last action ran on \"%1\"").arg(environment));
  });
  step(QStringLiteral("the git actions are available again"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return git(world).value(QStringLiteral("available")).toBool() && git(world).value(QStringLiteral("unavailableReason")).isNull(); },
                  [&] { return QStringLiteral("the git actions are %1").arg(show(git(world))); });
  });
  step(QStringLiteral("the git actions say %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return git(world).value(QStringLiteral("unavailableReason")) == c[0] && !git(world).value(QStringLiteral("available")).toBool(); },
                  [&] { return QStringLiteral("the git actions are %1").arg(show(git(world))); });
  });

  // navigation/layout.feature: the header's git pill (GitActions) over the git state.
  step(QStringLiteral("the user opens the git actions from the header"), [](World& world, const Captures&, const Table&) {
    dispatch(world, QStringLiteral("git.refresh"));
  });
  step(QStringLiteral("the thread's git actions are offered"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return git(world).value(QStringLiteral("available")).toBool() && !git(world).value(QStringLiteral("menu")).toList().isEmpty(); },
                  [&] { return QStringLiteral("the header's git actions; the git state is %1").arg(show(git(world))); });
  });
});

}  // namespace
