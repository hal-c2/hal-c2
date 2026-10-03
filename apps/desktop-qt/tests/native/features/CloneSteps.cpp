// Cloning a repository into a new project (ProjectCloneController): Add
// project's clone sources in the palette (features/navigation/
// palette-add-project.feature) and each clone's toast
// (features/files/adding-projects.feature). The fake MC looks repositories
// up, starts clones (adding their project at once, as the MC does) and
// reports them on each environment's `projectClones` shape; what git does is
// the MC's own scenarios'. Where Add project browses from is the
// environment's `addProjectBaseDirectory` setting (features/settings/
// general.feature).

#include <QJsonArray>
#include <QJsonObject>
#include <QVariantList>

#include "CommandPaletteController.h"
#include "DraftController.h"
#include "FakeConfig.h"
#include "FakeFiles.h"
#include "FakeSourceControl.h"
#include "Harness.h"
#include "KeybindingController.h"
#include "NavigationController.h"
#include "World.h"

namespace {

const QString kCloneProject = QStringLiteral("p-shop");

struct FakeClones {
  // By environment.
  QHash<QString, QList<QJsonObject>> clones;
  // Every projectClone.* and sourceControl.lookupRepository call, as {method, payload}.
  QList<QPair<QString, QJsonObject>> calls;
  QString refuseStart;
  QString refuseLookup;
  // The source the scenario added a project from, and what the palette asked
  // on the way ("ask: <placeholder>", "browse: <query>").
  QString source;
  QStringList asked;
};

QJsonArray reported(const FakeClones& fake, const QString& environment) {
  QJsonArray clones;
  for (const QJsonObject& clone : fake.clones.value(environment)) clones.append(clone);
  return clones;
}

// The environment a shape or call is for; the MC's own when it names none.
QString environmentOf(FakeMc& mc, const QString& named) {
  return named.isEmpty() ? mc.environmentId : named;
}

void publish(FakeMc& mc, const QString& environment) {
  for (const int id : mc.subscribers(QStringLiteral("projectClones"))) {
    if (environmentOf(mc, mc.shapeOf(id).value(QLatin1String("environment")).toString()) != environment) continue;
    mc.send({{QStringLiteral("t"), QStringLiteral("projectClones")}, {QStringLiteral("id"), id},
               {QStringLiteral("clones"), reported(mc.part<FakeClones>(), environment)}});
  }
}

QString expandHome(FakeMc& mc, const QString& path) {
  return path.startsWith(QLatin1Char('~')) ? fakeFiles(mc).home + path.mid(1) : path;
}

void addProjectRow(FakeMc& mc, const QString& id, const QString& title, const QString& root) {
  const QJsonObject row{{QStringLiteral("id"), id},
                        {QStringLiteral("title"), title},
                        {QStringLiteral("workspaceRoot"), root},
                        {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T10:00:00Z")},
                        {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T10:00:00Z")},
                        {QStringLiteral("scripts"), QJsonArray()}};
  mc.projects.insert(id, row);
  mc.sendRow(id, row, QStringLiteral("project"));
}

const FakeMc::Extension clones([](FakeMc& mc) {
  mc.onShape(QStringLiteral("projectClones"), [&mc](int id, const QJsonObject& shape) {
    const QString environment = environmentOf(mc, shape.value(QLatin1String("environment")).toString());
    mc.send({{QStringLiteral("t"), QStringLiteral("projectClones")}, {QStringLiteral("id"), id},
               {QStringLiteral("clones"), reported(mc.part<FakeClones>(), environment)}});
  });
  mc.onRpc(QStringLiteral("sourceControl.lookupRepository"), [&mc](const FakeMc::Rpc& rpc) {
    FakeClones& fake = mc.part<FakeClones>();
    fake.calls.append({rpc.method, rpc.payload});
    if (!fake.refuseLookup.isEmpty()) return mc.refuse(rpc, fake.refuseLookup);
    const QString provider = rpc.payload.value(QLatin1String("provider")).toString();
    const QString repository = rpc.payload.value(QLatin1String("repository")).toString();
    const QString host = provider + QStringLiteral(".example.com");
    mc.reply(rpc, QJsonObject{{QStringLiteral("provider"), provider},
                                {QStringLiteral("nameWithOwner"), repository},
                                {QStringLiteral("url"), QStringLiteral("https://%1/%2.git").arg(host, repository)},
                                {QStringLiteral("sshUrl"), QStringLiteral("git@%1:%2.git").arg(host, repository)}});
  });
  mc.onRpc(QStringLiteral("projectClone."), [&mc](const FakeMc::Rpc& rpc) {
    FakeClones& fake = mc.part<FakeClones>();
    fake.calls.append({rpc.method, rpc.payload});
    if (rpc.method != QLatin1String("projectClone.start")) return mc.reply(rpc, QJsonObject());
    if (!fake.refuseStart.isEmpty()) return mc.refuse(rpc, fake.refuseStart);
    const QString id = rpc.payload.value(QLatin1String("projectId")).toString();
    const QString destination = expandHome(mc, rpc.payload.value(QLatin1String("destinationPath")).toString());
    mc.reply(rpc, QJsonObject());
    addProjectRow(mc, id, rpc.payload.value(QLatin1String("title")).toString(), destination);
    const QString environment = environmentOf(mc, rpc.environment);
    fake.clones[environment].append({{QStringLiteral("projectId"), id},
                        {QStringLiteral("remoteUrl"), rpc.payload.value(QLatin1String("remoteUrl"))},
                        {QStringLiteral("destinationPath"), destination},
                        {QStringLiteral("repository"), QJsonValue::Null},
                        {QStringLiteral("phase"), QStringLiteral("running")},
                        {QStringLiteral("stage"), QStringLiteral("connecting")},
                        {QStringLiteral("percent"), QJsonValue::Null},
                        {QStringLiteral("detail"), QJsonValue::Null},
                        {QStringLiteral("error"), QJsonValue::Null}});
    publish(mc, environment);
  });
});

FakeClones& fake(World& world) {
  return world.mc.part<FakeClones>();
}

// --- The palette -------------------------------------------------------------------------

CommandPaletteController& palette(World& world) {
  auto* palette = world.native().controller<CommandPaletteController>();
  if (!palette) fail(QStringLiteral("the shell has no command palette"));
  return *palette;
}

QString describe(World& world) {
  CommandPaletteController& model = palette(world);
  QStringList rows;
  for (int row = 0; row < model.rowCount(); ++row) {
    rows << QStringLiteral("%1 (%2)").arg(model.index(row).data(CommandPaletteController::TitleRole).toString(),
                                         model.index(row).data(CommandPaletteController::DescriptionRole).toString());
  }
  return QStringLiteral("the palette (%1, %2 \"%3\", query \"%4\") lists [%5]")
      .arg(model.isOpen() ? u"open"_qs : u"closed"_qs, model.mode(), model.submenu(), model.query(), rows.join(u"; "));
}

// The row titled `title` once the palette's searches are answered, or -1.
int rowOf(World& world, const QString& title) {
  world.sync();
  CommandPaletteController& model = palette(world);
  world.waitFor([&model] { return !model.searching(); }, QStringLiteral("the palette's searches to be answered"));
  for (int row = 0; row < model.rowCount(); ++row) {
    if (model.index(row).data(CommandPaletteController::TitleRole) == title) return row;
  }
  return -1;
}

QString descriptionOf(World& world, const QString& title) {
  const int row = rowOf(world, title);
  return row < 0 ? QString() : palette(world).index(row).data(CommandPaletteController::DescriptionRole).toString();
}

void runRow(World& world, const QString& title) {
  const int row = rowOf(world, title);
  expect(row >= 0 && palette(world).run(row), QStringLiteral("to run \"%1\"; %2").arg(title, describe(world)));
  world.sync();
}

// Add project's sources, once the environment's providers are known.
void openSources(World& world) {
  if (!palette(world).isOpen()) world.native().controller<KeybindingController>()->commands()->run(QStringLiteral("project.add"));
  else runRow(world, QStringLiteral("Add project"));
  world.waitFor([&] { return !descriptionOf(world, QStringLiteral("GitHub repository")).startsWith(u"Setup Required"); },
                [&] { return QStringLiteral("the providers to be known; ") + describe(world); });
}

void remember(World& world) {
  CommandPaletteController& model = palette(world);
  fake(world).asked << (model.mode() == u"ask" ? QStringLiteral("ask: ") + model.placeholder()
                                               : model.mode() + QStringLiteral(": ") + model.query());
}

// Enter in the palette.
void enter(World& world, const QString& typed = {}) {
  if (!typed.isNull()) palette(world).setQuery(typed);
  rowOf(world, {});
  expect(palette(world).runHighlighted(), describe(world));
  world.sync();
}

// Add project from `source` up to where the MC is asked to clone (or adds the folder).
void addFrom(World& world, const QString& source) {
  FakeClones& clones = fake(world);
  clones.source = source;
  if (source == u"a repository on GitLab") setSourceControlHost(world.mc, QStringLiteral("gitlab"), true);
  openSources(world);
  if (source == u"a local folder") {
    FakeFiles& files = fakeFiles(world.mc);
    files.folders << files.home + QStringLiteral("/code") << files.home + QStringLiteral("/code/shop");
    runRow(world, QStringLiteral("Local folder"));
    remember(world);
    palette(world).setQuery(QStringLiteral("~/code/shop"));
    rowOf(world, {});
    expect(palette(world).addBrowsedFolder(), describe(world));
    world.sync();
    return;
  }
  const bool url = source == u"a Git URL";
  runRow(world, url ? QStringLiteral("Git URL")
                    : source == u"a repository on GitHub" ? QStringLiteral("GitHub repository") : QStringLiteral("GitLab repository"));
  remember(world);
  const qsizetype lookups = clones.calls.size();
  enter(world, url ? QStringLiteral("https://example.com/acme/shop.git") : QStringLiteral("acme/shop"));
  if (!url) {
    world.waitFor([&] { return clones.calls.size() > lookups; }, QStringLiteral("the repository to be looked up"));
    world.sync();
    if (!clones.refuseLookup.isEmpty()) return;
  }
  world.waitFor([&] { return palette(world).mode() == u"browse"; }, [&] { return describe(world); });
  remember(world);
  enter(world);
  world.waitFor([&] {
    return std::any_of(clones.calls.cbegin(), clones.calls.cend(), [](const auto& call) { return call.first == u"projectClone.start"; });
  }, QStringLiteral("the clone to start"));
  world.sync();
}

QJsonObject started(World& world) {
  for (const auto& call : std::as_const(fake(world).calls)) {
    if (call.first == u"projectClone.start") return call.second;
  }
  return {};
}

// --- Clones the MC reports ---------------------------------------------------------------

// Another machine of the cluster the scenario's clones run on.
const QString kMember = QStringLiteral("beast");

void reportClone(World& world, const QString& repository, QJsonObject fields, const QString& environment = {}) {
  const QString on = environmentOf(world.mc, environment);
  const QString destination = fakeFiles(world.mc).home + QStringLiteral("/shop");
  const bool own = on == world.mc.environmentId;
  if (own && !world.mc.projects.contains(kCloneProject)) addProjectRow(world.mc, kCloneProject, QStringLiteral("shop"), destination);
  QJsonObject clone{{QStringLiteral("projectId"), kCloneProject},
                    {QStringLiteral("remoteUrl"), QStringLiteral("https://github.com/%1.git").arg(repository)},
                    {QStringLiteral("destinationPath"), destination},
                    {QStringLiteral("repository"), QJsonObject{{QStringLiteral("nameWithOwner"), repository}}},
                    {QStringLiteral("stage"), QJsonValue::Null},
                    {QStringLiteral("percent"), QJsonValue::Null},
                    {QStringLiteral("detail"), QJsonValue::Null},
                    {QStringLiteral("error"), QJsonValue::Null}};
  for (auto it = fields.begin(); it != fields.end(); ++it) clone.insert(it.key(), it.value());
  fake(world).clones[on] = {clone};
  publish(world.mc, on);
  world.sync();
}

QVariantList toasts(World& world) {
  return world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList();
}

QVariantMap waitForToast(World& world, const QString& title) {
  QVariantMap found;
  world.waitFor([&] {
    for (const QVariant& item : toasts(world)) {
      if (item.toMap().value(QStringLiteral("title")) == title) {
        found = item.toMap();
        return true;
      }
    }
    return false;
  }, [&] { return QStringLiteral("the toast \"%1\"; the shell shows %2").arg(title, show(toasts(world))); });
  return found;
}

// Clicks `label` on the toast titled `title`, as the Notifications brick does.
void choose(World& world, const QString& title, const QString& label) {
  const QVariantMap toast = waitForToast(world, title);
  for (const QVariant& action : toast.value(QStringLiteral("actions")).toList()) {
    if (action.toMap().value(QStringLiteral("label")) != label) continue;
    world.bridge().dispatch(QStringLiteral("notification.action"),
                            QVariantMap{{QStringLiteral("id"), toast.value(QStringLiteral("id"))},
                                        {QStringLiteral("actionId"), action.toMap().value(QStringLiteral("id"))}});
    world.sync();
    return;
  }
  fail(QStringLiteral("no \"%1\" on %2").arg(label, show(toast)));
}

// The project of the draft the window shows.
QJsonObject draftProject(World& world) {
  const QVariant route = world.state(QStringLiteral("route"));
  if (at(route, QStringLiteral("kind")) != QLatin1String("draft")) return {};
  const auto draft = world.native().controller<DraftController>()->draft(at(route, QStringLiteral("draftId")).toString());
  if (!draft || draft->environmentId != world.mc.environmentId) return {};
  return world.mc.projects.value(draft->projectId);
}

const Steps steps([] {
  const QString q = kQuoted;

  // Adding from a source.
  step(QStringLiteral("the user adds a project from (a local folder|a Git URL|a repository on GitHub|a repository on GitLab)"),
       [](World& world, const Captures& c, const Table&) { addFrom(world, c[0]); });
  step(QStringLiteral("the project is added to the chosen environment"), [](World& world, const Captures&, const Table&) {
    const QString source = fake(world).source;
    const QString home = fakeFiles(world.mc).home;
    const QString root = source == u"a local folder" ? home + QStringLiteral("/code/shop") : home + QStringLiteral("/shop");
    world.waitFor([&] { return draftProject(world).value(QLatin1String("workspaceRoot")) == root; },
                  [&] { return QStringLiteral("a draft in the project at %1; the route is %2").arg(root, show(world.state(QStringLiteral("route")))); });
    if (source == u"a local folder") return;
    // Each source clones from its own address: a URL as given, GitHub over HTTPS, GitLab over SSH.
    const QString remote = started(world).value(QLatin1String("remoteUrl")).toString();
    const QString expected = source == u"a Git URL" ? QStringLiteral("https://example.com/acme/shop.git")
                             : source == u"a repository on GitHub" ? QStringLiteral("https://github.example.com/acme/shop.git")
                                                                   : QStringLiteral("git@gitlab.example.com:acme/shop.git");
    expect(remote == expected && started(world).value(QLatin1String("title")).toString() == u"shop",
           QStringLiteral("the clone started with %1").arg(show(started(world).toVariantMap())));
    expect(!palette(world).isOpen(), describe(world));
  });

  // A provider that is not set up.
  step(QStringLiteral("GitLab is not connected"), [](World& world, const Captures&, const Table&) {
    setSourceControlHost(world.mc, QStringLiteral("gitlab"), false);
  });
  step(QStringLiteral("the user looks at repository sources while adding a project"), [](World& world, const Captures&, const Table&) {
    openSources(world);
  });
  step(QStringLiteral("GitLab is marked %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(descriptionOf(world, QStringLiteral("GitLab repository")).startsWith(c[0] + u" · "), describe(world));
    // Ready sources come first.
    expect(rowOf(world, QStringLiteral("GitHub repository")) < rowOf(world, QStringLiteral("GitLab repository")), describe(world));
  });
  step(QStringLiteral("choosing it opens the source control settings"), [](World& world, const Captures&, const Table&) {
    runRow(world, QStringLiteral("GitLab repository"));
    const QVariant route = world.state(QStringLiteral("route"));
    expect(at(route, QStringLiteral("kind")) == QLatin1String("settings") &&
               at(route, QStringLiteral("section")) == QLatin1String("/settings/source-control") && !palette(world).isOpen(),
           show(route));
  });

  // The steps of a clone.
  step(QStringLiteral("the user is asked for the repository first"), [](World& world, const Captures&, const Table&) {
    expect(fake(world).asked.value(0) == u"ask: Enter Git clone URL", fake(world).asked.join(u"; "));
  });
  step(QStringLiteral("then for the destination folder"), [](World& world, const Captures&, const Table&) {
    // In the home folder, under the repository's name.
    expect(fake(world).asked.value(1) == u"browse: ~/shop" && started(world).value(QLatin1String("destinationPath")).toString() == u"~/shop",
           fake(world).asked.join(u"; "));
  });

  // Where browsing starts.
  step(QStringLiteral("the add project base directory is %1").arg(q), [](World& world, const Captures& c, const Table&) {
    saveElsewhere(world.mc, QStringLiteral("addProjectBaseDirectory"), c[0]);
  });
  step(QStringLiteral("the add project base directory is empty"), [](World& world, const Captures&, const Table&) {
    saveElsewhere(world.mc, QStringLiteral("addProjectBaseDirectory"), QString());
  });
  step(QStringLiteral("the user starts adding a project"), [](World& world, const Captures&, const Table&) {
    openSources(world);
    runRow(world, QStringLiteral("Local folder"));
    remember(world);
  });
  step(QStringLiteral("(?:the folder browser opens in|browsing starts at) (%1|the home folder)").arg(q),
       [](World& world, const Captures& c, const Table&) {
         // A folder, as the palette browses one: with its separator.
         QString folder = c[0] == u"the home folder" ? QStringLiteral("~") : c[0].mid(1, c[0].size() - 2);
         if (!folder.endsWith(QLatin1Char('/'))) folder += QLatin1Char('/');
         expect(fake(world).asked.contains(QStringLiteral("browse: ") + folder), fake(world).asked.join(u"; "));
       });
  step(QStringLiteral("the destination offered is %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(fake(world).asked.value(1) == QStringLiteral("browse: ") + c[0] &&
               started(world).value(QLatin1String("destinationPath")).toString() == c[0],
           fake(world).asked.join(u"; "));
  });

  // Failures.
  step(QStringLiteral("adding a project will fail at (the clone|the repository lookup)"), [](World& world, const Captures& c, const Table&) {
    if (c[0] == u"the clone") {
      fake(world).refuseStart = QStringLiteral("destination already exists");
      fake(world).source = QStringLiteral("a Git URL");
    } else {
      fake(world).refuseLookup = QStringLiteral("repository not found");
      fake(world).source = QStringLiteral("a repository on GitHub");
    }
  });
  step(QStringLiteral("the user adds the project"), [](World& world, const Captures&, const Table&) {
    FakeClones& clones = fake(world);
    if (!clones.refuseStart.isEmpty()) {
      // Refused, so addFrom's wait for the start is for the call, not a clone.
      addFrom(world, clones.source);
      expect(palette(world).isOpen() && palette(world).mode() == u"browse", describe(world));
      return;
    }
    addFrom(world, clones.source);
  });

  // Clone toasts.
  step(QStringLiteral("a clone of %1 is receiving objects at (\\d+) percent").arg(q), [](World& world, const Captures& c, const Table&) {
    reportClone(world, c[0], {{QStringLiteral("phase"), QStringLiteral("running")},
                              {QStringLiteral("stage"), QStringLiteral("receiving")},
                              {QStringLiteral("percent"), c[1].toInt()}});
  });
  step(QStringLiteral("a clone of %1 is receiving objects at (\\d+) percent on another machine of the cluster").arg(q),
       [](World& world, const Captures& c, const Table&) {
         world.mc.join(kMember);
         world.waitFor([&] {
           for (const int id : world.mc.subscribers(QStringLiteral("projectClones"))) {
             if (world.mc.shapeOf(id).value(QLatin1String("environment")) == kMember) return true;
           }
           return false;
         }, QStringLiteral("the clones of the other machine to be followed"));
         reportClone(world, c[0], {{QStringLiteral("phase"), QStringLiteral("running")},
                                   {QStringLiteral("stage"), QStringLiteral("receiving")},
                                   {QStringLiteral("percent"), c[1].toInt()}},
                     kMember);
       });
  step(QStringLiteral("a clone of %1 finished").arg(q), [](World& world, const Captures& c, const Table&) {
    reportClone(world, c[0], {{QStringLiteral("phase"), QStringLiteral("done")},
                              {QStringLiteral("stage"), QStringLiteral("checkout")},
                              {QStringLiteral("percent"), 100}});
  });
  step(QStringLiteral("a clone of %1 failed").arg(q), [](World& world, const Captures& c, const Table&) {
    reportClone(world, c[0], {{QStringLiteral("phase"), QStringLiteral("failed")},
                              {QStringLiteral("error"), QStringLiteral("Repository not found.")}});
  });
  step(QStringLiteral("the user looks at the app"), [](World& world, const Captures&, const Table&) { world.sync(); });
  step(QStringLiteral("the user sees %1 with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap toast = waitForToast(world, c[0]);
    expect(toast.value(QStringLiteral("description")) == c[1], show(toast));
  });
  step(QStringLiteral("the user sees %1 with its destination folder").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap toast = waitForToast(world, c[0]);
    expect(toast.value(QStringLiteral("description")) == fakeFiles(world.mc).home + u"/shop", show(toast));
  });
  step(QStringLiteral("the user can cancel the clone"), [](World& world, const Captures&, const Table&) {
    choose(world, QStringLiteral("Cloning acme/shop"), QStringLiteral("Cancel"));
    FakeClones& clones = fake(world);
    world.waitFor([&] {
      return std::any_of(clones.calls.cbegin(), clones.calls.cend(), [](const auto& call) {
        return call.first == u"projectClone.cancel" && call.second.value(QLatin1String("projectId")) == kCloneProject;
      });
    }, QStringLiteral("the clone to be cancelled"));
    // The toast stays, to say how the cancel went.
    waitForToast(world, QStringLiteral("Cloning acme/shop"));
  });
  step(QStringLiteral("the user can open the project"), [](World& world, const Captures&, const Table&) {
    choose(world, QStringLiteral("Cloned acme/shop"), QStringLiteral("Open project"));
    world.waitFor([&] { return draftProject(world).value(QLatin1String("id")) == kCloneProject; },
                  [&] { return show(world.state(QStringLiteral("route"))); });
  });
  step(QStringLiteral("the user removes the project from the clone's failure notice"), [](World& world, const Captures&, const Table&) {
    choose(world, QStringLiteral("Failed to clone acme/shop"), QStringLiteral("Remove project"));
  });
  step(QStringLiteral("the project %1 is no longer listed").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      for (const QVariant& project : at(world.state(QStringLiteral("sidebar")), QStringLiteral("projects")).toList()) {
        if (project.toMap().value(QStringLiteral("displayName")) == c[0]) return false;
      }
      return !world.mc.projects.contains(kCloneProject);
    }, [&] { return QStringLiteral("%1 to go; the sidebar is %2").arg(c[0], show(world.state(QStringLiteral("sidebar")))); });
  });
});

}  // namespace
