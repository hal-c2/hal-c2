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
