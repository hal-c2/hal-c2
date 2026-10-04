// The workspace header and the composer's context strip (WorkspaceController),
// and the MC's git behind them: features/navigation/header.feature, navigation/layout.feature,
// threads/titles.feature, source-control/refs-and-branches.feature and
// source-control/worktrees-and-setup-scripts.feature.

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>

#include "FakeConfig.h"
#include "FakeGit.h"
#include "FilesFolders.h"
#include "Harness.h"
#include "NavigationController.h"
#include "World.h"
#include "WorkspaceController.h"

// ProviderSettingsSteps.cpp
void renameProviderInstance(World& world, const QString& from, const QString& to);

// ArchivedThreadsSteps.cpp
bool archiveListsOnly(World& world, const QString& title);

namespace {

const QString kThread = QStringLiteral("t1");

// The MC's checkouts, by folder: `vcs` status frames, `vcs.listRefs` (the
// current branch first, the default next, the rest most recently committed
// first, as the MC orders them), `vcs.switchRef` and `vcs.createRef`.
struct FakeGit {
  struct Repo {
    QStringList branches;  // most recently committed first
    QString current;
    QString defaultBranch;
  };
  QHash<QString, Repo> repos;
  QString refuseSwitch;  // git's explanation, when a switch fails
  QList<QJsonObject> editorCalls;  // every shell.openInEditor payload
  QList<int> refPages;  // the cursor of every vcs.listRefs
};

QJsonObject localStatus(const FakeGit::Repo& repo) {
  return {{QStringLiteral("isRepo"), true}, {QStringLiteral("refName"), repo.current}, {QStringLiteral("hasWorkingTreeChanges"), false}};
}

void sendStatus(FakeMc& mc, const QString& cwd) {
  const FakeGit::Repo repo = mc.part<FakeGit>().repos.value(cwd);
  for (const int id : mc.subscribers(QStringLiteral("vcs"))) {
    if (mc.shapeOf(id).value(QLatin1String("cwd")) != cwd) continue;
    mc.send({{QStringLiteral("t"), QStringLiteral("vcs")},
               {QStringLiteral("id"), id},
               {QStringLiteral("event"), QJsonObject{{QStringLiteral("_tag"), QStringLiteral("localUpdated")}, {QStringLiteral("local"), localStatus(repo)}}}});
  }
}

QJsonArray orderedRefs(const FakeGit::Repo& repo, const QString& query) {
  QStringList names;
  if (repo.branches.contains(repo.current)) names.append(repo.current);
  if (repo.defaultBranch != repo.current && repo.branches.contains(repo.defaultBranch)) names.append(repo.defaultBranch);
  for (const QString& branch : repo.branches) {
    if (!names.contains(branch)) names.append(branch);
  }
  QJsonArray refs;
  for (const QString& name : std::as_const(names)) {
    if (!query.isEmpty() && !name.contains(query, Qt::CaseInsensitive)) continue;
    refs.append(QJsonObject{{QStringLiteral("name"), name},
                            {QStringLiteral("current"), name == repo.current},
                            {QStringLiteral("isDefault"), name == repo.defaultBranch},
                            {QStringLiteral("isRemote"), false}});
  }
  return refs;
}

// The orchestration projection of `thread.metadata.update` on the MC's rows.
void applyMetadata(FakeMc& mc, const QJsonObject& command) {
  if (command.value(QLatin1String("type")) != QLatin1String("thread.metadata.update")) return;
  const QString threadId = command.value(QLatin1String("threadId")).toString();
  if (!mc.threads.contains(threadId)) return;
  QJsonObject& row = mc.threads[threadId];
  for (const QString& field : {QStringLiteral("title"), QStringLiteral("branch"), QStringLiteral("worktreePath")}) {
    if (!command.contains(field)) continue;
    if (command.value(field).isNull()) {
      row.remove(field);
    } else {
      row.insert(field, command.value(field));
    }
  }
  mc.sendRow(threadId, row);
}

const FakeMc::Extension extension([](FakeMc& mc) {
  mc.effects.append([&mc](const QJsonObject& command) { applyMetadata(mc, command); });
  mc.onShape(QStringLiteral("vcs"), [&mc](int id, const QJsonObject& shape) {
    const QString cwd = shape.value(QLatin1String("cwd")).toString();
    if (const auto checkout = mc.checkouts.constFind(cwd); checkout != mc.checkouts.cend()) {
      QJsonObject snapshot = (*checkout)();
      snapshot.insert(QStringLiteral("_tag"), QStringLiteral("snapshot"));
      mc.send({{QStringLiteral("t"), QStringLiteral("vcs")}, {QStringLiteral("id"), id}, {QStringLiteral("event"), snapshot}});
      return;
    }
    const auto repo = mc.part<FakeGit>().repos.constFind(cwd);
    const QJsonObject local = repo == mc.part<FakeGit>().repos.cend() ? QJsonObject{{QStringLiteral("isRepo"), false}} : localStatus(*repo);
    mc.send({{QStringLiteral("t"), QStringLiteral("vcs")},
               {QStringLiteral("id"), id},
               {QStringLiteral("event"), QJsonObject{{QStringLiteral("_tag"), QStringLiteral("snapshot")}, {QStringLiteral("local"), local}, {QStringLiteral("remote"), QJsonObject{}}}}});
  });
  mc.onRpc(QStringLiteral("vcs.listRefs"), [&mc](const FakeMc::Rpc& rpc) {
    const FakeGit::Repo repo = mc.part<FakeGit>().repos.value(rpc.payload.value(QLatin1String("cwd")).toString());
    const QJsonArray all = orderedRefs(repo, rpc.payload.value(QLatin1String("query")).toString());
    const int limit = rpc.payload.value(QLatin1String("limit")).toInt(100);
    const int cursor = rpc.payload.value(QLatin1String("cursor")).toInt(0);
    mc.part<FakeGit>().refPages.append(cursor);
    QJsonArray page;
    for (qsizetype index = cursor; index < all.size() && index < cursor + limit; ++index) page.append(all.at(index));
    mc.reply(rpc, QJsonObject{{QStringLiteral("refs"), page},
                                {QStringLiteral("isRepo"), true},
                                {QStringLiteral("hasPrimaryRemote"), false},
                                {QStringLiteral("nextCursor"), all.size() > cursor + limit ? QJsonValue(cursor + limit) : QJsonValue()},
                                {QStringLiteral("totalCount"), all.size()}});
  });
  mc.onRpc(QStringLiteral("vcs.switchRef"), [&mc](const FakeMc::Rpc& rpc) {
    FakeGit& git = mc.part<FakeGit>();
    if (!git.refuseSwitch.isEmpty()) {
      mc.refuse(rpc, git.refuseSwitch);
      return;
    }
    const QString cwd = rpc.payload.value(QLatin1String("cwd")).toString();
    const QString name = rpc.payload.value(QLatin1String("refName")).toString();
    git.repos[cwd].current = name;
    sendStatus(mc, cwd);
    mc.reply(rpc, QJsonObject{{QStringLiteral("refName"), name}});
  });
  mc.onRpc(QStringLiteral("vcs.createRef"), [&mc](const FakeMc::Rpc& rpc) {
    const QString cwd = rpc.payload.value(QLatin1String("cwd")).toString();
    const QString name = rpc.payload.value(QLatin1String("refName")).toString();
    FakeGit::Repo& repo = mc.part<FakeGit>().repos[cwd];
    repo.branches.prepend(name);
    if (rpc.payload.value(QLatin1String("switchRef")).toBool()) repo.current = name;
    sendStatus(mc, cwd);
    mc.reply(rpc, QJsonObject{{QStringLiteral("refName"), name}});
  });
  mc.onRpc(QStringLiteral("shell.openInEditor"), [&mc](const FakeMc::Rpc& rpc) {
    mc.part<FakeGit>().editorCalls.append(rpc.payload);
    mc.reply(rpc, QJsonValue::Null);
  });
});

QVariantMap workspace(World& world) {
  return world.state(QStringLiteral("workspace")).toMap();
}

QString root(const QString& project) {
  return QStringLiteral("/work/") + project;
}

// The project on the MC, sent again when the shell is already connected.
void putProject(World& world, const QString& project, const QJsonObject& fields = {}) {
  QJsonObject row = world.mc.projects.value(project);
  if (row.isEmpty()) {
    row = {{QStringLiteral("id"), project}, {QStringLiteral("title"), project}, {QStringLiteral("workspaceRoot"), root(project)}, {QStringLiteral("scripts"), QJsonArray()}};
  }
  for (auto it = fields.begin(); it != fields.end(); ++it) row.insert(it.key(), it.value());
  world.mc.projects.insert(project, row);
  QJsonArray rows;
  rows.append(QJsonArray{project, QStringLiteral("project"), row});
  world.mc.sendRows(world.mc.name, rows);
}

void putThread(World& world, const QString& threadId, const QJsonObject& fields) {
  QJsonObject row{{QStringLiteral("id"), threadId}, {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")}, {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}};
  for (auto it = fields.begin(); it != fields.end(); ++it) row.insert(it.key(), it.value());
  world.mc.threads.insert(threadId, row);
  world.mc.sendRow(threadId, row);
}

void gitRepo(World& world, const QString& project, const QStringList& branches, const QString& current, const QString& defaultBranch) {
  world.mc.part<FakeGit>().repos.insert(root(project), {branches, current, defaultBranch});
}

void open(World& world, const QString& threadKey) {
  world.native().controller<NavigationController>()->open(NavigationController::Route::thread(threadKey));
  world.waitFor([&] { return workspace(world).value(QStringLiteral("threadKey")) == threadKey; },
                [&] { return QStringLiteral("the header to show %1; it shows %2").arg(threadKey, show(workspace(world))); });
}

void openDraft(World& world, const QString& project) {
  world.openDraft(project);
  world.waitFor([&] { return workspace(world).value(QStringLiteral("isDraft")).toBool(); },
                [&] { return QStringLiteral("the header to show the draft; it shows %1").arg(show(workspace(world))); });
}

QString threadKey(World& world, const QString& threadId = kThread) {
  return world.mc.environmentId + QLatin1Char(':') + threadId;
}

void dispatch(World& world, const QString& action, const QVariantMap& payload = {}) {
  world.bridge().dispatch(action, payload);
  world.sync();  // what it asked of the MC has been answered
}

QStringList branchNames(World& world) {
  QStringList names;
  for (const QVariant& branch : workspace(world).value(QStringLiteral("branches")).toList()) {
    names.append(branch.toMap().value(QStringLiteral("name")).toString());
  }
  return names;
}

QVariantMap branchAt(World& world, qsizetype index) {
  const QVariantList branches = workspace(world).value(QStringLiteral("branches")).toList();
  if (index >= branches.size()) fail(QStringLiteral("the branch list is %1").arg(branchNames(world).join(QStringLiteral(", "))));
  return branches.at(index).toMap();
}

// The sidebar's row for the thread, in whichever section.
std::optional<QVariantMap> sidebarRow(World& world, const QString& key) {
  const QVariantMap sidebar = world.state(QStringLiteral("sidebar")).toMap();
  for (auto section = sidebar.cbegin(); section != sidebar.cend(); ++section) {
    if (section.value().typeId() != QMetaType::QVariantList) continue;
    for (const QVariant& row : section.value().toList()) {
      if (row.toMap().value(QStringLiteral("key")) == key) return row.toMap();
    }
  }
  return std::nullopt;
}

QString editorLabel(const QString& id) {
  if (id == QLatin1String("vscode")) return QStringLiteral("VS Code");
  if (id == QLatin1String("zed")) return QStringLiteral("Zed");
  if (id == QLatin1String("cursor")) return QStringLiteral("Cursor");
  return id;
}

QString editorId(const QString& label) {
  for (const QString& id : {QStringLiteral("vscode"), QStringLiteral("zed"), QStringLiteral("cursor")}) {
    if (editorLabel(id) == label) return id;
  }
  return label;
}

const Steps steps([] {
  const QString q = kQuoted;

  // Backgrounds.
  step(QStringLiteral("a connected environment with the thread %1 in the project %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.projects.insert(c[1], {{QStringLiteral("id"), c[1]}, {QStringLiteral("title"), c[1]}, {QStringLiteral("workspaceRoot"), root(c[1])}, {QStringLiteral("scripts"), QJsonArray()}});
    world.mc.threads.insert(kThread, {{QStringLiteral("id"), kThread}, {QStringLiteral("title"), c[0]}, {QStringLiteral("projectId"), c[1]}, {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")}, {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}});
    world.connect();
    open(world, threadKey(world));
  });
  step(QStringLiteral("a connected environment with a thread in the git project %1 on the branch %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.projects.insert(c[0], {{QStringLiteral("id"), c[0]}, {QStringLiteral("title"), c[0]}, {QStringLiteral("workspaceRoot"), root(c[0])}, {QStringLiteral("scripts"), QJsonArray()},
                                      {QStringLiteral("repositoryIdentity"), QJsonObject{{QStringLiteral("canonicalKey"), QStringLiteral("github.com/acme/") + c[0]}}}});
    world.mc.threads.insert(kThread, {{QStringLiteral("id"), kThread}, {QStringLiteral("title"), QStringLiteral("Tax line")}, {QStringLiteral("projectId"), c[0]}, {QStringLiteral("branch"), c[1]},
                                        {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")}, {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}});
    gitRepo(world, c[0], {c[1], QStringLiteral("main")}, c[1], QStringLiteral("main"));
    world.connect();
    open(world, threadKey(world));
  });
  step(QStringLiteral("a connected environment with the git project %1 whose default branch is %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.projects.insert(c[0], {{QStringLiteral("id"), c[0]}, {QStringLiteral("title"), c[0]}, {QStringLiteral("workspaceRoot"), root(c[0])}, {QStringLiteral("scripts"), QJsonArray()}});
    gitRepo(world, c[0], {c[1]}, c[1], c[1]);
    world.connect();
    world.sync();
  });

  // The header.
  step(QStringLiteral("the header shows the thread %1 in %1 on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      const QVariantMap state = workspace(world);
      return state.value(QStringLiteral("threadTitle")) == c[0] && state.value(QStringLiteral("projectTitle")) == c[1] &&
             state.value(QStringLiteral("branch")) == c[2];
    }, [&] { return QStringLiteral("the header to show %1 in %2 on %3; it shows %4").arg(c[0], c[1], c[2], show(workspace(world))); });
  });
  step(QStringLiteral("the header shows a new thread in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      const QVariantMap state = workspace(world);
      return state.value(QStringLiteral("isDraft")).toBool() && state.value(QStringLiteral("threadTitle")) == QLatin1String("New thread") &&
             state.value(QStringLiteral("projectTitle")) == c[0];
    }, [&] { return QStringLiteral("the header to show a new thread in %1; it shows %2").arg(c[0], show(workspace(world))); });
  });
  step(QStringLiteral("the user leaves the thread"), [](World& world, const Captures&, const Table&) {
    world.native().controller<NavigationController>()->open(NavigationController::Route::of(QStringLiteral("home")));
  });

  // Titles.
  step(QStringLiteral("the user renames %1 to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    if (renameManagedFolder(world, c[0], c[1])) return;
    // The same words rename a provider instance in the Providers settings.
    if (at(world.state(QStringLiteral("providerSettings")), QStringLiteral("open")).toBool()) {
      renameProviderInstance(world, c[0], c[1]);
      return;
    }
    expect(workspace(world).value(QStringLiteral("threadTitle")) == c[0], QStringLiteral("the header shows %1").arg(show(workspace(world))));
    dispatch(world, QStringLiteral("workspace.rename"), {{QStringLiteral("title"), c[1]}});
  });
  step(QStringLiteral("the user renames %1 to an empty title").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(workspace(world).value(QStringLiteral("threadTitle")) == c[0], QStringLiteral("the header shows %1").arg(show(workspace(world))));
    dispatch(world, QStringLiteral("workspace.rename"), {{QStringLiteral("title"), QStringLiteral("   ")}});
  });
  step(QStringLiteral("the environment rejects the rename"), [](World& world, const Captures&, const Table&) {
    world.mc.refusals.insert(QStringLiteral("thread.metadata.update"), QStringLiteral("Thread is being deleted"));
  });
  const auto titled = [](World& world, const QString& title) {
    const auto row = sidebarRow(world, threadKey(world));
    return row && row->value(QStringLiteral("title")) == title && workspace(world).value(QStringLiteral("threadTitle")) == title;
  };
  const auto describeTitle = [](World& world) {
    const auto row = sidebarRow(world, threadKey(world));
    return QStringLiteral("the thread list shows %1 and the header %2").arg(row ? show(*row) : QStringLiteral("no row"), workspace(world).value(QStringLiteral("threadTitle")).toString());
  };
  step(QStringLiteral("the thread is listed as %1").arg(q), [titled, describeTitle](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return titled(world, c[0]); }, [&] { return describeTitle(world); });
  });
  step(QStringLiteral("the title stays %1").arg(q), [titled, describeTitle](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(titled(world, c[0]), describeTitle(world));
  });
  step(QStringLiteral("the user picks Rename for %1 in the thread list").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("workspace.rename.begin"), QVariantMap{{QStringLiteral("threadKey"), c[0]}});
  });
  step(QStringLiteral("the header starts editing the title of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      const QVariantMap state = workspace(world);
      return state.value(QStringLiteral("threadKey")) == c[0] && state.value(QStringLiteral("renameRequestId")).toInt() > 0;
    }, [&] { return QStringLiteral("the header to edit %1's title; it shows %2").arg(c[0], show(workspace(world))); });
  });
  step(QStringLiteral("the MC has the thread %1 titled %1 in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    putThread(world, c[0], {{QStringLiteral("title"), c[1]}, {QStringLiteral("projectId"), c[2]}});
    world.sync();
  });
  step(QStringLiteral("the user goes to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    open(world, c[0]);
  });

  // Branches.
  step(QStringLiteral("%1 has the branches %1, %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    FakeGit::Repo& repo = world.mc.part<FakeGit>().repos[root(c[0])];
    repo.branches = {c[1], c[2], c[3]};
  });
  step(QStringLiteral("%1 has (\\d+) branches").arg(q), [](World& world, const Captures& c, const Table&) {
    FakeGit::Repo& repo = world.mc.part<FakeGit>().repos[root(c[0])];
    repo.branches = {repo.current, repo.defaultBranch};
    for (int branch = 1; repo.branches.size() < c[1].toInt(); ++branch) repo.branches.append(QStringLiteral("feature/%1").arg(branch, 3, 10, QLatin1Char('0')));
  });
  step(QStringLiteral("the user opens the branch list"), [](World& world, const Captures&, const Table&) {
    dispatch(world, QStringLiteral("workspace.branch.search"), {{QStringLiteral("query"), QString()}});
  });
  // The branch list's ListView asks for more at its end (Composer.qml).
  step(QStringLiteral("the user scrolls to the end of the branch list"), [](World& world, const Captures&, const Table&) {
    dispatch(world, QStringLiteral("workspace.branch.search"), {{QStringLiteral("query"), QString()}});
    expect(branchNames(world).size() == 100, QStringLiteral("the list opens with %1 branches").arg(branchNames(world).size()));
    dispatch(world, QStringLiteral("workspace.branch.more"));
  });
  step(QStringLiteral("the next page of branches is loaded"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return branchNames(world).size() == 200; }, [&] { return QStringLiteral("200 branches; the list has %1").arg(branchNames(world).size()); });
    const QStringList names = branchNames(world);
    expect(world.mc.part<FakeGit>().refPages == QList<int>{0, 100} && names.at(100) == QLatin1String("feature/099") && QSet<QString>(names.cbegin(), names.cend()).size() == 200 &&
               workspace(world).value(QStringLiteral("branchesTotal")).toInt() == 400,
           QStringLiteral("the MC was asked for pages at %1; the 101st branch is %2").arg(world.mc.part<FakeGit>().refPages.size()).arg(names.value(100)));
    // And the next, until the list is whole; then nothing more is asked.
    dispatch(world, QStringLiteral("workspace.branch.more"));
    dispatch(world, QStringLiteral("workspace.branch.more"));
    dispatch(world, QStringLiteral("workspace.branch.more"));
    expect(branchNames(world).size() == 400 && world.mc.part<FakeGit>().refPages.size() == 4, QStringLiteral("the list has %1 branches after %2 pages").arg(branchNames(world).size()).arg(world.mc.part<FakeGit>().refPages.size()));
  });
  step(QStringLiteral("the user copies the thread's branch name"), [](World& world, const Captures&, const Table&) {
    dispatch(world, QStringLiteral("workspace.branch.copy"));
  });
  step(QStringLiteral("%1 is on the clipboard").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(world.clipboard == c[0], QStringLiteral("the clipboard holds \"%1\"").arg(world.clipboard));
  });
  step(QStringLiteral("the agent checked out %1 in the thread's checkout").arg(q), [](World& world, const Captures& c, const Table&) {
    // The shell has seen the checkout on the thread's branch first.
    world.waitFor([&] { return !world.mc.subscribers(QStringLiteral("vcs")).isEmpty(); }, QStringLiteral("the shell to follow the checkout"));
    world.sync();
    FakeGit::Repo& repo = world.mc.part<FakeGit>().repos[root(workspace(world).value(QStringLiteral("projectTitle")).toString())];
    expect(world.mc.threads.value(kThread).value(QLatin1String("branch")).toString() == repo.current, QStringLiteral("the thread is not on the checkout's branch"));
    repo.branches.prepend(c[0]);
    repo.current = c[0];
  });
  step(QStringLiteral("the status updates"), [](World& world, const Captures&, const Table&) {
    sendStatus(world.mc, root(workspace(world).value(QStringLiteral("projectTitle")).toString()));
    world.sync();
  });
  const auto search = [](World& world, const Captures& c, const Table&) {
    dispatch(world, QStringLiteral("workspace.branch.search"), {{QStringLiteral("query"), c[0]}});
  };
  step(QStringLiteral("the user searches the branch list for %1").arg(q), search);
  step(QStringLiteral("the user searched the branch list for %1").arg(q), search);
  step(QStringLiteral("only %1 is listed").arg(q), [](World& world, const Captures& c, const Table&) {
    if (at(world.state(QStringLiteral("archivedThreads")), QStringLiteral("open")).toBool()) {
      world.waitFor([&] { return archiveListsOnly(world, c[0]); },
                    [&] { return QStringLiteral("only %1 archived; the archive is %2").arg(c[0], show(world.state(QStringLiteral("archivedThreads")))); });
      return;
    }
    expect(branchNames(world) == QStringList{c[0]}, QStringLiteral("the list is %1").arg(branchNames(world).join(QStringLiteral(", "))));
  });
  step(QStringLiteral("no ref matches"), [](World& world, const Captures&, const Table&) {
    expect(branchNames(world).isEmpty(), QStringLiteral("the list is %1").arg(branchNames(world).join(QStringLiteral(", "))));
  });
  step(QStringLiteral("%1 is marked current and listed first").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap first = branchAt(world, 0);
    expect(first.value(QStringLiteral("name")) == c[0] && first.value(QStringLiteral("current")).toBool(), QStringLiteral("the first is %1").arg(show(first)));
  });
  step(QStringLiteral("%1 is marked default and listed next").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap next = branchAt(world, 1);
    expect(next.value(QStringLiteral("name")) == c[0] && next.value(QStringLiteral("isDefault")).toBool(), QStringLiteral("the next is %1").arg(show(next)));
  });
  step(QStringLiteral("the other branches follow, most recently committed first"), [](World& world, const Captures&, const Table&) {
    const FakeGit::Repo repo = world.mc.part<FakeGit>().repos.value(root(workspace(world).value(QStringLiteral("projectTitle")).toString()));
    QStringList others;
    for (const QString& branch : repo.branches) {
      if (branch != repo.current && branch != repo.defaultBranch) others.append(branch);
    }
    expect(branchNames(world).mid(2) == others, QStringLiteral("the list is %1").arg(branchNames(world).join(QStringLiteral(", "))));
  });
  step(QStringLiteral("the user is told how many of the (\\d+) refs are shown and to type to narrow them"), [](World& world, const Captures& c, const Table&) {
    const QVariantMap state = workspace(world);
    const int total = state.value(QStringLiteral("branchesTotal")).toInt();
    const qsizetype shown = state.value(QStringLiteral("branches")).toList().size();
    // Composer.qml's "Showing N of M refs — type to narrow" shows while some are hidden.
    expect(total == c[0].toInt() && shown < total, QStringLiteral("%1 of %2 are shown").arg(shown).arg(total));
  });
  step(QStringLiteral("the user switches the thread to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    dispatch(world, QStringLiteral("workspace.branch.search"), {{QStringLiteral("query"), QString()}});
    dispatch(world, QStringLiteral("workspace.branch.select"), {{QStringLiteral("name"), c[0]}});
  });
  step(QStringLiteral("the MC cannot switch the checkout: %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.part<FakeGit>().refuseSwitch = c[0];
  });
  step(QStringLiteral("the checkout is on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString current = world.mc.part<FakeGit>().repos.value(root(workspace(world).value(QStringLiteral("projectTitle")).toString())).current;
    expect(current == c[0], QStringLiteral("the checkout is on %1").arg(current));
  });
  step(QStringLiteral("the thread's branch reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      return workspace(world).value(QStringLiteral("branch")) == c[0] &&
             world.mc.threads.value(kThread).value(QLatin1String("branch")).toString() == c[0] &&
             !workspace(world).value(QStringLiteral("branchSwitchPending")).toBool();
    }, [&] { return QStringLiteral("the branch to read %1; the header shows %2, the thread %3").arg(c[0], workspace(world).value(QStringLiteral("branch")).toString(), world.mc.threads.value(kThread).value(QLatin1String("branch")).toString()); });
  });
  step(QStringLiteral("the user creates it"), [](World& world, const Captures&, const Table&) {
    dispatch(world, QStringLiteral("workspace.branch.create"), {{QStringLiteral("name"), workspace(world).value(QStringLiteral("branchQuery"))}});
  });
  step(QStringLiteral("%1 is created and the checkout switches to it").arg(q), [](World& world, const Captures& c, const Table&) {
    const FakeGit::Repo repo = world.mc.part<FakeGit>().repos.value(root(workspace(world).value(QStringLiteral("projectTitle")).toString()));
    expect(repo.branches.contains(c[0]) && repo.current == c[0], QStringLiteral("the checkout is on %1 of %2").arg(repo.current, repo.branches.join(QStringLiteral(", "))));
    world.waitFor([&] { return workspace(world).value(QStringLiteral("branch")) == c[0] && world.mc.threads.value(kThread).value(QLatin1String("branch")).toString() == c[0]; },
                  [&] { return QStringLiteral("the thread's branch to read %1; the header shows %2").arg(c[0], show(workspace(world))); });
  });
  step(QStringLiteral("the thread in %1 shows the branch %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const auto row = sidebarRow(world, threadKey(world));
    expect(row && world.mc.threads.value(kThread).value(QLatin1String("projectId")) == c[0] && row->value(QStringLiteral("branch")) == c[1],
           QStringLiteral("the thread list shows %1").arg(row ? show(*row) : QStringLiteral("no row")));
  });

  // A new thread's checkout.
  step(QStringLiteral("the user is writing the first message of a new thread in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    openDraft(world, c[0]);
  });
  step(QStringLiteral("the user starts a thread in a new worktree based on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString project = world.mc.projects.firstKey();
    QStringList& branches = world.mc.part<FakeGit>().repos[root(project)].branches;
    if (!branches.contains(c[0])) branches.append(c[0]);
    openDraft(world, project);
    dispatch(world, QStringLiteral("workspace.envMode.set"), {{QStringLiteral("mode"), QStringLiteral("worktree")}});
    dispatch(world, QStringLiteral("workspace.branch.search"), {{QStringLiteral("query"), QString()}});
    dispatch(world, QStringLiteral("workspace.branch.select"), {{QStringLiteral("name"), c[0]}});
    dispatch(world, QStringLiteral("composer.submit"), {{QStringLiteral("text"), QStringLiteral("Ship the fix")}, {QStringLiteral("intent"), QStringLiteral("foreground")}});
  });
  step(QStringLiteral("the user chose a new worktree without a base branch"), [](World& world, const Captures&, const Table&) {
    // A checkout on no branch (a detached head) offers no base to start from.
    const QString project = world.mc.projects.firstKey();
    gitRepo(world, project, {QStringLiteral("main")}, QString(), QStringLiteral("main"));
    sendStatus(world.mc, root(project));
    world.startNewThread(QVariantMap());
    world.waitFor([&] { return workspace(world).value(QStringLiteral("isDraft")).toBool(); },
                  [&] { return QStringLiteral("the header to show the draft; it shows %1").arg(show(workspace(world))); });
    dispatch(world, QStringLiteral("workspace.envMode.set"), {{QStringLiteral("mode"), QStringLiteral("worktree")}});
  });
  step(QStringLiteral("the user picks the new worktree checkout mode"), [](World& world, const Captures&, const Table&) {
    dispatch(world, QStringLiteral("workspace.envMode.set"), {{QStringLiteral("mode"), QStringLiteral("worktree")}});
  });
  step(QStringLiteral("the user picks the current checkout mode"), [](World& world, const Captures&, const Table&) {
    dispatch(world, QStringLiteral("workspace.envMode.set"), {{QStringLiteral("mode"), QStringLiteral("local")}});
  });
  step(QStringLiteral("the user picked the new worktree checkout mode for a new thread"), [](World& world, const Captures&, const Table&) {
    openDraft(world, world.mc.projects.firstKey());
    dispatch(world, QStringLiteral("workspace.envMode.set"), {{QStringLiteral("mode"), QStringLiteral("worktree")}});
  });
  const auto startsIn = [](World& world, const QString& mode, const QString& label) {
    const QVariantMap state = workspace(world);
    expect(state.value(QStringLiteral("envMode")) == mode && state.value(QStringLiteral("envModeLabel")) == label &&
               world.native().controller<WorkspaceController>()->checkout(world.draftId).envMode == mode,
           QStringLiteral("the header shows %1").arg(show(state)));
  };
  step(QStringLiteral("the thread will start in a worktree of its own instead of the project folder"), [startsIn](World& world, const Captures&, const Table&) {
    startsIn(world, QStringLiteral("worktree"), QStringLiteral("New worktree"));
  });
  step(QStringLiteral("the thread will start in the project folder"), [startsIn](World& world, const Captures&, const Table&) {
    startsIn(world, QStringLiteral("local"), QStringLiteral("Current checkout"));
  });
  step(QStringLiteral("%1 has a checkout of %1 at %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString peer = world.mc.peers.value(c[0]);
    expect(!peer.isEmpty(), QStringLiteral("%1 is not in the cluster").arg(c[0]));
    const QString project = c[1] + QStringLiteral("-copy");
    QJsonArray rows;
    rows.append(QJsonArray{project, QStringLiteral("project"),
                           QJsonObject{{QStringLiteral("id"), project}, {QStringLiteral("title"), c[1]}, {QStringLiteral("workspaceRoot"), c[2]}, {QStringLiteral("scripts"), QJsonArray()},
                                       {QStringLiteral("repositoryIdentity"), QJsonObject{{QStringLiteral("canonicalKey"), QStringLiteral("github.com/acme/") + c[1]}}}}});
    world.mc.sendRows(peer, rows);
    world.sync();
  });
  step(QStringLiteral("the user runs the new thread on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    dispatch(world, QStringLiteral("workspace.environment.set"), {{QStringLiteral("environmentId"), c[0]}});
  });
  step(QStringLiteral("the new thread will start on %1 in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap state = workspace(world);
    expect(state.value(QStringLiteral("activeEnvironmentId")) == c[0] && state.value(QStringLiteral("projectRoot")) == c[1],
           QStringLiteral("the header shows %1").arg(show(state)));
  });
  step(QStringLiteral("%1 is offered to run the new thread on").arg(q), [](World& world, const Captures& c, const Table&) {
    for (const QVariant& choice : workspace(world).value(QStringLiteral("environments")).toList()) {
      if (choice.toMap().value(QStringLiteral("environmentId")) == c[0]) return;
    }
    fail(QStringLiteral("the header offers %1").arg(show(workspace(world).value(QStringLiteral("environments")))));
  });

  // The previous worktree (composer.previousWorktree).
  const auto finishedIn = [](World& world, const QString& branch) {
    const QString project = world.mc.projects.firstKey();
    const QString worktree = root(project) + QStringLiteral("-worktrees/") + QString(branch).replace(QLatin1Char('/'), QLatin1Char('-'));
    const QJsonObject row{{QStringLiteral("id"), QStringLiteral("t-done")}, {QStringLiteral("title"), QStringLiteral("Tax line")}, {QStringLiteral("projectId"), project},
                          {QStringLiteral("branch"), branch}, {QStringLiteral("worktreePath"), worktree},
                          {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")}, {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T10:00:00Z")}};
    world.mc.threads.insert(QStringLiteral("t-done"), row);
    world.mc.sendRow(QStringLiteral("t-done"), row);
    world.sync();
    return worktree;
  };
  const auto draftCheckout = [](World& world) {
    const QString draftId = world.native().controller<NavigationController>()->route().draftId;
    return world.native().controller<WorkspaceController>()->checkout(draftId);
  };
  const auto usesPrevious = [draftCheckout](World& world, const QString& branch) {
    world.waitFor([&] { return draftCheckout(world).worktreePath.has_value(); },
                  [&] { return QStringLiteral("the draft to use the previous worktree; the header shows %1").arg(show(workspace(world))); });
    const WorkspaceController::Checkout checkout = draftCheckout(world);
    expect(checkout.branch == branch && checkout.envMode == QLatin1String("worktree") && checkout.worktreePath->endsWith(QString(branch).replace(QLatin1Char('/'), QLatin1Char('-'))),
           QStringLiteral("the draft is on %1 at %2").arg(checkout.branch.value_or(QStringLiteral("no branch")), checkout.worktreePath.value_or(QString())));
  };
  step(QStringLiteral("the user just finished a thread in the worktree on %1").arg(q), [finishedIn](World& world, const Captures& c, const Table&) {
    finishedIn(world, c[0]);
  });
  step(QStringLiteral("the user can pick the previous worktree on %1 for it").arg(q), [usesPrevious](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return workspace(world).value(QStringLiteral("previousWorktree")).toMap().value(QStringLiteral("label")).toString().contains(c[0]); },
                  [&] { return QStringLiteral("the checkout picker to offer the previous worktree; the header shows %1").arg(show(workspace(world))); });
    dispatch(world, QStringLiteral("workspace.previousWorktree"));
    usesPrevious(world, c[0]);
  });
  step(QStringLiteral("the native composer has keyboard focus"), [finishedIn](World& world, const Captures&, const Table&) {
    const QString project = QStringLiteral("shop");
    world.mc.projects.insert(project, {{QStringLiteral("id"), project}, {QStringLiteral("title"), project}, {QStringLiteral("workspaceRoot"), root(project)}, {QStringLiteral("scripts"), QJsonArray()}});
    gitRepo(world, project, {QStringLiteral("main"), QStringLiteral("feature/tax")}, QStringLiteral("main"), QStringLiteral("main"));
    world.connect();
    finishedIn(world, QStringLiteral("feature/tax"));
    world.startNewThread(QVariantMap{{QStringLiteral("projectKey"), world.projectKey(project)}});
    world.waitFor([&] { return workspace(world).value(QStringLiteral("isDraft")).toBool(); },
                  [&] { return QStringLiteral("the header to show the draft; it shows %1").arg(show(workspace(world))); });
  });
  step(QStringLiteral("the composer switches to the previous worktree"), [usesPrevious](World& world, const Captures&, const Table&) {
    usesPrevious(world, QStringLiteral("feature/tax"));
    expect(!world.actionsOf(QStringLiteral("composer.focus")).isEmpty(), QStringLiteral("the composer did not take the keyboard back: %1").arg(world.describeBrickActions()));
  });

  // Editors.
  step(QStringLiteral("the environment has the editors %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    FakeConfig& fake = fakeConfig(world.mc);
    fake.config.insert(QStringLiteral("availableEditors"), QJsonArray{editorId(c[0]), editorId(c[1])});
    QJsonObject config = fake.config;
    config.insert(QStringLiteral("settings"), fake.settings);
    for (const int id : world.mc.subscribers(QStringLiteral("config"))) {
      if (world.mc.shapeOf(id).value(QLatin1String("environment")) != world.mc.environmentId) continue;
      world.mc.send({{QStringLiteral("t"), QStringLiteral("config")}, {QStringLiteral("id"), id}, {QStringLiteral("config"), config}});
    }
    world.sync();
  });
  step(QStringLiteral("%1 has the editors %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    fakeConfig(world.mc).elsewhere.insert(c[0], {{QStringLiteral("availableEditors"), QJsonArray{editorId(c[1]), editorId(c[2])}}});
  });
  step(QStringLiteral("the header lists the editors %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      QStringList labels;
      for (const QVariant& editor : workspace(world).value(QStringLiteral("editors")).toList()) labels.append(editor.toMap().value(QStringLiteral("label")).toString());
      return labels == QStringList{c[0], c[1]};
    }, [&] { return QStringLiteral("the header to list %1 and %2; it shows %3").arg(c[0], c[1], show(workspace(world))); });
  });
  step(QStringLiteral("the user opens the thread in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    dispatch(world, QStringLiteral("workspace.openInEditor"), {{QStringLiteral("editorId"), editorId(c[0])}});
  });
  step(QStringLiteral("the user opens the thread in their editor"), [](World& world, const Captures&, const Table&) {
    dispatch(world, QStringLiteral("workspace.openInEditor"));
  });
  step(QStringLiteral("%1 opens %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QList<QJsonObject>& calls = world.mc.part<FakeGit>().editorCalls;
    expect(!calls.isEmpty() && calls.last().value(QLatin1String("editor")) == editorId(c[0]) && calls.last().value(QLatin1String("cwd")) == c[1],
           QStringLiteral("the MC was asked %1").arg(calls.isEmpty() ? QStringLiteral("nothing") : QString::fromUtf8(QJsonDocument(calls.last()).toJson(QJsonDocument::Compact))));
  });
  step(QStringLiteral("%1 is the editor offered first").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(workspace(world).value(QStringLiteral("preferredEditorId")) == editorId(c[0]), QStringLiteral("the header shows %1").arg(show(workspace(world))));
  });

  // navigation/layout.feature's header, in its words.
  step(QStringLiteral("the header shows the project name and the thread title"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      const QVariantMap state = workspace(world);
      const QString key = state.value(QStringLiteral("threadKey")).toString();
      const QJsonObject thread = world.mc.threads.value(key.mid(key.indexOf(QLatin1Char(':')) + 1));
      const QJsonObject project = world.mc.projects.value(thread.value(QLatin1String("projectId")).toString());
      return !thread.isEmpty() && state.value(QStringLiteral("threadTitle")) == thread.value(QLatin1String("title")).toString() &&
             state.value(QStringLiteral("projectTitle")) == project.value(QLatin1String("title")).toString();
    }, [&] { return QStringLiteral("the header to name the thread and its project; it shows %1").arg(show(workspace(world))); });
  });
  step(QStringLiteral("the user opens the thread's workspace in %1 from the header").arg(q), [](World& world, const Captures& c, const Table&) {
    dispatch(world, QStringLiteral("workspace.openInEditor"), {{QStringLiteral("editorId"), editorId(c[0])}});
  });
  step(QStringLiteral("%1 opens the thread's workspace folder").arg(q), [](World& world, const Captures& c, const Table&) {
    const QList<QJsonObject>& calls = world.mc.part<FakeGit>().editorCalls;
    const QString folder = workspace(world).value(QStringLiteral("projectRoot")).toString();
    expect(!folder.isEmpty() && !calls.isEmpty() && calls.last().value(QLatin1String("editor")) == editorId(c[0]) && calls.last().value(QLatin1String("cwd")) == folder,
           QStringLiteral("the MC was asked %1").arg(calls.isEmpty() ? QStringLiteral("nothing") : QString::fromUtf8(QJsonDocument(calls.last()).toJson(QJsonDocument::Compact))));
  });
  step(QStringLiteral("%1 becomes the preferred editor").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(workspace(world).value(QStringLiteral("preferredEditorId")) == editorId(c[0]), QStringLiteral("the header shows %1").arg(show(workspace(world))));
  });

  // The header's buttons that leave the header.
  step(QStringLiteral("the checkout's pull request is %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    const QJsonObject remote{{QStringLiteral("pr"), QJsonObject{{QStringLiteral("number"), 7}, {QStringLiteral("title"), QStringLiteral("Tax line")},
                                                                {QStringLiteral("url"), c[0]}, {QStringLiteral("state"), QStringLiteral("open")}}}};
    for (const int id : world.mc.subscribers(QStringLiteral("vcs"))) {
      world.mc.send({{QStringLiteral("t"), QStringLiteral("vcs")},
                       {QStringLiteral("id"), id},
                       {QStringLiteral("event"), QJsonObject{{QStringLiteral("_tag"), QStringLiteral("remoteUpdated")}, {QStringLiteral("remote"), remote}}}});
    }
    world.sync();
  });
  step(QStringLiteral("the user opens the pull request from the header"), [](World& world, const Captures&, const Table&) {
    dispatch(world, QStringLiteral("workspace.openPullRequest"));
  });
  step(QStringLiteral("the browser opens %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(world.openedUrls == QList<QUrl>{QUrl(c[0])}, QStringLiteral("the browser opened %1").arg(world.openedUrls.size()));
  });

  // The header's editor button opens the preferred editor; it is there only
  // when the environment has editors.
  const auto setEditors = [](World& world, const QJsonArray& editors) {
    FakeConfig& fake = fakeConfig(world.mc);
    fake.config.insert(QStringLiteral("availableEditors"), editors);
    QJsonObject config = fake.config;
    config.insert(QStringLiteral("settings"), fake.settings);
    for (const int id : world.mc.subscribers(QStringLiteral("config"))) {
      if (world.mc.shapeOf(id).value(QLatin1String("environment")) != world.mc.environmentId) continue;
      world.mc.send({{QStringLiteral("t"), QStringLiteral("config")}, {QStringLiteral("id"), id}, {QStringLiteral("config"), config}});
    }
    world.sync();
  };
  step(QStringLiteral("the user has picked %1 as their preferred editor").arg(q), [setEditors](World& world, const Captures& c, const Table&) {
    setEditors(world, QJsonArray{editorId(QStringLiteral("Zed")), editorId(c[0])});
    dispatch(world, QStringLiteral("workspace.openInEditor"), {{QStringLiteral("editorId"), editorId(c[0])}});
    world.sync();
    expect(workspace(world).value(QStringLiteral("preferredEditorId")) == editorId(c[0]), QStringLiteral("the header shows %1").arg(show(workspace(world))));
    world.mc.part<FakeGit>().editorCalls.clear();
  });
  step(QStringLiteral("the user opens the thread's workspace from the header"), [](World& world, const Captures&, const Table&) {
    dispatch(world, QStringLiteral("workspace.openInEditor"));
  });
  step(QStringLiteral("the environment has no editors"), [setEditors](World& world, const Captures&, const Table&) {
    setEditors(world, QJsonArray());
  });
  step(QStringLiteral("the header does not offer to open the workspace in an editor"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(!workspace(world).isEmpty() && workspace(world).value(QStringLiteral("editors")).toList().isEmpty(), QStringLiteral("the header shows %1").arg(show(workspace(world))));
  });
});

}  // namespace

// The project's checkout with these branches, `current` checked out and the
// default, for other step files (ScheduledTasksSteps.cpp).
void seedBranches(World& world, const QString& project, const QStringList& branches, const QString& current) {
  gitRepo(world, project, branches, current, current);
}

void fakeGitRepo(World& world, const QString& cwd, const QStringList& branches, const QString& current, const QString& defaultBranch) {
  world.mc.part<FakeGit>().repos.insert(cwd, {branches, current, defaultBranch});
  sendStatus(world.mc, cwd);
}
