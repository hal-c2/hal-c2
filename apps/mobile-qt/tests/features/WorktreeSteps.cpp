// A new thread's worktree on the phone, in the shared composer's context strip
// (features/source-control/worktrees-and-setup-scripts.feature): the MC's git
// for the project, `orchestration.launchThread` and the `worktreeSetup` shape.

#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>

#include "FakeThreads.h"
#include "Harness.h"
#include "Phone.h"
#include "World.h"

namespace {

#define S(text) QStringLiteral(text)

const QString kRoot = S("/work/shop");
const QString kNew = S("t-new");
const QString kAt = S("2026-09-23T09:00:00Z");

struct FakeWorktrees {
  QStringList branches;  // the project's, when it is a git project
  QList<QJsonObject> launches;
  QJsonObject setup;
  int sequence = 0;
};

const FakeMc::Extension worktrees([](FakeMc& mc) {
  mc.onShape(S("vcs"), [&mc](int id, const QJsonObject& shape) {
    const FakeWorktrees& fake = mc.part<FakeWorktrees>();
    if (fake.branches.isEmpty() || shape.value(QLatin1String("cwd")) != kRoot) return;
    mc.send({{S("t"), S("vcs")},
             {S("id"), id},
             {S("event"), QJsonObject{{S("_tag"), S("snapshot")},
                                      {S("local"), QJsonObject{{S("isRepo"), true}, {S("refName"), fake.branches.first()}, {S("hasWorkingTreeChanges"), false}}},
                                      {S("remote"), QJsonObject{}}}}});
  });
  mc.onRpc(S("vcs.listRefs"), [&mc](const FakeMc::Rpc& rpc) {
    const FakeWorktrees& fake = mc.part<FakeWorktrees>();
    const QString query = rpc.payload.value(QLatin1String("query")).toString();
    QJsonArray refs;
    for (const QString& name : fake.branches) {
      if (!query.isEmpty() && !name.contains(query, Qt::CaseInsensitive)) continue;
      refs.append(QJsonObject{{S("name"), name}, {S("current"), name == fake.branches.first()}, {S("isDefault"), name == fake.branches.first()}, {S("isRemote"), false}});
    }
    mc.reply(rpc, QJsonObject{{S("refs"), refs}, {S("isRepo"), true}, {S("hasPrimaryRemote"), false}, {S("nextCursor"), QJsonValue()}, {S("totalCount"), refs.size()}});
  });
  mc.onRpc(S("orchestration.launchThread"), [&mc](const FakeMc::Rpc& rpc) {
    mc.part<FakeWorktrees>().launches.append(rpc.payload);
    const QString threadId = rpc.payload.value(QLatin1String("threadId")).toString();
    const QJsonObject row{{S("id"), threadId}, {S("projectId"), rpc.payload.value(QLatin1String("projectId"))}, {S("title"), rpc.payload.value(QLatin1String("title"))},
                          {S("createdAt"), kAt}, {S("updatedAt"), kAt}};
    mc.threads.insert(threadId, row);
    mc.sendRow(threadId, row);
    mc.reply(rpc, QJsonObject{{S("threadId"), threadId}, {S("resumed"), false}});
  });
  mc.onShape(S("worktreeSetup"), [&mc](int id, const QJsonObject&) {
    const QJsonObject setup = mc.part<FakeWorktrees>().setup;
    mc.send({{S("t"), S("worktreeSetup")}, {S("id"), id}, {S("event"), setup.isEmpty() ? QJsonValue() : QJsonValue(setup)}});
  });
});

QVariantMap workspace(World& world) {
  return world.state(S("workspace")).toMap();
}

// A new thread's draft in the project, Codex ready to take it.
void newThread(World& world) {
  world.tap(S("newThread"));
  world.waitFor([&] { return workspace(world).value(S("isDraft")).toBool(); }, [&] { return S("the draft; the workspace is %1").arg(show(workspace(world))); });
  world.item(S("composer"));
}

// Takes the workspace choice's entry `index`.
void pickWorkspace(World& world, int index) {
  QQuickItem* picker = world.item(S("envModePicker"));
  world.tap(picker);
  QObject* popup = picker->property("popup").value<QObject*>();
  world.waitFor([&] { return popup->property("opened").toBool(); }, S("the workspace choice to open"));
  for (int guard = 0; picker->property("highlightedIndex").toInt() != index && guard < 8; ++guard) {
    world.press(picker->property("highlightedIndex").toInt() < index ? S("Down") : S("Up"));
  }
  expect(picker->property("highlightedIndex").toInt() == index, S("the workspace choice offers no entry %1").arg(index));
  world.press(S("Enter"));
  world.waitFor([&] { return !popup->property("visible").toBool(); }, S("the workspace choice to close"));
}

void chooseBase(World& world, const QString& name) {
  world.tap(S("branchButton"));
  world.awaitPopup(S("branchPicker"));
  world.type(name);
  world.waitFor([&] { return workspace(world).value(S("branchQuery")) == name && !workspace(world).value(S("branchesLoading")).toBool(); },
                [&] { return S("the refs for %1; the workspace is %2").arg(name, show(workspace(world))); });
  world.sync();
  world.press(S("Return"));
  world.awaitPopup(S("branchPicker"), false);
}

void send(World& world, const QString& text) {
  QQuickItem* input = world.item(S("input"));
  world.waitFor([&] { return input->isEnabled(); }, S("the composer to take text"));
  world.tap(input);
  world.type(text);
  world.tap(S("primaryAction"));
}

void startInNewWorktree(World& world, const QString& base) {
  newThread(world);
  pickWorkspace(world, 1);
  chooseBase(world, base);
  send(world, S("Add caching"));
}

QJsonObject launchStrategy(World& world) {
  const QList<QJsonObject>& launches = world.mc.part<FakeWorktrees>().launches;
  world.waitFor([&] { return !launches.isEmpty(); }, [&] { return S("a launch; the screen shows %1").arg(world.texts().join(S(" | "))); });
  return launches.constLast().value(QLatin1String("workspaceStrategy")).toObject();
}

QJsonObject stage(const QString& id, const QString& status) {
  return {{S("id"), id}, {S("status"), status}, {S("startedAt"), status == QLatin1String("pending") ? QJsonValue() : QJsonValue(kAt)}, {S("endedAt"), QJsonValue()},
          {S("percent"), QJsonValue()}, {S("detail"), QJsonValue()}, {S("tail"), QJsonArray()}};
}

void publishSetup(World& world, const QString& thread, const QString& phase, const QJsonArray& stages) {
  FakeWorktrees& fake = world.mc.part<FakeWorktrees>();
  fake.setup = {{S("threadId"), thread}, {S("phase"), phase}, {S("startedAt"), kAt}, {S("endedAt"), phase == QLatin1String("running") ? QJsonValue() : QJsonValue(kAt)},
                {S("branch"), S("hal-c2/cart-totals")}, {S("baseRef"), S("main")}, {S("worktreePath"), S("/work/worktrees/cart-totals")},
                {S("setupScript"), QJsonValue()}, {S("stages"), stages}, {S("error"), QJsonValue()}, {S("sequence"), ++fake.sequence}};
  for (const int id : world.mc.subscribers(S("worktreeSetup"))) {
    world.mc.send({{S("t"), S("worktreeSetup")}, {S("id"), id}, {S("event"), fake.setup}});
  }
  world.sync();
}

const Steps steps([] {
  const QString q = kQuoted;

  step(S("a connected environment with the git project %1 whose default branch is %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(world.mc.projects.contains(c[0]), S("the environment has no project %1").arg(c[0]));
    world.mc.part<FakeWorktrees>().branches = {c[1], S("release/2")};
    offerProviders(world.mc, {QJsonObject{{S("instanceId"), S("codex")}, {S("driver"), S("codex")}, {S("displayName"), S("Codex")}, {S("enabled"), true}, {S("installed"), true},
                                          {S("status"), S("ready")}, {S("models"), QJsonArray{QJsonObject{{S("slug"), S("gpt-5")}, {S("name"), S("GPT-5")}}}}}});
    pairWithEnvironment(world);
    world.sync();
  });
  step(S("the user starts a thread in a new worktree of %1").arg(q), [](World& world, const Captures&, const Table&) {
    startInNewWorktree(world, S("main"));
  });
  step(S("the thread starts in a worktree of its own"), [](World& world, const Captures&, const Table&) {
    const QJsonObject strategy = launchStrategy(world);
    expect(strategy.value(QLatin1String("type")) == QLatin1String("worktree"), S("the launch works in %1").arg(show(strategy.toVariantMap())));
  });
  step(S("the user starts a thread in a new worktree based on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    startInNewWorktree(world, c[0]);
  });
  step(S("the worktree starts from %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject strategy = launchStrategy(world);
    expect(strategy.value(QLatin1String("type")) == QLatin1String("worktree") && strategy.value(QLatin1String("baseRef")) == c[0], S("the launch works in %1").arg(show(strategy.toVariantMap())));
  });

  // The setup card over the thread its first message made.
  step(S("the user sends the first message of a thread in a new worktree"), [](World& world, const Captures&, const Table&) {
    startInNewWorktree(world, S("main"));
    launchStrategy(world);
    world.waitFor([&] { return !world.mc.subscribers(S("worktreeSetup")).isEmpty(); }, S("the phone to follow the new thread's setup"));
    const QString thread = world.mc.shapeOf(world.mc.subscribers(S("worktreeSetup")).last()).value(QLatin1String("threadId")).toString();
    world.thread = thread;
    publishSetup(world, thread, S("running"), {stage(S("fetch"), S("done")), stage(S("checkout"), S("running")), stage(S("setup-script"), S("pending")), stage(S("agent"), S("pending"))});
  });
  step(S("the thread shows the worktree's base, branch and path with the stages"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.shows(S("Setting up worktree…")); }, [&] { return S("the setup; the screen shows %1").arg(world.texts().join(S(" | "))); });
    world.tap(S("worktreeSetupDetails"));
    for (const QString& text : {S("main"), S("hal-c2/cart-totals"), S("/work/worktrees/cart-totals")}) {
      world.waitFor([&] { return world.shows(text, false); }, [&] { return S("\"%1\"; the screen shows %2").arg(text, world.texts().join(S(" | "))); });
    }
  });
  step(S("it reads %1 once the agent starts").arg(q), [](World& world, const Captures& c, const Table&) {
    publishSetup(world, world.thread, S("done"), {stage(S("fetch"), S("done")), stage(S("checkout"), S("done")), stage(S("setup-script"), S("done")), stage(S("agent"), S("done"))});
    world.waitFor([&] { return world.shows(c[0]); }, [&] { return S("\"%1\"; the screen shows %2").arg(c[0], world.texts().join(S(" | "))); });
  });

  // The previous worktree.
  step(S("the user just finished a thread in the worktree on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject row{{S("id"), S("t-done")}, {S("title"), S("Tax line")}, {S("projectId"), S("shop")}, {S("branch"), c[0]}, {S("worktreePath"), S("/work/shop-worktrees/tax")},
                          {S("createdAt"), kAt}, {S("updatedAt"), kAt}};
    world.mc.threads.insert(S("t-done"), row);
    world.mc.sendRow(S("t-done"), row);
    world.sync();
  });
  step(S("the user starts a new thread in %1").arg(q), [](World& world, const Captures&, const Table&) { newThread(world); });
  step(S("the user can pick the previous worktree on %1 for it").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return workspace(world).value(S("previousWorktree")).toMap().value(S("label")).toString().contains(c[0]); },
                  [&] { return S("the previous worktree offered; the workspace is %1").arg(show(workspace(world))); });
    pickWorkspace(world, 2);
    world.waitFor([&] { return workspace(world).value(S("worktreePath")) == QLatin1String("/work/shop-worktrees/tax") && workspace(world).value(S("branch")) == c[0]; },
                  [&] { return S("the draft in the previous worktree; the workspace is %1").arg(show(workspace(world))); });
  });
});

}  // namespace
