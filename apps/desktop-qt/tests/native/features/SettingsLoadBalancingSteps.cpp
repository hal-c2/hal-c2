// Balancing new threads across machines (LoadBalancingController,
// features/settings/load-balancing.feature): two linked machines with a
// checkout of one repository, what each reports of its free CPU and memory
// (`server.getHostResources`) and of its providers (`server.getConfig`), and
// where a new thread's draft ends up.

#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>
#include <QTest>

#include "Brick.h"
#include "FakeConfig.h"
#include "Harness.h"
#include "LoadBalancingController.h"
#include "NavigationController.h"
#include "SettingsShell.h"
#include "WorkspaceController.h"
#include "World.h"

namespace {

const QString kLaptop = QStringLiteral("laptop");
const QString kServer = QStringLiteral("server");
const QString kProvider = QStringLiteral("claudeAgent");

// What each machine answers, and the clock the shell times its samples on.
struct FakeHosts {
  QHash<QString, QJsonObject> resources;
  QSet<QString> silent;  // machines that no longer answer
  QStringList asked;     // every `server.getHostResources`, by machine
  qint64 now = 1'000'000;
  bool set = false;
};

QJsonObject host(double cpu, double freeMemory) {
  return {{QStringLiteral("sampledAt"), 1}, {QStringLiteral("cpuUtilization"), cpu}, {QStringLiteral("cpuCount"), 8},
          {QStringLiteral("availableMemoryBytes"), freeMemory * 16e9}, {QStringLiteral("totalMemoryBytes"), 16e9}};
}

QJsonObject provider(const QString& auth) {
  return {{QStringLiteral("instanceId"), kProvider}, {QStringLiteral("driver"), kProvider}, {QStringLiteral("displayName"), QStringLiteral("Claude")},
          {QStringLiteral("enabled"), true}, {QStringLiteral("installed"), true}, {QStringLiteral("status"), QStringLiteral("ready")},
          {QStringLiteral("auth"), QJsonObject{{QStringLiteral("status"), auth}}},
          {QStringLiteral("models"), QJsonArray{QJsonObject{{QStringLiteral("slug"), QStringLiteral("sonnet")}, {QStringLiteral("name"), QStringLiteral("Sonnet")}}}}};
}

const FakeMc::Extension hosts([](FakeMc& mc) {
  mc.onRpc(QStringLiteral("server.getHostResources"), [&mc](const FakeMc::Rpc& rpc) {
    FakeHosts& fake = mc.part<FakeHosts>();
    const QString machine = rpc.environment.isEmpty() ? mc.environmentId : rpc.environment;
    fake.asked.append(machine);
    if (fake.silent.contains(machine) || !fake.resources.contains(machine)) return mc.refuse(rpc, QStringLiteral("host resources unavailable"));
    mc.reply(rpc, fake.resources.value(machine));
  });
  mc.onRpc(QStringLiteral("server.getConfig"), [&mc](const FakeMc::Rpc& rpc) {
    const FakeConfig& config = fakeConfig(mc);
    const QString machine = rpc.environment.isEmpty() ? mc.environmentId : rpc.environment;
    mc.reply(rpc, machine == mc.environmentId ? config.config : config.elsewhere.value(machine));
  });
});

FakeHosts& hostsOf(World& world) {
  return world.mc.part<FakeHosts>();
}

QVariantMap workspace(World& world) {
  return world.state(QStringLiteral("workspace")).toMap();
}

QVariant balancing(World& world) {
  return world.state(QStringLiteral("loadBalancing"));
}

LoadBalancingController* controller(World& world) {
  auto* balancer = world.native().controller<LoadBalancingController>();
  FakeHosts& fake = hostsOf(world);
  balancer->setClock([&fake] { return fake.now; });
  return balancer;
}

void setProviders(World& world, const QString& machine, const QString& auth) {
  QJsonObject config = fakeConfig(world.mc).elsewhere.value(machine);
  config.insert(QStringLiteral("providers"), QJsonArray{provider(auth)});
  fakeConfig(world.mc).elsewhere.insert(machine, config);
}

// A checkout of the repository `project` on a linked machine.
void addCheckout(World& world, const QString& machine, const QString& project) {
  world.mc.sendLinkRow(machine, project,
                       {{QStringLiteral("id"), project},
                        {QStringLiteral("title"), project},
                        {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + project},
                        {QStringLiteral("scripts"), QJsonArray()},
                        // "docs" was used last: it is the project the window lands on, leaving "api" for the scenario's new thread.
                        {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                        {QStringLiteral("updatedAt"), project == QLatin1String("docs") ? QStringLiteral("2026-09-20T09:00:00Z") : QStringLiteral("2026-09-01T09:00:00Z")},
                        {QStringLiteral("repositoryIdentity"),
                         QJsonObject{{QStringLiteral("canonicalKey"), QStringLiteral("github.com/acme/") + project}, {QStringLiteral("name"), project}}}},
                       QStringLiteral("project"));
}

// "laptop" and "server", both connected, both idle, each with a checkout of "api" and of "docs".
void twoMachines(World& world) {
  FakeHosts& fake = hostsOf(world);
  if (fake.set) return;
  fake.set = true;
  for (const QString& machine : {kLaptop, kServer}) {
    setProviders(world, machine, QStringLiteral("authenticated"));
    documentOf(world.mc, machine);
    world.mc.linkLabels.insert(machine, machine);
    world.mc.link(machine);
    for (const QString& project : {QStringLiteral("api"), QStringLiteral("docs")}) addCheckout(world, machine, project);
    fake.resources.insert(machine, host(0.1, 0.8));
  }
  if (world.shellSubscriptions() == 0) world.connect();
  world.sync();
  controller(world);
  world.waitFor([&] { return balancing(world).toMap().value(QStringLiteral("machines")).toList().size() == 3; },  // with this machine
                [&] { return QStringLiteral("the machines to be connected; load balancing is %1").arg(show(balancing(world))); });
}

void startThreadIn(World& world, const QString& project) {
  world.startNewThread(QVariantMap{{QStringLiteral("projectKey"), world.projectKey(project)}});
  expect(!world.draftId.isEmpty(), QStringLiteral("no draft opened for %1; the route is %2").arg(project, show(world.state(QStringLiteral("route")))));
  world.waitFor([&] { return workspace(world).value(QStringLiteral("isDraft")).toBool(); },
                [&] { return QStringLiteral("the header to show the draft; it shows %1").arg(show(workspace(world))); });
  world.sync();
}

WorkspaceController::Checkout checkout(World& world) {
  return world.native().controller<WorkspaceController>()->checkout(world.draftId);
}

QString describe(World& world) {
  const WorkspaceController::Checkout placed = checkout(world);
  return QStringLiteral("the draft is on %1 (chosen by \"%2\"); the machines were asked %3; load balancing is %4")
      .arg(workspace(world).value(QStringLiteral("activeEnvironmentId")).toString(), placed.selection,
           hostsOf(world).asked.join(QStringLiteral(", ")), show(balancing(world)));
}

// Load balancing put the draft on `machine`.
void expectBalancedTo(World& world, const QString& machine) {
  world.waitFor([&] { return checkout(world).selection == QLatin1String("auto") && workspace(world).value(QStringLiteral("activeEnvironmentId")) == machine; },
                [&] { return describe(world); });
}

// The first message starts the thread on `machine`.
void expectLaunchOn(World& world, const QString& machine) {
  world.bridge().dispatch(QStringLiteral("composer.submit"), QVariantMap{{QStringLiteral("text"), QStringLiteral("Add tax to the cart")},
                                                                         {QStringLiteral("intent"), QStringLiteral("foreground")}});
  QString launchedOn;
  world.waitFor([&] {
    for (const FakeMc::Rpc& rpc : world.mc.calls) {
      if (rpc.method == QLatin1String("orchestration.launchThread")) launchedOn = rpc.environment;
    }
    return !launchedOn.isEmpty();
  }, [&] { return QStringLiteral("a thread to start; %1").arg(describe(world)); });
  expect(launchedOn == machine, QStringLiteral("the thread started on %1; %2").arg(launchedOn, describe(world)));
}

void turnOn(World& world) {
  twoMachines(world);
  world.bridge().dispatch(QStringLiteral("loadBalancing.enable"), QVariantMap{{QStringLiteral("enabled"), true}});
  expect(balancing(world).toMap().value(QStringLiteral("enabled")).toBool(), describe(world));
}

void prefer(World& world, const QString& machine, int value) {
  world.bridge().dispatch(QStringLiteral("loadBalancing.prefer"), QVariantMap{{QStringLiteral("environmentId"), machine}, {QStringLiteral("value"), value}});
}

QQuickItem* group(World& world) {
  Brick& brick = settingsShell(world);
  brick.grab();
  return brick.item(QStringLiteral("loadBalancing"));
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("two connected machines share project %1").arg(q), [](World& world, const Captures&, const Table&) { twoMachines(world); });
  step(QStringLiteral("load balancing is on"), [](World& world, const Captures&, const Table&) { turnOn(world); });
  step(QStringLiteral("the thread starts on the machine the user picked"), [](World& world, const Captures&, const Table&) {
    // Off by default: nothing is asked of the machines, and the draft is where the user opened it.
    expect(!balancing(world).toMap().value(QStringLiteral("enabled"), true).toBool() && hostsOf(world).asked.isEmpty() && checkout(world).selection.isEmpty(),
           describe(world));
    const QString other = workspace(world).value(QStringLiteral("activeEnvironmentId")) == kLaptop ? kServer : kLaptop;
    // And follows the user's own choice of machine.
    world.bridge().dispatch(QStringLiteral("workspace.environment.set"), QVariantMap{{QStringLiteral("environmentId"), other}});
    world.waitFor([&] { return workspace(world).value(QStringLiteral("activeEnvironmentId")) == other; }, [&] { return describe(world); });
    expectLaunchOn(world, other);
    expect(hostsOf(world).asked.isEmpty(), describe(world));
  });

  step(QStringLiteral("%1 is busy and %1 is idle").arg(q), [](World& world, const Captures& c, const Table&) {
    hostsOf(world).resources.insert(c[0], host(0.9, 0.2));
    hostsOf(world).resources.insert(c[1], host(0.05, 0.9));
  });
  step(QStringLiteral("the thread starts on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    // A draft the user tied to a machine was never balanced.
    if (checkout(world).selection != QLatin1String("manual")) expectBalancedTo(world, c[0]);
    expectLaunchOn(world, c[0]);
  });

  // A machine that cannot take work, where it would otherwise win: it has the most room.
  step(QStringLiteral("\"server\" (is set to manual only|reported its resources over 15s ago|is at 95% CPU|has 5% of memory free|does not have the chosen provider signed in)"),
       [](World& world, const Captures& c, const Table&) {
         FakeHosts& fake = hostsOf(world);
         fake.resources.insert(kLaptop, host(0.6, 0.4));
         fake.resources.insert(kServer, host(0.05, 0.9));
         if (c[0] == QLatin1String("is set to manual only")) {
           prefer(world, kServer, 0);
         } else if (c[0].startsWith(QLatin1String("reported"))) {
           // Both answered when the window's own draft (of "docs") was placed; since then the server has gone quiet.
           world.waitFor([&] { return fake.asked.contains(kServer) && fake.asked.contains(kLaptop); }, [&] { return describe(world); });
           world.sync();
           fake.now += LoadBalancingController::kStaleMs + 1000;
           fake.silent.insert(kServer);
         } else if (c[0] == QLatin1String("is at 95% CPU")) {
           fake.resources.insert(kServer, host(0.95, 0.9));
         } else if (c[0] == QLatin1String("has 5% of memory free")) {
           fake.resources.insert(kServer, host(0.05, 0.05));
         } else {
           setProviders(world, kServer, QStringLiteral("unauthenticated"));
         }
       });
  step(QStringLiteral("the thread does not start on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString other = c[0] == kServer ? kLaptop : kServer;
    expectBalancedTo(world, other);
    expectLaunchOn(world, other);
  });

  step(QStringLiteral("the user prefers %1 and sets %1 to less often").arg(q), [](World& world, const Captures& c, const Table&) {
    prefer(world, c[0], 100);
    prefer(world, c[1], 25);
    const QString summary = balancing(world).toMap().value(QStringLiteral("summary")).toString();
    expect(summary.contains(c[0] + QStringLiteral(" prefer")) && summary.contains(c[1] + QStringLiteral(" less often")), describe(world));
  });
  step(QStringLiteral("both machines are equally idle"), [](World& world, const Captures&, const Table&) {
    for (const QString& machine : {kLaptop, kServer}) hostsOf(world).resources.insert(machine, host(0.1, 0.8));
    startThreadIn(world, QStringLiteral("api"));
  });
  step(QStringLiteral("new threads start on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expectBalancedTo(world, c[0]);
    expectLaunchOn(world, c[0]);
  });

  step(QStringLiteral("the user chose a branch for the new thread on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    // The other machine has the most room, and is where balancing first puts the draft.
    const QString other = c[0] == kLaptop ? kServer : kLaptop;
    hostsOf(world).resources.insert(c[0], host(0.6, 0.4));
    hostsOf(world).resources.insert(other, host(0.05, 0.9));
    startThreadIn(world, QStringLiteral("api"));
    expectBalancedTo(world, other);
    world.bridge().dispatch(QStringLiteral("workspace.environment.set"), QVariantMap{{QStringLiteral("environmentId"), c[0]}});
    auto* places = world.native().controller<WorkspaceController>();
    WorkspaceController::Checkout chosen = places->checkout(world.draftId);
    chosen.branch = QStringLiteral("feature/tax");
    places->setCheckout(world.draftId, chosen);
    world.waitFor([&] { return workspace(world).value(QStringLiteral("activeEnvironmentId")) == c[0]; }, [&] { return describe(world); });
    // Leaving and coming back does not move it.
    world.bridge().dispatch(QStringLiteral("settings.open"), {});
    world.bridge().dispatch(QStringLiteral("draft.open"), QVariantMap{{QStringLiteral("draftId"), world.draftId}});
    world.sync();
  });
  step(QStringLiteral("the user sends the first message"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(checkout(world).selection == QLatin1String("manual"), describe(world));
  });

  // One machine.
  step(QStringLiteral("only one machine is connected"), [](World& world, const Captures&, const Table&) {
    if (world.shellSubscriptions() == 0) world.connect();
    world.sync();
    controller(world);
  });
  step(QStringLiteral("the user opens connection settings"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("connections.open"), {});
    world.sync();
  });
  step(QStringLiteral("load balancing is not offered"), [](World& world, const Captures&, const Table&) {
    expect(balancing(world).isNull() && !group(world)->isVisible(), QStringLiteral("load balancing is %1").arg(show(balancing(world))));
    // A second machine brings it.
    twoMachines(world);
    world.waitFor([&] { return group(world)->isVisible() && settingsShell(world).shows(QStringLiteral("Load balancing")); },
                  QStringLiteral("load balancing to be offered with two machines"));
  });

  // Its fold (settings/search-and-navigation.feature).
  step(QStringLiteral("the \"Load balancing\" group on the Connections page is folded"), [](World& world, const Captures&, const Table&) {
    twoMachines(world);
    world.bridge().dispatch(QStringLiteral("connections.open"), {});
    world.waitFor([&] { return group(world)->isVisible(); }, QStringLiteral("the load balancing group"));
    expect(!group(world)->property("open").toBool(), QStringLiteral("the group is open"));
    // Back to another section, so the result is opened from elsewhere.
    world.bridge().dispatch(QStringLiteral("settings.navigate"), QVariantMap{{QStringLiteral("to"), QStringLiteral("/settings/general")}});
    world.sync();
  });
  step(QStringLiteral("the \"Load balancing\" group is open"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return group(world)->isVisible() && group(world)->property("open").toBool(); }, QStringLiteral("the group to open"));
    // Its machines are listed.
    world.waitFor([&] { return settingsShell(world).shows(kLaptop) && settingsShell(world).shows(kServer); }, QStringLiteral("the machines to be listed"));
  });
});

}  // namespace
