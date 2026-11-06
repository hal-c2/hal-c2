// Switching a cluster member off and asking it to reconnect, from the
// desktop: the thread's notice about its computer offering both
// (ComputerNoticeController, features/connections/connection-health.feature)
// and the Cluster settings page's switch
// (features/settings/connections.feature).

#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>
#include <QQuickWindow>

#include "ComputerNotices.h"
#include "FakeCluster.h"
#include "Harness.h"
#include "McClient.h"
#include "NativeShell.h"
#include "ShellStore.h"
#include "Stream.h"
#include "ToldReason.h"
#include "World.h"

namespace {

using namespace computerNotices;

// The computer whose thread the scenario opened last.
struct Shown {
  QString name;
};

// What the notice offered a second before the 20 seconds were up.
struct Offered {
  bool reconnect = false;
  bool disconnect = false;
};

void pass(World& world, qint64 seconds) { world.setTime(world.now().addSecs(seconds)); }

// The notice's button `name` ("threadComputerReconnect",
// "threadComputerDisconnect") while it is shown.
QQuickItem* button(World& world, const QString& name) {
  world.sync();
  return shownNamed(window(world), name).value(0);
}

void waitForButton(World& world, const QString& name, bool shown) {
  world.waitFor(
      [&] { return (button(world, name) != nullptr) == shown; },
      [&] { return QStringLiteral("%1 to be %2; %3").arg(name, shown ? "shown" : "hidden", describe(world)); });
}

void click(World& world, const QString& name) {
  waitForButton(world, name, true);
  QMetaObject::invokeMethod(button(world, name), "clicked");
  world.sync();
}

// `name` is a member of this machine's cluster as the MC lists it.
void listMember(World& world, const QString& name) {
  FakeCluster& cluster = world.mc.part<FakeCluster>();
  for (const QJsonValue& member : std::as_const(cluster.members)) {
    if (member.toObject().value(QLatin1String("id")) == name) return;
  }
  cluster.members.append(QJsonObject{{QStringLiteral("id"), name},
                                     {QStringLiteral("label"), name},
                                     {QStringLiteral("addresses"), QJsonArray()},
                                     {QStringLiteral("connected"), true}});
}

QJsonObject member(World& world, const QString& name) {
  for (const QJsonValue& value : std::as_const(world.mc.part<FakeCluster>().members)) {
    if (value.toObject().value(QLatin1String("id")) == name) return value.toObject();
  }
  return {};
}

std::optional<QJsonObject> asked(World& world, const QString& method) {
  world.sync();
  for (const auto& [called, payload] : world.mc.part<FakeCluster>().calls) {
    if (called == method) return payload;
  }
  return std::nullopt;
}

// `name` has been down, the MC still trying it, for `seconds`, with its thread
// open.
void downFor(World& world, const QString& name, qint64 seconds) {
  if (world.mc.part<Shown>().name != name) lookAt(world, name);
  world.mc.part<Shown>().name = name;
  listMember(world, name);
  setOnline(world, name, false);
  pass(world, seconds);
}

// The MC refuses `method` from here on, saying `reason`.
void refuse(World& world, const QString& method, const QString& reason) {
  world.mc.part<ToldReason>().reason = reason;
  world.mc.onRpc(method, [&world, reason](const FakeMc::Rpc& rpc) {
    world.mc.refuse(rpc, reason,
                    {{QStringLiteral("_tag"), QStringLiteral("ClusterError")},
                     {QStringLiteral("reason"), QStringLiteral("unreachable")}});
  });
}

QVariantMap route(World& world) { return world.state(QStringLiteral("route")).toMap(); }

const Steps steps([] {
  const QString q = kQuoted;

  // The thread's notice.
  step(QStringLiteral("the user is looking at a thread on the saved computer %1").arg(q),
       [](World& world, const Captures& c, const Table&) {
         lookAt(world, c[0]);
         world.mc.part<Shown>().name = c[0];
         listMember(world, c[0]);
       });
  step(QStringLiteral("%1 has been offline or reconnecting for 20 seconds").arg(q),
       [](World& world, const Captures& c, const Table&) {
         downFor(world, c[0], 0);
         world.mc.setTrying(c[0], false);
         pass(world, 19);
         waitForButton(world, QStringLiteral("threadComputerReconnect"), true);
         world.mc.part<Offered>() = {button(world, QStringLiteral("threadComputerReconnect")) != nullptr,
                                     button(world, QStringLiteral("threadComputerDisconnect")) != nullptr};
         pass(world, 1);
       });
  step(QStringLiteral("the notice about %1 offers to disconnect it").arg(q),
       [](World& world, const Captures& c, const Table&) {
         waitForButton(world, QStringLiteral("threadComputerDisconnect"), true);
         const QVariantMap notice = world.state(QStringLiteral("threadComputer")).toMap();
         expect(notice.value(QStringLiteral("environmentId")) == c[0], describe(world));
       });
  step(QStringLiteral("before 20 seconds it offers only to reconnect"),
       [](World& world, const Captures&, const Table&) {
         const Offered offered = world.mc.part<Offered>();
         expect(offered.reconnect && !offered.disconnect,
                QStringLiteral("at 19 seconds the notice offered reconnect %1, disconnect %2")
                    .arg(offered.reconnect)
                    .arg(offered.disconnect));
       });
  step(QStringLiteral("the user is looking at a thread on %1 that has been "
                      "unavailable for 15 seconds")
           .arg(q),
       [](World& world, const Captures& c, const Table&) { downFor(world, c[0], 15); });
  step(QStringLiteral("the user opens a thread on %1 that is also unavailable").arg(q),
       [](World& world, const Captures& c, const Table&) {
         lookAt(world, c[0]);
         setOnline(world, c[0], false);
       });
  step(QStringLiteral("disconnecting %1 is offered only 20 seconds after it "
                      "became unavailable")
           .arg(q),
       [](World& world, const Captures& c, const Table&) {
         // Past the 20 seconds of the computer shown before it.
         pass(world, 5);
         waitForButton(world, QStringLiteral("threadComputerDisconnect"), false);
         pass(world, 14);
         waitForButton(world, QStringLiteral("threadComputerDisconnect"), false);
         pass(world, 1);
         waitForButton(world, QStringLiteral("threadComputerDisconnect"), true);
         expect(world.state(QStringLiteral("threadComputer")).toMap().value(QStringLiteral("environmentId")) == c[0],
                describe(world));
       });
  step(QStringLiteral("a thread on %1 which has been unavailable for 10 seconds").arg(q),
       [](World& world, const Captures& c, const Table&) { downFor(world, c[0], 10); });
  step(QStringLiteral("%1 connects again").arg(q),
       [](World& world, const Captures& c, const Table&) { setOnline(world, c[0], true); });
  step(QStringLiteral("no offer to disconnect %1 is shown").arg(q), [](World& world, const Captures&, const Table&) {
    // Past 20 seconds from when it first dropped.
    pass(world, 15);
    expect(button(world, QStringLiteral("threadComputerDisconnect")) == nullptr &&
               world.state(QStringLiteral("threadComputer")).isNull(),
           describe(world));
  });
  step(QStringLiteral("if it drops again the 20 seconds start over"), [](World& world, const Captures&, const Table&) {
    const QString name = world.mc.part<Shown>().name;
    setOnline(world, name, false);
    pass(world, 19);
    waitForButton(world, QStringLiteral("threadComputerDisconnect"), false);
    pass(world, 1);
    waitForButton(world, QStringLiteral("threadComputerDisconnect"), true);
  });
  step(QStringLiteral("the user is looking at a thread on (the computer serving "
                      "this client|a backend running on this same desktop)"),
       [](World& world, const Captures& c, const Table&) {
         if (c[0].startsWith(QLatin1String("the computer"))) {
           window(world);
           world.mc.projects.insert(stream::kProject,
                                    {{QStringLiteral("id"), stream::kProject},
                                     {QStringLiteral("title"), stream::kProject},
                                     {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + stream::kProject},
                                     {QStringLiteral("scripts"), QJsonArray()}});
           world.mc.sendRow(stream::kProject, world.mc.projects.value(stream::kProject), QStringLiteral("project"));
           stream::lookAtThread(world, stream::kProject);
           return;
         }
         // Another MC of the cluster that says it runs on this machine.
         world.mc.peerPlatforms.insert(QStringLiteral("desk"), {{QStringLiteral("machineId"), kThisMachine}});
         lookAt(world, QStringLiteral("desk"));
       });
  step(QStringLiteral("(the computer serving this client|a backend running on this same "
                      "desktop) has been unavailable for more than 20 seconds"),
       [](World& world, const Captures& c, const Table&) {
         if (c[0].startsWith(QLatin1String("the computer"))) {
           world.native().client()->setRetryDelays({600000});
           world.mc.stopAccepting();
           world.mc.drop();
           world.waitFor([&] { return !world.native().client()->isReady(); }, QStringLiteral("the connection to drop"));
         } else {
           setOnline(world, QStringLiteral("desk"), false);
         }
         pass(world, 25);
       });
  step(QStringLiteral("the notice does not offer to disconnect it"), [](World& world, const Captures&, const Table&) {
    world.sync();
    QList<QQuickItem*> offers = shownNamed(window(world), QStringLiteral("threadComputerDisconnect"));
    const QVariant notice = world.state(QStringLiteral("threadComputer"));
    expect(offers.isEmpty() && !notice.toMap().value(QStringLiteral("canDisconnect")).toBool(), describe(world));
    // A backend of the cluster still has its notice: it is only the offer
    // that is missing.
    if (!notice.isNull()) {
      expect(!notice.toMap().value(QStringLiteral("kind")).toString().isEmpty(), describe(world));
    }
  });
  step(QStringLiteral("%1 has been unavailable for 20 seconds").arg(q),
       [](World& world, const Captures& c, const Table&) {
         downFor(world, c[0], 20);
         waitForButton(world, QStringLiteral("threadComputerDisconnect"), true);
       });
  step(QStringLiteral("switching %1 off will fail").arg(q), [](World& world, const Captures& c, const Table&) {
    refuse(world, QStringLiteral("cluster.switch"),
           QStringLiteral("%1 could not be told it is switched off.").arg(c[0]));
  });
  step(QStringLiteral("the user chooses to disconnect it from the thread's notice"),
       [](World& world, const Captures&, const Table&) { click(world, QStringLiteral("threadComputerDisconnect")); });
  step(QStringLiteral("%1 is switched off in connections").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return member(world, c[0]).value(QLatin1String("off")).toBool(); },
                  [&] {
                    return QStringLiteral("the MC to switch %1 off; it is %2")
                        .arg(c[0], show(member(world, c[0]).toVariantMap()));
                  });
    const std::optional<QJsonObject> payload = asked(world, QStringLiteral("cluster.switch"));
    expect(payload && payload->value(QLatin1String("on")) == QJsonValue(false),
           QStringLiteral("cluster.switch was asked %1").arg(show(payload ? payload->toVariantMap() : QVariantMap())));
  });
  step(QStringLiteral("its threads are hidden"), [](World& world, const Captures&, const Table&) {
    const QString name = world.mc.part<FakeCluster>().switchedOff.keys().value(0);
    world.waitFor([&] { return !name.isEmpty() && !world.native().store()->servesEnvironment(name); },
                  QStringLiteral("the shell to drop %1").arg(name));
  });
  step(QStringLiteral("the user is taken to the home screen"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return route(world).value(QStringLiteral("kind")) == QLatin1String("home"); },
                  [&] { return QStringLiteral("the route is %1").arg(show(route(world))); });
  });
  step(QStringLiteral("the user stays on the thread"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(route(world).value(QStringLiteral("kind")) == QLatin1String("thread"),
           QStringLiteral("the route is %1").arg(show(route(world))));
  });
  // "%1 is offline" (UsageSteps) leaves the computer given up; its thread is opened here.
  step(QStringLiteral("reconnecting will fail"), [](World& world, const Captures&, const Table&) {
    refuse(world, QStringLiteral("cluster.reconnect"), QStringLiteral("This machine is not clustered."));
    const QString name = world.mc.givenUp.isEmpty() ? QString() : *world.mc.givenUp.cbegin();
    if (!name.isEmpty() && world.mc.part<Shown>().name != name) {
      // Its thread opens while it answers, then it is given up on again.
      world.mc.setOnline(name, true);
      downFor(world, name, 0);
      world.mc.setTrying(name, false);
    }
    waitForButton(world, QStringLiteral("threadComputerReconnect"), true);
  });
  step(QStringLiteral("the user chooses to reconnect it from the thread's notice"),
       [](World& world, const Captures&, const Table&) { click(world, QStringLiteral("threadComputerReconnect")); });
  step(QStringLiteral("%1 stops trying to connect").arg(q), [](World& world, const Captures& c, const Table&) {
    setOnline(world, c[0], false);
    world.mc.setTrying(c[0], false);
  });
  step(QStringLiteral("the user can ask it to reconnect"), [](World& world, const Captures&, const Table&) {
    const QString name =
        world.state(QStringLiteral("threadComputer")).toMap().value(QStringLiteral("environmentId")).toString();
    click(world, QStringLiteral("threadComputerReconnect"));
    world.waitFor([&] { return asked(world, QStringLiteral("cluster.reconnect")).has_value(); },
                  QStringLiteral("the MC to be asked to reconnect"));
    expect(asked(world, QStringLiteral("cluster.reconnect"))->value(QLatin1String("id")) == name,
           QStringLiteral("it was asked for another"));
    // Trying again, the notice no longer says it is offline.
    world.waitFor(
        [&] {
          return world.state(QStringLiteral("threadComputer")).toMap().value(QStringLiteral("kind")) !=
                 QLatin1String("offline");
        },
        [&] { return describe(world); });
  });

  // The Cluster settings page's switch.
  step(QStringLiteral("%1 is connected").arg(q), [](World& world, const Captures& c, const Table&) {
    listMember(world, c[0]);
    world.mc.join(c[0]);
    world.waitFor([&] { return world.native().store()->environmentOnline(c[0]); },
                  QStringLiteral("%1 to connect").arg(c[0]));
  });
  step(QStringLiteral("the user switches %1 (off|on)").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("cluster.open"), {});
    world.waitFor(
        [&] { return at(world.state(QStringLiteral("cluster")), QStringLiteral("status.clustered")).toBool(); },
        QStringLiteral("the Cluster page to read the cluster"));
    world.bridge().dispatch(
        QStringLiteral("cluster.switch"),
        QVariantMap{{QStringLiteral("id"), c[0]}, {QStringLiteral("on"), c[1] == QLatin1String("on")}});
  });
  step(QStringLiteral("the user switches it back on"), [](World& world, const Captures&, const Table&) {
    const QString name = world.mc.part<FakeCluster>().switchedOff.keys().value(0);
    expect(!name.isEmpty(), QStringLiteral("nothing is switched off"));
    world.bridge().dispatch(QStringLiteral("cluster.switch"),
                            QVariantMap{{QStringLiteral("id"), name}, {QStringLiteral("on"), true}});
  });
  step(QStringLiteral("this device disconnects from %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return !world.native().store()->servesEnvironment(c[0]); },
                  QStringLiteral("the shell to drop %1").arg(c[0]));
  });
  step(QStringLiteral("%1 stays listed as off").arg(q), [](World& world, const Captures& c, const Table&) {
    const auto listedOff = [&] {
      for (const QVariant& value :
           at(world.state(QStringLiteral("cluster")), QStringLiteral("status.members")).toList()) {
        if (value.toMap().value(QStringLiteral("id")) == c[0])
          return value.toMap().value(QStringLiteral("off")).toBool();
      }
      return false;
    };
    world.waitFor(listedOff, [&] {
      return QStringLiteral("the Cluster page lists %1").arg(show(world.state(QStringLiteral("cluster"))));
    });
  });
  step(QStringLiteral("this device connects to %1 again").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return world.native().store()->environmentOnline(c[0]); },
                  QStringLiteral("%1 to connect again").arg(c[0]));
    world.waitFor(
        [&] {
          return !at(world.state(QStringLiteral("cluster")), QStringLiteral("status.members")).toList().isEmpty() &&
                 !at(world.state(QStringLiteral("cluster")), QStringLiteral("status.members"))
                      .toList()
                      .first()
                      .toMap()
                      .value(QStringLiteral("off"))
                      .toBool();
        },
        [&] { return QStringLiteral("the Cluster page lists %1").arg(show(world.state(QStringLiteral("cluster")))); });
  });
});

}  // namespace
