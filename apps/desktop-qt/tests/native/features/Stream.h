#pragma once
// The MC's `stream` shape for a thread, faked as entity rows steps change
// (the Extension serving it is in TimelineSteps.cpp), and the ThreadStore's
// TimelineModel showing it. Shared by the steps files that drive a thread.

#include <QDateTime>
#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QMap>
#include <QPersistentModelIndex>
#include <QSet>
#include <QStringList>

#include <algorithm>
#include <utility>

#include "Harness.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "ThreadStore.h"
#include "TimelineModel.h"
#include "World.h"

namespace stream {

// What one follower of a stream holds, and so what it is sent
// (lib/hal_c2/streams/view.ex): the entity `kinds` its `sub` named, and its
// window, whose `floor` is the ordinal of its first run (null: it reaches the
// start of the thread).
struct View {
  QJsonObject kinds;
  bool windowed = false;
  QJsonValue floor = QJsonValue::Null;
};

// Every stream the MC serves: the entities of each thread, by "kind\nid",
// and the log of the changes that made them, which a follower's offset counts.
// A change made while nobody follows the thread (the connection is down) is
// in the log all the same, so a follower that resumes is sent it.
struct FakeStreams {
  struct Change {
    int seq = 0;
    QString kind;
    QString id;
    QJsonObject patch;
  };
  QHash<QString, QMap<QString, QJsonObject>> threads;
  QHash<QString, QList<Change>> log;
  // Names the MC's log: an offset only resumes with the handle it came with.
  QString handle = QStringLiteral("log-1.1");
  // What each follower holds, by subscription id.
  QHash<int, View> views;
  // Every `sub` to a stream as it was answered: its frame, and how many
  // frames had been sent to followers before it.
  struct Asked {
    QString thread;
    QJsonObject sub;
    qsizetype sentBefore = 0;
    // The changes made to the thread while nobody followed it, until then.
    int lacked = 0;
  };
  QList<Asked> asked;
  // Changes made to each thread since anyone last followed it.
  QHash<QString, int> unfollowed;
  // Every frame sent to a follower, in order, for counting what a thread cost.
  QList<QJsonObject> sent;
  // A catch-up is sent in two parts, and the connection drops after the
  // first, once.
  bool cutCatchUp = false;
  // Environments that are down (a cluster member that left): a stream on one
  // is refused.
  QSet<QString> offline;
  // The thread the steps write to, and its environment.
  QString thread;
  QString environment;
  int ordinal = 0;
  int seq = 0;
  QString run;
  QDateTime runStarted;
  QList<QPersistentModelIndex> kept;
  // The files the current turn changed, for the checkpoint it leaves.
  QStringList changedFiles;
};

inline const QString kProject = QStringLiteral("shop");
inline const QString kThread = QStringLiteral("thread-1");
inline const QString kPeer = QStringLiteral("mc-b");
inline const QString kPeerEnvironment = QStringLiteral("env-b");
inline const QString kPeerThread = QStringLiteral("thread-remote");

inline QString iso(const QDateTime& time) {
  return time.toUTC().toString(Qt::ISODate);
}

inline QDateTime now() {
  return QDateTime::fromString(QStringLiteral("2026-09-23T10:00:00Z"), Qt::ISODate);
}

// Whether the follower holds this entity of `entities` (a thread's).
inline bool holds(const View& view, const QMap<QString, QJsonObject>& entities, const QString& kind, const QJsonObject& entity) {
  if (!view.kinds.isEmpty()) {
    if (!view.kinds.contains(kind)) return false;
    const QJsonObject where = view.kinds.value(kind).toObject();
    for (auto it = where.begin(); it != where.end(); ++it) {
      if (entity.value(it.key()) != it.value()) return false;
    }
  }
  static const QSet<QString> windowed{QStringLiteral("turn-item"), QStringLiteral("message"), QStringLiteral("node")};
  if (!view.windowed || !windowed.contains(kind)) return true;
  const QJsonObject run = entities.value(QStringLiteral("run\n") + entity.value(QLatin1String("runId")).toString());
  if (run.isEmpty()) return true;
  if (run.value(QLatin1String("status")) == QLatin1String("rolled_back")) return false;
  return view.floor.isNull() || run.value(QLatin1String("ordinal")).toInt() >= view.floor.toInt();
}

// The runs before `before` (null: the newest) that together hold at least
// `items` turn items, and the floor of a window once it holds them too: null
// when no run is left before them (HalC2.Streams.View.take_runs).
inline std::pair<QSet<QString>, QJsonValue> takeRuns(const QMap<QString, QJsonObject>& entities, const QJsonValue& before, int items) {
  QHash<QString, int> counts;
  QList<std::pair<int, QString>> runs;
  for (auto it = entities.cbegin(); it != entities.cend(); ++it) {
    if (it.key().startsWith(QLatin1String("turn-item\n"))) ++counts[it->value(QLatin1String("runId")).toString()];
    if (!it.key().startsWith(QLatin1String("run\n")) || it->value(QLatin1String("status")) == QLatin1String("rolled_back")) continue;
    const int ordinal = it->value(QLatin1String("ordinal")).toInt();
    if (before.isNull() || ordinal < before.toInt()) runs.append({ordinal, it.key().mid(4)});
  }
  std::sort(runs.begin(), runs.end(), std::greater<>());
  QSet<QString> taken;
  int count = 0;
  for (qsizetype i = 0; i < runs.size(); ++i) {
    taken.insert(runs.at(i).second);
    count += counts.value(runs.at(i).second);
    if (count >= items) return {taken, i + 1 < runs.size() ? QJsonValue(runs.at(i).first) : QJsonValue(QJsonValue::Null)};
  }
  return {taken, QJsonValue::Null};
}

// A frame for a follower of a stream; false when no client is there to take it.
inline bool deliver(FakeMc& mc, const QJsonObject& frame) {
  if (!mc.connected()) return false;
  mc.part<FakeStreams>().sent.append(frame);
  mc.send(frame);
  return true;
}

// The frames of type `t` sent to followers since the first `from` of them.
inline QList<QJsonObject> sentSince(World& world, qsizetype from, const QString& t) {
  QList<QJsonObject> frames;
  const QList<QJsonObject>& sent = world.mc.part<FakeStreams>().sent;
  for (qsizetype i = from; i < sent.size(); ++i) {
    if (sent.at(i).value(QLatin1String("t")) == t) frames.append(sent.at(i));
  }
  return frames;
}

// What the MC answered the `sub` with: the frames of type `t` it sent that
// subscription up to its `live`. What it streamed afterwards is not part of it.
inline QList<QJsonObject> answerTo(World& world, const FakeStreams::Asked& asked, const QString& t) {
  QList<QJsonObject> frames;
  const QList<QJsonObject>& sent = world.mc.part<FakeStreams>().sent;
  const QJsonValue id = asked.sub.value(QLatin1String("id"));
  for (qsizetype i = asked.sentBefore; i < sent.size(); ++i) {
    if (sent.at(i).value(QLatin1String("id")) != id) continue;
    if (sent.at(i).value(QLatin1String("t")) == QLatin1String("live")) break;
    if (sent.at(i).value(QLatin1String("t")) == t) frames.append(sent.at(i));
  }
  return frames;
}

inline QList<int> followers(World& world, const QString& thread) {
  QList<int> ids;
  for (const int id : world.mc.subscribers(QStringLiteral("stream"))) {
    if (world.mc.shapeOf(id).value(QLatin1String("stream")).toString() == thread) ids.append(id);
  }
  return ids;
}

// One change to the current thread, as the MC's `events` frame carries it
// ({"s": set, "a": append, "u": unset, "d": delete}). `quiet` changes only
// the MC's copy, as if the frame were lost.
inline void change(World& world, const QString& kind, const QString& id, const QJsonObject& patch, bool quiet = false) {
  FakeStreams& fake = world.mc.part<FakeStreams>();
  QJsonObject& entity = fake.threads[fake.thread][kind + QLatin1Char('\n') + id];
  const QJsonObject set = patch.value(QLatin1String("s")).toObject();
  for (auto it = set.begin(); it != set.end(); ++it) entity.insert(it.key(), it.value());
  const QJsonObject append = patch.value(QLatin1String("a")).toObject();
  for (auto it = append.begin(); it != append.end(); ++it) {
    entity.insert(it.key(), entity.value(it.key()).toString() + it.value().toString());
  }
  const int seq = ++fake.seq;
  fake.log[fake.thread].append({seq, kind, id, patch});
  const QList<int> following = quiet || !world.mc.connected() ? QList<int>() : followers(world, fake.thread);
  if (following.isEmpty()) ++fake.unfollowed[fake.thread];
  if (quiet) return;
  // QJsonValue keeps the event nested: Apple clang before 20 reads
  // QJsonArray{QJsonArray{...}} as a copy of the inner array.
  for (const int follower : following) {
    // A follower is only sent changes to what it holds.
    if (!holds(fake.views.value(follower), fake.threads.value(fake.thread), kind, entity)) continue;
    deliver(world.mc, {{QStringLiteral("t"), QStringLiteral("events")}, {QStringLiteral("id"), follower}, {QStringLiteral("offset"), seq},
                       {QStringLiteral("events"), QJsonArray{QJsonValue(QJsonArray{seq, kind, id, patch, iso(now())})}}});
  }
  world.sync();
}

inline void set(World& world, const QString& kind, const QString& id, const QJsonObject& fields) {
  change(world, kind, id, {{QStringLiteral("s"), fields}});
}

// A new run of the current thread, started `since` seconds ago (not started
// when negative), with the user message that asked for it.
inline QString startRun(World& world, int since = 0, const QString& status = QStringLiteral("running")) {
  FakeStreams& fake = world.mc.part<FakeStreams>();
  const QString run = QStringLiteral("run-%1").arg(fake.ordinal + 1);
  fake.run = run;
  fake.runStarted = since >= 0 ? now().addSecs(-since) : QDateTime();
  QJsonObject fields{{QStringLiteral("id"), run}, {QStringLiteral("ordinal"), ++fake.ordinal}, {QStringLiteral("status"), status},
                     {QStringLiteral("requestedAt"), iso(now().addSecs(-std::max(since, 0)))}};
  if (fake.runStarted.isValid()) fields.insert(QStringLiteral("startedAt"), iso(fake.runStarted));
  set(world, QStringLiteral("run"), run, fields);
  set(world, QStringLiteral("turn-item"), QStringLiteral("message:") + run,
      {{QStringLiteral("id"), QStringLiteral("message:") + run}, {QStringLiteral("type"), QStringLiteral("user_message")},
       {QStringLiteral("runId"), run}, {QStringLiteral("ordinal"), ++fake.ordinal}, {QStringLiteral("status"), QStringLiteral("completed")},
       {QStringLiteral("text"), QStringLiteral("Add a tax line to the cart")},
       {QStringLiteral("updatedAt"), iso(now().addSecs(-std::max(since, 0)))}});
  return run;
}

// A turn item of the current run; `fields` adds to and overrides the defaults.
inline QString addItem(World& world, const QString& type, const QJsonObject& fields = {}) {
  FakeStreams& fake = world.mc.part<FakeStreams>();
  const QString id = QStringLiteral("%1:%2").arg(type).arg(fake.ordinal + 1);
  QJsonObject item{{QStringLiteral("id"), id},
                   {QStringLiteral("type"), type},
                   {QStringLiteral("runId"), fake.run},
                   {QStringLiteral("ordinal"), ++fake.ordinal},
                   {QStringLiteral("status"), QStringLiteral("completed")},
                   {QStringLiteral("updatedAt"), iso(now())}};
  for (auto it = fields.begin(); it != fields.end(); ++it) item.insert(it.key(), it.value());
  set(world, QStringLiteral("turn-item"), item.value(QLatin1String("id")).toString(), item);
  return item.value(QLatin1String("id")).toString();
}

inline QString addCommand(World& world, int n, const QString& status = QStringLiteral("completed")) {
  return addItem(world, QStringLiteral("command_execution"),
                 {{QStringLiteral("input"), QStringLiteral("bun test cart-%1").arg(n)}, {QStringLiteral("status"), status}, {QStringLiteral("exitCode"), 0}});
}

inline void settleRun(World& world, const QString& status, int after) {
  FakeStreams& fake = world.mc.part<FakeStreams>();
  QJsonObject fields{{QStringLiteral("status"), status}};
  if (fake.runStarted.isValid()) fields.insert(QStringLiteral("completedAt"), iso(fake.runStarted.addSecs(after)));
  set(world, QStringLiteral("run"), fake.run, fields);
}

// `runs` settled turns of the current thread, each a question, `calls` tool
// calls and "Answer <n>", as they were before anyone followed the thread.
inline void seedTurns(World& world, int runs, int calls) {
  FakeStreams& fake = world.mc.part<FakeStreams>();
  const auto put = [&](const QString& kind, const QString& id, QJsonObject fields) {
    fields.insert(QStringLiteral("id"), id);
    change(world, kind, id, {{QStringLiteral("s"), fields}}, true);
  };
  for (int n = 1; n <= runs; ++n) {
    const QDateTime started = now().addSecs(-3600 + n * 60);
    const QString run = QStringLiteral("run-%1").arg(fake.ordinal + 1);
    put(QStringLiteral("run"), run, {{QStringLiteral("ordinal"), ++fake.ordinal}, {QStringLiteral("status"), QStringLiteral("completed")},
                                     {QStringLiteral("requestedAt"), iso(started)}, {QStringLiteral("startedAt"), iso(started)},
                                     {QStringLiteral("completedAt"), iso(started.addSecs(30))}});
    const auto item = [&](const QString& type, const QJsonObject& more) {
      QJsonObject fields{{QStringLiteral("type"), type}, {QStringLiteral("runId"), run}, {QStringLiteral("status"), QStringLiteral("completed")},
                         {QStringLiteral("updatedAt"), iso(started)}};
      for (auto it = more.begin(); it != more.end(); ++it) fields.insert(it.key(), it.value());
      fields.insert(QStringLiteral("ordinal"), ++fake.ordinal);
      put(QStringLiteral("turn-item"), QStringLiteral("%1:%2").arg(type).arg(fake.ordinal), fields);
    };
    item(QStringLiteral("user_message"), {{QStringLiteral("text"), QStringLiteral("Question %1").arg(n)}});
    for (int call = 1; call <= calls; ++call) item(QStringLiteral("command_execution"), {{QStringLiteral("input"), QStringLiteral("bun test %1").arg(call)}, {QStringLiteral("exitCode"), 0}});
    item(QStringLiteral("assistant_message"), {{QStringLiteral("text"), QStringLiteral("Answer %1").arg(n)}});
    fake.run = run;
  }
}

inline ThreadStore* store(World& world) {
  return world.native().controller<ThreadStore>();
}

inline TimelineModel& timeline(World& world) {
  TimelineModel* model = store(world)->activeTimeline();
  if (!model) fail(QStringLiteral("no thread is open"));
  return *model;
}

inline QVariant role(TimelineModel& model, int row, int role) {
  return model.data(model.index(row), role);
}

inline QString describe(TimelineModel& model) {
  QStringList rows;
  for (int row = 0; row < model.rowCount(); ++row) {
    QVariantMap shown;
    const QHash<int, QByteArray> names = model.roleNames();
    for (auto it = names.cbegin(); it != names.cend(); ++it) {
      const QVariant value = role(model, row, it.key());
      if (value.isValid() && !value.toString().isEmpty() && value != QVariant(false) && value != QVariant(0)) {
        shown.insert(QString::fromUtf8(it.value()), value);
      }
    }
    rows.append(show(shown));
  }
  return QStringLiteral("status %1, rows: %2").arg(model.status(), rows.isEmpty() ? QStringLiteral("(none)") : rows.join(QStringLiteral("; ")));
}

// Opens `threadKey`'s route, and waits for its stream.
inline void look(World& world, const QString& threadKey, bool live = true) {
  world.native().controller<NavigationController>()->open(NavigationController::Route::thread(threadKey));
  world.waitFor([&] { return store(world)->activeThread() == threadKey && store(world)->activeTimeline(); },
                QStringLiteral("the thread to open"));
  if (!live) return;
  world.waitFor([&] { return timeline(world).status() == QLatin1String("live"); },
                [&] { return QStringLiteral("the thread to follow its MC; %1").arg(describe(timeline(world))); });
}

// What the client's cache holds of the thread `key`.
inline cache::Thread keptCopy(World& world, const QString& key) {
  cache::Thread copy;
  LocalCache* kept = world.native().cache();
  kept->loadThread(key, kept, [&copy](const cache::Thread& thread) { copy = thread; });
  kept->drain();
  return copy;
}

// The thread "thread-1" of `project`, opened and followed.
inline void lookAtThread(World& world, const QString& project) {
  world.mc.threads.insert(kThread, {{QStringLiteral("id"), kThread}, {QStringLiteral("title"), QStringLiteral("Tax line")}, {QStringLiteral("projectId"), project},
                                      {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")}, {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}});
  world.mc.sendRow(kThread, world.mc.threads.value(kThread));
  world.sync();
  FakeStreams& fake = world.mc.part<FakeStreams>();
  fake.thread = kThread;
  fake.environment = world.mc.environmentId;
  look(world, world.mc.environmentId + QLatin1Char(':') + kThread);
}

}  // namespace stream
