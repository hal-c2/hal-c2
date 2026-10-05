// A folder named when the app is launched again (src/SingleInstance, main.cpp):
// the later launch hands it to the running window and ends, and the window
// adds it as a project, or finds it, and starts a thread there
// (features/navigation/qt-shell-backlog.feature, "Opening a folder from outside").

#include <QDir>
#include <QFileInfo>
#include <QJsonArray>

#include <atomic>
#include <thread>

#include "DraftController.h"
#include "Harness.h"
#include "NavigationController.h"
#include "SingleInstance.h"
#include "World.h"

namespace {

struct Launches {
  std::unique_ptr<SingleInstance> running;
  QString folder;
  bool forwarded = false;
  qsizetype connectionsBefore = 0;
  int drafts = 0;
};

QString stateDir(World& world) {
  return QDir(world.homeDir()).filePath(QStringLiteral("state"));
}

// A real folder under the scenario's home, as the user's `~/code/<name>`.
QString folder(World& world, const QString& name) {
  const QString path = QDir(world.homeDir()).filePath(QStringLiteral("code/") + name);
  QDir().mkpath(path);
  return QFileInfo(path).canonicalFilePath();
}

// The app as main.cpp runs it: connected, and listening for later launches.
void run(World& world) {
  Launches& state = world.mc.part<Launches>();
  if (state.running) return;
  if (world.shellSubscriptions() == 0) world.connect();
  world.waitFor([&world] { return world.native().isActive(); }, QStringLiteral("the shell to start"));
  world.sync();
  state.running = std::make_unique<SingleInstance>(stateDir(world));
  expect(state.running->listen([&world](const QStringList& folders) {
    for (const QString& path : folders) world.bridge().dispatch(QStringLiteral("project.launch"), QVariantMap{{QStringLiteral("path"), path}});
  }), QStringLiteral("the running app cannot listen for later launches"));
  state.connectionsBefore = world.mc.connections.size();
}

// The later launch, up to where main.cpp would start its own MC.
void launchAgain(World& world, const QString& path) {
  Launches& state = world.mc.part<Launches>();
  state.folder = path;
  // The second process blocks on the socket while this one answers it.
  std::atomic<bool> done = false;
  std::thread later([&] {
    state.forwarded = SingleInstance::forward(stateDir(world), {path});
    done = true;
  });
  world.waitFor([&done] { return done.load(); }, QStringLiteral("the later launch to reach the running app"));
  later.join();
  world.sync();
}

QList<QJsonObject> created(World& world) {
  QList<QJsonObject> commands;
  for (const FakeMc::Rpc& rpc : std::as_const(world.mc.calls)) {
    if (rpc.method == QLatin1String("projects.mutate") && rpc.payload.value(QLatin1String("type")) == QLatin1String("project.create")) {
      commands.append(rpc.payload);
    }
  }
  return commands;
}

// The project of the draft the window shows.
QString draftProject(World& world) {
  const QVariant route = world.state(QStringLiteral("route"));
  if (at(route, QStringLiteral("kind")) != QLatin1String("draft")) return {};
  const auto draft = world.native().controller<DraftController>()->draft(at(route, QStringLiteral("draftId")).toString());
  return draft ? draft->projectId : QString();
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("the app is running"), [](World& world, const Captures&, const Table&) { run(world); });
  // A launch that names no folder asks nobody (main.cpp) and goes straight to
  // listening: it must find the running app's socket taken and leave it alone.
  step(QStringLiteral("the user launches the app again without a folder"), [](World& world, const Captures&, const Table&) {
    SingleInstance later(stateDir(world));
    expect(!later.listen([](const QStringList&) {}), QStringLiteral("the later launch took the running app's socket"));
  });
  step(QStringLiteral("the user launches the app again with a folder path"), [](World& world, const Captures&, const Table&) {
    launchAgain(world, folder(world, QStringLiteral("shop")));
  });
  step(QStringLiteral("the running window adds the folder as a project and opens a new thread there"), [](World& world, const Captures&, const Table&) {
    const Launches& state = world.mc.part<Launches>();
    world.waitFor([&] { return created(world).size() == 1 && !draftProject(world).isEmpty(); },
                  [&] { return QStringLiteral("the project and its thread; the MC was asked for %1, the route is %2")
                                   .arg(show(QVariant::fromValue(created(world))), show(world.state(QStringLiteral("route")))); });
    const QJsonObject project = created(world).first();
    expect(project.value(QLatin1String("workspaceRoot")) == state.folder && draftProject(world) == project.value(QLatin1String("projectId")).toString(),
           QStringLiteral("the project is %1, the draft in %2").arg(show(project.toVariantMap()), draftProject(world)));
  });
  step(QStringLiteral("no second server starts"), [](World& world, const Captures&, const Table&) {
    const Launches& state = world.mc.part<Launches>();
    // The later launch ended once the running app took the folder (main.cpp
    // returns before it starts a backend), and the MC has the one shell.
    expect(state.forwarded && world.mc.connections.size() == state.connectionsBefore,
           QStringLiteral("forwarded: %1; the MC has %2 connections").arg(state.forwarded).arg(world.mc.connections.size()));
  });
  step(QStringLiteral("%1 is already a project").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString path = folder(world, c[0].mid(c[0].lastIndexOf(QLatin1Char('/')) + 1));
    world.mc.projects.insert(QStringLiteral("api"), {{QStringLiteral("id"), QStringLiteral("api")}, {QStringLiteral("title"), QStringLiteral("api")},
                                                      {QStringLiteral("workspaceRoot"), path}, {QStringLiteral("scripts"), QJsonArray()},
                                                      {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                      {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")}});
    // With a thread of its own, which a launch must not just reopen.
    world.mc.threads.insert(QStringLiteral("t-api"), {{QStringLiteral("id"), QStringLiteral("t-api")}, {QStringLiteral("projectId"), QStringLiteral("api")},
                                                       {QStringLiteral("title"), QStringLiteral("Earlier work")},
                                                       {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                                                       {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}});
    run(world);
    world.bridge().dispatch(QStringLiteral("thread.open"), QVariantMap{{QStringLiteral("key"), world.mc.environmentId + QStringLiteral(":t-api")}});
    world.waitFor([&] { return at(world.state(QStringLiteral("route")), QStringLiteral("kind")) == QLatin1String("thread"); }, QStringLiteral("the earlier thread"));
  });
  step(QStringLiteral("the user launches the app again with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    launchAgain(world, folder(world, c[0].mid(c[0].lastIndexOf(QLatin1Char('/')) + 1)));
  });
  step(QStringLiteral("a new thread opens in the existing project"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return draftProject(world) == QLatin1String("api"); },
                  [&] { return QStringLiteral("a new thread in the project; the route is %1").arg(show(world.state(QStringLiteral("route")))); });
    expect(world.mc.part<Launches>().forwarded && created(world).isEmpty(),
           QStringLiteral("a second project was created: %1").arg(show(QVariant::fromValue(created(world)))));
  });
});

}  // namespace
