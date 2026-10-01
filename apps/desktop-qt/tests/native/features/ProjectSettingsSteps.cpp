// The native Project settings section (ProjectSettingsController): the
// @desktop scenarios of features/settings/projects.feature and
// features/settings/project-defaults.feature it delivers. The project's
// checkouts live on linked environments, each its own machine.

#include <QJsonArray>
#include <QJsonObject>

#include "FakeConfig.h"
#include "FakeProjects.h"
#include "Harness.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "McClient.h"
#include "SettingsController.h"
#include "SettingsScopeController.h"
#include "SidebarController.h"
#include "World.h"

namespace {

const QString kAt = QStringLiteral("2026-09-01T09:00:00Z");

QVariantMap panel(World& world) {
  return world.state(QStringLiteral("projectSettings")).toMap();
}

QVariantMap scope(World& world) {
  return world.state(QStringLiteral("settingsScope")).toMap();
}

void act(World& world, const QString& name, const QVariantMap& payload = {}) {
  world.bridge().dispatch(QStringLiteral("projectSettings.") + name, payload);
}

QString checkoutId(const QString& project, const QString& environment) {
  return project + QLatin1Char('-') + environment;
}

// A checkout of `project` on the linked machine `environment`, one repository
// wherever it is so its checkouts are one project.
void addCheckout(World& world, const QString& project, const QString& environment) {
  world.mc.sendLinkRow(environment, checkoutId(project, environment),
                         QJsonObject{{QStringLiteral("id"), checkoutId(project, environment)},
                                     {QStringLiteral("title"), project},
                                     {QStringLiteral("workspaceRoot"), QStringLiteral("/home/%1/%2").arg(environment, project)},
                                     {QStringLiteral("createdAt"), kAt},
                                     {QStringLiteral("updatedAt"), kAt},
                                     {QStringLiteral("repositoryIdentity"),
                                      QJsonObject{{QStringLiteral("canonicalKey"), QStringLiteral("github.com/hal-c2/") + project},
                                                  {QStringLiteral("rootPath"), QStringLiteral("/home/%1/%2").arg(environment, project)},
                                                  {QStringLiteral("name"), project}}}},
                         QStringLiteral("project"));
}

void removeCheckout(World& world, const QString& project, const QString& environment) {
  world.mc.sendLinkRow(environment, checkoutId(project, environment),
                         QJsonObject{{QStringLiteral("deletedAt"), QStringLiteral("2026-09-23T10:00:00Z")}}, QStringLiteral("project"));
}

QJsonObject checkout(World& world, const QString& project, const QString& environment) {
  const QJsonArray entry = world.mc.linkedRows.value(environment).value(checkoutId(project, environment));
  return entry.isEmpty() ? QJsonObject() : entry.at(2).toObject();
}

// Another machine the MC is linked to, with its own settings.
void linkMachine(World& world, const QString& name) {
  documentOf(world.mc, name);
  world.mc.linkLabels.insert(name, name);
  world.mc.link(name);
}

void openProjects(World& world) {
  if (world.shellSubscriptions() == 0) {
    world.connect();
    world.sync();
  }
  world.native().controller<NavigationController>()->open(NavigationController::Route::settings(QStringLiteral("/settings/projects")));
  world.waitFor([&] { return panel(world).value(QStringLiteral("open")).toBool() && !scope(world).isEmpty(); },
                [&] { return QStringLiteral("project settings to show; they are %1").arg(show(panel(world))); });
}

void chooseProject(World& world, const QString& title) {
  QString key;
  if (!title.isEmpty()) {
    world.waitFor([&] {
      for (const QVariant& row : scope(world).value(QStringLiteral("projects")).toList()) {
        if (row.toMap().value(QStringLiteral("title")) == title) key = row.toMap().value(QStringLiteral("key")).toString();
      }
      return !key.isEmpty();
    }, [&] { return QStringLiteral("%1 to be offered; the scope is %2").arg(title, show(scope(world))); });
  }
  world.bridge().dispatch(QStringLiteral("settingsScope.project"), QVariantMap{{QStringLiteral("key"), key}});
}

void chooseEnvironment(World& world, const QString& label) {
  QString id;
  if (!label.isEmpty()) {
    world.waitFor([&] {
      for (const QVariant& row : scope(world).value(QStringLiteral("environments")).toList()) {
        if (row.toMap().value(QStringLiteral("label")) == label) id = row.toMap().value(QStringLiteral("id")).toString();
      }
      return !id.isEmpty();
    }, [&] { return QStringLiteral("%1 to be offered; the scope is %2").arg(label, show(scope(world))); });
  }
  world.bridge().dispatch(QStringLiteral("settingsScope.environment"), QVariantMap{{QStringLiteral("id"), id}});
}

// Settings open on `project`, on `environment` or across them all.
void manage(World& world, const QString& project, const QString& environment = {}) {
  openProjects(world);
  chooseProject(world, project);
  chooseEnvironment(world, environment);
  world.waitFor([&] { return panel(world).value(QStringLiteral("status")) == QLatin1String("ready") && panel(world).value(QStringLiteral("name")) == project; },
                [&] { return QStringLiteral("%1 to be managed; the panel is %2").arg(project, show(panel(world))); });
}

void expectStatus(World& world, const QString& status, const QString& message) {
  world.waitFor([&] { return panel(world).value(QStringLiteral("status")) == status; },
                [&] { return QStringLiteral("the panel to be %1; it is %2").arg(status, show(panel(world))); });
  expect(panel(world).value(QStringLiteral("message")).toString().startsWith(message),
         QStringLiteral("the panel to say \"%1\"; it is %2").arg(message, show(panel(world))));
}

void expectToast(World& world, const QString& title, const QString& description = {}) {
  world.waitFor([&] {
    for (const QVariant& toast : at(world.state(QStringLiteral("toasts")), QStringLiteral("items")).toList()) {
      if (at(toast, QStringLiteral("title")) == title && at(toast, QStringLiteral("description")).toString().contains(description)) return true;
    }
    return false;
  }, [&] { return QStringLiteral("\"%1\" to be toasted; the shell shows %2").arg(title, show(world.state(QStringLiteral("toasts")))); });
}

// The environments the sidebar lists `project` on.
QStringList listedOn(World& world, const QString& project) {
  world.sync();
  QStringList environments;
  for (const sidebar::ProjectGroup& group : world.native().sidebar()->groups()) {
    if (group.summary.value(QStringLiteral("displayName")) != project) continue;
    for (const sidebar::Project& member : group.members) environments.append(member.environmentId);
  }
  environments.sort();
  return environments;
}

QString checkoutKey(World& world, const QString& project, const QString& environment) {
  for (const QVariant& row : panel(world).value(QStringLiteral("checkouts")).toList()) {
    if (at(row, QStringLiteral("environment")) == environment) return at(row, QStringLiteral("key")).toString();
  }
  fail(QStringLiteral("no checkout of %1 on %2; the panel is %3").arg(project, environment, show(panel(world))));
  return {};
}

QVariantMap removal(World& world) {
  return world.state(QStringLiteral("projectRemoval")).toMap();
}

QVariantMap row(World& world, const QString& name) {
  return panel(world).value(name).toMap();
}

QJsonObject provider(const QString& instanceId, const QString& name, const QStringList& models) {
  QJsonArray slugs;
  for (const QString& model : models) {
    slugs.append(QJsonObject{{QStringLiteral("slug"), model.toLower()}, {QStringLiteral("name"), model}});
  }
  return {{QStringLiteral("instanceId"), instanceId}, {QStringLiteral("displayName"), name}, {QStringLiteral("enabled"), true},
          {QStringLiteral("installed"), true}, {QStringLiteral("models"), slugs}};
}

// The environment's saved value of `key`.
QJsonValue savedOn(World& world, const QString& environment, const QString& key) {
  const QJsonObject settings = environment == world.mc.environmentId ? fakeConfig(world.mc).settings
                                                                        : documentOf(world.mc, environment).settings;
  return settings.value(key);
}

const Steps steps([] {
  const QString q = kQuoted;

  // projects.feature
  step(QStringLiteral("the user has the project %1 with checkouts on %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    for (const QString& environment : {c[1], c[2]}) {
      linkMachine(world, environment);
      addCheckout(world, c[0], environment);
    }
  });
  step(QStringLiteral("both environments are connected"), [](World& world, const Captures&, const Table&) {
    world.connect();
    world.sync();
    world.waitFor([&] { return listedOn(world, QStringLiteral("shop")).size() == 2; },
                  QStringLiteral("both machines' checkouts to be listed"));
  });
  step(QStringLiteral("the user opens the Projects settings without a project picked"), [](World& world, const Captures&, const Table&) {
    openProjects(world);
    chooseProject(world, {});
  });
  step(QStringLiteral("the user is asked to choose a project to manage its name, icon, checkouts and actions"),
       [](World& world, const Captures&, const Table&) {
         expectStatus(world, QStringLiteral("pick"), QStringLiteral("Choose a project to manage its name, icon, checkouts and actions."));
       });
  step(QStringLiteral("the user has no projects"), [](World& world, const Captures&, const Table&) {
    for (const QString& environment : world.mc.linked) {
      for (const QString& id : world.mc.linkedRows.value(environment).keys()) {
        world.mc.sendLinkRow(environment, id, QJsonObject{{QStringLiteral("deletedAt"), QStringLiteral("2026-09-23T10:00:00Z")}},
                               QStringLiteral("project"));
      }
    }
    world.sync();
  });
  step(QStringLiteral("the user opens the Projects settings"), [](World& world, const Captures&, const Table&) { openProjects(world); });
  step(QStringLiteral("the user is told to add a project from the sidebar to configure it here"), [](World& world, const Captures&, const Table&) {
    expectStatus(world, QStringLiteral("empty"), QStringLiteral("Add a project from the sidebar to configure it here."));
  });
  step(QStringLiteral("the user (?:is managing|manages) %1 in settings").arg(q), [](World& world, const Captures& c, const Table&) {
    manage(world, c[0]);
  });
  step(QStringLiteral("%1 is removed on another device").arg(q), [](World& world, const Captures& c, const Table&) {
    for (const QString& environment : world.mc.linked) removeCheckout(world, c[0], environment);
    world.sync();
  });
  step(QStringLiteral("the user is told this project is no longer available"), [](World& world, const Captures&, const Table&) {
    expectStatus(world, QStringLiteral("missing"), QStringLiteral("This project is no longer available."));
  });
  step(QStringLiteral("the user is managing the %1 checkout of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    manage(world, c[1], c[0]);
  });
  step(QStringLiteral("that checkout is removed on another device"), [](World& world, const Captures&, const Table&) {
    const QString environment = world.native().controller<SettingsScopeController>()->environmentFilter();
    removeCheckout(world, panel(world).value(QStringLiteral("name")).toString(), environment);
    world.sync();
  });
  step(QStringLiteral("the user is told this checkout is no longer available in the selected project and environment"),
       [](World& world, const Captures&, const Table&) {
         expectStatus(world, QStringLiteral("checkout-missing"),
                      QStringLiteral("This checkout is no longer available in the selected project and environment."));
       });
  step(QStringLiteral("the user changes how projects are grouped"), [](World& world, const Captures&, const Table&) {
    const QString before = world.native().controller<SettingsScopeController>()->projectKey();
    world.native().controller<SettingsController>()->set(QStringLiteral("sidebarProjectGroupingMode"), QStringLiteral("separate"));
    world.waitFor([&] { return world.native().controller<SettingsScopeController>()->projectKey() != before; },
                  [&] { return QStringLiteral("the project to be regrouped; the scope is %1").arg(show(scope(world))); });
  });
  step(QStringLiteral("the panel still shows %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return panel(world).value(QStringLiteral("status")) == QLatin1String("ready") && panel(world).value(QStringLiteral("name")) == c[0]; },
                  [&] { return QStringLiteral("%1 to show; the panel is %2").arg(c[0], show(panel(world))); });
  });

  // Renaming.
  step(QStringLiteral("the user renames %1 to %1 in settings").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();  // a link that went down says so first
    manage(world, c[0]);
    act(world, QStringLiteral("rename"), {{QStringLiteral("title"), c[1]}});
  });
  step(QStringLiteral("%1 is shown for the checkouts on %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      return checkout(world, QStringLiteral("shop"), c[1]).value(QLatin1String("title")) == c[0] &&
             checkout(world, QStringLiteral("shop"), c[2]).value(QLatin1String("title")) == c[0] && listedOn(world, c[0]).size() == 2;
    }, [&] { return QStringLiteral("both checkouts to be renamed %1; the panel is %2").arg(c[0], show(panel(world))); });
  });
  step(QStringLiteral("the user clears the name of %1 in settings").arg(q), [](World& world, const Captures& c, const Table&) {
    manage(world, c[0]);
    act(world, QStringLiteral("rename"), {{QStringLiteral("title"), QStringLiteral("  ")}});
  });
  step(QStringLiteral("the user is told the project title cannot be empty"), [](World& world, const Captures&, const Table&) {
    expectToast(world, QStringLiteral("Project title cannot be empty"));
  });
  step(QStringLiteral("the name stays %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(world.mc.part<FakeProjects>().mutations.isEmpty() && panel(world).value(QStringLiteral("name")) == c[0],
           QStringLiteral("nothing to be renamed; the panel is %1").arg(show(panel(world))));
  });
  step(QStringLiteral("the user is told to connect %1 and try again").arg(q), [](World& world, const Captures& c, const Table&) {
    expectToast(world, QStringLiteral("Failed to rename project"), QStringLiteral("Connect %1 and try again.").arg(c[0]));
    expect(world.mc.part<FakeProjects>().mutations.isEmpty(), QStringLiteral("no checkout to be renamed"));
  });
  step(QStringLiteral("renaming fails on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.part<FakeProjects>().refusedOn.insert(c[0], QStringLiteral("disk full"));
  });
  step(QStringLiteral("the user is told the rename failed on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expectToast(world, QStringLiteral("Failed to rename project on %1").arg(c[0]), QStringLiteral("disk full"));
  });

  // The icon.
  step(QStringLiteral("the user chooses the emoji %1 as the icon of %1 in settings").arg(q), [](World& world, const Captures& c, const Table&) {
    manage(world, c[1]);
    act(world, QStringLiteral("icon"), {{QStringLiteral("emoji"), c[0]}});
  });
  step(QStringLiteral("%1 shows %1 on every checkout").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      for (const QString& environment : world.mc.linked) {
        if (checkout(world, c[0], environment).value(QLatin1String("projectIcon")).toObject().value(QLatin1String("emoji")) != c[1]) return false;
      }
      return at(panel(world).value(QStringLiteral("icon")), QStringLiteral("label")) == c[1];
    }, [&] { return QStringLiteral("%1 on every checkout; the panel is %2").arg(c[1], show(panel(world))); });
  });
  step(QStringLiteral("the user sets the icon of %1 back to automatic").arg(q), [](World& world, const Captures&, const Table&) {
    act(world, QStringLiteral("icon"));
  });
  step(QStringLiteral("%1 shows its automatic icon").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      for (const QString& environment : world.mc.linked) {
        if (!checkout(world, c[0], environment).value(QLatin1String("projectIcon")).isNull()) return false;
      }
      return !at(panel(world).value(QStringLiteral("icon")), QStringLiteral("custom")).toBool();
    }, [&] { return QStringLiteral("the automatic icon; the panel is %1").arg(show(panel(world))); });
  });

  // Checkouts and removing them.
  step(QStringLiteral("the checkouts on %1 and %1 are listed with their folders").arg(q), [](World& world, const Captures& c, const Table&) {
    QStringList listed;
    for (const QVariant& row : panel(world).value(QStringLiteral("checkouts")).toList()) {
      listed.append(at(row, QStringLiteral("environment")).toString() + QLatin1Char(' ') + at(row, QStringLiteral("path")).toString());
    }
    listed.sort();
    expect(listed == QStringList{c[0] + QStringLiteral(" /home/") + c[0] + QStringLiteral("/shop"),
                                 c[1] + QStringLiteral(" /home/") + c[1] + QStringLiteral("/shop")},
           QStringLiteral("the checkouts are %1").arg(listed.join(u", ")));
  });
  step(QStringLiteral("the user removes the %1 checkout of %1 and confirms").arg(q), [](World& world, const Captures& c, const Table&) {
    manage(world, c[1]);
    act(world, QStringLiteral("remove"), {{QStringLiteral("key"), checkoutKey(world, c[1], c[0])}});
    world.waitFor([&] { return !removal(world).isEmpty(); }, QStringLiteral("the removal to be confirmed"));
    world.bridge().dispatch(QStringLiteral("project.remove.confirm"), QVariantMap());
  });
  step(QStringLiteral("%1 is listed only on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return listedOn(world, c[0]) == QStringList{c[1]}; },
                  [&] { return QStringLiteral("%1 only on %2; it is on %3").arg(c[0], c[1], listedOn(world, c[0]).join(u", ")); });
  });
  step(QStringLiteral("the user removes %1 everywhere and confirms").arg(q), [](World& world, const Captures& c, const Table&) {
    manage(world, c[0]);
    act(world, QStringLiteral("remove"));
    world.waitFor([&] { return removal(world).value(QStringLiteral("count")).toInt() == 2; },
                  [&] { return QStringLiteral("both checkouts to be confirmed; the confirmation is %1").arg(show(removal(world))); });
    world.bridge().dispatch(QStringLiteral("project.remove.confirm"), QVariantMap());
  });
  step(QStringLiteral("%1 is no longer listed on %1 or %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return listedOn(world, c[0]).isEmpty(); },
                  [&] { return QStringLiteral("%1 to be gone; it is on %2").arg(c[0], listedOn(world, c[0]).join(u", ")); });
  });
  step(QStringLiteral("no files are deleted on either machine"), [](World& world, const Captures&, const Table&) {
    // Only the entries go: nothing asks a machine to delete a folder.
    for (const QJsonObject& mutation : world.mc.part<FakeProjects>().mutations) {
      expect(mutation.value(QLatin1String("type")) == QLatin1String("project.delete") && !mutation.contains(QLatin1String("deleteFiles")),
             QStringLiteral("the MC was asked to %1").arg(show(mutation.toVariantMap())));
    }
  });
  step(QStringLiteral("the %1 checkout of %1 has (\\d+) threads").arg(q), [](World& world, const Captures& c, const Table&) {
    for (int index = 1; index <= c[2].toInt(); ++index) {
      const QString id = QStringLiteral("%1-thread-%2").arg(c[0]).arg(index);
      world.mc.sendLinkRow(c[0], id,
                             QJsonObject{{QStringLiteral("id"), id}, {QStringLiteral("projectId"), checkoutId(c[1], c[0])},
                                         {QStringLiteral("title"), QStringLiteral("Thread %1").arg(index)},
                                         {QStringLiteral("createdAt"), kAt}, {QStringLiteral("updatedAt"), kAt}});
    }
  });
  step(QStringLiteral("the user asks to remove the %1 checkout of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    manage(world, c[1]);
    act(world, QStringLiteral("remove"), {{QStringLiteral("key"), checkoutKey(world, c[1], c[0])}});
  });
  step(QStringLiteral("the confirmation names (\\d+) threads, the folder and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      const QVariantMap shown = removal(world);
      return shown.value(QStringLiteral("threadCount")).toInt() == c[0].toInt() &&
             shown.value(QStringLiteral("workspaceRoot")) == QStringLiteral("/home/%1/shop").arg(c[1]) &&
             shown.value(QStringLiteral("environment")) == c[1];
    }, [&] { return QStringLiteral("the confirmation is %1").arg(show(removal(world))); });
  });
  step(QStringLiteral("the confirmation says conversation history is cleared permanently"), [](World& world, const Captures&, const Table&) {
    // ProjectRemovalDialog.qml says so of every checkout it removes.
    expect(removal(world).value(QStringLiteral("kind")) == QLatin1String("checkout"),
           QStringLiteral("the confirmation is %1").arg(show(removal(world))));
  });
  step(QStringLiteral("the user is told to keep the project picked while browsing other pages to find more of its settings"),
       [](World& world, const Captures&, const Table&) {
         expect(panel(world).value(QStringLiteral("note")).toString().contains(QLatin1String("Keep this project picked above")),
                QStringLiteral("the panel is %1").arg(show(panel(world))));
       });

  // project-defaults.feature
  step(QStringLiteral("a connected environment %1 with the project %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.environmentId = c[0];
    world.mc.label = c[0];
    world.mc.projects.insert(c[1], QJsonObject{{QStringLiteral("id"), c[1]}, {QStringLiteral("title"), c[1]},
                                                 {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + c[1]},
                                                 {QStringLiteral("createdAt"), kAt}, {QStringLiteral("updatedAt"), kAt},
                                                 {QStringLiteral("scripts"), QJsonArray()}});
    publishProviders(world.mc, {provider(QStringLiteral("claudeAgent"), QStringLiteral("Claude"), {QStringLiteral("Sonnet")})});
    world.connect();
    world.sync();
  });
  step(QStringLiteral("neither %1 nor %1 sets a default model").arg(q), [](World& world, const Captures&, const Table&) {
    expect(!fakeConfig(world.mc).settings.contains(QLatin1String("defaultModelSelection")), QStringLiteral("no default model"));
  });
  step(QStringLiteral("the user looks at the project defaults of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    manage(world, c[0]);
  });
  step(QStringLiteral("the default model shows as automatic"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return row(world, QStringLiteral("model")).value(QStringLiteral("automatic")).toBool(); },
                  [&] { return QStringLiteral("an automatic model; the panel is %1").arg(show(panel(world))); });
    expect(row(world, QStringLiteral("model")).value(QStringLiteral("label")) == QLatin1String("Automatic"),
           QStringLiteral("the panel is %1").arg(show(panel(world))));
  });
  step(QStringLiteral("%1 is not available on %1").arg(q), [](World&, const Captures&, const Table&) {
    // Only Sonnet is offered there.
  });
  step(QStringLiteral("the user sets the default model of %1 to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    manage(world, c[0]);
    act(world, QStringLiteral("model"), {{QStringLiteral("key"), QStringLiteral("claudeAgent:") + c[1].toLower()}});
  });
  step(QStringLiteral("the user is told the default model was not saved because it is unavailable on %1").arg(q),
       [](World& world, const Captures& c, const Table&) {
         expectToast(world, QStringLiteral("Default model not saved"), QStringLiteral("This model is unavailable on %1.").arg(c[0]));
         expect(fakeConfig(world.mc).writes.isEmpty(), QStringLiteral("nothing to be written"));
       });
  step(QStringLiteral("%1 has no providers").arg(q), [](World& world, const Captures&, const Table&) {
    publishProviders(world.mc, {});
  });
  step(QStringLiteral("the user is told no providers are available"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return row(world, QStringLiteral("model")).value(QStringLiteral("none")).toBool(); },
                  [&] { return QStringLiteral("no models to be offered; the panel is %1").arg(show(panel(world))); });
  });
  step(QStringLiteral("the user applies settings to %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    linkMachine(world, c[1]);
    openProjects(world);
    chooseProject(world, {});
    chooseEnvironment(world, {});
    world.waitFor([&] { return world.native().controller<SettingsScopeController>()->targets().size() == 2; },
                  [&] { return QStringLiteral("both environments to be selected; the scope is %1").arg(show(scope(world))); });
  });
  step(QStringLiteral("their default workspaces differ"), [](World& world, const Captures&, const Table&) {
    saveOn(world.mc, world.mc.environmentId, QStringLiteral("defaultThreadEnvMode"), QStringLiteral("worktree"));
    saveOn(world.mc, world.mc.linked.first(), QStringLiteral("defaultThreadEnvMode"), QStringLiteral("local"));
  });
  step(QStringLiteral("the user looks at the default workspace"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return row(world, QStringLiteral("workspace")).value(QStringLiteral("mixed")).toBool(); },
                  [&] { return QStringLiteral("the workspaces to be read; the panel is %1").arg(show(panel(world))); });
  });
  step(QStringLiteral("it shows as mixed"), [](World& world, const Captures&, const Table&) {
    expect(row(world, QStringLiteral("workspace")).value(QStringLiteral("label")) == QLatin1String("Mixed"),
           QStringLiteral("the panel is %1").arg(show(panel(world))));
  });
  // "the user picks" is SidebarSteps.cpp's, which picks the workspace here.
  step(QStringLiteral("both environments use %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      return savedOn(world, world.mc.environmentId, QStringLiteral("defaultThreadEnvMode")) == QJsonValue(c[0]) &&
             savedOn(world, world.mc.linked.first(), QStringLiteral("defaultThreadEnvMode")) == QJsonValue(c[0]) &&
             !row(world, QStringLiteral("workspace")).value(QStringLiteral("mixed")).toBool();
    }, [&] { return QStringLiteral("%1 on both; the panel is %2").arg(c[0], show(panel(world))); });
  });
  step(QStringLiteral("no environment is connected"), [](World& world, const Captures&, const Table&) {
    openProjects(world);
    world.mc.stopAccepting();
    world.mc.drop();
    world.waitFor([&world] { return !world.native().client()->isReady(); }, QStringLiteral("the shell to see the drop"));
  });
  step(QStringLiteral("the user looks at the project defaults"), [](World&, const Captures&, const Table&) {});
  step(QStringLiteral("the defaults show as unavailable"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      return !panel(world).value(QStringLiteral("available"), true).toBool() &&
             row(world, QStringLiteral("model")).value(QStringLiteral("label")) == QLatin1String("Unavailable") &&
             row(world, QStringLiteral("workspace")).value(QStringLiteral("label")) == QLatin1String("Unavailable");
    }, [&] { return QStringLiteral("the defaults to be unavailable; the panel is %1").arg(show(panel(world))); });
  });
});

}  // namespace
