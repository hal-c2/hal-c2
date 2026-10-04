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

#include "Harness.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "ThreadStore.h"
#include "TimelineModel.h"
#include "World.h"

namespace stream {

// Every stream the MC serves: the entities of each thread, by "kind\nid".
// Events sent while nobody follows the thread (the connection is down) only
// change the entities, so the next snapshot carries them.
struct FakeStreams {
  QHash<QString, QMap<QString, QJsonObject>> threads;
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
  if (quiet) return;
  // QJsonValue keeps the event nested: Apple clang before 20 reads
  // QJsonArray{QJsonArray{...}} as a copy of the inner array.
  for (const int follower : followers(world, fake.thread)) {
    world.mc.send({{QStringLiteral("t"), QStringLiteral("events")}, {QStringLiteral("id"), follower}, {QStringLiteral("offset"), seq},
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
