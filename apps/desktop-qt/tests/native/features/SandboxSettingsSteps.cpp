// Settings → Review sandboxes (SandboxSettingsController, SandboxSettings.qml):
// the @shared Settings scenarios of features/mc/platform/openshell.feature,
// against a MC whose `server.getOpenShellStatus` this file fakes from what the
// scenario says about the machine.

#include <QJsonArray>
#include <QJsonObject>

#include "Brick.h"
#include "FakeMc.h"
#include "Harness.h"
#include "World.h"

namespace {

const QString kPinned = QStringLiteral("0.1.7");
const QString kIntelMac = QStringLiteral("OpenShell supports Apple Silicon Macs only. This MC runs as x86_64: an Intel Mac, or an MC running under Rosetta.");
const QString kNotInstalled = QStringLiteral("Run `hal-c2-service openshell install` to install it.");
const QString kFailure = QStringLiteral("OpenShell's status did not answer within 20 seconds. Try again, or run `hal-c2-service openshell status` on the MC's machine.");

// What the MC's machine is, as the scenario says.
struct FakeOpenShell {
  bool intelMac = false;
  bool gateway = false;  // the user runs a gateway
  bool pointed = false;  // and pointed the MC at it
  bool failing = false;
};

QJsonObject status(const FakeOpenShell& machine) {
  const auto problem = [](const QString& code, const QString& message) {
    return QJsonArray{QJsonObject{{QStringLiteral("code"), code}, {QStringLiteral("message"), message}}};
  };
  const bool ready = !machine.intelMac && machine.gateway && machine.pointed;
  return {{QStringLiteral("supported"), !machine.intelMac},
          {QStringLiteral("ready"), ready},
          {QStringLiteral("mode"), ready ? QJsonValue(QStringLiteral("external")) : QJsonValue()},
          {QStringLiteral("version"), ready ? QJsonValue(kPinned) : QJsonValue()},
          {QStringLiteral("pinnedVersion"), kPinned},
          {QStringLiteral("problems"), machine.intelMac ? problem(QStringLiteral("intel-mac"), kIntelMac)
                                       : ready          ? QJsonArray()
                                                        : problem(QStringLiteral("not-installed"), kNotInstalled)}};
}

const FakeMc::Extension extension([](FakeMc& mc) {
  mc.onRpc(QStringLiteral("server.getOpenShellStatus"), [&mc](const FakeMc::Rpc& rpc) {
    const FakeOpenShell& machine = mc.part<FakeOpenShell>();
    if (machine.failing) mc.refuse(rpc, kFailure, {{QStringLiteral("_tag"), QStringLiteral("ServerOpenShellStatusError")}});
    else mc.reply(rpc, status(machine));
  });
});

FakeOpenShell& machine(World& world) {
  return world.mc.part<FakeOpenShell>();
}

QVariantMap section(World& world) {
  return world.state(QStringLiteral("sandboxSettings")).toMap();
}

QString text(World& world, const QString& objectName) {
  world.brick->grab();
  return world.brick->item(objectName)->property("text").toString();
}

// Waits for the read the page asked for to land.
void landed(World& world) {
  world.waitFor([&] { return !section(world).value(QStringLiteral("loading"), true).toBool(); },
                [&] { return QStringLiteral("the sandbox status to land; the section is %1").arg(show(section(world))); });
}

void expectSummary(World& world, const QString& summary) {
  expect(text(world, QStringLiteral("sandboxSummary")) == summary,
         QStringLiteral("the page says \"%1\", not \"%2\"").arg(text(world, QStringLiteral("sandboxSummary")), summary));
}

const Steps steps([] {
  step(QStringLiteral("a Linux machine with rootless Podman"), [](World&, const Captures&, const Table&) {});
  step(QStringLiteral("a machine that is an Intel Mac"), [](World& world, const Captures&, const Table&) { machine(world).intelMac = true; });
  step(QStringLiteral("a gateway the user runs, with its CA and a client certificate"),
       [](World& world, const Captures&, const Table&) { machine(world).gateway = true; });
  step(QStringLiteral("the user points the MC at it"), [](World& world, const Captures&, const Table&) { machine(world).pointed = true; });
  step(QStringLiteral("the MC cannot say whether review sandboxes can run"),
       [](World& world, const Captures&, const Table&) { machine(world).failing = true; });

  step(QStringLiteral("the user opens the sandbox settings"), [](World& world, const Captures&, const Table&) {
    if (world.shellSubscriptions() == 0) {
      world.connect();
      world.sync();
    }
    world.bridge().dispatch(QStringLiteral("settings.open"), {});
    world.bridge().dispatch(QStringLiteral("settings.navigate"), QVariantMap{{QStringLiteral("to"), QStringLiteral("/settings/sandboxes")}});
    landed(world);
    world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nSandboxSettings {}\n", QSize(900, 700));
  });
  step(QStringLiteral("the MC can say again and the user refreshes the sandbox settings"), [](World& world, const Captures&, const Table&) {
    machine(world).failing = false;
    world.brick->click(QStringLiteral("sandboxRefresh"));
    landed(world);
  });

  step(QStringLiteral("they read that OpenShell does not run on an Intel Mac"), [](World& world, const Captures&, const Table&) {
    expectSummary(world, QStringLiteral("Review sandboxes can't run on this machine."));
    expect(text(world, QStringLiteral("sandboxProblem:intel-mac")) == kIntelMac, QStringLiteral("the page does not say why"));
  });
  step(QStringLiteral("they read that OpenShell is not installed, and how to install it"), [](World& world, const Captures&, const Table&) {
    expectSummary(world, QStringLiteral("Review sandboxes can't run here yet."));
    expect(text(world, QStringLiteral("sandboxProblem:not-installed")) == kNotInstalled, QStringLiteral("the page does not say how to install it"));
    expect(text(world, QStringLiteral("sandboxDetail")).contains(kPinned), QStringLiteral("the page does not name the version the MC pins"));
  });
  step(QStringLiteral("they read that review sandboxes can run here"), [](World& world, const Captures&, const Table&) {
    expectSummary(world, QStringLiteral("Review sandboxes can run here."));
    expect(text(world, QStringLiteral("sandboxDetail")) == QStringLiteral("OpenShell %1, a gateway you run.").arg(kPinned),
           QStringLiteral("the detail is \"%1\"").arg(text(world, QStringLiteral("sandboxDetail"))));
    expect(world.brick->find(QStringLiteral("sandboxProblem:not-installed")) == nullptr, QStringLiteral("the page still lists a problem"));
  });
  step(QStringLiteral("they read that the sandbox status could not be read"), [](World& world, const Captures&, const Table&) {
    expectSummary(world, QStringLiteral("Could not read whether review sandboxes can run here."));
    expect(text(world, QStringLiteral("sandboxDetail")) == kFailure, QStringLiteral("the page does not say what the MC said"));
    expect(world.brick->item(QStringLiteral("sandboxRefresh"))->isEnabled(), QStringLiteral("the user cannot ask again"));
  });
});

}  // namespace
