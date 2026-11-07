// The phone's side of features/files/adding-projects.feature: adding a folder
// from the home screen's Add project dialog, and each clone's toast as the
// phone layout stacks it. The MC's side is the desktop harness's fake MC with
// a `projects.mutate` and the `projectClones` shape of its own here, as the
// desktop's ProjectSteps.cpp and CloneSteps.cpp serve them.

#include <QFileInfo>
#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>
#include <QSet>
#include <QVariantList>

#include "DraftController.h"
#include "FakeFiles.h"
#include "Harness.h"
#include "NativeShell.h"
#include "Phone.h"
#include "ShellStore.h"
#include "World.h"

namespace {

#define S QStringLiteral

const QString kAt = S("2026-09-23T10:00:00Z");
const QString kCloneProject = S("p-shop");
// Another machine of the cluster the scenario's clones run on.
const QString kMember = S("beast");

struct FakeProjects {
  // The folders the scenario made on the MC's machine, and the error it
  // answers every change with once it has one to give.
  QSet<QString> folders;
  QString refusal;
};

struct FakeClones {
  // By environment.
  QHash<QString, QList<QJsonObject>> clones;
  // Every projectClone.* call, as {method, payload}.
  QList<QPair<QString, QJsonObject>> calls;
};

QJsonObject deleted() {
  return {{S("deletedAt"), S("2026-09-23T11:00:00Z")}};
}

QJsonObject projectRow(const QString& id, const QString& title, const QString& root) {
  return {{S("id"), id}, {S("title"), title}, {S("workspaceRoot"), root}, {S("scripts"), QJsonArray()},
          {S("createdAt"), kAt}, {S("updatedAt"), kAt}};
}

QString environmentOf(FakeMc& mc, const QString& named) {
  return named.isEmpty() ? mc.environmentId : named;
}

void publish(FakeMc& mc, const QString& environment) {
  QJsonArray clones;
  for (const QJsonObject& clone : mc.part<FakeClones>().clones.value(environment)) clones.append(clone);
  for (const int id : mc.subscribers(S("projectClones"))) {
    if (environmentOf(mc, mc.shapeOf(id).value(QLatin1String("environment")).toString()) != environment) continue;
    mc.send({{S("t"), S("projectClones")}, {S("id"), id}, {S("clones"), clones}});
  }
}

const FakeMc::Extension extension([](FakeMc& mc) {
  mc.onRpc(S("projects.mutate"), [&mc](const FakeMc::Rpc& rpc) {
    FakeProjects& fake = mc.part<FakeProjects>();
    if (!fake.refusal.isEmpty()) return mc.refuse(rpc, fake.refusal);
    const QString type = rpc.payload.value(QLatin1String("type")).toString();
    const QString id = rpc.payload.value(QLatin1String("projectId")).toString();
    if (type == QLatin1String("project.create")) {
      const QString root = rpc.payload.value(QLatin1String("workspaceRoot")).toString();
      if (!fake.folders.contains(root)) return mc.refuse(rpc, root + S(" does not exist on this machine."));
      const QJsonObject row = projectRow(id, QFileInfo(root).fileName(), root);
      mc.reply(rpc, row);
      mc.projects.insert(id, row);
      mc.sendRow(id, row, S("project"));
    } else if (type == QLatin1String("project.delete")) {
      if (!mc.projects.contains(id)) return mc.refuse(rpc, S("unknown project ") + id);
      mc.projects.remove(id);
      mc.sendRow(id, deleted(), S("project"));
      mc.reply(rpc, QJsonObject());
    } else {
      mc.refuse(rpc, type + S(" is not supported"));
    }
  });
  mc.onShape(S("projectClones"), [&mc](int id, const QJsonObject& shape) {
    const QString environment = environmentOf(mc, shape.value(QLatin1String("environment")).toString());
    QJsonArray clones;
    for (const QJsonObject& clone : mc.part<FakeClones>().clones.value(environment)) clones.append(clone);
    mc.send({{S("t"), S("projectClones")}, {S("id"), id}, {S("clones"), clones}});
  });
  mc.onRpc(S("projectClone."), [&mc](const FakeMc::Rpc& rpc) {
    mc.part<FakeClones>().calls.append({rpc.method, rpc.payload});
    mc.reply(rpc, QJsonObject());
  });
});

FakeClones& clones(World& world) {
  return world.mc.part<FakeClones>();
}

void reportClone(World& world, const QString& repository, QJsonObject fields, const QString& environment = {}) {
  const QString on = environmentOf(world.mc, environment);
  const QString destination = fakeFiles(world.mc).home + S("/shop");
  if (on == world.mc.environmentId && !world.mc.projects.contains(kCloneProject)) {
    const QJsonObject row = projectRow(kCloneProject, S("shop"), destination);
    world.mc.projects.insert(kCloneProject, row);
    world.mc.sendRow(kCloneProject, row, S("project"));
  }
  QJsonObject clone{{S("projectId"), kCloneProject},
                    {S("remoteUrl"), S("https://github.com/%1.git").arg(repository)},
                    {S("destinationPath"), destination},
                    {S("repository"), QJsonObject{{S("nameWithOwner"), repository}}},
                    {S("stage"), QJsonValue::Null},
                    {S("percent"), QJsonValue::Null},
                    {S("detail"), QJsonValue::Null},
                    {S("error"), QJsonValue::Null}};
  for (auto it = fields.begin(); it != fields.end(); ++it) clone.insert(it.key(), it.value());
  clones(world).clones[on] = {clone};
  publish(world.mc, on);
  world.sync();
}

// The sidebar's project names.
QStringList projectNames(World& world) {
  QStringList names;
  for (const QVariant& project : at(world.state(S("sidebar")), S("projects")).toList()) {
    names.append(project.toMap().value(S("displayName")).toString());
  }
  return names;
}

QVariantList toasts(World& world) {
  return world.state(S("toasts")).toMap().value(S("items")).toList();
}

// The toast titled `title`, waited for in the shell's state and on the screen.
QVariantMap waitForToast(World& world, const QString& title) {
  QVariantMap found;
  world.waitFor(
      [&] {
        for (const QVariant& item : toasts(world)) {
          if (item.toMap().value(S("title")) == title) found = item.toMap();
        }
        return !found.isEmpty() && world.shows(title);
      },
      [&] { return S("the toast \"%1\"; the shell has %2 and the screen says: %3").arg(title, show(toasts(world)), world.texts().join(S(" | "))); });
  return found;
}

// Taps `label` on the toast titled `title`, as a finger does on its card.
void choose(World& world, const QString& title, const QString& label) {
  const QVariantMap toast = waitForToast(world, title);
  for (const QVariant& action : toast.value(S("actions")).toList()) {
    if (action.toMap().value(S("label")) != label) continue;
    world.tap(S("notificationAction-%1-%2").arg(toast.value(S("id")).toString(), action.toMap().value(S("id")).toString()));
    world.sync();
    return;
  }
  fail(S("no \"%1\" on %2").arg(label, show(toast)));
}

// The user adds the folder at `path` from the home screen's Add project.
void addFolder(World& world, const QString& path) {
  threadList(world);
  world.tap(S("addProject"));
  world.awaitPopup(S("addProjectDialog"));
  world.type(path);
  world.tap(S("addProjectAdd"));
  world.awaitPopup(S("addProjectDialog"), false);
  world.sync();
}

void haveProject(World& world, const QString& id, const QString& root) {
  const QJsonObject row = projectRow(id, id, root);
  world.mc.projects.insert(id, row);
  world.sync();
  world.mc.sendRow(id, row, S("project"));
}

void haveThread(World& world, const QString& id, const QString& project, const QString& title, const QString& wrote,
                const QString& settled = {}) {
  QJsonObject row{{S("id"), id}, {S("title"), title}, {S("projectId"), project}, {S("createdAt"), kAt},
                  {S("updatedAt"), kAt}, {S("latestUserMessageAt"), wrote}};
  if (!settled.isEmpty()) row.insert(S("settledOverride"), settled);
  world.mc.threads.insert(id, row);
  world.mc.sendRow(id, row);
}

// The project of the draft the phone shows.
QJsonObject draftProject(World& world) {
  const QVariant route = world.state(S("route"));
  if (at(route, S("kind")) != QLatin1String("draft")) return {};
  const auto draft = world.native().controller<DraftController>()->draft(at(route, S("draftId")).toString());
  if (!draft || draft->environmentId != world.mc.environmentId) return {};
  return world.mc.projects.value(draft->projectId);
}

const Steps steps([] {
  const QString q = kQuoted;

  // The environment starts with no project: the scenarios add their own.
  step(S("a connected environment %1").arg(q), [](World& world, const Captures&, const Table&) {
    world.mc.projects.clear();
    world.mc.threads.clear();
    pairWithEnvironment(world);
    threadList(world);
  });
  step(S("the folder %1 exists on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.part<FakeProjects>().folders.insert(c[0]);
  });
  step(S("the environment refuses to change projects with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.part<FakeProjects>().refusal = c[0];
  });
  step(S("%1 is already a project on %1 with an unsettled thread %1").arg(q), [](World& world, const Captures& c, const Table&) {
    haveProject(world, c[0], S("/home/sam/") + c[0]);
    haveThread(world, S("t-latest"), c[0], c[2], S("2026-09-23T09:30:00Z"));
    haveThread(world, S("t-settled"), c[0], S("Done"), S("2026-09-23T09:45:00Z"), S("settled"));
    world.sync();
    threadRow(world, c[2]);
  });

  // The user.
  step(S("the user adds the local folder %1").arg(q), [](World& world, const Captures& c, const Table&) { addFolder(world, c[0]); });
  step(S("the user adds the local folder of %1 again").arg(q), [](World& world, const Captures& c, const Table&) {
    addFolder(world, world.mc.projects.value(c[0]).value(QLatin1String("workspaceRoot")).toString());
  });
  step(S("the user looks at the app"), [](World& world, const Captures&, const Table&) { world.sync(); });

  // What the phone shows.
  step(S("the project %1 is listed for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return projectNames(world).contains(c[0]); },
                  [&] { return S("%1 to be listed; the thread list has %2").arg(c[0], projectNames(world).join(S(", "))); });
  });
  step(S("the project %1 is no longer listed").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return !projectNames(world).contains(c[0]) && !world.mc.projects.contains(kCloneProject); },
                  [&] { return S("%1 to go; the sidebar is %2").arg(c[0], show(world.state(S("sidebar")))); });
  });
  step(S("no second project is created"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(world.mc.projects.size() == 1, S("the MC has %1 projects").arg(world.mc.projects.size()));
  });
  step(S("a draft thread opens in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return at(world.state(S("route")), S("kind")) == QLatin1String("draft"); },
                  [&] { return S("a draft; the route is %1").arg(show(world.state(S("route")))); });
    const QJsonObject project = draftProject(world);
    expect(project.value(QLatin1String("title")) == c[0], S("the draft is in %1").arg(QString::fromUtf8(QJsonDocument(project).toJson(QJsonDocument::Compact))));
  });
  step(S("the thread %1 opens").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return shownThread(world) == c[0]; },
                  [&] { return S("%1 to open; the phone shows %2").arg(c[0], shownThread(world)); });
  });
  step(S("the desktop keeps (\\d+) drafts?"), [](World& world, const Captures& c, const Table&) {
    world.sync();
    const int kept = world.native().controller<DraftController>()->drafts().size();
    expect(kept == c[0].toInt(), S("the app keeps %1 drafts").arg(kept));
  });
  step(S("the user sees an? %1 toast %1 saying %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap toast = waitForToast(world, c[1]);
    expect(toast.value(S("type")) == c[0] && toast.value(S("description")) == c[2], S("the toast is %1").arg(show(toast)));
  });

  // Clones.
  step(S("a clone of %1 is receiving objects at (\\d+) percent").arg(q), [](World& world, const Captures& c, const Table&) {
    reportClone(world, c[0], {{S("phase"), S("running")}, {S("stage"), S("receiving")}, {S("percent"), c[1].toInt()}});
  });
  step(S("a clone of %1 is receiving objects at (\\d+) percent on another machine of the cluster").arg(q),
       [](World& world, const Captures& c, const Table&) {
         world.mc.join(kMember);
         world.waitFor(
             [&] {
               for (const int id : world.mc.subscribers(S("projectClones"))) {
                 if (world.mc.shapeOf(id).value(QLatin1String("environment")) == kMember) return true;
               }
               return false;
             },
             S("the clones of the other machine to be followed"));
         reportClone(world, c[0], {{S("phase"), S("running")}, {S("stage"), S("receiving")}, {S("percent"), c[1].toInt()}}, kMember);
       });
  step(S("a clone of %1 finished").arg(q), [](World& world, const Captures& c, const Table&) {
    reportClone(world, c[0], {{S("phase"), S("done")}, {S("stage"), S("checkout")}, {S("percent"), 100}});
  });
  step(S("a clone of %1 failed").arg(q), [](World& world, const Captures& c, const Table&) {
    reportClone(world, c[0], {{S("phase"), S("failed")}, {S("error"), S("Repository not found.")}});
  });
  step(S("the user sees %1 with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap toast = waitForToast(world, c[0]);
    expect(toast.value(S("description")) == c[1], show(toast));
  });
  step(S("the user sees %1 with its destination folder").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap toast = waitForToast(world, c[0]);
    expect(toast.value(S("description")) == fakeFiles(world.mc).home + S("/shop"), show(toast));
  });
  step(S("the user can cancel the clone"), [](World& world, const Captures&, const Table&) {
    choose(world, S("Cloning acme/shop"), S("Cancel"));
    world.waitFor(
        [&] {
          const auto& calls = clones(world).calls;
          return std::any_of(calls.cbegin(), calls.cend(), [](const auto& call) {
            return call.first == u"projectClone.cancel" && call.second.value(QLatin1String("projectId")) == kCloneProject;
          });
        },
        S("the clone to be cancelled"));
    // The toast stays, to say how the cancel went.
    waitForToast(world, S("Cloning acme/shop"));
  });
  step(S("the user can open the project"), [](World& world, const Captures&, const Table&) {
    choose(world, S("Cloned acme/shop"), S("Open project"));
    world.waitFor([&] { return draftProject(world).value(QLatin1String("id")) == kCloneProject; },
                  [&] { return show(world.state(S("route"))); });
  });
  step(S("the user removes the project from the clone's failure notice"), [](World& world, const Captures&, const Table&) {
    choose(world, S("Failed to clone acme/shop"), S("Remove project"));
  });
});

}  // namespace
