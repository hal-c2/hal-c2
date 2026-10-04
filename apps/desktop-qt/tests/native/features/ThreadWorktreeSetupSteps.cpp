// A new thread's worktree being prepared, as the conversation shows it
// (features/threads/worktree-setup.feature): the MC's `worktreeSetup` shape
// (a WorktreeSetupSnapshot, packages/contracts/src/worktreeSetup.ts) and the
// WorktreeSetupController that follows it for the open thread.

#include <QJsonArray>
#include <QJsonObject>

#include "Harness.h"
#include "Stream.h"
#include "World.h"

namespace {

const QString kId = QStringLiteral("t-cart");
const QString kAt = QStringLiteral("2026-09-23T09:00:00Z");

// The snapshot the MC holds for the thread, and who watches it.
struct FakeSetup {
  QJsonObject snapshot;
  int sequence = 0;
};

const FakeMc::Extension setups([](FakeMc& mc) {
  mc.onShape(QStringLiteral("worktreeSetup"), [&mc](int id, const QJsonObject&) {
    const QJsonObject snapshot = mc.part<FakeSetup>().snapshot;
    mc.send({{QStringLiteral("t"), QStringLiteral("worktreeSetup")}, {QStringLiteral("id"), id},
             {QStringLiteral("event"), snapshot.isEmpty() ? QJsonValue() : QJsonValue(snapshot)}});
  });
});

QJsonObject stage(const QString& id, const QString& status, const QString& detail = {}, const QStringList& tail = {}) {
  return {{QStringLiteral("id"), id}, {QStringLiteral("status"), status}, {QStringLiteral("startedAt"), status == QLatin1String("pending") ? QJsonValue() : QJsonValue(kAt)},
          {QStringLiteral("endedAt"), QJsonValue()}, {QStringLiteral("percent"), QJsonValue()},
          {QStringLiteral("detail"), detail.isEmpty() ? QJsonValue() : QJsonValue(detail)}, {QStringLiteral("tail"), QJsonArray::fromStringList(tail)}};
}

void publish(World& world, const QString& phase, const QJsonArray& stages, const QString& error = {}) {
  FakeSetup& fake = world.mc.part<FakeSetup>();
  fake.snapshot = {{QStringLiteral("threadId"), kId}, {QStringLiteral("phase"), phase}, {QStringLiteral("startedAt"), kAt},
                   {QStringLiteral("endedAt"), phase == QLatin1String("running") ? QJsonValue() : QJsonValue(kAt)},
                   {QStringLiteral("branch"), QStringLiteral("hal-c2/cart-totals")}, {QStringLiteral("baseRef"), QStringLiteral("main")},
                   {QStringLiteral("worktreePath"), QStringLiteral("/work/worktrees/cart-totals")},
                   {QStringLiteral("setupScript"), QJsonObject{{QStringLiteral("name"), QStringLiteral("Install")}, {QStringLiteral("command"), QStringLiteral("bun install")},
                                                               {QStringLiteral("terminalId"), QStringLiteral("setup-1")}}},
                   {QStringLiteral("stages"), stages}, {QStringLiteral("error"), error.isEmpty() ? QJsonValue() : QJsonValue(error)},
                   {QStringLiteral("sequence"), ++fake.sequence}};
  for (const int id : world.mc.subscribers(QStringLiteral("worktreeSetup"))) {
    world.mc.send({{QStringLiteral("t"), QStringLiteral("worktreeSetup")}, {QStringLiteral("id"), id}, {QStringLiteral("event"), fake.snapshot}});
  }
  world.sync();
}

QVariantMap shown(World& world) {
  return world.state(QStringLiteral("worktreeSetup")).toMap();
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("the project %1 has a setup script").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.projects.insert(c[0], {{QStringLiteral("id"), c[0]}, {QStringLiteral("title"), c[0]}, {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + c[0]},
                                    {QStringLiteral("scripts"), QJsonArray{QJsonObject{{QStringLiteral("id"), QStringLiteral("setup")}, {QStringLiteral("name"), QStringLiteral("Install")},
                                                                                       {QStringLiteral("command"), QStringLiteral("bun install")},
                                                                                       {QStringLiteral("runOnWorktreeCreate"), true}}}}});
  });
  step(QStringLiteral("the user started the thread %1 in a new worktree from %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.threads.insert(kId, {{QStringLiteral("id"), kId}, {QStringLiteral("title"), c[0]}, {QStringLiteral("projectId"), world.mc.projects.firstKey()},
                                  {QStringLiteral("createdAt"), kAt}, {QStringLiteral("updatedAt"), kAt}});
    world.connect();
    world.sync();
    stream::FakeStreams& streams = world.mc.part<stream::FakeStreams>();
    streams.thread = kId;
    streams.environment = world.mc.environmentId;
    stream::look(world, world.mc.environmentId + QLatin1Char(':') + kId);
    world.waitFor([&] { return !world.mc.subscribers(QStringLiteral("worktreeSetup")).isEmpty(); }, QStringLiteral("the shell to follow the thread's setup"));
  });
  step(QStringLiteral("the setup of %1 (is still running|finished|made the worktree but its setup script failed|failed|was cancelled)").arg(q),
       [](World& world, const Captures& c, const Table&) {
         const QString state = c[1];
         const QJsonObject fetched = stage(QStringLiteral("fetch"), QStringLiteral("done"));
         if (state == QLatin1String("is still running")) {
           publish(world, QStringLiteral("running"), {fetched, stage(QStringLiteral("checkout"), QStringLiteral("running"), QStringLiteral("120 files")),
                                                      stage(QStringLiteral("setup-script"), QStringLiteral("pending")), stage(QStringLiteral("agent"), QStringLiteral("pending"))});
         } else if (state == QLatin1String("finished")) {
           publish(world, QStringLiteral("done"), {fetched, stage(QStringLiteral("checkout"), QStringLiteral("done")), stage(QStringLiteral("setup-script"), QStringLiteral("done")),
                                                   stage(QStringLiteral("agent"), QStringLiteral("done"))});
         } else if (state.startsWith(QLatin1String("made the worktree"))) {
           publish(world, QStringLiteral("done"), {fetched, stage(QStringLiteral("checkout"), QStringLiteral("done")),
                                                   stage(QStringLiteral("setup-script"), QStringLiteral("failed"), QStringLiteral("exit 1"), {QStringLiteral("error: lockfile is frozen")}),
                                                   stage(QStringLiteral("agent"), QStringLiteral("done"))});
         } else if (state == QLatin1String("failed")) {
           publish(world, QStringLiteral("failed"), {fetched, stage(QStringLiteral("checkout"), QStringLiteral("failed"), QStringLiteral("exit 128")),
                                                     stage(QStringLiteral("setup-script"), QStringLiteral("skipped")), stage(QStringLiteral("agent"), QStringLiteral("skipped"))},
                   QStringLiteral("Could not create the worktree: the branch already exists."));
         } else {
           publish(world, QStringLiteral("cancelled"), {fetched, stage(QStringLiteral("checkout"), QStringLiteral("done")),
                                                        stage(QStringLiteral("setup-script"), QStringLiteral("skipped")), stage(QStringLiteral("agent"), QStringLiteral("skipped"))});
         }
       });
  step(QStringLiteral("the conversation says %1").arg(q), [](World& world, const Captures& c, const Table&) {
    // WorktreeSetupCard.qml shows the label over the conversation.
    world.waitFor([&] { return shown(world).value(QStringLiteral("label")) == c[0]; },
                  [&] { return QStringLiteral("\"%1\"; the setup shown is %2").arg(c[0], show(shown(world))); });
  });
  step(QStringLiteral("the user opens the setup details"), [](World& world, const Captures&, const Table&) {
    expect(!shown(world).value(QStringLiteral("detailsOpen")).toBool(), QStringLiteral("the details are already open"));
    world.bridge().dispatch(QStringLiteral("worktreeSetup.details"), QVariantMap{{QStringLiteral("open"), true}});
  });
  step(QStringLiteral("the user sees why the setup failed and the steps that ran"), [](World& world, const Captures&, const Table&) {
    const QVariantMap setup = shown(world);
    QStringList ran;
    for (const QVariant& entry : setup.value(QStringLiteral("stages")).toList()) {
      ran.append(entry.toMap().value(QStringLiteral("label")).toString() + QLatin1Char('=') + entry.toMap().value(QStringLiteral("status")).toString());
    }
    expect(setup.value(QStringLiteral("detailsOpen")).toBool() && setup.value(QStringLiteral("error")) == QLatin1String("Could not create the worktree: the branch already exists.") &&
               ran == QStringList{QStringLiteral("Fetch base branch=done"), QStringLiteral("Check out files=failed"), QStringLiteral("Run setup script=skipped"),
                                  QStringLiteral("Start agent=skipped")},
           QStringLiteral("the setup shown is %1").arg(show(setup)));
  });
});

}  // namespace
