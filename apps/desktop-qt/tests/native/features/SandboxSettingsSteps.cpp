// Settings → Review sandboxes (SandboxSettingsController, SandboxSettings.qml):
// the @shared Settings scenarios of features/mc/platform/openshell.feature,
// against a MC whose `server.getOpenShellStatus`, `server.runOpenShellOperation`
// and openShell shape this file fakes from what the scenario says about the
// machine.

#include <QJsonArray>
#include <QJsonObject>

#include "Brick.h"
#include "FakeMc.h"
#include "Harness.h"
#include "World.h"

namespace {

const QString kPinned = QStringLiteral("0.1.7");
const QString kIntelMac = QStringLiteral("OpenShell supports Apple Silicon Macs only. This MC runs as x86_64: an Intel Mac, or an MC running under Rosetta.");
const QString kNotInstalled = QStringLiteral("Press Install to install it.");
const QString kNoPodman = QStringLiteral(
    "No rootless Podman socket. Install Podman 5 or later with your distribution's package manager, then press Install: it starts Podman's "
    "socket for you.");
const QString kFailure = QStringLiteral("OpenShell's status did not answer within 20 seconds. Refresh to try again.");
const QStringList kInstallSteps{QStringLiteral("Checking this machine"), QStringLiteral("Checking the gateway's configuration"),
                                QStringLiteral("Starting the gateway")};
const QString kInstalled = QStringLiteral("OpenShell installed, 0.1.7, listening on https://127.0.0.1:17670.");
const QString kRemoved = QStringLiteral("OpenShell removed.");
const QString kManageReason = QStringLiteral(
    "Installing and managing OpenShell needs a session that can manage this machine and use its terminal (access:write, terminal:operate). "
    "Pair this device with a link that grants them.");

// What the MC's machine is, as the scenario says.
struct FakeOpenShell {
  bool intelMac = false;
  bool noPodman = false;
  bool gateway = false;  // the user runs a gateway
  bool pointed = false;  // and pointed the MC at it
  bool failing = false;
  bool managed = false;       // a gateway this MC installed and runs
  int reviews = 0;            // this MC's review sandboxes on it
  bool cannotManage = false;  // paired without access:write and terminal:operate
  QStringList sandboxMachines;  // the cluster's machines that can run review sandboxes
  // The openShell shape's state: the operation running or last run.
  QJsonObject operation{{QStringLiteral("operation"), QJsonValue()}, {QStringLiteral("run"), 0}, {QStringLiteral("running"), false},
                        {QStringLiteral("steps"), QJsonArray()}, {QStringLiteral("result"), QJsonValue()}};
  // Each server.runOpenShellOperation's payload.
  QList<QJsonObject> runs;
};

QJsonObject action(const QString& operation, const QString& label) {
  return {{QStringLiteral("operation"), operation}, {QStringLiteral("label"), label}};
}

QJsonObject status(const FakeOpenShell& machine) {
  const auto problem = [](const QString& code, const QString& message) {
    return QJsonArray{QJsonObject{{QStringLiteral("code"), code}, {QStringLiteral("message"), message}}};
  };
  const bool external = !machine.intelMac && machine.gateway && machine.pointed;
  const bool ready = machine.managed || external;
  const QJsonArray actions = machine.intelMac ? QJsonArray()
                             : machine.managed
                                 ? QJsonArray{action(QStringLiteral("check"), QStringLiteral("Check")),
                                              action(QStringLiteral("rotate"), QStringLiteral("Rotate certificates")),
                                              action(QStringLiteral("uninstall"), QStringLiteral("Uninstall"))}
                             : external ? QJsonArray{action(QStringLiteral("check"), QStringLiteral("Check")),
                                                     action(QStringLiteral("uninstall"), QStringLiteral("Stop using it"))}
                                        : QJsonArray{action(QStringLiteral("install"), QStringLiteral("Install"))};
  QJsonObject answer{{QStringLiteral("supported"), !machine.intelMac},
          {QStringLiteral("ready"), ready},
          {QStringLiteral("mode"), machine.managed ? QJsonValue(QStringLiteral("managed"))
                                   : external      ? QJsonValue(QStringLiteral("external"))
                                                   : QJsonValue()},
          {QStringLiteral("actions"), actions},
          {QStringLiteral("canManage"), !machine.cannotManage},
          {QStringLiteral("manageReason"), machine.cannotManage ? QJsonValue(kManageReason) : QJsonValue()},
          {QStringLiteral("version"), ready ? QJsonValue(kPinned) : QJsonValue()},
          {QStringLiteral("pinnedVersion"), kPinned},
          {QStringLiteral("problems"), machine.intelMac ? problem(QStringLiteral("intel-mac"), kIntelMac)
                                       : ready          ? QJsonArray()
                                                        : problem(QStringLiteral("not-installed"), kNotInstalled)}};
  answer.insert(QStringLiteral("sandboxMachines"), QJsonArray::fromStringList(machine.sandboxMachines));
  // Like the MC: no Podman is a platform problem, and Install starts its socket once it is there.
  if (machine.noPodman) {
    answer.insert(QStringLiteral("supported"), false);
    answer.insert(QStringLiteral("problems"), problem(QStringLiteral("podman-missing"), kNoPodman));
  }
  return answer;
}

QJsonObject result(bool ok, const QJsonValue& code, const QString& message, const QJsonValue& sandboxes = QJsonValue(),
                   const QJsonValue& drain = QJsonValue()) {
  return {{QStringLiteral("ok"), ok}, {QStringLiteral("code"), code}, {QStringLiteral("message"), message}, {QStringLiteral("sandboxes"), sandboxes}, {QStringLiteral("drain"), drain}};
}

// This MC's reviews on the gateway, by the names the MC gives them.
QJsonArray reviewNames(int count) {
  QJsonArray names;
  for (int at = 1; at <= count; ++at) names.append(QStringLiteral("review-%1").arg(at));
  return names;
}

// Like the MC, a drain deletes only when it names every review there is.
bool drainsAll(const QJsonObject& payload, int count) {
  const QJsonArray drain = payload.value(QLatin1String("drain")).toArray();
  for (const QJsonValue& name : reviewNames(count)) {
    if (!drain.contains(name)) return false;
  }
  return true;
}

// The operation's new state, to everyone following the openShell shape.
void emitOperation(FakeMc& mc, const QJsonObject& operation) {
  mc.part<FakeOpenShell>().operation = operation;
  for (const int id : mc.subscribers(QStringLiteral("openShell"))) {
    mc.send({{QStringLiteral("t"), QStringLiteral("openShell")}, {QStringLiteral("id"), id}, {QStringLiteral("operation"), operation}});
  }
}

const FakeMc::Extension extension([](FakeMc& mc) {
  mc.onShape(QStringLiteral("openShell"), [&mc](int id, const QJsonObject&) {
    mc.send({{QStringLiteral("t"), QStringLiteral("openShell")}, {QStringLiteral("id"), id},
             {QStringLiteral("operation"), mc.part<FakeOpenShell>().operation}});
  });
  // Like the MC, the reply is the operation running, numbered; its steps and
  // outcome go to whoever follows the openShell shape.
  mc.onRpc(QStringLiteral("server.runOpenShellOperation"), [&mc](const FakeMc::Rpc& rpc) {
    FakeOpenShell& machine = mc.part<FakeOpenShell>();
    machine.runs.append(rpc.payload);
    if (machine.cannotManage) return mc.refuse(rpc, QStringLiteral("This session may not access:write."));
    const QString operation = rpc.payload.value(QLatin1String("operation")).toString();
    const QJsonObject running{{QStringLiteral("operation"), operation}, {QStringLiteral("run"), machine.runs.size()},
                              {QStringLiteral("running"), true}, {QStringLiteral("steps"), QJsonArray()}, {QStringLiteral("result"), QJsonValue()}};
    mc.reply(rpc, running);
    emitOperation(mc, running);
    const auto finish = [&mc, running](const QStringList& steps, const QJsonObject& outcome) {
      QJsonObject done = running;
      done.insert(QStringLiteral("running"), false);
      done.insert(QStringLiteral("steps"), QJsonArray::fromStringList(steps));
      done.insert(QStringLiteral("result"), outcome);
      emitOperation(mc, done);
    };
    if (operation == QLatin1String("install")) {
      for (qsizetype at = 1; at <= kInstallSteps.size(); ++at) {
        QJsonObject step = running;
        step.insert(QStringLiteral("steps"), QJsonArray::fromStringList(kInstallSteps.mid(0, at)));
        emitOperation(mc, step);
      }
      machine.managed = true;
      finish(kInstallSteps, result(true, QJsonValue(), kInstalled));
    } else if (operation == QLatin1String("uninstall") && machine.reviews > 0 && !drainsAll(rpc.payload, machine.reviews)) {
      // A drain that does not name them all was confirmed before others started.
      const bool confirmed = rpc.payload.contains(QLatin1String("drain"));
      finish({}, result(false, confirmed ? QStringLiteral("sandboxes-changed") : QStringLiteral("sandboxes-running"),
                        (confirmed ? QStringLiteral("The running reviews changed since you confirmed. ") : QString()) +
                        (machine.reviews == 1
                            ? QStringLiteral("1 of this MC's review sandboxes is on the gateway. Going ahead deletes it, which stops its review; "
                                             "or let it finish first.")
                            : QStringLiteral("%1 of this MC's review sandboxes are on the gateway. Going ahead deletes them, which stops their "
                                             "reviews; or let them finish first.")
                                  .arg(machine.reviews)),
                        machine.reviews, reviewNames(machine.reviews)));
    } else if (operation == QLatin1String("uninstall")) {
      machine.reviews = 0;
      machine.managed = false;
      finish({QStringLiteral("Removing the gateway")}, result(true, QJsonValue(), kRemoved));
    } else {
      finish({}, result(true, QJsonValue(), QStringLiteral("OpenShell passed its checks.")));
    }
  });
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

QVariantMap operation(World& world) {
  return section(world).value(QStringLiteral("operation")).toMap();
}

// Waits for the operation to end and the status read after it to land.
void settled(World& world) {
  world.waitFor(
      [&] {
        const QVariantMap now = operation(world);
        return !now.isEmpty() && !now.value(QStringLiteral("running")).toBool() && !section(world).value(QStringLiteral("loading")).toBool();
      },
      [&] { return QStringLiteral("the operation to end and the status to land; the section is %1").arg(show(section(world))); });
}

void expectText(World& world, const QString& objectName, const QString& expected) {
  const QString shown = text(world, objectName);
  expect(shown == expected, QStringLiteral("%1 says \"%2\", not \"%3\"").arg(objectName, shown, expected));
}

void expectSummary(World& world, const QString& summary) {
  expect(text(world, QStringLiteral("sandboxSummary")) == summary,
         QStringLiteral("the page says \"%1\", not \"%2\"").arg(text(world, QStringLiteral("sandboxSummary")), summary));
}

const Steps steps([] {
  step(QStringLiteral("a Linux machine with rootless Podman"), [](World&, const Captures&, const Table&) {});
  step(QStringLiteral("a machine that is an Intel Mac"), [](World& world, const Captures&, const Table&) { machine(world).intelMac = true; });
  step(QStringLiteral("a machine that is an Intel Mac, in a cluster with \"([^\"]+)\", which can run review sandboxes"),
       [](World& world, const Captures& c, const Table&) {
         machine(world).intelMac = true;
         machine(world).sandboxMachines = {c[0]};
       });
  step(QStringLiteral("a machine that has no Podman"), [](World& world, const Captures&, const Table&) { machine(world).noPodman = true; });
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
  step(QStringLiteral("they read that code reviews that need a sandbox go to \"([^\"]+)\""), [](World& world, const Captures& c, const Table&) {
    expectText(world, QStringLiteral("sandboxDetail"), QStringLiteral("Code reviews that need a sandbox go to %1.").arg(c[0]));
  });
  step(QStringLiteral("they read that code reviews that need a sandbox fail until a machine of the cluster can run them"),
       [](World& world, const Captures&, const Table&) {
         expectText(world, QStringLiteral("sandboxDetail"),
                    QStringLiteral("Code reviews that need a sandbox fail here until this machine or another of your cluster can run them."));
       });
  step(QStringLiteral("they read that OpenShell is not installed, and how to install it"), [](World& world, const Captures&, const Table&) {
    expectSummary(world, QStringLiteral("Review sandboxes can't run here yet."));
    expect(text(world, QStringLiteral("sandboxProblem:not-installed")) == kNotInstalled, QStringLiteral("the page does not say how to install it"));
    expect(text(world, QStringLiteral("sandboxDetail")).contains(kPinned), QStringLiteral("the page does not name the version the MC pins"));
  });
  step(QStringLiteral("they read that Podman must be installed first, and that Install starts its socket"), [](World& world, const Captures&, const Table&) {
    expectText(world, QStringLiteral("sandboxProblem:podman-missing"), kNoPodman);
    QQuickItem* install = world.brick->find(QStringLiteral("sandboxAction:install"));
    expect(install != nullptr && install->isEnabled(), QStringLiteral("the page does not offer Install"));
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

  step(QStringLiteral("an OpenShell gateway this MC runs, with a sandbox of this MC's and one of someone else's"),
       [](World& world, const Captures&, const Table&) {
         machine(world).managed = true;
         // Someone else's sandbox is the MC's to leave alone; only this MC's are counted.
         machine(world).reviews = 1;
       });
  step(QStringLiteral("the user's device was paired without the right to manage the MC's machine"),
       [](World& world, const Captures&, const Table&) { machine(world).cannotManage = true; });

  step(QStringLiteral("they press \"([^\"]+)\" in the sandbox settings"), [](World& world, const Captures& c, const Table&) {
    QString operation;
    for (const QVariant& value : section(world).value(QStringLiteral("actions")).toList()) {
      if (value.toMap().value(QStringLiteral("label")).toString() == c[0]) operation = value.toMap().value(QStringLiteral("operation")).toString();
    }
    expect(!operation.isEmpty(), QStringLiteral("the page offers no \"%1\"; the section is %2").arg(c[0], show(section(world))));
    world.brick->grab();
    world.brick->click(QStringLiteral("sandboxAction:") + operation);
    settled(world);
  });

  step(QStringLiteral("the sandbox settings show the install's steps"), [](World& world, const Captures&, const Table&) {
    for (qsizetype at = 0; at < kInstallSteps.size(); ++at) expectText(world, QStringLiteral("sandboxStep:%1").arg(at), kInstallSteps[at]);
  });
  step(QStringLiteral("they read that OpenShell was installed"), [](World& world, const Captures&, const Table&) {
    expectText(world, QStringLiteral("sandboxResult"), kInstalled);
    expectSummary(world, QStringLiteral("Review sandboxes can run here."));
    expectText(world, QStringLiteral("sandboxDetail"), QStringLiteral("OpenShell %1, run by this MC.").arg(kPinned));
  });
  step(QStringLiteral("the sandbox settings offer to uninstall it"), [](World& world, const Captures&, const Table&) {
    world.brick->grab();
    for (const QString& operation : {QStringLiteral("check"), QStringLiteral("rotate"), QStringLiteral("uninstall")}) {
      QQuickItem* button = world.brick->find(QStringLiteral("sandboxAction:") + operation);
      expect(button != nullptr && button->isEnabled(), QStringLiteral("the page does not offer %1").arg(operation));
    }
    // Install is offered again only once it is uninstalled.
    expect(world.brick->find(QStringLiteral("sandboxAction:install")) == nullptr, QStringLiteral("the page still offers Install"));
  });
  step(QStringLiteral("the sandbox settings offer to install it"), [](World& world, const Captures&, const Table&) {
    world.brick->grab();
    QQuickItem* install = world.brick->find(QStringLiteral("sandboxAction:install"));
    expect(install != nullptr && install->isEnabled(), QStringLiteral("the page does not offer Install"));
    expect(world.brick->find(QStringLiteral("sandboxAction:uninstall")) == nullptr, QStringLiteral("the page still offers Uninstall"));
    expectText(world, QStringLiteral("sandboxProblem:not-installed"), kNotInstalled);
  });

  step(QStringLiteral("they are asked whether to stop (\\d+) reviews?"), [](World& world, const Captures& c, const Table&) {
    const int count = c[0].toInt();
    const QString question = QStringLiteral("Stop %1 review%2 and go ahead?").arg(count).arg(count == 1 ? QString() : QStringLiteral("s"));
    world.brick->grab();
    expect(text(world, QStringLiteral("sandboxConfirmText")).startsWith(question),
           QStringLiteral("the page asks \"%1\"").arg(text(world, QStringLiteral("sandboxConfirmText"))));
    // Nothing was stopped yet: the first uninstall asked without draining.
    const QList<QJsonObject> runs = machine(world).runs;
    expect(runs == QList<QJsonObject>{QJsonObject{{QStringLiteral("operation"), QStringLiteral("uninstall")}}},
           QStringLiteral("the MC was asked %1 times").arg(runs.size()));
  });
  step(QStringLiteral("they agree to stop it"), [](World& world, const Captures&, const Table&) {
    const auto message = [&] { return operation(world).value(QStringLiteral("result")).toMap().value(QStringLiteral("message")).toString(); };
    const QString asked = message();
    world.brick->click(QStringLiteral("sandboxConfirmYes"));
    // The last uninstall's outcome is on the page until this one's lands.
    world.waitFor([&] { return message() != asked && !section(world).value(QStringLiteral("loading")).toBool(); },
                  [&] { return QStringLiteral("the drained uninstall to end; the section is %1").arg(show(section(world))); });
  });
  step(QStringLiteral("another of this MC's reviews starts on the gateway"),
       [](World& world, const Captures&, const Table&) { ++machine(world).reviews; });
  step(QStringLiteral("they are asked again whether to stop (\\d+) reviews, as the reviews changed"), [](World& world, const Captures& c, const Table&) {
    const QString question = QStringLiteral("Stop %1 reviews and go ahead? The running reviews changed since you confirmed.").arg(c[0]);
    world.brick->grab();
    expect(world.brick->item(QStringLiteral("sandboxConfirm"))->isVisible() && text(world, QStringLiteral("sandboxConfirmText")).startsWith(question),
           QStringLiteral("the page asks \"%1\"").arg(text(world, QStringLiteral("sandboxConfirmText"))));
    // The yes named only the review it was asked about.
    expect(machine(world).runs.last() ==
               QJsonObject{{QStringLiteral("operation"), QStringLiteral("uninstall")}, {QStringLiteral("drain"), QJsonArray{QStringLiteral("review-1")}}},
           QStringLiteral("the yes did not name the review it asked about"));
  });
  step(QStringLiteral("no review was stopped"), [](World& world, const Captures&, const Table&) {
    expect(machine(world).reviews == 2 && machine(world).managed, QStringLiteral("a review was stopped, or OpenShell removed"));
  });
  step(QStringLiteral("they read that OpenShell was removed, its review stopped first"), [](World& world, const Captures&, const Table&) {
    expectText(world, QStringLiteral("sandboxResult"), kRemoved);
    expect(machine(world).runs.last() == QJsonObject{{QStringLiteral("operation"), QStringLiteral("uninstall")}, {QStringLiteral("drain"), QJsonArray{QStringLiteral("review-1")}}},
           QStringLiteral("the second uninstall did not drain"));
    expect(!world.brick->item(QStringLiteral("sandboxConfirm"))->isVisible(), QStringLiteral("the page still asks"));
  });

  step(QStringLiteral("the sandbox settings' actions are off, and say which access the device lacks"), [](World& world, const Captures&, const Table&) {
    expectText(world, QStringLiteral("sandboxManageReason"), kManageReason);
    expect(!world.brick->item(QStringLiteral("sandboxAction:install"))->isEnabled(), QStringLiteral("Install is on"));
    // Nor does the controller run it when asked anyway.
    world.bridge().dispatch(QStringLiteral("sandboxSettings.run"), QVariantMap{{QStringLiteral("operation"), QStringLiteral("install")}});
    world.sync();
    expect(machine(world).runs.isEmpty(), QStringLiteral("the MC was asked to install"));
  });
});

}  // namespace
