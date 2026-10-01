// The Archive settings section on the desktop (ArchivedThreadsController):
// the archived threads scenarios of features/threads/archive-delete.feature.
// The Background's thread and project come from ThreadMenuSteps, whose MC
// follows the thread commands it accepts.

#include <QJsonArray>
#include <QJsonObject>

#include "Harness.h"
#include "NavigationController.h"
#include "Onboarding.h"
#include "World.h"

namespace {

// The MC's side: `orchestration.getArchivedShellSnapshot`, held while the
// scenario says the environments are still being checked.
struct FakeArchive {
  QString refusal;
};

const QString kHold = QStringLiteral("archive");
const QString kArchivedAt = QStringLiteral("2026-09-23T09:30:00Z");

const FakeMc::Extension extension([](FakeMc& mc) {
  mc.onRpc(QStringLiteral("orchestration.getArchivedShellSnapshot"), [&mc](const FakeMc::Rpc& rpc) {
    const auto answer = [&mc, rpc] {
      const QString refusal = mc.part<FakeArchive>().refusal;
      if (!refusal.isEmpty()) return mc.refuse(rpc, refusal);
      QJsonArray projects;
      for (const QJsonObject& project : std::as_const(mc.projects)) projects.append(project);
      QJsonArray threads;
      for (const QJsonObject& thread : std::as_const(mc.threads)) {
        if (thread.contains(QLatin1String("archivedAt"))) threads.append(thread);
      }
      mc.reply(rpc, QJsonObject{{QStringLiteral("schemaVersion"), 1},
                                  {QStringLiteral("snapshotSequence"), 0},
                                  {QStringLiteral("projects"), projects},
                                  {QStringLiteral("threads"), threads}});
    };
    if (mc.holding(kHold)) return mc.defer(answer);
    answer();
  });
});

// The MC's thread titled `title`, made in `project` when it has none.
QString threadNamed(World& world, const QString& title, const QString& project = {}) {
  for (auto row = world.mc.threads.cbegin(); row != world.mc.threads.cend(); ++row) {
    if (row.value().value(QLatin1String("title")).toString() == title) return row.key();
  }
  expect(!project.isEmpty(), QStringLiteral("no thread is titled \"%1\"").arg(title));
  const QString id = QStringLiteral("t%1").arg(world.mc.threads.size() + 1);
  world.mc.threads.insert(id, {{QStringLiteral("id"), id},
                                 {QStringLiteral("title"), title},
                                 {QStringLiteral("projectId"), project},
                                 {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T08:00:00Z")},
                                 {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T08:00:00Z")}});
  return id;
}

void ensureProject(World& world, const QString& id) {
  if (world.mc.projects.contains(id)) return;
  const QJsonObject row{{QStringLiteral("id"), id},
                        {QStringLiteral("title"), id},
                        {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + id},
                        {QStringLiteral("scripts"), QJsonArray()},
                        {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                        {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")}};
  world.mc.projects.insert(id, row);
  world.mc.sendRow(id, row, QStringLiteral("project"));
}

void archive(World& world, const QString& title, const QString& project = {}) {
  if (!project.isEmpty()) ensureProject(world, project);
  const QString id = threadNamed(world, title, project);
  QJsonObject& row = world.mc.threads[id];
  row.insert(QStringLiteral("archivedAt"), kArchivedAt);
  world.mc.sendRow(id, row);
}

void open(World& world) {
  world.sync();
  world.native().controller<NavigationController>()->open(
      NavigationController::Route::settings(NavigationController::kArchivedSection));
}

// The listed groups, as "project: thread, thread".
QVariantList groups(World& world) {
  return at(world.state(QStringLiteral("archivedThreads")), QStringLiteral("groups")).toList();
}

std::optional<QVariantMap> listed(World& world, const QString& title) {
  for (const QVariant& group : groups(world)) {
    for (const QVariant& thread : group.toMap().value(QStringLiteral("threads")).toList()) {
      if (thread.toMap().value(QStringLiteral("title")) == title) return thread.toMap();
    }
  }
  return std::nullopt;
}

QString groupOf(World& world, const QString& title) {
  for (const QVariant& group : groups(world)) {
    for (const QVariant& thread : group.toMap().value(QStringLiteral("threads")).toList()) {
      if (thread.toMap().value(QStringLiteral("title")) == title) return group.toMap().value(QStringLiteral("title")).toString();
    }
  }
  return {};
}

QVariantMap waitListed(World& world, const QString& title) {
  world.waitFor([&] { return listed(world, title).has_value(); },
                [&] { return QStringLiteral("%1 in the archived threads; they are %2").arg(title, show(world.state(QStringLiteral("archivedThreads")))); });
  return *listed(world, title);
}

void act(World& world, const QString& action, const QString& title) {
  const QVariantMap thread = waitListed(world, title);
  world.bridge().dispatch(QStringLiteral("archivedThreads.") + action,
                          QVariantMap{{QStringLiteral("environmentId"), thread.value(QStringLiteral("environmentId"))},
                                      {QStringLiteral("threadId"), thread.value(QStringLiteral("threadId"))}});
  world.sync();
  // A delete the user wants confirmed is confirmed.
  const QVariant question = world.state(QStringLiteral("confirmation"));
  if (question.typeId() == QMetaType::QVariantMap) {
    world.bridge().dispatch(QStringLiteral("confirmation.answer"),
                            QVariantMap{{QStringLiteral("requestId"), at(question, QStringLiteral("requestId"))},
                                        {QStringLiteral("accepted"), true}});
  }
}

bool inThreadList(World& world, const QString& title) {
  const QVariantMap sidebar = world.state(QStringLiteral("sidebar")).toMap();
  for (const QString& section : {QStringLiteral("pinned"), QStringLiteral("active"), QStringLiteral("settled"), QStringLiteral("snoozed")}) {
    for (const QVariant& row : sidebar.value(section).toList()) {
      if (row.toMap().value(QStringLiteral("title")) == title) return true;
    }
  }
  return false;
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("%1 is archived").arg(q), [](World& world, const Captures& c, const Table&) {
    archive(world, c[0]);
    world.sync();
  });
  step(QStringLiteral("%1 in %1 and %1 in %1 are archived").arg(q), [](World& world, const Captures& c, const Table&) {
    archive(world, c[0], c[1]);
    archive(world, c[2], c[3]);
    world.sync();
  });
  step(QStringLiteral("the environments are still being checked"), [](World& world, const Captures&, const Table&) {
    world.mc.hold(kHold);
  });
  step(QStringLiteral("no thread has been archived"), [](World& world, const Captures&, const Table&) {
    for (const QJsonObject& thread : std::as_const(world.mc.threads)) {
      expect(!thread.contains(QLatin1String("archivedAt")), QStringLiteral("%1 is archived").arg(thread.value(QLatin1String("title")).toString()));
    }
  });
  step(QStringLiteral("the archived threads cannot be loaded"), [](World& world, const Captures&, const Table&) {
    world.mc.part<FakeArchive>().refusal = QStringLiteral("The archive is unavailable");
  });

  step(QStringLiteral("the user opens the archived threads"), [](World& world, const Captures&, const Table&) {
    open(world);
  });
  // The settings scope's project picker, then the Archive section.
  step(QStringLiteral("the user opens the archived threads from the settings of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    open(world);
    QString key;
    world.waitFor([&] {
      for (const QVariant& row : at(world.state(QStringLiteral("settingsScope")), QStringLiteral("projects")).toList()) {
        if (row.toMap().value(QStringLiteral("title")) == c[0]) key = row.toMap().value(QStringLiteral("key")).toString();
      }
      return !key.isEmpty();
    }, [&] { return QStringLiteral("%1 to be offered; the scope is %2").arg(c[0], show(world.state(QStringLiteral("settingsScope")))); });
    world.bridge().dispatch(QStringLiteral("settingsScope.project"), QVariantMap{{QStringLiteral("key"), key}});
  });
  step(QStringLiteral("the user (restores|deletes) %1 from the archived threads").arg(q), [](World& world, const Captures& c, const Table&) {
    open(world);
    act(world, c[0] == QLatin1String("restores") ? QStringLiteral("unarchive") : QStringLiteral("delete"), c[1]);
  });
  step(QStringLiteral("the user tries to (unarchive|delete) %1 and the environment refuses").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.refusals.insert(QStringLiteral("thread.") + c[0], QStringLiteral("The environment is read-only"));
    open(world);
    act(world, c[0], c[1]);
  });

  step(QStringLiteral("the user sees %1").arg(q), [](World& world, const Captures& c, const Table&) {
    // The archive's page title, or the welcome wizard's (or its recovery page's).
    world.waitFor([&] { return at(world.state(QStringLiteral("archivedThreads")), QStringLiteral("title")) == c[0] || onboardingShows(world, c[0]); },
                  [&] { return QStringLiteral("\"%1\"; the archive shows %2").arg(c[0], show(world.state(QStringLiteral("archivedThreads")))); });
  });
  step(QStringLiteral("%1 is listed under %1 and %1 under %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return groupOf(world, c[0]) == c[1] && groupOf(world, c[2]) == c[3]; },
                  [&] { return QStringLiteral("the groups to be right; they are %1").arg(show(groups(world))); });
  });
  step(QStringLiteral("%1 is no longer in the archived threads").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return !listed(world, c[0]) && at(world.state(QStringLiteral("archivedThreads")), QStringLiteral("status")) == QLatin1String("empty"); },
                  [&] { return QStringLiteral("%1 gone; the archive shows %2").arg(c[0], show(world.state(QStringLiteral("archivedThreads")))); });
    expect(!world.mc.threads.contains(QStringLiteral("t1")), QStringLiteral("the MC still has the thread"));
  });
  step(QStringLiteral("%1 is back in the thread list").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return inThreadList(world, c[0]); },
                  [&] { return QStringLiteral("%1 in the thread list; it is %2").arg(c[0], show(world.state(QStringLiteral("sidebar")))); });
  });
  step(QStringLiteral("the user is told %1 and why").arg(q), [](World& world, const Captures& c, const Table&) {
    const auto told = [&] {
      for (const QVariant& item : world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList()) {
        if (item.toMap().value(QStringLiteral("title")) == c[0] &&
            item.toMap().value(QStringLiteral("description")) == QLatin1String("The environment is read-only")) {
          return true;
        }
      }
      return false;
    };
    world.waitFor(told, [&] { return QStringLiteral("\"%1\"; the toasts are %2").arg(c[0], show(world.state(QStringLiteral("toasts")))); });
  });
  step(QStringLiteral("%1 stays in the archived threads").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    const auto thread = listed(world, c[0]);
    expect(thread.has_value() && !thread->value(QStringLiteral("busy")).toBool(),
           QStringLiteral("the archive shows %1").arg(show(world.state(QStringLiteral("archivedThreads")))));
    expect(world.mc.threads.value(threadNamed(world, c[0])).contains(QLatin1String("archivedAt")), QStringLiteral("the MC's row is not archived"));
  });
});

}  // namespace

// Whether the archive lists only `title` (WorkspaceSteps' "only %1 is
// listed" asks this while the Archive section is open).
bool archiveListsOnly(World& world, const QString& title) {
  const QVariantList listedGroups = groups(world);
  return listedGroups.size() == 1 && listedGroups[0].toMap().value(QStringLiteral("threads")).toList().size() == 1 &&
         listed(world, title);
}
