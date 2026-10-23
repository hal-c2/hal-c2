// The home screen (features/mobile/home-and-thread-list.feature): the thread
// list narrowed to a project and back, the settled shelf a page at a time
// (threads/sidebar-list.feature), and the archive, reached from the home
// screen's own bar as the user reaches them.

#include <QDateTime>
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

  step(S("the user looks at the settled section"), [](World& world, const Captures&, const Table&) {
    world.sync();
    threadList(world);
  });

  // The rows past the screen are not drawn, so the count is the list's.
  step(S("(\\d+) settled threads are shown"), [](World& world, const Captures& c, const Table&) {
    const auto shown = [&] { return world.state(S("sidebar")).toMap().value(S("settled")).toList().size(); };
    world.waitFor([&] { return shown() == c[0].toInt(); }, [&] { return S("%1 settled threads; the list has %2").arg(c[0]).arg(shown()); });
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
