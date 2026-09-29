// The legacy page: what it publishes to the shell (the route, the workspace)
// and what the shell asks of it (navigation).

#include <QJsonArray>
#include <QJsonObject>
#include <QVariantList>

#include "Harness.h"
#include "World.h"

namespace {

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("the page shows %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.pageOpens({{QStringLiteral("kind"), QStringLiteral("thread")}, {QStringLiteral("threadKey"), c[0]}});
  });
  // A thread of another environment: a cluster member's rows carry it, or
  // the rows of a link to it.
  step(QStringLiteral("the page shows %1 with its project at %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const qsizetype colon = c[0].indexOf(QLatin1Char(':'));
    const QString environment = c[0].left(colon);
    const QString peer = world.node.peers.value(environment);
    const QString thread = c[0].mid(colon + 1);
    const QString project = QStringLiteral("project-") + thread;
    const QJsonObject projectRow{{QStringLiteral("id"), project}, {QStringLiteral("workspaceRoot"), c[1]}, {QStringLiteral("scripts"), QJsonArray()}};
    const QJsonObject threadRow{{QStringLiteral("id"), thread}, {QStringLiteral("projectId"), project}, {QStringLiteral("title"), thread}};
    if (!peer.isEmpty()) {
      QJsonArray rows;
      rows.append(QJsonArray{project, QStringLiteral("project"), projectRow});
      rows.append(QJsonArray{thread, QStringLiteral("thread"), threadRow});
      world.node.sendRows(peer, rows);
      world.sync();
    } else if (world.node.linked.contains(environment)) {
      world.node.sendLinkRow(environment, project, projectRow, QStringLiteral("project"));
      world.node.sendLinkRow(environment, thread, threadRow);
      world.sync();
    }
    world.pageOpens({{QStringLiteral("kind"), QStringLiteral("thread")}, {QStringLiteral("threadKey"), c[0]}});
  });
  step(QStringLiteral("the page shows the draft %1 in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    // The page reports the draft it opened, which the shell adopts.
    world.pageOpens({{QStringLiteral("kind"), QStringLiteral("draft")}, {QStringLiteral("draftId"), c[0]},
                     {QStringLiteral("environmentId"), world.node.environmentId}, {QStringLiteral("projectId"), c[1]},
                     {QStringLiteral("threadId"), c[0]}});
  });
  step(QStringLiteral("the time is %1").arg(q), [](World& world, const Captures& c, const Table&) { world.setTime(c[0]); });

  // What the page is asked to do.
  step(QStringLiteral("nothing reaches the page"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(world.pageActions.isEmpty() && world.follows.isEmpty(), QStringLiteral("the page got %1").arg(world.describePage()));
  });
  step(QStringLiteral("the action %1 for %1 reaches the page").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    for (const PageAction& action : world.actionsOf(c[0])) {
      if (action.payload.value(QStringLiteral("key")).toString() == c[1]) return;
    }
    fail(QStringLiteral("the page got %1").arg(world.describePage()));
  });
  step(QStringLiteral("the action %1 reaches the page").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(!world.actionsOf(c[0]).isEmpty(), QStringLiteral("the page got %1").arg(world.describePage()));
  });
  const auto followed = [](World& world, const QString& kind, const QString& field, const QString& value) {
    world.waitFor([&] {
      for (const QVariantMap& route : world.follows) {
        if (route.value(QStringLiteral("kind")) == kind && route.value(field).toString() == value) return true;
      }
      return false;
    }, [&] { return QStringLiteral("to follow %1 %2; the page got %3").arg(kind, value, world.describePage()); });
  };
  step(QStringLiteral("the page is asked to open %1").arg(q), [followed](World& world, const Captures& c, const Table&) {
    followed(world, QStringLiteral("thread"), QStringLiteral("threadKey"), c[0]);
  });
  step(QStringLiteral("the page is not asked to open anything"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(world.follows.isEmpty(), QStringLiteral("the page got %1").arg(world.describePage()));
  });
});

}  // namespace
