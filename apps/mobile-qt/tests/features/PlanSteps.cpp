// A plan Codex marked finished, implemented from the phone
// (features/providers/codex.feature): the plan card over the composer offers
// it, and implementing it starts a run from the plan in the same thread. The
// planning thread's stream is ComposerSteps' fake (FakeThreads.h).

#include <QJsonArray>
#include <QJsonObject>

#include "FakeThreads.h"
#include "Harness.h"
#include "Phone.h"
#include "World.h"

namespace {

using S = QString;

const QString kMarkdown = QStringLiteral("# Tax line\n\n- Add the line\n- Test it");
const QString kPlanningTitle = QStringLiteral("Plan the tax line");

const Steps steps([] {
  step(S("a connected environment with the project %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    world.mc.projects.clear();
    world.mc.threads.clear();
    world.mc.projects.insert(c[0], {{S("id"), c[0]}, {S("title"), c[0]}, {S("workspaceRoot"), S("/work/") + c[0]},
                                     {S("scripts"), QJsonArray()}, {S("createdAt"), S("2026-09-01T09:00:00Z")},
                                     {S("updatedAt"), S("2026-09-01T09:00:00Z")}});
  });

  step(S("Codex proposed a plan and marked it finished"), [](World& world, const Captures&, const Table&) {
    world.thread = haveThread(world, kPlanningTitle);
    pairWithEnvironment(world);
    openThread(world, kPlanningTitle);
    const QString run = S("run-plan");
    setEntity(world.mc, world.thread, S("run"), run, {{S("id"), run}, {S("ordinal"), 1}, {S("status"), S("completed")}});
    setEntity(world.mc, world.thread, S("turn-item"), S("item-plan"),
              {{S("type"), S("proposed_plan")}, {S("markdown"), kMarkdown}, {S("planId"), S("plan-1")},
               {S("status"), S("completed")}, {S("streaming"), false}, {S("runId"), run}});
    setEntity(world.mc, world.thread, S("plan"), S("plan-1"),
              {{S("id"), S("plan-1")}, {S("kind"), S("proposed_plan")}, {S("status"), S("active")},
               {S("runId"), run}, {S("markdown"), kMarkdown}});
    updateRow(world.mc, world.thread, {{S("interactionMode"), S("plan")}, {S("activeRunId"), QJsonValue::Null},
                                       {S("hasActionableProposedPlan"), true}});
  });

  step(S("the plan is offered for implementation"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.state(S("turn")).toMap().value(S("plan")).isValid(); },
                  [&] { return S("the plan to be offered; the turn is %1").arg(show(world.state(S("turn")))); });
    world.item(S("planImplement"));
  });

  step(S("the user implements the plan"), [](World& world, const Captures&, const Table&) {
    world.tap(S("planImplement"));
    world.sync();
  });

  step(S("a new run starts from that plan"), [](World& world, const Captures&, const Table&) {
    QJsonObject message;
    world.waitFor([&] {
      for (const QJsonObject& command : std::as_const(world.mc.commands)) {
        if (command.value(QLatin1String("type")) == QLatin1String("message.dispatch")) message = command;
      }
      return !message.isEmpty();
    }, [&] { return S("the plan's message; the MC was sent %1 commands").arg(world.mc.commands.size()); });
    expect(message.value(QLatin1String("threadId")) == world.thread &&
               message.value(QLatin1String("sourcePlanRef")).toObject().value(QLatin1String("planId")) == QLatin1String("plan-1") &&
               message.value(QLatin1String("text")).toString().contains(QLatin1String("# Tax line")),
           S("the MC was sent %1").arg(show(message.toVariantMap())));
  });
});

}  // namespace
