// The Providers settings section on the desktop (ProviderSettingsController):
// the @desktop scenarios of features/settings/providers-panel.feature and
// the desktop's side of providers/provider-setup.feature. The node's own
// environment plays "Laptop", this machine; others are linked environments.

#include <QJsonArray>
#include <QJsonObject>

#include "FakeConfig.h"
#include "Harness.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "World.h"

namespace {

// The node's side of sign-in (HalC2.ProviderAuth) and updates.
struct FakeProviders {
  QHash<QString, QJsonObject> auth;  // each instance's ProviderAuthState
  QStringList starts, cancels, logouts;
  QList<FakeNode::Rpc> updates;
  QString updateRefusal;
  int followedBefore = 0;
  QString instanceId;  // the instance the scenario last acted on
  QString suggestedId;  // the id the add-provider wizard last suggested
  QString choices;  // what the wizard held before the user went back
  QStringList uninstalls;  // agents whose managed binary was cleaned up
  QString uninstallRefusal;
};

FakeProviders& fake(World& world) {
  return world.node.part<FakeProviders>();
}

const QString kSignInUrl = QStringLiteral("https://auth.example/gemini");
const QString kUpdateCommand = QStringLiteral("npm install -g @openai/codex@latest");

QJsonObject authState(const QString& instanceId, const QJsonObject& fields = {}) {
  QJsonObject state{{QStringLiteral("instanceId"), instanceId},
                    {QStringLiteral("phase"), QStringLiteral("idle")},
                    {QStringLiteral("methods"), QJsonArray{QJsonObject{{QStringLiteral("id"), QStringLiteral("browser")}}}}};
  for (auto it = fields.begin(); it != fields.end(); ++it) state.insert(it.key(), it.value());
  return state;
}

void sendAuth(FakeNode& node, const QString& instanceId, const QJsonObject& fields) {
  QJsonObject& state = node.part<FakeProviders>().auth[instanceId];
  state = authState(instanceId, fields);
  for (const int id : node.subscribers(QStringLiteral("providerAuth"))) {
    if (node.shapeOf(id).value(QLatin1String("instanceId")) != instanceId) continue;
    node.send({{QStringLiteral("t"), QStringLiteral("providerAuth")}, {QStringLiteral("id"), id}, {QStringLiteral("state"), state}});
  }
}

const FakeNode::Extension extension([](FakeNode& node) {
  node.onShape(QStringLiteral("providerAuth"), [&node](int id, const QJsonObject& shape) {
    const QString instanceId = shape.value(QLatin1String("instanceId")).toString();
    const QJsonObject state = node.part<FakeProviders>().auth.value(instanceId, authState(instanceId));
    node.send({{QStringLiteral("t"), QStringLiteral("providerAuth")}, {QStringLiteral("id"), id}, {QStringLiteral("state"), state}});
  });
  node.onRpc(QStringLiteral("provider.auth.start"), [&node](const FakeNode::Rpc& rpc) {
    const QString instanceId = rpc.payload.value(QLatin1String("instanceId")).toString();
    node.part<FakeProviders>().starts.append(instanceId);
    node.reply(rpc, QJsonObject{});
    sendAuth(node, instanceId,
             {{QStringLiteral("phase"), QStringLiteral("waiting")},
              {QStringLiteral("flowId"), QStringLiteral("flow-1")},
              {QStringLiteral("interaction"), QJsonObject{{QStringLiteral("id"), QStringLiteral("browser-1")},
                                                          {QStringLiteral("type"), QStringLiteral("browser")},
                                                          {QStringLiteral("url"), kSignInUrl},
                                                          {QStringLiteral("requiresConsent"), false}}}});
  });
  node.onRpc(QStringLiteral("provider.auth.cancel"), [&node](const FakeNode::Rpc& rpc) {
    const QString instanceId = rpc.payload.value(QLatin1String("instanceId")).toString();
    node.part<FakeProviders>().cancels.append(rpc.payload.value(QLatin1String("flowId")).toString());
    node.reply(rpc, QJsonObject{});
    sendAuth(node, instanceId, {{QStringLiteral("phase"), QStringLiteral("cancelled")}});
  });
  node.onRpc(QStringLiteral("provider.auth.logout"), [&node](const FakeNode::Rpc& rpc) {
    node.part<FakeProviders>().logouts.append(rpc.payload.value(QLatin1String("instanceId")).toString());
    node.reply(rpc, QJsonObject{});
  });
  node.onRpc(QStringLiteral("server.uninstallAcpRegistryManagedBinary"), [&node](const FakeNode::Rpc& rpc) {
    FakeProviders& fake = node.part<FakeProviders>();
    fake.uninstalls.append(rpc.payload.value(QLatin1String("agentId")).toString());
    if (fake.uninstallRefusal.isEmpty()) node.reply(rpc, QJsonObject{});
    else node.refuse(rpc, fake.uninstallRefusal);
  });
  node.onRpc(QStringLiteral("server.updateProvider"), [&node](const FakeNode::Rpc& rpc) {
    FakeProviders& fake = node.part<FakeProviders>();
    fake.updates.append(rpc);
    if (!fake.updateRefusal.isEmpty()) {
      node.refuse(rpc, fake.updateRefusal, {{QStringLiteral("_tag"), QStringLiteral("ServerProviderUpdateError")}});
    }
    // Otherwise the update runs until the scenario finishes it.
  });
});

QVariantMap panel(World& world) {
  return world.state(QStringLiteral("providerSettings")).toMap();
}

QVariantMap entry(World& world, const QString& name) {
  for (const QVariant& provider : panel(world).value(QStringLiteral("providers")).toList()) {
    if (provider.toMap().value(QStringLiteral("name")) == name) return provider.toMap();
  }
  return {};
}

QVariantMap waitForEntry(World& world, const QString& name, const std::function<bool(const QVariantMap&)>& ready,
                         const QString& what) {
  world.waitFor([&] { const QVariantMap found = entry(world, name); return !found.isEmpty() && ready(found); },
                [&] { return QStringLiteral("%1 %2; the panel is %3").arg(name, what, show(panel(world))); });
  return entry(world, name);
}

void dispatch(World& world, const QString& action, const QString& name) {
  const QString instanceId = waitForEntry(world, name, [](const QVariantMap&) { return true; }, QStringLiteral("to be listed"))
                                 .value(QStringLiteral("instanceId")).toString();
  fake(world).instanceId = instanceId;
  world.bridge().dispatch(QStringLiteral("providerSettings.") + action, QVariantMap{{QStringLiteral("instanceId"), instanceId}});
}

void openPanel(World& world) {
  if (world.shellSubscriptions() == 0) {
    world.connect();
    world.sync();
  }
  if (panel(world).value(QStringLiteral("open")).toBool()) return;
  fake(world).followedBefore = world.node.subscribers(QStringLiteral("config")).size();
  world.native().controller<NavigationController>()->open(
      NavigationController::Route::settings(NavigationController::kProvidersSection));
  world.waitFor([&] { return panel(world).value(QStringLiteral("open")).toBool(); },
                [&] { return QStringLiteral("the Providers settings to open; they are %1").arg(show(panel(world))); });
}

void answer(World& world, bool accepted) {
  world.waitFor([&] { return world.state(QStringLiteral("confirmation")).typeId() == QMetaType::QVariantMap; },
                QStringLiteral("the user to be asked"));
  const QVariant question = world.state(QStringLiteral("confirmation"));
  world.bridge().dispatch(QStringLiteral("confirmation.answer"),
                          QVariantMap{{QStringLiteral("requestId"), at(question, QStringLiteral("requestId"))}, {QStringLiteral("accepted"), accepted}});
}

QJsonObject provider(const QString& instanceId, const QString& driver, const QString& name, const QJsonObject& fields = {}) {
  QJsonObject entry{{QStringLiteral("instanceId"), instanceId},
                    {QStringLiteral("driver"), driver},
                    {QStringLiteral("displayName"), name},
                    {QStringLiteral("enabled"), true},
                    {QStringLiteral("installed"), true},
                    {QStringLiteral("status"), QStringLiteral("ready")},
                    {QStringLiteral("version"), QStringLiteral("1.0.0")},
                    {QStringLiteral("auth"), QJsonObject{{QStringLiteral("status"), QStringLiteral("unknown")}}},
                    {QStringLiteral("models"), QJsonArray{QJsonObject{{QStringLiteral("slug"), instanceId + QStringLiteral("-model")},
                                                                      {QStringLiteral("name"), name + QStringLiteral(" model")}}}}};
  for (auto it = fields.begin(); it != fields.end(); ++it) entry.insert(it.key(), it.value());
  return entry;
}

// An ACP agent that signs in from HAL-C2.
QJsonObject gemini(const QString& authStatus) {
  QJsonObject auth{{QStringLiteral("status"), authStatus}};
  if (authStatus == QLatin1String("authenticated")) auth.insert(QStringLiteral("email"), QStringLiteral("sam@example.com"));
  return provider(QStringLiteral("gemini"), QStringLiteral("acpRegistry"), QStringLiteral("Gemini"),
                  {{QStringLiteral("auth"), auth},
                   {QStringLiteral("setup"), QJsonObject{{QStringLiteral("canAuthenticate"), true}}}});
}

// This machine's providers, replacing the one with the same instance id.
void offer(World& world, const QJsonObject& entry) {
  QJsonArray providers = fakeConfig(world.node).config.value(QLatin1String("providers")).toArray();
  for (qsizetype i = 0; i < providers.size(); ++i) {
    if (providers.at(i).toObject().value(QLatin1String("instanceId")) == entry.value(QLatin1String("instanceId"))) {
      providers.removeAt(i);
      break;
    }
  }
  providers.append(entry);
  publishProviders(world.node, providers);
}

void linkEnvironment(World& world, const QString& environment, const QJsonArray& providers) {
  fakeConfig(world.node).elsewhere.insert(environment, QJsonObject{{QStringLiteral("providers"), providers}});
  world.node.link(environment);
}

void showEnvironment(World& world, const QString& environment) {
  openPanel(world);
  world.waitFor([&] {
    for (const QVariant& row : panel(world).value(QStringLiteral("environments")).toList()) {
      if (row.toMap().value(QStringLiteral("id")) == environment) return true;
    }
    return false;
  }, [&] { return QStringLiteral("%1 to be offered; the panel is %2").arg(environment, show(panel(world))); });
  world.bridge().dispatch(QStringLiteral("providerSettings.environment"), QVariantMap{{QStringLiteral("id"), environment}});
  world.waitFor([&] { return panel(world).value(QStringLiteral("environmentId")) == environment; },
                [&] { return QStringLiteral("%1 to be shown; the panel is %2").arg(environment, show(panel(world))); });
}

bool instanceEnabled(World& world, const QString& instanceId) {
  return fakeConfig(world.node).settings.value(QLatin1String("providerInstances")).toObject()
      .value(instanceId).toObject().value(QLatin1String("enabled")).toBool(true);
}

void expectEnabled(World& world, bool enabled) {
  const QString instanceId = fake(world).instanceId;
  waitForEntry(world, QStringLiteral("Claude Work"), [&](const QVariantMap& found) {
    return found.value(QStringLiteral("enabled")).toBool() == enabled && instanceEnabled(world, instanceId) == enabled &&
           (found.value(QStringLiteral("headline")) == QLatin1String("Disabled")) == !enabled;
  }, enabled ? QStringLiteral("to be on in the saved settings") : QStringLiteral("to be off in the saved settings"));
}

// This machine's settings gain the instance, as another client would add it,
// and the machine lists it; it shows once its settings are there to edit.
void seedInstance(World& world, const QString& instanceId, const QJsonObject& instance, const QJsonObject& listed) {
  openPanel(world);
  QJsonObject instances = fakeConfig(world.node).settings.value(QLatin1String("providerInstances")).toObject();
  instances.insert(instanceId, instance);
  saveElsewhere(world.node, QStringLiteral("providerInstances"), instances);
  offer(world, listed);
  const QString name = listed.value(QLatin1String("displayName")).toString();
  waitForEntry(world, name, [](const QVariantMap& found) { return found.value(QStringLiteral("editable")).toBool(); },
               QStringLiteral("to be editable"));
  fake(world).instanceId = instanceId;
}

// "Claude Work", an added Claude instance.
void seedWork(World& world, const QString& name, const QJsonArray& environment = {}) {
  QJsonObject instance{{QStringLiteral("driver"), QStringLiteral("claudeAgent")},
                       {QStringLiteral("displayName"), name},
                       {QStringLiteral("enabled"), true}};
  if (!environment.isEmpty()) instance.insert(QStringLiteral("environment"), environment);
  seedInstance(world, QStringLiteral("claudeAgent_work"), instance,
               provider(QStringLiteral("claudeAgent_work"), QStringLiteral("claudeAgent"), name));
}

QJsonObject savedInstance(World& world, const QString& instanceId) {
  return fakeConfig(world.node).settings.value(QLatin1String("providerInstances")).toObject().value(instanceId).toObject();
}

QVariantMap wizard(World& world) {
  return panel(world).value(QStringLiteral("wizard")).toMap();
}

void act(World& world, const QString& action, const QVariantMap& payload = {}) {
  world.bridge().dispatch(QStringLiteral("providerSettings.") + action, payload);
}

void openWizard(World& world) {
  openPanel(world);
  world.waitFor([&] { return panel(world).value(QStringLiteral("status")) == QLatin1String("ready"); },
                [&] { return QStringLiteral("the providers to be ready; the panel is %1").arg(show(panel(world))); });
  act(world, QStringLiteral("wizardOpen"));
  world.waitFor([&] { return !wizard(world).isEmpty(); }, [&] { return QStringLiteral("the wizard to open; the panel is %1").arg(show(panel(world))); });
}

// Chooses the driver shown as `label` and names the instance.
void startAdding(World& world, const QString& driverLabel, const std::optional<QString>& label) {
  openWizard(world);
  QString driver;
  for (const QVariant& option : wizard(world).value(QStringLiteral("drivers")).toList()) {
    if (option.toMap().value(QStringLiteral("label")) == driverLabel) driver = option.toMap().value(QStringLiteral("id")).toString();
  }
  expect(!driver.isEmpty(), QStringLiteral("the wizard to offer %1; it is %2").arg(driverLabel, show(wizard(world))));
  act(world, QStringLiteral("wizardDriver"), {{QStringLiteral("driver"), driver}});
  act(world, QStringLiteral("wizardStep"), {{QStringLiteral("step"), 1}});
  if (label) act(world, QStringLiteral("wizardLabel"), {{QStringLiteral("label"), *label}});
  world.waitFor([&] { return wizard(world).value(QStringLiteral("driver")) == driver && wizard(world).value(QStringLiteral("step")) == 1 &&
                             (!label || wizard(world).value(QStringLiteral("label")) == *label); },
                [&] { return QStringLiteral("the identity step for %1; the wizard is %2").arg(driverLabel, show(wizard(world))); });
  fake(world).suggestedId = wizard(world).value(QStringLiteral("instanceId")).toString();
}

void finishAdding(World& world) {
  act(world, QStringLiteral("wizardStep"), {{QStringLiteral("step"), 2}});
  act(world, QStringLiteral("wizardSubmit"));
}

bool toasted(World& world, const QString& title, const QString& description = {}) {
  for (const QVariant& toast : at(world.state(QStringLiteral("toasts")), QStringLiteral("items")).toList()) {
    if (toast.toMap().value(QStringLiteral("title")) == title &&
        (description.isEmpty() || toast.toMap().value(QStringLiteral("description")) == description)) {
      return true;
    }
  }
  return false;
}

void expectToast(World& world, const QString& title, const QString& description = {}) {
  world.waitFor([&] { return toasted(world, title, description); },
                [&] { return QStringLiteral("a toast \"%1\"; the shell shows %2").arg(title, show(world.state(QStringLiteral("toasts")))); });
}

QVariantList variables(World& world, const QString& name) {
  return entry(world, name).value(QStringLiteral("variables")).toList();
}

QVariantMap account(World& world, const QString& name) {
  return entry(world, name).value(QStringLiteral("account")).toMap();
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("the user has opened the Providers settings for the environment %1").arg(q),
       [](World& world, const Captures&, const Table&) { openPanel(world); });

  // Environments.
  step(QStringLiteral("the user has environments %1, %1 and this machine").arg(q), [](World& world, const Captures& c, const Table&) {
    linkEnvironment(world, c[0], {});
    linkEnvironment(world, c[1], {});
  });
  step(QStringLiteral("the user chooses which environment's providers to show"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return panel(world).value(QStringLiteral("environments")).toList().size() == 3; },
                  [&] { return QStringLiteral("three environments; the panel is %1").arg(show(panel(world))); });
  });
  step(QStringLiteral("this machine is listed first and the others follow by name"), [](World& world, const Captures&, const Table&) {
    QStringList labels;
    for (const QVariant& row : panel(world).value(QStringLiteral("environments")).toList()) {
      labels.append(row.toMap().value(QStringLiteral("label")).toString());
    }
    expect(labels == QStringList{QStringLiteral("This machine"), QStringLiteral("Build box"), QStringLiteral("Laptop")},
           QStringLiteral("the environments are %1").arg(labels.join(QStringLiteral(", "))));
  });
  step(QStringLiteral("%1 is disconnected").arg(q), [](World& world, const Captures& c, const Table&) {
    linkEnvironment(world, c[0], {provider(QStringLiteral("codex"), QStringLiteral("codex"), QStringLiteral("Codex"))});
    world.node.setLinkProblem(c[0], QStringLiteral("unreachable"));
  });
  step(QStringLiteral("%1 reconnects").arg(q), [](World& world, const Captures& c, const Table&) {
    world.node.setLinkProblem(c[0], QString());
  });
  step(QStringLiteral("the user shows the providers of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    showEnvironment(world, c[0]);
  });
  step(QStringLiteral("the user is told to reconnect the device to set up its provider"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return panel(world).value(QStringLiteral("status")) == QLatin1String("offline") &&
                               panel(world).value(QStringLiteral("description")).toString().startsWith(QLatin1String("Reconnect this device")) &&
                               panel(world).value(QStringLiteral("providers")).toList().isEmpty(); },
                  [&] { return QStringLiteral("the panel to ask for a reconnect; it is %1").arg(show(panel(world))); });
  });
  step(QStringLiteral("the providers of %1 are listed").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForEntry(world, QStringLiteral("Codex"), [&](const QVariantMap&) {
      return panel(world).value(QStringLiteral("environmentId")) == c[0] && panel(world).value(QStringLiteral("status")) == QLatin1String("ready");
    }, QStringLiteral("of ") + c[0] + QStringLiteral(" to be listed"));
  });
  step(QStringLiteral("the user leaves the Providers settings"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !world.node.subscribers(QStringLiteral("providerAuth")).isEmpty(); }, QStringLiteral("a sign-in to be followed"));
    world.native().controller<NavigationController>()->open(NavigationController::Route::of(QStringLiteral("home")));
  });
  step(QStringLiteral("no provider or sign-in is followed for the panel"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.node.subscribers(QStringLiteral("config")).size() == fake(world).followedBefore &&
                               world.node.subscribers(QStringLiteral("providerAuth")).isEmpty(); },
                  [&] { return QStringLiteral("only the shell's own config to be followed; %1 configs and %2 sign-ins are")
                            .arg(world.node.subscribers(QStringLiteral("config")).size())
                            .arg(world.node.subscribers(QStringLiteral("providerAuth")).size()); });
  });

  // Turning an instance off and on.
  step(QStringLiteral("the user turns off the %1 instance").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString instanceId = QStringLiteral("claudeAgent_work");
    FakeConfig& config = fakeConfig(world.node);
    QJsonObject instances = config.settings.value(QLatin1String("providerInstances")).toObject();
    instances.insert(instanceId, QJsonObject{{QStringLiteral("driver"), QStringLiteral("claudeAgent")},
                                             {QStringLiteral("displayName"), c[0]},
                                             {QStringLiteral("enabled"), true}});
    config.settings.insert(QStringLiteral("providerInstances"), instances);
    offer(world, provider(instanceId, QStringLiteral("claudeAgent"), c[0]));
    waitForEntry(world, c[0], [](const QVariantMap& found) { return found.value(QStringLiteral("enabled")).toBool(); },
                 QStringLiteral("to be listed on"));
    fake(world).instanceId = instanceId;
    world.bridge().dispatch(QStringLiteral("providerSettings.enable"),
                            QVariantMap{{QStringLiteral("instanceId"), instanceId}, {QStringLiteral("enabled"), false}});
  });
  step(QStringLiteral("the user turns it back on"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("providerSettings.enable"),
                            QVariantMap{{QStringLiteral("instanceId"), fake(world).instanceId}, {QStringLiteral("enabled"), true}});
  });
  // The model picker leaves out what the environment reports disabled
  // (providers/models.feature); the panel turns it off where the node reads it.
  step(QStringLiteral("its models are not offered in new threads"), [](World& world, const Captures&, const Table&) {
    expectEnabled(world, false);
  });
  step(QStringLiteral("its models are offered again"), [](World& world, const Captures&, const Table&) {
    expectEnabled(world, true);
  });
  step(QStringLiteral("saving settings on %1 fails").arg(q), [](World& world, const Captures&, const Table&) {
    fakeConfig(world.node).refuseWrites = QStringLiteral("The settings file could not be written.");
  });
  step(QStringLiteral("the user is told the provider settings could not be saved"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      for (const QVariant& toast : at(world.state(QStringLiteral("toasts")), QStringLiteral("items")).toList()) {
        if (toast.toMap().value(QStringLiteral("title")) == QLatin1String("Could not save provider settings")) return true;
      }
      return false;
    }, [&] { return QStringLiteral("a toast that the settings were not saved; the shell shows %1").arg(show(world.state(QStringLiteral("toasts")))); });
  });
  step(QStringLiteral("%1 stays on").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(entry(world, c[0]).value(QStringLiteral("enabled")).toBool() && instanceEnabled(world, fake(world).instanceId),
           QStringLiteral("%1 to stay on; the panel is %2").arg(c[0], show(panel(world))));
  });

  // Adding an instance.
  step(QStringLiteral("the user adds (?:a|another) %1 (?:provider|instance) labelled %1").arg(q), [](World& world, const Captures& c, const Table&) {
    startAdding(world, c[0], c[1]);
    finishAdding(world);
  });
  step(QStringLiteral("(?:an|the) instance %1 exists").arg(q), [](World& world, const Captures& c, const Table&) {
    openPanel(world);
    QJsonObject instances = fakeConfig(world.node).settings.value(QLatin1String("providerInstances")).toObject();
    instances.insert(c[0], QJsonObject{{QStringLiteral("driver"), c[0].section(QLatin1Char('_'), 0, 0)}, {QStringLiteral("enabled"), true}});
    saveElsewhere(world.node, QStringLiteral("providerInstances"), instances);
    world.waitFor([&] {
      for (const QVariant& row : panel(world).value(QStringLiteral("providers")).toList()) {
        if (row.toMap().value(QStringLiteral("instanceId")) == c[0]) return true;
      }
      return false;
    }, [&] { return QStringLiteral("%1 to be listed; the panel is %2").arg(c[0], show(panel(world))); });
  });
  step(QStringLiteral("an instance with the id %1 is listed").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      for (const QVariant& row : panel(world).value(QStringLiteral("providers")).toList()) {
        if (row.toMap().value(QStringLiteral("instanceId")) == c[0]) return !savedInstance(world, c[0]).isEmpty();
      }
      return false;
    }, [&] { return QStringLiteral("%1 to be saved and listed; the panel is %2").arg(c[0], show(panel(world))); });
    const QJsonObject saved = savedInstance(world, c[0]);
    expect(saved.value(QLatin1String("driver")) == QLatin1String("claudeAgent") && saved.value(QLatin1String("enabled")).toBool() &&
               saved.value(QLatin1String("displayName")) == QLatin1String("Work") && panel(world).value(QStringLiteral("wizard")).isNull(),
           QStringLiteral("the saved instance is %1, the wizard %2").arg(show(saved), show(panel(world).value(QStringLiteral("wizard")))));
  });
  step(QStringLiteral("the user is told the instance was added"), [](World& world, const Captures&, const Table&) {
    expectToast(world, QStringLiteral("Provider instance added"), QStringLiteral("Claude instance 'claudeAgent_work' was added."));
  });
  step(QStringLiteral("(?:the suggested instance id|its instance id) is %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(fake(world).suggestedId == c[0], QStringLiteral("the wizard suggested %1").arg(fake(world).suggestedId));
    world.waitFor([&] { return !savedInstance(world, c[0]).isEmpty(); },
                  [&] { return QStringLiteral("%1 to be saved; the settings are %2").arg(c[0], show(fakeConfig(world.node).settings)); });
  });
  step(QStringLiteral("the user (?:enters|sets) the instance id (?:to )?%1(?: and continues)?").arg(q), [](World& world, const Captures& c, const Table&) {
    startAdding(world, QStringLiteral("Codex"), std::nullopt);
    act(world, QStringLiteral("wizardInstanceId"), {{QStringLiteral("instanceId"), c[0]}});
    act(world, QStringLiteral("wizardStep"), {{QStringLiteral("step"), 2}});
  });
  step(QStringLiteral("the user stays on the identity step and is told %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return wizard(world).value(QStringLiteral("step")) == 1 && wizard(world).value(QStringLiteral("instanceIdError")) == c[0]; },
                  [&] { return QStringLiteral("the identity step to say \"%1\"; the wizard is %2").arg(c[0], show(wizard(world))); });
  });
  step(QStringLiteral("the user is on the configuration step of adding a provider"), [](World& world, const Captures&, const Table&) {
    startAdding(world, QStringLiteral("Claude"), QStringLiteral("Work"));
    act(world, QStringLiteral("wizardAccent"), {{QStringLiteral("color"), QStringLiteral("#22c55e")}});
    act(world, QStringLiteral("wizardStep"), {{QStringLiteral("step"), 2}});
    act(world, QStringLiteral("wizardField"), {{QStringLiteral("key"), QStringLiteral("homePath")}, {QStringLiteral("value"), QStringLiteral("~/.claude-work")}});
    world.waitFor([&] { return wizard(world).value(QStringLiteral("step")) == 2 &&
                               at(wizard(world), QStringLiteral("fields")).toList().value(1).toMap().value(QStringLiteral("value")) == QLatin1String("~/.claude-work"); },
                  [&] { return QStringLiteral("the configuration step; the wizard is %1").arg(show(wizard(world))); });
    QVariantMap choices = wizard(world);
    choices.remove(QStringLiteral("step"));
    fake(world).choices = show(choices);
  });
  step(QStringLiteral("the user goes back to choosing a driver"), [](World& world, const Captures&, const Table&) {
    act(world, QStringLiteral("wizardStep"), {{QStringLiteral("step"), 0}});
  });
  step(QStringLiteral("the choices already made are kept"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return wizard(world).value(QStringLiteral("step")) == 0; },
                  [&] { return QStringLiteral("the driver step; the wizard is %1").arg(show(wizard(world))); });
    QVariantMap now = wizard(world);
    now.remove(QStringLiteral("step"));
    expect(show(now) == fake(world).choices, QStringLiteral("the wizard held %1 and now %2").arg(fake(world).choices, show(now)));
  });
  step(QStringLiteral("the user adds a provider instance"), [](World& world, const Captures&, const Table&) {
    startAdding(world, QStringLiteral("Codex"), std::nullopt);
    finishAdding(world);
  });
  step(QStringLiteral("the user is told the provider instance could not be added"), [](World& world, const Captures&, const Table&) {
    expectToast(world, QStringLiteral("Could not add provider instance"), fakeConfig(world.node).refuseWrites);
    world.waitFor([&] { return !wizard(world).isEmpty() && !wizard(world).value(QStringLiteral("saving")).toBool(); },
                  [&] { return QStringLiteral("the wizard to stay open; it is %1").arg(show(wizard(world))); });
  });

  // Editing an instance.
  // The picker names an instance as the environment lists it (ComposerModel).
  step(QStringLiteral("the instance is shown as %1 in the model picker").arg(q), [](World& world, const Captures& c, const Table&) {
    const auto listed = [&] {
      for (const QJsonValue& value : fakeConfig(world.node).config.value(QLatin1String("providers")).toArray()) {
        if (value.toObject().value(QLatin1String("instanceId")) == fake(world).instanceId) return value.toObject().value(QLatin1String("displayName")).toString();
      }
      return QString();
    };
    waitForEntry(world, c[0], [&](const QVariantMap& found) { return found.value(QStringLiteral("label")) == c[0] && listed() == c[0]; },
                 QStringLiteral("to be listed under its new name"));
  });
  step(QStringLiteral("the user adds the environment variable %1 and marks it sensitive").arg(q), [](World& world, const Captures& c, const Table&) {
    seedWork(world, QStringLiteral("Claude Work"));
    const QString id = fake(world).instanceId;
    act(world, QStringLiteral("addVariable"), {{QStringLiteral("instanceId"), id}});
    act(world, QStringLiteral("variable"), {{QStringLiteral("instanceId"), id}, {QStringLiteral("index"), 0}, {QStringLiteral("name"), c[0]}});
    act(world, QStringLiteral("variable"), {{QStringLiteral("instanceId"), id}, {QStringLiteral("index"), 0}, {QStringLiteral("sensitive"), true}});
    act(world, QStringLiteral("variable"), {{QStringLiteral("instanceId"), id}, {QStringLiteral("index"), 0}, {QStringLiteral("value"), QStringLiteral("sk-secret")}});
  });
  step(QStringLiteral("its value is stored as a secret"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      const QJsonArray environment = savedInstance(world, fake(world).instanceId).value(QLatin1String("environment")).toArray();
      return fakeConfig(world.node).secrets.value(fake(world).instanceId + QStringLiteral("/API_KEY")) == QLatin1String("sk-secret") &&
             environment.size() == 1 && environment.at(0).toObject().value(QLatin1String("value")).toString().isEmpty();
    }, [&] { return QStringLiteral("API_KEY to be sealed; the instance is %1").arg(show(savedInstance(world, fake(world).instanceId))); });
  });
  step(QStringLiteral("the page shows it as a stored secret that a new value replaces"), [](World& world, const Captures&, const Table&) {
    waitForEntry(world, QStringLiteral("Claude Work"), [](const QVariantMap& found) {
      const QVariantList rows = found.value(QStringLiteral("variables")).toList();
      return rows.size() == 1 && at(rows.first(), QStringLiteral("redacted")).toBool() && at(rows.first(), QStringLiteral("value")).toString().isEmpty() &&
             at(rows.first(), QStringLiteral("placeholder")) == QLatin1String("Stored secret, enter a new value to replace");
    }, QStringLiteral("to show a stored secret"));
  });
  step(QStringLiteral("the instance has the environment variable %1").arg(q), [](World& world, const Captures& c, const Table&) {
    seedWork(world, QStringLiteral("Claude Work"),
             {QJsonObject{{QStringLiteral("name"), c[0]}, {QStringLiteral("value"), QStringLiteral("sk-secret")}, {QStringLiteral("sensitive"), true}}});
    waitForEntry(world, QStringLiteral("Claude Work"), [](const QVariantMap& found) { return found.value(QStringLiteral("variables")).toList().size() == 1; },
                 QStringLiteral("to list its variable"));
  });
  step(QStringLiteral("the user removes %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantList rows = variables(world, QStringLiteral("Claude Work"));
    for (qsizetype i = 0; i < rows.size(); ++i) {
      if (at(rows.at(i), QStringLiteral("name")) != c[0]) continue;
      act(world, QStringLiteral("removeVariable"), {{QStringLiteral("instanceId"), fake(world).instanceId}, {QStringLiteral("index"), int(i)}});
      return;
    }
    expect(false, QStringLiteral("%1 to be listed; the rows are %2").arg(c[0], show(rows)));
  });
  step(QStringLiteral("the instance no longer sets %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      const QJsonObject saved = savedInstance(world, fake(world).instanceId);
      return !saved.isEmpty() && !saved.contains(QLatin1String("environment")) && variables(world, QStringLiteral("Claude Work")).isEmpty() &&
             !fakeConfig(world.node).secrets.contains(fake(world).instanceId + QLatin1Char('/') + c[0]);
    }, [&] { return QStringLiteral("%1 to be gone; the instance is %2").arg(c[0], show(savedInstance(world, fake(world).instanceId))); });
  });
  step(QStringLiteral("the user deletes the %1 instance").arg(q), [](World& world, const Captures& c, const Table&) {
    seedWork(world, c[0]);
    act(world, QStringLiteral("delete"), {{QStringLiteral("instanceId"), fake(world).instanceId}});
  });
  step(QStringLiteral("it is no longer listed"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      for (const QVariant& row : panel(world).value(QStringLiteral("providers")).toList()) {
        if (row.toMap().value(QStringLiteral("instanceId")) == fake(world).instanceId) return false;
      }
      return savedInstance(world, fake(world).instanceId).isEmpty();
    }, [&] { return QStringLiteral("%1 to be gone; the panel is %2").arg(fake(world).instanceId, show(panel(world))); });
  });
  step(QStringLiteral("cleaning up the instance's managed binary fails"), [](World& world, const Captures&, const Table&) {
    fake(world).uninstallRefusal = QStringLiteral("The agent's files are in use.");
  });
  step(QStringLiteral("the user deletes the instance"), [](World& world, const Captures&, const Table&) {
    const QJsonObject config{{QStringLiteral("agentId"), QStringLiteral("gemini")}};
    seedInstance(world, QStringLiteral("acpRegistry_gemini"),
                 {{QStringLiteral("driver"), QStringLiteral("acpRegistry")}, {QStringLiteral("displayName"), QStringLiteral("Gemini")},
                  {QStringLiteral("enabled"), true}, {QStringLiteral("config"), config}},
                 provider(QStringLiteral("acpRegistry_gemini"), QStringLiteral("acpRegistry"), QStringLiteral("Gemini")));
    act(world, QStringLiteral("delete"), {{QStringLiteral("instanceId"), fake(world).instanceId}});
  });
  step(QStringLiteral("the user is told the provider was deleted but managed files remain"), [](World& world, const Captures&, const Table&) {
    expectToast(world, QStringLiteral("Provider deleted, but managed files remain"), fake(world).uninstallRefusal);
    expect(fake(world).uninstalls == QStringList{QStringLiteral("gemini")} && savedInstance(world, fake(world).instanceId).isEmpty(),
           QStringLiteral("gemini to be deleted and cleaned up; cleaned up %1").arg(fake(world).uninstalls.join(QStringLiteral(", "))));
  });

  // Signing in and out.
  step(QStringLiteral("%1 can sign in from HAL-C2 and is signed out").arg(q), [](World& world, const Captures& c, const Table&) {
    openPanel(world);
    offer(world, gemini(QStringLiteral("unauthenticated")));
    waitForEntry(world, c[0], [](const QVariantMap& found) { return at(found, QStringLiteral("account.canSignIn")).toBool(); },
                 QStringLiteral("to offer signing in"));
  });
  step(QStringLiteral("(?:%1 is signed in from HAL-C2|the user is signed in to an ACP agent)").arg(q), [](World& world, const Captures&, const Table&) {
    openPanel(world);
    offer(world, gemini(QStringLiteral("authenticated")));
    waitForEntry(world, QStringLiteral("Gemini"), [](const QVariantMap& found) { return at(found, QStringLiteral("account.canSignOut")).toBool(); },
                 QStringLiteral("to offer signing out"));
  });
  step(QStringLiteral("the user signs in to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    dispatch(world, QStringLiteral("signIn"), c[0]);
  });
  step(QStringLiteral("the user is asked to finish signing in in the browser"), [](World& world, const Captures&, const Table&) {
    waitForEntry(world, QStringLiteral("Gemini"), [](const QVariantMap& found) {
      return at(found, QStringLiteral("account.description")) == QLatin1String("Finish signing in in your browser.") &&
             at(found, QStringLiteral("account.url")) == kSignInUrl && at(found, QStringLiteral("account.canCancel")).toBool();
    }, QStringLiteral("to wait on the browser"));
  });
  step(QStringLiteral("the user opens the sign-in page"), [](World& world, const Captures&, const Table&) {
    dispatch(world, QStringLiteral("openSignIn"), QStringLiteral("Gemini"));
  });
  step(QStringLiteral("the provider's sign-in page opens in the browser"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.openedUrls.contains(QUrl(kSignInUrl)); },
                  [&] { return QStringLiteral("%1 to open; opened %2").arg(kSignInUrl, QUrl::toStringList(world.openedUrls).join(QStringLiteral(", "))); });
  });
  step(QStringLiteral("the user cancels the sign-in"), [](World& world, const Captures&, const Table&) {
    waitForEntry(world, QStringLiteral("Gemini"), [](const QVariantMap& found) { return at(found, QStringLiteral("account.canCancel")).toBool(); },
                 QStringLiteral("to offer cancelling"));
    dispatch(world, QStringLiteral("cancelSignIn"), QStringLiteral("Gemini"));
  });
  step(QStringLiteral("the sign-in is cancelled on the environment"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return fake(world).cancels == QStringList{QStringLiteral("flow-1")}; },
                  [&] { return QStringLiteral("the flow to be cancelled; cancelled %1").arg(fake(world).cancels.join(QStringLiteral(", "))); });
  });
  step(QStringLiteral("the user can retry signing in to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForEntry(world, c[0], [](const QVariantMap& found) {
      return at(found, QStringLiteral("account.canSignIn")).toBool() && at(found, QStringLiteral("account.signInLabel")) == QLatin1String("Retry sign-in");
    }, QStringLiteral("to offer another sign-in"));
  });
  step(QStringLiteral("the sign-in fails with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForEntry(world, QStringLiteral("Gemini"), [](const QVariantMap& found) { return at(found, QStringLiteral("account.canCancel")).toBool(); },
                 QStringLiteral("to be signing in"));
    sendAuth(world.node, QStringLiteral("gemini"),
             {{QStringLiteral("phase"), QStringLiteral("failed")}, {QStringLiteral("flowId"), QStringLiteral("flow-1")}, {QStringLiteral("message"), c[0]}});
  });
  step(QStringLiteral("the user is told why the sign-in failed: %1").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForEntry(world, QStringLiteral("Gemini"), [&](const QVariantMap& found) { return at(found, QStringLiteral("account.error")) == c[0]; },
                 QStringLiteral("to say ") + c[0]);
  });
  step(QStringLiteral("the user signs out of %1 and declines").arg(q), [](World& world, const Captures& c, const Table&) {
    dispatch(world, QStringLiteral("signOut"), c[0]);
    answer(world, false);
  });
  step(QStringLiteral("the user signs out and confirms"), [](World& world, const Captures&, const Table&) {
    dispatch(world, QStringLiteral("signOut"), QStringLiteral("Gemini"));
    answer(world, true);
  });
  step(QStringLiteral("%1 is still signed in").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(fake(world).logouts.isEmpty() && at(entry(world, c[0]), QStringLiteral("account.canSignOut")).toBool(),
           QStringLiteral("%1 to stay signed in; signed out %2, the panel is %3").arg(c[0], fake(world).logouts.join(QStringLiteral(", ")), show(panel(world))));
  });
  // The node stops the threads that share the sign-in as it signs out.
  step(QStringLiteral("running threads sharing that sign-in stop"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return fake(world).logouts == QStringList{QStringLiteral("gemini")}; },
                  [&] { return QStringLiteral("Gemini to be signed out; signed out %1").arg(fake(world).logouts.join(QStringLiteral(", "))); });
  });
  step(QStringLiteral("thread history is kept"), [](World& world, const Captures&, const Table&) {
    world.sync();
    for (const QJsonObject& command : world.node.commands) {
      expect(!command.value(QLatin1String("type")).toString().contains(QLatin1String("delete")),
             QStringLiteral("no thread to be deleted; the node has %1").arg(world.describeCommands()));
    }
  });
  step(QStringLiteral("%1 is linked and its %1 can sign in from HAL-C2").arg(q), [](World& world, const Captures& c, const Table&) {
    linkEnvironment(world, c[0], {gemini(QStringLiteral("unauthenticated"))});
  });
  step(QStringLiteral("the user is told to sign in from a client paired with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForEntry(world, QStringLiteral("Gemini"), [&](const QVariantMap& found) {
      return at(found, QStringLiteral("account.description")) == QStringLiteral("Sign in from a client paired with %1.").arg(c[0]) &&
             !at(found, QStringLiteral("account.canSignIn")).toBool();
    }, QStringLiteral("to be signed in from elsewhere"));
    expect(world.node.subscribers(QStringLiteral("providerAuth")).isEmpty(), QStringLiteral("no sign-in to be followed"));
  });

  // The health check interval. The environment starts on the "performance"
  // preset (a minute), so each interval below is a change.
  step(QStringLiteral("the user sets the provider health check interval to (\\d+) seconds"), [](World& world, const Captures& c, const Table&) {
    saveElsewhere(world.node, QStringLiteral("backgroundActivity"),
                  QJsonObject{{QStringLiteral("schemaVersion"), 1}, {QStringLiteral("profile"), QStringLiteral("performance")}});
    world.waitFor([&] { return at(panel(world), QStringLiteral("health.seconds")) == 60; },
                  [&] { return QStringLiteral("the interval to show a minute; the panel is %1").arg(show(panel(world))); });
    world.bridge().dispatch(QStringLiteral("providerSettings.healthInterval"), QVariantMap{{QStringLiteral("seconds"), c[0].toInt()}});
  });
  step(QStringLiteral("providers are refreshed in the background (every five minutes|never)"), [](World& world, const Captures& c, const Table&) {
    const int seconds = c[0] == QLatin1String("never") ? 0 : 300;
    // What the node reads (HalC2.BackgroundPolicy.settings): a custom profile's override.
    const auto saved = [&] {
      const QJsonObject activity = fakeConfig(world.node).settings.value(QLatin1String("backgroundActivity")).toObject();
      return activity.value(QLatin1String("profile")) == QLatin1String("custom") &&
             activity.value(QLatin1String("baseProfile")) == QLatin1String("performance") &&
             activity.value(QLatin1String("overrides")).toObject().value(QLatin1String("providerHealthRefreshInterval")).toInt(-1) == seconds * 1000;
    };
    world.waitFor([&] { return saved() && at(panel(world), QStringLiteral("health.seconds")) == seconds; },
                  [&] { return QStringLiteral("a %1 s interval to be saved; the settings are %2, the panel %3")
                            .arg(seconds).arg(show(fakeConfig(world.node).settings.value(QLatin1String("backgroundActivity"))), show(panel(world))); });
  });

  // Updates.
  step(QStringLiteral("%1 is behind its latest release").arg(q), [](World& world, const Captures& c, const Table&) {
    offer(world, provider(QStringLiteral("codex"), QStringLiteral("codex"), c[0],
                          {{QStringLiteral("version"), QStringLiteral("0.50.0")},
                           {QStringLiteral("versionAdvisory"), QJsonObject{{QStringLiteral("status"), QStringLiteral("behind_latest")},
                                                                           {QStringLiteral("currentVersion"), QStringLiteral("0.50.0")},
                                                                           {QStringLiteral("latestVersion"), QStringLiteral("0.51.0")},
                                                                           {QStringLiteral("updateCommand"), kUpdateCommand},
                                                                           {QStringLiteral("canUpdate"), true}}}}));
  });
  step(QStringLiteral("the update command for %1 cannot be started here").arg(q), [](World& world, const Captures& c, const Table&) {
    offer(world, provider(QStringLiteral("codex"), QStringLiteral("codex"), c[0],
                          {{QStringLiteral("versionAdvisory"), QJsonObject{{QStringLiteral("status"), QStringLiteral("behind_latest")},
                                                                           {QStringLiteral("latestVersion"), QStringLiteral("0.51.0")},
                                                                           {QStringLiteral("updateCommand"), kUpdateCommand},
                                                                           {QStringLiteral("canUpdate"), false}}}}));
    waitForEntry(world, c[0], [](const QVariantMap& found) { return !found.value(QStringLiteral("canUpdate")).toBool(); },
                 QStringLiteral("to not update itself"));
  });
  step(QStringLiteral("the installed %1 is (of limited support|unsupported|known to be broken) for this HAL-C2 release").arg(q),
       [](World& world, const Captures& c, const Table&) {
         const QString status = c[1] == QLatin1String("of limited support") ? QStringLiteral("graceful")
                                : c[1] == QLatin1String("unsupported")      ? QStringLiteral("unsupported")
                                                                            : QStringLiteral("broken");
         offer(world, provider(QStringLiteral("opencode"), QStringLiteral("opencode"), c[0],
                               {{QStringLiteral("version"), QStringLiteral("1.15.0")},
                                {QStringLiteral("compatibilityAdvisory"), QJsonObject{{QStringLiteral("status"), status},
                                                                                      {QStringLiteral("recommendedVersion"), QStringLiteral("1.14.19")}}}}));
       });
  step(QStringLiteral("the user opens the version details of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForEntry(world, c[0], [](const QVariantMap& found) { return found.value(QStringLiteral("advisory")).typeId() == QMetaType::QVariantMap; },
                 QStringLiteral("to have version details"));
  });
  step(QStringLiteral("the user is told an update is available with the latest version"), [](World& world, const Captures&, const Table&) {
    const QVariantMap advisory = entry(world, QStringLiteral("Codex")).value(QStringLiteral("advisory")).toMap();
    expect(advisory.value(QStringLiteral("title")) == QLatin1String("Update available") &&
               advisory.value(QStringLiteral("detail")) == QLatin1String("Update available: install v0.51.0."),
           QStringLiteral("the advisory is %1").arg(show(advisory)));
  });
  step(QStringLiteral("the user can update now or copy the update command"), [](World& world, const Captures&, const Table&) {
    const QVariantMap codex = entry(world, QStringLiteral("Codex"));
    expect(codex.value(QStringLiteral("canUpdate")).toBool() && at(codex, QStringLiteral("advisory.updateCommand")) == kUpdateCommand,
           QStringLiteral("Codex is %1").arg(show(codex)));
  });
  step(QStringLiteral("the user is warned %1 with the version to use for full support").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap advisory = entry(world, QStringLiteral("OpenCode")).value(QStringLiteral("advisory")).toMap();
    expect(advisory.value(QStringLiteral("title")) == c[0] && advisory.value(QStringLiteral("detail")) == QLatin1String("Use v1.14.19 for full support."),
           QStringLiteral("the advisory is %1").arg(show(advisory)));
  });
  step(QStringLiteral("the user copies the update command"), [](World& world, const Captures&, const Table&) {
    dispatch(world, QStringLiteral("copyUpdateCommand"), QStringLiteral("Codex"));
  });
  step(QStringLiteral("the command is on the clipboard"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.clipboard == kUpdateCommand; },
                  [&] { return QStringLiteral("the clipboard holds \"%1\"").arg(world.clipboard); });
  });
  step(QStringLiteral("the user is told to run it in a terminal when ready"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      for (const QVariant& toast : at(world.state(QStringLiteral("toasts")), QStringLiteral("items")).toList()) {
        if (toast.toMap().value(QStringLiteral("description")) == QLatin1String("Run it in a terminal when ready.")) return true;
      }
      return false;
    }, [&] { return QStringLiteral("a toast to run it in a terminal; the shell shows %1").arg(show(world.state(QStringLiteral("toasts")))); });
  });
  step(QStringLiteral("updating %1 fails with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    fake(world).updateRefusal = c[1];
  });
  step(QStringLiteral("the user updates %1").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForEntry(world, c[0], [](const QVariantMap& found) { return found.value(QStringLiteral("canUpdate")).toBool(); },
                 QStringLiteral("to offer an update"));
    dispatch(world, QStringLiteral("update"), c[0]);
  });
  step(QStringLiteral("%1 is shown updating").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForEntry(world, c[0], [&](const QVariantMap& found) {
      return found.value(QStringLiteral("updating")).toBool() && fake(world).updates.size() == 1 &&
             fake(world).updates.first().payload.value(QLatin1String("provider")) == QLatin1String("codex");
    }, QStringLiteral("to be updating"));
  });
  step(QStringLiteral("the update finishes"), [](World& world, const Captures&, const Table&) {
    world.node.reply(fake(world).updates.first(), QJsonObject{});
  });
  step(QStringLiteral("%1 is no longer shown updating").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForEntry(world, c[0], [](const QVariantMap& found) { return !found.value(QStringLiteral("updating")).toBool(); },
                 QStringLiteral("to be done updating"));
  });
  step(QStringLiteral("the user is told %1 could not be updated").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      for (const QVariant& toast : at(world.state(QStringLiteral("toasts")), QStringLiteral("items")).toList()) {
        if (toast.toMap().value(QStringLiteral("title")) == QStringLiteral("Could not update %1").arg(c[0]) &&
            toast.toMap().value(QStringLiteral("description")) == fake(world).updateRefusal) {
          return true;
        }
      }
      return false;
    }, [&] { return QStringLiteral("a toast that %1 was not updated; the shell shows %2").arg(c[0], show(world.state(QStringLiteral("toasts")))); });
  });
});

}  // namespace

// "The user renames <instance> to <name>" in the Providers settings
// (WorkspaceSteps.cpp shares the words for thread titles).
void renameProviderInstance(World& world, const QString& from, const QString& to) {
  seedWork(world, from);
  act(world, QStringLiteral("rename"), {{QStringLiteral("instanceId"), fake(world).instanceId}, {QStringLiteral("name"), to}});
}
