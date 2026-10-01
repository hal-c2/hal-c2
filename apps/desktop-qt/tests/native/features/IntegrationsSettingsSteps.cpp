// The native Integrations settings section (DeviceSettingsController): the
// @desktop device scenarios of features/settings/integrations.feature. The
// MC fakes HalC2.Devices: its DeviceServiceState follows each environment's
// settings document, `device.configure` saves there, and its own state goes
// to `devices` watchers.

#include <QJsonArray>
#include <QJsonObject>
#include <QSet>

#include "FakeConfig.h"
#include "Harness.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "World.h"

namespace {

struct FakeDevices {
  QSet<QString> outdated;  // environments whose hub tool is behind
  bool failUpdates = false;
};

QString environmentOf(const FakeMc& mc, const FakeMc::Rpc& rpc) {
  return rpc.environment.isEmpty() ? mc.environmentId : rpc.environment;
}

QJsonObject settingsOf(FakeMc& mc, const QString& environment) {
  return environment == mc.environmentId ? fakeConfig(mc).settings : documentOf(mc, environment).settings;
}

// HalC2.Devices' state on `environment`: iOS here, Android missing; a
// linked machine says which it is, so the one shown can be told apart.
QJsonObject deviceState(FakeMc& mc, const QString& environment) {
  const QJsonObject settings = settingsOf(mc, environment);
  const bool enabled = settings.value(QLatin1String("enableDeviceSupport")).toBool();
  const QJsonObject tool{{QStringLiteral("requiredVersion"), QStringLiteral("1.4.0")},
                         {QStringLiteral("installedVersions"), QJsonArray{QStringLiteral("1.4.0")}},
                         {QStringLiteral("runningVersion"), QJsonValue::Null}};
  QJsonObject hub = tool;
  if (mc.part<FakeDevices>().outdated.contains(environment)) hub.insert(QStringLiteral("installedVersions"), QJsonArray{QStringLiteral("1.3.0")});
  const bool here = environment == mc.environmentId;
  return {{QStringLiteral("supportsHostRetry"), true},
          {QStringLiteral("supportsToolUpdate"), true},
          {QStringLiteral("supportsToolInspection"), true},
          {QStringLiteral("hosts"),
           QJsonArray{QJsonObject{
               {QStringLiteral("id"), QStringLiteral("local")},
               {QStringLiteral("kind"), QStringLiteral("local")},
               {QStringLiteral("label"), QStringLiteral("This host")},
               {QStringLiteral("platforms"),
                QJsonArray{QJsonObject{{QStringLiteral("platform"), QStringLiteral("ios")},
                                       {QStringLiteral("available"), here},
                                       {QStringLiteral("reason"), QStringLiteral("Xcode is not installed on %1.").arg(environment)}},
                           QJsonObject{{QStringLiteral("platform"), QStringLiteral("android")},
                                       {QStringLiteral("available"), false},
                                       {QStringLiteral("reason"), QStringLiteral("The Android SDK was not found.")}}}},
               {QStringLiteral("tools"), QJsonObject{{QStringLiteral("hub"), hub}, {QStringLiteral("agent"), tool}}},
               {QStringLiteral("hubInstalled"), true},
               {QStringLiteral("agentDeviceInstalled"), true},
           }}},
          {QStringLiteral("hostStatus"), enabled ? QStringLiteral("ready") : QStringLiteral("disabled")},
          {QStringLiteral("hostStatuses"), QJsonObject{}},
          {QStringLiteral("devices"), here && enabled ? QJsonArray{QJsonObject{{QStringLiteral("id"), QStringLiteral("iphone")},
                                                                              {QStringLiteral("platform"), QStringLiteral("ios")},
                                                                              {QStringLiteral("name"), QStringLiteral("iPhone 17")}}}
                                                     : QJsonArray{}},
          {QStringLiteral("sessions"), QJsonArray{}},
          {QStringLiteral("onboardingCompleted"), enabled},
          {QStringLiteral("agentAccessEnabled"), settings.value(QLatin1String("enableAgentDeviceAccess")).toBool()},
          {QStringLiteral("hubBasePath"), QStringLiteral("/api/device-hub")},
          {QStringLiteral("revision"), 0}};
}

void broadcast(FakeMc& mc) {
  for (const int id : mc.subscribers(QStringLiteral("devices"))) {
    mc.send({{QStringLiteral("t"), QStringLiteral("devices")}, {QStringLiteral("id"), id}, {QStringLiteral("state"), deviceState(mc, mc.environmentId)}});
  }
}

const FakeMc::Extension devices([](FakeMc& mc) {
  mc.onShape(QStringLiteral("devices"), [&mc](int id, const QJsonObject&) {
    mc.send({{QStringLiteral("t"), QStringLiteral("devices")}, {QStringLiteral("id"), id}, {QStringLiteral("state"), deviceState(mc, mc.environmentId)}});
  });
  mc.onRpc(QStringLiteral("device."), [&mc](const FakeMc::Rpc& rpc) {
    const QString environment = environmentOf(mc, rpc);
    FakeDevices& fake = mc.part<FakeDevices>();
    if (mc.holding(QStringLiteral("device"))) {
      // Answered once released, late: the change is still saving until then.
      mc.defer([&mc, rpc, environment] { mc.reply(rpc, deviceState(mc, environment)); });
      return;
    }
    if (rpc.method == QLatin1String("device.configure")) {
      const QString refusal = environment == mc.environmentId ? fakeConfig(mc).refuseWrites : documentOf(mc, environment).refuseWrites;
      if (!refusal.isEmpty()) {
        mc.refuse(rpc, refusal);
        return;
      }
      if (rpc.payload.value(QLatin1String("enabled")).isBool()) {
        saveOn(mc, environment, QStringLiteral("enableDeviceSupport"), rpc.payload.value(QLatin1String("enabled")));
      }
      if (rpc.payload.value(QLatin1String("agentAccessEnabled")).isBool()) {
        saveOn(mc, environment, QStringLiteral("enableAgentDeviceAccess"), rpc.payload.value(QLatin1String("agentAccessEnabled")));
      }
    } else if (rpc.method == QLatin1String("device.list") && rpc.payload.contains(QLatin1String("updateTool"))) {
      if (fake.failUpdates) {
        mc.refuse(rpc, QStringLiteral("Could not update device tool: command failed"));
        return;
      }
      fake.outdated.remove(environment);
    }
    mc.reply(rpc, deviceState(mc, environment));
    if (environment == mc.environmentId) broadcast(mc);
  });
});

QVariantMap section(World& world) {
  return world.state(QStringLiteral("deviceSettings")).toMap();
}

// Connects once the Givens have set the MC up, then waits for the section.
void ready(World& world) {
  if (world.shellSubscriptions() == 0) {
    world.connect();
    world.sync();
  }
  auto* navigation = world.native().controller<NavigationController>();
  const NavigationController::Route integrations = NavigationController::Route::settings(QStringLiteral("/settings/integrations"));
  if (!(navigation->route() == integrations)) navigation->open(integrations);
  world.waitFor([&] { return section(world).value(QStringLiteral("open")).toBool() && section(world).value(QStringLiteral("loaded")).toBool(); },
                [&] { return QStringLiteral("the device settings to load; they are %1").arg(show(section(world))); });
}

void chooseAllEnvironments(World& world) {
  world.bridge().dispatch(QStringLiteral("settingsScope.environment"), QVariantMap{{QStringLiteral("id"), QString()}});
}

void turn(World& world, const QString& tool, bool enabled) {
  ready(world);
  world.waitFor([&] { return at(section(world), tool + QStringLiteral(".enabled")).toBool(); },
                [&] { return QStringLiteral("the %1 switch to be usable; the section is %2").arg(tool, show(section(world))); });
  world.bridge().dispatch(QStringLiteral("deviceSettings.") + tool, QVariantMap{{QStringLiteral("enabled"), enabled}});
}

void expectStored(World& world, const QString& key, bool value) {
  world.waitFor([&] { return fakeConfig(world.mc).settings.value(key) == QJsonValue(value); },
                [&] { return QStringLiteral("%1 to be stored as %2; the section is %3").arg(key, value ? QStringLiteral("on") : QStringLiteral("off"), show(section(world))); });
  world.waitFor([&] { return at(section(world), (key == QLatin1String("enableDeviceSupport") ? QStringLiteral("hub") : QStringLiteral("agent")) + QStringLiteral(".on")).toBool() == value; },
                [&] { return QStringLiteral("the switch to show it; the section is %1").arg(show(section(world))); });
}

const Steps steps([] {
  const QString q = kQuoted;

  // The section opens once the scenario's Givens have shaped the MC (ready()).
  step(QStringLiteral("the user has opened the Integrations settings"), [](World&, const Captures&, const Table&) {});

  step(QStringLiteral("the device hub is on"), [](World& world, const Captures&, const Table&) {
    saveElsewhere(world.mc, QStringLiteral("enableDeviceSupport"), true, true);
  });
  step(QStringLiteral("agent device access is on"), [](World& world, const Captures&, const Table&) {
    saveElsewhere(world.mc, QStringLiteral("enableAgentDeviceAccess"), true, true);
  });
  step(QStringLiteral("the user turns on the device hub"), [](World& world, const Captures&, const Table&) { turn(world, QStringLiteral("hub"), true); });
  step(QStringLiteral("the user turns off the device hub"), [](World& world, const Captures&, const Table&) { turn(world, QStringLiteral("hub"), false); });
  step(QStringLiteral("the user turns on agent device access"), [](World& world, const Captures&, const Table&) { turn(world, QStringLiteral("agent"), true); });
  step(QStringLiteral("the user turns off agent device access"), [](World& world, const Captures&, const Table&) { turn(world, QStringLiteral("agent"), false); });
  step(QStringLiteral("agent device access is stored as (on|off) and shown as \\1"), [](World& world, const Captures& c, const Table&) {
    expectStored(world, QStringLiteral("enableAgentDeviceAccess"), c[0] == QLatin1String("on"));
  });
  step(QStringLiteral("the device hub is stored as on"), [](World& world, const Captures&, const Table&) {
    expectStored(world, QStringLiteral("enableDeviceSupport"), true);
  });
  step(QStringLiteral("the device hub is stored as off"), [](World& world, const Captures&, const Table&) {
    expectStored(world, QStringLiteral("enableDeviceSupport"), false);
  });
  step(QStringLiteral("agent device access is stored as off"), [](World& world, const Captures&, const Table&) {
    expectStored(world, QStringLiteral("enableAgentDeviceAccess"), false);
  });
  step(QStringLiteral("the user is told device settings were not saved on all environments and could not update %1").arg(q),
       [](World& world, const Captures& c, const Table&) {
         world.waitFor([&] {
           for (const QVariant& toast : at(world.state(QStringLiteral("toasts")), QStringLiteral("items")).toList()) {
             if (toast.toMap().value(QStringLiteral("title")) == QLatin1String("Device settings not saved on all environments") &&
                 toast.toMap().value(QStringLiteral("description")) == QStringLiteral("Could not update %1.").arg(c[0])) {
               return true;
             }
           }
           return false;
         }, [&] { return QStringLiteral("the failed save to be reported; the shell shows %1").arg(show(world.state(QStringLiteral("toasts")))); });
         expect(documentOf(world.mc, QStringLiteral("Laptop")).settings.value(QLatin1String("enableDeviceSupport")) == QJsonValue(true) &&
                    fakeConfig(world.mc).settings.value(QLatin1String("enableDeviceSupport")) == QJsonValue(true),
                QStringLiteral("the other environments to have saved it"));
       });

  step(QStringLiteral("the device tools are still being checked"), [](World& world, const Captures&, const Table&) {
    ready(world);
    world.mc.hold(QStringLiteral("device"));
    world.bridge().dispatch(QStringLiteral("deviceSettings.check"), QVariantMap{});
    world.waitFor([&] { return section(world).value(QStringLiteral("pending")) == QLatin1String("check"); },
                  [&] { return QStringLiteral("the check to be running; the section is %1").arg(show(section(world))); });
  });
  step(QStringLiteral("the user leaves the Integrations settings and comes back"), [](World& world, const Captures&, const Table&) {
    auto* navigation = world.native().controller<NavigationController>();
    navigation->open(NavigationController::Route::settings(QStringLiteral("/settings/general")));
    world.waitFor([&] { return !section(world).value(QStringLiteral("open")).toBool(); },
                  [&] { return QStringLiteral("the device settings to close; they are %1").arg(show(section(world))); });
    world.mc.answerHeld();
    ready(world);
  });
  step(QStringLiteral("the device hub can be changed again"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return section(world).value(QStringLiteral("pending")).toString().isEmpty() && at(section(world), QStringLiteral("hub.enabled")).toBool(); },
                  [&] { return QStringLiteral("the hub switch to be free; the section is %1").arg(show(section(world))); });
    turn(world, QStringLiteral("hub"), true);
    expectStored(world, QStringLiteral("enableDeviceSupport"), true);
  });

  step(QStringLiteral("the device hub tool update fails"), [](World& world, const Captures&, const Table&) {
    world.mc.part<FakeDevices>().outdated.insert(world.mc.environmentId);
    world.mc.part<FakeDevices>().failUpdates = true;
  });
  step(QStringLiteral("the user updates the device hub tool"), [](World& world, const Captures&, const Table&) {
    ready(world);
    world.waitFor([&] { return at(section(world), QStringLiteral("hub.update")) == QLatin1String("Update to v1.4.0"); },
                  [&] { return QStringLiteral("an update to be offered; the section is %1").arg(show(section(world))); });
    world.bridge().dispatch(QStringLiteral("deviceSettings.update"), QVariantMap{{QStringLiteral("tool"), QStringLiteral("hub")}});
  });
  step(QStringLiteral("the user is told to check this host's network connection and try again"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      return at(section(world), QStringLiteral("updateError.tool")) == QLatin1String("hub") &&
             at(section(world), QStringLiteral("updateError.message")).toString().contains(QLatin1String("Check this host's network connection and try again"));
    }, [&] { return QStringLiteral("the failed update to be explained; the section is %1").arg(show(section(world))); });
  });

  step(QStringLiteral("the user is editing settings across %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    // This machine is the first; the other is linked.
    world.mc.label = c[0];
    fakeConfig(world.mc).elsewhere.insert(c[1], QJsonObject{});
    documentOf(world.mc, c[1]).settings.insert(QStringLiteral("enableDeviceSupport"), true);
    world.mc.linkLabels.insert(c[1], c[1]);
    world.mc.link(c[1]);
    saveElsewhere(world.mc, QStringLiteral("enableDeviceSupport"), true, true);
    ready(world);
    chooseAllEnvironments(world);
  });
  step(QStringLiteral("the user looks at simulator support"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return section(world).value(QStringLiteral("platforms")).toList().size() == 2; },
                  [&] { return QStringLiteral("simulator support to show; the section is %1").arg(show(section(world))); });
  });
  step(QStringLiteral("the iOS and Android status of %1 is shown").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return section(world).value(QStringLiteral("statusNote")).toString().startsWith(QStringLiteral("Status for %1.").arg(c[0])); },
                  [&] { return QStringLiteral("the status to be %1's; the section is %2").arg(c[0], show(section(world))); });
    const QVariantList platforms = section(world).value(QStringLiteral("platforms")).toList();
    expect(platforms.size() == 2 && platforms[0].toMap().value(QStringLiteral("platform")) == QLatin1String("iOS") &&
               platforms[0].toMap().value(QStringLiteral("ready")).toBool() &&
               platforms[1].toMap().value(QStringLiteral("platform")) == QLatin1String("Android") &&
               platforms[1].toMap().value(QStringLiteral("message")) == QLatin1String("The Android SDK was not found."),
           QStringLiteral("this machine's iOS and Android status; the section is %1").arg(show(section(world))));
  });
  step(QStringLiteral("the user is told to select an environment to inspect its simulator support"), [](World& world, const Captures&, const Table&) {
    expect(section(world).value(QStringLiteral("statusNote")).toString().endsWith(QLatin1String("Select an environment to inspect its simulator support.")),
           QStringLiteral("the note; the section is %1").arg(show(section(world))));
  });
});

}  // namespace
