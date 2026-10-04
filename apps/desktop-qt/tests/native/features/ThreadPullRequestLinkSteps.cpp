// Pointing a thread at a pull request from the conversation, and what its
// Pull requests tab shows of the branch's own (features/threads/
// pull-request-links.feature). The links themselves are the MC's
// (PullRequestSteps.cpp projects `thread.pull-request.link` and `.unlink`);
// here the MC also puts the branch's pull request back once no link of the
// user's is left, as its sync does.

#include <QJsonArray>
#include <QJsonObject>

#include "Harness.h"
#include "MenuController.h"
#include "RightPanelController.h"
#include "Stream.h"
#include "ThreadPullRequests.h"
#include "World.h"

namespace {

const QString kId = QStringLiteral("t-cart");
const QString kLinkUrl = QStringLiteral("https://github.com/acme/shop/pull/41");

ThreadPullRequests& tab(World& world) {
  return *world.native().controller<RightPanelController>()->pullRequests();
}

QList<int> listed(World& world) {
  QList<int> numbers;
  for (int row = 0; row < tab(world).rowCount(); ++row) numbers.append(tab(world).value(row, ThreadPullRequests::NumberRole).toInt());
  return numbers;
}

QString describe(World& world) {
  QStringList numbers;
  for (const int number : listed(world)) numbers.append(QString::number(number));
  return QStringLiteral("the tab lists [%1] (problem \"%2\", notice \"%3\")").arg(numbers.join(QStringLiteral(", ")), tab(world).problem(), tab(world).notice());
}

QJsonObject link(int number, const QString& source) {
  return {{QStringLiteral("host"), QStringLiteral("github.com")}, {QStringLiteral("repository"), QStringLiteral("acme/shop")}, {QStringLiteral("number"), number},
          {QStringLiteral("url"), QStringLiteral("https://github.com/acme/shop/pull/%1").arg(number)}, {QStringLiteral("source"), source},
          {QStringLiteral("linkedAt"), QStringLiteral("2026-09-23T09:05:00Z")}, {QStringLiteral("snapshot"), QJsonValue()}, {QStringLiteral("stack"), QJsonValue()}};
}

const FakeMc::Extension branchPullRequests([](FakeMc& mc) {
  // The sync links the branch's pull request while the thread has no other.
  mc.effects.append([&mc](const QJsonObject& command) {
    if (command.value(QLatin1String("type")) != QLatin1String("thread.pull-request.unlink")) return;
    const QString id = command.value(QLatin1String("threadId")).toString();
    QJsonObject row = mc.threads.value(id);
    const QJsonObject branch = row.value(QLatin1String("branchPullRequest")).toObject();
    if (branch.isEmpty() || !row.value(QLatin1String("pullRequests")).toArray().isEmpty()) return;
    row.insert(QStringLiteral("pullRequests"), QJsonArray{link(branch.value(QLatin1String("number")).toInt(), QStringLiteral("created"))});
    mc.threads.insert(id, row);
    mc.sendRow(id, row);
  });
});

void showTab(World& world) {
  world.bridge().dispatch(QStringLiteral("rightPanel.add"), QVariantMap{{QStringLiteral("kind"), QStringLiteral("pull-requests")}});
  world.sync();
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("a connected environment with the thread %1 on the branch %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.projects.insert(QStringLiteral("shop"), {{QStringLiteral("id"), QStringLiteral("shop")}, {QStringLiteral("title"), QStringLiteral("shop")},
                                                        {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")}, {QStringLiteral("scripts"), QJsonArray()},
                                                        {QStringLiteral("repositoryIdentity"),
                                                         QJsonObject{{QStringLiteral("canonicalKey"), QStringLiteral("github.com/acme/shop")},
                                                                     {QStringLiteral("locator"), QJsonObject{{QStringLiteral("source"), QStringLiteral("git-remote")},
                                                                                                             {QStringLiteral("remoteName"), QStringLiteral("origin")},
                                                                                                             {QStringLiteral("remoteUrl"), QStringLiteral("https://github.com/acme/shop.git")}}},
                                                                     {QStringLiteral("provider"), QStringLiteral("github")}, {QStringLiteral("owner"), QStringLiteral("acme")},
                                                                     {QStringLiteral("name"), QStringLiteral("shop")}}}});
    world.mc.threads.insert(kId, {{QStringLiteral("id"), kId}, {QStringLiteral("title"), c[0]}, {QStringLiteral("projectId"), QStringLiteral("shop")},
                                  {QStringLiteral("branch"), c[1]}, {QStringLiteral("pullRequests"), QJsonArray()},
                                  {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")}, {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}});
    world.connect();
    world.sync();
    stream::FakeStreams& streams = world.mc.part<stream::FakeStreams>();
    streams.thread = kId;
    streams.environment = world.mc.environmentId;
    stream::look(world, world.mc.environmentId + QLatin1Char(':') + kId);
  });

  // From a link in the conversation.
  step(QStringLiteral("%1 shows a link to pull request (\\d+)").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(c[1].toInt() == 41 && listed(world).isEmpty(), describe(world));
    // The secondary button on the link, as Markdown.qml reports it.
    world.bridge().dispatch(QStringLiteral("link.menu"), QVariantMap{{QStringLiteral("url"), kLinkUrl}, {QStringLiteral("x"), 300}, {QStringLiteral("y"), 200}});
  });
  step(QStringLiteral("the user links pull request (\\d+) to the thread from that link"), [](World& world, const Captures&, const Table&) {
    const QVariant menu = world.state(QStringLiteral("menu"));
    bool offered = false;
    for (const QVariant& item : at(menu, QStringLiteral("items")).toList()) offered |= item.toMap().value(QStringLiteral("id")) == QLatin1String("link-pull-request");
    expect(offered, QStringLiteral("the link's menu is %1").arg(show(menu)));
    world.bridge().dispatch(QStringLiteral("menu.select"),
                            QVariantMap{{QStringLiteral("requestId"), at(menu, QStringLiteral("requestId"))}, {QStringLiteral("id"), QStringLiteral("link-pull-request")}});
  });
  step(QStringLiteral("%1 is linked to pull request (\\d+)").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return listed(world) == QList<int>{c[1].toInt()}; }, [&] { return describe(world); });
    bool sent = false;
    for (const QJsonObject& command : std::as_const(world.mc.commands)) {
      sent |= command.value(QLatin1String("type")) == QLatin1String("thread.pull-request.link") && command.value(QLatin1String("threadId")) == kId &&
              command.value(QLatin1String("number")).toInt() == c[1].toInt() && command.value(QLatin1String("source")) == QLatin1String("manual");
    }
    expect(sent, QStringLiteral("the MC has %1").arg(world.describeCommands()));
  });

  // Unlinking.
  step(QStringLiteral("%1 was linked by hand to pull request (\\d+)").arg(q), [](World& world, const Captures& c, const Table&) {
    QJsonObject row = world.mc.threads.value(kId);
    // The branch has its own pull request, 40; the user's link took its place.
    row.insert(QStringLiteral("branchPullRequest"), QJsonObject{{QStringLiteral("host"), QStringLiteral("github.com")}, {QStringLiteral("repository"), QStringLiteral("acme/shop")},
                                                                {QStringLiteral("number"), 40}, {QStringLiteral("url"), QStringLiteral("https://github.com/acme/shop/pull/40")}});
    row.insert(QStringLiteral("pullRequests"), QJsonArray{link(c[1].toInt(), QStringLiteral("manual"))});
    world.mc.threads.insert(kId, row);
    world.mc.sendRow(kId, row);
    showTab(world);
    world.waitFor([&] { return listed(world) == QList<int>{c[1].toInt()}; }, [&] { return describe(world); });
  });
  step(QStringLiteral("the user unlinks pull request (\\d+) from the thread"), [](World& world, const Captures& c, const Table&) {
    for (int row = 0; row < tab(world).rowCount(); ++row) {
      if (tab(world).value(row, ThreadPullRequests::NumberRole).toInt() == c[0].toInt()) {
        tab(world).unlink(tab(world).value(row, ThreadPullRequests::KeyRole).toString());
        return;
      }
    }
    fail(describe(world));
  });
  step(QStringLiteral("%1 shows the pull request for %1 again").arg(q), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return listed(world) == QList<int>{40}; }, [&] { return describe(world); });
  });

  // An environment too old for branch pull requests.
  step(QStringLiteral("the environment does not look for branch pull requests"), [](World& world, const Captures&, const Table&) {
    world.mc.capabilities.insert(QStringLiteral("threadPullRequests"), false);
    world.mc.sendSnapshot();
    world.sync();
  });
  step(QStringLiteral("the user looks at %1").arg(q), [](World& world, const Captures&, const Table&) { showTab(world); });
  step(QStringLiteral("the user is told to update the server to see branch pull requests"), [](World& world, const Captures&, const Table&) {
    // PullRequestsPanel.qml shows the tab's notice.
    expect(tab(world).notice() == QLatin1String("Update this environment's server to see branch pull requests."), describe(world));
  });
});

}  // namespace
