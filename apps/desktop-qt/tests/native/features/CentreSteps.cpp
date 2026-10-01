// The thread in the window's centre, past its rows: copying a message
// (TimelineModel::copy), the two ways into a revert, a reply's and the diff
// panel's, which both ask Panel.diff (ThreadDiff) and so the same question,
// and following a thread again after its MC stopped sending it
// (ThreadStore::reload) (timeline/streaming.feature, timeline/checkpoints.feature,
// and the reply without a checkpoint in features/desktop/native-centre.feature).

#include <QClipboard>
#include <QGuiApplication>
#include <QJsonObject>

#include "Harness.h"
#include "RightPanelController.h"
#include "Stream.h"
#include "ThreadDiff.h"
#include "ThreadStore.h"
#include "TimelineModel.h"
#include "World.h"

namespace {

using namespace stream;

// The agent replies the steps' thread has, in order.
struct FakeTurns {
  QStringList replies;
};

QString threadKey(World& world) {
  const FakeStreams& fake = world.mc.part<FakeStreams>();
  return fake.environment + QLatin1Char(':') + fake.thread;
}

ThreadDiff& diff(World& world) {
  return *world.native().controller<RightPanelController>()->diff();
}

// The row of the reply reading `text`, or empty.
QString rowReading(TimelineModel& model, const QString& text) {
  for (int row = 0; row < model.rowCount(); ++row) {
    if (role(model, row, TimelineModel::TextRole).toString() == text) return role(model, row, TimelineModel::IdRole).toString();
  }
  return {};
}

QList<QJsonObject> rollbacks(World& world) {
  QList<QJsonObject> found;
  for (const QJsonObject& command : std::as_const(world.mc.commands)) {
    if (command.value(QLatin1String("type")) == QLatin1String("checkpoint.rollback")) found.append(command);
  }
  return found;
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("a thread in %1 whose first turn left no checkpoint").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAtThread(world, c[0]);
    startRun(world, 60);
    world.mc.part<FakeTurns>().replies.append(
        addItem(world, QStringLiteral("assistant_message"), {{QStringLiteral("text"), QStringLiteral("Turn 1 is done.")}}));
    settleRun(world, QStringLiteral("completed"), 30);
  });

  // Copying.
  step(QStringLiteral("the agent has answered"), [](World& world, const Captures&, const Table&) {
    startRun(world, 30);
    world.mc.part<FakeTurns>().replies.append(
        addItem(world, QStringLiteral("assistant_message"), {{QStringLiteral("text"), QStringLiteral("The cart adds **tax** now.")}}));
    settleRun(world, QStringLiteral("completed"), 30);
  });
  step(QStringLiteral("the user copies the reply"), [](World& world, const Captures&, const Table&) {
    QGuiApplication::clipboard()->clear();
    const QString reply = world.mc.part<FakeTurns>().replies.value(0);
    expect(timeline(world).copy(reply), QStringLiteral("the reply cannot be copied; %1").arg(describe(timeline(world))));
  });
  step(QStringLiteral("the reply's markdown is on the clipboard"), [](World&, const Captures&, const Table&) {
    const QString copied = QGuiApplication::clipboard()->text();
    expect(copied == QLatin1String("The cart adds **tax** now."), QStringLiteral("the clipboard holds \"%1\"").arg(copied));
  });

  // Reverting: the reply's Revert and the diff panel's, as their QML asks
  // (ThreadView.askRevert, DiffPanel), answered as RevertDialog does. The
  // thread is PanelSteps' "a thread in … with three finished turns".
  step(QStringLiteral("the user asks to revert to turn (\\d+) from (its reply|the diff panel)"), [](World& world, const Captures& c, const Table&) {
    const int turn = c[0].toInt();
    if (c[1] == QLatin1String("its reply")) {
      TimelineModel& model = timeline(world);
      const QString reply = rowReading(model, QStringLiteral("Answer %1").arg(turn));
      const QVariantMap checkpoint = model.checkpointOf(reply);
      expect(checkpoint.value(QStringLiteral("turn")).toInt() == turn,
             QStringLiteral("the reply offers %1; %2").arg(show(checkpoint), describe(model)));
      diff(world).requestRevert(turn);
    } else {
      world.bridge().dispatch(QStringLiteral("panel.open"), QVariantMap{{QStringLiteral("tab"), QStringLiteral("diff")}, {QStringLiteral("turn"), turn}});
      world.waitFor([&] { return diff(world).shownTurn() == turn; }, [&] { return QStringLiteral("the diff to show turn %1").arg(turn); });
      diff(world).requestRevert(0);
    }
    expect(diff(world).revertTurn() == turn, QStringLiteral("the user is asked about turn %1").arg(diff(world).revertTurn()));
    expect(rollbacks(world).isEmpty(), QStringLiteral("a rollback was sent before the user confirmed"));
  });
  step(QStringLiteral("the user confirms with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QStringList answers{QStringLiteral("Keep files"), QStringLiteral("Revert files too")};
    expect(answers.contains(c[0]), QStringLiteral("the dialog offers %1").arg(answers.join(QStringLiteral(", "))));
    diff(world).confirmRevert(c[0] == answers.at(1));
    world.waitFor([&] { return !diff(world).reverting(); }, QStringLiteral("the revert to finish"));
    world.sync();
  });
  step(QStringLiteral("the MC is asked to leave the files as they are"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !rollbacks(world).isEmpty(); }, [] { return QStringLiteral("a rewind; the MC got none"); });
    const QJsonObject command = rollbacks(world).constLast();
    expect(command.value(QLatin1String("restoreFiles")) == QJsonValue(false), QStringLiteral("the MC was asked %1").arg(show(command.toVariantMap())));
  });
  step(QStringLiteral("the first turn's reply offers no rewind"), [](World& world, const Captures&, const Table&) {
    TimelineModel& model = timeline(world);
    const QString reply = world.mc.part<FakeTurns>().replies.value(0);
    expect(model.checkpointOf(reply).isEmpty(), QStringLiteral("the reply offers %1").arg(show(model.checkpointOf(reply))));
    diff(world).requestRevert(1);
    expect(!diff(world).canRevert() && diff(world).revertTurn() == 0, QStringLiteral("the user is asked to revert"));
  });

  // Following again.
  step(QStringLiteral("the MC stops sending the thread"), [](World& world, const Captures&, const Table&) {
    FakeStreams& fake = world.mc.part<FakeStreams>();
    fake.offline.insert(fake.environment);
    for (const int id : followers(world, fake.thread)) {
      world.mc.send({{QStringLiteral("t"), QStringLiteral("error")}, {QStringLiteral("id"), id}, {QStringLiteral("reason"), QStringLiteral("stream closed")}});
      world.mc.forget(id);
    }
    world.sync();
  });
  step(QStringLiteral("the MC can send the thread again"), [](World& world, const Captures&, const Table&) {
    FakeStreams& fake = world.mc.part<FakeStreams>();
    fake.offline.remove(fake.environment);
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
