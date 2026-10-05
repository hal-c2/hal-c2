// What the desktop shows of things the MC's orchestration decides: a turn that
// failed, a queue a usage limit holds, a plan Codex marked finished. The
// @shared scenarios of features/mc/orchestration and features/providers that
// are the MC's to decide and the client's to show; the MC's side is faked as
// the entities apps/server-ex writes (test/steps/orchestration, providers).

#include <QJsonArray>
#include <QJsonObject>

#include "Harness.h"
#include "NativeShell.h"
#include "Stream.h"
#include "World.h"

namespace {

using namespace stream;

struct Orchestration {
  QString project;
  qsizetype commandsBefore = 0;
};

QVariantMap turn(World& world) {
  return world.state(QStringLiteral("turn")).toMap();
}

void updateRow(World& world, const QString& thread, const QJsonObject& fields) {
  QJsonObject& row = world.mc.threads[thread];
  for (auto it = fields.begin(); it != fields.end(); ++it) row.insert(it.key(), it.value());
  world.mc.sendRow(thread, row);
  world.sync();
}

// The thread `id` of `project`, opened and followed.
void openThread(World& world, const QString& id, const QString& project) {
  if (world.shellSubscriptions() == 0) {
    world.connect();
    world.sync();
  }
  if (!world.mc.projects.contains(project)) {
    world.mc.projects.insert(project, {{QStringLiteral("id"), project}, {QStringLiteral("title"), project},
                                       {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + project}, {QStringLiteral("scripts"), QJsonArray()}});
  }
  world.mc.sendRow(project, world.mc.projects.value(project), QStringLiteral("project"));
  world.mc.threads.insert(id, {{QStringLiteral("id"), id}, {QStringLiteral("title"), QStringLiteral("Tax line")}, {QStringLiteral("projectId"), project},
                               {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")}, {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}});
  world.mc.sendRow(id, world.mc.threads.value(id));
  world.sync();
  FakeStreams& fake = world.mc.part<FakeStreams>();
  fake.thread = id;
  fake.environment = world.mc.environmentId;
  look(world, world.mc.environmentId + QLatin1Char(':') + id);
}

QString beginRun(World& world, const QString& thread) {
  const QString run = startRun(world);
  updateRow(world, thread, {{QStringLiteral("activeRunId"), run}, {QStringLiteral("latestRunId"), run}});
  return run;
}

QStringList queued(World& world) {
  QStringList texts;
  for (const QVariant& entry : turn(world).value(QStringLiteral("queue")).toList()) texts.append(entry.toMap().value(QStringLiteral("text")).toString());
  return texts;
}

bool shows(TimelineModel& model, const QString& text) {
  for (int row = 0; row < model.rowCount(); ++row) {
    if (role(model, row, TimelineModel::TextRole).toString().contains(text)) return true;
  }
  return false;
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("an MC with a project %1 rooted at a git repository").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.part<Orchestration>().project = c[0];
  });
  step(QStringLiteral("thread %1 exists in %1(?: with provider %1)?").arg(q), [](World& world, const Captures& c, const Table&) {
    openThread(world, c[0], c[1]);
  });

  // A turn that failed part-way (mc/orchestration/runs.feature).
  step(QStringLiteral("the provider streamed part of its answer to %1 and then failed").arg(q), [](World& world, const Captures& c, const Table&) {
    beginRun(world, c[0]);
    addItem(world, QStringLiteral("assistant_message"),
            {{QStringLiteral("text"), QStringLiteral("The cart total needs")}, {QStringLiteral("streaming"), true}, {QStringLiteral("status"), QStringLiteral("running")}});
    expect(shows(timeline(world), QStringLiteral("The cart total needs")), QStringLiteral("the answer is not streaming: %1").arg(describe(timeline(world))));
  });
  step(QStringLiteral("the failure is recorded"), [](World& world, const Captures&, const Table&) {
    FakeStreams& fake = world.mc.part<FakeStreams>();
    // As HalC2.Orchestration records it: the message stops streaming where it was, an error item, the run failed.
    for (auto it = fake.threads[fake.thread].cbegin(); it != fake.threads[fake.thread].cend(); ++it) {
      if (it->value(QLatin1String("type")) == QLatin1String("assistant_message")) {
        set(world, QStringLiteral("turn-item"), it->value(QLatin1String("id")).toString(),
            {{QStringLiteral("streaming"), false}, {QStringLiteral("status"), QStringLiteral("failed")}});
        break;
      }
    }
    addItem(world, QStringLiteral("error"),
            {{QStringLiteral("status"), QStringLiteral("failed")},
             {QStringLiteral("failure"), QJsonObject{{QStringLiteral("class"), QStringLiteral("provider_error")},
                                                     {QStringLiteral("message"), QStringLiteral("The provider stopped responding.")}}}});
    settleRun(world, QStringLiteral("failed"), 5);
    updateRow(world, fake.thread, {{QStringLiteral("activeRunId"), QJsonValue::Null}});
  });
  step(QStringLiteral("the partial answer stays in the failed run"), [](World& world, const Captures&, const Table&) {
    expect(shows(timeline(world), QStringLiteral("The cart total needs")), QStringLiteral("the partial answer is gone: %1").arg(describe(timeline(world))));
  });
  step(QStringLiteral("the run is marked failed"), [](World& world, const Captures&, const Table&) {
    TimelineModel& model = timeline(world);
    bool failed = false;
    for (int row = 0; row < model.rowCount(); ++row) {
      failed = failed || role(model, row, TimelineModel::KindRole).toString() == QLatin1String("error");
    }
    expect(failed && !turn(world).value(QStringLiteral("running")).toBool() && shows(model, QStringLiteral("The provider stopped responding.")),
           QStringLiteral("the thread shows %1; the turn is %2").arg(describe(model), show(turn(world))));
  });

  step(QStringLiteral("the provider retries a failed request during a turn of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    beginRun(world, c[0]);
    world.mc.part<Orchestration>().commandsBefore = world.mc.commands.size();
  });
  step(QStringLiteral("the retry is recorded"), [](World& world, const Captures&, const Table&) {
    // One item of the running run, which the retry does not fail (HalC2.Orchestration).
    addItem(world, QStringLiteral("error"),
            {{QStringLiteral("status"), QStringLiteral("running")}, {QStringLiteral("title"), QStringLiteral("Provider retry")},
             {QStringLiteral("retry"), QJsonObject{{QStringLiteral("attempt"), 2}, {QStringLiteral("maxAttempts"), 5}, {QStringLiteral("retryDelayMs"), QJsonValue::Null}}},
             {QStringLiteral("failure"), QJsonObject{{QStringLiteral("class"), QStringLiteral("transport_error")},
                                                     {QStringLiteral("code"), QStringLiteral("responseStreamDisconnected")},
                                                     {QStringLiteral("message"), QStringLiteral("stream disconnected before completion")}}}});
  });
  step(QStringLiteral("the turn's work log shows a provider retry"), [](World& world, const Captures&, const Table&) {
    TimelineModel& model = timeline(world);
    bool retry = false;
    for (int row = 0; row < model.rowCount(); ++row) {
      retry = retry || (role(model, row, TimelineModel::TitleRole).toString() == QLatin1String("Provider retry") &&
                        role(model, row, TimelineModel::TextRole).toString() == QLatin1String("stream disconnected before completion"));
    }
    expect(retry && turn(world).value(QStringLiteral("running")).toBool(),
           QStringLiteral("the thread shows %1; the turn is %2").arg(describe(model), show(turn(world))));
  });
  step(QStringLiteral("no second user turn is created"), [](World& world, const Captures&, const Table&) {
    TimelineModel& model = timeline(world);
    int asked = 0;
    for (int row = 0; row < model.rowCount(); ++row) {
      if (role(model, row, TimelineModel::KindRole).toString() == QLatin1String("message") && role(model, row, TimelineModel::AuthorRole).toString() == QLatin1String("user")) ++asked;
    }
    world.sync();
    expect(asked == 1 && world.mc.commands.size() == world.mc.part<Orchestration>().commandsBefore,
           QStringLiteral("%1 user messages; the client sent %2").arg(asked).arg(world.describeCommands()));
  });

  // A queue a usage limit holds (mc/orchestration/queue-and-steering.feature).
  step(QStringLiteral("%1 has a running turn and queued messages %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    beginRun(world, c[0]);
    FakeStreams& fake = world.mc.part<FakeStreams>();
    int position = 0;
    for (const QString& text : {c[1], c[2]}) {
      set(world, QStringLiteral("message"), QStringLiteral("message-") + text,
          {{QStringLiteral("id"), QStringLiteral("message-") + text}, {QStringLiteral("role"), QStringLiteral("user")}, {QStringLiteral("text"), text}});
      set(world, QStringLiteral("run"), QStringLiteral("run-queued-") + text,
          {{QStringLiteral("id"), QStringLiteral("run-queued-") + text}, {QStringLiteral("ordinal"), ++fake.ordinal}, {QStringLiteral("status"), QStringLiteral("queued")},
           {QStringLiteral("queuePosition"), ++position}, {QStringLiteral("userMessageId"), QStringLiteral("message-") + text}});
    }
    world.waitFor([&] { return queued(world) == QStringList{c[1], c[2]}; }, [&] { return QStringLiteral("the queue; the turn is %1").arg(show(turn(world))); });
  });
  step(QStringLiteral("the provider stops %1 because its usage limit was reached").arg(q), [](World& world, const Captures& c, const Table&) {
    FakeStreams& fake = world.mc.part<FakeStreams>();
    world.mc.part<Orchestration>().commandsBefore = world.mc.commands.size();
    // The run fails as a usage limit, which holds the queue where it is.
    addItem(world, QStringLiteral("error"),
            {{QStringLiteral("status"), QStringLiteral("failed")},
             {QStringLiteral("failure"), QJsonObject{{QStringLiteral("class"), QStringLiteral("usage_limit")},
                                                     {QStringLiteral("message"), QStringLiteral("You've hit your usage limit.")}}}});
    settleRun(world, QStringLiteral("failed"), 5);
    for (auto it = fake.threads[fake.thread].cbegin(); it != fake.threads[fake.thread].cend(); ++it) {
      if (it->value(QLatin1String("status")) == QLatin1String("queued")) {
        set(world, QStringLiteral("run"), it->value(QLatin1String("id")).toString(), {{QStringLiteral("queueHeld"), true}});
      }
    }
    updateRow(world, c[0], {{QStringLiteral("activeRunId"), QJsonValue::Null}});
  });
  step(QStringLiteral("%1 and %1 stay queued in their original order").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(queued(world) == QStringList{c[0], c[1]} && !turn(world).value(QStringLiteral("running")).toBool(),
           QStringLiteral("the composer lists [%1]; the turn is %2").arg(queued(world).join(QStringLiteral(", ")), show(turn(world))));
  });
  step(QStringLiteral("neither is discarded or sent early"), [](World& world, const Captures&, const Table&) {
    world.sync();
    // The client asked nothing of the MC on its own: no cancel, no steer, no send.
    expect(world.mc.commands.size() == world.mc.part<Orchestration>().commandsBefore && queued(world).size() == 2,
           QStringLiteral("the client sent %1").arg(world.describeCommands()));
    expect(shows(timeline(world), QStringLiteral("You've hit your usage limit.")), QStringLiteral("the thread shows %1").arg(describe(timeline(world))));
  });

  // A plan Codex marked finished (providers/codex.feature).
  step(QStringLiteral("Codex proposed a plan and marked it finished"), [](World& world, const Captures&, const Table&) {
    const QString thread = QStringLiteral("thread-plan");
    openThread(world, thread, kProject);
    const QString run = beginRun(world, thread);
    updateRow(world, thread, {{QStringLiteral("interactionMode"), QStringLiteral("plan")}});
    const QString markdown = QStringLiteral("# Tax line\n\n- Add the line\n- Test it");
    // Codex's own plan item completed; the plan itself stays active until it is implemented.
    addItem(world, QStringLiteral("proposed_plan"),
            {{QStringLiteral("markdown"), markdown}, {QStringLiteral("planId"), QStringLiteral("plan-1")}, {QStringLiteral("status"), QStringLiteral("completed")},
             {QStringLiteral("streaming"), false}});
    set(world, QStringLiteral("plan"), QStringLiteral("plan-1"),
        {{QStringLiteral("id"), QStringLiteral("plan-1")}, {QStringLiteral("kind"), QStringLiteral("proposed_plan")}, {QStringLiteral("status"), QStringLiteral("active")},
         {QStringLiteral("runId"), run}, {QStringLiteral("markdown"), markdown}});
    settleRun(world, QStringLiteral("completed"), 30);
    updateRow(world, thread, {{QStringLiteral("activeRunId"), QJsonValue::Null}, {QStringLiteral("hasActionableProposedPlan"), true}});
  });
  step(QStringLiteral("the plan is offered for implementation"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return turn(world).value(QStringLiteral("plan")).isValid(); },
                  [&] { return QStringLiteral("the plan to be offered; the turn is %1").arg(show(turn(world))); });
  });
  step(QStringLiteral("the user implements the plan"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("composer.plan.implement"));
    world.sync();
  });
  step(QStringLiteral("a new run starts from that plan"), [](World& world, const Captures&, const Table&) {
    QJsonObject message;
    world.waitFor([&] {
      for (const QJsonObject& command : world.mc.commands) {
        if (command.value(QLatin1String("type")) == QLatin1String("message.dispatch")) message = command;
      }
      return !message.isEmpty();
    }, [&] { return QStringLiteral("the plan's message; the MC was sent %1").arg(world.describeCommands()); });
    expect(message.value(QLatin1String("threadId")) == QLatin1String("thread-plan") &&
               message.value(QLatin1String("sourcePlanRef")).toObject().value(QLatin1String("planId")) == QLatin1String("plan-1") &&
               message.value(QLatin1String("text")).toString().contains(QLatin1String("# Tax line")),
           QStringLiteral("the MC was sent %1").arg(world.describeCommands()));
  });
});

}  // namespace
