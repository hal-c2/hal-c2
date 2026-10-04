// The environments a desktop is paired with, as
// features/connections/environments.feature words them: its own MC's and one
// the MC is linked to ("Build box"), removing and pairing it again, and this
// device's load preferences for them (ConnectionsController's `balancing`).

#include <QJsonArray>
#include <QJsonObject>
#include <QUrl>
#include <QUrlQuery>

#include "Brick.h"
#include "FakeConfig.h"
#include "Harness.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "ShellStore.h"
#include "World.h"

namespace {

const QString kEnvironment = QStringLiteral("buildbox");
const QString kLabel = QStringLiteral("Build box");
const QString kThread = QStringLiteral("buildbox:thread-ops");

struct Environments {
  QStringList usedTokens;
  QString iconOf;  // the environment whose icon the scenario tries to change
  int writesBefore = 0;
};

// The MC pairs with the machine a link names (HalC2.Links), once per link.
void answerLinks(FakeMc& mc) {
  mc.onRpc(QStringLiteral("hal-c2.linkEnvironment"), [&mc](const FakeMc::Rpc& rpc) {
    const QUrl url(rpc.payload.value(QLatin1String("pairingUrl")).toString());
    const QString token = QUrlQuery(url.fragment()).queryItemValue(QStringLiteral("token"));
    QStringList& used = mc.part<Environments>().usedTokens;
    if (url.host() != kEnvironment || token.isEmpty() || used.contains(token)) {
      mc.refuse(rpc, QStringLiteral("the pairing link is invalid or expired"));
      return;
    }
    used.append(token);
    mc.link(kEnvironment);
    mc.reply(rpc, QJsonObject{{QStringLiteral("environmentId"), kEnvironment}, {QStringLiteral("label"), kLabel}});
  });
}

// "Build box", with a project and a thread of its own.
void pairSecond(World& world) {
  world.mc.linkLabels.insert(kEnvironment, kLabel);
  world.mc.link(kEnvironment);
  world.mc.sendLinkRow(kEnvironment, QStringLiteral("ops"),
                       {{QStringLiteral("id"), QStringLiteral("ops")}, {QStringLiteral("title"), QStringLiteral("ops")},
                        {QStringLiteral("workspaceRoot"), QStringLiteral("/work/ops")}, {QStringLiteral("scripts"), QJsonArray()}},
                       QStringLiteral("project"));
  world.mc.sendLinkRow(kEnvironment, QStringLiteral("thread-ops"),
                       {{QStringLiteral("id"), QStringLiteral("thread-ops")}, {QStringLiteral("title"), QStringLiteral("Deploy")},
                        {QStringLiteral("projectId"), QStringLiteral("ops")},
                        {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")}, {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}});
  world.sync();
}

void start(World& world) {
  world.connect();
  world.waitFor([&world] { return world.native().isActive(); }, QStringLiteral("the shell to start"));
}

QVariantMap connections(World& world) {
  return world.state(QStringLiteral("connections")).toMap();
}

QVariantMap linkRow(World& world) {
  for (const QVariant& link : connections(world).value(QStringLiteral("links")).toList()) {
    if (link.toMap().value(QStringLiteral("environmentId")) == kEnvironment) return link.toMap();
  }
  return {};
}

void expectBack(World& world) {
  world.waitFor([&] { return linkRow(world).value(QStringLiteral("status")) == QLatin1String("Connected") &&
                             world.native().store()->thread(kThread).has_value(); },
                [&] { return QStringLiteral("Build box to be listed with its threads; the page is %1").arg(show(connections(world))); });
}

QVariantMap balancing(World& world) {
  return connections(world).value(QStringLiteral("balancing")).toMap();
}

QVariantMap balanced(World& world, const QString& environment = kEnvironment) {
  for (const QVariant& row : balancing(world).value(QStringLiteral("environments")).toList()) {
    if (row.toMap().value(QStringLiteral("environmentId")) == environment) return row.toMap();
  }
  return {};
}

void prefer(World& world, int weight) {
  world.bridge().dispatch(QStringLiteral("connections.balancing.preference"),
                          QVariantMap{{QStringLiteral("environmentId"), kEnvironment}, {QStringLiteral("weight"), weight}});
}

void setBalancing(World& world, bool enabled) {
  world.bridge().dispatch(QStringLiteral("connections.balancing.enabled"), QVariantMap{{QStringLiteral("enabled"), enabled}});
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("a client paired with two environments"), [](World& world, const Captures&, const Table&) {
    start(world);
    pairSecond(world);
  });

  // Removing and pairing again.
  step(QStringLiteral("the user removed an environment from this device"), [](World& world, const Captures&, const Table&) {
    const QVariantMap payload{{QStringLiteral("environmentId"), kEnvironment}};
    world.bridge().dispatch(QStringLiteral("connections.unlink.request"), payload);
    world.bridge().dispatch(QStringLiteral("connections.unlink"), payload);
    world.waitFor([&] { return linkRow(world).isEmpty() && !world.native().store()->thread(kThread).has_value(); },
                  [&] { return QStringLiteral("Build box to go; the page is %1").arg(show(connections(world))); });
  });
  step(QStringLiteral("the user pairs with it again"), [](World& world, const Captures&, const Table&) {
    answerLinks(world.mc);
    world.bridge().dispatch(QStringLiteral("connections.link"),
                            QVariantMap{{QStringLiteral("pairingUrl"), QStringLiteral("http://%1:3780/pair#token=fresh-1").arg(kEnvironment)}});
  });
  step(QStringLiteral("it returns to the list with its threads"), [](World& world, const Captures&, const Table&) {
    expectBack(world);
    const QVariantMap notice = connections(world).value(QStringLiteral("notice")).toMap();
    expect(notice.value(QStringLiteral("text")) == QLatin1String("Build box is linked."), QStringLiteral("the page says %1").arg(show(notice)));
  });

  // Starting again.
  step(QStringLiteral("a saved environment that was offline"), [](World& world, const Captures&, const Table&) {
    world.mc.setLinkProblem(kEnvironment, QStringLiteral("unreachable"));
    world.waitFor([&] { return linkRow(world).value(QStringLiteral("status")) == QLatin1String("Offline"); },
                  [&] { return QStringLiteral("Build box to be offline; the page is %1").arg(show(connections(world))); });
  });
  step(QStringLiteral("the app starts"), [](World& world, const Captures&, const Table&) {
    world.restart();
    // The machine is back by the time the app is.
    world.mc.linkProblems.remove(kEnvironment);
    start(world);
  });
  step(QStringLiteral("the client reconnects to it without pairing again"), [](World& world, const Captures&, const Table&) {
    expectBack(world);
    for (const FakeMc::Rpc& rpc : world.mc.calls) {
      expect(rpc.method != QLatin1String("hal-c2.linkEnvironment"), QStringLiteral("the environment was paired again"));
    }
  });

  // An icon that cannot be changed (IdentityController's lock, the EnvironmentIconPicker brick).
  step(QStringLiteral("the environment is not connected"), [](World& world, const Captures&, const Table&) {
    world.mc.part<Environments>().iconOf = kEnvironment;
    world.mc.setLinkProblem(kEnvironment, QStringLiteral("unreachable"));
    world.sync();
  });
  step(QStringLiteral("the environment's server predates icons"), [](World& world, const Captures&, const Table&) {
    // Its descriptor names no `environmentIcon` capability.
    FakeConfig& fake = fakeConfig(world.mc);
    fake.config.insert(QStringLiteral("environment"), QJsonObject{{QStringLiteral("environmentId"), world.mc.environmentId}, {QStringLiteral("capabilities"), QJsonObject()}});
    QJsonObject config = fake.config;
    config.insert(QStringLiteral("settings"), fake.settings);
    for (const int id : world.mc.subscribers(QStringLiteral("config"))) {
      if (world.mc.shapeOf(id).value(QLatin1String("environment")) != world.mc.environmentId) continue;
      world.mc.send({{QStringLiteral("t"), QStringLiteral("config")}, {QStringLiteral("id"), id}, {QStringLiteral("config"), config}});
    }
    world.sync();
  });
  step(QStringLiteral("the user tries to change the environment's icon"), [](World& world, const Captures&, const Table&) {
    Environments& state = world.mc.part<Environments>();
    if (state.iconOf.isEmpty()) state.iconOf = world.mc.environmentId;
    state.writesBefore = 0;
    for (const FakeMc::Rpc& rpc : world.mc.calls) state.writesBefore += rpc.method == QLatin1String("hal-c2.writeSettings");
    world.bridge().dispatch(QStringLiteral("environmentIcon.set"), QVariantMap{{QStringLiteral("environmentId"), state.iconOf}, {QStringLiteral("kind"), QStringLiteral("desktop")}});
  });
  step(QStringLiteral("the client says (connect to the environment to change its icon|the server is too old to keep an icon and should update|"
                      "this session cannot change the environment's settings)"),
       [](World& world, const Captures& c, const Table&) {
    const QString said = c[0].startsWith(QLatin1String("connect")) ? QStringLiteral("Connect to this environment to change its icon.")
                         : c[0].startsWith(QLatin1String("the server")) ? QStringLiteral("This environment's server is too old to keep an icon. Update it to choose one.")
                                                                        : QStringLiteral("Your session on this environment cannot change its settings.");
    const auto told = [&] {
      for (const QVariant& toast : at(world.state(QStringLiteral("toasts")), QStringLiteral("items")).toList()) {
        if (toast.toMap().value(QStringLiteral("title")) == QLatin1String("Icon not changed") && toast.toMap().value(QStringLiteral("description")) == said) return true;
      }
      return false;
    };
    world.waitFor(told, [&] { return QStringLiteral("\"%1\"; the toasts are %2").arg(said, show(world.state(QStringLiteral("toasts")))); });
    // Nothing was saved, and Connections settings says the same beside the picker, which takes no choice.
    const Environments& state = world.mc.part<Environments>();
    world.sync();
    int writes = 0;
    for (const FakeMc::Rpc& rpc : world.mc.calls) writes += rpc.method == QLatin1String("hal-c2.writeSettings");
    expect(writes == state.writesBefore, QStringLiteral("the settings were written"));
    world.brick = std::make_unique<Brick>(world, QStringLiteral("import QtQuick\nimport HalC2.Bricks\nEnvironmentIconPicker { width: 600; environmentId: \"%1\" }\n").arg(state.iconOf).toUtf8(),
                                          QSize(600, 80));
    expect(world.brick->shows(said) && !world.brick->item(QStringLiteral("environmentIconKind"))->isEnabled(),
           QStringLiteral("the picker does not say \"%1\"").arg(said));
  });

  // Load balancing.
  step(QStringLiteral("an environment's saved load weight is (\\d+)"), [](World& world, const Captures& c, const Table&) {
    auto* settings = world.native().controller<SettingsController>();
    settings->set(QStringLiteral("loadBalancingEnabled"), true);
    settings->set(QStringLiteral("loadBalancingWeights"), QVariantMap{{kEnvironment, c[0].toInt()}});
  });
  step(QStringLiteral("the user opens load balancing"), [](World& world, const Captures&, const Table&) {
    world.native().controller<NavigationController>()->open(NavigationController::Route::settings(NavigationController::kConnectionsSection));
    world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nLoadBalancingSettings {}\n", QSize(640, 300));
  });
  step(QStringLiteral("the environment shows %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(balanced(world).value(QStringLiteral("preference")) == c[0] && world.brick->shows(c[0]) && world.brick->shows(kLabel),
           QStringLiteral("load balancing is %1").arg(show(balancing(world))));
  });
  step(QStringLiteral("load balancing is on with preferences set"), [](World& world, const Captures&, const Table&) {
    setBalancing(world, true);
    prefer(world, 25);
    expect(balancing(world).value(QStringLiteral("enabled")).toBool() && balanced(world).value(QStringLiteral("preference")) == QLatin1String("Less often"),
           QStringLiteral("load balancing is %1").arg(show(balancing(world))));
  });
  step(QStringLiteral("the user turns load balancing off"), [](World& world, const Captures&, const Table&) {
    setBalancing(world, false);
    expect(!balancing(world).value(QStringLiteral("enabled")).toBool() &&
               !world.native().controller<SettingsController>()->setting(QStringLiteral("loadBalancingEnabled")).toBool(),
           QStringLiteral("load balancing is %1").arg(show(balancing(world))));
  });
  step(QStringLiteral("turns it on again"), [](World& world, const Captures&, const Table&) { setBalancing(world, true); });
  step(QStringLiteral("the earlier preferences are back"), [](World& world, const Captures&, const Table&) {
    expect(balancing(world).value(QStringLiteral("enabled")).toBool() && balanced(world).value(QStringLiteral("preference")) == QLatin1String("Less often") &&
               balanced(world, world.mc.environmentId).value(QStringLiteral("preference")) == QLatin1String("Normal"),
           QStringLiteral("load balancing is %1").arg(show(balancing(world))));
  });
  step(QStringLiteral("two desktop clients paired with the same environments"), [](World& world, const Captures&, const Table&) {
    setBalancing(world, true);
  });
  step(QStringLiteral("the user sets a preference on one client"), [](World& world, const Captures&, const Table&) {
    prefer(world, 100);
    expect(balanced(world).value(QStringLiteral("preference")) == QLatin1String("Prefer"), QStringLiteral("load balancing is %1").arg(show(balancing(world))));
  });
  step(QStringLiteral("the other client keeps its own preferences"), [](World& world, const Captures&, const Table&) {
    // The preference is this device's: nothing of it was saved on the environment.
    world.sync();
    for (const QJsonObject& write : fakeConfig(world.mc).writes) {
      expect(!QString::fromUtf8(QJsonDocument(write).toJson()).contains(QLatin1String("loadBalancing")),
             QStringLiteral("the preference was saved on the environment"));
    }
    // Another desktop, paired with environments of the same ids.
    World other;
    start(other);
    pairSecond(other);
    setBalancing(other, true);
    expect(balanced(other).value(QStringLiteral("preference")) == QLatin1String("Normal") && balanced(world).value(QStringLiteral("preference")) == QLatin1String("Prefer"),
           QStringLiteral("the other client shows %1").arg(show(balancing(other))));
  });
});

}  // namespace
