// Settings → Review sandboxes on the phone (the desktop's SandboxSettings
// brick and SandboxSettingsController): the @shared Settings scenarios of
// features/mc/platform/openshell.feature, against a MC whose
// `server.getOpenShellStatus`, `server.runOpenShellOperation` and openShell
// shape this file fakes from what the scenario says about its machine.

#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>

#include "FakeMc.h"
#include "Harness.h"
#include "Phone.h"
#include "ShellBridge.h"
#include "World.h"

namespace {

using S = QString;

const S kPinned = S("0.1.7");
const S kIntelMac = S("OpenShell supports Apple Silicon Macs only. This MC runs as x86_64: an Intel Mac, or an MC running under Rosetta.");
const S kNotInstalled = S("Press Install to install it.");
const S kNoPodman = S(
    "No rootless Podman socket. Install Podman 5 or later with your distribution's package manager, then press Install: it starts Podman's "
    "socket for you.");
const S kFailure = S("OpenShell's status did not answer within 20 seconds. Refresh to try again.");
const QStringList kInstallSteps{S("Checking this machine"), S("Checking the gateway's configuration"), S("Starting the gateway")};
const S kInstalled = S("OpenShell installed, 0.1.7, listening on https://127.0.0.1:17670.");
const S kRemoved = S("OpenShell removed.");
const S kManageReason = S(
    "Installing and managing OpenShell needs a session that can manage this machine and use its terminal (access:write, terminal:operate). "
    "Pair this device with a link that grants them.");

// What the MC's machine is, as the scenario says.
struct FakeOpenShell {
  bool intelMac = false;
  bool noPodman = false;
  bool gateway = false;
  bool pointed = false;
  bool failing = false;
  bool managed = false;       // a gateway this MC installed and runs
  int reviews = 0;            // this MC's review sandboxes on it
  bool cannotManage = false;  // paired without access:write and terminal:operate
  // The openShell shape's state: the operation running or last run.
  QJsonObject operation{{S("operation"), QJsonValue()}, {S("run"), 0}, {S("running"), false}, {S("steps"), QJsonArray()}, {S("result"), QJsonValue()}};
  // Each server.runOpenShellOperation's payload.
  QList<QJsonObject> runs;
};

QJsonObject action(const S& operation, const S& label) {
  return {{S("operation"), operation}, {S("label"), label}};
}

QJsonObject status(const FakeOpenShell& machine) {
  const auto problem = [](const S& code, const S& message) { return QJsonArray{QJsonObject{{S("code"), code}, {S("message"), message}}}; };
  const bool external = !machine.intelMac && machine.gateway && machine.pointed;
  const bool ready = machine.managed || external;
  const QJsonArray actions = machine.intelMac ? QJsonArray()
                             : machine.managed
                                 ? QJsonArray{action(S("check"), S("Check")), action(S("rotate"), S("Rotate certificates")),
                                              action(S("uninstall"), S("Uninstall"))}
                             : external ? QJsonArray{action(S("check"), S("Check")), action(S("uninstall"), S("Stop using it"))}
                                        : QJsonArray{action(S("install"), S("Install"))};
  QJsonObject answer{{S("supported"), !machine.intelMac},
          {S("ready"), ready},
          {S("mode"), machine.managed ? QJsonValue(S("managed")) : external ? QJsonValue(S("external")) : QJsonValue()},
          {S("actions"), actions},
          {S("canManage"), !machine.cannotManage},
          {S("manageReason"), machine.cannotManage ? QJsonValue(kManageReason) : QJsonValue()},
          {S("version"), ready ? QJsonValue(kPinned) : QJsonValue()},
          {S("pinnedVersion"), kPinned},
          {S("problems"), machine.intelMac ? problem(S("intel-mac"), kIntelMac)
                          : ready          ? QJsonArray()
                                           : problem(S("not-installed"), kNotInstalled)}};
  // Like the MC: no Podman is a platform problem, and Install starts its socket once it is there.
  if (machine.noPodman) {
    answer.insert(S("supported"), false);
    answer.insert(S("problems"), problem(S("podman-missing"), kNoPodman));
  }
  return answer;
}

QJsonObject result(bool ok, const QJsonValue& code, const S& message, const QJsonValue& sandboxes = QJsonValue()) {
  return {{S("ok"), ok}, {S("code"), code}, {S("message"), message}, {S("sandboxes"), sandboxes}};
}

// The operation's new state, to everyone following the openShell shape.
void emitOperation(FakeMc& mc, const QJsonObject& operation) {
  mc.part<FakeOpenShell>().operation = operation;
  for (const int id : mc.subscribers(S("openShell"))) {
    mc.send({{S("t"), S("openShell")}, {S("id"), id}, {S("operation"), operation}});
  }
}

const FakeMc::Extension extension([](FakeMc& mc) {
  mc.onShape(S("openShell"), [&mc](int id, const QJsonObject&) {
    mc.send({{S("t"), S("openShell")}, {S("id"), id}, {S("operation"), mc.part<FakeOpenShell>().operation}});
  });
  // Like the MC, the reply is the operation running, numbered; its steps and
  // outcome go to whoever follows the openShell shape.
  mc.onRpc(S("server.runOpenShellOperation"), [&mc](const FakeMc::Rpc& rpc) {
    FakeOpenShell& machine = mc.part<FakeOpenShell>();
    machine.runs.append(rpc.payload);
    if (machine.cannotManage) return mc.refuse(rpc, S("This session may not access:write."));
    const S operation = rpc.payload.value(QLatin1String("operation")).toString();
    const QJsonObject running{{S("operation"), operation}, {S("run"), machine.runs.size()}, {S("running"), true}, {S("steps"), QJsonArray()},
                              {S("result"), QJsonValue()}};
    mc.reply(rpc, running);
    emitOperation(mc, running);
    const auto finish = [&mc, running](const QStringList& steps, const QJsonObject& outcome) {
      QJsonObject done = running;
      done.insert(S("running"), false);
      done.insert(S("steps"), QJsonArray::fromStringList(steps));
      done.insert(S("result"), outcome);
      emitOperation(mc, done);
    };
    if (operation == QLatin1String("install")) {
      for (qsizetype at = 1; at <= kInstallSteps.size(); ++at) {
        QJsonObject step = running;
        step.insert(S("steps"), QJsonArray::fromStringList(kInstallSteps.mid(0, at)));
        emitOperation(mc, step);
      }
      machine.managed = true;
      finish(kInstallSteps, result(true, QJsonValue(), kInstalled));
    } else if (operation == QLatin1String("uninstall") && machine.reviews > 0 && !rpc.payload.value(QLatin1String("drain")).toBool()) {
      finish({}, result(false, S("sandboxes-running"),
                        machine.reviews == 1
                            ? S("1 of this MC's review sandboxes is on the gateway. Going ahead deletes it, which stops its review; "
                                "or let it finish first.")
                            : S("%1 of this MC's review sandboxes are on the gateway. Going ahead deletes them, which stops their reviews; "
                                "or let them finish first.")
                                  .arg(machine.reviews),
                        machine.reviews));
    } else if (operation == QLatin1String("uninstall")) {
      machine.reviews = 0;
      machine.managed = false;
      finish({S("Removing the gateway")}, result(true, QJsonValue(), kRemoved));
    } else {
      finish({}, result(true, QJsonValue(), S("OpenShell passed its checks.")));
    }
  });
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

// The action button labelled `label`, if the page shows one.
QQuickItem* actionButton(World& world, const S& label) {
  return world.findWhere([&](QQuickItem* candidate) {
    return candidate->objectName().startsWith(QLatin1String("sandboxAction:")) && candidate->isVisible() &&
           candidate->property("text").toString() == label;
  });
}

const Steps steps([] {
  step(S("a Linux machine with rootless Podman"), [](World&, const Captures&, const Table&) {});
  step(S("a machine that is an Intel Mac"), [](World& world, const Captures&, const Table&) { machine(world).intelMac = true; });
  step(S("a machine that has no Podman"), [](World& world, const Captures&, const Table&) { machine(world).noPodman = true; });
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
  step(S("they read that Podman must be installed first, and that Install starts its socket"), [](World& world, const Captures&, const Table&) {
    reads(world, S("sandboxProblem:podman-missing"), kNoPodman);
    world.waitFor([&] { return actionButton(world, S("Install")) != nullptr && actionButton(world, S("Install"))->isEnabled(); },
                  [&] { return S("the page to offer Install; the screen says: %1").arg(screenTexts(world)); });
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
  step(S("an OpenShell gateway this MC runs, with a sandbox of this MC's and one of someone else's"), [](World& world, const Captures&, const Table&) {
    machine(world).managed = true;
    // Someone else's sandbox is the MC's to leave alone; only this MC's are counted.
    machine(world).reviews = 1;
  });
  step(S("the user's device was paired without the right to manage the MC's machine"),
       [](World& world, const Captures&, const Table&) { machine(world).cannotManage = true; });

  step(S("they press \"([^\"]+)\" in the sandbox settings"), [](World& world, const Captures& c, const Table&) {
    QQuickItem* button = nullptr;
    world.waitFor([&] { return (button = actionButton(world, c[0])) != nullptr && button->isEnabled(); },
                  [&] { return S("\"%1\" among the sandbox actions; the screen says: %2").arg(c[0], screenTexts(world)); });
    world.tap(button);
  });

  step(S("the sandbox settings show the install's steps"), [](World& world, const Captures&, const Table&) {
    for (qsizetype at = 0; at < kInstallSteps.size(); ++at) reads(world, S("sandboxStep:%1").arg(at), kInstallSteps[at]);
  });
  step(S("they read that OpenShell was installed"), [](World& world, const Captures&, const Table&) {
    reads(world, S("sandboxResult"), kInstalled);
    reads(world, S("sandboxSummary"), S("Review sandboxes can run here."));
    reads(world, S("sandboxDetail"), S("OpenShell %1, run by this MC.").arg(kPinned));
  });
  step(S("the sandbox settings offer to uninstall it"), [](World& world, const Captures&, const Table&) {
    for (const S& label : {S("Check"), S("Rotate certificates"), S("Uninstall")}) {
      world.waitFor([&] { return actionButton(world, label) != nullptr && actionButton(world, label)->isEnabled(); },
                    [&] { return S("the page to offer %1; the screen says: %2").arg(label, screenTexts(world)); });
    }
    // Install is offered again only once it is uninstalled.
    expect(actionButton(world, S("Install")) == nullptr, S("the page still offers Install"));
  });
  step(S("the sandbox settings offer to install it"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return actionButton(world, S("Install")) != nullptr && actionButton(world, S("Install"))->isEnabled(); },
                  [&] { return S("the page to offer Install; the screen says: %1").arg(screenTexts(world)); });
    expect(actionButton(world, S("Uninstall")) == nullptr, S("the page still offers Uninstall"));
    reads(world, S("sandboxProblem:not-installed"), kNotInstalled);
  });

  step(S("they are asked whether to stop (\\d+) reviews?"), [](World& world, const Captures& c, const Table&) {
    const int count = c[0].toInt();
    const S question = S("Stop %1 review%2 and go ahead?").arg(count).arg(count == 1 ? S() : S("s"));
    world.waitFor([&] { return world.find(S("sandboxConfirmText")) != nullptr && world.find(S("sandboxConfirmText"))->isVisible() &&
                               world.find(S("sandboxConfirmText"))->property("text").toString().startsWith(question); },
                  [&] { return S("the page to ask \"%1\"; the screen says: %2").arg(question, screenTexts(world)); });
    // Nothing was stopped yet: the first uninstall asked without draining.
    expect(machine(world).runs == QList<QJsonObject>{QJsonObject{{S("operation"), S("uninstall")}}},
           S("the MC was asked %1 times").arg(machine(world).runs.size()));
  });
  step(S("they agree to stop it"), [](World& world, const Captures&, const Table&) { world.tap(S("sandboxConfirmYes")); });
  step(S("they read that OpenShell was removed, its review stopped first"), [](World& world, const Captures&, const Table&) {
    reads(world, S("sandboxResult"), kRemoved);
    expect(machine(world).runs.last() == QJsonObject{{S("operation"), S("uninstall")}, {S("drain"), true}}, S("the second uninstall did not drain"));
  });

  step(S("the sandbox settings' actions are off, and say which access the device lacks"), [](World& world, const Captures&, const Table&) {
    reads(world, S("sandboxManageReason"), kManageReason);
    QQuickItem* install = actionButton(world, S("Install"));
    expect(install != nullptr && !install->isEnabled(), S("Install is on, or missing"));
    // A tap cannot reach a disabled button; the action itself is refused too.
    world.bridge().dispatch(S("sandboxSettings.run"), QVariantMap{{S("operation"), S("install")}});
    world.sync();
    expect(machine(world).runs.isEmpty(), S("the MC was asked to install"));
  });
});

}  // namespace
