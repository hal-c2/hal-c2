// The right panel's Pull requests tab (ThreadPullRequests): the pull requests
// linked to a thread, from its shell row, and linking, unlinking and
// refreshing them as the MC does (apps/server-ex orchestration.ex
// thread.pull-request.link/unlink, pull_requests.ex invalidate).
// features/source-control/pull-request-threads.feature.

#include <QJsonArray>
#include <QJsonObject>
#include <QSet>

#include <QQuickItem>
#include <QTest>
#include <memory>

#include "Brick.h"
#include "Harness.h"
#include "KeybindingController.h"
#include "PullRequestReview.h"
#include "RightPanelController.h"
#include "Stream.h"
#include "ThreadPullRequests.h"
#include "World.h"

namespace {

using namespace stream;

// What GitHub holds of each pull request ("acme/shop#42"), the thread the
// scenario is about, and the pull requests the MC was asked to read again.
struct FakePullRequests {
  QHash<QString, QJsonObject> host{
      {QStringLiteral("acme/shop#42"),
       {{QStringLiteral("state"), QStringLiteral("open")}, {QStringLiteral("title"), QStringLiteral("Tax line fix")},
        {QStringLiteral("headBranch"), QStringLiteral("feature/tax")}, {QStringLiteral("baseBranch"), QStringLiteral("main")},
        {QStringLiteral("isDraft"), false}, {QStringLiteral("author"), QStringLiteral("ada")}, {QStringLiteral("additions"), 12},
        {QStringLiteral("deletions"), 3}, {QStringLiteral("reviewDecision"), QStringLiteral("review-required")},
        {QStringLiteral("checksState"), QStringLiteral("passing")}, {QStringLiteral("mergeability"), QStringLiteral("mergeable")},
        {QStringLiteral("syncedAt"), QStringLiteral("2026-09-23T09:00:00Z")}}},
      {QStringLiteral("acme/api#7"),
       {{QStringLiteral("state"), QStringLiteral("open")}, {QStringLiteral("title"), QStringLiteral("Tax API")},
        {QStringLiteral("headBranch"), QStringLiteral("tax")}, {QStringLiteral("baseBranch"), QStringLiteral("main")},
        {QStringLiteral("isDraft"), false}, {QStringLiteral("author"), QStringLiteral("ada")},
        {QStringLiteral("checksState"), QStringLiteral("pending")}, {QStringLiteral("syncedAt"), QStringLiteral("2026-09-23T09:00:00Z")}}},
  };
  QString thread;
  QList<QJsonObject> invalidated;
  // The host's stack: its base and its layers' numbers, bottom first.
  QString stackBase;
  QList<int> stack;
};

QString hostKey(const QJsonObject& reference) {
  return QStringLiteral("%1#%2").arg(reference.value(QLatin1String("repository")).toString()).arg(reference.value(QLatin1String("number")).toInt());
}

// The thread's links, each with what the host last said of it: the MC's sync.
void syncLinks(FakeMc& mc, const QString& threadId) {
  if (!mc.threads.contains(threadId)) return;
  QJsonObject row = mc.threads.value(threadId);
  QJsonArray links;
  for (const QJsonValue& value : row.value(QLatin1String("pullRequests")).toArray()) {
    QJsonObject link = value.toObject();
    const QJsonObject snapshot = mc.part<FakePullRequests>().host.value(hostKey(link));
    link.insert(QStringLiteral("snapshot"), snapshot.isEmpty() ? QJsonValue() : QJsonValue(snapshot));
    // A layer of the host's stack carries the stack (pull_requests/sync.ex).
    const FakePullRequests& fake = mc.part<FakePullRequests>();
    if (fake.stack.contains(link.value(QLatin1String("number")).toInt())) {
      QJsonArray layers;
      for (const int number : fake.stack) {
        layers.append(QJsonObject{{QStringLiteral("number"), number}, {QStringLiteral("headBranch"), QStringLiteral("stack/%1").arg(number)}, {QStringLiteral("state"), QStringLiteral("open")}});
      }
      link.insert(QStringLiteral("stack"), QJsonObject{{QStringLiteral("kind"), QStringLiteral("native")}, {QStringLiteral("id"), QStringLiteral("stack-1")},
                                                       {QStringLiteral("number"), 1}, {QStringLiteral("url"), QStringLiteral("https://github.com/acme/shop/stacks/1")},
                                                       {QStringLiteral("base"), fake.stackBase}, {QStringLiteral("layers"), layers}});
    }
    links.append(link);
  }
  row.insert(QStringLiteral("pullRequests"), links);
  mc.threads.insert(threadId, row);
  mc.sendRow(threadId, row);
}

const FakeMc::Extension pullRequests([](FakeMc& mc) {
  mc.effects.append([&mc](const QJsonObject& command) {
    const QString type = command.value(QLatin1String("type")).toString();
    if (type != QLatin1String("thread.pull-request.link") && type != QLatin1String("thread.pull-request.unlink")) return;
    const QString threadId = command.value(QLatin1String("threadId")).toString();
    QJsonObject row = mc.threads.value(threadId);
    QJsonArray links;
    bool known = false;
    for (const QJsonValue& value : row.value(QLatin1String("pullRequests")).toArray()) {
      const QJsonObject link = value.toObject();
      const bool same = hostKey(link) == hostKey(command) && link.value(QLatin1String("host")) == command.value(QLatin1String("host"));
      known = known || same;
      if (!(same && type == QLatin1String("thread.pull-request.unlink"))) links.append(link);
    }
    if (type == QLatin1String("thread.pull-request.link") && !known) {
      links.append(QJsonObject{{QStringLiteral("host"), command.value(QLatin1String("host"))},
                               {QStringLiteral("repository"), command.value(QLatin1String("repository"))},
                               {QStringLiteral("number"), command.value(QLatin1String("number"))},
                               {QStringLiteral("url"), command.value(QLatin1String("url"))},
                               {QStringLiteral("source"), command.value(QLatin1String("source"))},
                               {QStringLiteral("linkedAt"), QStringLiteral("2026-09-23T09:05:00Z")},
                               {QStringLiteral("snapshot"), QJsonValue()},
                               {QStringLiteral("stack"), QJsonValue()}});
    }
    row.insert(QStringLiteral("pullRequests"), links);
    mc.threads.insert(threadId, row);
    // The MC reads a new link from its host at once (Sync.request).
    syncLinks(mc, threadId);
  });
  mc.onRpc(QStringLiteral("pullRequests.invalidate"), [&mc](const FakeMc::Rpc& rpc) {
    // The pull requests page's refresh names no reference (PullRequestListSteps).
    if (!rpc.payload.contains(QLatin1String("reference"))) return mc.passOn(rpc);
    mc.part<FakePullRequests>().invalidated.append(rpc.payload.value(QLatin1String("reference")).toObject());
    syncLinks(mc, mc.part<FakePullRequests>().thread);
    mc.reply(rpc, QJsonValue::Null);
  });
});

ThreadPullRequests& model(World& world) {
  return *world.native().controller<RightPanelController>()->pullRequests();
}

QString describe(World& world) {
  ThreadPullRequests& prs = model(world);
  QStringList rows;
  for (int row = 0; row < prs.rowCount(); ++row) {
    rows.append(QStringLiteral("%1 \"%2\" %3/%4/%5").arg(prs.value(row, ThreadPullRequests::KeyRole).toString(),
                                                        prs.value(row, ThreadPullRequests::TitleRole).toString(),
                                                        prs.value(row, ThreadPullRequests::StateLabelRole).toString(),
                                                        prs.value(row, ThreadPullRequests::ChecksLabelRole).toString(),
                                                        prs.value(row, ThreadPullRequests::ReviewLabelRole).toString()));
  }
  return QStringLiteral("the tab lists %1 (%2, problem \"%3\")")
      .arg(rows.isEmpty() ? QStringLiteral("nothing") : rows.join(QStringLiteral("; ")),
           prs.online() ? QStringLiteral("online") : QStringLiteral("offline"), prs.problem());
}

int rowOf(World& world, int number) {
  ThreadPullRequests& prs = model(world);
  for (int row = 0; row < prs.rowCount(); ++row) {
    if (prs.value(row, ThreadPullRequests::NumberRole).toInt() == number) return row;
  }
  return -1;
}

QString keyOf(World& world, int number) {
  const int row = rowOf(world, number);
  if (row < 0) fail(describe(world));
  return model(world).value(row, ThreadPullRequests::KeyRole).toString();
}

void waitForRow(World& world, int number, bool listed) {
  world.waitFor([&] { return (rowOf(world, number) >= 0) == listed; }, [&] { return describe(world); });
}

// The thread the scenario is about, in "acme/shop", looked at with its Pull
// requests tab showing.
void lookAt(World& world, const QString& title) {
  FakePullRequests& fake = world.mc.part<FakePullRequests>();
  if (!fake.thread.isEmpty()) return;
  fake.thread = kThread;
  world.mc.threads.insert(kThread, {{QStringLiteral("id"), kThread}, {QStringLiteral("title"), title}, {QStringLiteral("projectId"), kProject},
                                      {QStringLiteral("pullRequests"), QJsonArray()},
                                      {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")}, {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}});
  world.mc.sendRow(kThread, world.mc.threads.value(kThread));
  world.sync();
  FakeStreams& streams = world.mc.part<FakeStreams>();
  streams.thread = kThread;
  streams.environment = world.mc.environmentId;
  look(world, world.mc.environmentId + QLatin1Char(':') + kThread);
  world.bridge().dispatch(QStringLiteral("rightPanel.add"), QVariantMap{{QStringLiteral("kind"), QStringLiteral("pull-requests")}});
  world.sync();
  expect(at(world.state(QStringLiteral("panel")), QStringLiteral("activeId")) == QLatin1String("pull-requests"),
         show(world.state(QStringLiteral("panel"))));
}

// As "Link pull request to thread" from the palette: the tab with its field open.
void link(World& world, const QString& text) {
  world.native().controller<RightPanelController>()->linkPullRequest();
  expect(model(world).linkOpen(), QStringLiteral("the link field is closed"));
  model(world).link(text);
  world.sync();
}

void setOnline(World& world, bool online) {
  world.mc.send({{QStringLiteral("t"), QStringLiteral("shell.mc")}, {QStringLiteral("id"), world.mc.subscribers(QStringLiteral("shell")).value(0)},
                   {QStringLiteral("mc"), world.mc.name}, {QStringLiteral("online"), online}});
  world.sync();
  world.waitFor([&] { return model(world).online() == online; }, [&] { return describe(world); });
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("a connected environment with the GitHub project %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.projects.insert(kProject, {{QStringLiteral("id"), kProject}, {QStringLiteral("title"), kProject},
                                          {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + kProject}, {QStringLiteral("scripts"), QJsonArray()},
                                          {QStringLiteral("repositoryIdentity"),
                                           QJsonObject{{QStringLiteral("canonicalKey"), QStringLiteral("github.com/") + c[0]}, {QStringLiteral("displayName"), c[0]}}}});
    world.connect();
    world.sync();
  });
  step(QStringLiteral("the environment also has the Azure DevOps project %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString id = QStringLiteral("azure-web");
    const QJsonObject row{{QStringLiteral("id"), id}, {QStringLiteral("title"), id}, {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + id},
                          {QStringLiteral("scripts"), QJsonArray()},
                          {QStringLiteral("repositoryIdentity"), QJsonObject{{QStringLiteral("canonicalKey"), c[0]}}}};
    world.mc.projects.insert(id, row);
    world.mc.sendRow(id, row, QStringLiteral("project"));
    world.sync();
  });
  step(QStringLiteral("the thread %1 has no linked pull request").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAt(world, c[0]);
    expect(model(world).count() == 0, describe(world));
  });
  step(QStringLiteral("pull request (\\d+) is linked to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAt(world, c[1]);
    QJsonObject row = world.mc.threads.value(kThread);
    row.insert(QStringLiteral("pullRequests"),
               QJsonArray{QJsonObject{{QStringLiteral("host"), QStringLiteral("github.com")}, {QStringLiteral("repository"), QStringLiteral("acme/shop")},
                                      {QStringLiteral("number"), c[0].toInt()},
                                      {QStringLiteral("url"), QStringLiteral("https://github.com/acme/shop/pull/") + c[0]},
                                      {QStringLiteral("source"), QStringLiteral("manual")}, {QStringLiteral("linkedAt"), QStringLiteral("2026-09-23T09:05:00Z")},
                                      {QStringLiteral("snapshot"), QJsonValue()}, {QStringLiteral("stack"), QJsonValue()}}});
    world.mc.threads.insert(kThread, row);
    syncLinks(world.mc, kThread);
    world.sync();
    waitForRow(world, c[0].toInt(), true);
  });

  step(QStringLiteral("the user links pull request (\\d+) to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAt(world, c[1]);
    link(world, c[0]);
  });
  step(QStringLiteral("the user links %1 pull request (\\d+) and %1 pull request (\\d+) to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAt(world, c[4]);
    // The thread's own repository by number, another by its URL.
    for (int at : {0, 2}) {
      link(world, c[at] == QLatin1String("acme/shop") ? QStringLiteral("#") + c[at + 1]
                                                      : QStringLiteral("https://github.com/%1/pull/%2").arg(c[at], c[at + 1]));
      expect(model(world).problem().isEmpty(), describe(world));
    }
  });
  step(QStringLiteral("the user links %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAt(world, QStringLiteral("Tax work"));
    link(world, c[0]);
  });
  step(QStringLiteral("the user unlinks pull request (\\d+)"), [](World& world, const Captures& c, const Table&) {
    model(world).unlink(keyOf(world, c[0].toInt()));
    world.sync();
  });
  step(QStringLiteral("the MC refuses to link pull requests to %1").arg(q), [](World& world, const Captures&, const Table&) {
    world.mc.refusals.insert(QStringLiteral("thread.pull-request.link"), QStringLiteral("Thread is archived"));
  });
  step(QStringLiteral("the user opens pull request (\\d+) from %1").arg(q), [](World& world, const Captures& c, const Table&) {
    model(world).open(keyOf(world, c[0].toInt()));
  });
  step(QStringLiteral("the user refreshes the pull requests of %1").arg(q), [](World& world, const Captures&, const Table&) {
    model(world).refresh();
    expect(model(world).refreshing(), QStringLiteral("the tab is not refreshing"));
    world.sync();
  });
  step(QStringLiteral("a review is submitted on pull request (\\d+) on GitHub"), [](World& world, const Captures& c, const Table&) {
    world.mc.part<FakePullRequests>().host[QStringLiteral("acme/shop#") + c[0]].insert(QStringLiteral("reviewDecision"), QStringLiteral("approved"));
  });
  step(QStringLiteral("the environment of %1 becomes unreachable").arg(q), [](World& world, const Captures&, const Table&) { setOnline(world, false); });
  step(QStringLiteral("the environment of %1 is reachable again").arg(q), [](World& world, const Captures&, const Table&) { setOnline(world, true); });

  // Outcomes.
  step(QStringLiteral("%1 lists pull request (\\d+) with its current state").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForRow(world, c[1].toInt(), true);
    const int row = rowOf(world, c[1].toInt());
    ThreadPullRequests& prs = model(world);
    expect(prs.value(row, ThreadPullRequests::TitleRole) == QLatin1String("Tax line fix") &&
               prs.value(row, ThreadPullRequests::StateLabelRole) == QLatin1String("Open") &&
               prs.value(row, ThreadPullRequests::ChecksLabelRole) == QLatin1String("Checks passing") &&
               prs.value(row, ThreadPullRequests::ReviewLabelRole) == QLatin1String("Review required") &&
               prs.value(row, ThreadPullRequests::SourceLabelRole) == QLatin1String("Linked by you") && !prs.linkOpen(),
           describe(world));
    const QJsonObject command = world.mc.commands.last();
    expect(command.value(QLatin1String("type")) == QLatin1String("thread.pull-request.link") &&
               command.value(QLatin1String("repository")) == QLatin1String("acme/shop") &&
               command.value(QLatin1String("url")) == QStringLiteral("https://github.com/acme/shop/pull/") + c[1],
           show(command.toVariantMap()));
  });
  step(QStringLiteral("%1 lists pull request (\\d+) of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForRow(world, c[1].toInt(), true);
    expect(keyOf(world, c[1].toInt()).endsWith(QStringLiteral("/%1#%2").arg(c[2], c[1])) && model(world).problem().isEmpty(), describe(world));
  });
  step(QStringLiteral("%1 no longer lists pull request (\\d+)").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForRow(world, c[1].toInt(), false);
  });
  step(QStringLiteral("%1 lists no pull requests").arg(q), [](World& world, const Captures&, const Table&) {
    expect(model(world).count() == 0, describe(world));
    expect(at(world.state(QStringLiteral("panel")), QStringLiteral("canAdd.pullRequests")) == false, show(world.state(QStringLiteral("panel"))));
  });
  step(QStringLiteral("%1 lists both pull requests").arg(q), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return model(world).count() == 2; }, [&] { return describe(world); });
    expect(keyOf(world, 42) == QLatin1String("github.com/acme/shop#42") && keyOf(world, 7) == QLatin1String("github.com/acme/api#7"),
           describe(world));
  });
  step(QStringLiteral("%1 shows the new review state after the next sync").arg(q), [](World& world, const Captures&, const Table&) {
    syncLinks(world.mc, kThread);
    world.sync();
    world.waitFor([&] { return model(world).value(rowOf(world, 42), ThreadPullRequests::ReviewLabelRole) == QLatin1String("Approved"); },
                  [&] { return describe(world); });
  });
  step(QStringLiteral("%1 shows the new review state").arg(q), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return model(world).value(rowOf(world, 42), ThreadPullRequests::ReviewLabelRole) == QLatin1String("Approved"); },
                  [&] { return describe(world); });
    expect(!model(world).refreshing(), QStringLiteral("the tab is still refreshing"));
  });
  step(QStringLiteral("pull request (\\d+) is read from GitHub again"), [](World& world, const Captures& c, const Table&) {
    const QList<QJsonObject>& asked = world.mc.part<FakePullRequests>().invalidated;
    expect(asked.size() == 1 && asked.first() == QJsonObject{{QStringLiteral("host"), QStringLiteral("github.com")},
                                                             {QStringLiteral("repository"), QStringLiteral("acme/shop")},
                                                             {QStringLiteral("number"), c[0].toInt()}},
           QStringLiteral("the MC was asked to read %1 pull requests").arg(asked.size()));
  });
  step(QStringLiteral("the user is told no project in this environment can read %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(model(world).problem() == QStringLiteral("No project in this environment can read %1.").arg(c[0]), describe(world));
    for (const QJsonObject& command : std::as_const(world.mc.commands)) {
      expect(command.value(QLatin1String("type")) != QLatin1String("thread.pull-request.link"), QStringLiteral("the link was sent"));
    }
  });
  step(QStringLiteral("the user is told pull request (\\d+) could not be linked"), [](World& world, const Captures&, const Table&) {
    expect(model(world).problem() == QLatin1String("Could not link the pull request: Thread is archived") && model(world).linkOpen() &&
               !model(world).linking(),
           describe(world));
  });
  step(QStringLiteral("%1 still lists pull request (\\d+)").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(rowOf(world, c[1].toInt()) >= 0 && !model(world).online(), describe(world));
  });
  step(QStringLiteral("the user cannot link, unlink or refresh pull requests"), [](World& world, const Captures&, const Table&) {
    const qsizetype sent = world.mc.commands.size();
    model(world).refresh();
    model(world).unlink(keyOf(world, 42));
    model(world).link(QStringLiteral("#7"));
    world.sync();
    expect(world.mc.commands.size() == sent && world.mc.part<FakePullRequests>().invalidated.isEmpty() && !model(world).refreshing() &&
               !model(world).linking(),
           QStringLiteral("something was sent while offline; %1").arg(describe(world)));
  });
  step(QStringLiteral("the user can link, unlink and refresh pull requests"), [](World& world, const Captures&, const Table&) {
    model(world).refresh();
    world.sync();
    expect(world.mc.part<FakePullRequests>().invalidated.size() == 1, QStringLiteral("the refresh was not sent"));
    model(world).unlink(keyOf(world, 42));
    world.sync();
    waitForRow(world, 42, false);
    link(world, QStringLiteral("42"));
    waitForRow(world, 42, true);
  });
});


// The Pull request review tab (PullRequestReview): what GitHub holds of pull
// request 42 as the MC reads it (apps/server-ex pull_requests.ex detail,
// activity, files_viewed, comment, submit_review, set_thread_resolution) and
// its code over HTTP in two slices (router.ex POST /api/pull-requests/diff).
// features/source-control/pull-request-review.feature.
struct FakeReview {
  QString author;
  QJsonArray comments;
  QJsonArray threads;
  QSet<QString> viewed;
  bool refuseViewed = false;
  // Every change asked of the host, by method.
  QStringList sent;
  int slices = 0;
  // What the host says of the pull request, and whether the viewer may merge it.
  QString state = QStringLiteral("open");
  bool writeAccess = false;
  // Every `pullRequests.runAction` input.
  QList<QJsonObject> actions;
};

const QString kCartPatch = QStringLiteral(
    "diff --git a/src/cart.ts b/src/cart.ts\n--- a/src/cart.ts\n+++ b/src/cart.ts\n@@ -1,2 +1,2 @@\n const total = 0;\n-const tax = 1;\n+const tax = 2;\n");
const QString kTaxPatch = QStringLiteral(
    "diff --git a/src/tax.ts b/src/tax.ts\n--- a/src/tax.ts\n+++ b/src/tax.ts\n@@ -1 +1,2 @@\n export const rate = 0.2;\n+export const reduced = 0.1;\n");

QJsonObject actor(const QString& login) {
  return {{QStringLiteral("login"), login}, {QStringLiteral("name"), QJsonValue()}, {QStringLiteral("avatarUrl"), QJsonValue()}};
}

// Answers the review's reads and changes the way the MC does.
void serveReview(FakeMc& mc) {
  mc.onRpc(QStringLiteral("pullRequests.detail"), [&mc](const FakeMc::Rpc& rpc) {
    const FakeReview& fake = mc.part<FakeReview>();
    mc.reply(rpc, QJsonObject{
                        {QStringLiteral("repository"), QStringLiteral("acme/shop")},
                        {QStringLiteral("number"), rpc.payload.value(QLatin1String("number"))},
                        {QStringLiteral("title"), QStringLiteral("Tax line fix")},
                        {QStringLiteral("body"), QStringLiteral("Rounds the tax line.")},
                        {QStringLiteral("url"), QStringLiteral("https://github.com/acme/shop/pull/42")},
                        {QStringLiteral("author"), actor(fake.author)},
                        {QStringLiteral("state"), fake.state},
                        {QStringLiteral("isDraft"), false},
                        // GitHub merges three ways; the repository allows them all.
                        {QStringLiteral("capabilities"), QJsonObject{{QStringLiteral("actions"), QJsonArray{QStringLiteral("merge"), QStringLiteral("close")}},
                                                                     {QStringLiteral("mergeMethods"), QJsonArray{QStringLiteral("merge"), QStringLiteral("squash"), QStringLiteral("rebase")}}}},
                        {QStringLiteral("mergeCapabilities"), QJsonObject{{QStringLiteral("merge"), true}, {QStringLiteral("squash"), true}, {QStringLiteral("rebase"), true}}},
                        {QStringLiteral("viewerPermissions"), QJsonObject{{QStringLiteral("actions"), fake.writeAccess ? QJsonArray{QStringLiteral("merge"), QStringLiteral("close")} : QJsonArray()}}},
                        {QStringLiteral("mergeability"), QStringLiteral("mergeable")},
                        {QStringLiteral("headBranch"), QStringLiteral("feature/tax")},
                        {QStringLiteral("baseBranch"), QStringLiteral("main")},
                        {QStringLiteral("behindBy"), 2},
                        {QStringLiteral("reviewers"), QJsonArray{actor(QStringLiteral("ada"))}},
                        {QStringLiteral("labels"), QJsonArray{QJsonObject{{QStringLiteral("name"), QStringLiteral("tax")}}}},
                        {QStringLiteral("checks"),
                         QJsonArray{QJsonObject{{QStringLiteral("name"), QStringLiteral("test")}, {QStringLiteral("status"), QStringLiteral("success")},
                                                {QStringLiteral("description"), QJsonValue()}, {QStringLiteral("url"), QJsonValue()}}}},
                    });
  });
  mc.onRpc(QStringLiteral("pullRequests.activity"), [&mc](const FakeMc::Rpc& rpc) {
    const FakeReview& fake = mc.part<FakeReview>();
    mc.reply(rpc, QJsonObject{{QStringLiteral("comments"), fake.comments},
                                {QStringLiteral("commentCount"), fake.comments.size()},
                                {QStringLiteral("commentsTruncated"), false},
                                {QStringLiteral("reviewThreads"), fake.threads},
                                {QStringLiteral("commits"), QJsonArray()}});
  });
  mc.onRpc(QStringLiteral("pullRequests.filesViewed"), [&mc](const FakeMc::Rpc& rpc) {
    QJsonArray files;
    for (const QString& path : std::as_const(mc.part<FakeReview>().viewed)) {
      files.append(QJsonObject{{QStringLiteral("path"), path}, {QStringLiteral("state"), QStringLiteral("viewed")}});
    }
    mc.reply(rpc, QJsonObject{{QStringLiteral("files"), files}, {QStringLiteral("truncated"), false}});
  });
  mc.onRpc(QStringLiteral("pullRequests.setFilesViewed"), [&mc](const FakeMc::Rpc& rpc) {
    FakeReview& fake = mc.part<FakeReview>();
    fake.sent.append(rpc.method);
    if (fake.refuseViewed) {
      mc.refuse(rpc, QStringLiteral("GitHub did not accept the viewed mark."));
      return;
    }
    for (const QJsonValue& value : rpc.payload.value(QLatin1String("files")).toArray()) {
      const QString path = value.toObject().value(QLatin1String("path")).toString();
      if (value.toObject().value(QLatin1String("viewed")).toBool()) {
        fake.viewed.insert(path);
      } else {
        fake.viewed.remove(path);
      }
    }
    mc.reply(rpc, QJsonValue::Null);
  });
  mc.onRpc(QStringLiteral("pullRequests.comment"), [&mc](const FakeMc::Rpc& rpc) {
    FakeReview& fake = mc.part<FakeReview>();
    fake.sent.append(rpc.method);
    fake.comments.append(QJsonObject{{QStringLiteral("id"), QStringLiteral("c%1").arg(fake.comments.size() + 1)},
                                     {QStringLiteral("kind"), QStringLiteral("comment")},
                                     {QStringLiteral("author"), actor(QStringLiteral("me"))},
                                     {QStringLiteral("body"), rpc.payload.value(QLatin1String("body"))},
                                     {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T10:00:00Z")},
                                     {QStringLiteral("reviewState"), QJsonValue()}});
    mc.reply(rpc, QJsonValue::Null);
  });
  mc.onRpc(QStringLiteral("pullRequests.submitReview"), [&mc](const FakeMc::Rpc& rpc) {
    FakeReview& fake = mc.part<FakeReview>();
    fake.sent.append(rpc.method);
    const QString verdict = rpc.payload.value(QLatin1String("verdict")).toString();
    fake.comments.append(QJsonObject{{QStringLiteral("id"), QStringLiteral("r%1").arg(fake.comments.size() + 1)},
                                     {QStringLiteral("kind"), QStringLiteral("review")},
                                     {QStringLiteral("author"), actor(QStringLiteral("me"))},
                                     {QStringLiteral("body"), rpc.payload.value(QLatin1String("body"))},
                                     {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T10:01:00Z")},
                                     {QStringLiteral("reviewState"), verdict == QLatin1String("approve") ? QStringLiteral("APPROVED")
                                                                     : verdict == QLatin1String("request-changes") ? QStringLiteral("CHANGES_REQUESTED")
                                                                                                                   : QStringLiteral("COMMENTED")}});
    mc.reply(rpc, QJsonValue::Null);
  });
  mc.onRpc(QStringLiteral("pullRequests.runAction"), [&mc](const FakeMc::Rpc& rpc) {
    FakeReview& fake = mc.part<FakeReview>();
    fake.sent.append(rpc.method);
    fake.actions.append(rpc.payload);
    if (!fake.writeAccess) {
      mc.refuse(rpc, QStringLiteral("You do not have permission to merge this pull request."));
      return;
    }
    if (rpc.payload.value(QLatin1String("action")) == QLatin1String("merge")) fake.state = QStringLiteral("merged");
    mc.reply(rpc, QJsonValue::Null);
  });
  mc.onRpc(QStringLiteral("pullRequests.setThreadResolution"), [&mc](const FakeMc::Rpc& rpc) {
    FakeReview& fake = mc.part<FakeReview>();
    fake.sent.append(rpc.method);
    QJsonArray threads;
    for (const QJsonValue& value : std::as_const(fake.threads)) {
      QJsonObject thread = value.toObject();
      if (thread.value(QLatin1String("id")) == rpc.payload.value(QLatin1String("threadId"))) {
        thread.insert(QStringLiteral("isResolved"), rpc.payload.value(QLatin1String("resolved")));
      }
      threads.append(thread);
    }
    fake.threads = threads;
    mc.reply(rpc, QJsonValue::Null);
  });
  mc.onHttp(QStringLiteral("/api/pull-requests/diff"), [&mc](const QJsonObject& body, const auto& respond) {
    FakeReview& fake = mc.part<FakeReview>();
    ++fake.slices;
    const bool first = !body.contains(QLatin1String("cursor"));
    respond(200, QJsonObject{{QStringLiteral("patch"), first ? kCartPatch : kTaxPatch},
                             {QStringLiteral("truncated"), false},
                             {QStringLiteral("nextCursor"), first ? QJsonValue(QStringLiteral("2")) : QJsonValue()}});
  });
}

PullRequestReview& review(World& world) {
  return *world.native().controller<RightPanelController>()->review();
}

QString describeReview(World& world) {
  PullRequestReview& pr = review(world);
  DiffModel& code = *pr.model();
  QStringList files;
  for (int file = 0; file < code.fileCount(); ++file) {
    files.append(code.path(file) + (code.expanded(file) ? QString() : QStringLiteral(" (collapsed)")));
  }
  return QStringLiteral("the review of %1 is %2 \"%3\" (%4), \"%5\", %6 remarks, %7 threads, code %8 [%9], %10 viewed, problem \"%11\"")
      .arg(pr.key(), pr.status(), pr.message(), pr.online() ? QStringLiteral("online") : QStringLiteral("offline"),
           pr.detail().value(QStringLiteral("title")).toString())
      .arg(pr.conversation().size())
      .arg(pr.reviewThreads().size())
      .arg(pr.codeStatus(), files.join(QStringLiteral(", ")))
      .arg(pr.viewedCount())
      .arg(pr.problem());
}

bool expanded(World& world, const QString& path) {
  DiffModel& code = *review(world).model();
  return code.expanded(code.fileOf(path));
}

void openReview(World& world, int number) {
  world.bridge().dispatch(QStringLiteral("rightPanel.review"), QVariantMap{{QStringLiteral("key"), keyOf(world, number)}});
  world.sync();
  expect(at(world.state(QStringLiteral("panel")), QStringLiteral("activeId")) == QStringLiteral("pull-request:") + keyOf(world, number),
         show(world.state(QStringLiteral("panel"))));
  world.waitFor([&] { return review(world).status() == QLatin1String("ready") && review(world).codeStatus() == QLatin1String("ready"); },
                [&] { return describeReview(world); });
}

QVariantMap reviewThread(World& world) {
  const QVariantList threads = review(world).reviewThreads();
  if (threads.isEmpty()) fail(describeReview(world));
  return threads.first().toMap();
}

const Steps reviewSteps([] {
  const QString q = kQuoted;

  step(QStringLiteral("the open pull request (\\d+)(?: by %1)?").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.part<FakeReview>().author = c.value(1).isEmpty() ? QStringLiteral("octocat") : c.value(1);
    world.mc.part<FakeReview>().comments = QJsonArray{
        QJsonObject{{QStringLiteral("id"), QStringLiteral("c1")}, {QStringLiteral("kind"), QStringLiteral("comment")},
                    {QStringLiteral("author"), actor(QStringLiteral("ada"))}, {QStringLiteral("body"), QStringLiteral("Why round up?")},
                    {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:30:00Z")}, {QStringLiteral("reviewState"), QJsonValue()}}};
    serveReview(world.mc);
    lookAt(world, QStringLiteral("Tax work"));
    QJsonObject row = world.mc.threads.value(kThread);
    row.insert(QStringLiteral("pullRequests"),
               QJsonArray{QJsonObject{{QStringLiteral("host"), QStringLiteral("github.com")}, {QStringLiteral("repository"), QStringLiteral("acme/shop")},
                                      {QStringLiteral("number"), c[0].toInt()},
                                      {QStringLiteral("url"), QStringLiteral("https://github.com/acme/shop/pull/") + c[0]},
                                      {QStringLiteral("source"), QStringLiteral("manual")}, {QStringLiteral("linkedAt"), QStringLiteral("2026-09-23T09:05:00Z")},
                                      {QStringLiteral("snapshot"), QJsonValue()}, {QStringLiteral("stack"), QJsonValue()}}});
    world.mc.threads.insert(kThread, row);
    syncLinks(world.mc, kThread);
    world.sync();
    waitForRow(world, c[0].toInt(), true);
  });
  // A pull request a message mentions, linked from that message.
  step(QStringLiteral("a message in %1 mentions %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAt(world, c[0]);
    startRun(world, 30);
    addItem(world, QStringLiteral("assistant_message"), {{QStringLiteral("text"), QStringLiteral("I opened %1 for the tax line.").arg(c[1])}});
    settleRun(world, QStringLiteral("completed"), 30);
    waitForRow(world, 42, false);
  });
  step(QStringLiteral("the user links that pull request from the mention"), [](World& world, const Captures&, const Table&) {
    world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nThreadView {}\n", QSize(820, 700));
    Brick& brick = *world.brick;
    QQuickItem* button = nullptr;
    const std::function<void(QQuickItem*)> find = [&](QQuickItem* item) {
      if (item->objectName() == QLatin1String("linkPullRequest") && item->isVisible()) button = item;
      for (QQuickItem* child : item->childItems()) find(child);
    };
    world.waitFor([&] {
      find(brick.window().contentItem());
      return button != nullptr;
    }, QStringLiteral("the message to offer linking its pull request"));
    QTest::mouseClick(&brick.window(), Qt::LeftButton, Qt::NoModifier, brick.at(button));
    world.sync();
  });
  step(QStringLiteral("%1 lists pull request (\\d+)").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForRow(world, c[1].toInt(), true);
    const int row = rowOf(world, c[1].toInt());
    expect(model(world).value(row, ThreadPullRequests::TitleRole) == QLatin1String("Tax line fix"), describe(world));
  });

  // A stack of pull requests on the host (stacked-pull-requests.feature).
  step(QStringLiteral("the stack onto %1 of pull requests (\\d+), (\\d+) and (\\d+), bottom to top").arg(q), [](World& world, const Captures& c, const Table&) {
    FakePullRequests& fake = world.mc.part<FakePullRequests>();
    fake.stackBase = c[0];
    fake.stack = {c[1].toInt(), c[2].toInt(), c[3].toInt()};
  });
  step(QStringLiteral("the user looks at %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAt(world, c[0]);
    expect(world.mc.threads.value(kThread).value(QLatin1String("title")) == c[0], QStringLiteral("the thread shown is not %1").arg(c[0]));
  });
  step(QStringLiteral("its pull request shows it is layer (\\d+) of (\\d+)"), [](World& world, const Captures& c, const Table&) {
    const QString wanted = QStringLiteral("Layer %1 of %2").arg(c[0], c[1]);
    world.waitFor([&] { return model(world).rowCount() == 1 && model(world).value(0, ThreadPullRequests::StackLabelRole) == wanted; },
                  [&] { return QStringLiteral("%1; the stack reads \"%2\"").arg(describe(world), model(world).rowCount() > 0 ? model(world).value(0, ThreadPullRequests::StackLabelRole).toString() : QString()); });
    world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Shell\nimport HalC2.Bricks\nPullRequestsPanel { source: Panel.pullRequests }\n", QSize(420, 500));
    world.waitFor([&] { return world.brick->shows(QStringLiteral("acme/shop #42 · feature/tax → main · ") + wanted); }, QStringLiteral("the tab to draw the layer"));
  });

  // The branch's own pull request, from the composer's chip.
  step(QStringLiteral("pull request (\\d+) is the branch's pull request of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString url = QStringLiteral("https://github.com/acme/shop/pull/") + c[0];
    world.mc.checkouts.insert(QStringLiteral("/work/") + kProject, [number = c[0].toInt(), url] {
      return QJsonObject{{QStringLiteral("local"), QJsonObject{{QStringLiteral("isRepo"), true}, {QStringLiteral("refName"), QStringLiteral("feature/tax")}}},
                         {QStringLiteral("remote"), QJsonObject{{QStringLiteral("hasUpstream"), true},
                                                                {QStringLiteral("pr"), QJsonObject{{QStringLiteral("number"), number}, {QStringLiteral("title"), QStringLiteral("Tax line fix")},
                                                                                                   {QStringLiteral("url"), url}, {QStringLiteral("state"), QStringLiteral("open")}}}}}};
    });
    lookAt(world, c[1]);
    // The checkout is already followed (the landing draft's): the MC says what it found.
    const QJsonObject status = world.mc.checkouts.value(QStringLiteral("/work/") + kProject)();
    for (const int id : world.mc.subscribers(QStringLiteral("vcs"))) {
      if (world.mc.shapeOf(id).value(QLatin1String("cwd")) != QStringLiteral("/work/") + kProject) continue;
      world.mc.send({{QStringLiteral("t"), QStringLiteral("vcs")}, {QStringLiteral("id"), id},
                     {QStringLiteral("event"), QJsonObject{{QStringLiteral("_tag"), QStringLiteral("localUpdated")}, {QStringLiteral("local"), status.value(QLatin1String("local"))}}}});
      world.mc.send({{QStringLiteral("t"), QStringLiteral("vcs")}, {QStringLiteral("id"), id},
                     {QStringLiteral("event"), QJsonObject{{QStringLiteral("_tag"), QStringLiteral("remoteUpdated")}, {QStringLiteral("remote"), status.value(QLatin1String("remote"))}}}});
    }
    world.sync();
    world.waitFor([&] { return at(world.state(QStringLiteral("workspace")), QStringLiteral("git.pullRequest.number")).toInt() == c[0].toInt(); },
                  [&] { return QStringLiteral("the composer to name the pull request; the workspace is %1").arg(show(world.state(QStringLiteral("workspace")))); });
  });
  step(QStringLiteral("the user opens the pull request from the thread"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("workspace.openPullRequest"));
    world.sync();
  });
  step(QStringLiteral("pull request (\\d+) opens"), [](World& world, const Captures& c, const Table&) {
    expect(world.openedUrls == QList<QUrl>{QUrl(QStringLiteral("https://github.com/acme/shop/pull/") + c[0])},
           QStringLiteral("the browser opened %1").arg(world.openedUrls.size()));
  });

  // Merging (pull-request-actions.feature), from the review's Overview.
  step(QStringLiteral("the user has write access to %1").arg(q), [](World& world, const Captures&, const Table&) {
    world.mc.part<FakeReview>().writeAccess = true;
  });
  step(QStringLiteral("the user merges pull request (\\d+) from its review with the default merge method"), [](World& world, const Captures& c, const Table&) {
    openReview(world, c[0].toInt());
    expect(review(world).detail().value(QStringLiteral("canMerge")).toBool(), QStringLiteral("merging is not offered: %1").arg(show(review(world).detail())));
    world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Shell\nimport HalC2.Bricks\nPullRequestReviewPanel { source: Panel.review }\n", QSize(700, 800));
    world.waitFor([&] { return world.brick->item(QStringLiteral("reviewMerge"))->isVisible(); }, QStringLiteral("the review to offer Merge"));
    world.brick->click(QStringLiteral("reviewMerge"));
    world.sync();
  });
  step(QStringLiteral("the review shows pull request (\\d+) as merged"), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return review(world).detail().value(QStringLiteral("stateLabel")) == QLatin1String("Merged") && !review(world).busy(); },
                  [&] { return QStringLiteral("%1; the host was asked %2 actions; the detail is %3").arg(describeReview(world)).arg(world.mc.part<FakeReview>().actions.size()).arg(show(review(world).detail())); });
    const QList<QJsonObject> actions = world.mc.part<FakeReview>().actions;
    // The default method: the first the repository allows.
    expect(actions.size() == 1 && actions.first().value(QLatin1String("action")) == QLatin1String("merge") &&
               actions.first().value(QLatin1String("mergeMethod")) == QLatin1String("merge") && actions.first().value(QLatin1String("number")).toInt() == c[0].toInt(),
           QStringLiteral("the host was asked %1").arg(actions.isEmpty() ? QStringLiteral("nothing") : show(actions.first().toVariantMap())));
    // A merged pull request offers no merge.
    expect(!review(world).detail().value(QStringLiteral("canMerge")).toBool(), describeReview(world));
    world.waitFor([&] { return !world.brick->item(QStringLiteral("reviewMerge"))->isVisible(); }, QStringLiteral("Merge to go away"));
  });
  step(QStringLiteral("%1 is marked viewed in pull request (\\d+)").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.part<FakeReview>().viewed.insert(c[0]);
  });
  step(QStringLiteral("GitHub refuses viewed marks on pull request (\\d+)"), [](World& world, const Captures&, const Table&) {
    world.mc.part<FakeReview>().refuseViewed = true;
  });
  step(QStringLiteral("an unresolved review thread on pull request (\\d+)"), [](World& world, const Captures&, const Table&) {
    world.mc.part<FakeReview>().threads = QJsonArray{QJsonObject{
        {QStringLiteral("id"), QStringLiteral("th1")}, {QStringLiteral("path"), QStringLiteral("src/cart.ts")}, {QStringLiteral("line"), 2},
        {QStringLiteral("isResolved"), false}, {QStringLiteral("isOutdated"), false},
        {QStringLiteral("comments"), QJsonArray{QJsonObject{{QStringLiteral("author"), actor(QStringLiteral("ada"))},
                                                            {QStringLiteral("body"), QStringLiteral("Round down here.")}}}}}};
  });
  step(QStringLiteral("the user opens pull request (\\d+)"), [](World& world, const Captures& c, const Table&) { openReview(world, c[0].toInt()); });
  step(QStringLiteral("the user opened pull request (\\d+)"), [](World& world, const Captures& c, const Table&) { openReview(world, c[0].toInt()); });
  step(QStringLiteral("the user marks %1 (viewed|not viewed) on the review page").arg(q), [](World& world, const Captures& c, const Table&) {
    review(world).setViewed(c[0], c[1] == QLatin1String("viewed"));
    world.sync();
  });
  step(QStringLiteral("the user comments %1 on the review page").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(review(world).comment(c[0]), describeReview(world));
    world.sync();
  });
  step(QStringLiteral("the user comments with only spaces on the review page"), [](World& world, const Captures&, const Table&) {
    expect(!review(world).comment(QStringLiteral("   ")), describeReview(world));
  });
  step(QStringLiteral("the user approves pull request (\\d+) on the review page"), [](World& world, const Captures&, const Table&) {
    expect(review(world).submitReview(QStringLiteral("approve"), {}), describeReview(world));
    world.sync();
  });
  step(QStringLiteral("the user requests changes on the review page with no summary"), [](World& world, const Captures&, const Table&) {
    expect(!review(world).submitReview(QStringLiteral("request-changes"), QStringLiteral(" ")), describeReview(world));
  });
  step(QStringLiteral("the user (resolves|unresolves) the thread on the review page"), [](World& world, const Captures& c, const Table&) {
    review(world).setThreadResolved(reviewThread(world).value(QStringLiteral("id")).toString(), c[0] == QLatin1String("resolves"));
    world.sync();
  });
  step(QStringLiteral("the user copies the pull request number"), [](World& world, const Captures&, const Table&) {
    expect(world.native().controller<KeybindingController>()->commands()->run(QStringLiteral("pullRequest.copyNumber")),
           show(world.state(QStringLiteral("panel"))));
  });

  // Outcomes.
  step(QStringLiteral("the description, conversation, checks and code are shown on its review page"), [](World& world, const Captures&, const Table&) {
    PullRequestReview& pr = review(world);
    const QVariantMap detail = pr.detail();
    world.waitFor([&] { return pr.conversation().size() == 1; }, [&] { return describeReview(world); });
    const QVariantList checks = detail.value(QStringLiteral("checks")).toList();
    expect(detail.value(QStringLiteral("title")) == QLatin1String("Tax line fix") &&
               detail.value(QStringLiteral("body")) == QLatin1String("Rounds the tax line.") &&
               detail.value(QStringLiteral("author")) == QLatin1String("octocat") &&
               detail.value(QStringLiteral("branches")) == QStringLiteral("feature/tax → main") &&
               detail.value(QStringLiteral("stateLabel")) == QLatin1String("Open") && detail.value(QStringLiteral("behindBy")) == 2 &&
               checks.size() == 1 && checks.first().toMap().value(QStringLiteral("status")) == QLatin1String("success"),
           show(detail));
    expect(pr.model()->paths() == QStringList{QStringLiteral("src/cart.ts"), QStringLiteral("src/tax.ts")} &&
               world.mc.part<FakeReview>().slices == 2,
           describeReview(world));
    expect(at(world.state(QStringLiteral("panel")), QStringLiteral("tabs")).toList().last().toMap().value(QStringLiteral("title")) ==
               QLatin1String("PR #42"),
           show(world.state(QStringLiteral("panel"))));
  });
  step(QStringLiteral("a viewed file collapses and the viewed count goes up"), [](World& world, const Captures&, const Table&) {
    expect(expanded(world, QStringLiteral("src/cart.ts")) && review(world).viewedCount() == 0, describeReview(world));
    review(world).setViewed(QStringLiteral("src/cart.ts"), true);
    expect(!expanded(world, QStringLiteral("src/cart.ts")) && review(world).viewedCount() == 1, describeReview(world));
    world.sync();
    world.waitFor([&] { return world.mc.part<FakeReview>().viewed.contains(QStringLiteral("src/cart.ts")); }, [&] { return describeReview(world); });
  });
  step(QStringLiteral("%1 expands and the viewed count goes down").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(expanded(world, c[0]) && review(world).viewedCount() == 0, describeReview(world));
    world.waitFor([&] { return !world.mc.part<FakeReview>().viewed.contains(c[0]); }, [&] { return describeReview(world); });
  });
  step(QStringLiteral("%1 is not marked viewed on the review page").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return !review(world).isViewed(c[0]) && expanded(world, c[0]) && review(world).viewedCount() == 0; },
                  [&] { return describeReview(world); });
    expect(world.mc.part<FakeReview>().sent == QStringList{QStringLiteral("pullRequests.setFilesViewed")}, describeReview(world));
  });
  step(QStringLiteral("%1 appears in the review page's conversation").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor(
        [&] {
          const QVariantList conversation = review(world).conversation();
          return !conversation.isEmpty() && conversation.last().toMap().value(QStringLiteral("body")) == c[0];
        },
        [&] { return describeReview(world); });
    expect(!review(world).busy() && review(world).problem().isEmpty(), describeReview(world));
  });
  step(QStringLiteral("the review page says %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(review(world).problem() == c[0], describeReview(world));
  });
  step(QStringLiteral("nothing was sent to pull request (\\d+)"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(world.mc.part<FakeReview>().sent.isEmpty(), world.mc.part<FakeReview>().sent.join(QStringLiteral(", ")));
  });
  step(QStringLiteral("the review page shows the thread (resolved|open)"), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return reviewThread(world).value(QStringLiteral("resolved")).toBool() == (c[0] == QLatin1String("resolved")); },
                  [&] { return describeReview(world); });
  });
  step(QStringLiteral("the review page still shows pull request (\\d+) and sends nothing"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !review(world).online(); }, [&] { return describeReview(world); });
    PullRequestReview& pr = review(world);
    expect(pr.detail().value(QStringLiteral("title")) == QLatin1String("Tax line fix") && pr.model()->fileCount() == 2, describeReview(world));
    expect(!pr.comment(QStringLiteral("Looks good")) && pr.problem() == QLatin1String("The environment is offline."), describeReview(world));
    pr.setViewed(QStringLiteral("src/cart.ts"), true);
    world.sync();
    expect(world.mc.part<FakeReview>().sent.isEmpty() && pr.viewedCount() == 0, describeReview(world));
  });
  step(QStringLiteral("the user can comment on the review page again"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return review(world).online(); }, [&] { return describeReview(world); });
    expect(review(world).comment(QStringLiteral("Back again")), describeReview(world));
    world.sync();
    world.waitFor(
        [&] {
          const QVariantList conversation = review(world).conversation();
          return conversation.last().toMap().value(QStringLiteral("body")) == QLatin1String("Back again");
        },
        [&] { return describeReview(world); });
  });
});

}  // namespace
