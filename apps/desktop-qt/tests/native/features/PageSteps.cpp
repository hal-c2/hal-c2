// The legacy page: what it publishes to the shell (the route, the workspace)
// and what the shell asks of it (navigation).

#include <QJsonObject>
#include <QVariantList>

#include "Harness.h"
#include "World.h"

namespace {

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("the page shows %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.pageOpens({{QStringLiteral("kind"), QStringLiteral("thread")}, {QStringLiteral("threadKey"), c[0]}});
    const QJsonObject thread = world.node.threads.value(c[0].mid(c[0].indexOf(QLatin1Char(':')) + 1));
    world.publishWorkspace(c[0], world.node.projects.value(thread.value(QLatin1String("projectId")).toString()),
                           thread.value(QLatin1String("worktreePath")).toString(), false);
  });
  step(QStringLiteral("the page shows %1 with its project at %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.pageOpens({{QStringLiteral("kind"), QStringLiteral("thread")}, {QStringLiteral("threadKey"), c[0]}});
    world.publishWorkspace(c[0], {{QStringLiteral("workspaceRoot"), c[1]}}, QString(), false);
  });
  step(QStringLiteral("the page shows the draft %1 in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.pageOpens({{QStringLiteral("kind"), QStringLiteral("draft")}, {QStringLiteral("draftId"), c[0]}});
    world.publishWorkspace(world.node.environmentId + QLatin1Char(':') + c[0], world.node.projects.value(c[1]), QString(), true);
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
