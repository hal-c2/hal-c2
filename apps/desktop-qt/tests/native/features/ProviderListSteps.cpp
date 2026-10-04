// The provider list of the Providers settings section as
// features/providers/provider-instances.feature words it: whose providers it
// shows, what a session that may only view them sees, and each provider's
// status headline. The MC's own environment is this machine; the others are
// environments it is linked to.

#include <QJsonArray>
#include <QJsonObject>

#include <QJsonDocument>

#include "Brick.h"
#include "FakeConfig.h"
#include "Harness.h"
#include "SharedSteps.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "World.h"

namespace {

struct ProviderList {
  // The environment the scenario is about, when it is not this machine.
  QString environment;
  // The instance whose headline the scenario reads.
  QString instanceId;
  bool hidModel = false;
};

QVariantMap panel(World& world) {
  return world.state(QStringLiteral("providerSettings")).toMap();
}

QJsonObject provider(const QString& instanceId, const QString& name, const QJsonObject& fields = {}) {
  QJsonObject entry{{QStringLiteral("instanceId"), instanceId},
                    {QStringLiteral("driver"), QStringLiteral("codex")},
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

void link(World& world, const QString& environment, const QJsonArray& providers) {
  fakeConfig(world.mc).elsewhere.insert(environment, QJsonObject{{QStringLiteral("providers"), providers}});
  world.mc.link(environment);
}

void openPanel(World& world) {
  if (panel(world).value(QStringLiteral("open")).toBool()) return;
  world.native().controller<NavigationController>()->open(
      NavigationController::Route::settings(NavigationController::kProvidersSection));
  world.waitFor([&] { return panel(world).value(QStringLiteral("open")).toBool(); },
                [&] { return QStringLiteral("the Providers settings to open; they are %1").arg(show(panel(world))); });
}

void pick(World& world, const QString& environment) {
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

QStringList listed(World& world) {
  QStringList names;
  for (const QVariant& row : panel(world).value(QStringLiteral("providers")).toList()) {
    names.append(row.toMap().value(QStringLiteral("name")).toString());
  }
  return names;
}

// Claude with four models, as the environment lists them.
void offerClaude(World& world) {
  QJsonArray models;
  for (const QString& name : {QStringLiteral("Opus"), QStringLiteral("Sonnet"), QStringLiteral("Haiku"), QStringLiteral("Fable")}) {
    models.append(QJsonObject{{QStringLiteral("slug"), name.toLower()}, {QStringLiteral("name"), name}});
  }
  QJsonObject claude = provider(QStringLiteral("claudeAgent"), QStringLiteral("Claude"), {{QStringLiteral("models"), models}});
  claude.insert(QStringLiteral("driver"), QStringLiteral("claudeAgent"));
  publishProviders(world.mc, {claude});
  world.openDraft(QStringLiteral("shop"));
  openPanel(world);
  world.waitFor([&] { return listed(world) == QStringList{QStringLiteral("Claude")}; },
                [&] { return QStringLiteral("Claude to be listed; the panel is %1").arg(show(panel(world))); });
}

// The models the picker offers for Claude, by name, in order.
QStringList picked(World& world) {
  QStringList names;
  for (const QVariant& instance : world.state(QStringLiteral("modelPicker")).toMap().value(QStringLiteral("instances")).toList()) {
    if (instance.toMap().value(QStringLiteral("instanceId")) != QLatin1String("claudeAgent")) continue;
    for (const QVariant& model : instance.toMap().value(QStringLiteral("models")).toList()) names.append(model.toMap().value(QStringLiteral("name")).toString());
  }
  return names;
}

void hide(World& world, const QString& name, bool hidden) {
  world.bridge().dispatch(QStringLiteral("providerSettings.modelHidden"),
                          QVariantMap{{QStringLiteral("instanceId"), QStringLiteral("claudeAgent")}, {QStringLiteral("slug"), name.toLower()}, {QStringLiteral("hidden"), hidden}});
}

}  // namespace

bool expectModelOffered(World& world, const QString& name) {
  if (!world.mc.part<ProviderList>().hidModel) return false;
  world.waitFor([&] { return picked(world).contains(name); }, [&] { return QStringLiteral("%1 in the picker; it offers %2").arg(name, picked(world).join(u", ")); });
  return true;
}

namespace {

const Steps steps([] {
  const QString q = kQuoted;

  // Whose providers.
  step(QStringLiteral("the user is connected to the environments %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    for (const QString& environment : {c[0], c[1]}) {
      link(world, environment, {provider(QStringLiteral("codex"), QStringLiteral("Codex on ") + environment)});
    }
    world.sync();
  });
  step(QStringLiteral("the user picks %1 in provider settings").arg(q), [](World& world, const Captures& c, const Table&) {
    pick(world, c[0]);
  });
  step(QStringLiteral("the providers of %1 are shown").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      return panel(world).value(QStringLiteral("status")) == QLatin1String("ready") &&
             panel(world).value(QStringLiteral("environmentId")) == c[0] &&
             listed(world) == QStringList{QStringLiteral("Codex on ") + c[0]};
    }, [&] { return QStringLiteral("only the providers of %1; the panel is %2").arg(c[0], show(panel(world))); });
  });
  step(QStringLiteral("the user is told to reconnect that device or pick another one"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      return panel(world).value(QStringLiteral("status")) == QLatin1String("offline") &&
             panel(world).value(QStringLiteral("description")) ==
                 QLatin1String("Reconnect this device to set up its provider, or select another device.") &&
             panel(world).value(QStringLiteral("providers")).toList().isEmpty();
    }, [&] { return QStringLiteral("the panel to ask for a reconnect; it is %1").arg(show(panel(world))); });
  });

  // A session that may only view.
  step(QStringLiteral("the client has view-only access to the environment"), [](World& world, const Captures&, const Table&) {
    const QString environment = QStringLiteral("Build box");
    world.mc.linkScopes.insert(environment, {QStringLiteral("orchestration:read")});
    link(world, environment, {provider(QStringLiteral("codex"), QStringLiteral("Codex"))});
    world.mc.part<ProviderList>().environment = environment;
    world.sync();
  });
  step(QStringLiteral("the user opens provider settings"), [](World& world, const Captures&, const Table&) {
    const QString environment = world.mc.part<ProviderList>().environment;
    if (environment.isEmpty()) {
      openPanel(world);
    } else {
      pick(world, environment);
    }
  });
  step(QStringLiteral("the providers are shown but every change is unavailable"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return listed(world) == QStringList{QStringLiteral("Codex")} && panel(world).value(QStringLiteral("readOnly")).toBool(); },
                  [&] { return QStringLiteral("the providers read-only; the panel is %1").arg(show(panel(world))); });
    // Nothing on the page takes a change: no instance is added, turned off or reconfigured.
    const qsizetype writes = fakeConfig(world.mc).writes.size();
    const QVariantMap before = panel(world);
    const QVariantMap codex{{QStringLiteral("instanceId"), QStringLiteral("codex")}};
    const auto act = [&](const QString& action, QVariantMap payload) {
      world.bridge().dispatch(QStringLiteral("providerSettings.") + action, payload);
    };
    act(QStringLiteral("wizardOpen"), {});
    act(QStringLiteral("enable"), {{QStringLiteral("instanceId"), QStringLiteral("codex")}, {QStringLiteral("enabled"), false}});
    act(QStringLiteral("rename"), {{QStringLiteral("instanceId"), QStringLiteral("codex")}, {QStringLiteral("name"), QStringLiteral("Mine")}});
    act(QStringLiteral("healthInterval"), {{QStringLiteral("seconds"), 60}});
    act(QStringLiteral("delete"), codex);
    world.sync();
    expect(panel(world) == before && fakeConfig(world.mc).writes.size() == writes &&
               documentOf(world.mc, world.mc.part<ProviderList>().environment).version == 0,
           QStringLiteral("no change to be made; the panel is %1").arg(show(panel(world))));
  });
  step(QStringLiteral("the user is told this session can only view them"), [](World& world, const Captures&, const Table&) {
    const QString said = panel(world).value(QStringLiteral("readOnlyDescription")).toString();
    expect(said == QLatin1String("This session can view Build box's providers but can't change their settings."),
           QStringLiteral("the read-only note; it says \"%1\"").arg(said));
  });

  // Which models this device's picker offers (providers/models.feature).
  step(QStringLiteral("the user hid the model %1").arg(q), [](World& world, const Captures& c, const Table&) {
    offerClaude(world);
    world.mc.part<ProviderList>().hidModel = true;
    hide(world, c[0], true);
    world.waitFor([&] { return !picked(world).contains(c[0]); }, [&] { return QStringLiteral("%1 to leave the picker; it offers %2").arg(c[0], picked(world).join(u", ")); });
  });
  step(QStringLiteral("the user shows %1 in the picker again").arg(q), [](World& world, const Captures& c, const Table&) {
    // From the provider's card, where the hidden model is still listed.
    world.brick = std::make_unique<Brick>(world, QByteArrayLiteral("import QtQuick\nimport HalC2.Shell\nimport HalC2.Bricks\n"
                                                                    "ProviderModelList { width: 500; provider: Shell.state.providerSettings.providers[0] }\n"),
                                          QSize(500, 300));
    expect(world.brick->shows(QStringLiteral("Show")), QStringLiteral("the card does not offer to show a model"));
    world.brick->click(QStringLiteral("modelHidden-") + c[0].toLower());
  });
  step(QStringLiteral("the user favourites one model, hides another and moves a third up"), [](World& world, const Captures&, const Table&) {
    offerClaude(world);
    world.bridge().dispatch(QStringLiteral("composer.model.favorite.toggle"),
                            QVariantMap{{QStringLiteral("instanceId"), QStringLiteral("claudeAgent")}, {QStringLiteral("model"), QStringLiteral("sonnet")}});
    hide(world, QStringLiteral("Haiku"), true);
    // Fable is listed last: up past Haiku, Sonnet and Opus.
    for (int step = 0; step < 3; ++step) {
      world.bridge().dispatch(QStringLiteral("providerSettings.modelMove"),
                              QVariantMap{{QStringLiteral("instanceId"), QStringLiteral("claudeAgent")}, {QStringLiteral("slug"), QStringLiteral("fable")}, {QStringLiteral("by"), -1}});
    }
  });
  step(QStringLiteral("the model picker on this device reflects those choices"), [](World& world, const Captures&, const Table&) {
    // The favourite leads, the one moved up comes before Opus, and Haiku is gone.
    const QStringList expected{QStringLiteral("Sonnet"), QStringLiteral("Fable"), QStringLiteral("Opus")};
    world.waitFor([&] { return picked(world) == expected; }, [&] { return QStringLiteral("the picker to offer %1; it offers %2").arg(expected.join(u", "), picked(world).join(u", ")); });
    // And they outlive the app.
    world.restart();
    world.connect();
    world.sync();
    publishProviders(world.mc, fakeConfig(world.mc).config.value(QLatin1String("providers")).toArray());
    world.waitFor([&] { return picked(world) == expected; }, [&] { return QStringLiteral("the same after a restart; the picker offers %1").arg(picked(world).join(u", ")); });
  });
  step(QStringLiteral("other devices keep their own choices"), [](World& world, const Captures&, const Table&) {
    // Kept in this device's preferences: nothing of them was saved on the environment.
    for (const QJsonObject& write : fakeConfig(world.mc).writes) {
      const QString saved = QString::fromUtf8(QJsonDocument(write).toJson());
      expect(!saved.contains(QLatin1String("hiddenModels")) && !saved.contains(QLatin1String("favorites")) && !saved.contains(QLatin1String("modelOrder")),
             QStringLiteral("the choices were saved on the environment: %1").arg(saved));
    }
    const QJsonObject device = world.native().controller<SettingsController>()->deviceSettings();
    expect(device.contains(QLatin1String("providerModelPreferences")) && device.contains(QLatin1String("favorites")),
           QStringLiteral("this device keeps %1").arg(show(device.toVariantMap())));
  });

  // Status headlines.
  step(QStringLiteral("a provider that is (not checked yet|disabled|not installed|signed out|failing its startup checks|signed in)"),
       [](World& world, const Captures& c, const Table&) {
    const QString instanceId = QStringLiteral("codex_work");
    world.mc.part<ProviderList>().instanceId = instanceId;
    // Configured here, as every state is; what the environment reports of it differs.
    QJsonObject instances = fakeConfig(world.mc).settings.value(QLatin1String("providerInstances")).toObject();
    instances.insert(instanceId, QJsonObject{{QStringLiteral("driver"), QStringLiteral("codex")},
                                             {QStringLiteral("displayName"), QStringLiteral("Codex Work")},
                                             {QStringLiteral("enabled"), c[0] != QLatin1String("disabled")}});
    saveElsewhere(world.mc, QStringLiteral("providerInstances"), instances);
    if (c[0] == QLatin1String("not checked yet")) return;
    QJsonObject fields;
    if (c[0] == QLatin1String("disabled")) {
      fields = {{QStringLiteral("enabled"), false}, {QStringLiteral("status"), QStringLiteral("disabled")}};
    } else if (c[0] == QLatin1String("not installed")) {
      fields = {{QStringLiteral("installed"), false}, {QStringLiteral("status"), QStringLiteral("error")}};
    } else if (c[0] == QLatin1String("signed out")) {
      fields = {{QStringLiteral("auth"), QJsonObject{{QStringLiteral("status"), QStringLiteral("unauthenticated")}}},
                {QStringLiteral("status"), QStringLiteral("error")}};
    } else if (c[0] == QLatin1String("failing its startup checks")) {
      fields = {{QStringLiteral("status"), QStringLiteral("error")}};
    } else {
      fields = {{QStringLiteral("auth"), QJsonObject{{QStringLiteral("status"), QStringLiteral("authenticated")}}}};
    }
    publishProviders(world.mc, {provider(instanceId, QStringLiteral("Codex Work"), fields)});
  });
  step(QStringLiteral("the user opens the provider list"), [](World& world, const Captures&, const Table&) {
    openPanel(world);
    world.waitFor([&] { return panel(world).value(QStringLiteral("status")) == QLatin1String("ready"); },
                  [&] { return QStringLiteral("the providers to be ready; the panel is %1").arg(show(panel(world))); });
  });
  step(QStringLiteral("the provider reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString instanceId = world.mc.part<ProviderList>().instanceId;
    QString headline;
    const auto reads = [&] {
      for (const QVariant& row : panel(world).value(QStringLiteral("providers")).toList()) {
        if (row.toMap().value(QStringLiteral("instanceId")) == instanceId) headline = row.toMap().value(QStringLiteral("headline")).toString();
      }
      return headline == c[0];
    };
    world.waitFor(reads, [&] { return QStringLiteral("%1 to read \"%2\"; it reads \"%3\" in %4").arg(instanceId, c[0], headline, show(panel(world))); });
  });
});

}  // namespace
