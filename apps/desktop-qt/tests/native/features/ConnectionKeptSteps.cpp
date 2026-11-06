// What the client keeps of an environment besides its threads (LocalCache's
// providers and branch lists): the kept-for-later scenarios of
// features/connections/connection-health.feature. "studio" is a cluster member
// that goes down while the shell's own MC stays up; "hal-c2" is a project of
// the MC's own with a git checkout and a worktree of it.

#include <QJsonArray>
#include <QJsonObject>

#include "DraftController.h"
#include "FakeConfig.h"
#include "FakeGit.h"
#include "Harness.h"
#include "LocalCache.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "ShellStore.h"
#include "World.h"

namespace {

const QString kRoot = QStringLiteral("/work/hal-c2");
const QString kWorktree = QStringLiteral("/work/hal-c2-fix");

struct Kept {
  QString environment;
  QString project;
  QStringList branches;  // every branch of the checkout
  QList<FakeMc::Rpc> heldLists;  // vcs.listRefs left unanswered
};

Kept& kept(World& world) {
  return world.mc.part<Kept>();
}

QJsonObject model(const QString& slug, const QString& name) {
  return {{QStringLiteral("slug"), slug}, {QStringLiteral("name"), name}};
}

QJsonObject provider(const QString& id, const QString& name, const QJsonArray& models) {
  return {{QStringLiteral("instanceId"), id}, {QStringLiteral("driver"), id}, {QStringLiteral("displayName"), name}, {QStringLiteral("enabled"), true},
          {QStringLiteral("installed"), true}, {QStringLiteral("status"), QStringLiteral("ready")}, {QStringLiteral("models"), models}};
}

// The model names the composer's picker offers.
QStringList offeredModels(World& world) {
  QStringList names;
  for (const QVariant& instance : world.state(QStringLiteral("modelPicker")).toMap().value(QStringLiteral("instances")).toList()) {
    for (const QVariant& entry : instance.toMap().value(QStringLiteral("models")).toList()) names.append(entry.toMap().value(QStringLiteral("name")).toString());
  }
  return names;
}

QVariantMap workspace(World& world) {
  return world.state(QStringLiteral("workspace")).toMap();
}

QStringList shownBranches(World& world) {
  QStringList names;
  for (const QVariant& branch : workspace(world).value(QStringLiteral("branches")).toList()) names.append(branch.toMap().value(QStringLiteral("name")).toString());
  return names;
}

// The branch list kept for `cwd` on the MC's environment, once everything asked of the cache is done.
std::optional<QJsonObject> keptRefs(World& world, const QString& cwd) {
  LocalCache* cache = world.native().cache();
  std::optional<QJsonObject> found;
  bool read = false;
  cache->loadRefs(world.mc.environmentId, cwd, &world.native(), [&](const std::optional<QJsonObject>& list) {
    found = list;
    read = true;
  });
  cache->drain();
  expect(read, QStringLiteral("the cache did not answer"));
  return found;
}

QStringList names(const QJsonObject& list) {
  QStringList result;
  for (const QJsonValue& ref : list.value(QLatin1String("refs")).toArray()) result.append(ref.toObject().value(QLatin1String("name")).toString());
  return result;
}

// The picker of the open checkout shows the list for `query`, as the MC has it.
void search(World& world, const QString& query) {
  world.bridge().dispatch(QStringLiteral("workspace.branch.search"), QVariantMap{{QStringLiteral("query"), query}});
  world.waitFor([&] {
    const QVariantMap state = workspace(world);
    const QStringList shown = shownBranches(world);
    return !state.value(QStringLiteral("branchesLoading")).toBool() && !shown.isEmpty() &&
           std::all_of(shown.cbegin(), shown.cend(), [&](const QString& name) { return name.contains(query); });
  }, [&] { return QStringLiteral("the branches for \"%1\"; the picker shows %2").arg(query, show(workspace(world))); });
}

void pageToEnd(World& world) {
  while (shownBranches(world).size() < workspace(world).value(QStringLiteral("branchesTotal")).toInt()) {
    const qsizetype before = shownBranches(world).size();
    world.bridge().dispatch(QStringLiteral("workspace.branch.more"), {});
    world.waitFor([&] { return shownBranches(world).size() > before; }, [&] { return QStringLiteral("the next page; the picker shows %1").arg(show(workspace(world))); });
  }
}

// The MC's project "hal-c2", its checkout holding `branches` on main.
void project(World& world, const QStringList& branches) {
  kept(world).branches = branches;
  world.mc.projects.insert(QStringLiteral("hal-c2"), {{QStringLiteral("id"), QStringLiteral("hal-c2")}, {QStringLiteral("title"), QStringLiteral("hal-c2")},
                                                     {QStringLiteral("workspaceRoot"), kRoot}, {QStringLiteral("scripts"), QJsonArray()}});
  fakeGitRepo(world, kRoot, branches, QStringLiteral("main"), QStringLiteral("main"));
  world.connect();
  world.sync();
}

// A thread of "hal-c2", on its root or a worktree, open in the shell.
void openThread(World& world, const QString& id, const QString& worktree) {
  QJsonObject row{{QStringLiteral("id"), id}, {QStringLiteral("title"), id}, {QStringLiteral("projectId"), QStringLiteral("hal-c2")},
                  {QStringLiteral("branch"), QStringLiteral("main")},
                  {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")}, {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}};
  if (!worktree.isEmpty()) row.insert(QStringLiteral("worktreePath"), worktree);
  world.mc.threads.insert(id, row);
  world.mc.sendRow(id, row);
  world.sync();
  const QString key = world.mc.environmentId + QLatin1Char(':') + id;
  world.native().controller<NavigationController>()->open(NavigationController::Route::thread(key));
  world.waitFor([&] { return workspace(world).value(QStringLiteral("threadKey")) == key; },
                [&] { return QStringLiteral("the header to show %1; it shows %2").arg(key, show(workspace(world))); });
}

const Steps steps([] {
  const QString q = kQuoted;

  // The models an environment last reported.
  step(QStringLiteral("%1 last reported the models %2 and %3").arg(q, q, q), [](World& world, const Captures& c, const Table&) {
    Kept& state = kept(world);
    state.environment = c[0];
    state.project = QStringLiteral("project-") + c[0];
    world.connect();
    world.mc.join(c[0]);
    world.mc.sendPeerRow(c[0], state.project,
                         {{QStringLiteral("id"), state.project}, {QStringLiteral("title"), c[0]},
                          {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + c[0]}, {QStringLiteral("scripts"), QJsonArray()}},
                         QStringLiteral("project"));
    publishProvidersOn(world.mc, c[0], {provider(QStringLiteral("claudeAgent"), QStringLiteral("Claude"), {model(QStringLiteral("claude-sonnet"), c[1])}),
                                        provider(QStringLiteral("codex"), QStringLiteral("Codex"), {model(QStringLiteral("gpt-5"), c[2])})});
    world.sync();
    // A new task there, while it is up, hears them.
    world.native().controller<DraftController>()->start(c[0], state.project);
    world.waitFor([&] { return offeredModels(world).contains(c[1]) && offeredModels(world).contains(c[2]); },
                  [&] { return QStringLiteral("%1's models to be offered; the picker offers %2").arg(c[0], offeredModels(world).join(QStringLiteral(", "))); });
    world.native().controller<NavigationController>()->open(NavigationController::Route::of(QStringLiteral("home")));
    world.onSettingsPage.insert(QStringLiteral("areOffered"), [&world](const QStringList& captures) {
      world.waitFor([&] { return offeredModels(world).contains(captures[0]) && offeredModels(world).contains(captures[1]); },
                    [&] { return QStringLiteral("the picker offers %1").arg(offeredModels(world).join(QStringLiteral(", "))); });
    });
  });
  // Down before the app starts again: nothing of it is in memory, and its MC
  // says nothing of its providers.
  step(QStringLiteral("%1 is not reachable").arg(q), [](World& world, const Captures& c, const Table&) {
    world.quit();
    world.mc.setOnline(c[0], false);
    fakeConfig(world.mc).elsewhere.remove(c[0]);
    world.launch();
    world.connect();
    world.waitFor([&] { return world.native().store()->synchronized() && world.native().store()->servesEnvironment(c[0]); },
                  QStringLiteral("the shell to hear its MC"));
    expect(!world.native().store()->environmentOnline(c[0]), QStringLiteral("%1 is still online").arg(c[0]));
  });
  step(QStringLiteral("the user starts a new task for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.native().controller<DraftController>()->start(c[0], kept(world).project);
    world.waitFor([&] { return workspace(world).value(QStringLiteral("isDraft")).toBool(); }, [&] { return show(workspace(world)); });
  });

  // Branch lists.
  step(QStringLiteral("the user searched the branches of %1 for %2").arg(q, q), [](World& world, const Captures& c, const Table&) {
    expect(c[0] == QLatin1String("hal-c2"), QStringLiteral("the steps know hal-c2 only"));
    // More than a page of them.
    QStringList branches{QStringLiteral("main")};
    for (int n = 1; n <= 130; ++n) branches.append(n % 3 ? QStringLiteral("feature/f%1").arg(n) : QStringLiteral("%1/f%2").arg(c[1]).arg(n));
    project(world, branches);
    openThread(world, QStringLiteral("t-root"), {});
    search(world, {});
    // Its first page is not the whole list.
    expect(!keptRefs(world, kRoot), QStringLiteral("the first page was kept as the whole list"));
    pageToEnd(world);
    search(world, c[1]);
  });
  step(QStringLiteral("the client keeps the branches of %1 for later").arg(q), [](World& world, const Captures&, const Table&) {
    world.sync();
    world.native().cache()->drain();
  });
  step(QStringLiteral("the matches for %1 are not kept").arg(q), [](World& world, const Captures& c, const Table&) {
    const std::optional<QJsonObject> list = keptRefs(world, kRoot);
    expect(list.has_value(), QStringLiteral("the whole list was not kept"));
    const QStringList kept = names(*list);
    expect(kept.size() == ::kept(world).branches.size() && list->value(QLatin1String("totalCount")).toInt() == kept.size(),
           QStringLiteral("kept %1 of %2 branches (\"%3\" has %4 matches)").arg(kept.size()).arg(::kept(world).branches.size()).arg(c[0]).arg(names(*list).filter(c[0]).size()));
  });
  step(QStringLiteral("a branch picker opened offline never presents a partial list as the whole one"), [](World& world, const Captures&, const Table&) {
    world.mc.stopAccepting();
    world.mc.drop();
    world.waitFor([&] { return !world.mc.connected(); }, QStringLiteral("the MC to go"));
    // A search offline has no matches to show, and shows no others as them.
    world.bridge().dispatch(QStringLiteral("workspace.branch.search"), QVariantMap{{QStringLiteral("query"), QStringLiteral("f1")}});
    world.waitFor([&] { return !workspace(world).value(QStringLiteral("branchesLoading")).toBool() && shownBranches(world).isEmpty(); },
                  [&] { return QStringLiteral("offline, the search shows %1").arg(shownBranches(world).join(QStringLiteral(", "))); });
    // The picker opened offline: the whole list kept.
    world.bridge().dispatch(QStringLiteral("workspace.branch.search"), QVariantMap{{QStringLiteral("query"), QString()}});
    world.native().cache()->drain();
    world.waitFor([&] { return !workspace(world).value(QStringLiteral("branchesLoading")).toBool() && !shownBranches(world).isEmpty(); },
                  [&] { return show(workspace(world)); });
    const QVariantMap state = workspace(world);
    expect(shownBranches(world).size() == kept(world).branches.size() && state.value(QStringLiteral("branchesTotal")).toInt() == kept(world).branches.size(),
           QStringLiteral("offline, the picker shows %1 of %2 branches").arg(shownBranches(world).size()).arg(state.value(QStringLiteral("branchesTotal")).toInt()));
  });

  step(QStringLiteral("the client kept the branch list of %1 and of a worktree of %1").arg(q), [](World& world, const Captures&, const Table&) {
    project(world, {QStringLiteral("main"), QStringLiteral("fix/login"), QStringLiteral("fix/cart")});
    fakeGitRepo(world, kWorktree, {QStringLiteral("main"), QStringLiteral("fix/login"), QStringLiteral("fix/cart")}, QStringLiteral("fix/login"), QStringLiteral("main"));
    openThread(world, QStringLiteral("t-root"), {});
    search(world, {});
    openThread(world, QStringLiteral("t-worktree"), kWorktree);
    search(world, {});
    expect(keptRefs(world, kRoot) && keptRefs(world, kWorktree), QStringLiteral("both lists are not kept"));
  });
  step(QStringLiteral("a branch of %1 is created").arg(q), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("workspace.branch.create"), QVariantMap{{QStringLiteral("name"), QStringLiteral("fix/tax")}});
    world.waitFor([&] { return shownBranches(world).contains(QStringLiteral("fix/tax")) && !workspace(world).value(QStringLiteral("branchesLoading")).toBool(); },
                  [&] { return QStringLiteral("the new branch to be listed; the picker shows %1").arg(show(workspace(world))); });
  });
  step(QStringLiteral("neither kept list is offered again until it is read anew"), [](World& world, const Captures&, const Table&) {
    world.sync();
    // The worktree's was read anew after the change, and has the new branch.
    const std::optional<QJsonObject> worktree = keptRefs(world, kWorktree);
    const QStringList worktreeKept = worktree ? names(*worktree) : QStringList();
    expect(!worktree || worktreeKept.contains(QStringLiteral("fix/tax")), QStringLiteral("the worktree keeps %1").arg(worktreeKept.join(QStringLiteral(", "))));
    expect(!keptRefs(world, kRoot), QStringLiteral("the root's list from before the change is still kept"));
    // The root's picker, before its MC answers, offers nothing kept.
    world.mc.onRpc(QStringLiteral("vcs.listRefs"), [&world](const FakeMc::Rpc& rpc) { kept(world).heldLists.append(rpc); });
    openThread(world, QStringLiteral("t-root"), {});
    world.bridge().dispatch(QStringLiteral("workspace.branch.search"), QVariantMap{{QStringLiteral("query"), QString()}});
    world.waitFor([&] { return !kept(world).heldLists.isEmpty(); }, QStringLiteral("the root's list to be asked for"));
    world.native().cache()->drain();
    world.sync();
    expect(shownBranches(world).isEmpty(), QStringLiteral("the root's picker offers %1 before the MC answers").arg(shownBranches(world).join(QStringLiteral(", "))));
  });
});

}  // namespace
