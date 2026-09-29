// The Providers settings section on the desktop (ProviderSettingsController):
// the @desktop scenarios of features/settings/providers-panel.feature and
// the desktop's side of providers/provider-setup.feature. The node's own
// environment plays "Laptop", this machine; others are linked environments.

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>

#include "FakeConfig.h"
#include "Harness.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "Stream.h"
#include "World.h"

namespace {

// The node's side of sign-in (HalC2.ProviderAuth) and updates.
struct FakeProviders {
  QHash<QString, QJsonObject> auth;  // each instance's ProviderAuthState
  QStringList starts, cancels, logouts;
  QStringList methods;  // the sign-in method each start asked for, "" for the default
  QList<QJsonObject> responses;  // provider.auth.respond payloads
  QList<QJsonObject> completes;  // provider.auth.complete payloads
  bool terminalGone = false;
  QString credential;  // the credential the agent last asked for
  QList<FakeNode::Rpc> updates;
  QString updateRefusal;
  int followedBefore = 0;
  QString instanceId;  // the instance the scenario last acted on
  QString suggestedId;  // the id the add-provider wizard last suggested
  QString choices;  // what the wizard held before the user went back
  QStringList uninstalls;  // agents whose managed binary was cleaned up
  QString uninstallRefusal;
  qsizetype writesBefore = 0;  // the settings writes made before a custom model's save
  QStringList searches, prepares;  // ACP Registry queries and agents prepared
  // The ACP agent's own sessions and model providers (HalC2.Acp.Sessions).
  QJsonArray acpSessions, acpProviders;
  QList<QJsonObject> acpImports, acpSets;
  QStringList acpDeletes, acpDisables, acpLogouts;
  // Calls the scenario answers itself, one at a time, while held.
  bool holdPrepares = false, holdStarts = false;
  QList<FakeNode::Rpc> heldPrepares, heldStarts;
};


// The ACP Registry's compatible agents, as server.searchAcpRegistry lists them.
QJsonArray registryAgents() {
  const auto agent = [](const QString& id, const QString& name, const QString& description) {
    return QJsonObject{{QStringLiteral("id"), id},
                       {QStringLiteral("name"), name},
                       {QStringLiteral("version"), QStringLiteral("1.2.3")},
                       {QStringLiteral("description"), description},
                       {QStringLiteral("distribution"), QStringLiteral("npx")},
                       {QStringLiteral("icon"), QStringLiteral("https://cdn.agentclientprotocol.com/%1.svg").arg(id)}};
  };
  return {agent(QStringLiteral("gemini-cli"), QStringLiteral("Gemini CLI"), QStringLiteral("Google's Gemini agent")),
          agent(QStringLiteral("gemini-lite"), QStringLiteral("Gemini Lite"), QStringLiteral("A smaller Gemini")),
          agent(QStringLiteral("goose"), QStringLiteral("Goose"), QStringLiteral("An open agent"))};
}

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
    node.part<FakeProviders>().methods.append(rpc.payload.value(QLatin1String("methodId")).toString());
    if (node.part<FakeProviders>().holdStarts) {
      node.part<FakeProviders>().heldStarts.append(rpc);
      return;
    }
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
  node.onRpc(QStringLiteral("provider.auth.respond"), [&node](const FakeNode::Rpc& rpc) {
    FakeProviders& fake = node.part<FakeProviders>();
    const bool terminal = rpc.payload.value(QLatin1String("response")).toObject().value(QLatin1String("type")) == QLatin1String("terminal");
    if (terminal && fake.terminalGone) {
      node.refuse(rpc, QStringLiteral("No sign-in is waiting for that input."));
      return;
    }
    fake.responses.append(rpc.payload);
    node.reply(rpc, QJsonObject{});
  });
  node.onRpc(QStringLiteral("provider.auth.complete"), [&node](const FakeNode::Rpc& rpc) {
    node.part<FakeProviders>().completes.append(rpc.payload);
    node.reply(rpc, QJsonObject{});
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
  node.onRpc(QStringLiteral("server.searchAcpRegistry"), [&node](const FakeNode::Rpc& rpc) {
    const QString query = rpc.payload.value(QLatin1String("query")).toString();
    node.part<FakeProviders>().searches.append(query);
    QJsonArray agents;
    for (const QJsonValue& agent : registryAgents()) {
      if (agent.toObject().value(QLatin1String("id")).toString().contains(query, Qt::CaseInsensitive)) agents.append(agent);
    }
    node.reply(rpc, QJsonObject{{QStringLiteral("agents"), agents}});
  });
  node.onRpc(QStringLiteral("server.prepareAcpRegistryAgent"), [&node](const FakeNode::Rpc& rpc) {
    const QString agentId = rpc.payload.value(QLatin1String("agentId")).toString();
    node.part<FakeProviders>().prepares.append(agentId);
    if (node.part<FakeProviders>().holdPrepares) {
      node.part<FakeProviders>().heldPrepares.append(rpc);
      return;
    }
    node.reply(rpc, QJsonObject{{QStringLiteral("agentId"), agentId},
                                {QStringLiteral("version"), QStringLiteral("1.2.3")},
                                {QStringLiteral("distribution"), QStringLiteral("npx")},
                                {QStringLiteral("prepared"), true}});
  });
  node.onRpc(QStringLiteral("server.listAcpRegistrySessions"), [&node](const FakeNode::Rpc& rpc) {
    node.reply(rpc, QJsonObject{{QStringLiteral("sessions"), node.part<FakeProviders>().acpSessions},
                                {QStringLiteral("nextCursor"), QJsonValue::Null},
                                {QStringLiteral("canLoad"), true},
                                {QStringLiteral("canResume"), false},
                                {QStringLiteral("canDelete"), true}});
  });
  node.onRpc(QStringLiteral("server.importAcpRegistrySession"), [&node](const FakeNode::Rpc& rpc) {
    node.part<FakeProviders>().acpImports.append(rpc.payload);
    node.reply(rpc, QJsonObject{{QStringLiteral("threadId"), QStringLiteral("thread-imported")}, {QStringLiteral("imported"), true}});
  });
  node.onRpc(QStringLiteral("server.deleteAcpRegistrySession"), [&node](const FakeNode::Rpc& rpc) {
    FakeProviders& fake = node.part<FakeProviders>();
    const QString sessionId = rpc.payload.value(QLatin1String("sessionId")).toString();
    fake.acpDeletes.append(sessionId);
    for (qsizetype i = 0; i < fake.acpSessions.size(); ++i) {
      if (fake.acpSessions.at(i).toObject().value(QLatin1String("sessionId")) == sessionId) fake.acpSessions.removeAt(i--);
    }
    node.reply(rpc, QJsonObject{{QStringLiteral("deleted"), true}});
  });
  node.onRpc(QStringLiteral("server.listAcpRegistryProviders"), [&node](const FakeNode::Rpc& rpc) {
    node.reply(rpc, QJsonObject{{QStringLiteral("providers"), node.part<FakeProviders>().acpProviders}});
  });
  const auto current = [&node](const QString& providerId, const QJsonValue& value) {
    QJsonArray& providers = node.part<FakeProviders>().acpProviders;
    for (qsizetype i = 0; i < providers.size(); ++i) {
      QJsonObject entry = providers.at(i).toObject();
      if (entry.value(QLatin1String("providerId")) != providerId) continue;
      entry.insert(QStringLiteral("current"), value);
      providers.replace(i, entry);
    }
  };
  node.onRpc(QStringLiteral("server.setAcpRegistryProvider"), [&node, current](const FakeNode::Rpc& rpc) {
    node.part<FakeProviders>().acpSets.append(rpc.payload);
    current(rpc.payload.value(QLatin1String("providerId")).toString(),
            QJsonObject{{QStringLiteral("apiType"), rpc.payload.value(QLatin1String("apiType"))},
                        {QStringLiteral("baseUrl"), rpc.payload.value(QLatin1String("baseUrl"))}});
    node.reply(rpc, QJsonObject{{QStringLiteral("configured"), true}});
  });
  node.onRpc(QStringLiteral("server.disableAcpRegistryProvider"), [&node, current](const FakeNode::Rpc& rpc) {
    node.part<FakeProviders>().acpDisables.append(rpc.payload.value(QLatin1String("providerId")).toString());
    current(rpc.payload.value(QLatin1String("providerId")).toString(), QJsonValue::Null);
    node.reply(rpc, QJsonObject{{QStringLiteral("disabled"), true}});
  });
  node.onRpc(QStringLiteral("server.logoutAcpRegistry"), [&node](const FakeNode::Rpc& rpc) {
    node.part<FakeProviders>().acpLogouts.append(rpc.payload.value(QLatin1String("instanceId")).toString());
    node.reply(rpc, QJsonObject{{QStringLiteral("loggedOut"), true}});
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

// A sign-in method named `name`, its id the name in kebab case.
QJsonObject signInMethod(const QString& name) {
  return {{QStringLiteral("id"), name.toLower().replace(QLatin1Char(' '), QLatin1Char('-'))}, {QStringLiteral("name"), name}};
}

// An ACP agent that signs in from HAL-C2.
QJsonObject gemini(const QString& authStatus) {
  QJsonObject auth{{QStringLiteral("status"), authStatus}};
  if (authStatus == QLatin1String("authenticated")) auth.insert(QStringLiteral("email"), QStringLiteral("sam@example.com"));
  return provider(QStringLiteral("gemini"), QStringLiteral("acpRegistry"), QStringLiteral("Gemini"),
                  {{QStringLiteral("auth"), auth},
                   {QStringLiteral("setup"), QJsonObject{{QStringLiteral("canAuthenticate"), true}}}});
}

// "Gemini" signed in, managing its own sessions and model providers.
QJsonObject acpAgent(const QString& authStatus = QStringLiteral("authenticated")) {
  return provider(QStringLiteral("gemini"), QStringLiteral("acpRegistry"), QStringLiteral("Gemini"),
                  {{QStringLiteral("auth"), QJsonObject{{QStringLiteral("status"), authStatus}, {QStringLiteral("canLogout"), true}}},
                   {QStringLiteral("setup"), QJsonObject{{QStringLiteral("canAuthenticate"), false}}},
                   {QStringLiteral("nativeSessions"), QJsonObject{{QStringLiteral("canList"), true},
                                                                  {QStringLiteral("canLoad"), true},
                                                                  {QStringLiteral("canResume"), false},
                                                                  {QStringLiteral("canDelete"), true}}},
                   {QStringLiteral("configurableProviders"), true}});
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
  step(QStringLiteral("the user's session may view but not operate %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.node.linkScopes.insert(c[0], {QStringLiteral("orchestration:read")});
    linkEnvironment(world, c[0], {provider(QStringLiteral("codex"), QStringLiteral("codex"), QStringLiteral("Codex"))});
  });
  step(QStringLiteral("the providers are shown read-only"), [](World& world, const Captures&, const Table&) {
    waitForEntry(world, QStringLiteral("Codex"), [&](const QVariantMap&) { return panel(world).value(QStringLiteral("readOnly")).toBool(); },
                 QStringLiteral("to be listed read-only"));
    // Nothing on it takes a change.
    const qsizetype writes = fakeConfig(world.node).writes.size();
    act(world, QStringLiteral("wizardOpen"));
    act(world, QStringLiteral("enable"), {{QStringLiteral("instanceId"), QStringLiteral("codex")}, {QStringLiteral("enabled"), false}});
    act(world, QStringLiteral("healthInterval"), {{QStringLiteral("seconds"), 60}});
    expect(panel(world).value(QStringLiteral("wizard")).isNull() && fakeConfig(world.node).writes.size() == writes &&
               !entry(world, QStringLiteral("Codex")).value(QStringLiteral("busy")).toBool(),
           QStringLiteral("no change to be made; the panel is %1").arg(show(panel(world))));
  });
  step(QStringLiteral("the user is told this session can view the providers but not change their settings"),
       [](World& world, const Captures&, const Table&) {
    const QString said = panel(world).value(QStringLiteral("readOnlyDescription")).toString();
    expect(said == QLatin1String("This session can view Build box's providers but can't change their settings."),
           QStringLiteral("the read-only note; it says \"%1\"").arg(said));
  });
  // Usage-limit hubs (settings/usage-limit-sources.feature).
  step(QStringLiteral("the user adds a hub with a URL and management key but no label"), [](World& world, const Captures&, const Table&) {
    openPanel(world);
    world.waitFor([&] { return panel(world).value(QStringLiteral("hubs")).typeId() == QMetaType::QVariantList; },
                  [&] { return QStringLiteral("the hubs to be listed; the panel is %1").arg(show(panel(world))); });
    act(world, QStringLiteral("addHub"), {{QStringLiteral("url"), QStringLiteral("https://hub.example.ts.net:8318")},
                                          {QStringLiteral("key"), QStringLiteral("hub-key")},
                                          {QStringLiteral("label"), QString()}});
  });
  step(QStringLiteral("the hub is listed under the hub's host name"), [](World& world, const Captures&, const Table&) {
    const QString id = QStringLiteral("cliproxy-hub.example.ts.net-8318");
    world.waitFor([&] {
      for (const QVariant& hub : panel(world).value(QStringLiteral("hubs")).toList()) {
        if (hub.toMap().value(QStringLiteral("id")) == id) return hub.toMap().value(QStringLiteral("label")) == QLatin1String("hub.example.ts.net:8318");
      }
      return false;
    }, [&] { return QStringLiteral("the hub listed by its host; the panel is %1").arg(show(panel(world))); });
    // The key went to the node's secret store, not the document.
    const FakeConfig& config = fakeConfig(world.node);
    expect(config.secrets.value(QStringLiteral("hub/") + id) == QLatin1String("hub-key") &&
               config.settings.value(QLatin1String("usageLimitSources")).toObject().value(id).toObject()
                       .value(QLatin1String("managementKey")) == QStringLiteral("••••••"),
           QStringLiteral("the key sealed on the node; the settings are %1").arg(QString::fromUtf8(QJsonDocument(config.settings).toJson(QJsonDocument::Compact))));
  });
  step(QStringLiteral("the user fills in a URL but no management key"), [](World& world, const Captures&, const Table&) {
    openPanel(world);
    act(world, QStringLiteral("addHub"), {{QStringLiteral("url"), QStringLiteral("https://hub.example")}, {QStringLiteral("key"), QString()}});
  });
  step(QStringLiteral("the user cannot add the hub"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(fakeConfig(world.node).writes.isEmpty(), QStringLiteral("no hub saved"));
  });
  step(QStringLiteral("the user removes %1 and confirms").arg(q), [](World& world, const Captures& c, const Table&) {
    openPanel(world);
    QString id;
    world.waitFor([&] {
      for (const QVariant& hub : panel(world).value(QStringLiteral("hubs")).toList()) {
        if (hub.toMap().value(QStringLiteral("label")) == c[0]) id = hub.toMap().value(QStringLiteral("id")).toString();
      }
      return !id.isEmpty();
    }, [&] { return QStringLiteral("%1 to be listed; the panel is %2").arg(c[0], show(panel(world))); });
    act(world, QStringLiteral("removeHub"), {{QStringLiteral("id"), id}});
  });
  step(QStringLiteral("its key is deleted from the node"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !fakeConfig(world.node).secrets.contains(QStringLiteral("hub/team-hub")); },
                  QStringLiteral("the hub's key to be deleted"));
    expect(!fakeConfig(world.node).settings.value(QLatin1String("usageLimitSources")).toObject().contains(QStringLiteral("team-hub")),
           QStringLiteral("the hub gone from the settings"));
  });
  // Nothing is sent to the hub: the node only saved its settings once.
  step(QStringLiteral("the hub itself is untouched"), [](World& world, const Captures&, const Table&) {
    expect(fakeConfig(world.node).writes.size() == 1, QStringLiteral("one settings write; there were %1").arg(fakeConfig(world.node).writes.size()));
  });
  step(QStringLiteral("the user is connected with read-only access"), [](World& world, const Captures&, const Table&) {
    world.node.linkScopes.insert(QStringLiteral("Build box"), {QStringLiteral("orchestration:read")});
    documentOf(world.node, QStringLiteral("Build box")).settings.insert(QStringLiteral("usageLimitSources"), QJsonObject{});
    linkEnvironment(world, QStringLiteral("Build box"), {provider(QStringLiteral("codex"), QStringLiteral("codex"), QStringLiteral("Codex"))});
  });
  step(QStringLiteral("the user opens usage providers"), [](World& world, const Captures&, const Table&) {
    showEnvironment(world, QStringLiteral("Build box"));
  });
  step(QStringLiteral("the user cannot add a hub"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return panel(world).value(QStringLiteral("readOnly")).toBool(); },
                  [&] { return QStringLiteral("the providers read-only; the panel is %1").arg(show(panel(world))); });
    act(world, QStringLiteral("addHub"), {{QStringLiteral("url"), QStringLiteral("https://hub.example")}, {QStringLiteral("key"), QStringLiteral("hub-key")}});
    world.sync();
    expect(documentOf(world.node, QStringLiteral("Build box")).version == 0 && fakeConfig(world.node).writes.isEmpty(),
           QStringLiteral("no hub saved on Build box"));
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
  step(QStringLiteral("the instance keeps %1 as a stored secret").arg(q), [](World& world, const Captures& c, const Table&) {
    fakeConfig(world.node).secrets.insert(QStringLiteral("claudeAgent_work/") + c[0], QStringLiteral("sk-secret"));
    seedWork(world, QStringLiteral("Claude Work"),
             {QJsonObject{{QStringLiteral("name"), c[0]}, {QStringLiteral("value"), QString()}, {QStringLiteral("sensitive"), true},
                          {QStringLiteral("valueRedacted"), true}}});
    waitForEntry(world, QStringLiteral("Claude Work"), [](const QVariantMap& found) {
      const QVariantList rows = found.value(QStringLiteral("variables")).toList();
      return rows.size() == 1 && at(rows.first(), QStringLiteral("redacted")).toBool();
    }, QStringLiteral("to show its stored secret"));
  });
  step(QStringLiteral("the user renames the variable %1 to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantList rows = variables(world, QStringLiteral("Claude Work"));
    for (qsizetype i = 0; i < rows.size(); ++i) {
      if (at(rows.at(i), QStringLiteral("name")) != c[0]) continue;
      act(world, QStringLiteral("variable"), {{QStringLiteral("instanceId"), fake(world).instanceId}, {QStringLiteral("index"), int(i)}, {QStringLiteral("name"), c[1]}});
      return;
    }
    expect(false, QStringLiteral("%1 to be listed; the rows are %2").arg(c[0], show(rows)));
  });
  step(QStringLiteral("%1 asks for a new value instead of showing a stored secret").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForEntry(world, QStringLiteral("Claude Work"), [&](const QVariantMap& found) {
      const QVariantList rows = found.value(QStringLiteral("variables")).toList();
      return rows.size() == 1 && at(rows.first(), QStringLiteral("name")) == c[0] && !at(rows.first(), QStringLiteral("redacted")).toBool() &&
             at(rows.first(), QStringLiteral("placeholder")) == QLatin1String("value");
    }, QStringLiteral("to ask for a value for ") + c[0]);
    world.waitFor([&] {
      const QJsonArray environment = savedInstance(world, fake(world).instanceId).value(QLatin1String("environment")).toArray();
      return environment.size() == 1 && environment.at(0).toObject().value(QLatin1String("name")) == c[0] &&
             !environment.at(0).toObject().contains(QLatin1String("valueRedacted"));
    }, [&] { return QStringLiteral("%1 to be saved without a secret; the instance is %2").arg(c[0], show(savedInstance(world, fake(world).instanceId))); });
  });
  step(QStringLiteral("the secret stored for %1 is forgotten").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return !fakeConfig(world.node).secrets.contains(fake(world).instanceId + QLatin1Char('/') + c[0]); },
                  [&] { return QStringLiteral("the secret of %1 to be deleted").arg(c[0]); });
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
  // A sign-in answered after the user switched environments and back.
  step(QStringLiteral("the user signs in to %1 while the environment is slow to answer").arg(q), [](World& world, const Captures& c, const Table&) {
    fake(world).holdStarts = true;
    dispatch(world, QStringLiteral("signIn"), c[0]);
    world.waitFor([&] { return fake(world).heldStarts.size() == 1; }, QStringLiteral("the sign-in to be started"));
  });
  step(QStringLiteral("the user switches to another environment and back and signs in to %1 again").arg(q), [](World& world, const Captures& c, const Table&) {
    linkEnvironment(world, QStringLiteral("Studio"), QJsonArray{});
    showEnvironment(world, QStringLiteral("Studio"));
    showEnvironment(world, world.node.environmentId);
    waitForEntry(world, c[0], [](const QVariantMap& found) { return at(found, QStringLiteral("account.canSignIn")).toBool(); },
                 QStringLiteral("to offer signing in again"));
    dispatch(world, QStringLiteral("signIn"), c[0]);
    world.waitFor([&] { return fake(world).heldStarts.size() == 2; }, QStringLiteral("the second sign-in to be started"));
  });
  step(QStringLiteral("the first sign-in is answered"), [](World& world, const Captures&, const Table&) {
    world.node.reply(fake(world).heldStarts.takeFirst(), QJsonObject{});
    world.sync();
  });
  step(QStringLiteral("the second sign-in is still waiting on the environment"), [](World& world, const Captures&, const Table&) {
    const QVariantMap found = entry(world, QStringLiteral("Gemini"));
    expect(!at(found, QStringLiteral("account.canSignIn")).toBool(),
           QStringLiteral("the second sign-in to stay busy; Gemini is %1").arg(show(found)));
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
  step(QStringLiteral("%1 offers the sign-in methods %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    openPanel(world);
    fake(world).auth.insert(QStringLiteral("gemini"),
                            authState(QStringLiteral("gemini"),
                                      {{QStringLiteral("methods"), QJsonArray{signInMethod(c[1]), signInMethod(c[2])}}}));
    offer(world, gemini(QStringLiteral("unauthenticated")));
    waitForEntry(world, c[0], [](const QVariantMap& found) {
      return at(found, QStringLiteral("account.canSignIn")).toBool() && at(found, QStringLiteral("account.methods")).toList().size() == 2;
    }, QStringLiteral("to offer two sign-in methods"));
  });
  step(QStringLiteral("the user chooses %1 and signs in to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QString methodId;
    for (const QVariant& method : at(entry(world, c[1]), QStringLiteral("account.methods")).toList()) {
      if (method.toMap().value(QStringLiteral("name")) == c[0]) methodId = method.toMap().value(QStringLiteral("id")).toString();
    }
    expect(!methodId.isEmpty(), QStringLiteral("%1 to be offered; the panel is %2").arg(c[0], show(panel(world))));
    act(world, QStringLiteral("signIn"), {{QStringLiteral("instanceId"), QStringLiteral("gemini")}, {QStringLiteral("methodId"), methodId}});
  });
  step(QStringLiteral("the sign-in starts with the method %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString id = signInMethod(c[0]).value(QLatin1String("id")).toString();
    world.waitFor([&] { return fake(world).methods == QStringList{id}; },
                  [&] { return QStringLiteral("a sign-in with %1; started with %2").arg(id, fake(world).methods.join(QStringLiteral(", "))); });
  });
  step(QStringLiteral("the agent's login terminal shows %1").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForEntry(world, QStringLiteral("Gemini"), [](const QVariantMap& found) { return at(found, QStringLiteral("account.canCancel")).toBool(); },
                 QStringLiteral("to be signing in"));
    sendAuth(world.node, QStringLiteral("gemini"),
             {{QStringLiteral("phase"), QStringLiteral("waiting")},
              {QStringLiteral("flowId"), QStringLiteral("flow-1")},
              {QStringLiteral("interaction"), QJsonObject{{QStringLiteral("id"), QStringLiteral("terminal")},
                                                          {QStringLiteral("type"), QStringLiteral("terminal")},
                                                          {QStringLiteral("output"), c[0]},
                                                          {QStringLiteral("outputOffset"), c[0].size()}}}});
    waitForEntry(world, QStringLiteral("Gemini"), [](const QVariantMap& found) { return !at(found, QStringLiteral("account.terminal")).isNull(); },
                 QStringLiteral("to show the login terminal"));
  });
  step(QStringLiteral("the user is asked to complete sign-in in a terminal showing %1").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForEntry(world, QStringLiteral("Gemini"), [&](const QVariantMap& found) {
      return at(found, QStringLiteral("account.description")) == QLatin1String("Complete sign-in in the terminal below.") &&
             at(found, QStringLiteral("account.terminal.output")) == c[0];
    }, QStringLiteral("to show the login terminal"));
  });
  step(QStringLiteral("the environment no longer has that login terminal"), [](World& world, const Captures&, const Table&) {
    fake(world).terminalGone = true;
  });
  step(QStringLiteral("the user types %1 in the sign-in terminal").arg(q), [](World& world, const Captures& c, const Table&) {
    act(world, QStringLiteral("signInTerminal"), {{QStringLiteral("instanceId"), QStringLiteral("gemini")}, {QStringLiteral("data"), c[0]}});
  });
  step(QStringLiteral("%1 reaches the sign-in terminal on the environment").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      for (const QJsonObject& response : std::as_const(fake(world).responses)) {
        const QJsonObject body = response.value(QLatin1String("response")).toObject();
        if (response.value(QLatin1String("flowId")) == QLatin1String("flow-1") &&
            response.value(QLatin1String("interactionId")) == QLatin1String("terminal") &&
            body.value(QLatin1String("type")) == QLatin1String("terminal") && body.value(QLatin1String("data")) == c[0]) {
          return true;
        }
      }
      return false;
    }, [&] { return QStringLiteral("%1 to reach the terminal; the environment has %2 responses").arg(c[0]).arg(fake(world).responses.size()); });
  });
  step(QStringLiteral("the agent asks for the credential %1").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForEntry(world, QStringLiteral("Gemini"), [](const QVariantMap& found) { return at(found, QStringLiteral("account.canCancel")).toBool(); },
                 QStringLiteral("to be signing in"));
    fake(world).credential = c[0];
    sendAuth(world.node, QStringLiteral("gemini"),
             {{QStringLiteral("phase"), QStringLiteral("waiting")},
              {QStringLiteral("flowId"), QStringLiteral("flow-1")},
              {QStringLiteral("interaction"),
               QJsonObject{{QStringLiteral("id"), QStringLiteral("credentials-1")},
                           {QStringLiteral("type"), QStringLiteral("credentials")},
                           {QStringLiteral("fields"), QJsonArray{QJsonObject{{QStringLiteral("name"), c[0]},
                                                                             {QStringLiteral("label"), QStringLiteral("API key")},
                                                                             {QStringLiteral("secret"), true}}}}}}});
  });
  step(QStringLiteral("the user enters %1 for it and connects").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForEntry(world, QStringLiteral("Gemini"), [](const QVariantMap& found) {
      return at(found, QStringLiteral("account.description")) == QLatin1String("Enter your credentials below.") &&
             !at(found, QStringLiteral("account.credentials")).toList().isEmpty();
    }, QStringLiteral("to ask for credentials"));
    act(world, QStringLiteral("signInCredentials"),
        {{QStringLiteral("instanceId"), QStringLiteral("gemini")}, {QStringLiteral("values"), QVariantMap{{fake(world).credential, c[0]}}}});
  });
  step(QStringLiteral("the environment receives %1 as %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      for (const QJsonObject& response : std::as_const(fake(world).responses)) {
        const QJsonObject body = response.value(QLatin1String("response")).toObject();
        if (response.value(QLatin1String("interactionId")) == QLatin1String("credentials-1") &&
            body.value(QLatin1String("type")) == QLatin1String("credentials") &&
            body.value(QLatin1String("values")).toObject() == QJsonObject{{c[1], c[0]}}) {
          return true;
        }
      }
      return false;
    }, [&] { return QStringLiteral("the credential to be sent; the environment has %1 responses").arg(fake(world).responses.size()); });
  });
  step(QStringLiteral("the sign-in returns to a local address"), [](World& world, const Captures&, const Table&) {
    waitForEntry(world, QStringLiteral("Gemini"), [](const QVariantMap& found) { return at(found, QStringLiteral("account.canCancel")).toBool(); },
                 QStringLiteral("to be signing in"));
    sendAuth(world.node, QStringLiteral("gemini"),
             {{QStringLiteral("phase"), QStringLiteral("waiting")},
              {QStringLiteral("flowId"), QStringLiteral("flow-1")},
              {QStringLiteral("interaction"), QJsonObject{{QStringLiteral("id"), QStringLiteral("browser-1")},
                                                          {QStringLiteral("type"), QStringLiteral("browser")},
                                                          {QStringLiteral("url"), kSignInUrl},
                                                          {QStringLiteral("requiresConsent"), false},
                                                          {QStringLiteral("acceptsCallback"), true}}}});
    waitForEntry(world, QStringLiteral("Gemini"), [](const QVariantMap& found) { return at(found, QStringLiteral("account.acceptsCallback")).toBool(); },
                 QStringLiteral("to accept a pasted address"));
  });
  step(QStringLiteral("the user pastes %1 as the final sign-in address").arg(q), [](World& world, const Captures& c, const Table&) {
    act(world, QStringLiteral("signInCallback"), {{QStringLiteral("instanceId"), QStringLiteral("gemini")}, {QStringLiteral("url"), c[0]}});
  });
  step(QStringLiteral("the environment finishes the sign-in with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      return fake(world).completes.size() == 1 && fake(world).completes.first().value(QLatin1String("callbackUrl")) == c[0] &&
             fake(world).completes.first().value(QLatin1String("flowId")) == QLatin1String("flow-1");
    }, [&] { return QStringLiteral("the sign-in to be finished with %1; it was finished %2 times").arg(c[0]).arg(fake(world).completes.size()); });
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
  step(QStringLiteral("the installed %1 is (of limited support|unsupported|known to be broken)(?: for this HAL-C2 release)?").arg(q),
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
  step(QStringLiteral("%1 is the recommended version").arg(q), [](World& world, const Captures& c, const Table&) {
    offer(world, provider(QStringLiteral("opencode"), QStringLiteral("opencode"), QStringLiteral("OpenCode"),
                          {{QStringLiteral("version"), QStringLiteral("1.15.0")},
                           {QStringLiteral("versionAdvisory"), QJsonObject{{QStringLiteral("status"), QStringLiteral("behind_latest")},
                                                                           {QStringLiteral("latestVersion"), QStringLiteral("1.16.0")},
                                                                           {QStringLiteral("updateCommand"), QStringLiteral("npm install -g opencode-ai@latest")},
                                                                           {QStringLiteral("canUpdate"), true},
                                                                           {QStringLiteral("canInstallVersion"), true}}},
                           {QStringLiteral("compatibilityAdvisory"),
                            QJsonObject{{QStringLiteral("status"), QStringLiteral("broken")},
                                        {QStringLiteral("message"), QStringLiteral("OpenCode 1.15.0 is known to break sessions.")},
                                        {QStringLiteral("recommendedVersion"), c[0]}}}}));
  });
  step(QStringLiteral("the user is offered to install %1 rather than update to the latest").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap found = waitForEntry(world, QStringLiteral("OpenCode"), [&](const QVariantMap& found) {
      return found.value(QStringLiteral("installLabel")) == QStringLiteral("Install ") + c[0];
    }, QStringLiteral("to offer installing ") + c[0]);
    expect(at(found, QStringLiteral("advisory.updateCommand")).isNull(),
           QStringLiteral("no update to the latest to be offered; OpenCode is %1").arg(show(found)));
  });
  step(QStringLiteral("the user installs the recommended version of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForEntry(world, c[0], [](const QVariantMap& found) { return !found.value(QStringLiteral("installLabel")).toString().isEmpty(); },
                 QStringLiteral("to offer the recommended version"));
    dispatch(world, QStringLiteral("install"), c[0]);
  });
  step(QStringLiteral("the environment installs %1 of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      return fake(world).updates.size() == 1 && fake(world).updates.first().payload.value(QLatin1String("targetVersion")) == c[0] &&
             fake(world).updates.first().payload.value(QLatin1String("provider")) == c[1].toLower();
    }, [&] { return QStringLiteral("%1 %2 to be installed; %3 updates ran").arg(c[1], c[0]).arg(fake(world).updates.size()); });
    waitForEntry(world, c[1], [](const QVariantMap& found) { return found.value(QStringLiteral("updating")).toBool(); },
                 QStringLiteral("to be shown updating"));
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


// Custom models: Codex, whose built-in model offers reasoning, and a thread to
// pick the custom model in.
const QString kCustomModel = QStringLiteral("my-model");

QJsonObject reasoning() {
  QJsonArray choices;
  for (const char* level : {"low", "medium", "high"}) {
    choices.append(QJsonObject{{QStringLiteral("id"), QString::fromLatin1(level)},
                               {QStringLiteral("label"), QString::fromLatin1(level)},
                               {QStringLiteral("isDefault"), qstrcmp(level, "medium") == 0}});
  }
  return {{QStringLiteral("id"), QStringLiteral("reasoningEffort")},
          {QStringLiteral("label"), QStringLiteral("Reasoning")},
          {QStringLiteral("type"), QStringLiteral("select")},
          {QStringLiteral("options"), choices}};
}

QJsonObject codexListing() {
  return provider(QStringLiteral("codex"), QStringLiteral("codex"), QStringLiteral("Codex"),
                  {{QStringLiteral("models"),
                    QJsonArray{QJsonObject{{QStringLiteral("slug"), QStringLiteral("gpt-5")},
                                           {QStringLiteral("name"), QStringLiteral("GPT-5")},
                                           {QStringLiteral("capabilities"),
                                            QJsonObject{{QStringLiteral("optionDescriptors"), QJsonArray{reasoning()}}}}}}}});
}

// Codex's instance's saved custom models, as its settings hold them.
QJsonArray savedModels(World& world) {
  return savedInstance(world, QStringLiteral("codex")).value(QLatin1String("config")).toObject().value(QLatin1String("customModels")).toArray();
}

// Codex lists its saved custom models after its own, as the node does
// (HalC2.Environment's with_custom_models): one without options of its own
// takes Codex's first model's.
void listCustomModels(World& world) {
  QJsonObject listing = codexListing();
  QJsonArray models = listing.value(QLatin1String("models")).toArray();
  const QJsonValue fallback = models.first().toObject().value(QLatin1String("capabilities"));
  for (const QJsonValue& value : savedModels(world)) {
    const QJsonObject setting = value.isString() ? QJsonObject{{QStringLiteral("slug"), value}} : value.toObject();
    const QString slug = setting.value(QLatin1String("slug")).toString();
    models.append(QJsonObject{{QStringLiteral("slug"), slug},
                              {QStringLiteral("name"), setting.value(QLatin1String("name")).toString(slug)},
                              {QStringLiteral("isCustom"), true},
                              {QStringLiteral("capabilities"), setting.contains(QLatin1String("capabilities"))
                                                                   ? setting.value(QLatin1String("capabilities"))
                                                                   : fallback}});
  }
  listing.insert(QStringLiteral("models"), models);
  offer(world, listing);
}

// Adds `my-model` to Codex and opens it to edit its options.
void addCustomModel(World& world) {
  seedInstance(world, QStringLiteral("codex"), {{QStringLiteral("driver"), QStringLiteral("codex")}, {QStringLiteral("enabled"), true}},
               codexListing());
  act(world, QStringLiteral("addModel"), {{QStringLiteral("instanceId"), QStringLiteral("codex")}, {QStringLiteral("slug"), kCustomModel}});
  waitForEntry(world, QStringLiteral("Codex"), [](const QVariantMap& found) {
    const QVariantList models = found.value(QStringLiteral("customModels")).toList();
    return models.size() == 1 && models.first().toMap().value(QStringLiteral("slug")) == kCustomModel;
  }, QStringLiteral("to list my-model among its custom models"));
  act(world, QStringLiteral("editModel"), {{QStringLiteral("instanceId"), QStringLiteral("codex")}, {QStringLiteral("slug"), kCustomModel}});
  waitForEntry(world, QStringLiteral("Codex"), [](const QVariantMap& found) {
    return found.value(QStringLiteral("modelDraft")).toMap().value(QStringLiteral("slug")) == kCustomModel;
  }, QStringLiteral("to edit my-model"));
}

QVariantMap editorChoice(const QString& id) {
  return {{QStringLiteral("id"), id}, {QStringLiteral("label"), id}, {QStringLiteral("isDefault"), false}};
}

QVariantMap editorOption(const QString& id, const QString& label, const QVariantList& choices) {
  return {{QStringLiteral("id"), id}, {QStringLiteral("label"), label}, {QStringLiteral("type"), QStringLiteral("select")},
          {QStringLiteral("choices"), choices}};
}

void draftOptions(World& world, const QVariantList& options) {
  act(world, QStringLiteral("modelDraft"), {{QStringLiteral("instanceId"), QStringLiteral("codex")}, {QStringLiteral("options"), options}});
}

void saveCustomModel(World& world) {
  act(world, QStringLiteral("saveModel"), {{QStringLiteral("instanceId"), QStringLiteral("codex")}, {QStringLiteral("slug"), kCustomModel}});
}

// A thread on Codex with `my-model` chosen, once the node lists it.
void chooseCustomModel(World& world) {
  listCustomModels(world);
  world.node.projects.insert(stream::kProject, {{QStringLiteral("id"), stream::kProject},
                                                {QStringLiteral("title"), stream::kProject},
                                                {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")},
                                                {QStringLiteral("scripts"), QJsonArray()}});
  stream::lookAtThread(world, stream::kProject);
  world.waitFor([&] {
    for (const QVariant& listed : world.state(QStringLiteral("modelPicker")).toMap().value(QStringLiteral("instances")).toList()) {
      if (listed.toMap().value(QStringLiteral("instanceId")) != QLatin1String("codex")) continue;
      for (const QVariant& model : listed.toMap().value(QStringLiteral("models")).toList()) {
        if (model.toMap().value(QStringLiteral("slug")) == kCustomModel && model.toMap().value(QStringLiteral("isCustom")).toBool()) return true;
      }
    }
    return false;
  }, [&] { return QStringLiteral("the model picker to offer my-model; it is %1").arg(show(world.state(QStringLiteral("modelPicker")))); });
  world.bridge().dispatch(QStringLiteral("composer.model.select"),
                          QVariantMap{{QStringLiteral("instanceId"), QStringLiteral("codex")}, {QStringLiteral("model"), kCustomModel}});
  world.waitFor([&] { return world.state(QStringLiteral("composer")).toMap().value(QStringLiteral("selectedModel")) == kCustomModel; },
                [&] { return QStringLiteral("the composer on my-model; it shows %1").arg(show(world.state(QStringLiteral("composer")))); });
}

// The choices the composer offers for its model's reasoning.
QStringList reasoningChoices(World& world) {
  QStringList result;
  for (const QVariant& option : world.state(QStringLiteral("composer")).toMap().value(QStringLiteral("options")).toList()) {
    if (option.toMap().value(QStringLiteral("id")) != QLatin1String("reasoningEffort")) continue;
    for (const QVariant& choice : option.toMap().value(QStringLiteral("choices")).toList()) {
      result.append(choice.toMap().value(QStringLiteral("id")).toString());
    }
  }
  return result;
}

QVariantMap registry(World& world) {
  return wizard(world).value(QStringLiteral("registry")).toMap();
}

// Searches the registry in the wizard and waits for this query's answer.
void searchRegistry(World& world, const QString& query) {
  openWizard(world);
  act(world, QStringLiteral("registrySearch"), {{QStringLiteral("query"), query}});
  world.waitFor([&] {
    return registry(world).value(QStringLiteral("query")) == query && !registry(world).value(QStringLiteral("searching")).toBool() &&
           registry(world).value(QStringLiteral("agents")).isValid() && !registry(world).value(QStringLiteral("agents")).isNull();
  }, [&] { return QStringLiteral("the registry's answer to \"%1\"; the wizard is %2").arg(query, show(wizard(world))); });
}

QVariantMap registryAgent(World& world, const QString& agentId) {
  for (const QVariant& agent : registry(world).value(QStringLiteral("agents")).toList()) {
    if (agent.toMap().value(QStringLiteral("id")) == agentId) return agent.toMap();
  }
  return {};
}

const Steps registrySteps([] {
  const QString q = kQuoted;

  step(QStringLiteral("the user searches the ACP Registry for %1").arg(q),
       [](World& world, const Captures& c, const Table&) { searchRegistry(world, c[0]); });
  step(QStringLiteral("the user is told no compatible agents were found and to try a broader search"),
       [](World& world, const Captures&, const Table&) {
    // The pane shows "No compatible agents found" / "Try a broader search." for an empty answer.
    expect(registry(world).value(QStringLiteral("agents")).toList().isEmpty() && registry(world).value(QStringLiteral("error")).toString().isEmpty(),
           QStringLiteral("an empty answer; the registry is %1").arg(show(registry(world))));
  });
  step(QStringLiteral("%1 is already configured").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject config{{QStringLiteral("agentId"), c[0]}};
    seedInstance(world, QStringLiteral("acpRegistry_gemini"),
                 QJsonObject{{QStringLiteral("driver"), QStringLiteral("acpRegistry")},
                             {QStringLiteral("displayName"), QStringLiteral("Gemini")},
                             {QStringLiteral("config"), config}},
                 provider(QStringLiteral("acpRegistry_gemini"), QStringLiteral("acpRegistry"), QStringLiteral("Gemini")));
  });
  step(QStringLiteral("%1 is marked as already added").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap agent = registryAgent(world, c[0]);
    const QVariantMap other = registryAgent(world, QStringLiteral("gemini-lite"));
    expect(agent.value(QStringLiteral("added")).toBool() && !other.isEmpty() && !other.value(QStringLiteral("added")).toBool(),
           QStringLiteral("%1 alone to be marked added; the registry is %2").arg(c[0], show(registry(world))));
    // Adding it again does nothing.
    act(world, QStringLiteral("registryAdd"), {{QStringLiteral("agentId"), c[0]}});
    expect(fake(world).prepares.isEmpty(), QStringLiteral("no agent to be prepared again"));
  });
  step(QStringLiteral("the user moves on without choosing an agent"), [](World& world, const Captures&, const Table&) {
    searchRegistry(world, QString());
    act(world, QStringLiteral("registryManual"), {{QStringLiteral("manual"), true}});
    act(world, QStringLiteral("registryManual"), {{QStringLiteral("manual"), false}});
    act(world, QStringLiteral("wizardStep"), {{QStringLiteral("step"), 1}});
  });
  step(QStringLiteral("the user is asked to select an ACP or configure one manually"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      return wizard(world).value(QStringLiteral("step")) == 0 &&
             registry(world).value(QStringLiteral("selectionError")) == QLatin1String("Select an ACP or configure one manually.");
    }, [&] { return QStringLiteral("the selection to be asked for; the wizard is %1").arg(show(wizard(world))); });
  });
  step(QStringLiteral("the user chooses %1 from the ACP Registry").arg(q), [](World& world, const Captures& c, const Table&) {
    searchRegistry(world, QString());
    act(world, QStringLiteral("registryAdd"), {{QStringLiteral("agentId"), c[0]}});
    world.waitFor([&] { return wizard(world).value(QStringLiteral("step")) == 1; },
                  [&] { return QStringLiteral("the identity step; the wizard is %1").arg(show(wizard(world))); });
    expect(fake(world).prepares == QStringList{c[0]}, QStringLiteral("%1 to be prepared; prepared %2").arg(c[0], fake(world).prepares.join(QStringLiteral(", "))));
    fake(world).suggestedId = wizard(world).value(QStringLiteral("instanceId")).toString();
    act(world, QStringLiteral("wizardSubmit"));
  });
  // A prepare answered after the wizard that asked for it was closed.
  step(QStringLiteral("the user chose %1 from the ACP Registry and it is still being prepared").arg(q), [](World& world, const Captures& c, const Table&) {
    fake(world).holdPrepares = true;
    searchRegistry(world, QString());
    act(world, QStringLiteral("registryAdd"), {{QStringLiteral("agentId"), c[0]}});
    world.waitFor([&] { return fake(world).heldPrepares.size() == 1; }, QStringLiteral("the agent to be prepared"));
  });
  step(QStringLiteral("the user closes the wizard and opens it again"), [](World& world, const Captures&, const Table&) {
    act(world, QStringLiteral("wizardClose"));
    world.waitFor([&] { return wizard(world).isEmpty(); }, [&] { return QStringLiteral("the wizard to close; it is %1").arg(show(wizard(world))); });
    searchRegistry(world, QString());
  });
  step(QStringLiteral("the agent finishes preparing"), [](World& world, const Captures&, const Table&) {
    const FakeNode::Rpc rpc = fake(world).heldPrepares.takeFirst();
    const QString agentId = rpc.payload.value(QLatin1String("agentId")).toString();
    world.node.reply(rpc, QJsonObject{{QStringLiteral("agentId"), agentId},
                                      {QStringLiteral("version"), QStringLiteral("1.2.3")},
                                      {QStringLiteral("distribution"), QStringLiteral("npx")},
                                      {QStringLiteral("prepared"), true}});
    world.sync();
  });
  step(QStringLiteral("the new wizard still asks which agent to add"), [](World& world, const Captures&, const Table&) {
    const QVariantMap shown = wizard(world);
    expect(shown.value(QStringLiteral("step")) == 0 && registry(world).value(QStringLiteral("selected")).toMap().isEmpty() &&
               !registry(world).value(QStringLiteral("busy")).toBool() && shown.value(QStringLiteral("driver")) != QLatin1String("acpRegistry"),
           QStringLiteral("the new wizard to be untouched; it is %1").arg(show(shown)));
  });
  step(QStringLiteral("the new instance is named %1 and runs %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString id = fake(world).suggestedId;
    world.waitFor([&] { return !savedInstance(world, id).isEmpty(); },
                  [&] { return QStringLiteral("%1 to be saved; the wizard is %2").arg(id, show(wizard(world))); });
    const QJsonObject saved = savedInstance(world, id);
    const QJsonObject config = saved.value(QLatin1String("config")).toObject();
    expect(saved.value(QLatin1String("driver")) == QLatin1String("acpRegistry") && saved.value(QLatin1String("displayName")) == c[0] &&
               config.value(QLatin1String("agentId")) == c[1] && config.value(QLatin1String("distribution")) == QLatin1String("auto") &&
               config.value(QLatin1String("registryIconUrl")) == QStringLiteral("https://cdn.agentclientprotocol.com/%1.svg").arg(c[1]),
           QStringLiteral("%1 running %2; saved %3").arg(c[0], c[1], show(saved.toVariantMap())));
    world.waitFor([&] { return wizard(world).isEmpty(); }, [&] { return QStringLiteral("the wizard to close; it is %1").arg(show(wizard(world))); });
  });
});

QVariantMap acpSection(World& world) {
  return entry(world, QStringLiteral("Gemini")).value(QStringLiteral("acp")).toMap();
}

// The shown environment's project `title`.
void acpProject(World& world, const QString& title) {
  const QJsonObject row{{QStringLiteral("id"), title},
                        {QStringLiteral("title"), title},
                        {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + title},
                        {QStringLiteral("createdAt"), stream::iso(stream::now())},
                        {QStringLiteral("updatedAt"), stream::iso(stream::now())},
                        {QStringLiteral("scripts"), QJsonArray()}};
  world.node.projects.insert(title, row);
  world.node.sendRow(title, row, QStringLiteral("project"));
}

// Gemini with one native session in `project`, imported as a thread or not.
void acpSession(World& world, const QString& project, bool imported) {
  openPanel(world);
  acpProject(world, project);
  QJsonObject session{{QStringLiteral("sessionId"), QStringLiteral("session-1")},
                      {QStringLiteral("cwd"), QStringLiteral("/work/") + project},
                      {QStringLiteral("title"), QStringLiteral("Fix the build")},
                      {QStringLiteral("updatedAt"), stream::iso(stream::now())},
                      {QStringLiteral("importedThreadId"), imported ? QJsonValue(QStringLiteral("thread-imported")) : QJsonValue::Null}};
  fake(world).acpSessions = {session};
  offer(world, acpAgent());
  world.waitFor([&] { return acpSection(world).value(QStringLiteral("projectId")) == project; },
                [&] { return QStringLiteral("Gemini's sessions to be asked from %1; the card is %2").arg(project, show(entry(world, QStringLiteral("Gemini")))); });
}

QVariantMap listedSession(World& world) {
  const QVariantList sessions = acpSection(world).value(QStringLiteral("sessions")).toList();
  return sessions.isEmpty() ? QVariantMap{} : sessions.first().toMap();
}

void listSessions(World& world) {
  act(world, QStringLiteral("acpSessions"), {{QStringLiteral("instanceId"), QStringLiteral("gemini")}});
  world.waitFor([&] { const QVariant sessions = acpSection(world).value(QStringLiteral("sessions"));
                      return sessions.typeId() == QMetaType::QVariantList && acpSection(world).value(QStringLiteral("busy")).toString().isEmpty(); },
                [&] { return QStringLiteral("Gemini's sessions to be listed; the section is %1").arg(show(acpSection(world))); });
}

// Gemini's "openai" model provider, listed from a project.
void listAcpProviders(World& world) {
  openPanel(world);
  acpProject(world, QStringLiteral("hal-c2"));
  fake(world).acpProviders = {QJsonObject{{QStringLiteral("providerId"), QStringLiteral("openai")},
                                          {QStringLiteral("supported"), QJsonArray{QStringLiteral("openai")}},
                                          {QStringLiteral("required"), false},
                                          {QStringLiteral("current"), QJsonValue::Null}}};
  offer(world, acpAgent());
  world.waitFor([&] { return !acpSection(world).value(QStringLiteral("projectId")).toString().isEmpty(); },
                [&] { return QStringLiteral("a project to ask Gemini from; the card is %1").arg(show(entry(world, QStringLiteral("Gemini")))); });
  act(world, QStringLiteral("acpProviders"), {{QStringLiteral("instanceId"), QStringLiteral("gemini")}});
  world.waitFor([&] { return acpSection(world).value(QStringLiteral("providers")).toList().size() == 1; },
                [&] { return QStringLiteral("Gemini's model providers; the section is %1").arg(show(acpSection(world))); });
}

QVariantMap acpProvider(World& world) {
  const QVariantList providers = acpSection(world).value(QStringLiteral("providers")).toList();
  return providers.isEmpty() ? QVariantMap{} : providers.first().toMap();
}

void setAcpProvider(World& world, const QString& baseUrl, const QString& headers) {
  act(world, QStringLiteral("acpSetProvider"), {{QStringLiteral("instanceId"), QStringLiteral("gemini")},
                                                {QStringLiteral("providerId"), QStringLiteral("openai")},
                                                {QStringLiteral("apiType"), QStringLiteral("openai")},
                                                {QStringLiteral("baseUrl"), baseUrl},
                                                {QStringLiteral("headers"), headers}});
}

const Steps acpSteps([] {
  const QString q = kQuoted;

  // Native sessions.
  step(QStringLiteral("the agent %1 has a native session for the project %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(c[0] == QLatin1String("gemini"), QStringLiteral("the scenario's agent is gemini"));
    acpSession(world, c[1], false);
  });
  step(QStringLiteral("the agent %1 has a native session that was not imported").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(c[0] == QLatin1String("gemini"), QStringLiteral("the scenario's agent is gemini"));
    acpSession(world, QStringLiteral("hal-c2"), false);
  });
  step(QStringLiteral("a native session was imported as a thread"),
       [](World& world, const Captures&, const Table&) { acpSession(world, QStringLiteral("hal-c2"), true); });
  step(QStringLiteral("the user imports that session"), [](World& world, const Captures&, const Table&) {
    listSessions(world);
    act(world, QStringLiteral("acpImport"), {{QStringLiteral("instanceId"), QStringLiteral("gemini")}, {QStringLiteral("sessionId"), QStringLiteral("session-1")}});
  });
  step(QStringLiteral("a thread continuing the session is created in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return listedSession(world).value(QStringLiteral("imported")).toBool(); },
                  [&] { return QStringLiteral("the session to show as imported; the section is %1").arg(show(acpSection(world))); });
    const QList<QJsonObject> imports = fake(world).acpImports;
    expect(imports.size() == 1 && imports.first().value(QLatin1String("projectId")) == c[0] &&
               imports.first().value(QLatin1String("sessionId")) == QLatin1String("session-1") &&
               imports.first().value(QLatin1String("title")) == QLatin1String("Fix the build"),
           QStringLiteral("session-1 to be imported into %1").arg(c[0]));
    expectToast(world, QStringLiteral("ACP session imported"));
  });
  step(QStringLiteral("the user deletes the native session"), [](World& world, const Captures&, const Table&) {
    listSessions(world);
    act(world, QStringLiteral("acpDelete"), {{QStringLiteral("instanceId"), QStringLiteral("gemini")}, {QStringLiteral("sessionId"), QStringLiteral("session-1")}});
  });
  step(QStringLiteral("the user is told to delete the imported thread first"), [](World& world, const Captures&, const Table&) {
    expectToast(world, QStringLiteral("Could not delete ACP session"),
                QStringLiteral("Delete the imported HAL-C2 thread before deleting its native ACP session."));
    expect(fake(world).acpDeletes.isEmpty() && !listedSession(world).isEmpty(), QStringLiteral("the session to be kept"));
  });
  step(QStringLiteral("the user deletes it and confirms"), [](World& world, const Captures&, const Table&) {
    listSessions(world);
    act(world, QStringLiteral("acpDelete"), {{QStringLiteral("instanceId"), QStringLiteral("gemini")}, {QStringLiteral("sessionId"), QStringLiteral("session-1")}});
    answer(world, true);
  });
  step(QStringLiteral("the session is deleted by the agent"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return fake(world).acpDeletes == QStringList{QStringLiteral("session-1")} && listedSession(world).isEmpty(); },
                  [&] { return QStringLiteral("session-1 to be deleted; the section is %1").arg(show(acpSection(world))); });
    expectToast(world, QStringLiteral("ACP session deleted"));
  });

  // Model providers.
  step(QStringLiteral("the user sets the agent's model provider to %1 with an authorization header").arg(q),
       [](World& world, const Captures& c, const Table&) {
    listAcpProviders(world);
    setAcpProvider(world, c[0], QStringLiteral(R"({"Authorization": "Bearer token"})"));
  });
  step(QStringLiteral("the agent uses that base URL"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return acpProvider(world).value(QStringLiteral("configured")).toBool(); },
                  [&] { return QStringLiteral("openai to be configured; the section is %1").arg(show(acpSection(world))); });
    const QJsonObject set = fake(world).acpSets.value(0);
    expect(acpProvider(world).value(QStringLiteral("baseUrl")) == set.value(QLatin1String("baseUrl")).toString() &&
               set.value(QLatin1String("headers")).toObject().value(QLatin1String("Authorization")) == QLatin1String("Bearer token"),
           QStringLiteral("the base URL and header to be sent; sent %1").arg(show(set.toVariantMap())));
    expectToast(world, QStringLiteral("ACP provider configured"));
  });
  step(QStringLiteral("the user disables that model provider"), [](World& world, const Captures&, const Table&) {
    act(world, QStringLiteral("acpDisableProvider"), {{QStringLiteral("instanceId"), QStringLiteral("gemini")}, {QStringLiteral("providerId"), QStringLiteral("openai")}});
    answer(world, true);
  });
  step(QStringLiteral("the agent no longer uses it"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return fake(world).acpDisables == QStringList{QStringLiteral("openai")} && !acpProvider(world).isEmpty() &&
                               !acpProvider(world).value(QStringLiteral("configured")).toBool(); },
                  [&] { return QStringLiteral("openai to be disabled; the section is %1").arg(show(acpSection(world))); });
    expectToast(world, QStringLiteral("ACP provider disabled"));
  });
  // The headers may hold quotes of their own.
  step(QStringLiteral("the user saves the headers \"(.*)\""), [](World& world, const Captures& c, const Table&) {
    listAcpProviders(world);
    setAcpProvider(world, QStringLiteral("https://api.example.com"), c[0]);
    expect(fake(world).acpSets.isEmpty(), QStringLiteral("nothing to be sent"));
  });

  // Signing out.
  step(QStringLiteral("the user logs out of the agent %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(c[0] == QLatin1String("gemini"), QStringLiteral("the scenario's agent is gemini"));
    openPanel(world);
    offer(world, acpAgent());
    world.waitFor([&] { return acpSection(world).value(QStringLiteral("canLogout")).toBool(); },
                  [&] { return QStringLiteral("Gemini to offer logging out; the card is %1").arg(show(entry(world, QStringLiteral("Gemini")))); });
    act(world, QStringLiteral("acpLogout"), {{QStringLiteral("instanceId"), QStringLiteral("gemini")}});
  });
  step(QStringLiteral("the agent is signed out and its status is read again"), [](World& world, const Captures&, const Table&) {
    expectToast(world, QStringLiteral("Logged out of ACP agent"));
    expect(fake(world).acpLogouts == QStringList{QStringLiteral("gemini")}, QStringLiteral("gemini to be logged out"));
    // The node reads the agent's status again and lists it signed out.
    const QString before = entry(world, QStringLiteral("Gemini")).value(QStringLiteral("headline")).toString();
    offer(world, acpAgent(QStringLiteral("unauthenticated")));
    world.waitFor([&] { return entry(world, QStringLiteral("Gemini")).value(QStringLiteral("headline")).toString() != before; },
                  [&] { return QStringLiteral("Gemini to show signed out; the card is %1").arg(show(entry(world, QStringLiteral("Gemini")))); });
  });
});

const Steps customModelSteps([] {
  const QString q = kQuoted;

  step(QStringLiteral("the user adds the custom model %1 with a reasoning option offering (\\w+) and (\\w+)").arg(q),
       [](World& world, const Captures& c, const Table&) {
    expect(c[0] == kCustomModel, QStringLiteral("the scenario adds my-model"));
    addCustomModel(world);
    draftOptions(world, {editorOption(QStringLiteral("reasoningEffort"), QStringLiteral("Reasoning"), {editorChoice(c[1]), editorChoice(c[2])})});
    saveCustomModel(world);
    world.waitFor([&] {
      const QJsonArray saved = savedModels(world);
      return saved.size() == 1 && saved.first().toObject().contains(QLatin1String("capabilities"));
    }, [&] { return QStringLiteral("my-model to be saved with its option; Codex holds %1").arg(show(savedModels(world).toVariantList())); });
  });
  step(QStringLiteral("%1 is offered in the model picker").arg(q), [](World& world, const Captures&, const Table&) {
    chooseCustomModel(world);
  });
  step(QStringLiteral("the composer offers (\\w+) and (\\w+) reasoning for it"), [](World& world, const Captures& c, const Table&) {
    const QStringList choices = reasoningChoices(world);
    expect(choices == QStringList{c[0], c[1]}, QStringLiteral("the composer offers %1").arg(choices.join(QStringLiteral(", "))));
  });

  step(QStringLiteral("the user adds a custom model and copies the options of a built-in model"), [](World& world, const Captures&, const Table&) {
    addCustomModel(world);
    act(world, QStringLiteral("modelDraft"), {{QStringLiteral("instanceId"), QStringLiteral("codex")}, {QStringLiteral("copyFrom"), QStringLiteral("gpt-5")}});
  });
  step(QStringLiteral("the custom model starts with the same options"), [](World& world, const Captures&, const Table&) {
    const QVariantMap copied = waitForEntry(world, QStringLiteral("Codex"), [](const QVariantMap& found) {
      return !found.value(QStringLiteral("modelDraft")).toMap().value(QStringLiteral("options")).toList().isEmpty();
    }, QStringLiteral("to hold GPT-5's options in the draft")).value(QStringLiteral("modelDraft")).toMap();
    const QVariantList options = copied.value(QStringLiteral("options")).toList();
    QStringList choices;
    QString chosen;
    for (const QVariant& choice : options.value(0).toMap().value(QStringLiteral("choices")).toList()) {
      choices.append(choice.toMap().value(QStringLiteral("id")).toString());
      if (choice.toMap().value(QStringLiteral("isDefault")).toBool()) chosen = choice.toMap().value(QStringLiteral("id")).toString();
    }
    expect(options.size() == 1 && options.first().toMap().value(QStringLiteral("id")) == QLatin1String("reasoningEffort") &&
               choices == QStringList{QStringLiteral("low"), QStringLiteral("medium"), QStringLiteral("high")} && chosen == QLatin1String("medium"),
           QStringLiteral("the draft starts with %1").arg(show(copied)));
    // Saved, it is the built-in model's option.
    saveCustomModel(world);
    world.waitFor([&] {
      const QJsonArray descriptors = savedModels(world).first().toObject().value(QLatin1String("capabilities")).toObject()
                                         .value(QLatin1String("optionDescriptors")).toArray();
      return descriptors.size() == 1 && descriptors.first().toObject().value(QLatin1String("options")).toArray().size() == 3 &&
             descriptors.first().toObject().value(QLatin1String("currentValue")) == QLatin1String("medium");
    }, [&] { return QStringLiteral("my-model to be saved with GPT-5's options; Codex holds %1").arg(show(savedModels(world).toVariantList())); });
  });

  step(QStringLiteral("the user saves a custom option with (.+)"), [](World& world, const Captures& c, const Table&) {
    addCustomModel(world);
    const QVariantMap problems{
        {QStringLiteral("no id"), editorOption(QString(), QStringLiteral("Reasoning"), {editorChoice(QStringLiteral("low"))})},
        {QStringLiteral("no label"), editorOption(QStringLiteral("reasoningEffort"), QString(), {editorChoice(QStringLiteral("low"))})},
        {QStringLiteral("a choice list with no choices"), editorOption(QStringLiteral("reasoningEffort"), QStringLiteral("Reasoning"), {})},
        {QStringLiteral("the same choice twice"),
         editorOption(QStringLiteral("reasoningEffort"), QStringLiteral("Reasoning"), {editorChoice(QStringLiteral("low")), editorChoice(QStringLiteral("low"))})},
    };
    expect(problems.contains(c[0]), QStringLiteral("a known problem, not %1").arg(c[0]));
    fake(world).writesBefore = fakeConfig(world.node).writes.size();
    draftOptions(world, {problems.value(c[0])});
    saveCustomModel(world);
  });
  step(QStringLiteral("the user is told the option (.+)"), [](World& world, const Captures& c, const Table&) {
    const QHash<QString, QString> messages{
        {QStringLiteral("needs an id"), QStringLiteral("Option 1 needs an id.")},
        {QStringLiteral("needs a label"), QStringLiteral("Option 1 needs a label.")},
        {QStringLiteral("needs at least one choice"), QStringLiteral("Option 1 needs at least one choice.")},
        {QStringLiteral("uses a choice twice"), QStringLiteral("Option 1: choice \"low\" is used twice.")},
    };
    const QVariantMap shown = waitForEntry(world, QStringLiteral("Codex"), [&](const QVariantMap& found) {
      return found.value(QStringLiteral("modelError")) == messages.value(c[0]);
    }, QStringLiteral("to say the option ") + c[0]);
    // Nothing is saved, and the option stays open to fix.
    expect(fakeConfig(world.node).writes.size() == fake(world).writesBefore &&
               shown.value(QStringLiteral("modelDraft")).toMap().value(QStringLiteral("slug")) == kCustomModel,
           QStringLiteral("the draft to stay unsaved; the entry is %1").arg(show(shown)));
  });

  step(QStringLiteral("the user adds a custom model with no options"), [](World& world, const Captures&, const Table&) {
    addCustomModel(world);
    saveCustomModel(world);
    world.waitFor([&] { return savedModels(world) == QJsonArray{kCustomModel} &&
                               entry(world, QStringLiteral("Codex")).value(QStringLiteral("modelDraft")).isNull(); },
                  [&] { return QStringLiteral("my-model to be saved as its slug alone; Codex holds %1").arg(show(savedModels(world).toVariantList())); });
  });
  step(QStringLiteral("the composer uses the provider's default options for it"), [](World& world, const Captures&, const Table&) {
    chooseCustomModel(world);
    const QStringList choices = reasoningChoices(world);
    expect(choices == QStringList{QStringLiteral("low"), QStringLiteral("medium"), QStringLiteral("high")},
           QStringLiteral("the composer offers Codex's reasoning for my-model; it offers %1").arg(choices.join(QStringLiteral(", "))));
  });
});

}  // namespace

// "The user renames <instance> to <name>" in the Providers settings
// (WorkspaceSteps.cpp shares the words for thread titles).
void renameProviderInstance(World& world, const QString& from, const QString& to) {
  seedWork(world, from);
  act(world, QStringLiteral("rename"), {{QStringLiteral("instanceId"), fake(world).instanceId}, {QStringLiteral("name"), to}});
}
