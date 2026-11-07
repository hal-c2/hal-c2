// What the client keeps and what its MC sends, when the two race or one of
// them is slow: the cache scenarios of features/connections/connection-health.feature
// (cached data against live data, a kept copy the client cannot read), and a
// slow MC that is given the time to finish a thread list or a thread instead
// of being asked for it twice (upstream pingdotgg/t3code#13683).

#include <QDir>
#include <QJsonArray>
#include <QJsonObject>
#include <QSqlDatabase>
#include <QSqlQuery>

#include "Harness.h"
#include "LocalCache.h"
#include "McClient.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "ShellStore.h"
#include "Stream.h"
#include "ThreadList.h"
#include "World.h"

namespace {

using namespace stream;

// A slow MC's seconds become milliseconds here: 12 seconds of work take 120 ms,
// and the client's deadlines shrink by as much, so the race is the real one.
constexpr int kScale = 100;

// What a scenario watches.
struct Watched {
  QString thread;               // the key of the thread it is about
  QString item;                 // the turn item it changes or garbles
  qsizetype subs = 0;           // `sub` frames the MC had read before the scenario's step
  qsizetype connections = 0;    // connections the MC had taken by then
  qsizetype shells = 0;         // `shell` frames it had sent by then
  QString listed;               // the key of a thread the MC lists only once it is asked
};

Watched& watched(World& world) {
  return world.mc.part<Watched>();
}

FakeStreams& streams(World& world) {
  return world.mc.part<FakeStreams>();
}

QString threadKey(World& world) {
  return world.mc.environmentId + QLatin1Char(':') + kThread;
}

bool shows(TimelineModel& model, const QString& text) {
  for (int row = 0; row < model.rowCount(); ++row) {
    if (role(model, row, TimelineModel::TextRole).toString() == text) return true;
  }
  return false;
}

// The client's deadlines, shrunk by kScale, after checking that the real ones
// leave a busy MC `seconds` to answer: a ping sent while it works is answered
// once it is done, so the pong deadline is what bounds it. The client sends a
// ping every few milliseconds, so one is always waiting while the MC works.
void slowMc(World& world, int seconds) {
  const McClient defaults;
  expect(defaults.pongTimeout() > seconds * 1000,
         QStringLiteral("the client gives up on an unanswered ping after %1 ms, before a %2 s load is done").arg(defaults.pongTimeout()).arg(seconds));
  McClient& client = *world.native().client();
  client.setPongTimeout(defaults.pongTimeout() / kScale);
  client.setPingInterval(10);
  Watched& state = watched(world);
  state.subs = world.mc.subscriptions.size();
  state.connections = world.mc.connections.size();
  state.shells = world.mc.shellFrames.size();
}

// The `sub` frames the MC read since the scenario's step, of `type`.
QList<QJsonObject> subsSince(World& world, const QString& type) {
  QList<QJsonObject> subs;
  for (qsizetype i = watched(world).subs; i < world.mc.subscriptions.size(); ++i) {
    const QJsonObject sub = world.mc.subscriptions.at(i);
    if (sub.value(QLatin1String("shape")).toObject().value(QLatin1String("type")) == type) subs.append(sub);
  }
  return subs;
}

// The scenario's thread, listed and followed, with one settled turn whose
// answer is `answer`; then left, so the app does not open it when it starts.
void keepThread(World& world, const QString& title, const QString& answer) {
  lookAtThread(world, kProject, {{QStringLiteral("title"), title}});
  startRun(world, 60);
  Watched& state = watched(world);
  state.thread = threadKey(world);
  state.item = addItem(world, QStringLiteral("assistant_message"), {{QStringLiteral("text"), answer}});
  settleRun(world, QStringLiteral("completed"), 30);
  world.native().controller<NavigationController>()->open(NavigationController::Route::of(QStringLiteral("home")));
  world.sync();
  world.native().cache()->drain();
  expect(keptCopy(world, state.thread).found(), QStringLiteral("the client kept no copy of %1").arg(state.thread));
}

// The app starts on the files it left and is pointed at its MC, and is up on its rows.
void startOnMc(World& world) {
  Watched& state = watched(world);
  state.subs = world.mc.subscriptions.size();
  world.launch();
  world.native().cache()->drain();
  world.native().open(world.mc.origin(), QStringLiteral("mc-token"));
  world.native().cache()->drain();
  world.waitFor([&] { return world.native().isActive() && world.native().store()->synchronized(); }, QStringLiteral("the shell to start on its MC's rows"));
  world.sync();
}

// Runs `sql` with `values` on the client's cache file, from outside the app.
int onKeptFile(World& world, const QString& sql, const QVariantList& values) {
  const QString name = QStringLiteral("connection-cache-steps");
  int changed = -1;
  {
    QSqlDatabase db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), name);
    db.setDatabaseName(QDir(world.homeDir()).filePath(QStringLiteral("cache/client-cache.sqlite")));
    if (db.open()) {
      QSqlQuery query(db);
      if (query.prepare(sql)) {
        for (const QVariant& value : values) query.addBindValue(value);
        if (query.exec()) changed = query.isSelect() ? (query.next() ? query.value(0).toInt() : 0) : query.numRowsAffected();
      }
      query.finish();
      db.close();
    }
  }
  QSqlDatabase::removeDatabase(name);
  if (changed < 0) fail(QStringLiteral("the client's cache file could not be read: %1").arg(sql));
  return changed;
}

// The MC's answer to a `sub` of the whole thread, as it frames it.
QList<QJsonObject> wholeAnswer(World& world) {
  const FakeStreams& fake = streams(world);
  QJsonArray rows;
  const QMap<QString, QJsonObject> entities = fake.threads.value(kThread);
  for (auto it = entities.cbegin(); it != entities.cend(); ++it) {
    const qsizetype newline = it.key().indexOf(QLatin1Char('\n'));
    rows.append(QJsonArray{it.key().left(newline), it.key().mid(newline + 1), *it});
  }
  return {{{QStringLiteral("t"), QStringLiteral("snapshot")}, {QStringLiteral("offset"), fake.seq}, {QStringLiteral("rows"), rows},
           {QStringLiteral("done"), true}, {QStringLiteral("handle"), fake.handle}},
          {{QStringLiteral("t"), QStringLiteral("live")}, {QStringLiteral("offset"), fake.seq}, {QStringLiteral("handle"), fake.handle}}};
}

// The last `sub` the MC answered for the scenario's thread.
FakeStreams::Asked lastAsked(World& world) {
  const FakeStreams& fake = streams(world);
  for (qsizetype i = fake.asked.size() - 1; i >= 0; --i) {
    if (fake.asked.at(i).thread == kThread) return fake.asked.at(i);
  }
  fail(QStringLiteral("the MC was never asked for %1").arg(kThread));
}

void settle(World& world) {
  world.waitFor([&] { return store(world)->activeTimeline() && timeline(world).status() == QLatin1String("live"); },
                [&] { return QStringLiteral("the thread to follow its MC; %1").arg(store(world)->activeTimeline() ? describe(timeline(world)) : QStringLiteral("none is open")); });
  world.sync();
}

const QString kOldAnswer = QStringLiteral("The cart total includes tax.");
const QString kNewAnswer = QStringLiteral("The cart total includes tax and shipping.");
const QString kGarbled = QStringLiteral("{\"id\": \"assistant_message:");

const Steps steps([] {
  const QString q = kQuoted;

  // A slow MC's thread list.
  step(QStringLiteral("the MC takes (\\d+) seconds to build the thread list"), [](World& world, const Captures& c, const Table&) {
    slowMc(world, c[0].toInt());
    world.mc.buildMs = c[0].toInt() * 1000 / kScale;
    // Built anew, as after the MC restarted: the whole list is the work.
    world.mc.epoch = QStringLiteral("epoch-slow");
    const QString id = QStringLiteral("t-built-slowly");
    world.mc.threads.insert(id, {{QStringLiteral("id"), id}, {QStringLiteral("title"), QStringLiteral("Built slowly")}, {QStringLiteral("projectId"), kProject},
                                 {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")}, {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}});
    watched(world).listed = world.mc.environmentId + QLatin1Char(':') + id;
  });
  step(QStringLiteral("the thread list shows once the MC answers"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.native().store()->synchronized() && !sidebarSectionOf(world, watched(world).listed).isEmpty(); },
                  [&] { return QStringLiteral("the thread list to show %1: %2").arg(watched(world).listed, show(world.state(QStringLiteral("sidebar")))); });
  });
  step(QStringLiteral("the MC builds the thread list once"), [](World& world, const Captures&, const Table&) {
    world.sync();
    const Watched& state = watched(world);
    const QList<QJsonObject> asked = subsSince(world, QStringLiteral("shell"));
    expect(asked.size() == 1 && world.mc.connections.size() == state.connections + 1 && world.mc.shellFrames.size() == state.shells + 1,
           QStringLiteral("the MC was asked for its thread list %1 times over %2 connections, and sent it %3 times")
               .arg(asked.size()).arg(world.mc.connections.size() - state.connections).arg(world.mc.shellFrames.size() - state.shells));
  });

  // A slow MC's thread.
  step(QStringLiteral("the MC takes (\\d+) seconds to load a thread"), [](World& world, const Captures& c, const Table&) {
    // A thread the client has not opened, with a turn in it.
    world.mc.threads.insert(kThread, {{QStringLiteral("id"), kThread}, {QStringLiteral("title"), QStringLiteral("Tax line")}, {QStringLiteral("projectId"), kProject},
                                      {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")}, {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}});
    world.mc.sendRow(kThread, world.mc.threads.value(kThread));
    FakeStreams& fake = streams(world);
    fake.thread = kThread;
    fake.environment = world.mc.environmentId;
    startRun(world, 60);
    watched(world).item = addItem(world, QStringLiteral("assistant_message"), {{QStringLiteral("text"), kOldAnswer}});
    settleRun(world, QStringLiteral("completed"), 30);
    world.sync();
    slowMc(world, c[0].toInt());
    fake.loadMs = c[0].toInt() * 1000 / kScale;
  });
  step(QStringLiteral("the user opens the thread"), [](World& world, const Captures&, const Table&) {
    look(world, threadKey(world), false);
  });
  step(QStringLiteral("the thread shows once the MC answers"), [](World& world, const Captures&, const Table&) {
    settle(world);
    expect(shows(timeline(world), kOldAnswer), QStringLiteral("the thread shows %1").arg(describe(timeline(world))));
  });
  step(QStringLiteral("the MC loads the thread once"), [](World& world, const Captures&, const Table&) {
    int asked = 0;
    for (const QJsonObject& sub : subsSince(world, QStringLiteral("stream"))) {
      if (sub.value(QLatin1String("shape")).toObject().value(QLatin1String("stream")) == kThread) ++asked;
    }
    expect(asked == 1 && world.mc.connections.size() == watched(world).connections,
           QStringLiteral("the MC was asked for the thread %1 times, and took %2 connections meanwhile").arg(asked).arg(world.mc.connections.size() - watched(world).connections));
  });

  // Cached data against live data.
  step(QStringLiteral("the client reconnects while cached data loads"), [](World& world, const Captures&, const Table&) {
    keepThread(world, QStringLiteral("Tax line"), kOldAnswer);
    world.quit();
    // While the app was closed the answer changed on the MC.
    set(world, QStringLiteral("turn-item"), watched(world).item, {{QStringLiteral("text"), kNewAnswer}});
    startOnMc(world);
    // The thread opens: its kept copy is being read, and nothing the cache
    // reads is handed back until the event loop runs again.
    store(world)->open(watched(world).thread);
    expect(store(world)->activeTimeline() && timeline(world).rowCount() == 0, QStringLiteral("the kept copy was read at once"));
  });
  step(QStringLiteral("live data arrives first"), [](World& world, const Captures&, const Table&) {
    for (const QJsonObject& frame : wholeAnswer(world)) timeline(world).receive(frame);
    // Then the copy the cache read.
    world.native().cache()->drain();
    world.sync();
  });
  step(QStringLiteral("the older cached data is not applied over it"), [](World& world, const Captures&, const Table&) {
    settle(world);
    TimelineModel& model = timeline(world);
    expect(shows(model, kNewAnswer) && !shows(model, kOldAnswer), QStringLiteral("the thread shows %1").arg(describe(model)));
    // And the client goes on from where the live data stands, not the copy.
    const QJsonObject sub = lastAsked(world).sub;
    expect(sub.value(QLatin1String("offset")).toInteger() == streams(world).seq, QStringLiteral("it asked with %1").arg(show(sub.toVariantMap())));
  });

  // A kept copy the client cannot read.
  step(QStringLiteral("the client kept a copy of %1 that it can no longer read").arg(q), [](World& world, const Captures& c, const Table&) {
    keepThread(world, c[0], kOldAnswer);
    world.quit();
    const int garbled = onKeptFile(world, QStringLiteral("UPDATE entities SET json = ? WHERE thread = ? AND kind = 'turn-item' AND id = ?"),
                                   {kGarbled.toUtf8(), watched(world).thread, watched(world).item});
    expect(garbled == 1, QStringLiteral("%1 rows of the copy were garbled").arg(garbled));
    startOnMc(world);
  });
  step(QStringLiteral("the user opens %1 while connected").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(world.native().store()->threadRow(watched(world).thread).value(QLatin1String("title")) == c[0],
           QStringLiteral("the thread list holds no %1").arg(c[0]));
    look(world, watched(world).thread, false);
  });
  step(QStringLiteral("the kept copy is removed"), [](World& world, const Captures&, const Table&) {
    settle(world);
    // The copy was never resumed from: the client asked for the thread whole.
    const QJsonObject sub = lastAsked(world).sub;
    expect(!sub.value(QLatin1String("offset")).isDouble() && sub.value(QLatin1String("handle")).toString().isEmpty(),
           QStringLiteral("it asked with %1").arg(show(sub.toVariantMap())));
    world.native().cache()->drain();
    const int left = onKeptFile(world, QStringLiteral("SELECT count(*) FROM entities WHERE json = ?"), {kGarbled.toUtf8()});
    expect(left == 0, QStringLiteral("%1 unreadable rows are still kept").arg(left));
  });
  step(QStringLiteral("%1 loads from the MC as if nothing had been kept").arg(q), [](World& world, const Captures&, const Table&) {
    settle(world);
    const FakeStreams::Asked asked = lastAsked(world);
    const QList<QJsonObject> snapshots = answerTo(world, asked, QStringLiteral("snapshot"));
    TimelineModel& model = timeline(world);
    expect(snapshots.size() == 1 && shows(model, kOldAnswer) && shows(model, QStringLiteral("Add a tax line to the cart")),
           QStringLiteral("the MC sent %1 snapshots and the thread shows %2").arg(snapshots.size()).arg(describe(model)));
  });
});

}  // namespace
