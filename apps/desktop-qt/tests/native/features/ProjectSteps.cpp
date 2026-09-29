// Projects (ProjectController and the sidebar's grouping): the node's
// `projects.mutate`, adding a local folder, asking before removing, and the
// domain's thread-list scenarios (files/adding-projects.feature,
// files/removing-and-listing-projects.feature, threads/sidebar-list.feature,
// threads/creating.feature).

#include <QDir>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonObject>
#include <QSet>

#include <algorithm>

#include "FakeProjects.h"
#include "Harness.h"
#include "NavigationController.h"
#include "NodeClient.h"
#include "World.h"

namespace {

const QString kAt = QStringLiteral("2026-09-23T09:00:00Z");

QJsonObject deleted() {
  return {{QStringLiteral("deletedAt"), QStringLiteral("2026-09-23T10:00:00Z")}};
}

// The node answers before the row arrives, which the shell must not trip on.
const FakeNode::Extension projects([](FakeNode& node) {
  node.onRpc(QStringLiteral("projects.mutate"), [&node](const FakeNode::Rpc& rpc) {
    FakeProjects& fake = node.part<FakeProjects>();
    fake.mutations.append(rpc.payload);
    if (!fake.refusal.isEmpty()) {
      node.refuse(rpc, fake.refusal);
      return;
    }
    const QString type = rpc.payload.value(QLatin1String("type")).toString();
    const QString id = rpc.payload.value(QLatin1String("projectId")).toString();
    const QString environment = rpc.environment.isEmpty() ? node.environmentId : rpc.environment;
    if (fake.refusedOn.contains(environment)) {
      node.refuse(rpc, fake.refusedOn.value(environment));
      return;
    }
    // A linked environment's projects are its link rows.
    if (environment != node.environmentId) {
      const QJsonArray entry = node.linkedRows.value(environment).value(id);
      if (entry.isEmpty() || (type != QLatin1String("project.update") && type != QLatin1String("project.delete"))) {
        node.refuse(rpc, type + QStringLiteral(" of ") + id + QStringLiteral(" is not supported"));
        return;
      }
      QJsonObject row = entry.at(2).toObject();
      if (type == QLatin1String("project.delete")) {
        row = deleted();
      } else {
        for (auto it = rpc.payload.begin(); it != rpc.payload.end(); ++it) {
          if (it.key() != QLatin1String("type") && it.key() != QLatin1String("projectId")) row.insert(it.key(), it.value());
        }
      }
      node.reply(rpc, QJsonObject());
      node.sendLinkRow(environment, id, row, QStringLiteral("project"));
      return;
    }
    if (type == QLatin1String("project.update")) {
      if (!node.projects.contains(id)) {
        node.refuse(rpc, QStringLiteral("unknown project ") + id);
        return;
      }
      QJsonObject row = node.projects.value(id);
      for (auto it = rpc.payload.begin(); it != rpc.payload.end(); ++it) {
        if (it.key() != QLatin1String("type") && it.key() != QLatin1String("projectId")) row.insert(it.key(), it.value());
      }
      node.projects.insert(id, row);
      node.reply(rpc, row);
      node.sendRow(id, row, QStringLiteral("project"));
    } else if (type == QLatin1String("project.create")) {
      const QString root = rpc.payload.value(QLatin1String("workspaceRoot")).toString();
      const QJsonObject row{
          {QStringLiteral("id"), id},
          {QStringLiteral("title"), QFileInfo(root).fileName()},
          {QStringLiteral("workspaceRoot"), root},
          {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T10:00:00Z")},
          {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T10:00:00Z")},
          {QStringLiteral("scripts"), QJsonArray()},
      };
      node.reply(rpc, row);
      node.projects.insert(id, row);
      node.sendRow(id, row, QStringLiteral("project"));
    } else if (type == QLatin1String("project.delete")) {
      if (!node.projects.contains(id)) {
        node.refuse(rpc, QStringLiteral("unknown project ") + id);
        return;
      }
      QStringList threads;
      for (auto it = node.threads.cbegin(); it != node.threads.cend(); ++it) {
        if (it->value(QLatin1String("projectId")).toString() == id) threads.append(it.key());
      }
      if (!threads.isEmpty() && !rpc.payload.value(QLatin1String("force")).toBool()) {
        node.refuse(rpc, QStringLiteral("Project %1 is not empty.").arg(id));
        return;
      }
      for (const QString& thread : std::as_const(threads)) {
        node.threads.remove(thread);
        node.sendRow(thread, deleted());
      }
      node.projects.remove(id);
      node.sendRow(id, deleted(), QStringLiteral("project"));
      node.reply(rpc, QJsonObject());
    } else {
      node.refuse(rpc, type + QStringLiteral(" is not supported"));
    }
  });
});

QList<QJsonObject> mutations(World& world, const QString& type) {
  QList<QJsonObject> result;
  for (const QJsonObject& mutation : world.node.part<FakeProjects>().mutations) {
    if (mutation.value(QLatin1String("type")) == type) result.append(mutation);
  }
  return result;
}

// Where a folder the scenario names lives on this machine: under the World's home.
QString localPath(World& world, const QString& path) {
  return QDir::cleanPath(world.configDir() + QStringLiteral("/../files") + path);
}

QString makeFolder(World& world, const QString& path) {
  const QString local = localPath(world, path);
  QDir().mkpath(local);
  return QFileInfo(local).canonicalFilePath();
}

// A project row on the node (in the snapshot, or as a row once connected).
void addProject(World& world, const QString& id, const QString& title, const QString& root) {
  const QJsonObject row{
      {QStringLiteral("id"), id},
      {QStringLiteral("title"), title},
      {QStringLiteral("workspaceRoot"), root},
      {QStringLiteral("createdAt"), kAt},
      {QStringLiteral("updatedAt"), kAt},
      {QStringLiteral("scripts"), QJsonArray()},
  };
  world.node.projects.insert(id, row);
  world.node.sendRow(id, row, QStringLiteral("project"));
  if (world.native().client()->isReady()) world.sync();
}

void addThread(World& world, const QString& id, QJsonObject row) {
  row.insert(QStringLiteral("id"), id);
  if (!row.contains(QLatin1String("createdAt"))) row.insert(QStringLiteral("createdAt"), kAt);
  if (!row.contains(QLatin1String("updatedAt"))) row.insert(QStringLiteral("updatedAt"), row.value(QLatin1String("createdAt")));
  world.node.threads.insert(id, row);
  world.node.sendRow(id, row);
  if (world.native().client()->isReady()) world.sync();
}

// The sidebar's projects named `name`, with their environments.
QStringList projectEnvironments(World& world, const QString& name) {
  QStringList environments;
  for (const QVariant& project : at(world.state(QStringLiteral("sidebar")), QStringLiteral("projects")).toList()) {
    const QVariantMap map = project.toMap();
    if (map.value(QStringLiteral("displayName")) == name) environments.append(map.value(QStringLiteral("environmentId")).toString());
  }
  return environments;
}

QStringList projectNames(World& world) {
  QStringList names;
  for (const QVariant& project : at(world.state(QStringLiteral("sidebar")), QStringLiteral("projects")).toList()) {
    names.append(project.toMap().value(QStringLiteral("displayName")).toString());
  }
  return names;
}

QStringList threadTitles(World& world) {
  QStringList titles;
  for (const QString& section : {QStringLiteral("pinned"), QStringLiteral("active"), QStringLiteral("snoozed"), QStringLiteral("settled")}) {
    for (const QVariant& row : at(world.state(QStringLiteral("sidebar")), section).toList()) {
      titles.append(row.toMap().value(QStringLiteral("title")).toString());
    }
  }
  return titles;
}

QVariant removal(World& world) {
  return world.state(QStringLiteral("projectRemoval"));
}

void askToRemove(World& world, const QString& name) {
  world.bridge().dispatch(QStringLiteral("project.remove"), QVariantMap{{QStringLiteral("projectKey"), world.projectKey(name)}});
}

void connectAs(World& world, const QString& environmentId) {
  world.node.environmentId = environmentId;
  world.connect();
  world.sync();
}

const Steps steps([] {
  const QString q = kQuoted;

  // Environments and their projects.
  step(QStringLiteral("a connected environment %1").arg(q), [](World& world, const Captures& c, const Table&) {
    connectAs(world, c[0]);
  });
  step(QStringLiteral("a connected environment with the projects %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    for (const QString& name : c) addProject(world, name, name, QStringLiteral("/work/") + name);
    connectAs(world, world.node.environmentId);
  });
  step(QStringLiteral("a connected environment %1 with the project %1 at %1").arg(q), [](World& world, const Captures& c, const Table&) {
    addProject(world, c[1], c[1], c[2]);
    connectAs(world, c[0]);
  });
  step(QStringLiteral("the folder %1 exists on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    makeFolder(world, c[0]);
  });
  step(QStringLiteral("%1 is already a project on %1 with an unsettled thread %1").arg(q), [](World& world, const Captures& c, const Table&) {
    addProject(world, c[0], c[0], makeFolder(world, QStringLiteral("/home/sam/") + c[0]));
    addThread(world, QStringLiteral("t-latest"), {{QStringLiteral("projectId"), c[0]}, {QStringLiteral("title"), c[2]},
                                                  {QStringLiteral("latestUserMessageAt"), QStringLiteral("2026-09-23T09:30:00Z")}});
    addThread(world, QStringLiteral("t-settled"), {{QStringLiteral("projectId"), c[0]}, {QStringLiteral("title"), QStringLiteral("Done")},
                                                   {QStringLiteral("settledOverride"), QStringLiteral("settled")},
                                                   {QStringLiteral("latestUserMessageAt"), QStringLiteral("2026-09-23T09:45:00Z")}});
  });
  step(QStringLiteral("%1 has (\\d+) threads").arg(q), [](World& world, const Captures& c, const Table&) {
    for (int index = 1; index <= c[1].toInt(); ++index) {
      addThread(world, QStringLiteral("%1-%2").arg(c[0]).arg(index),
                {{QStringLiteral("projectId"), c[0]}, {QStringLiteral("title"), QStringLiteral("Thread %1").arg(index)}});
    }
  });
  // A new thread the user typed into and left.
  step(QStringLiteral("%1 has an unsent draft").arg(q), [](World& world, const Captures& c, const Table&) {
    world.startNewThread(QVariantMap{{QStringLiteral("projectKey"), world.projectKey(c[0])}});
    world.bridge().dispatch(QStringLiteral("composer.text.set"),
                            QVariantMap{{QStringLiteral("target"), world.draftId},
                                        {QStringLiteral("edit"), QVariantMap{{QStringLiteral("clientId"), QStringLiteral("qml")}, {QStringLiteral("revision"), world.nextEdit++}}},
                                        {QStringLiteral("text"), QStringLiteral("Unsent work")},
                                        {QStringLiteral("cursor"), 11}});
    world.native().controller<NavigationController>()->open(NavigationController::Route::of(QStringLiteral("home")));
  });
  step(QStringLiteral("the environments %1 and %1 both have a project %1").arg(q), [](World& world, const Captures& c, const Table&) {
    for (const QString& environment : {c[0], c[1]}) {
      const QString node = QStringLiteral("node-") + environment;
      world.node.join(node, environment);
      world.node.send({
          {QStringLiteral("t"), QStringLiteral("shell.rows")},
          {QStringLiteral("id"), world.node.subscribers(QStringLiteral("shell")).value(0)},
          {QStringLiteral("node"), node},
          {QStringLiteral("rows"), QJsonArray{QJsonValue(QJsonArray{
                                       c[2], QStringLiteral("project"),
                                       QJsonObject{{QStringLiteral("id"), c[2]}, {QStringLiteral("title"), c[2]},
                                                   {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + c[2]},
                                                   {QStringLiteral("createdAt"), kAt}, {QStringLiteral("updatedAt"), kAt}}})}},
      });
    }
    world.sync();
  });
  step(QStringLiteral("the environment refuses to change projects with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.node.part<FakeProjects>().refusal = c[0];
  });
  step(QStringLiteral("the local environment is disconnected"), [](World& world, const Captures&, const Table&) {
    world.node.stopAccepting();
    world.node.drop();
    world.waitFor([&world] { return !world.native().client()->isReady(); }, QStringLiteral("the shell to see the drop"));
  });
  step(QStringLiteral("the shell may not open local folders"), [](World& world, const Captures&, const Table&) {
    world.bridge().setLocalFolderImportEnabled(false);
  });
  step(QStringLiteral("the user asks to add a project without a folder"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("project.add"), QVariantMap());
  });
  step(QStringLiteral("the desktop app is connected to its own local environment"), [](World& world, const Captures&, const Table&) {
    expect(world.bridge().localFolderImportEnabled() && world.native().client()->isReady(),
           QStringLiteral("the shell is not connected to its own environment"));
  });

  // Threads in the domain's words.
  step(QStringLiteral("the user last wrote in %1 after %1").arg(q), [](World& world, const Captures& c, const Table&) {
    addThread(world, QStringLiteral("t-later"), {{QStringLiteral("projectId"), c[0]}, {QStringLiteral("title"), QStringLiteral("Later")},
                                                 {QStringLiteral("latestUserMessageAt"), QStringLiteral("2026-09-23T09:30:00Z")}});
    addThread(world, QStringLiteral("t-earlier"), {{QStringLiteral("projectId"), c[1]}, {QStringLiteral("title"), QStringLiteral("Earlier")},
                                                   {QStringLiteral("latestUserMessageAt"), QStringLiteral("2026-09-23T09:10:00Z")}});
  });
  step(QStringLiteral("the agent in %1 started a helper agent thread").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString project = world.node.projects.firstKey();
    addThread(world, QStringLiteral("t-parent"), {{QStringLiteral("projectId"), project}, {QStringLiteral("title"), c[0]}});
    addThread(world, QStringLiteral("t-helper"),
              {{QStringLiteral("projectId"), project},
               {QStringLiteral("title"), QStringLiteral("Helper")},
               {QStringLiteral("lineage"), QJsonObject{{QStringLiteral("parentThreadId"), QStringLiteral("t-parent")},
                                                       {QStringLiteral("relationshipToParent"), QStringLiteral("subagent")}}}});
  });
  step(QStringLiteral("the thread list is scoped to the project %1").arg(q), [](World& world, const Captures& c, const Table&) {
    if (projectEnvironments(world, c[0]).isEmpty()) addProject(world, c[0], c[0], QStringLiteral("/work/") + c[0]);
    world.bridge().dispatch(QStringLiteral("sidebar.scope"), QVariantMap{{QStringLiteral("projectKey"), world.projectKey(c[0])}});
  });

  // The user.
  step(QStringLiteral("the user looks at the (?:projects|thread list)"), [](World& world, const Captures&, const Table&) {
    world.sync();
  });
  // The sidebar's folder picker and the drop target hand over the folder as this machine names it.
  step(QStringLiteral("the user adds the local folder %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("project.add"), QVariantMap{{QStringLiteral("path"), localPath(world, c[0])}});
  });
  step(QStringLiteral("the user drops the folder %1 on the window").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("project.folder.open"), QVariantMap{{QStringLiteral("path"), makeFolder(world, c[0])}});
  });
  step(QStringLiteral("the user adds the local folder of %1 again").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString root = world.node.projects.value(c[0]).value(QLatin1String("workspaceRoot")).toString();
    world.bridge().dispatch(QStringLiteral("project.add"), QVariantMap{{QStringLiteral("path"), root}});
  });
  step(QStringLiteral("the user asks to remove %1").arg(q), [](World& world, const Captures& c, const Table&) {
    askToRemove(world, c[0]);
  });
  step(QStringLiteral("the user confirms removing %1(?: everywhere)?").arg(q), [](World& world, const Captures& c, const Table&) {
    askToRemove(world, c[0]);
    world.bridge().dispatch(QStringLiteral("project.remove.confirm"), QVariantMap());
    world.sync();
  });
  step(QStringLiteral("the user cancels"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("project.remove.cancel"), QVariantMap());
  });
  step(QStringLiteral("the folder explorer shows %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    const QVariantList local = at(world.state(QStringLiteral("sidebar")), QStringLiteral("localProjects")).toList();
    expect(std::any_of(local.cbegin(), local.cend(), [&](const QVariant& project) { return at(project, QStringLiteral("workspaceRoot")) == c[0]; }),
           QStringLiteral("the explorer's projects are %1").arg(show(local)));
  });
  step(QStringLiteral("the user removes %1 from HAL-C2").arg(q), [](World& world, const Captures& c, const Table&) {
    // FolderExplorer.qml: the registered project at the selected folder.
    for (const QVariant& project : at(world.state(QStringLiteral("sidebar")), QStringLiteral("localProjects")).toList()) {
      if (at(project, QStringLiteral("workspaceRoot")) != c[0]) continue;
      world.bridge().dispatch(QStringLiteral("project.remove"), QVariantMap{{QStringLiteral("projectKey"), at(project, QStringLiteral("key"))}});
      return;
    }
    fail(QStringLiteral("no project at %1").arg(c[0]));
  });

  // What the user sees.
  step(QStringLiteral("the (?:project )?%1 is listed for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return projectEnvironments(world, c[0]).contains(world.node.environmentId); },
                  [&] { return QStringLiteral("%1 to be listed; the sidebar lists %2").arg(c[0], projectNames(world).join(u", ")); });
  });
  step(QStringLiteral("%1 is still listed for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(projectEnvironments(world, c[0]).contains(world.node.environmentId),
           QStringLiteral("the sidebar lists %1").arg(projectNames(world).join(u", ")));
  });
  step(QStringLiteral("%1 is no longer listed for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(!projectEnvironments(world, c[0]).contains(world.node.environmentId),
           QStringLiteral("the sidebar lists %1").arg(projectNames(world).join(u", ")));
  });
  step(QStringLiteral("the sidebar lists the projects %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    const QString names = projectNames(world).join(u", ");
    expect(names == c[0], QStringLiteral("the sidebar lists the projects \"%1\"").arg(names));
  });
  // Projects, or threads when the names are threads'.
  step(QStringLiteral("%1 is listed above %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    const QStringList projects = projectNames(world);
    const bool threads = !projects.contains(c[0]);
    const QStringList names = threads ? threadTitles(world) : projects;
    expect(names.contains(c[0]) && names.contains(c[1]) && names.indexOf(c[0]) < names.indexOf(c[1]),
           QStringLiteral("the sidebar lists the %1 %2").arg(threads ? u"threads" : u"projects", names.join(u", ")));
  });
  step(QStringLiteral("%1 is listed once for each environment").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    const QStringList environments = projectEnvironments(world, c[0]);
    expect(environments.size() == QSet<QString>(environments.cbegin(), environments.cend()).size() && environments.size() >= 2,
           QStringLiteral("%1 is listed for %2").arg(c[0], environments.join(u", ")));
  });
  step(QStringLiteral("the helper thread is not listed"), [](World& world, const Captures&, const Table&) {
    world.sync();
    const QStringList titles = threadTitles(world);
    expect(!titles.contains(QStringLiteral("Helper")) && titles.contains(QStringLiteral("Alpha")),
           QStringLiteral("the sidebar lists %1").arg(titles.join(u", ")));
  });
  step(QStringLiteral("the thread %1 opens").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(at(world.state(QStringLiteral("route")), QStringLiteral("title")) == c[0],
           QStringLiteral("the route is %1").arg(show(world.state(QStringLiteral("route")))));
  });
  step(QStringLiteral("no (?:second )?project is created"), [](World& world, const Captures&, const Table&) {
    world.sync();
    const QList<QJsonObject> created = mutations(world, QStringLiteral("project.create"));
    expect(created.isEmpty(), QStringLiteral("the node was asked to create %1 project(s)").arg(created.size()));
  });
  step(QStringLiteral("the user is told the folder could not be opened"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      for (const QVariant& toast : at(world.state(QStringLiteral("toasts")), QStringLiteral("items")).toList()) {
        if (at(toast, QStringLiteral("title")) == QLatin1String("Could not open folder")) return true;
      }
      return false;
    }, [&] { return QStringLiteral("a toast; the shell shows %1").arg(show(world.state(QStringLiteral("toasts")))); });
  });
  step(QStringLiteral("the user is told (\\d+) threads and their conversation history will be cleared"), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(at(removal(world), QStringLiteral("threadCount")).toInt() == c[0].toInt(),
           QStringLiteral("the confirmation is %1").arg(show(removal(world))));
  });
  step(QStringLiteral("the user is told the files on disk are kept"), [](World& world, const Captures&, const Table&) {
    // ProjectRemovalDialog.qml names the folder it keeps.
    expect(!at(removal(world), QStringLiteral("workspaceRoot")).toString().isEmpty(),
           QStringLiteral("the confirmation is %1").arg(show(removal(world))));
  });
  step(QStringLiteral("the removal confirmation for %1 on %1 opens").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(at(removal(world), QStringLiteral("title")) == c[0] &&
               at(removal(world), QStringLiteral("projectKey")).toString().startsWith(c[1] + QLatin1Char(':')),
           QStringLiteral("the confirmation is %1").arg(show(removal(world))));
  });
  step(QStringLiteral("the removal confirmation is closed"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(removal(world).isNull(), QStringLiteral("the confirmation is %1").arg(show(removal(world))));
  });
  step(QStringLiteral("the draft for %1 is gone").arg(q), [](World& world, const Captures&, const Table&) {
    world.sync();
    const QVariantList drafts = at(world.state(QStringLiteral("sidebar")), QStringLiteral("drafts")).toList();
    expect(drafts.isEmpty(), QStringLiteral("the sidebar lists the drafts %1").arg(show(drafts)));
  });
  step(QStringLiteral("the user is taken home"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(at(world.state(QStringLiteral("route")), QStringLiteral("kind")) == QLatin1String("home"),
           QStringLiteral("the route is %1").arg(show(world.state(QStringLiteral("route")))));
  });
});

}  // namespace
