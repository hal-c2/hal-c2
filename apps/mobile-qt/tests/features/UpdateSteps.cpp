// Updating environments and their providers from the phone (features/settings/
// updates.feature): Settings → Maintenance (Maintenance, MaintenanceSettings.qml),
// and the update the connection notice offers when the environment is behind
// the app. The MC answers `server.updateServer`, `server.updateProvider` and
// `server.refreshProviders` as apps/server-ex does; releases come from a fake
// index on the environment's own address.

#include <QJsonArray>
#include <QJsonDocument>
#include <QQuickItem>
#include <QTcpSocket>

#include "ConnectionHealthController.h"
#include "FakeThreads.h"
#include "Harness.h"
#include "Maintenance.h"
#include "McClient.h"
#include "NativeShell.h"
#include "Phone.h"
#include "World.h"

namespace {

using S = QString;

// Longer than any scenario: nothing the phone does on its own is due.
const int kLater = 60 * 60 * 1000;

const S kOwn = S("env-a");
const S kWsl = S("wsl");

// The MC's side of maintenance.
struct FakeUpdates {
  // Each environment's providers, the MC's own included (its config's).
  QHash<QString, QJsonArray> providers;
  // How a provider update ends on each environment (its `updateState`).
  QHash<QString, QJsonObject> providerEnds;
  // Provider updates wait for the scenario to end them.
  bool holdProviders = false;
  QList<FakeMc::Rpc> heldProviders;
  // Server updates: the version each environment comes back on, or why it fails.
  QHash<QString, QString> reconnectOn;
  QHash<QString, QString> serverFailures;
  // The environments told to update, in order.
  QStringList serverUpdates;
  // The release index, newest first.
  QJsonArray releases;
};

QString environmentOf(const FakeMc& mc, const FakeMc::Rpc& rpc) { return rpc.environment.isEmpty() ? mc.environmentId : rpc.environment; }

// The environment's providers are `providers`, as its MC would say next.
void setProviders(FakeMc& mc, const QString& environment, const QJsonArray& providers) {
  mc.part<FakeUpdates>().providers.insert(environment, providers);
  if (environment == mc.environmentId) offerProviders(mc, providers);
}

void endProviderUpdate(FakeMc& mc, const FakeMc::Rpc& rpc) {
  FakeUpdates& fake = mc.part<FakeUpdates>();
  const QString environment = environmentOf(mc, rpc);
  const QString instance = rpc.payload.value(QLatin1String("instanceId")).toString();
  QJsonArray providers = fake.providers.value(environment);
  for (qsizetype i = 0; i < providers.size(); ++i) {
    QJsonObject provider = providers.at(i).toObject();
    if (provider.value(QLatin1String("instanceId")).toString() != instance) continue;
    const QJsonObject end = fake.providerEnds.value(environment, QJsonObject{{S("status"), S("succeeded")}});
    provider.insert(S("updateState"), end);
    if (end.value(QLatin1String("status")).toString() == QLatin1String("succeeded")) {
      QJsonObject advisory = provider.value(QLatin1String("versionAdvisory")).toObject();
      advisory.insert(S("status"), S("current"));
      advisory.insert(S("currentVersion"), advisory.value(QLatin1String("latestVersion")));
      provider.insert(S("versionAdvisory"), advisory);
    }
    providers.replace(i, provider);
  }
  setProviders(mc, environment, providers);
  mc.reply(rpc, QJsonObject{{S("providers"), providers}});
}

const FakeMc::Extension updates([](FakeMc& mc) {
  mc.onRpc(S("server.refreshProviders"), [&mc](const FakeMc::Rpc& rpc) {
    mc.reply(rpc, QJsonObject{{S("providers"), mc.part<FakeUpdates>().providers.value(environmentOf(mc, rpc))}});
  });
  mc.onRpc(S("server.updateProvider"), [&mc](const FakeMc::Rpc& rpc) {
    FakeUpdates& fake = mc.part<FakeUpdates>();
    if (fake.holdProviders) {
      fake.heldProviders.append(rpc);
      return;
    }
    endProviderUpdate(mc, rpc);
  });
  mc.onRpc(S("server.updateServer"), [&mc](const FakeMc::Rpc& rpc) {
    FakeUpdates& fake = mc.part<FakeUpdates>();
    const QString environment = environmentOf(mc, rpc);
    fake.serverUpdates.append(environment);
    if (fake.serverFailures.contains(environment)) return mc.refuse(rpc, fake.serverFailures.value(environment));
    const QString target = rpc.payload.value(QLatin1String("targetVersion")).toString();
    mc.reply(rpc, QJsonObject{{S("targetVersion"), target}, {S("method"), S("hot-upgrade")}});
    // A hot upgrade: the MC comes back on the new release and its shell says so.
    QJsonObject descriptor = mc.descriptors.value(environment);
    descriptor.insert(S("serverVersion"), fake.reconnectOn.value(environment, target));
    mc.descriptors.insert(environment, descriptor);
    if (environment == mc.environmentId) {
      mc.announceEnvironment();
    } else {
      mc.join(mc.peers.value(environment), environment);
    }
  });
  mc.onRaw(S("/releases"), [&mc](QTcpSocket* socket, const QByteArray&) {
    pairable::answer(socket, 200, QJsonDocument(mc.part<FakeUpdates>().releases).toJson(QJsonDocument::Compact));
  });
});

// The environment runs `version` of HAL-C2, updated the way `selfUpdate` says
// ("" for by hand), and is called `label` when it is the MC's own.
void describe(FakeMc& mc, const QString& environment, const QString& version, const QJsonObject& selfUpdate = {}) {
  QJsonObject capabilities = mc.capabilities;
  for (auto it = selfUpdate.begin(); it != selfUpdate.end(); ++it) capabilities.insert(it.key(), it.value());
  mc.descriptors.insert(environment, QJsonObject{{S("serverVersion"), version}, {S("capabilities"), capabilities}});
}

const QJsonObject kService{{S("serverSelfUpdate"), S("hot-upgrade")}};
const QJsonObject kDesktopHost{{S("serverSelfUpdate"), S("desktop-managed")}, {S("desktopAppUpdate"), true}};

// This app is `version`, as its build says.
void appIs(World& world, const QString& version) {
  world.native().shared<ConnectionHealthController>()->setClientVersion(version);
  world.app().maintenance().setAppVersion(version);
}

// The paired environment is called `label`, before the phone pairs with it.
void callEnvironment(World& world, const QString& label) {
  expect(!world.isOpen() || world.native().client()->environment().isEmpty(), S("the phone is already paired with %1").arg(world.mc.label));
  world.mc.label = label;
}

QJsonObject provider(const QString& driver, bool enabled, const QJsonObject& updateState = {}) {
  QJsonObject provider{{S("instanceId"), driver},
                       {S("driver"), driver},
                       {S("enabled"), enabled},
                       {S("installed"), true},
                       {S("availability"), S("available")},
                       {S("versionAdvisory"), QJsonObject{{S("status"), S("behind_latest")},
                                                          {S("canUpdate"), true},
                                                          {S("currentVersion"), S("0.50.0")},
                                                          {S("latestVersion"), S("0.51.0")}}}};
  if (!updateState.isEmpty()) provider.insert(S("updateState"), updateState);
  return provider;
}

QString screenTexts(World& world) { return world.texts().join(S(" | ")); }

QVariantMap maintenanceState(World& world) { return world.state(S("maintenance")).toMap(); }

QString textOf(World& world, const QString& objectName) { return world.item(objectName)->property("text").toString(); }

// The item named `objectName` comes to say `text`.
void awaitText(World& world, const QString& objectName, const QString& text) {
  world.waitFor([&] { return world.find(objectName) != nullptr && world.find(objectName)->property("text").toString() == text; },
                [&] { return S("%1 to say \"%2\"; the screen says: %3").arg(objectName, text, screenTexts(world)); });
}

// Home's bar, Settings, and its Maintenance page.
void openMaintenance(World& world) {
  if (world.isOpen() && world.find(S("maintenanceSettings")) != nullptr) return;
  world.tap(S("settings"));
  world.item(S("settingsSections"));
  QQuickItem* row = nullptr;
  world.waitFor(
      [&] {
        row = world.findWhere([](QQuickItem* candidate) {
          return candidate->objectName().startsWith(QLatin1String("settingsRow")) &&
                 candidate->property("modelData").toMap().value(S("to")).toString() == QLatin1String("/settings/maintenance");
        });
        return row != nullptr;
      },
      [&] { return S("Maintenance among the settings; the screen says: %1").arg(screenTexts(world)); });
  world.tap(row);
  world.item(S("maintenanceSettings"));
}

// The phone's maintenance page, the session's permissions read: what it may start is on screen.
void openOperable(World& world) {
  openMaintenance(world);
  world.item(S("maintenanceCheck-") + kOwn);
}

// The paired environment "server", behind this app at 1.3.0 against 1.4.0 and updated as `selfUpdate` says.
void serverBehind(World& world, const QJsonObject& selfUpdate = kService) {
  callEnvironment(world, S("server"));
  describe(world.mc, kOwn, S("1.3.0"), selfUpdate);
  appIs(world, S("1.4.0"));
  pairWithEnvironment(world);
}

// The user reconnects: the connection drops and the phone is back on it.
void reconnect(World& world) {
  McClient* client = world.native().client();
  const qsizetype before = world.mc.connections.size();
  world.mc.drop();
  world.waitFor([&] { return world.mc.connections.size() > before && client->isReady(); },
                [&] { return S("the phone to reconnect; it is %1").arg(show(world.state(S("connection")))); });
  world.sync();
}

const Steps steps([] {
  // The connection notice and the conversation.

  step(S("the app is newer than the server on %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    callEnvironment(world, c[0]);
    describe(world.mc, kOwn, S("1.3.0"), kService);
    appIs(world, S("1.4.0"));
  });

  step(S("the user opens a thread on %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    expect(world.mc.label == c[0], S("the paired environment is %1").arg(world.mc.label));
    pairWithEnvironment(world);
    openThread(world, S("Tax line"));
  });

  step(S("the user is offered to update %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    awaitText(world, S("connectionUpdate"), S("Update %1").arg(c[0]));
    world.tap(S("connectionUpdate"));
    awaitText(world, S("maintenanceUpdate-") + kOwn, S("Update to 1.4.0"));
  });

  step(S("the user dismissed the update notice for %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    callEnvironment(world, S("server"));
    describe(world.mc, kOwn, S("1.3.0"), kService);
    appIs(world, c[0]);
    pairWithEnvironment(world);
    world.item(S("connectionUpdate"));
    world.tap(S("connectionDismissWarning"));
    world.waitFor([&] { return world.find(S("connectionUpdate")) == nullptr; },
                  [&] { return S("the notice to go; the screen says: %1").arg(screenTexts(world)); });
  });

  step(S("the user reconnects to the same server"), [](World& world, const Captures&, const Table&) { reconnect(world); });

  step(S("the notice for %1 does not return").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    const QVariant warning = world.state(S("connection")).toMap().value(S("versionWarning"));
    expect(warning.isNull() || !warning.isValid(), S("the notice for %1 is back: %2").arg(c[0], show(warning)));
    expect(world.find(S("connectionUpdate")) == nullptr, S("the update is offered again; the screen says: %1").arg(screenTexts(world)));
  });

  // The next release of the app: the notice is for it.
  step(S("a notice for %1 does appear").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    appIs(world, c[0]);
    awaitText(world, S("connectionUpdate"), S("Update server"));
    const QVariantMap warning = world.state(S("connection")).toMap().value(S("versionWarning")).toMap();
    expect(warning.value(S("clientVersion")).toString() == c[0], S("the notice is for %1").arg(show(warning)));
  });

  // Server updates.

  step(S("the user updates %1 and it reconnects on %2").arg(kQuoted, kQuoted), [](World& world, const Captures& c, const Table&) {
    callEnvironment(world, c[0]);
    world.mc.part<FakeUpdates>().reconnectOn.insert(kOwn, c[1]);
    describe(world.mc, kOwn, S("1.3.0"), kService);
    appIs(world, c[1]);
    pairWithEnvironment(world);
    openOperable(world);
    world.tap(S("maintenanceUpdate-") + kOwn);
  });

  step(S("the user is told %1 was updated and reconnected on %2").arg(kQuoted, kQuoted), [](World& world, const Captures& c, const Table&) {
    awaitText(world, S("maintenanceOutcome-") + kOwn, S("%1 was updated and reconnected on %2.").arg(c[0], c[1]));
    awaitText(world, S("maintenanceVersion-") + kOwn, S("Version %1").arg(c[1]));
  });

  step(S("%1 is hosted by the desktop app and %2 is a service").arg(kQuoted, kQuoted), [](World& world, const Captures& c, const Table&) {
    callEnvironment(world, c[1]);
    describe(world.mc, kOwn, S("1.3.0"), kService);
    describe(world.mc, c[0], S("1.3.0"), kDesktopHost);
    // The desktop app on it is not there to relaunch.
    world.mc.part<FakeUpdates>().serverFailures.insert(c[0], S("The desktop app could not be reached."));
    world.mc.join(c[0]);
    appIs(world, S("1.4.0"));
    pairWithEnvironment(world);
  });

  step(S("the user updates all machines"), [](World& world, const Captures&, const Table&) {
    openOperable(world);
    world.waitFor([&] { return maintenanceState(world).value(S("updatable")).toInt() == 2; },
                  [&] { return S("both machines to be updatable; maintenance is %1").arg(show(maintenanceState(world))); });
    world.tap(S("maintenanceUpdateAll"));
  });

  step(S("the user is asked to confirm that the desktop app on %1 will relaunch").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    awaitText(world, S("maintenanceConfirmText"),
              S("Update the HAL-C2 desktop app that runs %1? It will close and relaunch on that machine.").arg(c[0]));
  });

  step(S("%1 updates independently of %2").arg(kQuoted, kQuoted), [](World& world, const Captures& c, const Table&) {
    FakeUpdates& fake = world.mc.part<FakeUpdates>();
    // Before the user answers, the service is already updating.
    world.waitFor([&] { return fake.serverUpdates == QStringList{kOwn}; },
                  [&] { return S("only %1 to be updated; updated: %2").arg(c[0], fake.serverUpdates.join(S(", "))); });
    awaitText(world, S("maintenanceOutcome-") + kOwn, S("%1 was updated and reconnected on 1.4.0.").arg(c[0]));
    // And whatever happens to the desktop app, it stays updated.
    world.tap(S("maintenanceConfirmUpdate"));
    awaitText(world, S("maintenanceOutcome-") + c[1], S("%1 update failed: The desktop app could not be reached.").arg(c[1]));
    awaitText(world, S("maintenanceOutcome-") + kOwn, S("%1 was updated and reconnected on 1.4.0.").arg(c[0]));
  });

  step(S("the user copies the update command for %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    callEnvironment(world, c[0]);
    describe(world.mc, kOwn, S("1.3.0"));
    appIs(world, S("1.4.0"));
    pairWithEnvironment(world);
    openOperable(world);
    world.tap(S("maintenanceCopyCommand-") + kOwn);
  });

  step(S("the command for the matching version is on the clipboard"), [](World& world, const Captures&, const Table&) {
    expect(world.clipboard == QLatin1String("npx hal-c2@1.4.0"), S("the clipboard has \"%1\"").arg(world.clipboard));
    awaitText(world, S("maintenanceMessage"), S("Update command copied. Run `npx hal-c2@1.4.0` on server."));
  });

  // The phone's maintenance of an environment.

  step(S("%1 is connected to the phone").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    callEnvironment(world, c[0]);
    describe(world.mc, kOwn, S("1.3.0"), kService);
    // Newest first: a nightly past it, which a stable server does not follow.
    world.mc.part<FakeUpdates>().releases = QJsonArray{
        QJsonObject{{S("tag_name"), S("mc-v1.5.0-nightly.20261030.1")}},
        QJsonObject{{S("tag_name"), S("mc-v1.6.0")}, {S("draft"), true}},
        QJsonObject{{S("tag_name"), S("mc-v1.4.0")}},
        QJsonObject{{S("tag_name"), S("mc-v1.3.0")}},
    };
    pairWithEnvironment(world);
  });

  step(S("the user checks %1 for updates").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    expect(world.mc.label == c[0], S("the paired environment is %1").arg(world.mc.label));
    openOperable(world);
    world.tap(S("maintenanceCheck-") + kOwn);
  });

  step(S("the phone says whether a newer HAL-C2 release is available on %1's channel").arg(kQuoted), [](World& world, const Captures&, const Table&) {
    awaitText(world, S("maintenanceRelease-") + kOwn, S("Version 1.4.0 is available."));
    awaitText(world, S("maintenanceUpdate-") + kOwn, S("Update to 1.4.0"));
  });

  step(S("Codex is enabled on %1 and Claude is not").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    callEnvironment(world, c[0]);
    setProviders(world.mc, kOwn, QJsonArray{provider(S("codex"), true), provider(S("claudeAgent"), false)});
    pairWithEnvironment(world);
  });

  step(S("Codex is enabled on %1 and behind its latest release").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    callEnvironment(world, c[0]);
    setProviders(world.mc, kOwn, QJsonArray{provider(S("codex"), true)});
    pairWithEnvironment(world);
  });

  step(S("the user opens the maintenance of %1 on the phone").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    expect(world.mc.label == c[0], S("the paired environment is %1").arg(world.mc.label));
    openMaintenance(world);
  });

  step(S("only Codex is offered for update on %1").arg(kQuoted), [](World& world, const Captures&, const Table&) {
    awaitText(world, S("maintenanceUpdateProvider-env-a-codex"), S("Update Codex"));
    expect(world.find(S("maintenanceProvider-env-a-claudeAgent")) == nullptr,
           S("Claude is offered, though it is turned off; the screen says: %1").arg(screenTexts(world)));
  });

  step(S("the user updates Codex on %1 from the phone").arg(kQuoted), [](World& world, const Captures&, const Table&) {
    world.mc.part<FakeUpdates>().holdProviders = true;
    openOperable(world);
    world.tap(S("maintenanceUpdateProvider-env-a-codex"));
  });

  step(S("the phone shows the update's progress until it ends"), [](World& world, const Captures&, const Table&) {
    FakeUpdates& fake = world.mc.part<FakeUpdates>();
    world.waitFor([&] { return !fake.heldProviders.isEmpty(); }, S("the phone to ask the MC to update Codex"));
    awaitText(world, S("maintenanceProviderStatus-env-a-codex"), S("Updating…"));
    expect(world.find(S("maintenanceUpdateProvider-env-a-codex")) == nullptr, S("Codex can be updated again while it updates"));
    setProviders(world.mc, kOwn, QJsonArray{provider(S("codex"), true, {{S("status"), S("running")}, {S("message"), S("Installing Codex 0.51.0")}})});
    awaitText(world, S("maintenanceProviderStatus-env-a-codex"), S("Installing Codex 0.51.0"));
    fake.providerEnds.insert(kOwn, QJsonObject{{S("status"), S("failed")}, {S("message"), S("npm is not installed")}});
    endProviderUpdate(world.mc, fake.heldProviders.takeFirst());
  });

  step(S("it says whether the update succeeded and, if it failed, why"), [](World& world, const Captures&, const Table&) {
    awaitText(world, S("maintenanceProviderStatus-env-a-codex"), S("Failed: npm is not installed"));
    // And it can be tried again.
    awaitText(world, S("maintenanceUpdateProvider-env-a-codex"), S("Update Codex"));
  });

  step(S("%1 (is not connected|is connected without the operate scope)").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    callEnvironment(world, c[0]);
    if (c[1] == QLatin1String("is connected without the operate scope")) {
      world.environment.scopes = {S("orchestration:read")};
      pairWithEnvironment(world);
      return;
    }
    pairWithEnvironment(world);
    McClient* client = world.native().client();
    client->setRetryDelays({20, kLater});
    world.mc.stopAccepting();
    world.mc.drop();
    world.waitFor([&] { return client->phase() == McClient::Phase::Retrying && client->retryDelay() == kLater; },
                  [&] { return S("the phone to give up for now; the connection is %1").arg(show(world.state(S("connection")))); });
  });

  step(S("its updates cannot be started and the user is told why"), [](World& world, const Captures&, const Table&) {
    const QString blocked = S("maintenanceBlocked-") + kOwn;
    world.waitFor(
        [&] {
          const QString why = world.find(blocked) ? world.find(blocked)->property("text").toString() : QString();
          return why == QLatin1String("Connect this environment to manage it.") ||
                 why == QLatin1String("This connection does not have permission to manage the environment.");
        },
        [&] { return S("the phone to say why; the screen says: %1").arg(screenTexts(world)); });
    const bool connected = world.native().client()->isReady();
    expect(textOf(world, blocked) == (connected ? S("This connection does not have permission to manage the environment.")
                                                : S("Connect this environment to manage it.")),
           S("the phone says \"%1\"").arg(textOf(world, blocked)));
    for (const QString& control : {S("maintenanceCheck-"), S("maintenanceUpdate-"), S("maintenanceRefresh-")}) {
      expect(world.find(control + kOwn) == nullptr, S("%1 can still be used").arg(control + kOwn));
    }
    expect(maintenanceState(world).value(S("updatable")).toInt() == 0, S("an update can still be started: %1").arg(show(maintenanceState(world))));
  });

  // Providers on several machines.

  step(S("Codex is behind on %1 and on its WSL environment").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    callEnvironment(world, c[0]);
    setProviders(world.mc, kOwn, QJsonArray{provider(S("codex"), true)});
    setProviders(world.mc, kWsl, QJsonArray{provider(S("codex"), true)});
    world.mc.part<FakeUpdates>().providerEnds.insert(kWsl, QJsonObject{{S("status"), S("failed")}, {S("message"), S("npm is not installed")}});
    world.mc.peerLabels.insert(kWsl, S("WSL · Ubuntu"));
    world.mc.join(S("mc-wsl"), kWsl);
    pairWithEnvironment(world);
  });

  step(S("the user updates Codex on both"), [](World& world, const Captures&, const Table&) {
    openOperable(world);
    awaitText(world, S("maintenanceUpdateProviders-codex"), S("Update Codex on 2 machines"));
    world.tap(S("maintenanceUpdateProviders-codex"));
  });

  step(S("each machine shows whether its update succeeded, was unchanged or failed"), [](World& world, const Captures&, const Table&) {
    awaitText(world, S("maintenanceProviderStatus-env-a-codex"), S("Updated"));
    awaitText(world, S("maintenanceProviderStatus-wsl-codex"), S("Failed: npm is not installed"));
  });
});

}  // namespace
