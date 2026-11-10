// Settings → Review sandboxes on the phone (the desktop's SandboxSettings
// brick and SandboxSettingsController): the @shared Settings scenarios of
// features/mc/platform/openshell.feature, against a MC whose
// `server.getOpenShellStatus` this file fakes from what the scenario says
// about its machine.

#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>

#include "FakeMc.h"
#include "Harness.h"
#include "Phone.h"
#include "World.h"

namespace {

using S = QString;

const S kPinned = S("0.1.7");
const S kIntelMac = S("OpenShell supports Apple Silicon Macs only. This MC runs as x86_64: an Intel Mac, or an MC running under Rosetta.");
const S kNotInstalled = S("Run `hal-c2-service openshell install` to install it.");
const S kFailure = S("OpenShell's status did not answer within 20 seconds. Try again, or run `hal-c2-service openshell status` on the MC's machine.");

// What the MC's machine is, as the scenario says.
struct FakeOpenShell {
  bool intelMac = false;
  bool gateway = false;
  bool pointed = false;
  bool failing = false;
};

QJsonObject status(const FakeOpenShell& machine) {
  const auto problem = [](const S& code, const S& message) { return QJsonArray{QJsonObject{{S("code"), code}, {S("message"), message}}}; };
  const bool ready = !machine.intelMac && machine.gateway && machine.pointed;
  return {{S("supported"), !machine.intelMac},
          {S("ready"), ready},
          {S("mode"), ready ? QJsonValue(S("external")) : QJsonValue()},
          {S("version"), ready ? QJsonValue(kPinned) : QJsonValue()},
          {S("pinnedVersion"), kPinned},
          {S("problems"), machine.intelMac ? problem(S("intel-mac"), kIntelMac)
                          : ready          ? QJsonArray()
                                           : problem(S("not-installed"), kNotInstalled)}};
}

const FakeMc::Extension extension([](FakeMc& mc) {
  mc.onRpc(S("server.getOpenShellStatus"), [&mc](const FakeMc::Rpc& rpc) {
    const FakeOpenShell& machine = mc.part<FakeOpenShell>();
    if (machine.failing) mc.refuse(rpc, kFailure, {{S("_tag"), S("ServerOpenShellStatusError")}});
    else mc.reply(rpc, status(machine));
  });
});

FakeOpenShell& machine(World& world) {
  return world.mc.part<FakeOpenShell>();
}

QString screenTexts(World& world) {
  return world.texts().join(S(" | "));
}

// Waits for the item named `objectName` to say `text`.
void reads(World& world, const S& objectName, const S& text) {
  world.waitFor([&] { return world.find(objectName) != nullptr && world.find(objectName)->property("text").toString() == text; },
                [&] { return S("%1 to say \"%2\"; the screen says: %3").arg(objectName, text, screenTexts(world)); });
}

const Steps steps([] {
  step(S("a Linux machine with rootless Podman"), [](World&, const Captures&, const Table&) {});
  step(S("a machine that is an Intel Mac"), [](World& world, const Captures&, const Table&) { machine(world).intelMac = true; });
  step(S("a gateway the user runs, with its CA and a client certificate"), [](World& world, const Captures&, const Table&) { machine(world).gateway = true; });
  step(S("the user points the MC at it"), [](World& world, const Captures&, const Table&) { machine(world).pointed = true; });
  step(S("the MC cannot say whether review sandboxes can run"), [](World& world, const Captures&, const Table&) { machine(world).failing = true; });

  // Home's bar, Settings, and its Review sandboxes page.
  step(S("the user opens the sandbox settings"), [](World& world, const Captures&, const Table&) {
    pairWithEnvironment(world);
    world.tap(S("settings"));
    world.item(S("settingsSections"));
    QQuickItem* row = nullptr;
    world.waitFor(
        [&] {
          row = world.findWhere([](QQuickItem* candidate) {
            return candidate->objectName().startsWith(QLatin1String("settingsRow")) &&
                   candidate->property("modelData").toMap().value(S("to")).toString() == QLatin1String("/settings/sandboxes");
          });
          return row != nullptr;
        },
        [&] { return S("Review sandboxes among the settings; the screen says: %1").arg(screenTexts(world)); });
    world.tap(row);
    world.item(S("sandboxSettings"));
  });
  step(S("the MC can say again and the user refreshes the sandbox settings"), [](World& world, const Captures&, const Table&) {
    machine(world).failing = false;
    world.tap(S("sandboxRefresh"));
  });

  step(S("they read that OpenShell does not run on an Intel Mac"), [](World& world, const Captures&, const Table&) {
    reads(world, S("sandboxSummary"), S("Review sandboxes can't run on this machine."));
    reads(world, S("sandboxProblem:intel-mac"), kIntelMac);
  });
  step(S("they read that OpenShell is not installed, and how to install it"), [](World& world, const Captures&, const Table&) {
    reads(world, S("sandboxSummary"), S("Review sandboxes can't run here yet."));
    reads(world, S("sandboxProblem:not-installed"), kNotInstalled);
    reads(world, S("sandboxDetail"), S("OpenShell %1 is the version this MC pins.").arg(kPinned));
  });
  step(S("they read that review sandboxes can run here"), [](World& world, const Captures&, const Table&) {
    reads(world, S("sandboxSummary"), S("Review sandboxes can run here."));
    reads(world, S("sandboxDetail"), S("OpenShell %1, a gateway you run.").arg(kPinned));
    expect(world.find(S("sandboxProblem:not-installed")) == nullptr, S("the page still lists a problem"));
  });
  step(S("they read that the sandbox status could not be read"), [](World& world, const Captures&, const Table&) {
    reads(world, S("sandboxSummary"), S("Could not read whether review sandboxes can run here."));
    reads(world, S("sandboxDetail"), kFailure);
    expect(world.item(S("sandboxRefresh"))->isEnabled(), S("the user cannot ask again"));
  });
});

}  // namespace
