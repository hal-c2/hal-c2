// The thread in the window's centre, past its rows: copying a message
// (TimelineModel::copy), rewinding the thread to a turn's checkpoint
// (ThreadStore::revert, `checkpoint.rollback`) and following it again after
// its node stopped sending it (ThreadStore::reload)
// (timeline/streaming.feature, timeline/checkpoints.feature,
// features/desktop/native-centre.feature).

#include <QClipboard>
#include <QGuiApplication>
#include <QJsonArray>
#include <QJsonObject>

#include "Harness.h"
#include "Stream.h"
#include "ThreadStore.h"
#include "TimelineModel.h"
#include "World.h"

namespace {

using namespace stream;

// What the steps' thread has: each finished turn's run, reply and checkpoint.
struct FakeTurns {
  QStringList runs;
  QStringList replies;
  QStringList checkpoints;
};

QString threadKey(World& world) {
  const FakeStreams& fake = world.node.part<FakeStreams>();
  return world.node.environmentId + QLatin1Char(':') + fake.thread;
}

// A finished turn: the user's message, the agent's reply, and the checkpoint
// it left (ready unless `checkpoint` is false).
void finishTurn(World& world, int n, bool checkpoint = true) {
  const QString run = startRun(world, 60);
  const QString reply = addItem(world, QStringLiteral("assistant_message"), {{QStringLiteral("text"), QStringLiteral("Turn %1 is done.").arg(n)}});
  settleRun(world, QStringLiteral("completed"), 30);
  FakeTurns& turns = world.node.part<FakeTurns>();
  turns.runs.append(run);
  turns.replies.append(reply);
  const QString id = QStringLiteral("checkpoint-%1").arg(n);
  turns.checkpoints.append(checkpoint ? id : QString());
  if (!checkpoint) return;
  set(world, QStringLiteral("checkpoint"), id,
      {{QStringLiteral("id"), id}, {QStringLiteral("scopeId"), QStringLiteral("scope-1")}, {QStringLiteral("runId"), run},
       {QStringLiteral("status"), QStringLiteral("ready")}});
}

// Rewinds as the node does: the later runs become rolled_back.
void rollBackOnCommand(World& world) {
  World* w = &world;
  world.node.effects.append([w](const QJsonObject& command) {
    if (command.value(QLatin1String("type")) != QLatin1String("checkpoint.rollback")) return;
    FakeTurns& turns = w->node.part<FakeTurns>();
    const int target = int(turns.checkpoints.indexOf(command.value(QLatin1String("checkpointId")).toString()));
    // The effect runs inside the node's answer, so it sends without waiting on a round trip.
    FakeStreams& fake = w->node.part<FakeStreams>();
    for (int i = target + 1; i < turns.runs.size(); ++i) {
      const QJsonObject patch{{QStringLiteral("s"), QJsonObject{{QStringLiteral("status"), QStringLiteral("rolled_back")}}}};
      change(*w, QStringLiteral("run"), turns.runs.at(i), patch, true);
      for (const int follower : followers(*w, fake.thread)) {
        w->node.send({{QStringLiteral("t"), QStringLiteral("events")}, {QStringLiteral("id"), follower}, {QStringLiteral("offset"), fake.seq},
                      {QStringLiteral("events"),
                       QJsonArray{QJsonValue(QJsonArray{fake.seq, QStringLiteral("run"), turns.runs.at(i), patch, iso(now())})}}});
      }
    }
  });
}

QList<QJsonObject> rollbacks(World& world) {
  QList<QJsonObject> found;
  for (const QJsonObject& command : std::as_const(world.node.commands)) {
    if (command.value(QLatin1String("type")) == QLatin1String("checkpoint.rollback")) found.append(command);
  }
  return found;
}

QJsonObject lastRollback(World& world) {
  world.waitFor([&] { return !rollbacks(world).isEmpty(); }, [] { return QStringLiteral("a rewind; the node got none"); });
  return rollbacks(world).constLast();
}

bool shows(TimelineModel& model, const QString& text) {
  for (int row = 0; row < model.rowCount(); ++row) {
    if (role(model, row, TimelineModel::TextRole).toString() == text) return true;
  }
  return false;
}

bool revert(World& world, int turn, bool restoreFiles) {
  const QString reply = world.node.part<FakeTurns>().replies.value(turn - 1);
  return store(world)->revert(threadKey(world), reply, restoreFiles);
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("a thread in %1 with three finished turns").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAtThread(world, c[0]);
    for (int n = 1; n <= 3; ++n) finishTurn(world, n);
    rollBackOnCommand(world);
  });
  step(QStringLiteral("a thread in %1 whose first turn left no checkpoint").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAtThread(world, c[0]);
    finishTurn(world, 1, false);
  });

  // Copying.
  step(QStringLiteral("the agent has answered"), [](World& world, const Captures&, const Table&) {
    startRun(world, 30);
    world.node.part<FakeTurns>().replies.append(
        addItem(world, QStringLiteral("assistant_message"), {{QStringLiteral("text"), QStringLiteral("The cart adds **tax** now.")}}));
    settleRun(world, QStringLiteral("completed"), 30);
  });
  step(QStringLiteral("the user copies the reply"), [](World& world, const Captures&, const Table&) {
    QGuiApplication::clipboard()->clear();
    const QString reply = world.node.part<FakeTurns>().replies.value(0);
    expect(timeline(world).copy(reply), QStringLiteral("the reply cannot be copied; %1").arg(describe(timeline(world))));
  });
  step(QStringLiteral("the reply's markdown is on the clipboard"), [](World&, const Captures&, const Table&) {
    const QString copied = QGuiApplication::clipboard()->text();
    expect(copied == QLatin1String("The cart adds **tax** now."), QStringLiteral("the clipboard holds \"%1\"").arg(copied));
  });

  // Rewinding.
  step(QStringLiteral("the user reverts the thread to the checkpoint after turn (\\d+)"), [](World& world, const Captures& c, const Table&) {
    expect(revert(world, c[0].toInt(), true), QStringLiteral("turn %1 offers no checkpoint; %2").arg(c[0], describe(timeline(world))));
  });
  step(QStringLiteral("the user rewinds the conversation to turn (\\d+) and keeps the files"), [](World& world, const Captures& c, const Table&) {
    expect(revert(world, c[0].toInt(), false), QStringLiteral("turn %1 offers no checkpoint; %2").arg(c[0], describe(timeline(world))));
  });
  step(QStringLiteral("turns 2 and 3 are removed from the conversation"), [](World& world, const Captures&, const Table&) {
    TimelineModel& model = timeline(world);
    world.waitFor([&] { return !shows(model, QStringLiteral("Turn 2 is done.")) && !shows(model, QStringLiteral("Turn 3 is done.")); },
                  [&] { return describe(model); });
    expect(shows(model, QStringLiteral("Turn 1 is done.")), QStringLiteral("turn 1 is gone too; %1").arg(describe(model)));
  });
  step(QStringLiteral("the workspace files match the end of turn (\\d+)"), [](World& world, const Captures& c, const Table&) {
    const QJsonObject command = lastRollback(world);
    expect(command.value(QLatin1String("checkpointId")) == world.node.part<FakeTurns>().checkpoints.value(c[0].toInt() - 1) &&
               command.value(QLatin1String("scopeId")) == QLatin1String("scope-1") && command.value(QLatin1String("restoreFiles")).toBool() &&
               command.value(QLatin1String("threadId")) == world.node.part<FakeStreams>().thread,
           QStringLiteral("the node was asked %1").arg(show(command.toVariantMap())));
  });
  step(QStringLiteral("the node is asked to leave the files as they are"), [](World& world, const Captures&, const Table&) {
    const QJsonObject command = lastRollback(world);
    expect(command.value(QLatin1String("restoreFiles")) == QJsonValue(false), QStringLiteral("the node was asked %1").arg(show(command.toVariantMap())));
  });
  step(QStringLiteral("the node refuses rewinds with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.node.refusals.insert(QStringLiteral("checkpoint.rollback"), c[0]);
  });
  step(QStringLiteral("the conversation still has its three turns"), [](World& world, const Captures&, const Table&) {
    world.sync();
    TimelineModel& model = timeline(world);
    for (int n = 1; n <= 3; ++n) {
      expect(shows(model, QStringLiteral("Turn %1 is done.").arg(n)), QStringLiteral("turn %1 is gone; %2").arg(n).arg(describe(model)));
    }
  });
  step(QStringLiteral("the first turn's reply offers no rewind"), [](World& world, const Captures&, const Table&) {
    TimelineModel& model = timeline(world);
    const QString reply = world.node.part<FakeTurns>().replies.value(0);
    expect(model.checkpointOf(reply).isEmpty(), QStringLiteral("the reply offers %1").arg(show(model.checkpointOf(reply))));
    expect(!store(world)->revert(threadKey(world), reply), QStringLiteral("the thread was rewound"));
    world.sync();
    expect(rollbacks(world).isEmpty(), QStringLiteral("the node was asked to rewind"));
  });

  // Following again.
  step(QStringLiteral("the node stops sending the thread"), [](World& world, const Captures&, const Table&) {
    FakeStreams& fake = world.node.part<FakeStreams>();
    fake.offline.insert(fake.node);
    for (const int id : followers(world, fake.thread)) {
      world.node.send({{QStringLiteral("t"), QStringLiteral("error")}, {QStringLiteral("id"), id}, {QStringLiteral("reason"), QStringLiteral("stream closed")}});
      world.node.forget(id);
    }
    world.sync();
  });
  step(QStringLiteral("the node can send the thread again"), [](World& world, const Captures&, const Table&) {
    FakeStreams& fake = world.node.part<FakeStreams>();
    fake.offline.remove(fake.node);
  });
  step(QStringLiteral("the user retries the thread"), [](World& world, const Captures&, const Table&) {
    store(world)->reload(threadKey(world));
  });
  step(QStringLiteral("the thread is still unreachable"), [](World& world, const Captures&, const Table&) {
    world.sync();
    TimelineModel& model = timeline(world);
    expect(model.status() == QLatin1String("unreachable"), describe(model));
  });
});

}  // namespace
