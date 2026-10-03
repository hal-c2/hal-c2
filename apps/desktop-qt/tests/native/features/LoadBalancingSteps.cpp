// Load balancing on the desktop (features/settings/load-balancing.feature,
// its settings in connections/environments.feature, and its search result in
// settings/search-and-navigation.feature): a new thread's first send asks the
// MC where it starts (ComposerController::place, `hal-c2.placeThread`) and
// launches it there, and the Connections page's "Load balancing" group
// (LoadBalancingController, LoadBalancingGroup.qml) keeps what the MC chooses
// by in the MC's settings document.
//
// The choosing is the MC's (apps/server-ex, HalC2.LoadBalancing): the fake
// answers what the scenario says of the machines, and the steps check where
// the shell then launched the thread.

#include <QDir>
#include <QJSValue>
#include <QJsonArray>
#include <QJsonObject>
#include <QUrl>

#include "Brick.h"
#include "FakeConfig.h"
#include "Harness.h"
#include "Launch.h"
#include "LoadBalancing.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "World.h"

namespace {

const QString kServer = QStringLiteral("server");
const QString kPrompt = QStringLiteral("Add tax to the cart");
const QString kEnabled = QStringLiteral("loadBalancingEnabled");
const QString kWeights = QStringLiteral("loadBalancingWeights");

FakePlacement& placement(World& world) {
  return world.mc.part<FakePlacement>();
}

QString repositoryOf(const QString& project) {
  return QStringLiteral("github.com/acme/") + project;
}

// The id of `machine`'s checkout of the shared project `name`.
QString checkoutId(const FakeMc& mc, const QString& machine, const QString& name) {
  return machine == mc.environmentId ? name : name + QStringLiteral("-on-") + machine;
}

// Whether the member `machine` lists a checkout of the shared project `name`.
bool hasCheckout(const FakeMc& mc, const QString& machine, const QString& name) {
  const QJsonArray row = mc.peerRows.value(machine).value(checkoutId(mc, machine, name));
  return row.at(2).toObject().value(QLatin1String("repositoryIdentity")).toObject().value(QLatin1String("canonicalKey")) ==
         repositoryOf(name);
}

// `hal-c2.placeThread`, asked of the MC the shell is connected to: the user's
// pick, or the checkout of the machine the scenario gives more room.
const FakeMc::Extension places([](FakeMc& mc) {
  mc.onRpc(QStringLiteral("hal-c2.placeThread"), [&mc](const FakeMc::Rpc& rpc) {
    FakePlacement& fake = mc.part<FakePlacement>();
    fake.asked.append(rpc);
    const bool balancing = fakeConfig(mc).settings.value(kEnabled).toBool();
    if (balancing && !mc.offline.contains(fake.elsewhere) && hasCheckout(mc, fake.elsewhere, fake.project)) {
      mc.reply(rpc, QJsonObject{{QStringLiteral("environmentId"), fake.elsewhere},
                                {QStringLiteral("projectId"), checkoutId(mc, fake.elsewhere, fake.project)}});
      return;
    }
    mc.reply(rpc, QJsonObject{{QStringLiteral("environmentId"), rpc.payload.value(QLatin1String("environmentId"))},
                              {QStringLiteral("projectId"), rpc.payload.value(QLatin1String("projectId"))}});
  });
});

// The MC's own machine and one member, each known by its name.
void cluster(FakeMc& mc, const QString& own, const QString& member) {
  mc.environmentId = own;
  mc.name = QStringLiteral("mc-") + own;
  mc.label = own;
  mc.join(member);
}

void connected(World& world) {
  if (world.mc.connections.isEmpty()) world.connect();
  world.sync();
}

QJsonObject weights(World& world) {
  return fakeConfig(world.mc).settings.value(kWeights).toObject();
}

QVariantMap balancing(World& world) {
  return world.state(QStringLiteral("loadBalancing")).toMap();
}

// The Connections page over the shell, which can also say what a settings
// search finds (js/settingsPages.js, as SettingsNav.qml asks it).
Brick& page(World& world, const QSize& size = QSize(820, 700)) {
  if (!world.brick) {
    const QString pages =
        QUrl::fromLocalFile(QDir::cleanPath(QStringLiteral(HAL_C2_QML_DIR "/HalC2/Bricks/js/settingsPages.js"))).toString();
    world.brick = std::make_unique<Brick>(world,
                                          QStringLiteral("import QtQuick\nimport HalC2.Bricks\nimport HalC2.Shell\n"
                                                         "import \"%1\" as Pages\n"
                                                         "ConnectionsSettings {\n"
                                                         "  function results(query) { return Pages.searchRows(query, Shell.state, []); }\n"
                                                         "}\n")
                                              .arg(pages)
                                              .toUtf8(),
                                          size);
  }
  return *world.brick;
}

// The user opens Settings → Connections; the group is there once the shell
// has read the MC's settings and lists more than one machine.
Brick& openConnections(World& world, const QSize& size = QSize(820, 700)) {
  connected(world);
  world.bridge().dispatch(QStringLiteral("connections.open"), {});
  world.sync();
  expect(at(world.state(QStringLiteral("route")), QStringLiteral("section")).toString() == QLatin1String("/settings/connections"),
         QStringLiteral("the route is %1").arg(show(world.state(QStringLiteral("route")))));
  return page(world, size);
}

QQuickItem* group(World& world) {
  return page(world).item(QStringLiteral("load-balancing"));
}

void waitForGroup(World& world) {
  world.waitFor([&] { return group(world)->isVisible() && balancing(world).value(QStringLiteral("ready")).toBool(); },
                [&] { return QStringLiteral("the Load balancing group; the shell publishes %1").arg(show(world.state(QStringLiteral("loadBalancing")))); });
}

void unfold(World& world) {
  waitForGroup(world);
  if (!group(world)->property("open").toBool()) page(world).click(QStringLiteral("loadBalancingFold"));
  world.waitFor([&] { return page(world).item(QStringLiteral("loadBalancingBody"))->isVisible(); }, QStringLiteral("the group to open"));
}

// The preference `machine`'s row shows.
QString shown(World& world, const QString& machine) {
  return page(world).item(QStringLiteral("loadPreference:") + machine)->property("displayText").toString();
}

// Whether the group's header is within the page's view.
bool inView(World& world) {
  Brick& brick = page(world);
  brick.grab();  // layouts settle on the window's polish
  const QQuickItem* header = brick.item(QStringLiteral("loadBalancingFold"));
  const qreal top = header->mapToItem(brick.root(), QPointF(0, 0)).y();
  return top >= 0 && top + header->height() <= brick.root()->height();
}

// The user flips the group's switch.
void turn(World& world, bool on) {
  openConnections(world);
  waitForGroup(world);
  page(world).click(QStringLiteral("loadBalancingEnabled"));
  world.waitFor([&] { return fakeConfig(world.mc).settings.value(kEnabled).toBool() == on &&
                             balancing(world).value(QStringLiteral("enabled")).toBool() == on; },
                [&] { return QStringLiteral("load balancing to be %1; the MC holds %2")
                                 .arg(on ? QStringLiteral("on") : QStringLiteral("off"), show(fakeConfig(world.mc).settings.toVariantMap())); });
}

// What a settings search for `query` finds.
QVariantList results(World& world, const QString& query) {
  QVariant found;
  QMetaObject::invokeMethod(page(world).root(), "results", Q_RETURN_ARG(QVariant, found), Q_ARG(QVariant, query.toLower()));
  if (found.userType() == qMetaTypeId<QJSValue>()) found = found.value<QJSValue>().toVariant();
  return found.toList();
}

void sendFirstMessage(World& world) {
  world.bridge().dispatch(QStringLiteral("composer.submit"),
                          QVariantMap{{QStringLiteral("text"), kPrompt}, {QStringLiteral("intent"), QStringLiteral("foreground")}});
}

// The one thread the shell launched is `machine`'s, in its checkout of the
// shared project, after asking the MC about the user's pick (or without
// asking, for a draft tied to its machine); the window then shows it there.
void startsOn(World& world, const QString& machine) {
  const FakeLaunches& launches = world.mc.part<FakeLaunches>();
  world.waitFor([&] { return !launches.calls.isEmpty(); }, QStringLiteral("a launch; the MC got none"));
  world.sync();
  const FakePlacement& fake = placement(world);
  const QJsonObject launch = launches.calls.constLast();
  expect(launches.calls.size() == 1 && launches.machines.constLast() == machine &&
             launch.value(QLatin1String("projectId")) == checkoutId(world.mc, machine, fake.project) &&
             launch.value(QLatin1String("initialMessage")).toObject().value(QLatin1String("text")) == kPrompt,
         QStringLiteral("the shell launched %1 threads, the last on %2: %3")
             .arg(launches.calls.size())
             .arg(launches.machines.constLast(), show(launch.toVariantMap())));
  if (fake.tied) {
    expect(fake.asked.isEmpty(), QStringLiteral("the MC was asked where to start it: %1").arg(show(fake.asked.value(0).payload.toVariantMap())));
  } else {
    const FakeMc::Rpc asked = fake.asked.value(0);
    expect(fake.asked.size() == 1 && (asked.environment.isEmpty() || asked.environment == world.mc.environmentId) &&
               asked.payload.value(QLatin1String("environmentId")) == world.mc.environmentId &&
               asked.payload.value(QLatin1String("projectId")) == fake.project &&
               asked.payload.value(QLatin1String("instanceId")) ==
                   launch.value(QLatin1String("modelSelection")).toObject().value(QLatin1String("instanceId")),
           QStringLiteral("the MC was asked %1 times, first of \"%2\": %3")
               .arg(fake.asked.size())
               .arg(asked.environment, show(asked.payload.toVariantMap())));
  }
  const QString threadKey = machine + QLatin1Char(':') + launch.value(QLatin1String("threadId")).toString();
  world.waitFor([&] { return world.native().controller<NavigationController>()->threadKey() == threadKey; },
                [&] { return QStringLiteral("%1; the route is %2").arg(threadKey, show(world.state(QStringLiteral("route")))); });
}

const Steps steps([] {
  const QString q = kQuoted;

  // The machines, as the MC finds them when it is asked.
  step(QStringLiteral("load balancing is on"), [](World& world, const Captures&, const Table&) {
    saveElsewhere(world.mc, kEnabled, true);
  });
  step(QStringLiteral("%1 is busy and %1 is idle").arg(q), [](World& world, const Captures& c, const Table&) {
    placement(world).elsewhere = c[1];
  });
  step(QStringLiteral("both machines are equally idle"), [](World& world, const Captures&, const Table&) {
    placement(world).elsewhere.clear();
  });
  // A machine the MC passes over. One that is offline is UsageSteps' step.
  step(QStringLiteral("%1 (is set to manual only|does not answer in time|is at 95% CPU|has 5% of memory free|"
                      "does not have the chosen provider signed in|instead has no checkout of the repository)")
           .arg(q),
       [](World& world, const Captures& c, const Table&) {
         FakePlacement& fake = placement(world);
         if (c[1] == QLatin1String("instead has no checkout of the repository")) {
           world.mc.peerRows[c[0]].remove(checkoutId(world.mc, c[0], fake.project));
           return;
         }
         if (c[1] == QLatin1String("is set to manual only")) {
           QJsonObject saved = weights(world);
           saved.insert(c[0], 0);
           saveElsewhere(world.mc, kWeights, saved);
         }
         if (fake.elsewhere == c[0]) fake.elsewhere.clear();
       });
  step(QStringLiteral("the user prefers %1 and sets %1 to less often").arg(q), [](World& world, const Captures& c, const Table&) {
    connected(world);
    world.waitFor([&] { return balancing(world).value(QStringLiteral("ready")).toBool(); },
                  [&] { return QStringLiteral("load balancing's settings; the shell publishes %1").arg(show(world.state(QStringLiteral("loadBalancing")))); });
    const auto prefer = [&](const QString& machine, int weight) {
      world.bridge().dispatch(QStringLiteral("loadBalancing.prefer"),
                              QVariantMap{{QStringLiteral("environmentId"), machine}, {QStringLiteral("weight"), weight}});
      world.waitFor([&] { return weights(world).value(machine) == weight; },
                    [&] { return QStringLiteral("%1 at %2; the MC holds %3").arg(machine).arg(weight).arg(show(weights(world).toVariantMap())); });
    };
    prefer(c[0], 100);
    prefer(c[1], 25);
  });
  // The little more room the other has is outweighed by the preferences saved.
  step(QStringLiteral("%1 is somewhat busier than %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject saved = weights(world);
    placement(world).elsewhere = saved.value(c[0]).toInt(50) > saved.value(c[1]).toInt(50) ? c[0] : QString();
  });

  // The first send.
  step(QStringLiteral("the user starts a new thread in %1 on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(c[1] == world.mc.environmentId, QStringLiteral("the shell is connected to %1").arg(world.mc.environmentId));
    connected(world);
    world.openDraft(c[0]);
    world.waitFor([&] { return world.state(QStringLiteral("workspace")).toMap().value(QStringLiteral("isDraft")).toBool(); },
                  [&] { return QStringLiteral("the draft; the header shows %1").arg(show(world.state(QStringLiteral("workspace")))); });
    sendFirstMessage(world);
  });
  step(QStringLiteral("the user sends the first message"), [](World& world, const Captures&, const Table&) {
    sendFirstMessage(world);
  });
  step(QStringLiteral("the thread starts on %1(?: in its checkout of %1)?").arg(q), [](World& world, const Captures& c, const Table&) {
    startsOn(world, c[0]);
  });

  // The settings.
  step(QStringLiteral("only one machine is connected"), [](World& world, const Captures&, const Table&) {
    connected(world);
  });
  step(QStringLiteral("the user opens connection settings"), [](World& world, const Captures&, const Table&) {
    openConnections(world);
  });
  step(QStringLiteral("load balancing is not offered"), [](World& world, const Captures&, const Table&) {
    world.sync();
    world.waitFor([&] { return world.native().controller<SettingsController>()->ready(); }, QStringLiteral("the shell to read the MC's settings"));
    const QVariant published = world.state(QStringLiteral("loadBalancing"));
    expect(!published.isValid() || published.isNull(), QStringLiteral("the shell publishes %1").arg(show(published)));
    expect(!group(world)->isVisible(), QStringLiteral("the Connections page shows the Load balancing group"));
    for (const QVariant& result : results(world, QStringLiteral("load balancing"))) {
      expect(at(result, QStringLiteral("label")).toString() != QLatin1String("Load balancing"), QStringLiteral("settings search finds Load balancing"));
    }
  });

  // connections/environments.feature: the group's switch and preferences.
  step(QStringLiteral("a client paired with two environments"), [](World& world, const Captures&, const Table&) {
    cluster(world.mc, QStringLiteral("laptop"), kServer);
    connected(world);
  });
  step(QStringLiteral("an environment's saved load weight is (\\d+)"), [](World& world, const Captures& c, const Table&) {
    saveElsewhere(world.mc, kEnabled, true);
    saveElsewhere(world.mc, kWeights, QJsonObject{{kServer, c[0].toInt()}});
  });
  step(QStringLiteral("the user opens load balancing"), [](World& world, const Captures&, const Table&) {
    openConnections(world);
    unfold(world);
  });
  step(QStringLiteral("the environment shows %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return shown(world, kServer) == c[0]; },
                  [&] { return QStringLiteral("%1 to show %2; it shows %3").arg(kServer, c[0], shown(world, kServer)); });
  });
  step(QStringLiteral("load balancing is on with preferences set"), [](World& world, const Captures&, const Table&) {
    saveElsewhere(world.mc, kEnabled, true);
    saveElsewhere(world.mc, kWeights, QJsonObject{{kServer, 100}, {world.mc.environmentId, 25}});
  });
  step(QStringLiteral("the user turns load balancing off"), [](World& world, const Captures&, const Table&) {
    turn(world, false);
  });
  step(QStringLiteral("turns it on again"), [](World& world, const Captures&, const Table&) {
    turn(world, true);
  });
  step(QStringLiteral("the earlier preferences are back"), [](World& world, const Captures&, const Table&) {
    const QJsonObject kept{{kServer, 100}, {world.mc.environmentId, 25}};
    expect(weights(world) == kept, QStringLiteral("the MC holds %1").arg(show(weights(world).toVariantMap())));
    unfold(world);
    world.waitFor([&] { return shown(world, kServer) == QLatin1String("Prefer") && shown(world, world.mc.environmentId) == QLatin1String("Less often"); },
                  [&] { return QStringLiteral("the preferences; %1 shows %2 and %3 shows %4")
                                   .arg(kServer, shown(world, kServer), world.mc.environmentId, shown(world, world.mc.environmentId)); });
    expect(page(world).item(QStringLiteral("loadPreference:") + kServer)->isEnabled(), QStringLiteral("the preferences cannot be changed"));
  });

  // settings/search-and-navigation.feature: the search result for the group.
  // The page is short, so the group starts below its view.
  step(QStringLiteral("the \"Load balancing\" group on the Connections page is folded"), [](World& world, const Captures&, const Table&) {
    world.mc.join(kServer);
    openConnections(world, QSize(820, 140));
    waitForGroup(world);
    expect(!group(world)->property("open").toBool() && !inView(world), QStringLiteral("the group is open or already in view"));
  });
  // What SettingsNav.qml's result row does when it is clicked.
  step(QStringLiteral("the user opens the search result %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantList found = results(world, c[0]);
    for (const QVariant& result : found) {
      if (at(result, QStringLiteral("label")).toString() != c[0]) continue;
      world.bridge().dispatch(QStringLiteral("settings.openResult"),
                              QVariantMap{{QStringLiteral("to"), at(result, QStringLiteral("to"))},
                                          {QStringLiteral("targetId"), at(result, QStringLiteral("targetId"))}});
      return;
    }
    fail(QStringLiteral("the search finds %1").arg(show(found)));
  });
  step(QStringLiteral("the \"Load balancing\" group is open"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return group(world)->property("open").toBool() && page(world).item(QStringLiteral("loadBalancingBody"))->isVisible(); },
                  [&] { return QStringLiteral("the group to open; the route is %1").arg(show(world.state(QStringLiteral("route")))); });
  });
  step(QStringLiteral("the page brings the setting into view"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return inView(world); }, QStringLiteral("the group to be scrolled into view"));
  });
});

}  // namespace

void shareProject(FakeMc& mc, const QString& name) {
  mc.part<FakePlacement>().project = name;
  const auto checkout = [&](const QString& machine, const QString& root) {
    const QString id = checkoutId(mc, machine, name);
    return QJsonObject{{QStringLiteral("id"), id},
                       {QStringLiteral("title"), name},
                       {QStringLiteral("workspaceRoot"), root},
                       {QStringLiteral("repositoryIdentity"), QJsonObject{{QStringLiteral("canonicalKey"), repositoryOf(name)}}},
                       {QStringLiteral("scripts"), QJsonArray()},
                       {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                       {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")}};
  };
  mc.projects.insert(name, checkout(mc.environmentId, QStringLiteral("/work/") + name));
  for (const QString& machine : std::as_const(mc.members)) {
    mc.sendPeerRow(machine, checkoutId(mc, machine, name), checkout(machine, QStringLiteral("/srv/") + name), QStringLiteral("project"));
  }
}

QString clusterWithRoomElsewhere(World& world, const QString& machine) {
  const QString project = QStringLiteral("api");
  cluster(world.mc, machine, kServer);
  shareProject(world.mc, project);
  placement(world).elsewhere = kServer;
  return project;
}
