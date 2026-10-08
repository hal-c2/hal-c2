// The right panel's Agents tab (AgentsModel): the thread's subagents and
// running commands, from the MC's `stream` shape as the MC writes them
// (apps/server-ex delegation.ex: a `subagent` entity and its `subagent` turn
// item). features/timeline/plans-and-subagents.feature.

#include <QJsonObject>
#include <memory>

#include "AgentsModel.h"
#include "Harness.h"
#include "NavigationController.h"
#include "RightPanelController.h"
#include "Stream.h"
#include "World.h"

namespace {

using namespace stream;

// The subagents the steps started, by title, and the command running.
struct FakeAgents {
  QHash<QString, QString> ids;
  QString last;
  QString command;
  // Resets of the list since the tab opened, which would lose the user's scroll.
  std::shared_ptr<int> resets = std::make_shared<int>(0);
  // Redraws of the end times since the day turned over.
  std::shared_ptr<int> endedRedraws = std::make_shared<int>(0);
};

AgentsModel& agents(World& world) {
  return *world.native().controller<RightPanelController>()->agents();
}

QString describeAgents(World& world) {
  AgentsModel& model = agents(world);
  QStringList rows;
  for (int row = 0; row < model.rowCount(); ++row) {
    rows.append(QStringLiteral("%1 %2 %3 \"%4\" %5 (%6) \"%7\" \"%8\"")
                    .arg(model.value(row, AgentsModel::SectionRole).toString(), model.value(row, AgentsModel::KindRole).toString(),
                         model.value(row, AgentsModel::IdRole).toString(), model.value(row, AgentsModel::TitleRole).toString(),
                         model.value(row, AgentsModel::StatusLabelRole).toString(), model.value(row, AgentsModel::ElapsedRole).toString(),
                         model.value(row, AgentsModel::DetailRole).toString(), model.value(row, AgentsModel::EndedRole).toString()));
  }
  return QStringLiteral("the Agents tab lists %1%2")
      .arg(rows.isEmpty() ? QStringLiteral("nothing") : rows.join(QStringLiteral("; ")),
           agents(world).ticking() ? QStringLiteral(", ticking") : QString());
}

// The next local midnight the Agents tab waits for, a second past it; counts the end
// times it redraws from then on.
QDateTime pastMidnight(World& world) {
  const QDateTime midnight(world.now().toLocalTime().date().addDays(1), QTime(0, 0));
  expect(agents(world).nextDay() == midnight,
         QStringLiteral("the end times are next redrawn at %1, not midnight; %2").arg(agents(world).nextDay().toString(Qt::ISODate), describeAgents(world)));
  std::shared_ptr<int> redraws = world.mc.part<FakeAgents>().endedRedraws;
  QObject::connect(&agents(world), &QAbstractItemModel::dataChanged, &agents(world),
                   [redraws](const QModelIndex&, const QModelIndex&, const QList<int>& roles) {
                     if (roles.contains(AgentsModel::EndedRole)) ++*redraws;
                   });
  return midnight.addSecs(1);
}

int rowTitled(World& world, const QString& title) {
  AgentsModel& model = agents(world);
  for (int row = 0; row < model.rowCount(); ++row) {
    if (model.value(row, AgentsModel::TitleRole).toString() == title) return row;
  }
  fail(describeAgents(world));
}

// A subagent the agent delegated `since` seconds ago, as delegation.ex records it.
void startSubagent(World& world, const QString& title, int since) {
  FakeStreams& fake = world.mc.part<FakeStreams>();
  if (fake.run.isEmpty()) startRun(world);
  world.setTime(now());
  const QString slug = title.toLower().replace(QLatin1Char(' '), QLatin1Char('-'));
  const QString id = QStringLiteral("task-") + slug;
  const QString started = iso(now().addSecs(-since));
  set(world, QStringLiteral("subagent"), id,
      {{QStringLiteral("id"), id}, {QStringLiteral("threadId"), fake.thread}, {QStringLiteral("runId"), fake.run},
       {QStringLiteral("childThreadId"), QStringLiteral("thread-") + slug}, {QStringLiteral("prompt"), QStringLiteral("write the %1").arg(title.toLower())},
       {QStringLiteral("title"), title}, {QStringLiteral("model"), QStringLiteral("gpt-5.5")}, {QStringLiteral("status"), QStringLiteral("running")},
       {QStringLiteral("startedAt"), started}, {QStringLiteral("completedAt"), QJsonValue()}, {QStringLiteral("updatedAt"), started}});
  addItem(world, QStringLiteral("subagent"),
          {{QStringLiteral("id"), QStringLiteral("turn-item:subagent:") + id}, {QStringLiteral("status"), QStringLiteral("running")},
           {QStringLiteral("subagentId"), id}, {QStringLiteral("childThreadId"), QStringLiteral("thread-") + slug}, {QStringLiteral("startedAt"), started}});
  world.mc.part<FakeAgents>().ids.insert(title, id);
  world.mc.part<FakeAgents>().last = id;
}

void settleSubagent(World& world, const QString& id, const QJsonObject& fields) {
  set(world, QStringLiteral("subagent"), id, fields);
  set(world, QStringLiteral("turn-item"), QStringLiteral("turn-item:subagent:") + id, fields);
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("the agent started the subagents %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    startSubagent(world, c[0], 90);
    startSubagent(world, c[1], 80);
  });
  step(QStringLiteral("the agent started the subagent %1 (\\d+) seconds ago").arg(q), [](World& world, const Captures& c, const Table&) {
    startSubagent(world, c[0], c[1].toInt());
  });
  step(QStringLiteral("%1 finished (\\d+) seconds after it started").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString id = world.mc.part<FakeAgents>().ids.value(c[0]);
    const QString started = world.mc.part<FakeStreams>().threads.value(kThread).value(QStringLiteral("subagent\n") + id).value(QLatin1String("startedAt")).toString();
    settleSubagent(world, id, {{QStringLiteral("status"), QStringLiteral("completed")},
                               {QStringLiteral("completedAt"), iso(QDateTime::fromString(started, Qt::ISODate).addSecs(c[1].toInt()))}});
  });
  step(QStringLiteral("the subagent finishes with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    settleSubagent(world, world.mc.part<FakeAgents>().last,
                   {{QStringLiteral("status"), QStringLiteral("completed")}, {QStringLiteral("result"), c[0]}, {QStringLiteral("completedAt"), iso(now())}});
  });

  step(QStringLiteral("the agent is running the command %1").arg(q), [](World& world, const Captures& c, const Table&) {
    startRun(world);
    world.mc.part<FakeAgents>().command =
        addItem(world, QStringLiteral("command_execution"),
                {{QStringLiteral("input"), c[0]}, {QStringLiteral("status"), QStringLiteral("running")}, {QStringLiteral("startedAt"), iso(now())}});
  });
  step(QStringLiteral("the command finishes"), [](World& world, const Captures&, const Table&) {
    set(world, QStringLiteral("turn-item"), world.mc.part<FakeAgents>().command,
        {{QStringLiteral("status"), QStringLiteral("completed")}, {QStringLiteral("exitCode"), 0}});
  });

  step(QStringLiteral("the user opens the Agents tab"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("rightPanel.add"), QVariantMap{{QStringLiteral("kind"), QStringLiteral("agents")}});
    world.sync();
    expect(at(world.state(QStringLiteral("panel")), QStringLiteral("activeId")) == QStringLiteral("agents"), QStringLiteral("the Agents tab is not shown"));
    std::shared_ptr<int> resets = world.mc.part<FakeAgents>().resets;
    QObject::connect(&agents(world), &QAbstractItemModel::modelReset, &agents(world), [resets] { ++*resets; });
  });
  step(QStringLiteral("the user switches to the Diff tab"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("rightPanel.add"), QVariantMap{{QStringLiteral("kind"), QStringLiteral("diff")}});
    world.sync();
  });

  step(QStringLiteral("the Agents tab lists %1 as %1 and %1 as %1").arg(q), [](World& world, const Captures& c, const Table&) {
    AgentsModel& model = agents(world);
    const int first = rowTitled(world, c[0]);
    const int second = rowTitled(world, c[2]);
    expect(first < second && model.value(first, AgentsModel::StatusLabelRole) == c[1] && model.value(second, AgentsModel::StatusLabelRole) == c[3],
           describeAgents(world));
  });
  step(QStringLiteral("the Agents tab lists %1 as %1 with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    AgentsModel& model = agents(world);
    const int row = rowTitled(world, c[0]);
    expect(model.value(row, AgentsModel::StatusLabelRole) == c[1] && model.value(row, AgentsModel::DetailRole) == c[2], describeAgents(world));
  });
  step(QStringLiteral("the Agents tab lists, in order:"), [](World& world, const Captures&, const Table& table) {
    AgentsModel& model = agents(world);
    bool same = model.rowCount() == table.size();
    for (int row = 0; same && row < table.size(); ++row) {
      same = model.value(row, AgentsModel::TitleRole).toString() == table.at(row).at(0) &&
             model.value(row, AgentsModel::SectionRole).toString() == table.at(row).at(1).toLower();
    }
    expect(same, describeAgents(world));
  });
  step(QStringLiteral("%1 is shown to have ended %1").arg(q), [](World& world, const Captures& c, const Table&) {
    // ICU puts a narrow no-break space before "AM".
    const QString ended = agents(world).value(rowTitled(world, c[0]), AgentsModel::EndedRole).toString().replace(QChar(0x202F), QLatin1Char(' '));
    expect(ended == c[1], describeAgents(world));
  });
  step(QStringLiteral("the Agents tab never started its list over"), [](World& world, const Captures&, const Table&) {
    expect(*world.mc.part<FakeAgents>().resets == 0, QStringLiteral("the list started over %1 times; %2").arg(*world.mc.part<FakeAgents>().resets).arg(describeAgents(world)));
  });
  step(QStringLiteral("%1 is shown to have taken %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(agents(world).value(rowTitled(world, c[0]), AgentsModel::ElapsedRole) == c[1], describeAgents(world));
  });
  step(QStringLiteral("a second passes"), [](World& world, const Captures&, const Table&) {
    // The model's own once-a-second timer, without waiting a second for it.
    expect(agents(world).ticking(), describeAgents(world));
    world.setTime(world.now().addSecs(1));
    agents(world).tick();
  });
  step(QStringLiteral("the day turns over"), [](World& world, const Captures&, const Table&) {
    // The model's own midnight timer, without waiting for midnight.
    world.setTime(pastMidnight(world));
    agents(world).redrawEnded();
  });
  step(QStringLiteral("the day turns over while the desktop sleeps"), [](World& world, const Captures&, const Table&) {
    // Midnight passed, and the midnight timer has yet to fire.
    world.setTime(pastMidnight(world));
  });
  step(QStringLiteral("the Agents tab redraws when each subagent ended"), [](World& world, const Captures&, const Table&) {
    expect(*world.mc.part<FakeAgents>().endedRedraws > 0, describeAgents(world));
  });
  step(QStringLiteral("the Agents tab's times stand still"), [](World& world, const Captures&, const Table&) {
    expect(!agents(world).ticking(), describeAgents(world));
  });
  step(QStringLiteral("the Agents tab lists the running command %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const int row = rowTitled(world, c[0]);
    expect(agents(world).value(row, AgentsModel::KindRole) == QStringLiteral("command") && agents(world).value(row, AgentsModel::RunningRole).toBool(),
           describeAgents(world));
  });
  step(QStringLiteral("the Agents tab lists no running command"), [](World& world, const Captures&, const Table&) {
    AgentsModel& model = agents(world);
    for (int row = 0; row < model.rowCount(); ++row) {
      expect(model.value(row, AgentsModel::KindRole) != QStringLiteral("command"), describeAgents(world));
    }
  });

  step(QStringLiteral("the user opens %1 from the Agents tab").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString child = agents(world).value(rowTitled(world, c[0]), AgentsModel::ChildThreadKeyRole).toString();
    world.bridge().dispatch(QStringLiteral("rightPanel.openThread"), QVariantMap{{QStringLiteral("threadKey"), child}});
    world.sync();
  });
  step(QStringLiteral("the subagent's thread is shown"), [](World& world, const Captures&, const Table&) {
    const QString shown = world.native().controller<NavigationController>()->threadKey();
    const QString child = world.mc.environmentId + QStringLiteral(":thread-") +
                          world.mc.part<FakeAgents>().last.mid(QStringLiteral("task-").size());
    expect(shown == child, QStringLiteral("the route shows \"%1\", not \"%2\"").arg(shown, child));
  });
});

}  // namespace
