// The pull requests page on the desktop (PullRequestListController), and the
// MC's side of it: the @desktop scenarios of
// features/source-control/pull-request-list.feature.

#include <QJsonArray>
#include <QJsonObject>

#include "Harness.h"
#include "World.h"

namespace {

const QString kViewer = QStringLiteral("sam");

// The pull requests the MC lists, as apps/server-ex HalC2.PullRequests
// answers `pullRequests.*` for its own environment. Another member has none
// of them.
struct FakePullRequests {
  QJsonArray entries;
  QString refusal;
  // Thread ids by pull request number, for `pullRequests.linkedThreads`.
  QHash<int, QJsonArray> linked;
  int revision = 0;
  QList<QPair<QString, QJsonObject>> calls;
};

QJsonObject entry(const QString& project, int number, const QString& title, const QString& author, const QString& state,
                  bool draft = false, bool reviewRequested = false) {
  return {
      {QStringLiteral("provider"), QStringLiteral("github")},
      {QStringLiteral("host"), QStringLiteral("github.com")},
      {QStringLiteral("projectId"), project},
      {QStringLiteral("projectTitle"), project},
      {QStringLiteral("repository"), project},
      {QStringLiteral("number"), number},
      {QStringLiteral("title"), title},
      {QStringLiteral("url"), QStringLiteral("https://github.com/%1/pull/%2").arg(project).arg(number)},
      {QStringLiteral("author"), QJsonObject{{QStringLiteral("login"), author}}},
      {QStringLiteral("headBranch"), QStringLiteral("topic-%1").arg(number)},
      {QStringLiteral("baseBranch"), QStringLiteral("main")},
      {QStringLiteral("state"), state},
      {QStringLiteral("isDraft"), draft},
      {QStringLiteral("mergeability"), QStringLiteral("mergeable")},
      {QStringLiteral("additions"), 10},
      {QStringLiteral("deletions"), 2},
      {QStringLiteral("createdAt"), QStringLiteral("2026-09-20T10:00:00Z")},
      {QStringLiteral("updatedAt"), QStringLiteral("2026-09-2%1T10:00:00Z").arg(number % 10)},
      {QStringLiteral("viewerReviewRequested"), reviewRequested},
      {QStringLiteral("labels"), QJsonArray()},
  };
}

QJsonObject list(FakeMc& mc, const FakeMc::Rpc& rpc) {
  const FakePullRequests& fake = mc.part<FakePullRequests>();
  const QString state = rpc.payload.value(QLatin1String("state")).toString();
  const QString involvement = rpc.payload.value(QLatin1String("involvement")).toString();
  const QString draft = rpc.payload.value(QLatin1String("filters")).toObject().value(QLatin1String("draft")).toString();
  const QString project = rpc.payload.value(QLatin1String("projectId")).toString();
  QJsonArray entries;
  if (rpc.environment == mc.environmentId) {
    for (const QJsonValue& value : fake.entries) {
      const QJsonObject pr = value.toObject();
      const bool isDraft = pr.value(QLatin1String("isDraft")).toBool();
      const QString login = pr.value(QLatin1String("author")).toObject().value(QLatin1String("login")).toString();
      if (state != QLatin1String("all") && pr.value(QLatin1String("state")).toString() != state) continue;
      if (involvement == QLatin1String("authored") && login != kViewer) continue;
      if (involvement == QLatin1String("reviewing") && !pr.value(QLatin1String("viewerReviewRequested")).toBool()) continue;
      if ((draft == QLatin1String("only") && !isDraft) || (draft == QLatin1String("hide") && isDraft)) continue;
      if (!project.isEmpty() && pr.value(QLatin1String("projectId")).toString() != project) continue;
      entries.append(pr);
    }
  }
  return {{QStringLiteral("viewers"), QJsonObject{{QStringLiteral("github.com"), kViewer}}},
          {QStringLiteral("providers"), QJsonArray()},
          {QStringLiteral("entries"), entries},
          {QStringLiteral("errors"), QJsonArray()},
          {QStringLiteral("truncated"), false},
          {QStringLiteral("nextCursors"), QJsonObject()}};
}

void sendRevision(FakeMc& mc, int id) {
  mc.send({{QStringLiteral("t"), QStringLiteral("pullRequestRefreshes")},
             {QStringLiteral("id"), id},
             {QStringLiteral("revision"), mc.part<FakePullRequests>().revision}});
}

const FakeMc::Extension extension([](FakeMc& mc) {
  mc.onRpc(QStringLiteral("pullRequests."), [&mc](const FakeMc::Rpc& rpc) {
    FakePullRequests& fake = mc.part<FakePullRequests>();
    fake.calls.append({rpc.method, rpc.payload});
    if (rpc.method == QLatin1String("pullRequests.list")) {
      if (!fake.refusal.isEmpty() && rpc.environment == mc.environmentId) {
        mc.refuse(rpc, fake.refusal, {{QStringLiteral("_tag"), QStringLiteral("PullRequestUnavailableError")}});
        return;
      }
      mc.reply(rpc, list(mc, rpc));
    } else if (rpc.method == QLatin1String("pullRequests.invalidate")) {
      ++fake.revision;
      mc.reply(rpc, QJsonObject());
      for (const int id : mc.subscribers(QStringLiteral("pullRequestRefreshes"))) sendRevision(mc, id);
    } else if (rpc.method == QLatin1String("pullRequests.linkedThreads")) {
      mc.reply(rpc, QJsonObject{{QStringLiteral("threads"), fake.linked.value(rpc.payload.value(QLatin1String("number")).toInt())}});
    } else {
      mc.reply(rpc, QJsonValue::Null);
    }
  });
  mc.onShape(QStringLiteral("pullRequestRefreshes"), [&mc](int id, const QJsonObject&) { sendRevision(mc, id); });
});

FakePullRequests& fake(World& world) {
  return world.mc.part<FakePullRequests>();
}

QVariantMap page(World& world) {
  return world.state(QStringLiteral("pullRequestList")).toMap();
}

// The listed rows as "<repository>#<number>".
QStringList listed(World& world) {
  QStringList rows;
  for (const QVariant& group : page(world).value(QStringLiteral("groups")).toList()) {
    for (const QVariant& row : group.toMap().value(QStringLiteral("rows")).toList()) {
      rows.append(QStringLiteral("%1#%2").arg(row.toMap().value(QStringLiteral("repository")).toString())
                      .arg(row.toMap().value(QStringLiteral("number")).toInt()));
    }
  }
  return rows;
}

QString rowKey(World& world, int number) {
  for (const QVariant& group : page(world).value(QStringLiteral("groups")).toList()) {
    for (const QVariant& row : group.toMap().value(QStringLiteral("rows")).toList()) {
      if (row.toMap().value(QStringLiteral("number")).toInt() == number) return row.toMap().value(QStringLiteral("key")).toString();
    }
  }
  fail(QStringLiteral("#%1 is not listed: %2").arg(number).arg(show(page(world))));
}

int calls(World& world, const QString& method) {
  int count = 0;
  for (const auto& [called, payload] : fake(world).calls) count += called == method ? 1 : 0;
  return count;
}

void openPage(World& world) {
  world.bridge().dispatch(QStringLiteral("pullRequests.open"), {});
  world.waitFor([&] { return page(world).value(QStringLiteral("open")).toBool() && !page(world).value(QStringLiteral("loading")).toBool(); },
                [&] { return QStringLiteral("the pull requests page to load; it is %1").arg(show(page(world))); });
}

void expectListed(World& world, const QStringList& wanted) {
  world.waitFor([&] {
    QStringList now = listed(world);
    QStringList expected = wanted;
    std::sort(now.begin(), now.end());
    std::sort(expected.begin(), expected.end());
    return now == expected && !page(world).value(QStringLiteral("loading")).toBool();
  }, [&] { return QStringLiteral("%1 to be listed; the page is %2").arg(wanted.join(QStringLiteral(", ")), show(page(world))); });
}

const QStringList kOpen{QStringLiteral("acme/shop#12"), QStringLiteral("acme/api#7"), QStringLiteral("acme/api#9")};

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("a connected environment with the GitHub projects %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    for (const QString& name : c) {
      world.mc.projects.insert(name, {{QStringLiteral("id"), name},
                                        {QStringLiteral("title"), name},
                                        {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + name},
                                        {QStringLiteral("scripts"), QJsonArray()}});
    }
    fake(world).entries = {
        entry(c[0], 12, QStringLiteral("Fix tax rounding"), QStringLiteral("octocat"), QStringLiteral("open")),
        entry(c[1], 7, QStringLiteral("Add rate limits"), kViewer, QStringLiteral("open")),
        entry(c[1], 9, QStringLiteral("Retry webhooks"), QStringLiteral("hubot"), QStringLiteral("open"), true, true),
        entry(c[0], 3, QStringLiteral("Drop the old cart"), kViewer, QStringLiteral("merged")),
    };
    world.connect();
    world.sync();
  });
  // The MC's own gh is the fake's; nothing to set up on the desktop.
  step(QStringLiteral("the GitHub CLI is installed and signed in"), [](World&, const Captures&, const Table&) {});

  step(QStringLiteral("the user opens the pull requests page"), [](World& world, const Captures&, const Table&) {
    openPage(world);
  });
  step(QStringLiteral("the user is on the pull requests page"), [](World& world, const Captures&, const Table&) {
    openPage(world);
    expectListed(world, kOpen);
  });
  step(QStringLiteral("pull requests from every project are listed with state, involvement, project and filter choices"),
       [](World& world, const Captures&, const Table&) {
         expectListed(world, kOpen);
         const QVariantMap now = page(world);
         const QVariantMap filters = now.value(QStringLiteral("filters")).toMap();
         expect(filters.value(QStringLiteral("state")) == QLatin1String("open") &&
                    filters.value(QStringLiteral("involvement")) == QLatin1String("all") && filters.contains(QStringLiteral("draft")) &&
                    filters.contains(QStringLiteral("review")) && filters.contains(QStringLiteral("checks")),
                QStringLiteral("the filters are %1").arg(show(filters)));
         QStringList projects;
         for (const QVariant& project : now.value(QStringLiteral("projects")).toList()) projects.append(project.toMap().value(QStringLiteral("label")).toString());
         expect(projects.contains(QStringLiteral("acme/shop")) && projects.contains(QStringLiteral("acme/api")),
                QStringLiteral("the project choices are %1").arg(projects.join(QStringLiteral(", "))));
         QStringList groups;
         for (const QVariant& group : now.value(QStringLiteral("groups")).toList()) groups.append(group.toMap().value(QStringLiteral("label")).toString());
         expect(groups == QStringList{QStringLiteral("Authored"), QStringLiteral("Review requested"), QStringLiteral("Others")},
                QStringLiteral("the groups are %1").arg(groups.join(QStringLiteral(", "))));
       });
  step(QStringLiteral("the user's filter choices are kept for next time"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("pullRequestList.filter"),
                            QVariantMap{{QStringLiteral("name"), QStringLiteral("involvement")}, {QStringLiteral("value"), QStringLiteral("authored")}});
    expectListed(world, {QStringLiteral("acme/api#7")});
    world.restart();
    world.connect();
    world.waitFor([&] { return at(page(world), QStringLiteral("filters.involvement")) == QLatin1String("authored"); },
                  [&] { return QStringLiteral("the choice to be kept; after a restart the page is %1").arg(show(page(world))); });
  });

  step(QStringLiteral("the user filters pull requests to (drafts only|drafts hidden|merged ones|open ones)"),
       [](World& world, const Captures& c, const Table&) {
         const auto filter = [&](const QString& name, const QString& value) {
           world.bridge().dispatch(QStringLiteral("pullRequestList.filter"),
                                   QVariantMap{{QStringLiteral("name"), name}, {QStringLiteral("value"), value}});
         };
         if (c[0] == QLatin1String("drafts only")) filter(QStringLiteral("draft"), QStringLiteral("only"));
         else if (c[0] == QLatin1String("drafts hidden")) filter(QStringLiteral("draft"), QStringLiteral("hide"));
         else if (c[0] == QLatin1String("merged ones")) filter(QStringLiteral("state"), QStringLiteral("merged"));
         else filter(QStringLiteral("state"), QStringLiteral("open"));
       });
  step(QStringLiteral("no pull request matches the chosen filters"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("pullRequestList.filter"),
                            QVariantMap{{QStringLiteral("name"), QStringLiteral("state")}, {QStringLiteral("value"), QStringLiteral("closed")}});
  });
  step(QStringLiteral("the projects have no pull requests"), [](World& world, const Captures&, const Table&) {
    fake(world).entries = {};
  });
  step(QStringLiteral("the user is told %1 and to widen the filters").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return at(page(world), QStringLiteral("empty.title")) == c[0]; },
                  [&] { return QStringLiteral("the page to say \"%1\"; it is %2").arg(c[0], show(page(world))); });
    expect(at(page(world), QStringLiteral("empty.body")).toString().contains(QLatin1String("Widen")),
           QStringLiteral("the page is %1").arg(show(page(world))));
  });
  step(QStringLiteral("the pull requests page says %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const auto says = [&] {
      const QVariantMap now = page(world);
      return at(now, QStringLiteral("empty.title")) == c[0] || at(now, QStringLiteral("error.title")) == c[0] ||
             at(now, QStringLiteral("notice.text")) == c[0] || now.value(QStringLiteral("problems")).toStringList().contains(c[0]);
    };
    world.waitFor(says, [&] { return QStringLiteral("the page to say \"%1\"; it is %2").arg(c[0], show(page(world))); });
  });
  step(QStringLiteral("the (open|merged|draft|non-draft) pull requests are listed"), [](World& world, const Captures& c, const Table&) {
    if (c[0] == QLatin1String("open")) expectListed(world, kOpen);
    else if (c[0] == QLatin1String("merged")) expectListed(world, {QStringLiteral("acme/shop#3")});
    else if (c[0] == QLatin1String("draft")) expectListed(world, {QStringLiteral("acme/api#9")});
    else expectListed(world, {QStringLiteral("acme/shop#12"), QStringLiteral("acme/api#7")});
  });

  // Environments and failures.
  step(QStringLiteral("the MC cannot list pull requests, saying %1").arg(q), [](World& world, const Captures& c, const Table&) {
    fake(world).refusal = c[0];
  });
  step(QStringLiteral("the MC can list pull requests again"), [](World& world, const Captures&, const Table&) {
    fake(world).refusal.clear();
  });
  step(QStringLiteral("the pull requests page shows the error %1 with a retry").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return at(page(world), QStringLiteral("error.message")) == c[0]; },
                  [&] { return QStringLiteral("the page to show the error; it is %1").arg(show(page(world))); });
    expect(at(page(world), QStringLiteral("error.title")) == QLatin1String("Could not load pull requests") && listed(world).isEmpty(),
           QStringLiteral("the page is %1").arg(show(page(world))));
  });
  step(QStringLiteral("the user (?:refreshes|retries) the pull requests page"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("pullRequestList.refresh"), {});
  });
  step(QStringLiteral("the MC forgets what it knew and the list is read again"), [](World& world, const Captures&, const Table&) {
    const int before = calls(world, QStringLiteral("pullRequests.list"));
    world.waitFor([&] { return calls(world, QStringLiteral("pullRequests.list")) > before; },
                  [&] { return QStringLiteral("the list to be read again"); });
    expect(calls(world, QStringLiteral("pullRequests.invalidate")) >= 1, QStringLiteral("the MC was not asked to forget"));
  });
  step(QStringLiteral("a pull request is merged from HAL-C2"), [](World& world, const Captures&, const Table&) {
    fake(world).calls.clear();
    FakePullRequests& pulls = fake(world);
    ++pulls.revision;
    QJsonObject merged = pulls.entries.at(0).toObject();
    merged.insert(QStringLiteral("state"), QStringLiteral("merged"));
    pulls.entries.replace(0, merged);
    for (const int id : world.mc.subscribers(QStringLiteral("pullRequestRefreshes"))) sendRevision(world.mc, id);
  });
  step(QStringLiteral("the page lists it no longer"), [](World& world, const Captures&, const Table&) {
    expectListed(world, {QStringLiteral("acme/api#7"), QStringLiteral("acme/api#9")});
  });
  step(QStringLiteral("the user leaves the pull requests page"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("settings.open"), {});
    world.sync();
  });
  step(QStringLiteral("the desktop stops listening for pull request changes"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.mc.subscribers(QStringLiteral("pullRequestRefreshes")).isEmpty(); },
                  QStringLiteral("the pull request changes to be unsubscribed"));
  });

  // Opening a pull request.
  step(QStringLiteral("the thread %1 works on #(\\d+)").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject thread{{QStringLiteral("id"), QStringLiteral("thread-") + c[0]},
                             {QStringLiteral("projectId"), QStringLiteral("acme/shop")},
                             {QStringLiteral("title"), c[0]},
                             {QStringLiteral("createdAt"), QStringLiteral("2026-09-20T10:00:00Z")},
                             {QStringLiteral("updatedAt"), QStringLiteral("2026-09-20T10:00:00Z")}};
    world.mc.threads.insert(thread.value(QLatin1String("id")).toString(), thread);
    world.mc.sendRow(thread.value(QLatin1String("id")).toString(), thread);
    fake(world).linked[c[1].toInt()].append(QJsonObject{{QStringLiteral("id"), QStringLiteral("thread-") + c[0]},
                                                        {QStringLiteral("projectId"), QStringLiteral("acme/shop")},
                                                        {QStringLiteral("title"), c[0]},
                                                        {QStringLiteral("archivedAt"), QJsonValue::Null}});
  });
  step(QStringLiteral("the user opens #(\\d+) from the pull requests page"), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("pullRequestList.open"), QVariantMap{{QStringLiteral("key"), rowKey(world, c[0].toInt())}});
  });
  step(QStringLiteral("the user opens #(\\d+) on GitHub from the pull requests page"), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("pullRequestList.openOnHost"), QVariantMap{{QStringLiteral("key"), rowKey(world, c[0].toInt())}});
  });
});

}  // namespace
