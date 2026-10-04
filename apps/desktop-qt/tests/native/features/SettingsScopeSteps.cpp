// Where settings apply, as the settings pages show and honour it: the scope
// sentence, a project's overrides, this device's own preferences, and values
// the environments disagree on (features/settings/scopes-and-inheritance.feature,
// settings/search-and-navigation.feature).

#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>

#include "Brick.h"
#include "FakeConfig.h"
#include "Harness.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "SettingsRows.h"
#include "SettingsScopeController.h"
#include "SettingsShell.h"
#include "World.h"

namespace {

const QString kModel = QStringLiteral("defaultModelSelection");
const QString kProvider = QStringLiteral("claudeAgent");
const QString kDevicePreference = QStringLiteral("timestampFormat");
const QString kEnvironmentWide = QStringLiteral("autoResumeLimitedThreads");

struct Scoped {
  QString project;
  QString chosen;  // the model the user chose, as "<instance>:<slug>"
};

Scoped& scoped(World& world) {
  return world.mc.part<Scoped>();
}

QVariantMap scope(World& world) {
  return world.state(QStringLiteral("settingsScope")).toMap();
}

QVariantMap projectPanel(World& world) {
  return world.state(QStringLiteral("projectSettings")).toMap();
}

QVariantMap modelRow(World& world) {
  return projectPanel(world).value(QStringLiteral("model")).toMap();
}

QJsonObject selection(const QString& slug) {
  return {{QStringLiteral("instanceId"), kProvider}, {QStringLiteral("model"), slug}};
}

QJsonObject provider(const QStringList& models) {
  QJsonArray slugs;
  for (const QString& model : models) slugs.append(QJsonObject{{QStringLiteral("slug"), model.toLower()}, {QStringLiteral("name"), model}});
  return {{QStringLiteral("instanceId"), kProvider}, {QStringLiteral("displayName"), QStringLiteral("Claude")}, {QStringLiteral("enabled"), true},
          {QStringLiteral("installed"), true}, {QStringLiteral("models"), slugs}};
}

// The models each environment's provider offers, before the settings follow it.
void offer(World& world, const QString& environment, const QStringList& models) {
  const QJsonArray providers{provider(models)};
  if (environment == world.mc.environmentId) {
    publishProviders(world.mc, providers);
    return;
  }
  QJsonObject config = fakeConfig(world.mc).elsewhere.value(environment);
  config.insert(QStringLiteral("providers"), providers);
  fakeConfig(world.mc).elsewhere.insert(environment, config);
}

void offerEverywhere(World& world, const QStringList& models) {
  if (fakeConfig(world.mc).config.contains(QLatin1String("providers"))) return;
  offer(world, world.mc.environmentId, models);
  for (const QString& environment : world.mc.members) offer(world, environment, models);
}

QJsonObject& settingsOf(World& world, const QString& environment) {
  return environment == world.mc.environmentId ? fakeConfig(world.mc).settings : documentOf(world.mc, environment).settings;
}

// The project's checkout on a linked machine, as the feature's background names it.
QString checkoutOn(const QString& project, const QString& environment) {
  return project + QLatin1Char('-') + environment;
}

QJsonValue overrideOn(World& world, const QString& project, const QString& environment) {
  return SettingsScopeController::overrideOf(settingsOf(world, environment), checkoutOn(project, environment), kModel);
}

void setOverride(World& world, const QString& project, const QString& environment, const QJsonValue& value) {
  QJsonObject& settings = settingsOf(world, environment);
  settings = SettingsScopeController::withOverride(settings, checkoutOn(project, environment), kModel, value);
}

QString describeDocuments(World& world) {
  QStringList lines{QStringLiteral("this machine holds %1").arg(show(fakeConfig(world.mc).settings.toVariantMap()))};
  for (const QString& environment : world.mc.members) {
    lines.append(QStringLiteral("%1 holds %2").arg(environment, show(documentOf(world.mc, environment).settings.toVariantMap())));
  }
  return lines.join(QStringLiteral("; "));
}

int writes(World& world) {
  FakeConfig& fake = fakeConfig(world.mc);
  int count = int(fake.writes.size());
  for (const FakeConfig::Document& document : std::as_const(fake.documents)) count += document.version;
  return count;
}

void connectIfNeeded(World& world) {
  if (world.shellSubscriptions() > 0) return;
  world.connect();
  world.sync();
}

void openSection(World& world, const QString& section) {
  connectIfNeeded(world);
  world.bridge().dispatch(QStringLiteral("settings.navigate"), QVariantMap{{QStringLiteral("to"), section}});
  world.waitFor([&] { return at(world.state(QStringLiteral("route")), QStringLiteral("section")) == section; },
                [&] { return QStringLiteral("the route is %1").arg(show(world.state(QStringLiteral("route")))); });
}

// Picks the project in the scope sentence's list, as its picker does.
void chooseProject(World& world, const QString& title) {
  QString key;
  world.waitFor([&] {
    for (const QVariant& row : scope(world).value(QStringLiteral("projects")).toList()) {
      if (row.toMap().value(QStringLiteral("title")) == title) key = row.toMap().value(QStringLiteral("key")).toString();
    }
    return !key.isEmpty();
  }, [&] { return QStringLiteral("%1 to be offered; the scope is %2").arg(title, show(scope(world))); });
  world.bridge().dispatch(QStringLiteral("settingsScope.project"), QVariantMap{{QStringLiteral("key"), key}});
  world.waitFor([&] { return scope(world).value(QStringLiteral("kind")) == QLatin1String("project") && scope(world).value(QStringLiteral("projectLabel")) == title; },
                [&] { return QStringLiteral("the project scope; it is %1").arg(show(scope(world))); });
}

void waitForModelRow(World& world, const std::function<bool(const QVariantMap&)>& holds, const QString& what) {
  world.waitFor([&] { return projectPanel(world).value(QStringLiteral("open")).toBool() && holds(modelRow(world)); },
                [&] { return QStringLiteral("%1; the panel is %2").arg(what, show(projectPanel(world))); });
}

QQuickItem* breadcrumb(World& world) {
  return settingsShell(world).item(QStringLiteral("settingsBreadcrumb"));
}

bool asksWhere(World& world) {
  Brick& brick = settingsShell(world);
  brick.grab();
  return brick.shows(QStringLiteral("Applying settings for"));
}

const Steps steps([] {
  const QString q = kQuoted;

  // The scope sentence.
  step(QStringLiteral("the page says it is applying settings for all projects across all environments"), [](World& world, const Captures&, const Table&) {
    connectIfNeeded(world);
    Brick& brick = settingsShell(world);
    world.waitFor([&] { return asksWhere(world); }, QStringLiteral("the page to say where settings apply"));
    const QString project = brick.item(QStringLiteral("scopeProject"))->property("displayText").toString();
    const QString environment = brick.item(QStringLiteral("scopeEnvironment"))->property("displayText").toString();
    expect(project == QLatin1String("All projects") && environment == QLatin1String("All environments") && brick.shows(QStringLiteral("across")),
           QStringLiteral("the page says \"%1\" and \"%2\"; the scope is %3").arg(project, environment, show(scope(world))));
  });

  // A project scope.
  step(QStringLiteral("the user is editing settings for the project %1").arg(q), [](World& world, const Captures& c, const Table&) {
    scoped(world).project = c[0];
    offerEverywhere(world, {QStringLiteral("Sonnet"), QStringLiteral("Opus")});
    connectIfNeeded(world);
    // A feature with no such project has it on this machine.
    const QVariantList projects = at(world.state(QStringLiteral("sidebar")), QStringLiteral("projects")).toList();
    const bool known = std::any_of(projects.cbegin(), projects.cend(), [&](const QVariant& project) { return at(project, QStringLiteral("displayName")) == c[0]; });
    if (!known) {
      world.mc.projects.insert(c[0], {{QStringLiteral("id"), c[0]}, {QStringLiteral("title"), c[0]}, {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + c[0]},
                                       {QStringLiteral("scripts"), QJsonArray()}});
      world.mc.sendRow(c[0], world.mc.projects.value(c[0]), QStringLiteral("project"));
      world.sync();
    }
    openSection(world, QStringLiteral("/settings/projects"));
    world.bridge().dispatch(QStringLiteral("settingsScope.environment"), QVariantMap{{QStringLiteral("id"), QString()}});
    chooseProject(world, c[0]);
  });
  step(QStringLiteral("the user changes the default model"), [](World& world, const Captures&, const Table&) {
    waitForModelRow(world, [](const QVariantMap& row) { return !row.value(QStringLiteral("models")).toList().isEmpty(); }, QStringLiteral("models to be offered"));
    scoped(world).chosen = kProvider + QStringLiteral(":opus");
    world.bridge().dispatch(QStringLiteral("projectSettings.model"), QVariantMap{{QStringLiteral("key"), scoped(world).chosen}});
  });
  step(QStringLiteral("%1 overrides the default model on each environment with a checkout of it").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      return std::all_of(world.mc.members.cbegin(), world.mc.members.cend(),
                         [&](const QString& environment) { return overrideOn(world, c[0], environment) == QJsonValue(selection(QStringLiteral("opus"))); });
    }, [&] { return describeDocuments(world); });
  });
  step(QStringLiteral("other projects keep the environment's default model"), [](World& world, const Captures&, const Table&) {
    world.sync();
    for (const QString& environment : world.mc.members) {
      const QJsonObject settings = documentOf(world.mc, environment).settings;
      expect(!settings.contains(kModel) && settings.value(QLatin1String("projectSettingsOverrides")).toObject().size() == 1, describeDocuments(world));
    }
    // And the environment with no checkout of it is not written to.
    expect(fakeConfig(world.mc).writes.isEmpty(), describeDocuments(world));
  });

  // This device's preferences.
  step(QStringLiteral("the user changes a preference that belongs to this device"), [](World& world, const Captures&, const Table&) {
    openSection(world, QStringLiteral("/settings/general"));
    world.mc.part<int>() = writes(world);
    chooseRow(world, kDevicePreference, QStringLiteral("24-hour"));
  });
  step(QStringLiteral("the preference is saved on this device"), [](World& world, const Captures&, const Table&) {
    auto* settings = world.native().controller<SettingsController>();
    expect(settings->onDevice(kDevicePreference) && settings->deviceSettings().value(kDevicePreference) == QLatin1String("24-hour"),
           QStringLiteral("this device holds %1").arg(show(settings->deviceSettings().toVariantMap())));
  });
  step(QStringLiteral("no environment is changed"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(writes(world) == world.mc.part<int>(), describeDocuments(world));
  });

  // An environment-wide row at project scope.
  step(QStringLiteral("the user looks at an environment-wide setting"), [](World& world, const Captures&, const Table&) {
    openSection(world, QStringLiteral("/settings/general"));
    world.settingRow = kEnvironmentWide;
    expect(rowShown(world, kEnvironmentWide), QStringLiteral("the page has no %1 row").arg(kEnvironmentWide));
  });
  step(QStringLiteral("the user is told to select an environment to change it"), [](World& world, const Captures&, const Table&) {
    const QQuickItem* status = pageItem(world, QStringLiteral("settingsRow:") + kEnvironmentWide, QStringLiteral("status"));
    expect(status->isVisible() && status->property("text") == QLatin1String("Environment-wide setting. Select an environment to change it."),
           QStringLiteral("the row says \"%1\"").arg(status->property("text").toString()));
    // A setting the project can override stays open.
    expect(pageItem(world, QStringLiteral("settingsRow:responseStreamingMode"), QStringLiteral("control"))->isEnabled(),
           QStringLiteral("a project setting is locked too"));
  });

  // Overrides.
  step(QStringLiteral("%1 overrides the default model").arg(q), [](World& world, const Captures& c, const Table&) {
    // The environments default to Opus; the project keeps Sonnet.
    for (const QString& environment : world.mc.members) {
      settingsOf(world, environment).insert(kModel, selection(QStringLiteral("opus")));
      setOverride(world, c[0], environment, selection(QStringLiteral("sonnet")));
    }
  });
  step(QStringLiteral("the user resets the default model to the inherited value"), [](World& world, const Captures&, const Table&) {
    waitForModelRow(world, [](const QVariantMap& row) { return row.value(QStringLiteral("resettable")).toBool() && row.value(QStringLiteral("label")) == QStringLiteral("Claude · Sonnet"); },
                    QStringLiteral("the project's own model with a reset"));
    world.bridge().dispatch(QStringLiteral("projectSettings.reset"), QVariantMap{{QStringLiteral("key"), QStringLiteral("model")}});
  });
  step(QStringLiteral("%1 no longer overrides the default model").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      return std::all_of(world.mc.members.cbegin(), world.mc.members.cend(),
                         [&](const QString& environment) { return overrideOn(world, c[0], environment).isUndefined(); });
    }, [&] { return describeDocuments(world); });
  });
  step(QStringLiteral("the default model shows the environment's value"), [](World& world, const Captures&, const Table&) {
    waitForModelRow(world, [](const QVariantMap& row) { return row.value(QStringLiteral("label")) == QStringLiteral("Claude · Opus") && !row.value(QStringLiteral("resettable")).toBool(); },
                    QStringLiteral("the environment's model without a reset"));
  });

  // Where a value comes from.
  step(QStringLiteral("%1 does not override the default model").arg(q), [](World& world, const Captures& c, const Table&) {
    // The environments set one; the project sets none.
    for (const QString& environment : world.mc.members) {
      expect(overrideOn(world, c[0], environment).isUndefined(), describeDocuments(world));
      saveOn(world.mc, environment, kModel, selection(QStringLiteral("opus")));
    }
  });
  step(QStringLiteral("the user asks where the default model comes from"), [](World& world, const Captures&, const Table&) {
    if (at(world.state(QStringLiteral("route")), QStringLiteral("section")) != QLatin1String("/settings/projects")) {
      openSection(world, QStringLiteral("/settings/projects"));
    }
    waitForModelRow(world, [](const QVariantMap& row) { return !row.value(QStringLiteral("models")).toList().isEmpty(); }, QStringLiteral("the default model row"));
    world.bridge().dispatch(QStringLiteral("projectSettings.inspect"), QVariantMap{{QStringLiteral("key"), QStringLiteral("model")}});
  });
  step(QStringLiteral("the project, environment, repository file and built-in default layers are listed in that order"), [](World& world, const Captures&, const Table&) {
    QStringList keys;
    for (const QVariant& layer : at(modelRow(world), QStringLiteral("inheritance.layers")).toList()) keys.append(at(layer, QStringLiteral("key")).toString());
    expect(keys == QStringList{QStringLiteral("project"), QStringLiteral("environment"), QStringLiteral("hal-c2.json"), QStringLiteral("built-in")},
           QStringLiteral("the layers are %1").arg(show(modelRow(world).value(QStringLiteral("inheritance")))));
  });
  step(QStringLiteral("the environment layer is marked as the one in effect"), [](World& world, const Captures&, const Table&) {
    QStringList inEffect;
    QString value;
    for (const QVariant& layer : at(modelRow(world), QStringLiteral("inheritance.layers")).toList()) {
      if (!at(layer, QStringLiteral("effective")).toBool()) continue;
      inEffect.append(at(layer, QStringLiteral("key")).toString());
      value = at(layer, QStringLiteral("value")).toString();
    }
    expect(inEffect == QStringList{QStringLiteral("environment")} && value == QStringLiteral("Claude · Opus"),
           QStringLiteral("the layers are %1").arg(show(modelRow(world).value(QStringLiteral("inheritance")))));
  });
  step(QStringLiteral("%1 overrides the default model on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    offerEverywhere(world, {QStringLiteral("Sonnet"), QStringLiteral("Opus")});
    settingsOf(world, c[1]).insert(kModel, selection(QStringLiteral("opus")));
    setOverride(world, c[0], c[1], selection(QStringLiteral("sonnet")));
    scoped(world).project = c[0];
  });
  step(QStringLiteral("%1 is listed as overriding it").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      const QVariantList overriding = at(modelRow(world), QStringLiteral("inheritance.overridingProjects")).toList();
      return overriding.size() == 1 && at(overriding.first(), QStringLiteral("title")) == c[0] && at(overriding.first(), QStringLiteral("value")) == QStringLiteral("Claude · Sonnet");
    }, [&] { return QStringLiteral("the row is %1").arg(show(modelRow(world))); });
  });
  step(QStringLiteral("the user resets the override for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap overriding = at(modelRow(world), QStringLiteral("inheritance.overridingProjects")).toList().value(0).toMap();
    expect(overriding.value(QStringLiteral("title")) == c[0], QStringLiteral("the row is %1").arg(show(modelRow(world))));
    world.bridge().dispatch(QStringLiteral("projectSettings.clearOverride"),
                            QVariantMap{{QStringLiteral("environmentId"), overriding.value(QStringLiteral("environmentId"))}, {QStringLiteral("projectId"), overriding.value(QStringLiteral("projectId"))}});
  });
  step(QStringLiteral("%1 uses the value from %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return overrideOn(world, c[0], c[1]).isUndefined() && at(modelRow(world), QStringLiteral("inheritance.overridingProjects")).toList().isEmpty(); },
                  [&] { return describeDocuments(world); });
    // The environment's own model is untouched, and is what the project now gets.
    expect(settingsOf(world, c[1]).value(kModel) == QJsonValue(selection(QStringLiteral("opus"))), describeDocuments(world));
  });

  // Environments that disagree.
  step(QStringLiteral("the default model differs between %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    offerEverywhere(world, {QStringLiteral("Sonnet"), QStringLiteral("Opus")});
    settingsOf(world, c[0]).insert(kModel, selection(QStringLiteral("sonnet")));
    settingsOf(world, c[1]).insert(kModel, selection(QStringLiteral("opus")));
  });
  step(QStringLiteral("the user looks at the default model"), [](World& world, const Captures&, const Table&) {
    openSection(world, QStringLiteral("/settings/projects"));
    waitForModelRow(world, [](const QVariantMap& row) { return !row.value(QStringLiteral("models")).toList().isEmpty(); }, QStringLiteral("the default model row"));
  });
  step(QStringLiteral("it shows as mixed across the selected environments"), [](World& world, const Captures&, const Table&) {
    waitForModelRow(world, [](const QVariantMap& row) { return row.value(QStringLiteral("mixed")).toBool() && row.value(QStringLiteral("label")) == QLatin1String("Mixed"); },
                    QStringLiteral("a mixed default model"));
  });
  step(QStringLiteral("the user chooses one model"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("projectSettings.model"), QVariantMap{{QStringLiteral("key"), kProvider + QStringLiteral(":opus")}});
  });
  step(QStringLiteral("every environment uses that model"), [](World& world, const Captures&, const Table&) {
    QStringList environments = world.mc.members;
    environments.append(world.mc.environmentId);
    world.waitFor([&] {
      return std::all_of(environments.cbegin(), environments.cend(),
                         [&](const QString& environment) { return settingsOf(world, environment).value(kModel) == QJsonValue(selection(QStringLiteral("opus"))); });
    }, [&] { return describeDocuments(world); });
    waitForModelRow(world, [](const QVariantMap& row) { return !row.value(QStringLiteral("mixed")).toBool() && row.value(QStringLiteral("label")) == QStringLiteral("Claude · Opus"); },
                    QStringLiteral("one default model"));
  });
  step(QStringLiteral("the model %1 is only available on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    // Of the feature's two machines; this one offers it too.
    offer(world, world.mc.environmentId, {QStringLiteral("Sonnet"), c[0]});
    for (const QString& environment : world.mc.members) {
      offer(world, environment, environment == c[1] ? QStringList{QStringLiteral("Sonnet"), c[0]} : QStringList{QStringLiteral("Sonnet")});
    }
  });
  step(QStringLiteral("the user tries to choose %1 as the default model").arg(q), [](World& world, const Captures& c, const Table&) {
    openSection(world, QStringLiteral("/settings/projects"));
    waitForModelRow(world, [&](const QVariantMap& row) {
      const QVariantList models = row.value(QStringLiteral("models")).toList();
      return std::any_of(models.cbegin(), models.cend(), [&](const QVariant& model) { return at(model, QStringLiteral("key")) == kProvider + QLatin1Char(':') + c[0]; });
    }, QStringLiteral("%1 to be offered").arg(c[0]));
    world.mc.part<int>() = writes(world);
    world.bridge().dispatch(QStringLiteral("projectSettings.model"), QVariantMap{{QStringLiteral("key"), kProvider + QLatin1Char(':') + c[0]}});
  });
  const auto toastSaying = [](World& world, const QString& text) {
    world.waitFor([&] {
      for (const QVariant& toast : at(world.state(QStringLiteral("toasts")), QStringLiteral("items")).toList()) {
        if (at(toast, QStringLiteral("title")) == QLatin1String("Default model not saved") && at(toast, QStringLiteral("description")).toString().contains(text)) return true;
      }
      return false;
    }, [&] { return QStringLiteral("\"%1\"; the shell shows %2").arg(text, show(world.state(QStringLiteral("toasts")))); });
  };
  step(QStringLiteral("the user is told the model is unavailable on %1").arg(q), [toastSaying](World& world, const Captures& c, const Table&) {
    toastSaying(world, QStringLiteral("This model is unavailable on %1.").arg(c[0]));
    world.sync();
    expect(writes(world) == world.mc.part<int>(), describeDocuments(world));
  });
  step(QStringLiteral("is told to select that environment to choose its model separately"), [toastSaying](World& world, const Captures&, const Table&) {
    toastSaying(world, QStringLiteral("Select that environment to choose its model separately."));
  });

  // Sections and their titles (search-and-navigation.feature).
  step(QStringLiteral("the user opens (the Keybindings section|the Appearance section|the Integrations section|diagnostics|the open source licenses page)"),
       [](World& world, const Captures& c, const Table&) {
         static const QHash<QString, QString> sections{
             {QStringLiteral("the Keybindings section"), QStringLiteral("/settings/keybindings")},
             {QStringLiteral("the Appearance section"), QStringLiteral("/settings/appearance")},
             {QStringLiteral("the Integrations section"), QStringLiteral("/settings/integrations")},
             {QStringLiteral("diagnostics"), QStringLiteral("/settings/diagnostics")},
             {QStringLiteral("the open source licenses page"), QStringLiteral("/settings/open-source-licenses")},
         };
         // General asks where settings apply, before the user moves on.
         if (world.shellSubscriptions() > 0 && scoped(world).project.isEmpty()) {
           world.waitFor([&] { return asksWhere(world); }, QStringLiteral("General to say where settings apply"));
         }
         openSection(world, sections.value(c[0]));
       });
  step(QStringLiteral("the page is titled %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return breadcrumb(world)->isVisible() && breadcrumb(world)->property("text") == c[0]; },
                  [&] { return QStringLiteral("the page is titled \"%1\"").arg(breadcrumb(world)->property("text").toString()); });
  });
  step(QStringLiteral("the page does not offer a choice of project or environment"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return breadcrumb(world)->property("text") == QLatin1String("Settings / Appearance"); }, QStringLiteral("the Appearance page"));
    expect(!asksWhere(world), QStringLiteral("the page asks where settings apply"));
  });
  step(QStringLiteral("settings still apply to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(scope(world).value(QStringLiteral("kind")) == QLatin1String("project") && scope(world).value(QStringLiteral("projectLabel")) == c[0],
           QStringLiteral("the scope is %1").arg(show(scope(world))));
    // And the page says so.
    Brick& brick = settingsShell(world);
    world.waitFor([&] { return asksWhere(world) && brick.item(QStringLiteral("scopeProject"))->property("displayText") == c[0]; },
                  QStringLiteral("the page to name the project"));
  });
});

}  // namespace
