// The home screen (features/mobile/home-and-thread-list.feature): the thread
// list narrowed to a project and back, the settled shelf a page at a time and
// with or without the threads plugins settled (threads/sidebar-list.feature),
// and the archive, reached from the home screen's own bar as the user reaches
// them.

#include <QDateTime>
#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>

#include <algorithm>

#include "Harness.h"
#include "NativeShell.h"
#include "Phone.h"
#include "ShellStore.h"
#include "World.h"

namespace {

// The MC's side of the archive: how often it was asked, an answer it refuses,
// and whether it holds its answer back (scenarios that need the archive to be
// loading).
struct ArchiveCalls {
  int asked = 0;
  QString refusal;
};

const QString kArchiveHold = QStringLiteral("archive");

// The MC's archive: its projects, and the threads it has archived.
const FakeMc::Extension archive([](FakeMc& mc) {
  mc.onRpc(QStringLiteral("orchestration.getArchivedShellSnapshot"), [&mc](const FakeMc::Rpc& rpc) {
    ++mc.part<ArchiveCalls>().asked;
    const auto answer = [&mc, rpc] {
      const QString refusal = mc.part<ArchiveCalls>().refusal;
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
    if (mc.holding(kArchiveHold)) return mc.defer(answer);
    answer();
  });
});

QString screenTexts(World& world) {
  return world.texts().join(QStringLiteral(" | "));
}

// The titles of the threads the list shows now.
QStringList listedThreads(World& world) {
  QStringList titles;
  world.findWhere([&](QQuickItem* candidate) {
    if (candidate->objectName().startsWith(QLatin1String("threadRow:"))) titles.append(candidate->property("item").toMap().value(QStringLiteral("title")).toString());
    return false;
  });
  titles.sort();
  return titles;
}

// The titles of the threads the phone holds, those of `project` or of every other.
QStringList heldThreads(World& world, const QString& project, bool inIt) {
  QStringList titles;
  for (const sidebar::Thread& thread : world.native().store()->threads()) {
    if ((thread.projectId == project) == inIt) titles.append(thread.title);
  }
  titles.sort();
  return titles;
}

// The phone is paired and holds one thread in each of "shop" and "docs", the
// two projects the scenarios narrow the list to, when the scenario gave it none.
void haveShopAndDocs(World& world) {
  using S = QString;
  for (const QString& project : {S("shop"), S("docs")}) {
    if (!world.mc.projects.contains(project)) {
      const QJsonObject row{{S("id"), project}, {S("title"), project}, {S("workspaceRoot"), S("/work/") + project},
                            {S("scripts"), QJsonArray()}, {S("createdAt"), S("2026-09-01T09:00:00Z")},
                            {S("updatedAt"), S("2026-09-01T09:00:00Z")}};
      world.mc.projects.insert(project, row);
      world.mc.sendRow(project, row, S("project"));
    }
    if (heldThreads(world, project, true).isEmpty()) {
      const QString id = S("thread-in-") + project;
      const QJsonObject row{{S("id"), id}, {S("title"), project == S("shop") ? S("Fix cart") : S("Update readme")},
                            {S("projectId"), project}, {S("createdAt"), S("2026-09-23T09:00:00Z")},
                            {S("updatedAt"), S("2026-09-23T09:00:00Z")}};
      world.mc.threads.insert(id, row);
      world.mc.sendRow(id, row);
    }
  }
  for (const QString& project : {S("shop"), S("docs")}) {
    world.waitFor([&] { return !heldThreads(world, project, true).isEmpty(); }, S("the phone to hold a thread of %1").arg(project));
  }
  threadList(world);
}

void showOnlyProject(World& world, const QString& project) {
  using S = QString;
  haveShopAndDocs(world);
  const QStringList threads = heldThreads(world, project, true);
  expect(!threads.isEmpty(), S("%1 has no thread to start from").arg(project));
  world.hold(threadRow(world, threads.first()), [&] { return world.popupShowing(S("mobileMenu")); }, S("the thread's menu"));
  world.awaitPopup(S("mobileMenu"));
  QQuickItem* filter = world.findWhere([&](QQuickItem* candidate) {
    return candidate->objectName().startsWith(QLatin1String("mobileMenuItem:")) &&
           candidate->property("modelData").toMap().value(S("label")).toString() == S("Filter by %1").arg(project);
  });
  expect(filter != nullptr, S("the menu does not offer it; it says: %1").arg(screenTexts(world)));
  world.tap(filter);
  world.awaitPopup(S("mobileMenu"), false);
}

// The user opens archived threads: home's bar, then Settings' sections.
void openArchive(World& world) {
  using S = QString;
  world.item(S("homeScreen"));
  world.tap(S("settings"));
  world.item(S("settingsSections"));
  QQuickItem* section = nullptr;
  world.waitFor(
      [&] {
        section = world.findWhere([](QQuickItem* candidate) {
          return candidate->objectName().startsWith(QLatin1String("settingsRow")) &&
                 candidate->property("modelData").toMap().value(QStringLiteral("to")).toString() == QLatin1String("/settings/archived");
        });
        return section != nullptr;
      },
      [&] { return S("the archive among the settings; the screen says: %1").arg(screenTexts(world)); });
  world.tap(section);
  world.item(S("archivedThreads"));
}

// The MC archives the thread titled `title`, made in "shop" when it has none.
void archiveThread(World& world, const QString& title) {
  const QString id = haveThread(world, title);
  QJsonObject row = world.mc.threads.value(id);
  row.insert(QStringLiteral("archivedAt"), QStringLiteral("2026-09-23T09:30:00Z"));
  world.mc.threads.insert(id, row);
  world.mc.sendRow(id, row);
}

bool archiveLists(World& world, const QString& title) {
  const QVariantList groups = world.state(QStringLiteral("archivedThreads")).toMap().value(QStringLiteral("groups")).toList();
  for (const QVariant& group : groups) {
    for (const QVariant& thread : group.toMap().value(QStringLiteral("threads")).toList()) {
      if (thread.toMap().value(QStringLiteral("title")) == title) return true;
    }
  }
  return false;
}

// The settled shelf's "Show N more" row, scrolled to as the user would; null
// when the shelf lists every settled thread.
QQuickItem* settledMore(World& world) {
  QQuickItem* list = threadList(world)->findChild<QQuickItem*>(QStringLiteral("list"));
  expect(list != nullptr, QStringLiteral("the thread list has no rows"));
  QMetaObject::invokeMethod(list, "positionViewAtEnd");
  return world.find(QStringLiteral("settledMore"));
}

QString moreLabel(QQuickItem* more) {
  for (QQuickItem* child : more->childItems()) {
    if (child->property("text").isValid()) return child->property("text").toString();
  }
  return {};
}

const Steps steps([] {
  using S = QString;

  // The environment holds the two projects and no threads yet; the phone
  // pairs once a step has given it threads.
  step(S("a connected environment with the projects %1 and %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    world.mc.projects.clear();
    world.mc.threads.clear();
    for (const QString& name : c) {
      world.mc.projects.insert(name, {{S("id"), name}, {S("title"), name}, {S("workspaceRoot"), S("/work/") + name},
                                      {S("scripts"), QJsonArray()}, {S("createdAt"), S("2026-09-01T09:00:00Z")},
                                      {S("updatedAt"), S("2026-09-01T09:00:00Z")}});
    }
  });

  step(S("there are (\\d+) settled threads"), [](World& world, const Captures& c, const Table&) {
    const QDateTime newest = QDateTime::fromString(S("2026-09-23T09:00:00Z"), Qt::ISODate);
    for (int index = 0; index < c[0].toInt(); ++index) {
      const QString id = S("settled-%1").arg(index);
      const QString at = newest.addSecs(-60 * index).toString(Qt::ISODate);
      world.mc.threads.insert(id, {{S("id"), id}, {S("title"), S("Settled %1").arg(index)}, {S("projectId"), S("shop")},
                                   {S("createdAt"), at}, {S("updatedAt"), at},
                                   {S("settledOverride"), S("settled")}, {S("settledAt"), at}});
      world.mc.sendRow(id, world.mc.threads.value(id));
    }
    pairWithEnvironment(world);
  });

  // Threads a plugin settles as it finishes them, as the code-review plugin does.
  step(S("(\\d+) settled threads a plugin started"), [](World& world, const Captures& c, const Table&) {
    const QDateTime newest = QDateTime::fromString(S("2026-09-23T09:00:30Z"), Qt::ISODate);
    for (int index = 1; index <= c[0].toInt(); ++index) {
      const QString id = S("review-%1").arg(index);
      const QString at = newest.addSecs(-60 * index).toString(Qt::ISODate);
      world.mc.threads.insert(id, {{S("id"), id}, {S("title"), S("Review %1").arg(index)}, {S("projectId"), S("shop")},
                                   {S("createdAt"), at}, {S("updatedAt"), at},
                                   {S("settledOverride"), S("settled")}, {S("settledAt"), at},
                                   {S("plugin"), QJsonObject{{S("id"), S("code-review")}, {S("kind"), S("review")}, {S("listed"), true}}}});
      world.mc.sendRow(id, world.mc.threads.value(id));
    }
    pairWithEnvironment(world);
  });

  // Home's bar, Settings → General, the row's switch, and back home.
  step(S("the user turns (on|off) \"Show plugin threads in Settled\""), [](World& world, const Captures& c, const Table&) {
    const bool on = c[0] == QLatin1String("on");
    world.item(S("homeScreen"));
    world.tap(S("settings"));
    world.item(S("settingsSections"));
    QQuickItem* general = nullptr;
    world.waitFor(
        [&] {
          general = world.findWhere([](QQuickItem* candidate) {
            return candidate->objectName().startsWith(QLatin1String("settingsRow")) &&
                   candidate->property("modelData").toMap().value(QStringLiteral("to")).toString() == QLatin1String("/settings/general");
          });
          return general != nullptr;
        },
        [&] { return S("General among the settings; the screen says: %1").arg(screenTexts(world)); });
    world.tap(general);
    QQuickItem* row = nullptr;
    world.waitFor([&] { return (row = world.find(S("settingsRow:sidebarShowSettledPluginThreads"))) != nullptr; },
                  [&] { return S("the row among the general settings; the screen says: %1").arg(screenTexts(world)); });
    // Scrolled to, as the user would: the page is taller than the phone.
    QQuickItem* page = row->parentItem();
    while (page && !page->inherits("QQuickFlickable")) page = page->parentItem();
    expect(page != nullptr, S("the general settings do not scroll"));
    QQuickItem* content = page->property("contentItem").value<QQuickItem*>();
    page->setProperty("contentY", std::max(0.0, row->mapToItem(content, QPointF(0, 0)).y() - page->height() / 2));
    QQuickItem* control = nullptr;
    for (QQuickItem* child : row->findChildren<QQuickItem*>()) {
      if (child->objectName() == QLatin1String("control")) control = child;
    }
    expect(control != nullptr, S("the row has no switch"));
    if (control->property("checked").toBool() != on) world.tap(control);
    world.waitFor([&] { return control->property("checked").toBool() == on; }, S("the switch to turn %1").arg(c[0]));
    for (int presses = 0; presses < 3 && world.find(S("settingsScreen")) != nullptr; ++presses) world.back();
    world.waitFor([&] { return world.find(S("settingsScreen")) == nullptr; }, [&] { return S("home again; the screen says: %1").arg(screenTexts(world)); });
    world.item(S("homeScreen"));
  });

  step(S("the user looks at the settled section"), [](World& world, const Captures&, const Table&) {
    world.sync();
    threadList(world);
  });

  // The rows past the screen are not drawn, so the count is the list's.
  step(S("(\\d+) settled threads are shown"), [](World& world, const Captures& c, const Table&) {
    const auto shown = [&] { return world.state(S("sidebar")).toMap().value(S("settled")).toList().size(); };
    world.waitFor([&] { return shown() == c[0].toInt(); }, [&] { return S("%1 settled threads; the list has %2").arg(c[0]).arg(shown()); });
  });

  step(S("the settled section counts (\\d+) threads"), [](World& world, const Captures& c, const Table&) {
    const auto total = [&] { return world.state(S("sidebar")).toMap().value(S("settledTotal")).toInt(); };
    world.waitFor([&] { return total() == c[0].toInt(); }, [&] { return S("the settled section counts %1 threads").arg(total()); });
  });

  step(S("the section offers %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    QString offered;
    world.waitFor(
        [&] {
          QQuickItem* more = settledMore(world);
          offered = more ? moreLabel(more) : QString();
          return offered == c[0];
        },
        [&] { return S("%1 under the shelf; it offers \"%2\"").arg(c[0], offered); });
  });

  step(S("the section offers no more"), [](World& world, const Captures&, const Table&) {
    world.sync();
    const QVariantMap state = world.state(S("sidebar")).toMap();
    const qsizetype hidden = state.value(S("settledTotal")).toInt() - state.value(S("settled")).toList().size();
    expect(hidden == 0, S("%1 settled threads are not listed").arg(hidden));
  });

  step(S("the user shows more settled threads"), [](World& world, const Captures&, const Table&) {
    QQuickItem* more = nullptr;
    world.waitFor([&] { return (more = settledMore(world)) != nullptr; },
                  [&] { return S("more to show under the shelf; the screen says: %1").arg(screenTexts(world)); });
    world.tap(more);
  });

  // A long press on one of the project's threads opens its menu, which
  // narrows the list to its project.
  step(S("the user shows only the project %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) { showOnlyProject(world, c[0]); });

  step(S("the list shows only the project %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) { showOnlyProject(world, c[0]); });

  // The project is gone from its environment, and its threads with it.
  step(S("%1 is removed from its environment").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    const QString deletedAt = S("2026-09-23T10:00:00Z");
    for (auto thread = world.mc.threads.begin(); thread != world.mc.threads.end(); ++thread) {
      if (thread->value(S("projectId")).toString() != c[0]) continue;
      thread->insert(S("deletedAt"), deletedAt);
      world.mc.sendRow(thread.key(), *thread);
    }
    QJsonObject project = world.mc.projects.value(c[0]);
    project.insert(S("deletedAt"), deletedAt);
    world.mc.projects.insert(c[0], project);
    world.mc.sendRow(c[0], project, S("project"));
  });

  step(S("only threads in %1 are listed").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    const QStringList others = heldThreads(world, c[0], false);
    expect(!others.isEmpty(), S("the phone holds no thread outside %1 to leave out").arg(c[0]));
    world.waitFor([&] { return listedThreads(world) == heldThreads(world, c[0], true); },
                  [&] { return S("only the threads of %1; the list has %2").arg(c[0], listedThreads(world).join(S(", "))); });
    // And the screen says that it is narrowed, with the way back.
    expect(world.item(S("scopeLabel"))->property("text").toString() == S("Only %1").arg(c[0]), S("the screen says: %1").arg(screenTexts(world)));
  });

  step(S("the user shows all projects"), [](World& world, const Captures&, const Table&) { world.tap(S("scopeClear")); });

  step(S("threads from every project are listed"), [](World& world, const Captures&, const Table&) {
    QStringList all;
    for (const sidebar::Thread& thread : world.native().store()->threads()) all.append(thread.title);
    all.sort();
    world.waitFor([&] { return listedThreads(world) == all; }, [&] { return S("every thread; the list has %1").arg(listedThreads(world).join(S(", "))); });
    expect(world.find(S("scopeBar")) == nullptr, S("the list still says it is narrowed: %1").arg(screenTexts(world)));
  });

  step(S("the user has no archived threads"), [](World& world, const Captures&, const Table&) {
    for (const QJsonObject& thread : std::as_const(world.mc.threads)) {
      expect(!thread.contains(QLatin1String("archivedAt")), S("%1 is archived").arg(thread.value(QLatin1String("title")).toString()));
    }
  });

  // Home's bar leads to settings, whose sections list the archive.
  step(S("the user opens archived threads"), [](World& world, const Captures&, const Table&) { openArchive(world); });

  // Archived elsewhere, by the MC's own row.
  step(S("the thread %1 is archived").arg(kQuoted), [](World& world, const Captures& c, const Table&) { archiveThread(world, c[0]); });

  step(S("the user archived %1 on another device after the phone last listed archived threads").arg(kQuoted),
       [](World& world, const Captures& c, const Table&) {
         // The phone lists the archive once, and leaves it.
         openArchive(world);
         world.waitFor([&] { return world.state(S("archivedThreads")).toMap().value(S("status")).toString() != S("loading"); },
                       [&] { return S("the archive to be listed; it is %1").arg(show(world.state(S("archivedThreads")))); });
         world.back();
         world.waitFor([&] { return world.find(S("archivedThreads")) == nullptr; }, S("the archive to close"));
         world.back();
         world.item(S("homeScreen"));
         archiveThread(world, c[0]);
       });

  step(S("the phone has not yet heard back about archived threads"), [](World& world, const Captures&, const Table&) { world.mc.hold(kArchiveHold); });

  step(S("the user is told the archive is loading"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.shows(S("Loading archived threads")); },
                  [&] { return S("the archive to say it is loading; the screen says: %1").arg(screenTexts(world)); });
  });

  // The environment refuses to list its archive; the page says so and offers another try.
  step(S("the user was told not every archive could be loaded"), [](World& world, const Captures&, const Table&) {
    world.mc.part<ArchiveCalls>().refusal = S("The archive is unavailable");
    openArchive(world);
    world.waitFor([&] { return world.shows(S("Could not load archived threads")); },
                  [&] { return S("the archive to say it failed; the screen says: %1").arg(screenTexts(world)); });
    world.mc.part<ArchiveCalls>().refusal.clear();
  });

  step(S("the user chooses to try again"), [](World& world, const Captures&, const Table&) {
    world.mc.part<ArchiveCalls>().asked = 0;
    QQuickItem* again = world.findWhere([](QQuickItem* candidate) { return candidate->property("text").toString() == QLatin1String("Try again"); });
    expect(again != nullptr, S("the archive offers no way to try again; the screen says: %1").arg(screenTexts(world)));
    world.tap(again);
  });

  step(S("the phone asks the environments for their archived threads again"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.mc.part<ArchiveCalls>().asked > 0; }, S("the phone to ask for the archive again"));
  });

  step(S("%1 is listed").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return archiveLists(world, c[0]); },
                  [&] { return S("%1 among the archived threads; they are %2").arg(c[0], show(world.state(S("archivedThreads")))); });
  });

  step(S("the user unarchives %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    if (world.find(S("archivedThreads")) == nullptr) openArchive(world);
    QQuickItem* row = nullptr;
    world.waitFor(
        [&] {
          row = world.findWhere([&](QQuickItem* candidate) {
            return candidate->objectName().startsWith(QLatin1String("thread_")) &&
                   candidate->property("modelData").toMap().value(S("title")).toString() == c[0];
          });
          return row != nullptr;
        },
        [&] { return S("%1 among the archived threads; they are %2").arg(c[0], show(world.state(S("archivedThreads")))); });
    QQuickItem* button = nullptr;
    for (QQuickItem* child : row->findChildren<QQuickItem*>()) {
      if (child->objectName() == QLatin1String("unarchive")) button = child;
    }
    expect(button != nullptr, S("%1 has no way back").arg(c[0]));
    world.tap(button);
    // The MC accepts the command and the thread's row loses its archive time.
    const QString id = haveThread(world, c[0]);
    world.waitFor(
        [&] {
          return std::any_of(world.mc.commands.cbegin(), world.mc.commands.cend(), [&](const QJsonObject& command) {
            return command.value(QLatin1String("type")) == QLatin1String("thread.unarchive") &&
                   command.value(QLatin1String("threadId")).toString() == id;
          });
        },
        S("the phone to ask the MC to unarchive %1").arg(c[0]));
    QJsonObject restored = world.mc.threads.value(id);
    restored.remove(S("archivedAt"));
    world.mc.threads.insert(id, restored);
    world.mc.sendRow(id, restored);
  });

  step(S("%1 is listed on the home screen again").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    for (int presses = 0; presses < 3 && world.find(S("homeScreen")) == nullptr; ++presses) world.back();
    world.item(S("homeScreen"));
    threadRow(world, c[0]);
  });

  step(S("the user is told threads they archive will appear there"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.shows(S("No archived threads")); }, [&] { return S("the archive to say it is empty; the screen says: %1").arg(screenTexts(world)); });
    expect(world.shows(S("Archived threads will appear here.")), S("the screen says: %1").arg(screenTexts(world)));
  });
});

}  // namespace
