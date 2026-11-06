// What the phone keeps and what its MC sends, when the two race or one of
// them is slow: the cache scenarios of
// features/connections/connection-health.feature (cached data against live
// data, a kept copy the phone cannot read), and a slow MC that is given the
// time to finish a thread list or a thread instead of being asked for it twice
// (upstream pingdotgg/t3code#13683). The desktop's ConnectionCacheSteps.cpp
// drives the same C++ the same way.

#include <QDir>
#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>
#include <QSqlDatabase>
#include <QSqlQuery>

#include "FakeThreads.h"
#include "Harness.h"
#include "LocalCache.h"
#include "McClient.h"
#include "NativeShell.h"
#include "Phone.h"
#include "ShellStore.h"
#include "ThreadStore.h"
#include "TimelineModel.h"
#include "World.h"

namespace {

using S = QString;

// A slow MC's seconds become milliseconds here: 12 seconds of work take 120 ms,
// and the client's deadlines shrink by as much, so the race is the real one.
constexpr int kScale = 100;

const QString kNow = S("2026-09-23T10:00:00Z");
const QString kQuestion = S("Add a tax line to the cart");
const QString kOldAnswer = S("The cart total includes tax.");
const QString kNewAnswer = S("The cart total includes tax and shipping.");
const QString kGarbled = S("{\"id\": \"assistant_message:");

// What a scenario watches.
struct Watched {
  QString item;       // the turn item it changes or garbles
  qsizetype subs = 0; // `sub` frames the MC had read before the scenario's step
  qsizetype connections = 0; // connections the MC had taken by then
  qsizetype shells = 0;      // `shell` frames it had sent by then
};

Watched &watched(World &world) { return world.mc.part<Watched>(); }

FakeStreams &streams(World &world) { return world.mc.part<FakeStreams>(); }

QString threadKey(World &world) {
  return world.mc.environmentId + QLatin1Char(':') + world.thread;
}

ThreadStore *store(World &world) {
  return world.native().controller<ThreadStore>();
}

TimelineModel &timeline(World &world) {
  TimelineModel *model = store(world)->activeTimeline();
  if (!model)
    fail(S("no thread is open"));
  return *model;
}

bool holds(TimelineModel &model, const QString &text) {
  for (int row = 0; row < model.rowCount(); ++row) {
    if (model.data(model.index(row), TimelineModel::TextRole).toString() ==
        text)
      return true;
  }
  return false;
}

QString describe(TimelineModel &model) {
  QStringList rows;
  for (int row = 0; row < model.rowCount(); ++row)
    rows.append(
        model.data(model.index(row), TimelineModel::TextRole).toString());
  return S("status %1, rows: %2").arg(model.status(), rows.join(S("; ")));
}

QString phase(World &world) {
  return world.state(S("connection")).toMap().value(S("phase")).toString();
}

// The client's deadlines, shrunk by kScale, after checking that the real ones
// leave a busy MC `seconds` to answer: a ping sent while it works is answered
// once it is done, so the pong deadline is what bounds it. The client sends a
// ping every few milliseconds, so one is always waiting while the MC works.
void slowMc(World &world, int seconds) {
  const McClient defaults;
  expect(defaults.pongTimeout() > seconds * 1000,
         S("the client gives up on an unanswered ping after %1 ms, before a %2 "
           "s load is done")
             .arg(defaults.pongTimeout())
             .arg(seconds));
  McClient &client = *world.native().client();
  client.setPongTimeout(defaults.pongTimeout() / kScale);
  client.setPingInterval(10);
  Watched &state = watched(world);
  state.subs = world.mc.subscriptions.size();
  state.connections = world.mc.connections.size();
  state.shells = world.mc.shellFrames.size();
}

QList<QJsonObject> subsSince(World &world, const QString &type) {
  QList<QJsonObject> subs;
  for (qsizetype i = watched(world).subs; i < world.mc.subscriptions.size();
       ++i) {
    const QJsonObject sub = world.mc.subscriptions.at(i);
    if (sub.value(QLatin1String("shape"))
            .toObject()
            .value(QLatin1String("type")) == type)
      subs.append(sub);
  }
  return subs;
}

// The thread `title` with one settled turn: the user's question and `answer`.
void seedThread(World &world, const QString &title, const QString &answer) {
  world.thread = haveThread(world, title);
  FakeStreams &fake = streams(world);
  world.run = S("run-%1").arg(fake.ordinal + 1);
  setEntity(world.mc, world.thread, S("run"), world.run,
            {{S("id"), world.run},
             {S("ordinal"), ++fake.ordinal},
             {S("status"), S("completed")},
             {S("requestedAt"), kNow},
             {S("startedAt"), kNow},
             {S("completedAt"), kNow}});
  const QString message = S("message:") + world.run;
  setEntity(world.mc, world.thread, S("turn-item"), message,
            {{S("id"), message},
             {S("type"), S("user_message")},
             {S("runId"), world.run},
             {S("ordinal"), ++fake.ordinal},
             {S("status"), S("completed")},
             {S("text"), kQuestion},
             {S("updatedAt"), kNow}});
  watched(world).item = S("assistant_message:%1").arg(fake.ordinal + 1);
  setEntity(world.mc, world.thread, S("turn-item"), watched(world).item,
            {{S("id"), watched(world).item},
             {S("type"), S("assistant_message")},
             {S("runId"), world.run},
             {S("ordinal"), ++fake.ordinal},
             {S("status"), S("completed")},
             {S("text"), answer},
             {S("updatedAt"), kNow}});
  world.sync();
}

void settle(World &world) {
  world.waitFor(
      [&] {
        return store(world)->activeTimeline() &&
               timeline(world).status() == QLatin1String("live");
      },
      [&] {
        return S("the thread to follow its MC; %1")
            .arg(store(world)->activeTimeline() ? describe(timeline(world))
                                                : S("none is open"));
      });
  world.sync();
}

// The thread, opened, followed and left: the phone keeps a copy of it.
void keepThread(World &world, const QString &title, const QString &answer) {
  // An MC that names its log, so a copy says where it resumes.
  streams(world).handle = S("log-1.1");
  seedThread(world, title, answer);
  openThread(world, title);
  settle(world);
  world.back();
  world.item(S("homeScreen"));
  world.native().cache()->drain();
  cache::Thread copy;
  world.native().cache()->loadThread(
      threadKey(world), world.native().cache(),
      [&copy](const cache::Thread &thread) { copy = thread; });
  world.native().cache()->drain();
  expect(copy.found(), S("the phone kept no copy of %1").arg(title));
}

// The app opens on the files it left, and is up on its MC's rows.
void reopen(World &world) {
  watched(world).subs = world.mc.subscriptions.size();
  world.open();
  world.native().cache()->drain();
  world.waitFor(
      [&] {
        return phase(world) == QLatin1String("connected") &&
               world.native().store()->synchronized();
      },
      [&] {
        return S("the phone to connect; it is %1")
            .arg(show(world.state(S("connection"))));
      });
  world.sync();
}

// Runs `sql` with `values` on the phone's cache file, from outside the app.
int onKeptFile(World &world, const QString &sql, const QVariantList &values) {
  const QString name = S("connection-cache-steps");
  int changed = -1;
  {
    QSqlDatabase db = QSqlDatabase::addDatabase(S("QSQLITE"), name);
    db.setDatabaseName(
        QDir(world.homeDir()).filePath(S("cache/client-cache.sqlite")));
    if (db.open()) {
      QSqlQuery query(db);
      if (query.prepare(sql)) {
        for (const QVariant &value : values)
          query.addBindValue(value);
        if (query.exec())
          changed = query.isSelect()
                        ? (query.next() ? query.value(0).toInt() : 0)
                        : query.numRowsAffected();
      }
      query.finish();
      db.close();
    }
  }
  QSqlDatabase::removeDatabase(name);
  if (changed < 0)
    fail(S("the phone's cache file could not be read: %1").arg(sql));
  return changed;
}

// The MC's answer to a `sub` of the whole thread, as it frames it.
QList<QJsonObject> wholeAnswer(World &world) {
  const FakeStreams &fake = streams(world);
  QJsonArray rows;
  const QMap<QString, QJsonObject> entities = fake.threads.value(world.thread);
  for (auto it = entities.cbegin(); it != entities.cend(); ++it) {
    const qsizetype newline = it.key().indexOf(QLatin1Char('\n'));
    rows.append(
        QJsonArray{it.key().left(newline), it.key().mid(newline + 1), *it});
  }
  return {{{S("t"), S("snapshot")},
           {S("offset"), fake.seq},
           {S("at"), kNow},
           {S("part"), 0},
           {S("rows"), rows},
           {S("done"), true},
           {S("handle"), fake.handle}},
          {{S("t"), S("live")},
           {S("offset"), fake.seq},
           {S("handle"), fake.handle}}};
}

FakeStreams::Asked lastAsked(World &world) {
  const FakeStreams &fake = streams(world);
  for (qsizetype i = fake.asked.size() - 1; i >= 0; --i) {
    if (fake.asked.at(i).thread == world.thread)
      return fake.asked.at(i);
  }
  fail(S("the MC was never asked for %1").arg(world.thread));
}

const Steps steps([] {
  const QString q = kQuoted;

  // A slow MC's thread list.
  step(S("the MC takes (\\d+) seconds to build the thread list"),
       [](World &world, const Captures &c, const Table &) {
         slowMc(world, c[0].toInt());
         world.mc.buildMs = c[0].toInt() * 1000 / kScale;
         // Built anew, as after the MC restarted: the whole list is the work.
         world.mc.epoch = S("epoch-slow");
         const QString id = S("t-built-slowly");
         world.mc.threads.insert(id,
                                 {{S("id"), id},
                                  {S("title"), S("Built slowly")},
                                  {S("projectId"), S("shop")},
                                  {S("createdAt"), S("2026-09-23T09:00:00Z")},
                                  {S("updatedAt"), S("2026-09-23T09:00:00Z")}});
       });
  // "the client connects" is ConnectionClientSteps.cpp's.
  step(S("the thread list shows once the MC answers"),
       [](World &world, const Captures &, const Table &) {
         threadRow(world, S("Built slowly"));
         expect(world.native().store()->synchronized(),
                S("the thread list is not the MC's"));
       });
  step(S("the MC builds the thread list once"),
       [](World &world, const Captures &, const Table &) {
         world.sync();
         const Watched &state = watched(world);
         const QList<QJsonObject> asked = subsSince(world, S("shell"));
         expect(asked.size() == 1 &&
                    world.mc.connections.size() == state.connections + 1 &&
                    world.mc.shellFrames.size() == state.shells + 1,
                S("the MC was asked for its thread list %1 times over %2 "
                  "connections, and sent it %3 times")
                    .arg(asked.size())
                    .arg(world.mc.connections.size() - state.connections)
                    .arg(world.mc.shellFrames.size() - state.shells));
       });

  // A slow MC's thread.
  step(S("the MC takes (\\d+) seconds to load a thread"),
       [](World &world, const Captures &c, const Table &) {
         seedThread(world, S("Tax line"), kOldAnswer);
         threadRow(world, S("Tax line"));
         slowMc(world, c[0].toInt());
         streams(world).loadMs = c[0].toInt() * 1000 / kScale;
       });
  step(S("the user opens the thread"),
       [](World &world, const Captures &, const Table &) {
         openThread(world, S("Tax line"));
       });
  step(S("the thread shows once the MC answers"),
       [](World &world, const Captures &, const Table &) {
         settle(world);
         world.waitFor([&] { return world.shows(kOldAnswer); },
                       [&] {
                         return S("the answer on screen; it shows: %1")
                             .arg(world.texts().join(S(" | ")));
                       });
       });
  step(S("the MC loads the thread once"), [](World &world, const Captures &,
                                             const Table &) {
    int asked = 0;
    for (const QJsonObject &sub : subsSince(world, S("stream"))) {
      if (sub.value(QLatin1String("shape"))
              .toObject()
              .value(QLatin1String("stream")) == world.thread)
        ++asked;
    }
    expect(asked == 1 &&
               world.mc.connections.size() == watched(world).connections,
           S("the MC was asked for the thread %1 times, and took %2 "
             "connections meanwhile")
               .arg(asked)
               .arg(world.mc.connections.size() - watched(world).connections));
  });

  // Cached data against live data.
  step(S("the client reconnects while cached data loads"),
       [](World &world, const Captures &, const Table &) {
         keepThread(world, S("Tax line"), kOldAnswer);
         world.close();
         // While the app was closed the answer changed on the MC.
         setEntity(world.mc, world.thread, S("turn-item"), watched(world).item,
                   {{S("text"), kNewAnswer}});
         reopen(world);
         // The thread opens: its kept copy is being read, and nothing the cache
         // reads is handed back until the event loop runs again.
         store(world)->open(threadKey(world));
         expect(store(world)->activeTimeline() &&
                    timeline(world).rowCount() == 0,
                S("the kept copy was read at once"));
       });
  step(S("live data arrives first"),
       [](World &world, const Captures &, const Table &) {
         for (const QJsonObject &frame : wholeAnswer(world))
           timeline(world).receive(frame);
         // Then the copy the cache read.
         world.native().cache()->drain();
         world.sync();
       });
  step(S("the older cached data is not applied over it"),
       [](World &world, const Captures &, const Table &) {
         settle(world);
         TimelineModel &model = timeline(world);
         expect(holds(model, kNewAnswer) && !holds(model, kOldAnswer),
                S("the thread shows %1").arg(describe(model)));
         // And the phone goes on from where the live data stands, not the copy.
         const QJsonObject sub = lastAsked(world).sub;
         expect(sub.value(QLatin1String("offset")).toInteger() ==
                    streams(world).seq,
                S("it asked with %1").arg(show(sub.toVariantMap())));
       });

  // A kept copy the phone cannot read.
  step(S("the client kept a copy of %1 that it can no longer read").arg(q),
       [](World &world, const Captures &c, const Table &) {
         keepThread(world, c[0], kOldAnswer);
         world.close();
         const int garbled = onKeptFile(
             world,
             S("UPDATE entities SET json = ? WHERE thread = ? AND kind = "
               "'turn-item' AND id = ?"),
             {kGarbled.toUtf8(), threadKey(world), watched(world).item});
         expect(garbled == 1,
                S("%1 rows of the copy were garbled").arg(garbled));
         reopen(world);
       });
  step(S("the user opens %1 while connected").arg(q),
       [](World &world, const Captures &c, const Table &) {
         expect(phase(world) == QLatin1String("connected"),
                S("the phone is %1").arg(phase(world)));
         openThread(world, c[0]);
       });
  step(S("the kept copy is removed"), [](World &world, const Captures &,
                                         const Table &) {
    settle(world);
    // The copy was never resumed from: the phone asked for the thread whole.
    const QJsonObject sub = lastAsked(world).sub;
    expect(!sub.value(QLatin1String("offset")).isDouble() &&
               sub.value(QLatin1String("handle")).toString().isEmpty(),
           S("it asked with %1").arg(show(sub.toVariantMap())));
    world.native().cache()->drain();
    const int left =
        onKeptFile(world, S("SELECT count(*) FROM entities WHERE json = ?"),
                   {kGarbled.toUtf8()});
    expect(left == 0, S("%1 unreadable rows are still kept").arg(left));
  });
  step(S("%1 loads from the MC as if nothing had been kept").arg(q),
       [](World &world, const Captures &, const Table &) {
         settle(world);
         const FakeStreams::Asked asked = lastAsked(world);
         int snapshots = 0;
         const QList<QJsonObject> &sent = streams(world).sent;
         for (qsizetype i = asked.sent; i < sent.size(); ++i) {
           if (sent.at(i).value(QLatin1String("id")) ==
                   asked.sub.value(QLatin1String("id")) &&
               sent.at(i).value(QLatin1String("t")) ==
                   QLatin1String("snapshot"))
             ++snapshots;
         }
         world.waitFor(
             [&] { return world.shows(kOldAnswer) && world.shows(kQuestion); },
             [&] {
               return S("the conversation on screen; it shows: %1")
                   .arg(world.texts().join(S(" | ")));
             });
         expect(snapshots == 1, S("the MC sent %1 snapshots").arg(snapshots));
       });
});

} // namespace
