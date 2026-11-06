// A thread's linked pull requests on the phone: the thread screen's Pull
// requests screen (the shared PullRequestsPanel over ThreadPullRequests),
// linking, unlinking and refreshing them as the MC does, linking one a message
// mentions, and starting a thread on a pull request
// (features/source-control/pull-request-threads.feature). The MC's side is the
// desktop harness's PullRequestSteps.cpp, for this runner's World.

#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>
#include <QUrl>

#include "FakeThreads.h"
#include "Harness.h"
#include "NativeShell.h"
#include "Phone.h"
#include "RightPanelController.h"
#include "ThreadPullRequests.h"
#include "World.h"

namespace {

#define S(text) QStringLiteral(text)

const QString kAt = S("2026-09-23T09:00:00Z");

// What GitHub holds of each pull request ("acme/shop#42"), the pull requests
// the MC was asked to read again, and the host's stack of them.
struct FakePullRequests {
  QHash<QString, QJsonObject> host{
      {S("acme/shop#42"),
       {{S("state"), S("open")}, {S("title"), S("Tax line fix")}, {S("headBranch"), S("feature/tax")}, {S("baseBranch"), S("main")},
        {S("isDraft"), false}, {S("author"), S("ada")}, {S("reviewDecision"), S("review-required")}, {S("checksState"), S("passing")},
        {S("mergeability"), S("mergeable")}, {S("syncedAt"), kAt}}},
      {S("acme/api#42"),
       {{S("state"), S("open")}, {S("title"), S("Tax API")}, {S("headBranch"), S("tax")}, {S("baseBranch"), S("main")},
        {S("isDraft"), false}, {S("author"), S("ada")}, {S("syncedAt"), kAt}}},
  };
  QString thread;
  QList<QJsonObject> invalidated;
  QList<int> stack;
};

QString hostKey(const QJsonObject& reference) {
  return S("%1#%2").arg(reference.value(QLatin1String("repository")).toString()).arg(reference.value(QLatin1String("number")).toInt());
}

// The thread's links, each with what the host last said of it: the MC's sync.
void syncLinks(FakeMc& mc, const QString& threadId) {
  if (!mc.threads.contains(threadId)) return;
  const FakePullRequests& fake = mc.part<FakePullRequests>();
  QJsonArray links;
  for (const QJsonValue& value : mc.threads.value(threadId).value(QLatin1String("pullRequests")).toArray()) {
    QJsonObject link = value.toObject();
    const QJsonObject snapshot = fake.host.value(hostKey(link));
    link.insert(S("snapshot"), snapshot.isEmpty() ? QJsonValue() : QJsonValue(snapshot));
    if (fake.stack.contains(link.value(QLatin1String("number")).toInt())) {
      QJsonArray layers;
      for (const int number : fake.stack) {
        layers.append(QJsonObject{{S("number"), number}, {S("headBranch"), S("stack/%1").arg(number)}, {S("state"), S("open")}});
      }
      link.insert(S("stack"), QJsonObject{{S("kind"), S("native")}, {S("id"), S("stack-1")}, {S("number"), 1},
                                          {S("url"), S("https://github.com/acme/shop/stacks/1")}, {S("base"), S("main")}, {S("layers"), layers}});
    }
    links.append(link);
  }
  updateRow(mc, threadId, {{S("pullRequests"), links}});
}

QJsonObject linkOf(const QString& repository, int number) {
  return {{S("host"), S("github.com")}, {S("repository"), repository}, {S("number"), number},
          {S("url"), S("https://github.com/%1/pull/%2").arg(repository).arg(number)}, {S("source"), S("manual")},
          {S("linkedAt"), S("2026-09-23T09:05:00Z")}, {S("snapshot"), QJsonValue()}, {S("stack"), QJsonValue()}};
}

const FakeMc::Extension pullRequests([](FakeMc& mc) {
  mc.effects.append([&mc](const QJsonObject& command) {
    const QString type = command.value(QLatin1String("type")).toString();
    if (type != QLatin1String("thread.pull-request.link") && type != QLatin1String("thread.pull-request.unlink")) return;
    const QString threadId = command.value(QLatin1String("threadId")).toString();
    QJsonArray links;
    bool known = false;
    for (const QJsonValue& value : mc.threads.value(threadId).value(QLatin1String("pullRequests")).toArray()) {
      const QJsonObject link = value.toObject();
      const bool same = hostKey(link) == hostKey(command) && link.value(QLatin1String("host")) == command.value(QLatin1String("host"));
      known = known || same;
      if (!(same && type == QLatin1String("thread.pull-request.unlink"))) links.append(link);
    }
    if (type == QLatin1String("thread.pull-request.link") && !known) {
      links.append(QJsonObject{{S("host"), command.value(QLatin1String("host"))}, {S("repository"), command.value(QLatin1String("repository"))},
                               {S("number"), command.value(QLatin1String("number"))}, {S("url"), command.value(QLatin1String("url"))},
                               {S("source"), command.value(QLatin1String("source"))}, {S("linkedAt"), S("2026-09-23T09:05:00Z")},
                               {S("snapshot"), QJsonValue()}, {S("stack"), QJsonValue()}});
    }
    mc.threads[threadId].insert(S("pullRequests"), links);
    // The MC reads a new link from its host at once (Sync.request).
    syncLinks(mc, threadId);
  });
  mc.onRpc(S("pullRequests.invalidate"), [&mc](const FakeMc::Rpc& rpc) {
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
    rows.append(S("%1 \"%2\" %3").arg(prs.value(row, ThreadPullRequests::KeyRole).toString(), prs.value(row, ThreadPullRequests::TitleRole).toString(),
                                      prs.value(row, ThreadPullRequests::ReviewLabelRole).toString()));
  }
  return S("the phone lists %1 (%2, problem \"%3\"); the screen says: %4")
      .arg(rows.isEmpty() ? S("nothing") : rows.join(S("; ")), prs.online() ? S("online") : S("offline"), prs.problem(), world.texts().join(S(" | ")));
}

// The row of pull request `number` on the screen, or null.
QQuickItem* rowOf(World& world, int number) {
  return world.find(S("pullRequestRow-%1").arg(number));
}

void waitForRow(World& world, int number, bool listed) {
  world.waitFor([&] { return (rowOf(world, number) != nullptr) == listed; }, [&] { return describe(world); });
}

// The user is in the thread `title` of "acme/shop".
void inThread(World& world, const QString& title) {
  FakePullRequests& fake = world.mc.part<FakePullRequests>();
  if (!fake.thread.isEmpty()) return;
  fake.thread = world.thread = haveThread(world, title);
  updateRow(world.mc, world.thread, {{S("pullRequests"), QJsonArray()}});
  openThread(world, title);
}

// And on its Pull requests screen, reached from the thread's bar.
void pullRequestsScreen(World& world, const QString& title) {
  inThread(world, title);
  if (!world.find(S("pullRequestsPanel"))) world.tap(S("openPullRequests"));
  world.item(S("pullRequestsPanel"));
}

// The user links what `text` names from the screen's field.
void link(World& world, const QString& text) {
  pullRequestsScreen(world, S("Tax work"));
  if (!world.find(S("pullRequestsLinkField"))) world.tap(S("pullRequestsLink"));
  world.tap(world.item(S("pullRequestsLinkField")));
  // What a refused link left in the field gives way to the new one.
  world.press(S("mod+A"));
  world.type(text);
  world.press(S("Return"));
  world.sync();
}

// The row's menu, and its entry `objectName` in it.
QQuickItem* rowAction(World& world, int number, const QString& objectName) {
  QQuickItem* row = rowOf(world, number);
  if (!row) fail(describe(world));
  QQuickItem* menu = nullptr;
  const std::function<void(QQuickItem*)> find = [&](QQuickItem* item) {
    if (item->objectName() == QLatin1String("pullRequestMenu")) menu = item;
    for (QQuickItem* child : item->childItems()) find(child);
  };
  find(row);
  expect(menu != nullptr, S("pull request %1 has no menu").arg(number));
  world.tap(menu);
  return world.item(objectName);
}

void setOnline(World& world, bool online) {
  world.mc.send({{S("t"), S("shell.mc")}, {S("id"), world.mc.subscribers(S("shell")).value(0)}, {S("mc"), world.mc.name}, {S("online"), online}});
  world.sync();
  world.waitFor([&] { return model(world).online() == online; }, [&] { return describe(world); });
}

bool enabled(World& world, const QString& objectName) {
  return world.item(objectName)->isEnabled();
}

QList<QJsonObject> asked(World& world, const QString& method) {
  QList<QJsonObject> found;
  for (const FakeMc::Rpc& rpc : std::as_const(world.mc.calls)) {
    if (rpc.method == method) found.append(rpc.payload);
  }
  return found;
}

const Steps steps([] {
  const QString q = kQuoted;

  step(S("a connected environment with the GitHub project %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.projects[S("shop")].insert(S("repositoryIdentity"), QJsonObject{{S("canonicalKey"), S("github.com/") + c[0]}, {S("displayName"), c[0]}});
    pairWithEnvironment(world);
    world.sync();
  });
  step(S("the environment also has the Azure DevOps project %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject row{{S("id"), S("azure-web")}, {S("title"), S("azure-web")}, {S("workspaceRoot"), S("/work/azure-web")}, {S("scripts"), QJsonArray()},
                          {S("repositoryIdentity"), QJsonObject{{S("canonicalKey"), c[0]}}}};
    world.mc.projects.insert(S("azure-web"), row);
    world.mc.sendRow(S("azure-web"), row, S("project"));
    world.sync();
  });
  step(S("the thread %1 has no linked pull request").arg(q), [](World& world, const Captures& c, const Table&) {
    pullRequestsScreen(world, c[0]);
    expect(model(world).count() == 0, describe(world));
  });
  step(S("pull request (\\d+) is linked to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    pullRequestsScreen(world, c[1]);
    world.mc.threads[world.thread].insert(S("pullRequests"), QJsonArray{linkOf(S("acme/shop"), c[0].toInt())});
    syncLinks(world.mc, world.thread);
    world.sync();
    waitForRow(world, c[0].toInt(), true);
  });
  step(S("%1 links pull request (\\d+) of %1 and pull request (\\d+) of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    inThread(world, c[0]);
    world.mc.threads[world.thread].insert(S("pullRequests"), QJsonArray{linkOf(c[2], c[1].toInt()), linkOf(c[4], c[3].toInt())});
    syncLinks(world.mc, world.thread);
    world.sync();
  });
  step(S("the MC refuses to link pull requests to %1").arg(q), [](World& world, const Captures&, const Table&) {
    world.mc.refusals.insert(S("thread.pull-request.link"), S("Thread is archived"));
  });
  step(S("a review is submitted on pull request (\\d+) on GitHub"), [](World& world, const Captures& c, const Table&) {
    world.mc.part<FakePullRequests>().host[S("acme/shop#") + c[0]].insert(S("reviewDecision"), S("approved"));
  });
  step(S("the environment of %1 becomes unreachable").arg(q), [](World& world, const Captures&, const Table&) { setOnline(world, false); });
  step(S("the environment of %1 is reachable again").arg(q), [](World& world, const Captures&, const Table&) { setOnline(world, true); });

  step(S("the user links pull request (\\d+) to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    pullRequestsScreen(world, c[1]);
    link(world, c[0]);
  });
  step(S("the user links %1").arg(q), [](World& world, const Captures& c, const Table&) { link(world, c[0]); });
  step(S("the user opens pull request (\\d+) from %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.tap(world.item(S("pullRequestRow-") + c[0]));
  });
  step(S("the user refreshes the pull requests of %1").arg(q), [](World& world, const Captures&, const Table&) {
    world.tap(S("pullRequestsRefresh"));
    world.sync();
  });
  step(S("the user looks at the thread's linked pull requests"), [](World& world, const Captures&, const Table&) {
    world.tap(S("openPullRequests"));
    world.item(S("pullRequestsPanel"));
  });
  step(S("the user opens the git overview of %1 on the phone").arg(q), [](World& world, const Captures& c, const Table&) {
    // GitHub holds 42 as the middle layer of a stack the MC has synced; the
    // thread is on its Pull requests screen already, so back to it, then in again.
    pullRequestsScreen(world, c[0]);
    world.mc.part<FakePullRequests>().stack = {41, 42, 43};
    syncLinks(world.mc, world.thread);
    world.sync();
    world.back();
    world.waitFor([&] { return world.find(S("pullRequestsPanel")) == nullptr && world.find(S("composer")) != nullptr; },
                  [&] { return S("the thread; the screen says: %1").arg(world.texts().join(S(" | "))); });
    world.tap(S("openPullRequests"));
    world.item(S("pullRequestsPanel"));
  });

  // Outcomes.
  step(S("the browser opens %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return world.openedUrls.contains(QUrl(c[0])); },
                  [&] { return S("the browser to open %1; it opened %2").arg(c[0], QUrl::toStringList(world.openedUrls).join(S(", "))); });
  });
  step(S("%1 lists pull request (\\d+) of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForRow(world, c[1].toInt(), true);
    expect(world.shows(S("%1 #%2").arg(c[2], c[1]), false) && model(world).problem().isEmpty(), describe(world));
  });
  step(S("%1 lists pull request (\\d+)").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForRow(world, c[1].toInt(), true);
    world.waitFor([&] { return world.shows(S("Tax line fix")); }, [&] { return describe(world); });
  });
  step(S("%1 lists no pull requests").arg(q), [](World& world, const Captures&, const Table&) {
    expect(model(world).count() == 0 && world.find(S("pullRequestsEmpty")) != nullptr, describe(world));
  });
  step(S("%1 still lists pull request (\\d+)").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(rowOf(world, c[1].toInt()) != nullptr && world.find(S("pullRequestsOffline")) != nullptr, describe(world));
  });
  step(S("%1 shows the new review state").arg(q), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.shows(S("Approved")); }, [&] { return describe(world); });
    world.waitFor([&] { return enabled(world, S("pullRequestsRefresh")); }, S("the refresh to finish"));
  });
  step(S("pull request (\\d+) is read from GitHub again"), [](World& world, const Captures& c, const Table&) {
    const QList<QJsonObject>& invalidated = world.mc.part<FakePullRequests>().invalidated;
    expect(invalidated.size() == 1 &&
               invalidated.first() == QJsonObject{{S("host"), S("github.com")}, {S("repository"), S("acme/shop")}, {S("number"), c[0].toInt()}},
           S("the MC was asked to read %1 pull requests").arg(invalidated.size()));
  });
  step(S("the user is told no project in this environment can read %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return world.shows(S("No project in this environment can read %1.").arg(c[0])); }, [&] { return describe(world); });
    for (const QJsonObject& command : std::as_const(world.mc.commands)) {
      expect(command.value(QLatin1String("type")) != QLatin1String("thread.pull-request.link"), S("the link was sent"));
    }
  });
  step(S("the user is told pull request (\\d+) could not be linked"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.shows(S("Could not link the pull request: Thread is archived")); }, [&] { return describe(world); });
    expect(world.find(S("pullRequestsLinkField")) != nullptr, S("the link field closed"));
  });
  step(S("the user cannot link, unlink or refresh pull requests"), [](World& world, const Captures&, const Table&) {
    expect(!enabled(world, S("pullRequestsLink")) && !enabled(world, S("pullRequestsRefresh")), describe(world));
    expect(!rowAction(world, 42, S("pullRequestUnlink"))->isEnabled(), S("unlinking is offered offline"));
    world.press(S("Escape"));
  });
  step(S("the user can link, unlink and refresh pull requests"), [](World& world, const Captures&, const Table&) {
    world.tap(S("pullRequestsRefresh"));
    world.sync();
    expect(world.mc.part<FakePullRequests>().invalidated.size() == 1, S("the refresh was not sent"));
    world.tap(rowAction(world, 42, S("pullRequestUnlink")));
    world.sync();
    waitForRow(world, 42, false);
    link(world, S("42"));
    waitForRow(world, 42, true);
  });
  step(S("each row names its pull request's repository"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return model(world).count() == 2; }, [&] { return describe(world); });
    expect(world.shows(S("acme/shop · feature/tax → main")) && world.shows(S("acme/api · tax → main")), describe(world));
  });
  step(S("pull request (\\d+) is listed with its stack"), [](World& world, const Captures& c, const Table&) {
    waitForRow(world, c[0].toInt(), true);
    expect(world.shows(S("Layer 2 of 3"), false), describe(world));
  });

  // A thread started on a pull request the user names (PullRequestThreadController).
  step(S("the user pastes %1 to start a pull request thread").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject pullRequest{{S("number"), 42}, {S("title"), S("Add tax to the cart")}, {S("url"), c[0]},
                                  {S("baseBranch"), S("main")}, {S("headBranch"), S("feature/tax")}, {S("state"), S("open")}};
    world.mc.onRpc(S("git.resolvePullRequest"), [&mc = world.mc, pullRequest](const FakeMc::Rpc& rpc) {
      mc.reply(rpc, QJsonObject{{S("pullRequest"), pullRequest}});
    });
    world.mc.onRpc(S("git.preparePullRequestThread"), [&mc = world.mc, pullRequest](const FakeMc::Rpc& rpc) {
      const bool worktree = rpc.payload.value(QLatin1String("mode")) == QLatin1String("worktree");
      mc.reply(rpc, QJsonObject{{S("pullRequest"), pullRequest}, {S("branch"), S("feature/tax")},
                                {S("worktreePath"), worktree ? QJsonValue(S("/work/worktrees/pr-42")) : QJsonValue()}, {S("isOnPullRequestHead"), true}});
    });
    pullRequestsScreen(world, S("Tax work"));
    world.tap(S("startPullRequestThread"));
    world.awaitPopup(S("pullRequestThreadDialog"));
    world.tap(world.item(S("pullRequestThreadReference")));
    world.type(c[0]);
    world.press(S("Return"));
    world.sync();
  });
  step(S("the user sees the pull request's title and branches before choosing local or worktree"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.shows(S("Add tax to the cart")) && world.shows(S("#42 · feature/tax to main")); },
                  [&] { return S("the pull request to be shown; the dialog is %1").arg(show(world.state(S("pullRequestThread")))); });
    const QList<QJsonObject> resolved = asked(world, S("git.resolvePullRequest"));
    expect(resolved.size() == 1 && resolved.first().value(QLatin1String("cwd")) == QLatin1String("/work/shop") &&
               resolved.first().value(QLatin1String("reference")) == QLatin1String("https://github.com/acme/shop/pull/42"),
           S("the MC was asked to resolve %1").arg(resolved.size()));
    world.item(S("pullRequestThreadLocal"));
    expect(asked(world, S("git.preparePullRequestThread")).isEmpty() && asked(world, S("orchestration.launchThread")).isEmpty(),
           S("the pull request was checked out before the user chose"));
    // Chosen, the worktree is prepared and the phone moves to the new thread in it.
    world.tap(S("pullRequestThreadWorktree"));
    world.waitFor([&] { return asked(world, S("orchestration.launchThread")).size() == 1; }, S("the thread to be started"));
    const QJsonObject prepared = asked(world, S("git.preparePullRequestThread")).value(0);
    const QJsonObject launched = asked(world, S("orchestration.launchThread")).first();
    expect(prepared.value(QLatin1String("mode")) == QLatin1String("worktree") && prepared.value(QLatin1String("threadId")) == launched.value(QLatin1String("threadId")) &&
               launched.value(QLatin1String("workspaceStrategy")).toObject().value(QLatin1String("worktreePath")) == QLatin1String("/work/worktrees/pr-42"),
           S("the MC was asked %1 then %2").arg(show(prepared.toVariantMap()), show(launched.toVariantMap())));
    world.waitFor([&] { return shownThread(world) == QLatin1String("#42 Add tax to the cart") && !world.popupShowing(S("pullRequestThreadDialog")); },
                  [&] { return S("the new thread to open; the screen says: %1").arg(world.texts().join(S(" | "))); });
  });

  // A pull request a message mentions, linked from that message.
  step(S("a message in %1 mentions %1").arg(q), [](World& world, const Captures& c, const Table&) {
    inThread(world, c[0]);
    const QString run = S("run-1");
    setEntity(world.mc, world.thread, S("run"), run, {{S("id"), run}, {S("ordinal"), 1}, {S("status"), S("completed")}});
    setEntity(world.mc, world.thread, S("turn-item"), S("message:") + run,
              {{S("id"), S("message:") + run}, {S("type"), S("assistant_message")}, {S("runId"), run}, {S("ordinal"), 2}, {S("status"), S("completed")},
               {S("text"), S("I opened %1 for the tax line.").arg(c[1])}, {S("updatedAt"), kAt}});
    world.sync();
  });
  step(S("the user links that pull request from the mention"), [](World& world, const Captures&, const Table&) {
    // The message's own button: other rows keep a hidden one.
    QQuickItem* button = nullptr;
    world.waitFor([&] { return (button = world.findWhere([](QQuickItem* item) {
                              return item->objectName() == QLatin1String("linkPullRequest") && item->isVisible();
                            })) != nullptr; },
                  S("the message to offer linking its pull request"));
    world.tap(button);
    world.sync();
  });
});

}  // namespace
