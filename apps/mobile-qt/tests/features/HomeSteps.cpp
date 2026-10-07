// The home screen (features/mobile/home-and-thread-list.feature): the thread
// list narrowed to a project and back, and the archive, reached from the
// home screen's own bar as the user reaches them.

#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>

#include "Harness.h"
#include "NativeShell.h"
#include "Phone.h"
#include "ShellStore.h"
#include "World.h"

namespace {

// The MC's archive: its projects, and the threads it has archived.
const FakeMc::Extension archive([](FakeMc& mc) {
  mc.onRpc(QStringLiteral("orchestration.getArchivedShellSnapshot"), [&mc](const FakeMc::Rpc& rpc) {
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

const Steps steps([] {
  using S = QString;

  // A long press on one of the project's threads opens its menu, which
  // narrows the list to its project.
  step(S("the user shows only the project %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    const QStringList threads = heldThreads(world, c[0], true);
    expect(!threads.isEmpty(), S("%1 has no thread to start from").arg(c[0]));
    world.hold(threadRow(world, threads.first()), [&] { return world.popupShowing(S("mobileMenu")); }, S("the thread's menu"));
    world.awaitPopup(S("mobileMenu"));
    QQuickItem* filter = world.findWhere([&](QQuickItem* candidate) {
      return candidate->objectName().startsWith(QLatin1String("mobileMenuItem:")) &&
             candidate->property("modelData").toMap().value(S("label")).toString() == S("Filter by %1").arg(c[0]);
    });
    expect(filter != nullptr, S("the menu does not offer it; it says: %1").arg(screenTexts(world)));
    world.tap(filter);
    world.awaitPopup(S("mobileMenu"), false);
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
  step(S("the user opens archived threads"), [](World& world, const Captures&, const Table&) {
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
  });

  step(S("the user is told threads they archive will appear there"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.shows(S("No archived threads")); }, [&] { return S("the archive to say it is empty; the screen says: %1").arg(screenTexts(world)); });
    expect(world.shows(S("Archived threads will appear here.")), S("the screen says: %1").arg(screenTexts(world)));
  });
});

}  // namespace
