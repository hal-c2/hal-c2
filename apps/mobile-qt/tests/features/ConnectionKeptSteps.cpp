// What the phone keeps of an environment besides its threads (LocalCache's
// providers and branch lists): the kept-for-later scenarios of
// features/connections/connection-health.feature. "studio" is a cluster member
// that goes down while the phone's own MC stays up; "hal-c2" is a project of
// the MC's own with a git checkout and a worktree of it. The MC's `config` and
// git answers are this file's, put in place by the step that needs them, so
// the other steps files' fakes stay as they are for every other scenario.

#include <QJsonArray>
#include <QJsonObject>

#include <algorithm>

#include "DraftController.h"
#include "Harness.h"
#include "LocalCache.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "Phone.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "World.h"

namespace {

#define S(text) QStringLiteral(text)

const QString kRoot = S("/work/hal-c2");
const QString kWorktree = S("/work/hal-c2-fix");
const QString kAt = S("2026-09-23T09:00:00Z");

struct Kept {
  QString environment;
  QString project;
  QJsonArray providers; // what `environment` reports while it is up
  bool up = false;
  struct Repo {
    QStringList branches; // the current one first
    QString current;
  };
  QHash<QString, Repo> repos;   // by folder
  QStringList branches;         // every branch of the root's checkout
  QList<FakeMc::Rpc> heldLists; // vcs.listRefs left unanswered
};

Kept &kept(World &world) { return world.mc.part<Kept>(); }

// The MC answers `config` for its own environment (nothing of providers) and
// for `environment` while it is up.
void fakeConfig(World &world) {
  FakeMc &mc = world.mc;
  mc.onShape(S("config"), [&mc](int id, const QJsonObject &shape) {
    const QString environment =
        shape.value(QLatin1String("environment")).toString();
    const Kept &fake = mc.part<Kept>();
    if (environment == mc.environmentId) {
      mc.send({{S("t"), S("config")},
               {S("id"), id},
               {S("mc"), mc.name},
               {S("config"), QJsonObject{{S("providers"), QJsonArray()},
                                         {S("settings"), QJsonObject()}}}});
    } else if (environment == fake.environment && fake.up) {
      mc.send({{S("t"), S("config")},
               {S("id"), id},
               {S("config"), QJsonObject{{S("providers"), fake.providers},
                                         {S("settings"), QJsonObject()}}}});
    }
    mc.send({{S("t"), S("config.themes")},
             {S("id"), id},
             {S("themes"), QJsonArray()}});
  });
}

QJsonObject localStatus(const Kept::Repo &repo) {
  return {{S("isRepo"), true},
          {S("refName"), repo.current},
          {S("hasWorkingTreeChanges"), false}};
}

// The MC's checkouts: their `vcs` status, `vcs.listRefs` a page at a time and
// `vcs.createRef`.
void fakeGit(World &world) {
  FakeMc &mc = world.mc;
  mc.onShape(S("vcs"), [&mc](int id, const QJsonObject &shape) {
    const auto repo = mc.part<Kept>().repos.constFind(
        shape.value(QLatin1String("cwd")).toString());
    const QJsonObject local = repo == mc.part<Kept>().repos.cend()
                                  ? QJsonObject{{S("isRepo"), false}}
                                  : localStatus(*repo);
    mc.send({{S("t"), S("vcs")},
             {S("id"), id},
             {S("event"), QJsonObject{{S("_tag"), S("snapshot")},
                                      {S("local"), local},
                                      {S("remote"), QJsonObject()}}}});
  });
  mc.onRpc(S("vcs.listRefs"), [&mc](const FakeMc::Rpc &rpc) {
    const Kept::Repo repo = mc.part<Kept>().repos.value(
        rpc.payload.value(QLatin1String("cwd")).toString());
    const QString query = rpc.payload.value(QLatin1String("query")).toString();
    QJsonArray all;
    for (const QString &name : repo.branches) {
      if (!query.isEmpty() && !name.contains(query, Qt::CaseInsensitive))
        continue;
      all.append(QJsonObject{{S("name"), name},
                             {S("current"), name == repo.current},
                             {S("isDefault"), name == QLatin1String("main")},
                             {S("isRemote"), false}});
    }
    const int limit = rpc.payload.value(QLatin1String("limit")).toInt(100);
    const int cursor = rpc.payload.value(QLatin1String("cursor")).toInt(0);
    QJsonArray page;
    for (qsizetype index = cursor; index < all.size() && index < cursor + limit;
         ++index)
      page.append(all.at(index));
    mc.reply(rpc, QJsonObject{{S("refs"), page},
                              {S("isRepo"), true},
                              {S("hasPrimaryRemote"), false},
                              {S("nextCursor"), all.size() > cursor + limit
                                                    ? QJsonValue(cursor + limit)
                                                    : QJsonValue()},
                              {S("totalCount"), all.size()}});
  });
  mc.onRpc(S("vcs.createRef"), [&mc](const FakeMc::Rpc &rpc) {
    const QString cwd = rpc.payload.value(QLatin1String("cwd")).toString();
    const QString name = rpc.payload.value(QLatin1String("refName")).toString();
    Kept::Repo &repo = mc.part<Kept>().repos[cwd];
    repo.branches.insert(1, name);
    if (rpc.payload.value(QLatin1String("switchRef")).toBool()) {
      repo.branches.move(1, 0);
      repo.current = name;
    }
    for (const int id : mc.subscribers(S("vcs"))) {
      if (mc.shapeOf(id).value(QLatin1String("cwd")) != cwd)
        continue;
      mc.send({{S("t"), S("vcs")},
               {S("id"), id},
               {S("event"), QJsonObject{{S("_tag"), S("localUpdated")},
                                        {S("local"), localStatus(repo)}}}});
    }
    mc.reply(rpc, QJsonObject{{S("refName"), name}});
  });
}

QJsonObject model(const QString &slug, const QString &name) {
  return {{S("slug"), slug}, {S("name"), name}};
}

QJsonObject provider(const QString &id, const QString &name,
                     const QJsonArray &models) {
  return {{S("instanceId"), id},    {S("driver"), id},
          {S("displayName"), name}, {S("enabled"), true},
          {S("installed"), true},   {S("status"), S("ready")},
          {S("models"), models}};
}

// The model names the composer's picker offers.
QStringList offeredModels(World &world) {
  QStringList names;
  for (const QVariant &instance :
       world.state(S("modelPicker")).toMap().value(S("instances")).toList()) {
    for (const QVariant &entry : instance.toMap().value(S("models")).toList())
      names.append(entry.toMap().value(S("name")).toString());
  }
  return names;
}

QVariantMap workspace(World &world) {
  return world.state(S("workspace")).toMap();
}

QStringList shownBranches(World &world) {
  QStringList names;
  for (const QVariant &branch : workspace(world).value(S("branches")).toList())
    names.append(branch.toMap().value(S("name")).toString());
  return names;
}

// The branch list kept for `cwd` on the MC's environment, once everything asked
// of the cache is done.
std::optional<QJsonObject> keptRefs(World &world, const QString &cwd) {
  LocalCache *cache = world.native().cache();
  std::optional<QJsonObject> found;
  bool read = false;
  cache->loadRefs(world.mc.environmentId, cwd, &world.native(),
                  [&](const std::optional<QJsonObject> &list) {
                    found = list;
                    read = true;
                  });
  cache->drain();
  expect(read, S("the cache did not answer"));
  return found;
}

QStringList names(const QJsonObject &list) {
  QStringList result;
  for (const QJsonValue &ref : list.value(QLatin1String("refs")).toArray())
    result.append(ref.toObject().value(QLatin1String("name")).toString());
  return result;
}

// The picker of the open checkout shows the list for `query`, as the MC has it.
void search(World &world, const QString &query) {
  world.bridge().dispatch(S("workspace.branch.search"),
                          QVariantMap{{S("query"), query}});
  world.waitFor(
      [&] {
        const QStringList shown = shownBranches(world);
        return !workspace(world).value(S("branchesLoading")).toBool() &&
               !shown.isEmpty() &&
               std::all_of(
                   shown.cbegin(), shown.cend(),
                   [&](const QString &name) { return name.contains(query); });
      },
      [&] {
        return S("the branches for \"%1\"; the picker shows %2")
            .arg(query, show(workspace(world)));
      });
}

void pageToEnd(World &world) {
  while (shownBranches(world).size() <
         workspace(world).value(S("branchesTotal")).toInt()) {
    const qsizetype before = shownBranches(world).size();
    world.bridge().dispatch(S("workspace.branch.more"), {});
    world.waitFor([&] { return shownBranches(world).size() > before; },
                  [&] {
                    return S("the next page; the picker shows %1")
                        .arg(show(workspace(world)));
                  });
  }
}

// The MC's project "hal-c2", its checkout holding `branches` on main, and the
// phone paired with it.
void project(World &world, const QStringList &branches) {
  fakeGit(world);
  kept(world).branches = branches;
  kept(world).repos.insert(kRoot, {branches, S("main")});
  const QJsonObject row{
      {S("id"), S("hal-c2")},      {S("title"), S("hal-c2")},
      {S("workspaceRoot"), kRoot}, {S("scripts"), QJsonArray()},
      {S("createdAt"), kAt},       {S("updatedAt"), kAt}};
  world.mc.projects.insert(S("hal-c2"), row);
  pairWithEnvironment(world);
  world.mc.sendRow(S("hal-c2"), row, S("project"));
  world.sync();
  ShellStore *store = world.native().store();
  world.waitFor(
      [&] {
        return !store->projectRow(world.mc.environmentId, S("hal-c2"))
                    .isEmpty();
      },
      [&] {
        QStringList held;
        for (const QJsonObject &project :
             store->projectRows(world.mc.environmentId))
          held.append(project.value(QLatin1String("id")).toString());
        return S("the phone to hold hal-c2; it holds %1 of %2")
            .arg(held.join(S(", ")), store->environments().join(S(", ")));
      });
}

// A thread of "hal-c2", on its root or a worktree, open on the phone.
void openThread(World &world, const QString &id, const QString &worktree) {
  QJsonObject row{{S("id"), id},
                  {S("title"), id},
                  {S("projectId"), S("hal-c2")},
                  {S("branch"), S("main")},
                  {S("createdAt"), kAt},
                  {S("updatedAt"), kAt}};
  if (!worktree.isEmpty())
    row.insert(S("worktreePath"), worktree);
  world.mc.threads.insert(id, row);
  world.mc.sendRow(id, row);
  world.sync();
  const QString key = world.mc.environmentId + QLatin1Char(':') + id;
  world.native().controller<NavigationController>()->open(
      NavigationController::Route::thread(key));
  world.waitFor([&] { return workspace(world).value(S("threadKey")) == key; },
                [&] {
                  return S("the thread to show %1; it shows %2")
                      .arg(key, show(workspace(world)));
                });
}

const Steps steps([] {
  const QString q = kQuoted;

  // The models an environment last reported.
  step(S("%1 last reported the models %2 and %3").arg(q, q, q),
       [](World &world, const Captures &c, const Table &) {
         Kept &state = kept(world);
         state.environment = c[0];
         state.project = S("project-") + c[0];
         state.providers = {
             provider(S("claudeAgent"), S("Claude"),
                      {model(S("claude-sonnet"), c[1])}),
             provider(S("codex"), S("Codex"), {model(S("gpt-5"), c[2])})};
         state.up = true;
         fakeConfig(world);
         pairWithEnvironment(world);
         world.mc.join(c[0]);
         world.mc.sendPeerRow(c[0], state.project,
                              {{S("id"), state.project},
                               {S("title"), c[0]},
                               {S("workspaceRoot"), S("/work/") + c[0]},
                               {S("scripts"), QJsonArray()}},
                              S("project"));
         world.sync();
         // A new task there, while it is up, hears them.
         world.native().controller<DraftController>()->start(c[0],
                                                             state.project);
         world.waitFor(
             [&] {
               return offeredModels(world).contains(c[1]) &&
                      offeredModels(world).contains(c[2]);
             },
             [&] {
               return S("%1's models to be offered; the picker offers %2")
                   .arg(c[0], offeredModels(world).join(S(", ")));
             });
         world.native().controller<NavigationController>()->open(
             NavigationController::Route::of(S("home")));
       });
  // Down before the app opens again: nothing of it is in memory, and its MC
  // says nothing of its providers.
  step(S("%1 is not reachable").arg(q),
       [](World &world, const Captures &c, const Table &) {
         world.close();
         kept(world).up = false;
         world.mc.setOnline(c[0], false);
         world.open();
         world.waitFor(
             [&] {
               return world.native().store()->synchronized() &&
                      world.native().store()->servesEnvironment(c[0]);
             },
             S("the phone to hear its MC"));
         expect(!world.native().store()->environmentOnline(c[0]),
                S("%1 is still online").arg(c[0]));
       });
  step(S("the user starts a new task for %1").arg(q), [](World &world,
                                                         const Captures &c,
                                                         const Table &) {
    world.native().controller<DraftController>()->start(c[0],
                                                        kept(world).project);
    world.waitFor([&] { return workspace(world).value(S("isDraft")).toBool(); },
                  [&] { return show(workspace(world)); });
  });
  step(S("%1 and %2 are offered").arg(q, q),
       [](World &world, const Captures &c, const Table &) {
         world.waitFor(
             [&] {
               return offeredModels(world).contains(c[0]) &&
                      offeredModels(world).contains(c[1]);
             },
             [&] {
               return S("the picker offers %1")
                   .arg(offeredModels(world).join(S(", ")));
             });
       });

  // Branch lists.
  step(S("the user searched the branches of %1 for %2").arg(q, q),
       [](World &world, const Captures &c, const Table &) {
         expect(c[0] == QLatin1String("hal-c2"),
                S("the steps know hal-c2 only"));
         // More than a page of them.
         QStringList branches{S("main")};
         for (int n = 1; n <= 130; ++n)
           branches.append(n % 3 ? S("feature/f%1").arg(n)
                                 : S("%1/f%2").arg(c[1]).arg(n));
         project(world, branches);
         openThread(world, S("t-root"), {});
         search(world, {});
         // Its first page is not the whole list.
         expect(!keptRefs(world, kRoot),
                S("the first page was kept as the whole list"));
         pageToEnd(world);
         search(world, c[1]);
       });
  step(S("the client keeps the branches of %1 for later").arg(q),
       [](World &world, const Captures &, const Table &) {
         world.sync();
         world.native().cache()->drain();
       });
  step(S("the matches for %1 are not kept").arg(q),
       [](World &world, const Captures &c, const Table &) {
         const std::optional<QJsonObject> list = keptRefs(world, kRoot);
         expect(list.has_value(), S("the whole list was not kept"));
         const QStringList kept = names(*list);
         const qsizetype all = ::kept(world).branches.size();
         expect(kept.size() == all &&
                    list->value(QLatin1String("totalCount")).toInt() ==
                        kept.size(),
                S("kept %1 of %2 branches (\"%3\" has %4 matches)")
                    .arg(kept.size())
                    .arg(all)
                    .arg(c[0])
                    .arg(kept.filter(c[0]).size()));
       });
  step(S("a branch picker opened offline never presents a partial list as the "
         "whole one"),
       [](World &world, const Captures &, const Table &) {
         world.mc.stopAccepting();
         world.mc.drop();
         world.waitFor([&] { return !world.mc.connected(); },
                       S("the MC to go"));
         // A search offline has no matches to show, and shows no others as
         // them.
         world.bridge().dispatch(S("workspace.branch.search"),
                                 QVariantMap{{S("query"), S("f1")}});
         world.waitFor(
             [&] {
               return !workspace(world).value(S("branchesLoading")).toBool() &&
                      shownBranches(world).isEmpty();
             },
             [&] {
               return S("offline, the search shows %1")
                   .arg(shownBranches(world).join(S(", ")));
             });
         // The picker opened offline: the whole list kept.
         world.bridge().dispatch(S("workspace.branch.search"),
                                 QVariantMap{{S("query"), QString()}});
         world.native().cache()->drain();
         world.waitFor(
             [&] {
               return !workspace(world).value(S("branchesLoading")).toBool() &&
                      !shownBranches(world).isEmpty();
             },
             [&] { return show(workspace(world)); });
         const int total = workspace(world).value(S("branchesTotal")).toInt();
         expect(shownBranches(world).size() == kept(world).branches.size() &&
                    total == kept(world).branches.size(),
                S("offline, the picker shows %1 of %2 branches")
                    .arg(shownBranches(world).size())
                    .arg(total));
       });

  step(
      S("the client kept the branch list of %1 and of a worktree of %1").arg(q),
      [](World &world, const Captures &, const Table &) {
        project(world, {S("main"), S("fix/login"), S("fix/cart")});
        kept(world).repos.insert(
            kWorktree,
            {{S("fix/login"), S("main"), S("fix/cart")}, S("fix/login")});
        openThread(world, S("t-root"), {});
        search(world, {});
        openThread(world, S("t-worktree"), kWorktree);
        search(world, {});
        expect(keptRefs(world, kRoot) && keptRefs(world, kWorktree),
               S("both lists are not kept"));
      });
  step(S("a branch of %1 is created").arg(q),
       [](World &world, const Captures &, const Table &) {
         world.bridge().dispatch(S("workspace.branch.create"),
                                 QVariantMap{{S("name"), S("fix/tax")}});
         world.waitFor(
             [&] {
               return shownBranches(world).contains(S("fix/tax")) &&
                      !workspace(world).value(S("branchesLoading")).toBool();
             },
             [&] {
               return S("the new branch to be listed; the picker shows %1")
                   .arg(show(workspace(world)));
             });
       });
  step(S("neither kept list is offered again until it is read anew"),
       [](World &world, const Captures &, const Table &) {
         world.sync();
         // The worktree's was read anew after the change, and has the new
         // branch.
         const std::optional<QJsonObject> worktree = keptRefs(world, kWorktree);
         const QStringList worktreeKept =
             worktree ? names(*worktree) : QStringList();
         expect(!worktree || worktreeKept.contains(S("fix/tax")),
                S("the worktree keeps %1").arg(worktreeKept.join(S(", "))));
         expect(!keptRefs(world, kRoot),
                S("the root's list from before the change is still kept"));
         // The root's picker, before its MC answers, offers nothing kept.
         world.mc.onRpc(S("vcs.listRefs"), [&world](const FakeMc::Rpc &rpc) {
           kept(world).heldLists.append(rpc);
         });
         openThread(world, S("t-root"), {});
         world.bridge().dispatch(S("workspace.branch.search"),
                                 QVariantMap{{S("query"), QString()}});
         world.waitFor([&] { return !kept(world).heldLists.isEmpty(); },
                       S("the root's list to be asked for"));
         world.native().cache()->drain();
         world.sync();
         expect(shownBranches(world).isEmpty(),
                S("the root's picker offers %1 before the MC answers")
                    .arg(shownBranches(world).join(S(", "))));
       });
});

} // namespace
