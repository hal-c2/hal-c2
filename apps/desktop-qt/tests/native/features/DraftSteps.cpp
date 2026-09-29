// The desktop's drafts (DraftController): starting a new thread, the draft in
// the sidebar and the window, its menu, and the thread it becomes
// (features/threads/drafts.feature, threads/creating.feature,
// navigation/layout.feature), and the draft a window with no thread lands on
// (navigation/landing.feature).

#include <QDir>
#include <QJsonObject>

#include "DraftController.h"
#include "Harness.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "World.h"

namespace {

DraftController* drafts(World& world) {
  return world.native().controller<DraftController>();
}

std::optional<DraftController::Draft> lastDraft(World& world) {
  return drafts(world)->draft(world.draftId);
}

QString sidebarProjectName(World& world, const QString& environmentId, const QString& projectId) {
  const QString physical = environmentId + QLatin1Char(':') + projectId;
  for (const QVariant& project : at(world.state(QStringLiteral("sidebar")), QStringLiteral("localProjects")).toList()) {
    const QVariantMap map = project.toMap();
    if (map.value(QStringLiteral("key")) == physical) return map.value(QStringLiteral("displayName")).toString();
  }
  return physical;
}

// Where NativeShell keeps the drafts (setStoreDirs); a folder in its place
// makes every save fail.
QString draftsFile(World& world) {
  return QDir(world.homeDir()).filePath(QStringLiteral("data/shell-drafts.json"));
}

QStringList sidebarDraftIds(World& world) {
  QStringList ids;
  for (const QVariant& draft : at(world.state(QStringLiteral("sidebar")), QStringLiteral("drafts")).toList()) {
    ids.append(draft.toMap().value(QStringLiteral("draftId")).toString());
  }
  return ids;
}

// The one draft `sidebar` lists is the draft the steps talk about, reading `label`.
void expectListedDraft(World& world, const QVariant& sidebar, const QString& label) {
  const QVariantList drafts = at(sidebar, QStringLiteral("drafts")).toList();
  expect(drafts.size() == 1 && drafts.first().toMap().value(QStringLiteral("draftId")) == world.draftId &&
             drafts.first().toMap().value(QStringLiteral("label")) == label,
         QStringLiteral("the sidebar lists the drafts %1, not %2 reading %3").arg(show(drafts), world.draftId, label));
}

// The window shows a draft in the project named `name`; it becomes the draft the steps talk about.
// The project the header named when the user chose it.
QString& headerProject() {
  static QString name;
  return name;
}

void expectNewDraft(World& world, const QString& name) {
  world.sync();
  const QVariant route = world.state(QStringLiteral("route"));
  expect(at(route, QStringLiteral("kind")) == QLatin1String("draft"), QStringLiteral("the route is %1").arg(show(route)));
  world.draftId = at(route, QStringLiteral("draftId")).toString();
  const auto draft = lastDraft(world);
  expect(draft.has_value(), QStringLiteral("the shell has no draft %1").arg(world.draftId));
  const QString project = sidebarProjectName(world, draft->environmentId, draft->projectId);
  expect(project == name, QStringLiteral("the draft is in %1").arg(project));
}

void expectRouteDraft(World& world, const QString& id) {
  world.sync();
  const QVariant route = world.state(QStringLiteral("route"));
  expect(at(route, QStringLiteral("kind")) == QLatin1String("draft") && at(route, QStringLiteral("draftId")) == id,
         QStringLiteral("the route is %1").arg(show(route)));
}

const Steps steps([] {
  const QString q = kQuoted;

  // The user.
  step(QStringLiteral("the user starts a new thread"), [](World& world, const Captures&, const Table&) {
    world.startNewThread(QVariantMap());
  });
  step(QStringLiteral("the user opens the draft from the sidebar"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("draft.open"), QVariantMap{{QStringLiteral("draftId"), world.draftId}});
  });
  step(QStringLiteral("the user opens the draft's menu at (\\d+), (\\d+)"), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("draft.menu"), QVariantMap{
                                                              {QStringLiteral("draftId"), world.draftId},
                                                              {QStringLiteral("x"), c[0].toDouble()},
                                                              {QStringLiteral("y"), c[1].toDouble()},
                                                          });
  });

  // The page.
  step(QStringLiteral("the page lands on its own draft %1 for the thread %1 in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.pageOpens({{QStringLiteral("kind"), QStringLiteral("draft")},
                     {QStringLiteral("draftId"), c[0]},
                     {QStringLiteral("environmentId"), world.node.environmentId},
                     {QStringLiteral("projectId"), c[2]},
                     {QStringLiteral("threadId"), c[1]}},
                    true);
  });
  step(QStringLiteral("the page is asked to open the draft for its thread in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const auto draft = lastDraft(world);
    expect(draft.has_value(), QStringLiteral("the shell has no draft %1").arg(world.draftId));
    world.waitFor([&] {
      for (const QVariantMap& follow : world.follows) {
        if (follow.value(QStringLiteral("kind")) == QLatin1String("draft") && follow.value(QStringLiteral("draftId")) == draft->id &&
            follow.value(QStringLiteral("environmentId")) == world.node.environmentId &&
            follow.value(QStringLiteral("projectId")) == c[0] && follow.value(QStringLiteral("threadId")) == draft->threadId) {
          return true;
        }
      }
      return false;
    }, [&] { return QStringLiteral("to follow the draft; the page got %1").arg(world.describePage()); });
  });

  // The node.
  step(QStringLiteral("the node creates the draft's thread"), [](World& world, const Captures&, const Table&) {
    const auto draft = lastDraft(world);
    expect(draft.has_value(), QStringLiteral("the shell has no draft %1").arg(world.draftId));
    const QJsonObject row{
        {QStringLiteral("id"), draft->threadId},
        {QStringLiteral("projectId"), draft->projectId},
        {QStringLiteral("title"), QStringLiteral("Started")},
        {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:59:00Z")},
        {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:59:00Z")},
    };
    world.node.threads.insert(draft->threadId, row);
    world.node.sendRow(draft->threadId, row);
    world.sync();
  });

  // The header's project label (navigation/layout.feature).
  step(QStringLiteral("the user chooses the project name in the header"), [](World& world, const Captures&, const Table&) {
    world.sync();
    headerProject() = at(world.state(QStringLiteral("workspace")), QStringLiteral("projectTitle")).toString();
    expect(!headerProject().isEmpty(), QStringLiteral("the header names no project"));
    world.bridge().dispatch(QStringLiteral("workspace.newThread"), QVariantMap{});
  });
  step(QStringLiteral("a new thread starts in that project"), [](World& world, const Captures&, const Table&) {
    expectNewDraft(world, headerProject());
  });

  // What the shell shows.
  step(QStringLiteral("(?:the window shows a new draft|a new thread starts) in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expectNewDraft(world, c[0]);
  });
  step(QStringLiteral("a draft thread opens in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return at(world.state(QStringLiteral("route")), QStringLiteral("kind")) == QLatin1String("draft"); },
                  [&] { return QStringLiteral("a draft; the route is %1").arg(show(world.state(QStringLiteral("route")))); });
    expectNewDraft(world, c[0]);
  });
  step(QStringLiteral("the window shows the draft"), [](World& world, const Captures&, const Table&) {
    expectRouteDraft(world, world.draftId);
  });
  step(QStringLiteral("the window shows the draft's thread"), [](World& world, const Captures&, const Table&) {
    world.sync();
    const QVariant route = world.state(QStringLiteral("route"));
    expect(at(route, QStringLiteral("kind")) == QLatin1String("thread") && !lastDraft(world) &&
               at(route, QStringLiteral("threadKey")).toString().startsWith(world.node.environmentId + QLatin1Char(':')),
           QStringLiteral("the route is %1").arg(show(route)));
    const QString threadKey = at(route, QStringLiteral("threadKey")).toString();
    expect(world.node.threads.value(threadKey.section(u':', 1)).value(QLatin1String("title")) == QLatin1String("Started"),
           QStringLiteral("the window shows %1, not the draft's thread").arg(threadKey));
  });
  step(QStringLiteral("the sidebar marks the draft as open"), [](World& world, const Captures&, const Table&) {
    world.sync();
    const QVariant sidebar = world.state(QStringLiteral("sidebar"));
    expect(at(sidebar, QStringLiteral("activeDraftId")) == world.draftId && at(sidebar, QStringLiteral("activeThreadKey")).isNull(),
           QStringLiteral("the sidebar is %1").arg(show(sidebar)));
  });
  step(QStringLiteral("the sidebar lists the draft reading %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expectListedDraft(world, world.state(QStringLiteral("sidebar")), c[0]);
  });
  step(QStringLiteral("the new window's sidebar lists the draft reading %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    const auto& windows = world.native().windows();
    expect(windows.size() == 2, QStringLiteral("%1 windows are open").arg(windows.size()));
    expectListedDraft(world, windows.at(1)->bridge()->state()->value(QStringLiteral("sidebar")), c[0]);
  });
  step(QStringLiteral("(?:the sidebar lists no drafts|the thread list does not list the empty draft)"),
       [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(sidebarDraftIds(world).isEmpty(), QStringLiteral("the sidebar lists the drafts %1").arg(sidebarDraftIds(world).join(u", ")));
  });
  // Landing (navigation/landing.feature).
  step(QStringLiteral("the desktop can not keep its drafts"), [](World& world, const Captures&, const Table&) {
    expect(QDir().mkpath(draftsFile(world)), QStringLiteral("could not block %1").arg(draftsFile(world)));
  });
  step(QStringLiteral("the desktop can keep its drafts again"), [](World& world, const Captures&, const Table&) {
    expect(QDir(draftsFile(world)).removeRecursively(), QStringLiteral("could not unblock %1").arg(draftsFile(world)));
  });
  step(QStringLiteral("the window says it couldn't start a new thread"), [](World& world, const Captures&, const Table&) {
    world.sync();
    const QVariant route = world.state(QStringLiteral("route"));
    expect(at(route, QStringLiteral("kind")) == QLatin1String("home"), QStringLiteral("the route is %1").arg(show(route)));
    const QVariant landing = world.state(QStringLiteral("landing"));
    expect(at(landing, QStringLiteral("failed")).toBool(), QStringLiteral("landing is %1").arg(show(landing)));
  });
  step(QStringLiteral("the user tries again"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("landing.retry"), QVariantMap{});
  });
  step(QStringLiteral("the user opens a new window"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("window.new"), QVariantMap{});
    world.sync();
  });
  step(QStringLiteral("the new window shows the first window's draft"), [](World& world, const Captures&, const Table&) {
    world.sync();
    const auto& windows = world.native().windows();
    expect(windows.size() == 2, QStringLiteral("%1 windows are open").arg(windows.size()));
    const auto first = windows.at(0)->controller<NavigationController>()->route();
    const auto second = windows.at(1)->controller<NavigationController>()->route();
    expect(first.kind == QLatin1String("draft") && second == first,
           QStringLiteral("the windows show %1 %2 and %3 %4").arg(first.kind, first.draftId, second.kind, second.draftId));
  });

  step(QStringLiteral("the desktop keeps the draft(?: %1)?").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    const QString id = c.value(0).isEmpty() ? world.draftId : c[0];
    expect(drafts(world)->draft(id).has_value(), QStringLiteral("the desktop keeps no draft %1").arg(id));
  });
  step(QStringLiteral("the desktop keeps (\\d+) drafts?"), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(drafts(world)->drafts().size() == c[0].toInt(), QStringLiteral("the desktop keeps %1 drafts").arg(drafts(world)->drafts().size()));
  });
});

}  // namespace
