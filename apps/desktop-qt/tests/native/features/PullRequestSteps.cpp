// The right panel's Pull requests tab (ThreadPullRequests): the pull requests
// linked to a thread, from its shell row, and linking, unlinking and
// refreshing them as the node does (apps/server-ex orchestration.ex
// thread.pull-request.link/unlink, pull_requests.ex invalidate).
// features/source-control/pull-request-threads.feature.

#include <QJsonArray>
#include <QJsonObject>

#include "Harness.h"
#include "RightPanelController.h"
#include "Stream.h"
#include "ThreadPullRequests.h"
#include "World.h"

namespace {

using namespace stream;

// What GitHub holds of each pull request ("acme/shop#42"), the thread the
// scenario is about, and the pull requests the node was asked to read again.
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
};

QString hostKey(const QJsonObject& reference) {
  return QStringLiteral("%1#%2").arg(reference.value(QLatin1String("repository")).toString()).arg(reference.value(QLatin1String("number")).toInt());
}

// The thread's links, each with what the host last said of it: the node's sync.
void syncLinks(FakeNode& node, const QString& threadId) {
  if (!node.threads.contains(threadId)) return;
  QJsonObject row = node.threads.value(threadId);
  QJsonArray links;
  for (const QJsonValue& value : row.value(QLatin1String("pullRequests")).toArray()) {
    QJsonObject link = value.toObject();
    const QJsonObject snapshot = node.part<FakePullRequests>().host.value(hostKey(link));
    link.insert(QStringLiteral("snapshot"), snapshot.isEmpty() ? QJsonValue() : QJsonValue(snapshot));
    links.append(link);
  }
  row.insert(QStringLiteral("pullRequests"), links);
  node.threads.insert(threadId, row);
  node.sendRow(threadId, row);
}

const FakeNode::Extension pullRequests([](FakeNode& node) {
  node.effects.append([&node](const QJsonObject& command) {
    const QString type = command.value(QLatin1String("type")).toString();
    if (type != QLatin1String("thread.pull-request.link") && type != QLatin1String("thread.pull-request.unlink")) return;
    const QString threadId = command.value(QLatin1String("threadId")).toString();
    QJsonObject row = node.threads.value(threadId);
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
    node.threads.insert(threadId, row);
    // The node reads a new link from its host at once (Sync.request).
    syncLinks(node, threadId);
  });
  node.onRpc(QStringLiteral("pullRequests.invalidate"), [&node](const FakeNode::Rpc& rpc) {
    node.part<FakePullRequests>().invalidated.append(rpc.payload.value(QLatin1String("reference")).toObject());
    syncLinks(node, node.part<FakePullRequests>().thread);
    node.reply(rpc, QJsonValue::Null);
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
  FakePullRequests& fake = world.node.part<FakePullRequests>();
  if (!fake.thread.isEmpty()) return;
  fake.thread = kThread;
  world.node.threads.insert(kThread, {{QStringLiteral("id"), kThread}, {QStringLiteral("title"), title}, {QStringLiteral("projectId"), kProject},
                                      {QStringLiteral("pullRequests"), QJsonArray()},
                                      {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")}, {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}});
  world.node.sendRow(kThread, world.node.threads.value(kThread));
  world.sync();
  FakeStreams& streams = world.node.part<FakeStreams>();
  streams.thread = kThread;
  streams.environment = world.node.environmentId;
  look(world, world.node.environmentId + QLatin1Char(':') + kThread);
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
  world.node.send({{QStringLiteral("t"), QStringLiteral("shell.node")}, {QStringLiteral("id"), world.node.subscribers(QStringLiteral("shell")).value(0)},
                   {QStringLiteral("node"), world.node.name}, {QStringLiteral("online"), online}});
  world.sync();
  world.waitFor([&] { return model(world).online() == online; }, [&] { return describe(world); });
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("a connected environment with the GitHub project %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.node.projects.insert(kProject, {{QStringLiteral("id"), kProject}, {QStringLiteral("title"), kProject},
                                          {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + kProject}, {QStringLiteral("scripts"), QJsonArray()},
                                          {QStringLiteral("repositoryIdentity"),
                                           QJsonObject{{QStringLiteral("canonicalKey"), QStringLiteral("github.com/") + c[0]}, {QStringLiteral("displayName"), c[0]}}}});
    world.connect();
    world.sync();
  });
  step(QStringLiteral("the thread %1 has no linked pull request").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAt(world, c[0]);
    expect(model(world).count() == 0, describe(world));
  });
  step(QStringLiteral("pull request (\\d+) is linked to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAt(world, c[1]);
    QJsonObject row = world.node.threads.value(kThread);
    row.insert(QStringLiteral("pullRequests"),
               QJsonArray{QJsonObject{{QStringLiteral("host"), QStringLiteral("github.com")}, {QStringLiteral("repository"), QStringLiteral("acme/shop")},
                                      {QStringLiteral("number"), c[0].toInt()},
                                      {QStringLiteral("url"), QStringLiteral("https://github.com/acme/shop/pull/") + c[0]},
                                      {QStringLiteral("source"), QStringLiteral("manual")}, {QStringLiteral("linkedAt"), QStringLiteral("2026-09-23T09:05:00Z")},
                                      {QStringLiteral("snapshot"), QJsonValue()}, {QStringLiteral("stack"), QJsonValue()}}});
    world.node.threads.insert(kThread, row);
    syncLinks(world.node, kThread);
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
  step(QStringLiteral("the node refuses to link pull requests to %1").arg(q), [](World& world, const Captures&, const Table&) {
    world.node.refusals.insert(QStringLiteral("thread.pull-request.link"), QStringLiteral("Thread is archived"));
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
    world.node.part<FakePullRequests>().host[QStringLiteral("acme/shop#") + c[0]].insert(QStringLiteral("reviewDecision"), QStringLiteral("approved"));
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
    const QJsonObject command = world.node.commands.last();
    expect(command.value(QLatin1String("type")) == QLatin1String("thread.pull-request.link") &&
               command.value(QLatin1String("repository")) == QLatin1String("acme/shop") &&
               command.value(QLatin1String("url")) == QStringLiteral("https://github.com/acme/shop/pull/") + c[1],
           show(command.toVariantMap()));
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
    syncLinks(world.node, kThread);
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
    const QList<QJsonObject>& asked = world.node.part<FakePullRequests>().invalidated;
    expect(asked.size() == 1 && asked.first() == QJsonObject{{QStringLiteral("host"), QStringLiteral("github.com")},
                                                             {QStringLiteral("repository"), QStringLiteral("acme/shop")},
                                                             {QStringLiteral("number"), c[0].toInt()}},
           QStringLiteral("the node was asked to read %1 pull requests").arg(asked.size()));
  });
  step(QStringLiteral("the user is told no project in this environment can read %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(model(world).problem() == QStringLiteral("No project in this environment can read %1.").arg(c[0]), describe(world));
    for (const QJsonObject& command : std::as_const(world.node.commands)) {
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
    const qsizetype sent = world.node.commands.size();
    model(world).refresh();
    model(world).unlink(keyOf(world, 42));
    model(world).link(QStringLiteral("#7"));
    world.sync();
    expect(world.node.commands.size() == sent && world.node.part<FakePullRequests>().invalidated.isEmpty() && !model(world).refreshing() &&
               !model(world).linking(),
           QStringLiteral("something was sent while offline; %1").arg(describe(world)));
  });
  step(QStringLiteral("the user can link, unlink and refresh pull requests"), [](World& world, const Captures&, const Table&) {
    model(world).refresh();
    world.sync();
    expect(world.node.part<FakePullRequests>().invalidated.size() == 1, QStringLiteral("the refresh was not sent"));
    model(world).unlink(keyOf(world, 42));
    world.sync();
    waitForRow(world, 42, false);
    link(world, QStringLiteral("42"));
    waitForRow(world, 42, true);
  });
});

}  // namespace
