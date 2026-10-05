// An environment's icon that cannot be changed, as
// features/connections/environments.feature words it (IdentityController's
// lock, the EnvironmentIconPicker brick). The two environments are
// LoadBalancingSteps' cluster: this machine and "server".

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

const QString kEnvironment = QStringLiteral("server");

struct Environments {
  QString iconOf;  // the environment whose icon the scenario tries to change
  int writesBefore = 0;
};

const Steps steps([] {
  const QString q = kQuoted;

  // An icon that cannot be changed (IdentityController's lock, the EnvironmentIconPicker brick).
  step(QStringLiteral("the environment is not connected"), [](World& world, const Captures&, const Table&) {
    world.mc.part<Environments>().iconOf = kEnvironment;
    world.mc.setOnline(kEnvironment, false);
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

});

}  // namespace
