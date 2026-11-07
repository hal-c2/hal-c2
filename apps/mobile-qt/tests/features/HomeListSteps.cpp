// What a thread row says (features/mobile/home-and-thread-list.feature): the
// status word that needs the user most. The rows are the desktop's own
// SidebarThreadRow, so the words are the ones threads/unread-and-status.feature
// names on the desktop.

#include <QDateTime>
#include <functional>
#include <QJsonObject>
#include <QQuickItem>

#include "Harness.h"
#include "Phone.h"
#include "World.h"

namespace {

QString iso(const QDateTime& at) {
  return at.toUTC().toString(Qt::ISODate);
}

// A running thread moves into the sidebar's Working section, which starts
// folded (threads/sidebar-list.feature); the user unfolds it to see the row.
void unfoldWorking(World& world, const QString& title) {
  const auto listed = [&] {
    return world.findWhere([&](QQuickItem* candidate) {
             return candidate->objectName().startsWith(QLatin1String("threadRow:")) &&
                    candidate->property("item").toMap().value(QStringLiteral("title")).toString() == title;
           }) != nullptr;
  };
  world.waitFor([&] { return listed() || world.find(QStringLiteral("header:working")) != nullptr; },
                [&] { return QStringLiteral("%1 or the Working section in the thread list; the screen says: %2").arg(title, world.texts().join(QStringLiteral(" | "))); });
  if (!listed()) world.tap(QStringLiteral("header:working"));
}

// The thread "Fix cart" the scenarios speak of, with the fields a state adds.
void putState(World& world, const QString& state) {
  using S = QString;
  const QString id = haveThread(world, S("Fix cart"));
  const QDateTime now = QDateTime::currentDateTimeUtc();
  QJsonObject row = world.mc.threads.value(id);
  const auto run = [&](const QString& status) {
    row.insert(S("latestRunId"), S("r1"));
    row.insert(S("status"), status);
    row.insert(S("latestRunStartedAt"), iso(now.addSecs(-900)));
  };
  if (state == QLatin1String("has a turn running")) {
    run(S("running"));
    row.insert(S("activeRunId"), S("r1"));
    // Just started: a longer run adds its time to the word.
    row.insert(S("latestRunStartedAt"), iso(now.addSecs(-5)));
  } else if (state == QLatin1String("has a queued turn waiting to start")) {
    // The session is up and idle; the queued turn has not started a run.
    row.insert(S("activeProviderThreadId"), S("p1"));
    row.insert(S("status"), S("idle"));
  } else if (state.startsWith(QLatin1String("waits for the user")) || state.startsWith(QLatin1String("asks the user"))) {
    run(S("running"));
    row.insert(S("pendingRuntimeRequest"), QJsonObject{{S("id"), S("q1")},
                                                       {S("kind"), state.startsWith(QLatin1String("asks")) ? S("user_input") : S("command_approval")},
                                                       {S("createdAt"), iso(now.addSecs(-60))}});
  } else if (state.contains(QLatin1String("usage limit"))) {
    run(S("failed"));
    row.insert(S("lastErrorClass"), S("usage_limit"));
  } else if (state.contains(QLatin1String("error"))) {
    run(S("failed"));
  } else {  // finished work the user has not looked at
    run(S("completed"));
    row.insert(S("latestRunCompletedAt"), iso(now.addSecs(-600)));
    row.insert(S("updatedAt"), iso(now.addSecs(-600)));
    row.insert(S("lastVisitedAt"), iso(now.addSecs(-3600)));
  }
  world.mc.threads.insert(id, row);
  world.mc.sendRow(id, row);
  if (state == QLatin1String("has a turn running")) unfoldWorking(world, S("Fix cart"));
}

// The thread "Fix cart"'s row as the MC sends it after `change`.
void updateThread(World& world, const QString& title, const std::function<void(QJsonObject&)>& change) {
  const QString id = haveThread(world, title);
  QJsonObject row = world.mc.threads.value(id);
  change(row);
  world.mc.threads.insert(id, row);
  world.mc.sendRow(id, row);
}

const Steps steps([] {
  using S = QString;

  step(S("a thread (waits for the user to approve a command|asks the user a question|has a turn running|has a queued turn waiting to start|"
         "ended its last turn with an error|hit a provider usage limit|finished work the user has not looked at)"),
       [](World& world, const Captures& c, const Table&) { putState(world, c[0]); });

  step(S("a thread is labelled \"Done\""), [](World& world, const Captures&, const Table&) {
    putState(world, S("finished work the user has not looked at"));
    QQuickItem* row = threadRow(world, S("Fix cart"));
    world.waitFor([&] { return row->property("statusWord").toString() == S("Done"); }, S("the row to read \"Done\""));
  });

  // The other device opens it, which the MC records as a visit.
  step(S("the user opens that thread on the desktop"), [](World& world, const Captures&, const Table&) {
    updateThread(world, S("Fix cart"), [](QJsonObject& row) { row.insert(S("lastVisitedAt"), iso(QDateTime::currentDateTimeUtc())); });
  });

  step(S("the thread is no longer labelled %1 on the phone").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    QQuickItem* row = threadRow(world, S("Fix cart"));
    world.waitFor([&] { return row->property("statusWord").toString() != c[0]; }, S("the row to stop reading \"%1\"").arg(c[0]));
  });

  step(S("the thread is labelled %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    QQuickItem* row = threadRow(world, S("Fix cart"));
    world.waitFor([&] { return row->property("statusWord").toString() == c[0]; },
                  [&] { return S("the row to read \"%1\"; it reads \"%2\"").arg(c[0], row->property("statusWord").toString()); });
  });
});

}  // namespace
