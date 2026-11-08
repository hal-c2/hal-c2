// A plugin's notice in a turn (features/plugins/turn-hooks.feature): one that
// offers to stop its turn draws Stop while the turn works, and Stop asks the MC
// to stop that turn, never one that started after it. The notice is the item HalC2.Plugins.Host.notice/5 writes; the
// stream is Stream.h's, the rows the TimelineModel's and the Timeline brick's.

#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>
#include <QTest>

#include <memory>

#include "Brick.h"
#include "Harness.h"
#include "Stream.h"
#include "Turn.h"
#include "World.h"

namespace {

using namespace stream;

// The notice's entry, wherever the timeline shows it (a settled turn folds
// its work behind a summary; this opens it).
QVariantMap notice(World& world) {
  TimelineModel& model = timeline(world);
  for (const QString kind : {QStringLiteral("fold"), QStringLiteral("work")}) {
    for (int row = 0; row < model.rowCount(); ++row) {
      if (role(model, row, TimelineModel::KindRole).toString() == kind && role(model, row, TimelineModel::HiddenCountRole).toInt() > 0 &&
          !role(model, row, TimelineModel::ExpandedRole).toBool())
        model.toggle(role(model, row, TimelineModel::IdRole).toString());
    }
  }
  for (int row = 0; row < model.rowCount(); ++row) {
    for (const QVariant& entry : role(model, row, TimelineModel::EntriesRole).toList()) {
      if (entry.toMap().value(QStringLiteral("label")) == QLatin1String("Loop")) return entry.toMap();
    }
  }
  fail(QStringLiteral("the timeline shows no notice; %1").arg(describe(model)));
  return {};
}

Brick& timelineBrick(World& world) {
  if (!world.brick) {
    world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nTimeline {}\n", QSize(820, 1400));
    world.brick->root()->setProperty("model", QVariant::fromValue(static_cast<QObject*>(&timeline(world))));
  }
  return *world.brick;
}

void collect(QQuickItem* item, QList<QQuickItem*>& out) {
  if (item->objectName() == QLatin1String("noticeInterrupt") && item->isVisible()) out.append(item);
  for (QQuickItem* child : item->childItems()) collect(child, out);
}

QList<QQuickItem*> stopLinks(World& world) {
  QList<QQuickItem*> links;
  collect(timelineBrick(world).window().contentItem(), links);
  return links;
}

// The runs the MC was asked to stop.
QStringList stopped(World& world) {
  QStringList runs;
  for (const QJsonObject& command : std::as_const(world.mc.commands)) {
    if (command.value(QLatin1String("type")) == QLatin1String("run.interrupt")) runs.append(command.value(QLatin1String("runId")).toString());
  }
  return runs;
}

// The run the scenario's notice was shown in.
QString shownIn;
QString noticeRun(World&) { return shownIn; }

void clickStop(World& world, const QString& what) {
  Brick& brick = timelineBrick(world);
  QList<QQuickItem*> links;
  world.waitFor([&] { return !(links = stopLinks(world)).isEmpty(); }, QStringLiteral("the timeline to draw %1").arg(what));
  QTest::mouseClick(&brick.window(), Qt::LeftButton, Qt::NoModifier, brick.at(links.last()));
  world.sync();
}

void expectStopped(World& world) {
  expect(stopped(world) == QStringList{noticeRun(world)},
         QStringLiteral("Stop did not ask the MC to stop the notice's turn %1; it has %2").arg(noticeRun(world), world.describeCommands()));
}

const Steps steps([] {
  step(QStringLiteral("a plugin's notice in a turn that is working, offering to stop it"), [](World& world, const Captures&, const Table&) {
    startWorkingTurn(world);
    addCommand(world, 1);
    shownIn = world.mc.part<FakeStreams>().run;
    addItem(world, QStringLiteral("system_notice"),
            {{QStringLiteral("message"), QStringLiteral("The agent is repeating itself.")},
             {QStringLiteral("title"), QStringLiteral("Loop")},
             {QStringLiteral("pluginId"), QStringLiteral("token-economizer")},
             {QStringLiteral("actions"), QJsonArray{QStringLiteral("interrupt")}}});
  });
  step(QStringLiteral("the notice shows a Stop action"), [](World& world, const Captures&, const Table&) {
    const QVariantMap entry = notice(world);
    expect(entry.value(QStringLiteral("interrupt")).toString() == noticeRun(world) && entry.value(QStringLiteral("detail")) == QLatin1String("The agent is repeating itself."),
           QStringLiteral("the notice is %1").arg(show(entry)));
    Brick& brick = timelineBrick(world);
    QList<QQuickItem*> links;
    world.waitFor([&] { return !(links = stopLinks(world)).isEmpty(); }, QStringLiteral("the timeline to draw the notice's Stop"));
    expect(brick.shows(QStringLiteral("Loop")), QStringLiteral("the timeline does not draw the notice's title"));
    QTest::mouseClick(&brick.window(), Qt::LeftButton, Qt::NoModifier, brick.at(links.last()));
    world.sync();
    expectStopped(world);
  });
  step(QStringLiteral("the turn runs another command after the notice"), [](World& world, const Captures&, const Table&) { addCommand(world, 2); });
  step(QStringLiteral("the folded tool calls still offer Stop"), [](World& world, const Captures&, const Table&) {
    TimelineModel& model = timeline(world);
    int group = -1;
    for (int row = 0; row < model.rowCount(); ++row) {
      if (role(model, row, TimelineModel::KindRole).toString() == QLatin1String("work")) group = row;
    }
    expect(group >= 0 && role(model, group, TimelineModel::HiddenCountRole).toInt() > 0 && !role(model, group, TimelineModel::ExpandedRole).toBool(),
           QStringLiteral("the turn's calls are not folded; %1").arg(describe(model)));
    for (const QVariant& entry : role(model, group, TimelineModel::EntriesRole).toList()) {
      expect(entry.toMap().value(QStringLiteral("label")) != QLatin1String("Loop"), QStringLiteral("the notice is on screen, not folded"));
    }
    expect(role(model, group, TimelineModel::StopRunRole).toString() == noticeRun(world), QStringLiteral("the folded group does not offer to stop the notice's turn"));
    clickStop(world, QStringLiteral("the folded group's Stop"));
    expectStopped(world);
    expect(!role(model, group, TimelineModel::ExpandedRole).toBool(), QStringLiteral("Stop opened the folded group"));
  });
  // The thread's row says the next turn is the one working before the notice's turn
  // is seen to end, as a queued turn starts the moment the one before it settles.
  step(QStringLiteral("the thread moves on to its next turn before the notice redraws"), [](World& world, const Captures&, const Table&) {
    QJsonObject& row = world.mc.threads[kThread];
    row.insert(QStringLiteral("activeRunId"), QStringLiteral("run-next"));
    row.insert(QStringLiteral("latestRunId"), QStringLiteral("run-next"));
    world.mc.sendRow(kThread, row);
    world.sync();
  });
  step(QStringLiteral("the notice's Stop stops nothing"), [](World& world, const Captures&, const Table&) {
    clickStop(world, QStringLiteral("the notice's Stop"));
    expect(stopped(world).isEmpty(), QStringLiteral("Stop asked the MC to stop %1").arg(stopped(world).join(QStringLiteral(", "))));
  });
  step(QStringLiteral("the turn ends"), [](World& world, const Captures&, const Table&) {
    settleRun(world, QStringLiteral("interrupted"), 30);
  });
  step(QStringLiteral("the folded tool calls no longer offer Stop"), [](World& world, const Captures&, const Table&) {
    TimelineModel& model = timeline(world);
    for (int row = 0; row < model.rowCount(); ++row) {
      expect(role(model, row, TimelineModel::StopRunRole).toString().isEmpty(), QStringLiteral("row %1 still offers to stop the turn; %2").arg(row).arg(describe(model)));
    }
    world.waitFor([&] { return stopLinks(world).isEmpty(); }, QStringLiteral("the timeline to stop drawing the folded group's Stop"));
  });
  step(QStringLiteral("the notice no longer offers to stop it"), [](World& world, const Captures&, const Table&) {
    const QVariantMap entry = notice(world);
    expect(entry.value(QStringLiteral("interrupt")).toString().isEmpty(), QStringLiteral("the notice is %1").arg(show(entry)));
    world.waitFor([&] { return stopLinks(world).isEmpty(); }, QStringLiteral("the timeline to stop drawing the notice's Stop"));
  });
});

}  // namespace
