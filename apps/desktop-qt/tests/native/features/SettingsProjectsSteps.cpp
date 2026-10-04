// Removing a project from the desktop's folder explorer, which Settings →
// Project confirms (features/settings/projects.feature).

#include <QJsonArray>
#include <QJsonObject>

#include "Harness.h"
#include "World.h"

namespace {

const QString kProject = QStringLiteral("shop");

QVariantMap removal(World& world) {
  return world.state(QStringLiteral("projectRemoval")).toMap();
}

// The folder explorer's Remove from HAL-C2… on the project registered at the selected folder.
void removeFromExplorer(World& world, const QString& project) {
  if (!world.mc.projects.contains(project)) {
    world.mc.projects.insert(project, {{QStringLiteral("id"), project}, {QStringLiteral("title"), project},
                                         {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + project}, {QStringLiteral("scripts"), QJsonArray()}});
    if (world.shellSubscriptions() > 0) world.mc.sendRow(project, world.mc.projects.value(project), QStringLiteral("project"));
  }
  if (world.shellSubscriptions() == 0) world.connect();
  world.sync();
  for (const QVariant& local : at(world.state(QStringLiteral("sidebar")), QStringLiteral("localProjects")).toList()) {
    if (at(local, QStringLiteral("displayName")) != project) continue;
    world.bridge().dispatch(QStringLiteral("project.remove"), QVariantMap{{QStringLiteral("projectKey"), at(local, QStringLiteral("key"))}, {QStringLiteral("inSettings"), true}});
    world.sync();
    return;
  }
  fail(QStringLiteral("the folder explorer has no %1: %2").arg(project, show(at(world.state(QStringLiteral("sidebar")), QStringLiteral("localProjects")))));
}

bool listed(World& world, const QString& project) {
  const QVariantList projects = at(world.state(QStringLiteral("sidebar")), QStringLiteral("projects")).toList();
  return std::any_of(projects.cbegin(), projects.cend(), [&](const QVariant& entry) { return at(entry, QStringLiteral("displayName")) == project; });
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("the user removes a registered folder from HAL-C2 in the folder explorer"), [](World& world, const Captures&, const Table&) {
    removeFromExplorer(world, kProject);
  });
  step(QStringLiteral("the Projects settings open with the removal confirmation for that project"), [](World& world, const Captures&, const Table&) {
    const QVariant route = world.state(QStringLiteral("route"));
    expect(at(route, QStringLiteral("kind")) == QLatin1String("settings") && at(route, QStringLiteral("section")) == QLatin1String("/settings/projects"),
           QStringLiteral("the route is %1").arg(show(route)));
    // On that project, asking about it.
    world.waitFor([&] { return world.state(QStringLiteral("projectSettings")).toMap().value(QStringLiteral("name")) == kProject; },
                  [&] { return QStringLiteral("the panel is %1").arg(show(world.state(QStringLiteral("projectSettings")))); });
    expect(removal(world).value(QStringLiteral("title")) == kProject && world.mc.projects.contains(kProject) && world.mc.commands.isEmpty(),
           QStringLiteral("the confirmation is %1; the MC has %2").arg(show(removal(world)), world.describeCommands()));
  });
  step(QStringLiteral("the user asked to remove %1 from the folder explorer").arg(q), [](World& world, const Captures& c, const Table&) {
    removeFromExplorer(world, c[0]);
    expect(removal(world).value(QStringLiteral("title")) == c[0], QStringLiteral("the confirmation is %1").arg(show(removal(world))));
  });
  step(QStringLiteral("%1 is still listed").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(removal(world).isEmpty() && listed(world, c[0]) && world.mc.projects.contains(c[0]) && world.mc.commands.isEmpty(),
           QStringLiteral("the confirmation is %1; the MC has %2").arg(show(removal(world)), world.describeCommands()));
  });
  step(QStringLiteral("the user cancels the removal in settings"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("project.remove.cancel"), QVariantMap());
    world.sync();
  });
});

}  // namespace
