// Background work in a thread (features/providers/claude.feature): a Claude
// monitor still running after its turn settled, as the shared Agents tab
// lists it in the desktop layout a tablet has room for. The MC's side is
// written as the Claude adapter writes it: a `dynamic_tool` turn item that
// stays running, never a `command_execution`.

#include <QJsonObject>
#include <QQuickItem>

#include "AgentsModel.h"
#include "FakeThreads.h"
#include "Harness.h"
#include "NativeShell.h"
#include "Phone.h"
#include "RightPanelController.h"
#include "ShellBridge.h"
#include "World.h"

namespace {

const QString kNow = QStringLiteral("2026-09-23T10:00:00Z");

AgentsModel& agents(World& world) {
  return *world.native().controller<RightPanelController>()->agents();
}

QString describeAgents(World& world) {
  AgentsModel& model = agents(world);
  QStringList rows;
  for (int row = 0; row < model.rowCount(); ++row) {
    rows.append(QStringLiteral("%1 \"%2\"").arg(model.value(row, AgentsModel::KindRole).toString(),
                                                model.value(row, AgentsModel::TitleRole).toString()));
  }
  return QStringLiteral("the Agents tab lists %1; the screen says: %2")
      .arg(rows.isEmpty() ? QStringLiteral("nothing") : rows.join(QStringLiteral("; ")),
           world.texts().join(QStringLiteral(" | ")));
}

const Steps steps([] {
  using S = QString;

  // The feature's Background registers the project (PlanSteps.cpp); pairing
  // is this step's, as there.
  step(S("Claude starts a monitor in the thread"), [](World& world, const Captures&, const Table&) {
    pairWithEnvironment(world);
    // Room for the desktop layout, whose right panel carries the Agents tab.
    world.resize(960, 600);
    world.waitFor([&] { return world.find(S("desktopLayout")) != nullptr; },
                  [&] { return S("the desktop layout; the screen says: %1").arg(world.texts().join(S(" | "))); });
    world.thread = haveThread(world, S("Tax line"));
    openThread(world, S("Tax line"));
    FakeStreams& fake = world.mc.part<FakeStreams>();
    world.run = S("run-%1").arg(fake.ordinal + 1);
    setEntity(world.mc, world.thread, S("run"), world.run,
              {{S("id"), world.run}, {S("ordinal"), ++fake.ordinal}, {S("status"), S("running")}, {S("requestedAt"), kNow}, {S("startedAt"), kNow}});
    const QString message = S("message:") + world.run;
    setEntity(world.mc, world.thread, S("turn-item"), message,
              {{S("id"), message}, {S("type"), S("user_message")}, {S("runId"), world.run}, {S("ordinal"), ++fake.ordinal},
               {S("status"), S("completed")}, {S("text"), S("start a monitor")}, {S("updatedAt"), kNow}});
    const QString monitor = S("dynamic_tool:%1").arg(fake.ordinal + 1);
    setEntity(world.mc, world.thread, S("turn-item"), monitor,
              {{S("id"), monitor}, {S("type"), S("dynamic_tool")}, {S("runId"), world.run}, {S("ordinal"), ++fake.ordinal},
               {S("status"), S("running")}, {S("toolName"), S("Monitor")},
               {S("input"), QJsonObject{{S("command"), S("tail -f log/dev.log")}, {S("description"), S("Watch the dev log")}}},
               {S("startedAt"), kNow}, {S("updatedAt"), kNow}});
    setEntity(world.mc, world.thread, S("run"), world.run, {{S("status"), S("completed")}, {S("completedAt"), kNow}});
    world.bridge().dispatch(S("rightPanel.add"), QVariantMap{{S("kind"), S("agents")}});
    world.sync();
  });

  step(S("the user sends another message and its turn is running"), [](World& world, const Captures&, const Table&) {
    FakeStreams& fake = world.mc.part<FakeStreams>();
    setEntity(world.mc, world.thread, S("run"), S("run-next"),
              {{S("id"), S("run-next")}, {S("ordinal"), ++fake.ordinal}, {S("status"), S("running")}, {S("requestedAt"), kNow}, {S("startedAt"), kNow}});
    world.sync();
  });

  step(S("the thread lists the monitor as background work"), [](World& world, const Captures&, const Table&) {
    world.waitFor(
        [&] {
          AgentsModel& model = agents(world);
          for (int row = 0; row < model.rowCount(); ++row) {
            if (model.value(row, AgentsModel::KindRole) == S("background") &&
                model.value(row, AgentsModel::TitleRole) == S("Monitor") && model.value(row, AgentsModel::RunningRole).toBool()) {
              return true;
            }
          }
          return false;
        },
        [&] { return describeAgents(world); });
    expect(world.find(S("agentsPanel")) != nullptr, describeAgents(world));
  });

  step(S("the monitor is not shown as a command"), [](World& world, const Captures&, const Table&) {
    AgentsModel& model = agents(world);
    for (int row = 0; row < model.rowCount(); ++row) {
      expect(model.value(row, AgentsModel::KindRole) != S("command"), describeAgents(world));
    }
  });
});

}  // namespace
