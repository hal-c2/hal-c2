// The right panel's Pull requests tab (ThreadPullRequests): the pull requests
// linked to a thread, from its shell row, and linking, unlinking and
// refreshing them as the MC does (apps/server-ex orchestration.ex
// thread.pull-request.link/unlink, pull_requests.ex invalidate).
// features/source-control/pull-request-threads.feature.

#include <QJsonArray>
#include <QJsonObject>
#include <QRegularExpression>
#include <QSet>
#include <QUrl>

#include <QQuickItem>
#include <QTest>
#include <algorithm>
#include <memory>
#include <optional>

#include "Brick.h"
#include "Harness.h"
#include "NavigationController.h"
#include "KeybindingController.h"
#include "PullRequestReview.h"
#include "RightPanelController.h"
#include "Stream.h"
#include "ThreadPullRequests.h"
#include "World.h"
#include "PullRequestSteps.h"
#include "PullRequestThreadLinks.h"
#include "CommandPaletteController.h"

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
  // The pull request whose row's actions the user opened.
  int actionsOf = 0;
  // The pull requests GitHub will not show (or knows as issues), and the
  // link a message in the conversation mentions.
  QSet<int> unreadable;
  QString mentioned;
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
      QJsonObject link = value.toObject();
      const bool same = hostKey(link) == hostKey(command) && link.value(QLatin1String("host")) == command.value(QLatin1String("host"));
      known = known || same;
      const QString source = link.value(QLatin1String("source")).toString();
      // A stack layer, or one the thread created, is dismissed rather than
      // unlinked; linking a dismissed one again brings it back as the user's
      // (orchestration.ex thread.pull-request.unlink / link).
      if (same && type == QLatin1String("thread.pull-request.unlink") &&
          (source == QLatin1String("stack") || source == QLatin1String("created"))) {
        link.insert(QStringLiteral("source"), QStringLiteral("stack-dismissed"));
      } else if (same && type == QLatin1String("thread.pull-request.link") && source == QLatin1String("stack-dismissed")) {
        link.insert(QStringLiteral("source"), QStringLiteral("manual"));
      } else if (same && type == QLatin1String("thread.pull-request.unlink")) {
        continue;
      }
      links.append(link);
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
  // The threads of this MC that link the pull request, newest first (pull_requests.ex linked_threads).
  mc.onRpc(QStringLiteral("pullRequests.linkedThreads"), [&mc](const FakeMc::Rpc& rpc) {
    if (mc.part<FakePullRequests>().thread.isEmpty()) return mc.passOn(rpc);
    QList<QJsonObject> rows;
    for (const QJsonObject& row : std::as_const(mc.threads)) {
      for (const QJsonValue& value : row.value(QLatin1String("pullRequests")).toArray()) {
        const QJsonObject link = value.toObject();
        if (hostKey(link) == hostKey(rpc.payload) && link.value(QLatin1String("source")) != QLatin1String("stack-dismissed")) {
          rows.append(row);
          break;
        }
      }
    }
    std::sort(rows.begin(), rows.end(), [](const QJsonObject& a, const QJsonObject& b) {
      return a.value(QLatin1String("updatedAt")).toString() > b.value(QLatin1String("updatedAt")).toString();
    });
    QJsonArray threads;
    for (const QJsonObject& row : std::as_const(rows)) {
      threads.append(QJsonObject{{QStringLiteral("id"), row.value(QLatin1String("id"))}, {QStringLiteral("projectId"), row.value(QLatin1String("projectId"))},
                                 {QStringLiteral("title"), row.value(QLatin1String("title"))}, {QStringLiteral("archivedAt"), row.value(QLatin1String("archivedAt"))}});
    }
    mc.reply(rpc, QJsonObject{{QStringLiteral("threads"), threads}});
  });
  mc.onRpc(QStringLiteral("pullRequests.invalidate"), [&mc](const FakeMc::Rpc& rpc) {
    // The pull requests page's refresh names no reference (PullRequestListSteps).
    if (!rpc.payload.contains(QLatin1String("reference"))) return mc.passOn(rpc);
    mc.part<FakePullRequests>().invalidated.append(rpc.payload.value(QLatin1String("reference")).toObject());
    syncLinks(mc, mc.part<FakePullRequests>().thread);
    mc.reply(rpc, QJsonValue::Null);
  });
  // What a link's hover card shows (pull_requests.ex preview/1, through GitHub only).
  mc.onRpc(QStringLiteral("pullRequests.preview"), [&mc](const FakeMc::Rpc& rpc) {
    const FakePullRequests& fake = mc.part<FakePullRequests>();
    const int number = rpc.payload.value(QLatin1String("number")).toInt();
    const QJsonObject held = fake.host.value(hostKey(rpc.payload));
    if (rpc.payload.value(QLatin1String("host")) != QLatin1String("github.com") || held.isEmpty() || fake.unreadable.contains(number)) {
      return mc.refuse(rpc, QStringLiteral("Pull request not found."));
    }
    mc.reply(rpc, QJsonObject{{QStringLiteral("number"), number}, {QStringLiteral("title"), held.value(QLatin1String("title"))},
                              {QStringLiteral("url"), QStringLiteral("https://github.com/%1/pull/%2").arg(rpc.payload.value(QLatin1String("repository")).toString()).arg(number)},
                              {QStringLiteral("isDraft"), held.value(QLatin1String("isDraft"))}, {QStringLiteral("state"), held.value(QLatin1String("state"))},
                              {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T06:00:00Z")},
                              {QStringLiteral("author"), QJsonObject{{QStringLiteral("login"), QStringLiteral("ada")}, {QStringLiteral("name"), QStringLiteral("Ada Lovelace")}}},
                              {QStringLiteral("projectId"), rpc.payload.value(QLatin1String("projectId"))},
                              {QStringLiteral("repository"), rpc.payload.value(QLatin1String("repository"))}});
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
  // What the tab says in place: why a reference does not link, and what each stack is.
  world.toldInPlace = [&world] {
    ThreadPullRequests& prs = model(world);
    QStringList told{prs.problem()};
    for (int row = 0; row < prs.rowCount(); ++row) {
      if (prs.value(row, ThreadPullRequests::StackSizeRole).toInt() > 1) told.append(prs.value(row, ThreadPullRequests::StackNoteRole).toString());
    }
    return told;
  };
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

// The link the scenario's message mentions, as drawn in the thread's view:
// the Markdown text holding it and a point on it, in window coordinates.
struct LinkSpot {
  QQuickItem* text = nullptr;
  QPoint at;
};

LinkSpot mentionedLink(World& world) {
  if (!world.brick) world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nThreadView {}\n", QSize(820, 700));
  const QString wanted = world.mc.part<FakePullRequests>().mentioned;
  LinkSpot spot;
  const std::function<void(QQuickItem*)> find = [&](QQuickItem* item) {
    if (spot.text || !item->isVisible()) return;
    if (item->inherits("QQuickTextEdit")) {
      for (qreal y = 2; y < item->height() && !spot.text; y += 4) {
        for (qreal x = 2; x < item->width(); x += 4) {
          QString link;
          QMetaObject::invokeMethod(item, "linkAt", Q_RETURN_ARG(QString, link), Q_ARG(qreal, x), Q_ARG(qreal, y));
          if (link == wanted) {
            spot = {item, item->mapToScene(QPointF(x, y)).toPoint()};
            break;
          }
        }
      }
    }
    for (QQuickItem* child : item->childItems()) find(child);
  };
  world.waitFor([&] {
    find(world.brick->window().contentItem());
    return spot.text != nullptr;
  }, QStringLiteral("the message to show a link to %1").arg(wanted));
  return spot;
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
  // The stack cannot be read from the host now, and how often it was asked.
  bool stackFails = false;
  int stackReads = 0;
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
                        // A stack is its author's to merge and rebase.
                        {QStringLiteral("viewerPermissions"), QJsonObject{{QStringLiteral("actions"), fake.writeAccess || !mc.part<FakePullRequests>().stack.isEmpty()
                                                                                                           ? QJsonArray{QStringLiteral("merge"), QStringLiteral("close")}
                                                                                                           : QJsonArray()},
                                                                          {QStringLiteral("stackRebase"), true}}},
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
  // The host's stack, as `pullRequests.stack` reads it: every layer with the head it has now.
  mc.onRpc(QStringLiteral("pullRequests.stack"), [&mc](const FakeMc::Rpc& rpc) {
    const FakePullRequests& pulls = mc.part<FakePullRequests>();
    FakeReview& fake = mc.part<FakeReview>();
    ++fake.stackReads;
    if (fake.stackFails) {
      mc.refuse(rpc, QStringLiteral("GitHub could not be reached."));
      return;
    }
    if (!pulls.stack.contains(rpc.payload.value(QLatin1String("number")).toInt())) {
      mc.reply(rpc, QJsonValue::Null);
      return;
    }
    QJsonArray layers;
    for (const int number : pulls.stack) {
      layers.append(QJsonObject{{QStringLiteral("number"), number}, {QStringLiteral("title"), QStringLiteral("Layer %1").arg(number)}, {QStringLiteral("isDraft"), false},
                                {QStringLiteral("headSha"), QStringLiteral("sha-%1").arg(number)}, {QStringLiteral("headBranch"), QStringLiteral("stack/%1").arg(number)},
                                {QStringLiteral("state"), QStringLiteral("open")}});
    }
    mc.reply(rpc, QJsonObject{{QStringLiteral("id"), QStringLiteral("stack-1")}, {QStringLiteral("number"), 1},
                              {QStringLiteral("url"), QStringLiteral("https://github.com/acme/shop/stacks/1")}, {QStringLiteral("base"), pulls.stackBase}, {QStringLiteral("layers"), layers}});
  });
  mc.onRpc(QStringLiteral("pullRequests.runAction"), [&mc](const FakeMc::Rpc& rpc) {
    FakeReview& fake = mc.part<FakeReview>();
    fake.sent.append(rpc.method);
    fake.actions.append(rpc.payload);
    if (!fake.writeAccess && !rpc.payload.contains(QLatin1String("stackNumber"))) {
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

// The MC's answers to the pull request thread dialog: git.resolvePullRequest
// reads what is named without checking anything out,
// git.preparePullRequestThread checks it out when asked (or never answers).
struct FakePullRequestThread {
  // Numbers the host does not know, with what it says of them.
  QHash<QString, QString> missing;
  bool holdPrepare = false;
  std::optional<QString> prepareRefusal;
};

// The number at the end of what was named: "7", ".../pull/7", ".../pullrequest/7".
QJsonObject resolvedPullRequest(const QString& reference) {
  static const QRegularExpression last(QStringLiteral("([0-9]+)/?$"));
  const int number = last.match(reference).captured(1).toInt();
  return {{QStringLiteral("number"), number}, {QStringLiteral("title"), QStringLiteral("Add tax to the cart")},
          {QStringLiteral("url"), reference.startsWith(QLatin1String("http")) ? reference : QStringLiteral("https://github.com/acme/shop/pull/%1").arg(number)},
          {QStringLiteral("baseBranch"), QStringLiteral("main")}, {QStringLiteral("headBranch"), QStringLiteral("feature/tax")}, {QStringLiteral("state"), QStringLiteral("open")}};
}

QList<QJsonObject> asked(World& world, const QString& method) {
  QList<QJsonObject> found;
  for (const FakeMc::Rpc& rpc : std::as_const(world.mc.calls)) {
    if (rpc.method == method) found.append(rpc.payload);
  }
  return found;
}

bool choosable(World& world) {
  return world.brick->item(QStringLiteral("pullRequestThreadLocal"))->isEnabled() && world.brick->item(QStringLiteral("pullRequestThreadWorktree"))->isEnabled();
}

// The dialog, opened from the command palette's entry; its field.
QQuickItem* openPullRequestThread(World& world) {
  world.mc.onRpc(QStringLiteral("git.resolvePullRequest"), [&mc = world.mc](const FakeMc::Rpc& rpc) {
    FakePullRequestThread& fake = mc.part<FakePullRequestThread>();
    const QString reference = rpc.payload.value(QLatin1String("reference")).toString();
    if (fake.missing.contains(reference)) return mc.refuse(rpc, fake.missing.value(reference));
    mc.reply(rpc, QJsonObject{{QStringLiteral("pullRequest"), resolvedPullRequest(reference)}});
  });
  world.mc.onRpc(QStringLiteral("git.preparePullRequestThread"), [&mc = world.mc](const FakeMc::Rpc& rpc) {
    FakePullRequestThread& fake = mc.part<FakePullRequestThread>();
    if (fake.holdPrepare) return;
    if (fake.prepareRefusal) return mc.refuse(rpc, *fake.prepareRefusal);
    const bool worktree = rpc.payload.value(QLatin1String("mode")) == QLatin1String("worktree");
    mc.reply(rpc, QJsonObject{{QStringLiteral("pullRequest"), resolvedPullRequest(rpc.payload.value(QLatin1String("reference")).toString())},
                              {QStringLiteral("branch"), QStringLiteral("feature/tax")},
                              {QStringLiteral("worktreePath"), worktree ? QJsonValue(QStringLiteral("/work/worktrees/pr-42")) : QJsonValue()},
                              {QStringLiteral("isOnPullRequestHead"), true}});
  });
  lookAt(world, QStringLiteral("Tax work"));
  world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nItem { PullRequestThreadDialog {} }\n", QSize(640, 480));
  auto* keys = world.native().controller<KeybindingController>();
  expect(keys->commands()->contains(QStringLiteral("pullRequestThread.open")), QStringLiteral("no command starts a pull request thread"));
  keys->commands()->run(QStringLiteral("pullRequestThread.open"));
  QQuickItem* field = world.brick->item(QStringLiteral("pullRequestThreadReference"));
  world.waitFor([&] { return field->isVisible(); }, QStringLiteral("the dialog to ask for a pull request"));
  return field;
}

void startInWorktree(World& world, const QString& number) {
  openPullRequestThread(world)->setProperty("text", number);
  world.waitFor([&] { return choosable(world); },
                [&] { return QStringLiteral("the pull request to resolve; the dialog is %1").arg(show(world.state(QStringLiteral("pullRequestThread")))); });
  world.brick->click(QStringLiteral("pullRequestThreadWorktree"));
  world.sync();
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
  // A thread started on a pull request the user names (PullRequestThreadController).
  step(QStringLiteral("the user pastes %1 to start a pull request thread").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* field = openPullRequestThread(world);
    world.brick->click(QStringLiteral("pullRequestThreadReference"));
    field->setProperty("text", c[0]);
    QTest::keyClick(&world.brick->window(), Qt::Key_Return);
    world.sync();
  });
  step(QStringLiteral("the user (?:types|typed) %1 to start a pull request thread").arg(q), [](World& world, const Captures& c, const Table&) {
    openPullRequestThread(world)->setProperty("text", c[0]);
    world.sync();
  });
  step(QStringLiteral("the user clears the reference"), [](World& world, const Captures&, const Table&) {
    world.brick->item(QStringLiteral("pullRequestThreadReference"))->setProperty("text", QString());
    world.sync();
  });
  step(QStringLiteral("the pull request number is read as (\\d+)"), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return world.brick->shows(QStringLiteral("#%1 · feature/tax to main").arg(c[0])); },
                  [&] { return QStringLiteral("the pull request to be shown; the dialog is %1").arg(show(world.state(QStringLiteral("pullRequestThread")))); });
    expect(choosable(world), QStringLiteral("local and worktree cannot be chosen"));
  });
  step(QStringLiteral("neither local nor worktree can be chosen"), [](World& world, const Captures&, const Table&) {
    expect(!choosable(world), QStringLiteral("local or worktree can be chosen; the dialog is %1").arg(show(world.state(QStringLiteral("pullRequestThread")))));
    // Return does not start one either.
    QTest::keyClick(&world.brick->window(), Qt::Key_Return);
    world.sync();
    expect(asked(world, QStringLiteral("git.preparePullRequestThread")).isEmpty(), QStringLiteral("a checkout was prepared"));
  });
  // The dialog resolves once the typing pauses, so it is resolving straight after.
  step(QStringLiteral("the user is told \"Resolving pull request...\" until its title and branches arrive"), [](World& world, const Captures&, const Table&) {
    expect(world.brick->shows(QStringLiteral("Resolving pull request...")) && !world.brick->shows(QStringLiteral("Add tax to the cart")),
           QStringLiteral("the dialog does not say it is resolving; it is %1").arg(show(world.state(QStringLiteral("pullRequestThread")))));
    expect(!choosable(world), QStringLiteral("local or worktree can be chosen while resolving"));
  });
  step(QStringLiteral("neither local nor worktree can be chosen until then"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.brick->shows(QStringLiteral("Add tax to the cart")); },
                  [&] { return QStringLiteral("the pull request to resolve; the dialog is %1").arg(show(world.state(QStringLiteral("pullRequestThread")))); });
    expect(choosable(world) && !world.brick->shows(QStringLiteral("Resolving pull request...")),
           QStringLiteral("the resolved pull request cannot be chosen; the dialog is %1").arg(show(world.state(QStringLiteral("pullRequestThread")))));
    expect(asked(world, QStringLiteral("git.resolvePullRequest")).size() == 1, QStringLiteral("the pull request was asked for more than once"));
  });
  step(QStringLiteral("the host answers that pull request (\\d+) does not exist"), [](World& world, const Captures& c, const Table&) {
    world.mc.part<FakePullRequestThread>().missing.insert(c[0], QStringLiteral("GitHub has no pull request #%1 in acme/shop.").arg(c[0]));
  });
  step(QStringLiteral("the user is told the host's reason in the dialog"), [](World& world, const Captures&, const Table&) {
    const QString reason = world.mc.part<FakePullRequestThread>().missing.cbegin().value();
    world.waitFor([&] { return world.brick->shows(reason); },
                  [&] { return QStringLiteral("the host's reason to be shown; the dialog is %1").arg(show(world.state(QStringLiteral("pullRequestThread")))); });
  });
  // Choosing a worktree, with the MC still preparing it or failing to.
  step(QStringLiteral("the user chose to start a thread on pull request (\\d+) in a new worktree"), [](World& world, const Captures& c, const Table&) {
    world.mc.part<FakePullRequestThread>().holdPrepare = true;
    startInWorktree(world, c[0]);
  });
  step(QStringLiteral("the user starts a thread on pull request (\\d+) in a new worktree"), [](World& world, const Captures& c, const Table&) {
    startInWorktree(world, c[0]);
  });
  step(QStringLiteral("the MC fails to prepare pull request (\\d+) saying %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.part<FakePullRequestThread>().prepareRefusal = c[1];
  });
  step(QStringLiteral("the MC fails to prepare pull request (\\d+) without saying why"), [](World& world, const Captures&, const Table&) {
    world.mc.part<FakePullRequestThread>().prepareRefusal = QString();
  });
  step(QStringLiteral("the checkout is still being prepared"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !asked(world, QStringLiteral("git.preparePullRequestThread")).isEmpty(); }, QStringLiteral("the checkout to be asked of the MC"));
    expect(at(world.state(QStringLiteral("pullRequestThread")).toMap(), QStringLiteral("step")) == QLatin1String("starting"),
           show(world.state(QStringLiteral("pullRequestThread"))));
  });
  step(QStringLiteral("the dialog says %1 and cannot be cancelled").arg(q), [](World& world, const Captures& c, const Table&) {
    Brick& brick = *world.brick;
    expect(brick.shows(c[0]), QStringLiteral("the dialog does not say %1").arg(c[0]));
    expect(!brick.item(QStringLiteral("pullRequestThreadCancel"))->isEnabled(), QStringLiteral("Cancel can be pressed"));
    QTest::keyClick(&brick.window(), Qt::Key_Escape);
    world.bridge().dispatch(QStringLiteral("pullRequestThread.cancel"), QVariantMap());
    world.sync();
    expect(!world.state(QStringLiteral("pullRequestThread")).isNull() && brick.item(QStringLiteral("pullRequestThreadReference"))->isVisible(),
           QStringLiteral("the dialog was closed while preparing"));
  });
  step(QStringLiteral("local and worktree cannot be chosen again"), [](World& world, const Captures&, const Table&) {
    expect(!choosable(world), QStringLiteral("local or worktree can be chosen while preparing"));
    // Nor does the controller start a second one if asked.
    world.bridge().dispatch(QStringLiteral("pullRequestThread.start"), QVariantMap{{QStringLiteral("mode"), QStringLiteral("local")}});
    world.sync();
    expect(asked(world, QStringLiteral("git.preparePullRequestThread")).size() == 1, QStringLiteral("a second checkout was asked for"));
  });
  step(QStringLiteral("the dialog stays open and says %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return world.brick->shows(c[0]); },
                  [&] { return QStringLiteral("%1 to be shown; the dialog is %2").arg(c[0], show(world.state(QStringLiteral("pullRequestThread")))); });
    expect(world.brick->item(QStringLiteral("pullRequestThreadReference"))->isVisible() && asked(world, QStringLiteral("orchestration.launchThread")).isEmpty(),
           QStringLiteral("the dialog closed or a thread was started"));
  });
  step(QStringLiteral("the user can choose local or worktree again"), [](World& world, const Captures&, const Table&) {
    expect(choosable(world), QStringLiteral("local and worktree cannot be chosen; the dialog is %1").arg(show(world.state(QStringLiteral("pullRequestThread")))));
  });
  step(QStringLiteral("the user sees the pull request's title and branches before choosing local or worktree"), [](World& world, const Captures&, const Table&) {
    Brick& brick = *world.brick;
    const auto asked = [&world](const QString& method) { return ::asked(world, method); };
    world.waitFor([&] { return brick.shows(QStringLiteral("Add tax to the cart")) && brick.shows(QStringLiteral("#42 · feature/tax to main")); },
                  [&] { return QStringLiteral("the pull request to be shown; the dialog is %1").arg(show(world.state(QStringLiteral("pullRequestThread")))); });
    const QList<QJsonObject> resolved = asked(QStringLiteral("git.resolvePullRequest"));
    expect(resolved.size() == 1 && resolved.first().value(QLatin1String("cwd")) == QLatin1String("/work/shop") &&
               resolved.first().value(QLatin1String("reference")) == QLatin1String("https://github.com/acme/shop/pull/42"),
           QStringLiteral("the MC was asked to resolve %1").arg(resolved.size()));
    expect(brick.item(QStringLiteral("pullRequestThreadLocal"))->isVisible() && brick.item(QStringLiteral("pullRequestThreadWorktree"))->isVisible(),
           QStringLiteral("local and worktree are not both offered"));
    // Nothing was checked out to show it.
    expect(asked(QStringLiteral("git.preparePullRequestThread")).isEmpty() && asked(QStringLiteral("orchestration.launchThread")).isEmpty(),
           QStringLiteral("the pull request was checked out before the user chose"));
    // Chosen, the worktree is prepared and the window moves to the new thread in it.
    brick.click(QStringLiteral("pullRequestThreadWorktree"));
    world.waitFor([&] { return asked(QStringLiteral("orchestration.launchThread")).size() == 1; }, QStringLiteral("the thread to be started"));
    const QJsonObject prepared = asked(QStringLiteral("git.preparePullRequestThread")).value(0);
    const QJsonObject launched = asked(QStringLiteral("orchestration.launchThread")).first();
    const QJsonObject strategy = launched.value(QLatin1String("workspaceStrategy")).toObject();
    expect(prepared.value(QLatin1String("mode")) == QLatin1String("worktree") && prepared.value(QLatin1String("threadId")) == launched.value(QLatin1String("threadId")) &&
               launched.value(QLatin1String("title")) == QLatin1String("#42 Add tax to the cart") && strategy.value(QLatin1String("type")) == QLatin1String("existing_worktree") &&
               strategy.value(QLatin1String("worktreePath")) == QLatin1String("/work/worktrees/pr-42") && strategy.value(QLatin1String("branch")) == QLatin1String("feature/tax"),
           QStringLiteral("the MC was asked %1 then %2").arg(show(prepared.toVariantMap()), show(launched.toVariantMap())));
    const QString key = world.mc.environmentId + QLatin1Char(':') + launched.value(QLatin1String("threadId")).toString();
    world.waitFor([&] { return world.native().controller<NavigationController>()->threadKey() == key && world.state(QStringLiteral("pullRequestThread")).isNull(); },
                  QStringLiteral("the new thread to open"));
  });

  // A pull request a message mentions, linked from that message.
  step(QStringLiteral("a message in %1 mentions %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAt(world, c[0]);
    startRun(world, 30);
    addItem(world, QStringLiteral("assistant_message"), {{QStringLiteral("text"), QStringLiteral("I opened %1 for the tax line.").arg(c[1])}});
    settleRun(world, QStringLiteral("completed"), 30);
    waitForRow(world, 42, false);
    world.mc.part<FakePullRequests>().mentioned = c[1];
  });
  // GitHub writes "#42" through its issue page, pull request or not.
  step(QStringLiteral("a message in %1 mentions %1 of %1, which the message links to GitHub's page for issue (\\d+)").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAt(world, c[0]);
    const QString url = QStringLiteral("https://github.com/%1/issues/%2").arg(c[2], c[3]);
    startRun(world, 30);
    addItem(world, QStringLiteral("assistant_message"), {{QStringLiteral("text"), QStringLiteral("The tax line is fixed in [%1](%2).").arg(c[1], url)}});
    settleRun(world, QStringLiteral("completed"), 30);
    world.mc.part<FakePullRequests>().mentioned = url;
  });
  step(QStringLiteral("the host knows (\\d+) as (a pull request|an issue)"), [](World& world, const Captures& c, const Table&) {
    if (c[1] == QLatin1String("an issue")) world.mc.part<FakePullRequests>().unreadable.insert(c[0].toInt());
  });
  step(QStringLiteral("the MC cannot read pull request (\\d+)"), [](World& world, const Captures& c, const Table&) {
    world.mc.part<FakePullRequests>().unreadable.insert(c[0].toInt());
  });
  step(QStringLiteral("no project is checked out from that host"), [](World& world, const Captures&, const Table&) {
    const QString host = QUrl(world.mc.part<FakePullRequests>().mentioned).host();
    for (const QJsonObject& project : std::as_const(world.mc.projects)) {
      const QString key = project.value(QLatin1String("repositoryIdentity")).toObject().value(QLatin1String("canonicalKey")).toString();
      expect(key.section(QLatin1Char('/'), 0, 0) != host, QStringLiteral("%1 is checked out from %2").arg(key, host));
    }
  });
  step(QStringLiteral("the user rests the pointer on that link"), [](World& world, const Captures&, const Table&) {
    // The card says how long ago the pull request was opened.
    world.setTime(QStringLiteral("2026-09-23T09:00:00Z"));
    const LinkSpot spot = mentionedLink(world);
    // From off the text: the pointer may still rest where the previous scenario left it.
    QTest::mouseMove(&world.brick->window(), QPoint(1, 1));
    QTest::mouseMove(&world.brick->window(), spot.at);
    world.sync();
  });
  step(QStringLiteral("a card shows %1 #(\\d+), its state, its title, its author and when it was opened").arg(q), [](World& world, const Captures& c, const Table&) {
    Brick& brick = *world.brick;
    const QStringList drawn{c[0], QStringLiteral("#") + c[1], QStringLiteral("Open"), QStringLiteral("Tax line fix"), QStringLiteral("Ada Lovelace (@ada)"), QStringLiteral("opened 3h ago")};
    world.waitFor([&] { return std::all_of(drawn.cbegin(), drawn.cend(), [&](const QString& text) { return brick.shows(text); }); },
                  [&] {
                    QStringList missing;
                    for (const QString& text : drawn) {
                      if (!brick.shows(text)) missing.append(text);
                    }
                    return QStringLiteral("the card to show %1").arg(missing.join(QStringLiteral(", ")));
                  });
  });
  step(QStringLiteral("the card shows %1").arg(q), [](World& world, const Captures& c, const Table&) {
    PullRequestLinkPreviews* previews = world.native().controller<RightPanelController>()->linkPreviews();
    world.waitFor([&] { return world.brick->shows(c[0]); },
                  [&] { return QStringLiteral("the card to show the address; the link is %1 and %2").arg(previews->address(), previews->status()); });
    expect(!world.brick->shows(QStringLiteral("Tax line fix")), QStringLiteral("the card shows the pull request it could not read"));
  });
  step(QStringLiteral("the user clicks that link( holding the modifier key)?"), [](World& world, const Captures& c, const Table&) {
    const LinkSpot spot = mentionedLink(world);
    // The desktop follows a link on the primary modifier; Shift as well forces the browser.
    Qt::KeyboardModifiers modifiers = Qt::ControlModifier;
    if (!c[0].isEmpty()) modifiers |= Qt::ShiftModifier;
    QTest::mouseClick(&world.brick->window(), Qt::LeftButton, modifiers, spot.at);
    world.sync();
  });
  step(QStringLiteral("pull request (\\d+) (opens|does not open) in HAL-C2"), [](World& world, const Captures& c, const Table&) {
    const QString tab = QStringLiteral("pull-request:github.com/acme/shop#") + c[0];
    const auto active = [&] { return at(world.state(QStringLiteral("panel")), QStringLiteral("activeId")).toString(); };
    if (c[1] == QLatin1String("opens")) {
      world.waitFor([&] { return active() == tab; }, [&] { return QStringLiteral("the review to open; the panel is %1").arg(show(world.state(QStringLiteral("panel")))); });
      expect(world.openedUrls.isEmpty(), QStringLiteral("the browser opened %1 as well").arg(world.openedUrls.value(0).toString()));
    } else {
      expect(active() != tab, QStringLiteral("the review opened"));
    }
  });
  step(QStringLiteral("it is not opened as a pull request of the public host"), [](World& world, const Captures&, const Table&) {
    for (const FakeMc::Rpc& rpc : std::as_const(world.mc.calls)) {
      expect(rpc.method != QLatin1String("pullRequests.preview"), QStringLiteral("the MC was asked to read %1").arg(show(rpc.payload.toVariantMap())));
    }
    expect(!at(world.state(QStringLiteral("panel")), QStringLiteral("activeId")).toString().startsWith(QLatin1String("pull-request:")),
           show(world.state(QStringLiteral("panel"))));
  });

  // The right-click on a pull request's number (PullRequestsPanel.qml, the review's header).
  const auto numberMenu = [](World& world, const QString& url) {
    world.bridge().dispatch(QStringLiteral("pullRequest.linkMenu"), QVariantMap{{QStringLiteral("url"), url}, {QStringLiteral("x"), 300}, {QStringLiteral("y"), 200}});
    world.sync();
  };
  step(QStringLiteral("the user opens the menu of the number of a pull request of (GitHub|GitLab|Forgejo|Bitbucket|Azure DevOps)"), [numberMenu](World& world, const Captures& c, const Table&) {
    static const QHash<QString, QString> pages{
        {QStringLiteral("GitHub"), QStringLiteral("https://github.com/acme/shop/pull/42")},
        {QStringLiteral("GitLab"), QStringLiteral("https://gitlab.com/acme/shop/-/merge_requests/42")},
        {QStringLiteral("Forgejo"), QStringLiteral("https://codeberg.org/acme/shop/pulls/42")},
        {QStringLiteral("Bitbucket"), QStringLiteral("https://bitbucket.org/acme/shop/pull-requests/42")},
        {QStringLiteral("Azure DevOps"), QStringLiteral("https://dev.azure.com/acme/shop/_git/shop/pullrequest/42")},
    };
    numberMenu(world, pages.value(c[0]));
  });
  step(QStringLiteral("the clipboard cannot be written and the browser cannot be opened"), [](World& world, const Captures&, const Table&) {
    world.clipboardFails = true;
    world.browserFails = true;
  });
  step(QStringLiteral("the user chooses %1 from the menu of a pull request number").arg(q), [numberMenu](World& world, const Captures& c, const Table&) {
    numberMenu(world, QStringLiteral("https://github.com/acme/shop/pull/42"));
    const QVariant menu = world.state(QStringLiteral("menu"));
    for (const QVariant& item : at(menu, QStringLiteral("items")).toList()) {
      if (item.toMap().value(QStringLiteral("label")) != c[0]) continue;
      world.bridge().dispatch(QStringLiteral("menu.select"),
                              QVariantMap{{QStringLiteral("requestId"), at(menu, QStringLiteral("requestId"))}, {QStringLiteral("id"), item.toMap().value(QStringLiteral("id"))}});
      world.sync();
      return;
    }
    fail(QStringLiteral("the menu is %1").arg(show(menu)));
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
  // The stack in the pull request's review, and its actions, which ask first.
  const auto reviewStack = [](World& world, int number) -> Brick& {
    world.mc.part<FakeReview>().author = QStringLiteral("octocat");
    serveReview(world.mc);
    lookAt(world, QStringLiteral("Tax work"));
    if (rowOf(world, number) < 0) link(world, QString::number(number));
    waitForRow(world, number, true);
    openReview(world, number);
    world.waitFor([&] { return review(world).stack().value(QStringLiteral("size")).toInt() == 3; }, [&] { return QStringLiteral("the stack; it is %1").arg(show(review(world).stack())); });
    world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Shell\nimport HalC2.Bricks\nPullRequestReviewPanel { source: Panel.review }\n", QSize(700, 800));
    world.waitFor([&] { return world.brick->shows(QStringLiteral("Stack #1 · layer 2 of 3 onto main")); }, QStringLiteral("the review to show the stack"));
    return *world.brick;
  };
  step(QStringLiteral("the user chooses to merge the stack at pull request (\\d+)"), [reviewStack](World& world, const Captures& c, const Table&) {
    Brick& brick = reviewStack(world, c[0].toInt());
    expect(brick.shows(QStringLiteral("Merge stack (2)")), QStringLiteral("the stack does not offer to merge two layers"));
    brick.click(QStringLiteral("reviewStackMerge"));
  });
  step(QStringLiteral("the user is asked to confirm merging (\\d+) pull requests into %1 with the chosen method").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap asked = review(world).stackConfirmation();
    expect(asked.value(QStringLiteral("title")) == QStringLiteral("Merge %1 pull requests?").arg(c[0]) &&
               asked.value(QStringLiteral("description")).toString().startsWith(QStringLiteral("Merge #42 and its unmerged layers below into %1 using merge.").arg(c[1])),
           QStringLiteral("the user is asked %1").arg(show(asked)));
    Brick& brick = *world.brick;
    world.waitFor([&] { return brick.shows(asked.value(QStringLiteral("title")).toString()) && brick.shows(asked.value(QStringLiteral("description")).toString()); },
                  QStringLiteral("the confirmation to be drawn"));
    // Nothing is merged before the answer; cancelling asks nothing of the host.
    expect(world.mc.part<FakeReview>().actions.isEmpty(), QStringLiteral("the host was asked before the user confirmed"));
    brick.click(QStringLiteral("reviewStackConfirmCancel"));
    world.sync();
    expect(review(world).stackConfirmation().isEmpty() && world.mc.part<FakeReview>().actions.isEmpty(), QStringLiteral("cancelling did not drop the merge"));
    // Confirmed, the two layers go with the heads that were shown.
    brick.click(QStringLiteral("reviewStackMerge"));
    brick.click(QStringLiteral("reviewStackConfirmAccept"));
    world.waitFor([&] { return world.mc.part<FakeReview>().actions.size() == 1; }, QStringLiteral("the merge to be asked of the host"));
    const QJsonObject action = world.mc.part<FakeReview>().actions.first();
    const QJsonArray heads = action.value(QLatin1String("expectedStackHeads")).toArray();
    expect(action.value(QLatin1String("action")) == QLatin1String("merge") && action.value(QLatin1String("stackNumber")).toInt() == 1 &&
               action.value(QLatin1String("number")).toInt() == 42 && action.value(QLatin1String("mergeMethod")) == QLatin1String("merge") && heads.size() == 2 &&
               heads.at(0).toObject().value(QLatin1String("number")).toInt() == 41 && heads.at(1).toObject().value(QLatin1String("headSha")) == QLatin1String("sha-42"),
           QStringLiteral("the host was asked %1").arg(show(action.toVariantMap())));
  });
  step(QStringLiteral("the user chooses to rebase the stack"), [reviewStack](World& world, const Captures&, const Table&) {
    reviewStack(world, 42).click(QStringLiteral("reviewStackRebase"));
  });
  step(QStringLiteral("the user is warned that branch history is rewritten and checks may restart"), [](World& world, const Captures&, const Table&) {
    const QVariantMap asked = review(world).stackConfirmation();
    const QString warning = QStringLiteral("Rebase the remote branches from bottom to top onto main. This rewrites branch history and may restart checks. If a layer fails, earlier updates remain.");
    expect(asked.value(QStringLiteral("title")) == QLatin1String("Rebase 3 pull requests?") && asked.value(QStringLiteral("description")) == warning,
           QStringLiteral("the user is asked %1").arg(show(asked)));
    Brick& brick = *world.brick;
    world.waitFor([&] { return brick.shows(warning); }, QStringLiteral("the warning to be drawn"));
    expect(world.mc.part<FakeReview>().actions.isEmpty(), QStringLiteral("the host was asked before the user confirmed"));
    brick.click(QStringLiteral("reviewStackConfirmAccept"));
    world.waitFor([&] { return world.mc.part<FakeReview>().actions.size() == 1; }, QStringLiteral("the rebase to be asked of the host"));
    const QJsonObject action = world.mc.part<FakeReview>().actions.first();
    expect(action.value(QLatin1String("action")) == QLatin1String("update-branch") && action.value(QLatin1String("updateMethod")) == QLatin1String("rebase") &&
               action.value(QLatin1String("number")).toInt() == 43 && action.value(QLatin1String("expectedStackHeads")).toArray().size() == 3,
           QStringLiteral("the host was asked %1").arg(show(action.toVariantMap())));
  });
  step(QStringLiteral("the last stack refresh failed"), [reviewStack](World& world, const Captures&, const Table&) {
    Brick& brick = reviewStack(world, 42);
    world.mc.part<FakeReview>().stackFails = true;
    brick.click(QStringLiteral("reviewReload"));
    world.sync();
  });
  step(QStringLiteral("the user looks at the stack"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return review(world).stack().value(QStringLiteral("stale")).toBool(); }, [&] { return QStringLiteral("the stack; it is %1").arg(show(review(world).stack())); });
  });
  step(QStringLiteral("the stack is marked as possibly stale with a way to retry"), [](World& world, const Captures&, const Table&) {
    Brick& brick = *world.brick;
    // What was read before is still shown, with the notice; nothing can be done to it meanwhile.
    const QVariantMap stack = review(world).stack();
    expect(stack.value(QStringLiteral("size")).toInt() == 3 && stack.value(QStringLiteral("notice")) == QStringLiteral("Stack data may be stale. We couldn’t refresh it.") &&
               !stack.value(QStringLiteral("canMerge")).toBool() && !stack.value(QStringLiteral("canRebase")).toBool(),
           QStringLiteral("the stack is %1").arg(show(stack)));
    world.waitFor([&] { return brick.shows(QStringLiteral("Stack data may be stale. We couldn’t refresh it.")) && brick.item(QStringLiteral("reviewStackRetry"))->isVisible(); },
                  QStringLiteral("the notice and its retry to be drawn"));
    // The retry reads the stack again; once the host answers the notice goes.
    world.mc.part<FakeReview>().stackFails = false;
    const int reads = world.mc.part<FakeReview>().stackReads;
    brick.click(QStringLiteral("reviewStackRetry"));
    world.waitFor([&] { return !review(world).stack().value(QStringLiteral("stale")).toBool(); }, QStringLiteral("the stack to be read again"));
    expect(world.mc.part<FakeReview>().stackReads == reads + 1 && review(world).stack().value(QStringLiteral("canRebase")).toBool(), QStringLiteral("the stack is %1").arg(show(review(world).stack())));
  });
  step(QStringLiteral("its pull request shows it is layer (\\d+) of (\\d+)"), [](World& world, const Captures& c, const Table&) {
    const QString wanted = QStringLiteral("Layer %1 of %2").arg(c[0], c[1]);
    world.waitFor([&] { return model(world).rowCount() == 1 && model(world).value(0, ThreadPullRequests::StackLabelRole) == wanted; },
                  [&] { return QStringLiteral("%1; the stack reads \"%2\"").arg(describe(world), model(world).rowCount() > 0 ? model(world).value(0, ThreadPullRequests::StackLabelRole).toString() : QString()); });
    world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Shell\nimport HalC2.Bricks\nPullRequestsPanel { width: 420; height: 600; source: Panel.pullRequests }\n", QSize(420, 500));
    world.waitFor([&] { return world.brick->shows(QStringLiteral("acme/shop · feature/tax → main · ") + wanted); }, QStringLiteral("the tab to draw the layer"));
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


// The Pull requests tab as drawn (PullRequestsPanel), and the threads of one
// pull request from its review (PullRequestThreadLinks):
// features/source-control/pull-request-threads.feature.
PullRequestThreadLinks& reviewThreads(World& world) {
  return *world.native().controller<RightPanelController>()->reviewThreads();
}

QString describeThreads(World& world) {
  PullRequestThreadLinks& links = reviewThreads(world);
  return QStringLiteral("the review's threads: %1 (%2), \"%3\", picker %4 %5")
      .arg(links.label())
      .arg(links.count())
      .arg(links.menuLabel(), links.pickerOpen() ? QStringLiteral("open") : QStringLiteral("closed"), show(links.candidates()));
}

QJsonObject linkOf(const QString& repository, int number, const QString& source, const QString& linkedAt = QStringLiteral("2026-09-23T09:05:00Z")) {
  return {{QStringLiteral("host"), QStringLiteral("github.com")}, {QStringLiteral("repository"), repository}, {QStringLiteral("number"), number},
          {QStringLiteral("url"), QStringLiteral("https://github.com/%1/pull/%2").arg(repository).arg(number)},
          {QStringLiteral("source"), source}, {QStringLiteral("linkedAt"), linkedAt},
          {QStringLiteral("snapshot"), QJsonValue()}, {QStringLiteral("stack"), QJsonValue()}};
}

// The thread links `links` and nothing else, as the MC's sync sends them.
void setLinks(World& world, const QString& threadId, const QJsonArray& links) {
  QJsonObject row = world.mc.threads.value(threadId);
  row.insert(QStringLiteral("pullRequests"), links);
  world.mc.threads.insert(threadId, row);
  syncLinks(world.mc, threadId);
  world.sync();
}

// Another thread of the project, `updatedAt` newer than "Tax work".
void addThread(World& world, const QString& id, const QString& title, const QJsonArray& links, bool archived = false) {
  QJsonObject row{{QStringLiteral("id"), id}, {QStringLiteral("title"), title}, {QStringLiteral("projectId"), kProject},
                  {QStringLiteral("pullRequests"), links},
                  {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:30:00Z")}, {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:30:00Z")}};
  if (archived) row.insert(QStringLiteral("archivedAt"), QStringLiteral("2026-09-23T09:40:00Z"));
  world.mc.threads.insert(id, row);
  world.mc.sendRow(id, row);
  world.sync();
}

void openPanel(World& world) {
  if (world.brick) return;
  world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Shell\nimport HalC2.Bricks\nPullRequestsPanel { width: 420; height: 600; source: Panel.pullRequests }\n",
                                        QSize(420, 600));
  world.sync();
}

void findAll(QQuickItem* item, const QString& name, QList<QQuickItem*>& found) {
  if (item->objectName() == name) found.append(item);
  for (QQuickItem* child : item->childItems()) findAll(child, name, found);
}

QQuickItem* rowItem(World& world, int number) {
  QList<QQuickItem*> rows;
  world.waitFor([&] {
    rows.clear();
    findAll(world.brick->window().contentItem(), QStringLiteral("pullRequestRow-%1").arg(number), rows);
    return !rows.isEmpty();
  }, [&] { return describe(world); });
  return rows.first();
}

QQuickItem* inRow(QQuickItem* row, const QString& name) {
  QList<QQuickItem*> found;
  findAll(row, name, found);
  expect(!found.isEmpty(), QStringLiteral("the row has no %1").arg(name));
  return found.first();
}

bool menuShown(World& world) {
  QList<QQuickItem*> items;
  findAll(world.brick->window().contentItem(), QStringLiteral("pullRequestCopyLink"), items);
  return std::any_of(items.cbegin(), items.cend(), [](QQuickItem* item) { return item->isVisible(); });
}

void openActions(World& world, int number) {
  openPanel(world);
  // A menu still closing would take the click.
  world.waitFor([&] { return !menuShown(world); }, [] { return QStringLiteral("the row's menu stays open"); });
  QQuickItem* button = inRow(rowItem(world, number), QStringLiteral("pullRequestMenu"));
  QTest::mouseClick(&world.brick->window(), Qt::LeftButton, Qt::NoModifier, world.brick->at(button));
  world.sync();
}

// The visible menu entry `name` (each row has its own menu).
QQuickItem* menuItem(World& world, const QString& name) {
  QQuickItem* found = nullptr;
  world.waitFor([&] {
    QList<QQuickItem*> items;
    findAll(world.brick->window().contentItem(), name, items);
    for (QQuickItem* item : std::as_const(items)) {
      if (item->isVisible()) found = item;
    }
    return found != nullptr;
  }, [&] { return QStringLiteral("no %1 is shown").arg(name); });
  return found;
}

// A review tab of pull request `number` of "acme/shop", linked to the thread or not.
void reviewUnlinked(World& world, int number) {
  serveReview(world.mc);
  world.bridge().dispatch(QStringLiteral("rightPanel.reviewProject"), QVariantMap{{QStringLiteral("key"), QStringLiteral("github.com/acme/shop#%1").arg(number)}});
  world.sync();
  world.waitFor([&] { return reviewThreads(world).available() && reviewThreads(world).count() >= 0; }, [&] { return describeThreads(world); });
}

int linkCommands(World& world) {
  int sent = 0;
  for (const QJsonObject& command : std::as_const(world.mc.commands)) {
    if (command.value(QLatin1String("type")).toString().startsWith(QLatin1String("thread.pull-request."))) ++sent;
  }
  return sent;
}

const Steps panelSteps([] {
  const QString q = kQuoted;

  // The link field.
  step(QStringLiteral("the user is linking a pull request to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAt(world, c[0]);
    world.native().controller<RightPanelController>()->linkPullRequest();
    world.sync();
    expect(model(world).linkOpen(), QStringLiteral("the link field is closed"));
  });
  step(QStringLiteral("the user types %1 as the pull request to link").arg(q), [](World& world, const Captures& c, const Table&) {
    model(world).setReference(c[0]);
  });
  step(QStringLiteral("the user clears the pull request to link"), [](World& world, const Captures&, const Table&) {
    model(world).setReference(QString());
  });
  step(QStringLiteral("%1 is not in a project").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAt(world, c[0]);
    QJsonObject row = world.mc.threads.value(kThread);
    row.insert(QStringLiteral("projectId"), QJsonValue());
    world.mc.threads.insert(kThread, row);
    world.mc.sendRow(kThread, row);
    world.sync();
  });
  step(QStringLiteral("the project of %1 is on a host whose pull request addresses are not known").arg(q), [](World& world, const Captures& c, const Table&) {
    QJsonObject project = world.mc.projects.value(kProject);
    project.insert(QStringLiteral("repositoryIdentity"),
                   QJsonObject{{QStringLiteral("canonicalKey"), QStringLiteral("git.example.com/acme/shop")}, {QStringLiteral("displayName"), QStringLiteral("acme/shop")}});
    world.mc.projects.insert(kProject, project);
    world.mc.sendRow(kProject, project, QStringLiteral("project"));
    world.sync();
    lookAt(world, c[0]);
  });
  step(QStringLiteral("the user links %1 to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAt(world, c[1]);
    link(world, c[0]);
  });
  step(QStringLiteral("the MC takes a while to link pull requests to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAt(world, c[0]);
    world.mc.hold(QStringLiteral("answers"));
  });
  step(QStringLiteral("the link dialog shows \"Linking...\" and cannot be submitted again"), [](World& world, const Captures&, const Table&) {
    openPanel(world);
    expect(model(world).linking() && !model(world).canLink(), describe(world));
    world.waitFor([&] { return world.brick->shows(QStringLiteral("Linking...")); }, [&] { return describe(world); });
    expect(!world.brick->item(QStringLiteral("pullRequestsLinkSubmit"))->isEnabled(), QStringLiteral("Linking... can be pressed"));
    const int sent = linkCommands(world);
    model(world).link(QStringLiteral("42"));
    world.sync();
    expect(linkCommands(world) == sent, QStringLiteral("a second link was sent"));
  });
  step(QStringLiteral("the user links pull request (\\d+) to %1 again").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.answerHeld();
    world.sync();
    world.waitFor([&] { return !model(world).linking(); }, [&] { return describe(world); });
    link(world, c[0]);
  });
  step(QStringLiteral("the link dialog says the pull request could not be linked and stays open"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !model(world).linking(); }, [&] { return describe(world); });
    expect(model(world).problem().startsWith(QLatin1String("Could not link the pull request")) && model(world).linkOpen(), describe(world));
    world.waitFor([&] { return world.brick->shows(model(world).problem()); }, [&] { return describe(world); });
  });

  // How each link came to be, and what its row offers.
  step(QStringLiteral("pull request (\\d+) was (linked by the user|created from the thread|linked by the agent|found in the stack of another layer|dismissed from "
                      "the stack) to %1")
           .arg(q),
       [](World& world, const Captures& c, const Table&) {
         static const QHash<QString, QString> sources{{QStringLiteral("linked by the user"), QStringLiteral("manual")},
                                                      {QStringLiteral("created from the thread"), QStringLiteral("created")},
                                                      {QStringLiteral("linked by the agent"), QStringLiteral("agent")},
                                                      {QStringLiteral("found in the stack of another layer"), QStringLiteral("stack")},
                                                      {QStringLiteral("dismissed from the stack"), QStringLiteral("stack-dismissed")}};
         lookAt(world, c[2]);
         setLinks(world, kThread, {linkOf(QStringLiteral("acme/shop"), c[0].toInt(), sources.value(c[1]))});
       });
  step(QStringLiteral("the user opens the pull requests of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAt(world, c[0]);
    openPanel(world);
  });
  step(QStringLiteral("pull request (\\d+) says %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const auto says = [&] {
      const int row = rowOf(world, c[0].toInt());
      if (row >= 0) return model(world).value(row, ThreadPullRequests::SourceLabelRole).toString();
      for (const QVariant& entry : model(world).dismissed()) {
        if (entry.toMap().value(QStringLiteral("number")).toInt() == c[0].toInt()) return entry.toMap().value(QStringLiteral("sourceLabel")).toString();
      }
      return QString();
    };
    // A dismissed one is listed below the rest, its label after its title.
    const auto shown = [&] {
      if (world.brick->shows(c[1])) return true;
      QList<QQuickItem*> dismissed;
      findAll(world.brick->window().contentItem(), QStringLiteral("dismissedPullRequest-") + c[0], dismissed);
      for (QQuickItem* row : std::as_const(dismissed)) {
        for (QQuickItem* child : row->childItems()) {
          if (row->isVisible() && child->property("text").toString().endsWith(QStringLiteral(" · ") + c[1])) return true;
        }
      }
      return false;
    };
    world.waitFor([&] { return says() == c[1] && shown(); }, [&] { return describe(world) + QStringLiteral(", it says ") + says(); });
  });
  step(QStringLiteral("pull request (\\d+) is a layer found in the stack of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAt(world, c[1]);
    setLinks(world, kThread, {linkOf(QStringLiteral("acme/shop"), 42, QStringLiteral("manual")), linkOf(QStringLiteral("acme/shop"), c[0].toInt(), QStringLiteral("stack"))});
  });
  step(QStringLiteral("the user opens the actions of pull request (\\d+) in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAt(world, c[1]);
    waitForRow(world, c[0].toInt(), true);
    openActions(world, c[0].toInt());
    world.mc.part<FakePullRequests>().actionsOf = c[0].toInt();
  });
  step(QStringLiteral("the action is %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const int number = world.mc.part<FakePullRequests>().actionsOf;
    expect(model(world).value(rowOf(world, number), ThreadPullRequests::UnlinkLabelRole) == c[0], describe(world));
    expect(menuItem(world, QStringLiteral("pullRequestUnlink"))->property("text") == c[0], QStringLiteral("the menu does not offer %1").arg(c[0]));
  });
  step(QStringLiteral("a pull request the user linked is offered %1 instead").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(model(world).value(rowOf(world, 42), ThreadPullRequests::SourceRole) == QLatin1String("manual") &&
               model(world).value(rowOf(world, 42), ThreadPullRequests::UnlinkLabelRole) == c[0],
           describe(world));
  });
  step(QStringLiteral("pull request (\\d+) is a layer of a GitHub stack of 3"), [](World& world, const Captures& c, const Table&) {
    FakePullRequests& fake = world.mc.part<FakePullRequests>();
    lookAt(world, QStringLiteral("Tax work"));
    fake.stackBase = QStringLiteral("main");
    fake.stack = {c[0].toInt(), c[0].toInt() + 1, c[0].toInt() + 2};
    QJsonArray links;
    for (const int number : std::as_const(fake.stack)) {
      links.append(linkOf(QStringLiteral("acme/shop"), number, number == c[0].toInt() ? QStringLiteral("manual") : QStringLiteral("stack")));
    }
    setLinks(world, kThread, links);
  });
  step(QStringLiteral("pull requests (\\d+), (\\d+) and (\\d+) are chained by their base branches on a host with no stacks of its own"),
       [](World& world, const Captures& c, const Table&) {
         FakePullRequests& fake = world.mc.part<FakePullRequests>();
         lookAt(world, QStringLiteral("Tax work"));
         QJsonArray links;
         QString base = QStringLiteral("main");
         for (int at = 0; at < 3; ++at) {
           QJsonObject snapshot = fake.host.value(QStringLiteral("acme/shop#42"));
           snapshot.insert(QStringLiteral("headBranch"), QStringLiteral("tax/%1").arg(at));
           snapshot.insert(QStringLiteral("baseBranch"), base);
           base = QStringLiteral("tax/%1").arg(at);
           fake.host.insert(QStringLiteral("acme/shop#") + c[at], snapshot);
           links.append(linkOf(QStringLiteral("acme/shop"), c[at].toInt(), QStringLiteral("manual")));
         }
         setLinks(world, kThread, links);
       });
  step(QStringLiteral("pull request (\\d+) was just linked to %1 and the host has not answered").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAt(world, c[1]);
    world.mc.part<FakePullRequests>().host.remove(QStringLiteral("acme/shop#") + c[0]);
    setLinks(world, kThread, {linkOf(QStringLiteral("acme/shop"), c[0].toInt(), QStringLiteral("manual"))});
  });
  step(QStringLiteral("pull request (\\d+) is listed with its repository and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* row = rowItem(world, c[0].toInt());
    world.waitFor([&] { return inRow(row, QStringLiteral("pullRequestRepository"))->property("text").toString().contains(QLatin1String("acme/shop")) &&
                               world.brick->shows(c[1]); },
                  [&] { return describe(world) + QStringLiteral(", the row says ") + inRow(row, QStringLiteral("pullRequestRepository"))->property("text").toString(); });
  });
  step(QStringLiteral("pull request (\\d+) was linked to %1 by the user an hour ago").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAt(world, c[1]);
    setLinks(world, kThread, {linkOf(QStringLiteral("acme/shop"), c[0].toInt(), QStringLiteral("manual"), world.now().addSecs(-3600).toString(Qt::ISODate))});
  });
  step(QStringLiteral("the user rests the pointer on the number of pull request (\\d+)"), [](World& world, const Captures& c, const Table&) {
    openPanel(world);
    QQuickItem* number = inRow(rowItem(world, c[0].toInt()), QStringLiteral("pullRequestNumber"));
    QTest::mouseMove(&world.brick->window(), world.brick->at(number));
    world.sync();
  });
  step(QStringLiteral("the user is told %1 and how long ago").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString note = c[0] + QStringLiteral(" · 1h ago");
    world.waitFor([&] { return model(world).value(0, ThreadPullRequests::LinkedNoteRole) == note && world.brick->shows(note); },
                  [&] { return describe(world) + QStringLiteral(", the note is ") + model(world).value(0, ThreadPullRequests::LinkedNoteRole).toString(); });
  });
  step(QStringLiteral("the user can copy its link"), [](World& world, const Captures&, const Table&) {
    QQuickItem* copy = menuItem(world, QStringLiteral("pullRequestCopyLink"));
    QTest::mouseClick(&world.brick->window(), Qt::LeftButton, Qt::NoModifier, world.brick->at(copy));
    world.sync();
    expect(world.clipboard == QLatin1String("https://github.com/acme/shop/pull/42"), QStringLiteral("the clipboard holds \"%1\"").arg(world.clipboard));
  });
  step(QStringLiteral("the user can open it"), [](World& world, const Captures&, const Table&) {
    openActions(world, 42);
    QQuickItem* open = menuItem(world, QStringLiteral("pullRequestOpen"));
    QTest::mouseClick(&world.brick->window(), Qt::LeftButton, Qt::NoModifier, world.brick->at(open));
    world.sync();
    expect(world.openedUrls.contains(QUrl(QStringLiteral("https://github.com/acme/shop/pull/42"))), show(QVariant::fromValue(world.openedUrls)));
  });

  // What the tab says with nothing to list.
  step(QStringLiteral("the environment does not support several linked pull requests per thread"), [](World& world, const Captures&, const Table&) {
    world.mc.capabilities.insert(QStringLiteral("threadPullRequests"), false);
    world.mc.sendSnapshot();
    world.sync();
  });
  step(QStringLiteral("%1 has no linked pull request").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAt(world, c[0]);
    expect(model(world).count() == 0, describe(world));
  });
  step(QStringLiteral("the user can link one"), [](World& world, const Captures&, const Table&) {
    world.brick->click(QStringLiteral("emptyStateAction"));  // the empty state's "Link pull request"
    world.sync();
    expect(model(world).linkOpen(), QStringLiteral("the link field is closed"));
  });

  // The threads of one pull request, from its review.
  step(QStringLiteral("pull request (\\d+) is linked to %1 and to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAt(world, c[1]);
    setLinks(world, kThread, {linkOf(QStringLiteral("acme/shop"), c[0].toInt(), QStringLiteral("manual"))});
    addThread(world, QStringLiteral("thread-2"), c[2], {linkOf(QStringLiteral("acme/shop"), c[0].toInt(), QStringLiteral("manual"))});
    waitForRow(world, c[0].toInt(), true);
  });
  step(QStringLiteral("the user reads pull request (\\d+)"), [](World& world, const Captures& c, const Table&) {
    serveReview(world.mc);
    openReview(world, c[0].toInt());
  });
  step(QStringLiteral("choosing it searches the threads for pull request (\\d+)"), [](World& world, const Captures& c, const Table&) {
    reviewThreads(world).search();
    world.sync();
    auto* palette = world.native().controller<CommandPaletteController>();
    expect(palette->isOpen() && palette->query() == QStringLiteral("https://github.com/acme/shop/pull/") + c[0],
           QStringLiteral("the palette is %1 searching \"%2\"").arg(palette->isOpen() ? QStringLiteral("open") : QStringLiteral("closed"), palette->query()));
  });
  step(QStringLiteral("pull request (\\d+) is linked to no thread"), [](World& world, const Captures& c, const Table&) {
    lookAt(world, QStringLiteral("Tax work"));
    addThread(world, QStringLiteral("thread-2"), QStringLiteral("Tax review"), {});
    addThread(world, QStringLiteral("thread-3"), QStringLiteral("Old tax work"), {}, true);
    reviewUnlinked(world, c[0].toInt());
  });
  step(QStringLiteral("the user chooses to link pull request (\\d+) to a thread"), [](World& world, const Captures& c, const Table&) {
    if (reviewThreads(world).count() < 0 || !world.native().controller<RightPanelController>()->review()->key().endsWith(QLatin1Char('#') + c[0])) {
      serveReview(world.mc);
      openReview(world, c[0].toInt());
    }
    reviewThreads(world).setPickerOpen(true);
    expect(reviewThreads(world).pickerOpen(), describeThreads(world));
  });
  step(QStringLiteral("the user sees the active threads, newest first, with a way to search threads and projects"), [](World& world, const Captures&, const Table&) {
    PullRequestThreadLinks& links = reviewThreads(world);
    const auto titles = [&] {
      QStringList titles;
      for (const QVariant& candidate : links.candidates()) titles.append(candidate.toMap().value(QStringLiteral("title")).toString());
      return titles;
    };
    expect(titles() == QStringList{QStringLiteral("Tax review"), QStringLiteral("Tax work")}, describeThreads(world));
    links.setQuery(QStringLiteral("review"));
    expect(titles() == QStringList{QStringLiteral("Tax review")}, describeThreads(world));
    links.setQuery(kProject);
    expect(titles().size() == 2, describeThreads(world));
    links.setQuery(QString());
  });
  step(QStringLiteral("archived threads are not offered"), [](World& world, const Captures&, const Table&) {
    for (const QVariant& candidate : reviewThreads(world).candidates()) {
      expect(candidate.toMap().value(QStringLiteral("id")) != QLatin1String("thread-3"), describeThreads(world));
    }
  });
  step(QStringLiteral("%1 is shown as %1 and cannot be chosen").arg(q), [](World& world, const Captures& c, const Table&) {
    QVariantMap found;
    for (const QVariant& candidate : reviewThreads(world).candidates()) {
      if (candidate.toMap().value(QStringLiteral("title")) == c[0]) found = candidate.toMap();
    }
    expect(c[1] == QLatin1String("Linked") && found.value(QStringLiteral("linked")).toBool(), describeThreads(world));
    const int sent = linkCommands(world);
    reviewThreads(world).choose(found.value(QStringLiteral("id")).toString());
    world.sync();
    expect(linkCommands(world) == sent, QStringLiteral("a linked thread was chosen"));
  });
  step(QStringLiteral("the menu offers to unlink pull request (\\d+) from this thread"), [](World& world, const Captures&, const Table&) {
    expect(reviewThreads(world).menuLabel() == QLatin1String("Unlink from this thread"), describeThreads(world));
  });
  step(QStringLiteral("the MC refuses to (link|unlink) pull request (\\d+) (?:to|from) %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAt(world, c[2]);
    if (c[0] == QLatin1String("link")) {
      reviewUnlinked(world, c[1].toInt());
    } else {
      setLinks(world, kThread, {linkOf(QStringLiteral("acme/shop"), c[1].toInt(), QStringLiteral("manual"))});
      waitForRow(world, c[1].toInt(), true);
      serveReview(world.mc);
      openReview(world, c[1].toInt());
    }
    world.mc.refusals.insert(QStringLiteral("thread.pull-request.") + c[0], QStringLiteral("Thread is archived"));
  });
  step(QStringLiteral("the user tries to (link|unlink) pull request (\\d+) (?:to|from) %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(reviewThreads(world).linkedHere() == (c[0] == QLatin1String("unlink")), describeThreads(world));
    reviewThreads(world).toggleHere();
    world.sync();
  });

  // Two repositories' pull requests of one number.
  step(QStringLiteral("%1 links pull request (\\d+) of %1 and pull request (\\d+) of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAt(world, c[0]);
    setLinks(world, kThread, {linkOf(c[2], c[1].toInt(), QStringLiteral("manual")), linkOf(c[4], c[3].toInt(), QStringLiteral("manual"))});
    world.waitFor([&] { return model(world).count() == 2; }, [&] { return describe(world); });
  });
  step(QStringLiteral("the user looks at the thread's linked pull requests"), [](World& world, const Captures&, const Table&) { openPanel(world); });
  step(QStringLiteral("each row names its pull request's repository"), [](World& world, const Captures&, const Table&) {
    QStringList named;
    world.waitFor([&] {
      named.clear();
      for (int row = 0; row < model(world).rowCount(); ++row) {
        QList<QQuickItem*> rows;
        findAll(world.brick->window().contentItem(), QStringLiteral("pullRequestRow-%1").arg(model(world).value(row, ThreadPullRequests::NumberRole).toInt()), rows);
        for (QQuickItem* item : std::as_const(rows)) {
          const QString text = inRow(item, QStringLiteral("pullRequestRepository"))->property("text").toString();
          if (item->property("repository") == model(world).value(row, ThreadPullRequests::RepositoryRole) &&
              text.contains(model(world).value(row, ThreadPullRequests::RepositoryRole).toString())) {
            named.append(text);
          }
        }
      }
      return named.size() == 2;
    }, [&] { return describe(world) + QStringLiteral(", the rows say ") + named.join(QStringLiteral("; ")); });
  });
});

}  // namespace

// Other domains' phrases this tab answers too (PullRequestSteps.h).
bool pullRequestThreadChooses(World& world, const QString& what) {
  auto* panel = world.native().controller<RightPanelController>();
  if (!panel || !panel->reviewThreads()->pickerOpen()) return false;
  for (const QVariant& candidate : panel->reviewThreads()->candidates()) {
    if (candidate.toMap().value(QStringLiteral("title")) == what) {
      panel->reviewThreads()->choose(candidate.toMap().value(QStringLiteral("id")).toString());
      world.sync();
      return true;
    }
  }
  fail(QStringLiteral("the thread picker does not offer \"%1\"").arg(what));
  return false;
}

bool pullRequestReviewSays(World& world, const QString& what) {
  auto* panel = world.native().controller<RightPanelController>();
  if (!panel || !panel->reviewThreads()->available() || !what.startsWith(QLatin1String("Linked from"))) return false;
  world.waitFor([&] { return panel->reviewThreads()->label() == what; }, [&] { return describeThreads(world); });
  return true;
}

bool pullRequestCannotBeLinked(World& world) {
  if (world.mc.part<FakePullRequests>().thread.isEmpty()) return false;
  expect(!model(world).canLink() && linkCommands(world) == 0, describe(world));
  return true;
}
