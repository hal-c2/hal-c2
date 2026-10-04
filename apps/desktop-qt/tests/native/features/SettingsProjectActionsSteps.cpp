// Settings → Project, Actions (ProjectActionsController,
// features/settings/project-actions.feature): the environment's default
// actions and a project's own list in the MC's settings document, what each
// project then offers to run, and hal-c2.json's actions read from the checkout.

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QQuickItem>

#include "Brick.h"
#include "FakeConfig.h"
#include "FakeFiles.h"
#include "Harness.h"
#include "NavigationController.h"
#include "SettingsScopeController.h"
#include "SettingsShell.h"
#include "World.h"

namespace {

const QString kScripts = QStringLiteral("defaultProjectScripts");
const QString kOverrides = QStringLiteral("projectSettingsOverrides");
const QString kServer = QStringLiteral("server");
const QString kRepository = QStringLiteral("github.com/acme/shop");

QJsonObject script(const QString& name, const QString& command, bool setup = false, const QString& previewUrl = {}) {
  QJsonObject action{{QStringLiteral("id"), name.toLower()}, {QStringLiteral("name"), name}, {QStringLiteral("command"), command},
                     {QStringLiteral("icon"), QStringLiteral("play")}, {QStringLiteral("runOnWorktreeCreate"), setup}};
  if (!previewUrl.isEmpty()) action.insert(QStringLiteral("previewUrl"), previewUrl);
  return action;
}

QVariantMap panel(World& world) {
  return world.state(QStringLiteral("projectActions")).toMap();
}

QVariantMap scopeState(World& world) {
  return world.state(QStringLiteral("settingsScope")).toMap();
}

SettingsScopeController* scope(World& world) {
  return world.native().controller<SettingsScopeController>();
}

QStringList names(const QVariantList& actions) {
  QStringList result;
  for (const QVariant& action : actions) result.append(at(action, QStringLiteral("name")).toString());
  return result;
}

QStringList names(const QJsonArray& actions) {
  return names(actions.toVariantList());
}

QString describe(World& world) {
  return QStringLiteral("the Actions panel is %1; the MC holds %2").arg(show(panel(world)), show(fakeConfig(world.mc).settings.toVariantMap()));
}

QJsonArray overrideOf(const QJsonObject& settings, const QString& project) {
  return settings.value(kOverrides).toObject().value(project).toObject().value(kScripts).toArray();
}

bool hasOverride(const QJsonObject& settings, const QString& project) {
  return settings.value(kOverrides).toObject().value(project).toObject().contains(kScripts);
}

void setOverride(World& world, const QString& project, const QJsonArray& scripts) {
  QJsonObject overrides = fakeConfig(world.mc).settings.value(kOverrides).toObject();
  overrides.insert(project, QJsonObject{{kScripts, scripts}});
  saveOn(world.mc, world.mc.environmentId, kOverrides, overrides);
}

QJsonObject withCapabilities(QJsonObject config, bool overrides) {
  QJsonObject environment = config.value(QLatin1String("environment")).toObject();
  environment.insert(QStringLiteral("capabilities"), QJsonObject{{kOverrides, overrides}});
  config.insert(QStringLiteral("environment"), environment);
  return config;
}

// This machine's MC keeps project overrides, as its config says.
void announceOverrides(World& world) {
  FakeConfig& fake = fakeConfig(world.mc);
  fake.config = withCapabilities(fake.config, true);
  QJsonObject config = fake.config;
  config.insert(QStringLiteral("settings"), fake.settings);
  for (const int id : world.mc.subscribers(QStringLiteral("config"))) {
    if (world.mc.shapeOf(id).value(QLatin1String("environment")) != world.mc.environmentId) continue;
    world.mc.send({{QStringLiteral("t"), QStringLiteral("config")}, {QStringLiteral("id"), id}, {QStringLiteral("mc"), world.mc.name}, {QStringLiteral("config"), config}});
  }
  world.sync();
}

// The page's own words, as the brick draws them.
QQuickItem* drawn(World& world, const QString& name) {
  Brick& brick = settingsShell(world, QSize(900, 2000));
  brick.grab();
  return brick.item(name);
}

// Settings → Project, on all projects or on `project`.
void openActions(World& world, const QString& project = {}) {
  // FilesActionsSteps' words for the thread's details, as this page shows them.
  world.onSettingsPage.insert(QStringLiteral("hasAction"), [&world](const QStringList& c) {
    world.waitFor([&] {
      const QJsonArray own = overrideOf(fakeConfig(world.mc).settings, c[0]);
      return names(own) == QStringList{c[1]} && own.first().toObject().value(QLatin1String("command")) == QLatin1String("bun lint") &&
             names(panel(world).value(QStringLiteral("scripts")).toList()) == QStringList{c[1]} && panel(world).value(QStringLiteral("imports")).toList().isEmpty();
    }, [&] { return describe(world); });
  });
  world.onSettingsPage.insert(QStringLiteral("invalidProjectFile"), [&world](const QStringList&) {
    world.waitFor([&] { return panel(world).value(QStringLiteral("file")) == QLatin1String("invalid"); }, [&] { return describe(world); });
    const QQuickItem* note = drawn(world, QStringLiteral("invalidFile"));
    expect(note->isVisible() && note->property("text").toString().startsWith(QLatin1String("hal-c2.json is invalid")), QStringLiteral("the page does not warn"));
  });
  world.native().controller<NavigationController>()->open(NavigationController::Route::settings(QStringLiteral("/settings/projects")));
  world.waitFor([&] { return panel(world).value(QStringLiteral("settings")).toBool() && !scopeState(world).isEmpty(); }, [&] { return describe(world); });
  announceOverrides(world);
  QString key;
  if (!project.isEmpty()) {
    world.waitFor([&] {
      for (const QVariant& row : scopeState(world).value(QStringLiteral("projects")).toList()) {
        if (at(row, QStringLiteral("title")) == project) key = at(row, QStringLiteral("key")).toString();
      }
      return !key.isEmpty();
    }, [&] { return QStringLiteral("%1 to be offered; the scope is %2").arg(project, show(scopeState(world))); });
  }
  world.bridge().dispatch(QStringLiteral("settingsScope.project"), QVariantMap{{QStringLiteral("key"), key}});
  world.bridge().dispatch(QStringLiteral("settingsScope.environment"), QVariantMap{{QStringLiteral("id"), QString()}});
  world.waitFor([&] { return panel(world).value(QStringLiteral("project")).toBool() == !project.isEmpty() && panel(world).value(QStringLiteral("available")).toBool(); },
                [&] { return describe(world); });
}

void add(World& world, const QString& name, const QString& command) {
  world.bridge().dispatch(QStringLiteral("projectActions.add"), QVariantMap{{QStringLiteral("name"), name}, {QStringLiteral("command"), command}});
}

// Another project on this machine, with `own` actions if any.
void addProject(World& world, const QString& project, const QJsonArray& own = {}) {
  world.mc.projects.insert(project, {{QStringLiteral("id"), project}, {QStringLiteral("title"), project},
                                       {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + project}, {QStringLiteral("scripts"), own}});
  world.mc.sendRow(project, world.mc.projects.value(project), QStringLiteral("project"));
  world.sync();
}

// What a new thread in `project` offers to run (the header's actions).
QStringList offered(World& world, const QString& project) {
  world.startNewThread(QVariantMap{{QStringLiteral("projectKey"), world.projectKey(project)}});
  world.waitFor([&] {
    const QVariantMap workspace = world.state(QStringLiteral("workspace")).toMap();
    return workspace.value(QStringLiteral("isDraft")).toBool() && workspace.value(QStringLiteral("projectRoot")) == QStringLiteral("/work/") + project;
  }, [&] { return QStringLiteral("a new thread in %1; the header shows %2").arg(project, show(world.state(QStringLiteral("workspace")))); });
  return names(world.state(QStringLiteral("workspace")).toMap().value(QStringLiteral("scripts")).toList());
}

void expectOffered(World& world, const QString& project, const QStringList& wanted) {
  QStringList shown;
  world.waitFor([&] { return (shown = offered(world, project)) == wanted; },
                [&] { return QStringLiteral("%1 to offer %2; it offers %3").arg(project, wanted.join(QStringLiteral(", ")), shown.join(QStringLiteral(", "))); });
}

bool told(World& world, const QString& title) {
  for (const QVariant& toast : at(world.state(QStringLiteral("toasts")), QStringLiteral("items")).toList()) {
    if (at(toast, QStringLiteral("title")) == title) return true;
  }
  return false;
}

void expectTold(World& world, const QString& title) {
  world.waitFor([&] { return told(world, title); },
                [&] { return QStringLiteral("\"%1\"; the shell shows %2").arg(title, show(world.state(QStringLiteral("toasts")))); });
}

const QJsonArray kDev{script(QStringLiteral("Dev"), QStringLiteral("bun dev"))};

const Steps steps([] {
  const QString q = kQuoted;

  // The environment's defaults.
  step(QStringLiteral("%1 has no default actions").arg(q), [](World& world, const Captures&, const Table&) {
    expect(!fakeConfig(world.mc).settings.contains(kScripts), describe(world));
  });
  step(QStringLiteral("the user opens the Actions settings for all projects"), [](World& world, const Captures&, const Table&) { openActions(world); });
  step(QStringLiteral("the user is told no actions are configured"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return panel(world).value(QStringLiteral("scripts")).toList().isEmpty(); }, [&] { return describe(world); });
    expect(drawn(world, QStringLiteral("noActions"))->isVisible() && settingsShell(world).shows(QStringLiteral("No actions configured.")),
           QStringLiteral("the page does not say so"));
  });
  step(QStringLiteral("the user adds the default action %1 running %1 for all projects").arg(q), [](World& world, const Captures& c, const Table&) {
    openActions(world);
    add(world, c[0], c[1]);
    world.waitFor([&] { return names(fakeConfig(world.mc).settings.value(kScripts).toArray()) == QStringList{c[0]}; }, [&] { return describe(world); });
  });
  step(QStringLiteral("%1 is offered in every project on %1 that has no actions of its own").arg(q), [](World& world, const Captures& c, const Table&) {
    addProject(world, QStringLiteral("docs"));
    addProject(world, QStringLiteral("tools"), QJsonArray{script(QStringLiteral("Lint"), QStringLiteral("bun lint"))});
    expectOffered(world, QStringLiteral("shop"), {c[0]});
    expectOffered(world, QStringLiteral("docs"), {c[0]});
    // A project with its own keeps them.
    expectOffered(world, QStringLiteral("tools"), {QStringLiteral("Lint")});
  });
  step(QStringLiteral("%1 has the default action %1").arg(q), [](World& world, const Captures& c, const Table&) {
    saveOn(world.mc, world.mc.environmentId, kScripts, QJsonArray{script(c[1], QStringLiteral("bun dev"))});
  });

  // A project's own.
  step(QStringLiteral("the user picks %1 and adds the action %1").arg(q), [](World& world, const Captures& c, const Table&) {
    openActions(world, c[0]);
    add(world, c[1], QStringLiteral("bun storybook"));
  });
  step(QStringLiteral("%1 offers its own list with %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return names(overrideOf(fakeConfig(world.mc).settings, c[0])) == QStringList{c[1], c[2]} && panel(world).value(QStringLiteral("own")).toBool(); },
                  [&] { return describe(world); });
    expectOffered(world, c[0], {c[1], c[2]});
  });
  step(QStringLiteral("other projects still offer only %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(names(fakeConfig(world.mc).settings.value(kScripts).toArray()) == QStringList{c[0]}, describe(world));
    addProject(world, QStringLiteral("docs"));
    expectOffered(world, QStringLiteral("docs"), {c[0]});
  });
  step(QStringLiteral("%1 has its own actions").arg(q), [](World& world, const Captures& c, const Table&) {
    saveOn(world.mc, world.mc.environmentId, kScripts, kDev);
    setOverride(world, c[0], QJsonArray{script(QStringLiteral("Lint"), QStringLiteral("bun lint"))});
  });
  step(QStringLiteral("the user resets the actions of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    openActions(world, c[0]);
    world.waitFor([&] { return panel(world).value(QStringLiteral("own")).toBool() && names(panel(world).value(QStringLiteral("scripts")).toList()) == QStringList{QStringLiteral("Lint")}; },
                  [&] { return describe(world); });
    world.bridge().dispatch(QStringLiteral("projectActions.reset"), QVariantMap());
  });
  step(QStringLiteral("%1 offers the default actions of %1 again").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return !hasOverride(fakeConfig(world.mc).settings, c[0]) && !panel(world).value(QStringLiteral("own")).toBool(); },
                  [&] { return describe(world); });
    expectOffered(world, c[0], {QStringLiteral("Dev")});
  });

  // What the list marks.
  step(QStringLiteral("%1 has the setup action %1 and the action %1 with a preview address").arg(q), [](World& world, const Captures& c, const Table&) {
    setOverride(world, c[0], QJsonArray{script(c[1], QStringLiteral("bun install"), true), script(c[2], QStringLiteral("bun dev"), false, QStringLiteral("http://localhost:3000"))});
  });
  step(QStringLiteral("the user opens the Actions settings for %1").arg(q), [](World& world, const Captures& c, const Table&) { openActions(world, c[0]); });
  step(QStringLiteral("%1 is marked as the setup action").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return names(panel(world).value(QStringLiteral("scripts")).toList()).contains(c[0]); }, [&] { return describe(world); });
    const QQuickItem* row = drawn(world, QStringLiteral("action:") + c[0].toLower());
    const QQuickItem* tag = row->findChild<QQuickItem*>(QStringLiteral("setup"));
    expect(tag && tag->isVisible() && tag->property("text") == QLatin1String("setup"), QStringLiteral("%1 has no setup mark").arg(c[0]));
  });
  step(QStringLiteral("%1 is marked as having a preview on desktop only").arg(q), [](World& world, const Captures& c, const Table&) {
    const QQuickItem* row = drawn(world, QStringLiteral("action:") + c[0].toLower());
    const QQuickItem* tag = row->findChild<QQuickItem*>(QStringLiteral("preview"));
    expect(tag && tag->isVisible() && tag->property("text") == QStringLiteral("preview · desktop only"), QStringLiteral("%1 has no preview mark").arg(c[0]));
    // Only it, and only it is not the setup action.
    const QQuickItem* setup = row->findChild<QQuickItem*>(QStringLiteral("setup"));
    expect(setup && !setup->isVisible(), QStringLiteral("%1 is marked as the setup action").arg(c[0]));
  });

  // hal-c2.json.
  step(QStringLiteral("the checkout's hal-c2.json declares the action %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject file{{QStringLiteral("scripts"), QJsonArray{QJsonObject{{QStringLiteral("name"), c[0]}, {QStringLiteral("command"), QStringLiteral("bun lint")}}}}};
    fakeFiles(world.mc).files.insert(QStringLiteral("hal-c2.json"), QString::fromUtf8(QJsonDocument(file).toJson()));
  });
  step(QStringLiteral("the user imports the actions of %1 from hal-c2.json").arg(q), [](World& world, const Captures& c, const Table&) {
    openActions(world, c[0]);
    world.waitFor([&] { return names(panel(world).value(QStringLiteral("imports")).toList()) == QStringList{QStringLiteral("Lint")}; }, [&] { return describe(world); });
    world.bridge().dispatch(QStringLiteral("projectActions.import"), QVariantMap{{QStringLiteral("name"), QStringLiteral("Lint")}});
  });
  step(QStringLiteral("the checkout's hal-c2.json is invalid"), [](World& world, const Captures&, const Table&) {
    fakeFiles(world.mc).files.insert(QStringLiteral("hal-c2.json"), QStringLiteral("{ \"scripts\": [ { \"name\": \"Lint\" "));
  });

  // Several environments.
  step(QStringLiteral("their default actions differ"), [](World& world, const Captures&, const Table&) {
    saveOn(world.mc, world.mc.environmentId, kScripts, kDev);
    saveOn(world.mc, world.mc.linked.first(), kScripts, QJsonArray{script(QStringLiteral("Test"), QStringLiteral("bun test"))});
  });
  step(QStringLiteral("the user opens the Actions settings"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return panel(world).value(QStringLiteral("settings")).toBool(); }, [&] { return describe(world); });
  });
  step(QStringLiteral("the user is told the environments have different actions"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return panel(world).value(QStringLiteral("mixed")).toBool(); }, [&] { return describe(world); });
    const QQuickItem* note = drawn(world, QStringLiteral("mixedActions"));
    expect(note->isVisible() && note->property("text").toString().startsWith(QLatin1String("Different actions across environments.")),
           QStringLiteral("the page does not say the environments differ"));
  });

  // Saves that do not land.
  step(QStringLiteral("no connected environment can take the change"), [](World& world, const Captures&, const Table&) {
    openActions(world);
    world.mc.stopAccepting();
    world.mc.drop();
    world.waitFor([&world] { return !world.native().client()->isReady(); }, QStringLiteral("the shell to see the drop"));
    world.waitFor([&] { return !panel(world).value(QStringLiteral("available"), true).toBool(); }, [&] { return describe(world); });
  });
  step(QStringLiteral("the user adds a default action"), [](World& world, const Captures&, const Table&) {
    if (!panel(world).value(QStringLiteral("settings")).toBool()) openActions(world);
    add(world, QStringLiteral("Dev"), QStringLiteral("bun dev"));
  });
  step(QStringLiteral("the user is told the actions were not saved"), [](World& world, const Captures&, const Table&) {
    expectTold(world, QStringLiteral("Actions not saved"));
    expect(fakeConfig(world.mc).writes.isEmpty(), describe(world));
  });
  step(QStringLiteral("%1 rejects the settings change").arg(q), [](World& world, const Captures&, const Table&) {
    fakeConfig(world.mc).refuseWrites = QStringLiteral("disk full");
  });
  step(QStringLiteral("the user is told the project actions failed to save"), [](World& world, const Captures&, const Table&) {
    expectTold(world, QStringLiteral("Failed to save project actions"));
    expect(!fakeConfig(world.mc).settings.contains(kScripts) && panel(world).value(QStringLiteral("scripts")).toList().isEmpty(), describe(world));
  });

  // An environment too old for project overrides.
  step(QStringLiteral("%1 runs a server without project overrides").arg(q), [](World& world, const Captures& c, const Table&) {
    // The same repository on both, so "shop" is one project with two checkouts.
    QJsonObject local = world.mc.projects.value(QStringLiteral("shop"));
    local.insert(QStringLiteral("repositoryIdentity"), QJsonObject{{QStringLiteral("canonicalKey"), kRepository}, {QStringLiteral("name"), QStringLiteral("shop")}});
    world.mc.projects.insert(QStringLiteral("shop"), local);
    world.mc.sendRow(QStringLiteral("shop"), local, QStringLiteral("project"));
    FakeConfig& fake = fakeConfig(world.mc);
    fake.elsewhere.insert(c[0], withCapabilities({}, false));
    documentOf(world.mc, c[0]);
    world.mc.linkLabels.insert(c[0], c[0]);
    world.mc.link(c[0]);
    QJsonObject remote = local;
    remote.insert(QStringLiteral("id"), QStringLiteral("shop-server"));
    world.mc.sendLinkRow(c[0], QStringLiteral("shop-server"), remote, QStringLiteral("project"));
    world.sync();
  });
  step(QStringLiteral("the user picks %1 in the Actions settings").arg(q), [](World& world, const Captures& c, const Table&) {
    openActions(world, c[0]);
    world.waitFor([&] { return scope(world)->targets().size() == 2 && scope(world)->settings(kServer).has_value(); },
                  [&] { return QStringLiteral("both checkouts in the scope; it is %1").arg(show(scopeState(world))); });
  });
  step(QStringLiteral("changes apply only to environments that support project overrides"), [](World& world, const Captures&, const Table&) {
    add(world, QStringLiteral("Dev"), QStringLiteral("bun dev"));
    world.waitFor([&] { return names(overrideOf(fakeConfig(world.mc).settings, QStringLiteral("shop"))) == QStringList{QStringLiteral("Dev")}; }, [&] { return describe(world); });
    world.sync();
    const FakeConfig::Document& server = documentOf(world.mc, kServer);
    expect(server.version == 0 && server.settings.isEmpty(), QStringLiteral("%1 was written %2").arg(kServer, show(server.settings.toVariantMap())));
    expect(!told(world, QStringLiteral("Failed to save project actions")), QStringLiteral("a failure was reported: %1").arg(show(world.state(QStringLiteral("toasts")))));
  });
});

}  // namespace
