// A plugin's notice in a turn (features/plugins/turn-hooks.feature): one that
// offers to stop its turn draws Stop while the turn works, and Stop asks the MC
// to stop it. The notice is the item HalC2.Plugins.Host.notice/5 writes; the
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

bool askedToStop(World& world) {
  for (const QJsonObject& command : std::as_const(world.mc.commands)) {
    if (command.value(QLatin1String("type")) == QLatin1String("run.interrupt")) return true;
  }
  return false;
}

const Steps steps([] {
  step(QStringLiteral("a plugin's notice in a turn that is working, offering to stop it"), [](World& world, const Captures&, const Table&) {
    startWorkingTurn(world);
    addCommand(world, 1);
    addItem(world, QStringLiteral("system_notice"),
            {{QStringLiteral("message"), QStringLiteral("The agent is repeating itself.")},
             {QStringLiteral("title"), QStringLiteral("Loop")},
             {QStringLiteral("pluginId"), QStringLiteral("token-economizer")},
             {QStringLiteral("actions"), QJsonArray{QStringLiteral("interrupt")}}});
  });
  step(QStringLiteral("the notice shows a Stop action"), [](World& world, const Captures&, const Table&) {
    const QVariantMap entry = notice(world);
    expect(entry.value(QStringLiteral("interrupt")).toBool() && entry.value(QStringLiteral("detail")) == QLatin1String("The agent is repeating itself."),
           QStringLiteral("the notice is %1").arg(show(entry)));
    Brick& brick = timelineBrick(world);
    QList<QQuickItem*> links;
    world.waitFor([&] { return !(links = stopLinks(world)).isEmpty(); }, QStringLiteral("the timeline to draw the notice's Stop"));
    expect(brick.shows(QStringLiteral("Loop")), QStringLiteral("the timeline does not draw the notice's title"));
    QTest::mouseClick(&brick.window(), Qt::LeftButton, Qt::NoModifier, brick.at(links.last()));
    world.sync();
    expect(askedToStop(world), QStringLiteral("Stop did not ask the MC to stop the turn; it has %1").arg(world.describeCommands()));
  });
  step(QStringLiteral("the turn ends"), [](World& world, const Captures&, const Table&) {
    settleRun(world, QStringLiteral("interrupted"), 30);
  });
  step(QStringLiteral("the notice no longer offers to stop it"), [](World& world, const Captures&, const Table&) {
    const QVariantMap entry = notice(world);
    expect(!entry.value(QStringLiteral("interrupt")).toBool(), QStringLiteral("the notice is %1").arg(show(entry)));
    world.waitFor([&] { return stopLinks(world).isEmpty(); }, QStringLiteral("the timeline to stop drawing the notice's Stop"));
  });
});

}  // namespace
