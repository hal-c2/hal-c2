// The legacy page: what it publishes to the shell (grouping, the route, the
// workspace) and what the shell asks of it (navigation).

#include <QJsonObject>
#include <QVariantList>

#include "Harness.h"
#include "World.h"

namespace {

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("the page groups %1 as the project %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const qsizetype colon = c[0].indexOf(QLatin1Char(':'));
    QVariantList projects = world.sidebarInput.value(QStringLiteral("projects")).toList();
    projects.append(QVariantMap{
        {QStringLiteral("key"), c[1]},
        {QStringLiteral("displayName"), c[1]},
        {QStringLiteral("environmentId"), c[0].left(colon)},
        {QStringLiteral("projectId"), c[0].mid(colon + 1)},
        {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + c[1]},
        {QStringLiteral("memberKeys"), QStringList{c[0]}},
    });
    world.sidebarInput.insert(QStringLiteral("projects"), projects);
    world.publishSidebarInput();
  });
  step(QStringLiteral("the page stops grouping %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QVariantList projects;
    for (const QVariant& project : world.sidebarInput.value(QStringLiteral("projects")).toList()) {
      if (!project.toMap().value(QStringLiteral("memberKeys")).toStringList().contains(c[0])) projects.append(project);
    }
    world.sidebarInput.insert(QStringLiteral("projects"), projects);
    world.publishSidebarInput();
  });
  step(QStringLiteral("the page shows %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sidebarInput.insert(QStringLiteral("activeThreadKey"), c[0]);
    world.publishSidebarInput();
    const QJsonObject thread = world.node.threads.value(c[0].mid(c[0].indexOf(QLatin1Char(':')) + 1));
    world.publishWorkspace(c[0], world.node.projects.value(thread.value(QLatin1String("projectId")).toString()),
                           thread.value(QLatin1String("worktreePath")).toString(), false);
  });
  step(QStringLiteral("the page shows %1 with its project at %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sidebarInput.insert(QStringLiteral("activeThreadKey"), c[0]);
    world.publishSidebarInput();
    world.publishWorkspace(c[0], {{QStringLiteral("workspaceRoot"), c[1]}}, QString(), false);
  });
  step(QStringLiteral("the page shows the draft %1 in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sidebarInput.insert(QStringLiteral("activeThreadKey"), QVariant());
    world.publishSidebarInput();
    world.publishWorkspace(world.node.environmentId + QLatin1Char(':') + c[0], world.node.projects.value(c[1]), QString(), true);
  });
  step(QStringLiteral("the page's sidebar is scoped to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sidebarInput.insert(QStringLiteral("scopeProjectKey"), c[0]);
    world.publishSidebarInput();
  });
  step(QStringLiteral("the page's timestamps are %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sidebarInput.insert(QStringLiteral("timestampFormat"), c[0]);
    world.publishSidebarInput();
  });
  step(QStringLiteral("the time is %1").arg(q), [](World& world, const Captures& c, const Table&) { world.setTime(c[0]); });

  // What the page is asked to do.
  step(QStringLiteral("nothing reaches the page"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(world.pageActions.isEmpty(), QStringLiteral("the page got %1").arg(world.describePage()));
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
  const auto opened = [](World& world, const QString& type, const QString& field, const QString& value) {
    world.waitFor([&] {
      for (const PageAction& action : world.actionsOf(type)) {
        if (action.payload.value(field).toString() == value) return true;
      }
      return false;
    }, [&] { return QStringLiteral("%1 %2; the page got %3").arg(type, value, world.describePage()); });
  };
  step(QStringLiteral("the page is asked to open %1").arg(q), [opened](World& world, const Captures& c, const Table&) {
    opened(world, QStringLiteral("thread.open"), QStringLiteral("key"), c[0]);
  });
  step(QStringLiteral("the page is asked to open a new thread in %1").arg(q), [opened](World& world, const Captures& c, const Table&) {
    opened(world, QStringLiteral("thread.new"), QStringLiteral("projectKey"), c[0]);
  });
  step(QStringLiteral("the page is not asked to open anything"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(world.actionsOf(QStringLiteral("thread.open")).isEmpty() && world.actionsOf(QStringLiteral("thread.new")).isEmpty(),
           QStringLiteral("the page got %1").arg(world.describePage()));
  });
});

}  // namespace
