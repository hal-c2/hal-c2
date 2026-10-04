// The native Storage settings section and the settings scope it follows
// (StorageSettingsController, SettingsScopeController): the @desktop and
// @shared scenarios of features/settings/storage.feature and the scope ones of
// features/settings/scopes-and-inheritance.feature it delivers. Other
// machines are members of the cluster, each with its own settings document.

#include <QJsonArray>
#include <QJsonObject>

#include "FakeConfig.h"
#include "Harness.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "SettingsRows.h"
#include "SettingsScopeController.h"
#include "World.h"

namespace {

const QJsonObject kSupported{{QStringLiteral("storageCleanup"), true}, {QStringLiteral("projectWorktreeCleanup"), true}};

QVariantMap storage(World& world) {
  return world.state(QStringLiteral("storageSettings")).toMap();
}

QVariantMap scope(World& world) {
  return world.state(QStringLiteral("settingsScope")).toMap();
}

QJsonObject withCapabilities(QJsonObject config, const QJsonObject& capabilities) {
  QJsonObject environment = config.value(QLatin1String("environment")).toObject();
  environment.insert(QStringLiteral("capabilities"), capabilities);
  config.insert(QStringLiteral("environment"), environment);
  return config;
}

// This machine, supporting storage cleanup unless told otherwise.
void supportHere(World& world, const QJsonObject& capabilities = kSupported) {
  FakeConfig& fake = fakeConfig(world.mc);
  fake.config = withCapabilities(fake.config, capabilities);
}

// Another machine of the cluster, named `name`, with its own settings.
void joinMachine(World& world, const QString& name, const QJsonObject& capabilities = kSupported) {
  FakeConfig& fake = fakeConfig(world.mc);
  fake.elsewhere.insert(name, withCapabilities(fake.elsewhere.value(name), capabilities));
  documentOf(world.mc, name);
  world.mc.join(name);
}

void setCleanup(World& world, const QString& environment, const QString& key, const QJsonValue& value) {
  FakeConfig::Document& document = documentOf(world.mc, environment);
  QJsonObject cleanup = document.settings.value(QLatin1String("storageCleanup")).toObject();
  cleanup.insert(key, value);
  document.settings.insert(QStringLiteral("storageCleanup"), cleanup);
}

QJsonValue cleanupOf(World& world, const QString& environment, const QString& key) {
  const QJsonObject settings = environment == world.mc.environmentId ? fakeConfig(world.mc).settings
                                                                        : documentOf(world.mc, environment).settings;
  return settings.value(QLatin1String("storageCleanup")).toObject().value(key);
}

void openStorage(World& world) {
  if (world.shellSubscriptions() == 0) {
    world.connect();
    world.sync();
  }
  // Another scoped section that is open stays: the scope is shared.
  auto* navigation = world.native().controller<NavigationController>();
  if (navigation->route().kind != QLatin1String("settings")) {
    navigation->open(NavigationController::Route::settings(QStringLiteral("/settings/storage")));
  }
  world.waitFor([&] { return !scope(world).isEmpty() && !storage(world).isEmpty(); },
                [&] { return QStringLiteral("storage settings to show; they are %1").arg(show(storage(world))); });
}

// The scope's environment named `label`, "" for all.
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

QVariantMap rule(World& world, const QString& key) {
  for (const QString& group : {QStringLiteral("worktrees"), QStringLiteral("artifacts")}) {
    for (const QVariant& row : storage(world).value(group).toList()) {
      if (row.toMap().value(QStringLiteral("key")) == key) return row.toMap();
    }
  }
  return {};
}

void waitReady(World& world, int targets) {
  world.waitFor([&] {
    return storage(world).value(QStringLiteral("status")) == QLatin1String("ready") && scope(world).value(QStringLiteral("editable")).toBool() &&
           world.native().controller<SettingsScopeController>()->targets().size() == targets;
  }, [&] { return QStringLiteral("storage settings to be ready on %1 environments; they are %2, the scope %3")
               .arg(targets).arg(show(storage(world)), show(scope(world))); });
}

const Steps steps([] {
  const QString q = kQuoted;

  // storage.feature
  step(QStringLiteral("an MC with a project %1").arg(q), [](World& world, const Captures& c, const Table&) {
    supportHere(world);
    world.mc.projects.insert(c[0], QJsonObject{{QStringLiteral("id"), c[0]},
                                                 {QStringLiteral("title"), c[0]},
                                                 {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + c[0]},
                                                 {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                 {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                 {QStringLiteral("scripts"), QJsonArray()}});
  });
  step(QStringLiteral("%1 deletes inactive worktrees and %1 does not").arg(q), [](World& world, const Captures& c, const Table&) {
    for (const QString& name : {c[0], c[1]}) joinMachine(world, name);
    setCleanup(world, c[0], QStringLiteral("worktreeAfterDays"), 8);
    setCleanup(world, c[1], QStringLiteral("worktreeAfterDays"), QJsonValue::Null);
  });
  step(QStringLiteral("the user views storage settings for both machines"), [](World& world, const Captures&, const Table&) {
    openStorage(world);
    world.waitFor([&] { return scope(world).value(QStringLiteral("environments")).toList().size() == 3; },
                  [&] { return QStringLiteral("three environments; the scope is %1").arg(show(scope(world))); });
    chooseEnvironment(world, {});
  });
  step(QStringLiteral("that rule shows as mixed"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return rule(world, QStringLiteral("worktreeAfterDays")).value(QStringLiteral("mixed")).toBool(); },
                  [&] { return QStringLiteral("inactive worktrees to be mixed; storage is %1").arg(show(storage(world))); });
    expect(!rule(world, QStringLiteral("worktreeOnMerge")).value(QStringLiteral("mixed")).toBool(),
           QStringLiteral("rules set alike to stay unmixed; storage is %1").arg(show(storage(world))));
  });
  step(QStringLiteral("the selected machine does not support storage cleanup"), [](World& world, const Captures&, const Table&) {
    supportHere(world, {});
  });
  step(QStringLiteral("the user opens storage settings"), [](World& world, const Captures&, const Table&) {
    openStorage(world);
  });
  step(QStringLiteral("the user is asked to update that machine first"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return storage(world).value(QStringLiteral("status")) == QLatin1String("unsupported"); },
                  [&] { return QStringLiteral("storage settings to ask for an update; they are %1").arg(show(storage(world))); });
    expect(storage(world).value(QStringLiteral("notice")).toString().startsWith(QLatin1String("Update the selected environments")),
           QStringLiteral("the update notice; storage is %1").arg(show(storage(world))));
  });

  // scopes-and-inheritance.feature, through the Storage section.
  step(QStringLiteral("the user has environments %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    supportHere(world);
    for (const QString& name : {c[0], c[1]}) joinMachine(world, name);
  });
  step(QStringLiteral("the project %1 has a checkout on each environment").arg(q), [](World& world, const Captures& c, const Table&) {
    for (const QString& environment : world.mc.members) {
      world.mc.sendPeerRow(environment, c[0] + QLatin1Char('-') + environment,
                             QJsonObject{{QStringLiteral("id"), c[0] + QLatin1Char('-') + environment},
                                         {QStringLiteral("title"), c[0]},
                                         {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + c[0]},
                                         {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                         {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                         // One repository, so its checkouts are one project.
                                         {QStringLiteral("repositoryIdentity"),
                                          QJsonObject{{QStringLiteral("canonicalKey"), QStringLiteral("github.com/hal-c2/") + c[0]},
                                                      {QStringLiteral("rootPath"), QStringLiteral("/work/") + c[0]},
                                                      {QStringLiteral("name"), c[0]}}}},
                             QStringLiteral("project"));
    }
    // And another project, only here.
    world.mc.projects.insert(QStringLiteral("docs"), QJsonObject{{QStringLiteral("id"), QStringLiteral("docs")},
                                                                   {QStringLiteral("title"), QStringLiteral("docs")},
                                                                   {QStringLiteral("workspaceRoot"), QStringLiteral("/work/docs")},
                                                                   {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                                   {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                                   {QStringLiteral("scripts"), QJsonArray()}});
  });
  step(QStringLiteral("the user is editing settings for %1 on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    openStorage(world);
    chooseProject(world, c[0]);
    chooseEnvironment(world, c[1]);
    world.waitFor([&] { return scope(world).value(QStringLiteral("kind")) == QLatin1String("project"); },
                  [&] { return QStringLiteral("the project scope; it is %1").arg(show(scope(world))); });
  });
  step(QStringLiteral("the user chooses the environment %1").arg(q), [](World& world, const Captures& c, const Table&) {
    chooseEnvironment(world, c[0]);
  });
  step(QStringLiteral("the user chooses all environments"), [](World& world, const Captures&, const Table&) {
    chooseEnvironment(world, {});
  });
  step(QStringLiteral("the user chooses all projects"), [](World& world, const Captures&, const Table&) {
    chooseProject(world, {});
  });
  step(QStringLiteral("settings apply to %1 on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      const QVariantMap now = scope(world);
      return now.value(QStringLiteral("projectLabel")) == c[0] && now.value(QStringLiteral("environmentLabel")) == c[1] &&
             now.value(QStringLiteral("connective")) == QLatin1String("on") && now.value(QStringLiteral("kind")) == QLatin1String("project");
    }, [&] { return QStringLiteral("%1 on %2; the scope is %3").arg(c[0], c[1], show(scope(world))); });
    expect(world.native().controller<SettingsScopeController>()->targets() == QStringList{c[1]},
           QStringLiteral("only %1 to be written to").arg(c[1]));
  });
  step(QStringLiteral("settings apply to %1 across all checkouts").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      const QVariantMap now = scope(world);
      return now.value(QStringLiteral("projectLabel")) == c[0] && now.value(QStringLiteral("environmentLabel")) == QLatin1String("All environments") &&
             now.value(QStringLiteral("connective")) == QLatin1String("across");
    }, [&] { return QStringLiteral("%1 across all environments; the scope is %2").arg(c[0], show(scope(world))); });
    // Only the environments with a checkout of it.
    QStringList targets = world.native().controller<SettingsScopeController>()->targets();
    targets.sort();
    expect(targets == QStringList{QStringLiteral("Build box"), QStringLiteral("Laptop")},
           QStringLiteral("the checkouts to be written to; they are %1").arg(targets.join(QStringLiteral(", "))));
  });
  step(QStringLiteral("settings apply to every project on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      const QVariantMap now = scope(world);
      return now.value(QStringLiteral("kind")) == QLatin1String("environment") &&
             now.value(QStringLiteral("projectLabel")) == QLatin1String("All projects") && now.value(QStringLiteral("environmentLabel")) == c[0];
    }, [&] { return QStringLiteral("every project on %1; the scope is %2").arg(c[0], show(scope(world))); });
  });
  step(QStringLiteral("the user chooses which environment settings apply to"), [](World& world, const Captures&, const Table&) {
    openStorage(world);
  });
  step(QStringLiteral("%1 is listed as offline").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      for (const QVariant& row : scope(world).value(QStringLiteral("environments")).toList()) {
        if (row.toMap().value(QStringLiteral("label")) == c[0]) return !row.toMap().value(QStringLiteral("online")).toBool();
      }
      return false;
    }, [&] { return QStringLiteral("%1 to be listed offline; the scope is %2").arg(c[0], show(scope(world))); });
  });
  step(QStringLiteral("the user is editing settings across all environments"), [](World& world, const Captures&, const Table&) {
    // The ledger's two other machines, when the feature has named none.
    if (world.mc.members.isEmpty()) {
      supportHere(world);
      for (const QString& name : {QStringLiteral("Laptop"), QStringLiteral("Build box")}) joinMachine(world, name);
    }
    openStorage(world);
    chooseEnvironment(world, {});
    waitReady(world, 3);
  });
  step(QStringLiteral("saving on %1 fails").arg(q), [](World& world, const Captures& c, const Table&) {
    documentOf(world.mc, c[0]).refuseWrites = QStringLiteral("disk full");
  });
  const auto change = [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("storageSettings.set"),
                            QVariantMap{{QStringLiteral("key"), QStringLiteral("worktreeOnMerge")}, {QStringLiteral("value"), true}});
  };
  step(QStringLiteral("the user changes an environment-wide setting"), change);
  step(QStringLiteral("the user changes a setting"), change);
  step(QStringLiteral("the change is saved on %1 and on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      return cleanupOf(world, c[0], QStringLiteral("worktreeOnMerge")) == QJsonValue(true) &&
             cleanupOf(world, c[1], QStringLiteral("worktreeOnMerge")) == QJsonValue(true) &&
             cleanupOf(world, world.mc.environmentId, QStringLiteral("worktreeOnMerge")) == QJsonValue(true);
    }, QStringLiteral("merged worktree cleanup to be saved on every environment"));
  });
  step(QStringLiteral("the user is told the setting saved on some environments and could not update %1").arg(q),
       [](World& world, const Captures& c, const Table&) {
         world.waitFor([&] {
           for (const QVariant& toast : at(world.state(QStringLiteral("toasts")), QStringLiteral("items")).toList()) {
             if (toast.toMap().value(QStringLiteral("title")) == QLatin1String("Setting saved on some environments") &&
                 toast.toMap().value(QStringLiteral("description")).toString().contains(c[0])) {
               return true;
             }
           }
           return false;
         }, [&] { return QStringLiteral("a partial save to be reported; the shell shows %1").arg(show(world.state(QStringLiteral("toasts")))); });
         expect(cleanupOf(world, QStringLiteral("Laptop"), QStringLiteral("worktreeOnMerge")) == QJsonValue(true),
                QStringLiteral("Laptop to have saved the change"));
       });
  step(QStringLiteral("the user is editing settings for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    openStorage(world);
    chooseEnvironment(world, c[0]);
  });
  step(QStringLiteral("the user looks at an environment setting"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !scope(world).value(QStringLiteral("disabledReason")).toString().isEmpty(); },
                  [&] { return QStringLiteral("the scope to be disabled; it is %1").arg(show(scope(world))); });
  });
  step(QStringLiteral("the setting cannot be changed"), [](World& world, const Captures&, const Table&) {
    if (!world.settingRow.isEmpty()) return expectRowLocked(world, world.settingRow);  // a row of Settings → General
    expect(!scope(world).value(QStringLiteral("editable")).toBool(), QStringLiteral("the setting to be locked"));
    const qsizetype writes = fakeConfig(world.mc).writes.size();
    world.bridge().dispatch(QStringLiteral("storageSettings.set"),
                            QVariantMap{{QStringLiteral("key"), QStringLiteral("worktreeOnMerge")}, {QStringLiteral("value"), true}});
    world.sync();
    expect(fakeConfig(world.mc).writes.size() == writes, QStringLiteral("nothing to be written"));
  });
  step(QStringLiteral("the user is told to reconnect the selected environment to change it"), [](World& world, const Captures&, const Table&) {
    expect(scope(world).value(QStringLiteral("disabledReason")) == QLatin1String("Reconnect the selected environment to change this setting."),
           QStringLiteral("the reconnect notice; the scope is %1").arg(show(scope(world))));
  });
});

}  // namespace
