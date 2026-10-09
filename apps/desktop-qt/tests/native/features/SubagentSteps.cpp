// A thread and the subagents it started (features/timeline/plans-and-subagents.feature):
// moving between a subagent's thread and its parent, a message that came
// from another agent's thread, the model a subagent runs on, work a finished
// subagent left running, and a subagent's approval answered from its parent.
// The parent is Stream.h's thread-1 ("Tax line"); the MC's side is written as
// delegation.ex and the Claude adapter write it.

#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>
#include <QTest>

#include <memory>

#include "AgentsModel.h"
#include "Brick.h"
#include "Harness.h"
#include "NavigationController.h"
#include "RightPanelController.h"
#include "Stream.h"
#include "Turn.h"
#include "World.h"

namespace {

using namespace stream;

const QString kChild = QStringLiteral("thread-child");
const QString kChildTitle = QStringLiteral("Tax tests");
const QString kTask = QStringLiteral("task-1");

QString key(World& world, const QString& thread) {
  return world.mc.environmentId + QLatin1Char(':') + thread;
}

QString shownThread(World& world) {
  return world.native().controller<NavigationController>()->threadKey();
}

// The MC lists the subagent's thread under its parent.
void listChildThread(World& world) {
  world.mc.threads.insert(kChild, {{QStringLiteral("id"), kChild}, {QStringLiteral("title"), kChildTitle}, {QStringLiteral("projectId"), kProject},
                                   {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:30:00Z")}, {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:30:00Z")},
                                   {QStringLiteral("lineage"), QJsonObject{{QStringLiteral("rootThreadId"), kThread}, {QStringLiteral("parentThreadId"), kThread},
                                                                           {QStringLiteral("relationshipToParent"), QStringLiteral("subagent")}}}});
  world.mc.sendRow(kChild, world.mc.threads.value(kChild));
  world.sync();
}

// A subagent of the running turn: its entity and the item that shows it.
void delegate(World& world, const QJsonObject& fields = {}) {
  FakeStreams& fake = world.mc.part<FakeStreams>();
  QJsonObject entity{{QStringLiteral("id"), kTask}, {QStringLiteral("threadId"), fake.thread}, {QStringLiteral("runId"), fake.run}, {QStringLiteral("childThreadId"), kChild},
                     {QStringLiteral("prompt"), QStringLiteral("write the tax tests")}, {QStringLiteral("title"), kChildTitle}, {QStringLiteral("model"), QStringLiteral("gpt-5.5")},
                     {QStringLiteral("status"), QStringLiteral("running")}, {QStringLiteral("startedAt"), iso(now())}, {QStringLiteral("updatedAt"), iso(now())}};
  QJsonObject item{{QStringLiteral("id"), QStringLiteral("turn-item:subagent:") + kTask}, {QStringLiteral("subagentId"), kTask}, {QStringLiteral("origin"), QStringLiteral("app_owned")},
                   {QStringLiteral("childThreadId"), kChild}, {QStringLiteral("title"), kChildTitle}, {QStringLiteral("prompt"), QStringLiteral("write the tax tests")},
                   {QStringLiteral("result"), QJsonValue()}, {QStringLiteral("status"), QStringLiteral("running")}};
  for (auto it = fields.begin(); it != fields.end(); ++it) {
    entity.insert(it.key(), it.value());
    if (it.key() != QLatin1String("model")) item.insert(it.key(), it.value());
  }
  set(world, QStringLiteral("subagent"), kTask, entity);
  addItem(world, QStringLiteral("subagent"), item);
}

int rowOf(World& world, const QString& kind) {
  TimelineModel& model = timeline(world);
  for (int row = model.rowCount() - 1; row >= 0; --row) {
    if (role(model, row, TimelineModel::KindRole).toString() == kind) return row;
  }
  fail(QStringLiteral("no %1 row; %2").arg(kind, describe(model)));
}

// The open thread as the ThreadView brick draws it.
Brick& view(World& world) {
  if (!world.brick) world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nThreadView {}\n", QSize(820, 900));
  return *world.brick;
}

QQuickItem* drawn(World& world, const QString& name) {
  Brick& brick = view(world);
  QQuickItem* found = nullptr;
  const std::function<void(QQuickItem*)> find = [&](QQuickItem* item) {
    if (item->objectName() == name && item->isVisible()) found = item;
    for (QQuickItem* child : item->childItems()) find(child);
  };
  world.waitFor([&] {
    find(brick.window().contentItem());
    return found != nullptr;
  }, QStringLiteral("the thread to draw %1").arg(name));
  return found;
}

void click(World& world, const QString& name) {
  QQuickItem* item = drawn(world, name);
  QTest::mouseClick(&view(world).window(), Qt::LeftButton, Qt::NoModifier, view(world).at(item, 0.5, 0.5));
  world.sync();
}

AgentsModel& agents(World& world) {
  return *world.native().controller<RightPanelController>()->agents();
}

// A run the MC started for the agent itself: in place of a user's message its
// first item is the notification of what it was sent (orchestration.ex message_item).
void startNotifiedRun(World& world, const QJsonObject& notification) {
  FakeStreams& fake = world.mc.part<FakeStreams>();
  const QString run = QStringLiteral("run-%1").arg(fake.ordinal + 1);
  fake.run = run;
  fake.runStarted = now();
  set(world, QStringLiteral("run"), run,
      {{QStringLiteral("id"), run}, {QStringLiteral("ordinal"), ++fake.ordinal}, {QStringLiteral("status"), QStringLiteral("running")},
       {QStringLiteral("requestedAt"), iso(now())}, {QStringLiteral("startedAt"), iso(now())}});
  QJsonObject item{{QStringLiteral("id"), QStringLiteral("turn-item:user:message:") + run}, {QStringLiteral("type"), QStringLiteral("notification")},
                   {QStringLiteral("runId"), run}, {QStringLiteral("ordinal"), ++fake.ordinal}, {QStringLiteral("status"), QStringLiteral("completed")},
                   {QStringLiteral("updatedAt"), iso(now())}};
  for (auto it = notification.begin(); it != notification.end(); ++it) item.insert(it.key(), it.value());
  set(world, QStringLiteral("turn-item"), item.value(QLatin1String("id")).toString(), item);
  addItem(world, QStringLiteral("assistant_message"), {{QStringLiteral("text"), QStringLiteral("Noted.")}});
}

// Whether the thread draws an item of that name.
bool draws(World& world, const QString& name) {
  bool found = false;
  const std::function<void(QQuickItem*)> find = [&](QQuickItem* item) {
    found = found || (item->objectName() == name && item->isVisible());
    for (QQuickItem* child : item->childItems()) find(child);
  };
  find(view(world).window().contentItem());
  return found;
}

QJsonObject lastCommandOf(World& world, const QString& type) {
  QJsonObject found;
  for (const QJsonObject& command : std::as_const(world.mc.commands)) {
    if (command.value(QLatin1String("type")) == type) found = command;
  }
  return found;
}

const Steps steps([] {
  const QString q = kQuoted;

  // Between a subagent and its parent.
  step(QStringLiteral("the agent has a subagent"), [](World& world, const Captures&, const Table&) {
    listChildThread(world);
    startRun(world);
    delegate(world);
  });
  step(QStringLiteral("the user opens the subagent's thread"), [](World& world, const Captures&, const Table&) {
    // The subagent's row in the parent's timeline.
    click(world, QStringLiteral("subagentRow"));
    world.waitFor([&] { return shownThread(world) == key(world, kChild); },
                  [&] { return QStringLiteral("the subagent's thread to open; the window shows %1").arg(shownThread(world)); });
  });
  step(QStringLiteral("the thread says it is a subagent of the parent"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      return at(world.state(QStringLiteral("lineage")), QStringLiteral("parent.key")) == key(world, kThread) &&
             at(world.state(QStringLiteral("lineage")), QStringLiteral("parent.subagent")).toBool();
    }, [&] { return QStringLiteral("the thread's parent; its lineage is %1").arg(show(world.state(QStringLiteral("lineage")))); });
    world.waitFor([&] { return view(world).shows(QStringLiteral("Subagent of Tax line")); }, QStringLiteral("the thread to say where it came from"));
  });
  step(QStringLiteral("the user opens the parent thread"), [](World& world, const Captures&, const Table&) { click(world, QStringLiteral("lineageParent")); });
  step(QStringLiteral("the parent thread is shown"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return shownThread(world) == key(world, kThread) && store(world)->activeThread() == key(world, kThread); },
                  [&] { return QStringLiteral("the parent thread; the window shows %1").arg(shownThread(world)); });
    // Its own timeline, with the subagent's row and no line saying where it came from.
    expect(role(timeline(world), rowOf(world, QStringLiteral("subagent")), TimelineModel::TitleRole) == kChildTitle, describe(timeline(world)));
    world.waitFor([&] { return at(world.state(QStringLiteral("lineage")), QStringLiteral("parent")).isNull() && !view(world).shows(QStringLiteral("Subagent of Tax line")); },
                  QStringLiteral("the parent to say nothing of a parent"));
  });

  // A message from another agent.
  step(QStringLiteral("a subagent sent a message to its parent"), [](World& world, const Captures&, const Table&) {
    listChildThread(world);
    const QString run = startRun(world);
    // The MC records the sending thread on the message.
    set(world, QStringLiteral("turn-item"), QStringLiteral("message:") + run,
        {{QStringLiteral("text"), QStringLiteral("12 tests added")}, {QStringLiteral("createdBy"), QStringLiteral("agent")}, {QStringLiteral("senderThreadId"), kChild}});
  });
  step(QStringLiteral("the user reads the message in the parent thread"), [](World& world, const Captures&, const Table&) {
    expect(shownThread(world) == key(world, kThread), QStringLiteral("the window shows %1").arg(shownThread(world)));
    expect(role(timeline(world), rowOf(world, QStringLiteral("message")), TimelineModel::TextRole) == QLatin1String("12 tests added"), describe(timeline(world)));
  });
  step(QStringLiteral("it says which thread it came from"), [](World& world, const Captures&, const Table&) {
    const QString attribution = role(timeline(world), rowOf(world, QStringLiteral("message")), TimelineModel::AttributionRole).toString();
    expect(attribution == QLatin1String("From Tax tests"), QStringLiteral("the message says \"%1\"").arg(attribution));
    expect(drawn(world, QStringLiteral("messageAttribution"))->property("text") == QLatin1String("From Tax tests"), QStringLiteral("the message is not drawn with its sender"));
  });
  step(QStringLiteral("the user can open that thread"), [](World& world, const Captures&, const Table&) {
    click(world, QStringLiteral("messageAttribution"));
    world.waitFor([&] { return shownThread(world) == key(world, kChild); },
                  [&] { return QStringLiteral("the sender's thread to open; the window shows %1").arg(shownThread(world)); });
  });

  // What the MC sent the agent for itself.
  step(QStringLiteral("a task the agent delegated as %1 finished").arg(q), [](World& world, const Captures& c, const Table&) {
    listChildThread(world);
    startNotifiedRun(world, {{QStringLiteral("source"), QJsonObject{{QStringLiteral("kind"), QStringLiteral("delegated_task")}, {QStringLiteral("taskIds"), QJsonArray{kTask}}}},
                             {QStringLiteral("outcome"), QStringLiteral("completed")}, {QStringLiteral("summary"), c[0] + QStringLiteral(" finished")}});
  });
  step(QStringLiteral("a thread stored the failed result of the delegated task %1 as a user message").arg(q), [](World& world, const Captures& c, const Table&) {
    listChildThread(world);
    const QString run = startRun(world);
    // What delegation.ex sent before the MC recorded it as a notification.
    set(world, QStringLiteral("turn-item"), QStringLiteral("message:") + run,
        {{QStringLiteral("createdBy"), QStringLiteral("system")}, {QStringLiteral("creationSource"), QStringLiteral("server")}, {QStringLiteral("inputIntent"), QStringLiteral("queued_turn")},
         {QStringLiteral("text"), QStringLiteral("<delegated_task_result taskId=\"task:1\" title=\"%1\" status=\"failed\" childThreadId=\"%2\">\nThe tests do not build.\n</delegated_task_result>").arg(c[0], kChild)}});
    addItem(world, QStringLiteral("assistant_message"), {{QStringLiteral("text"), QStringLiteral("Noted.")}});
  });
  step(QStringLiteral("the agent's background work woke it up"), [](World& world, const Captures&, const Table&) {
    // claude/thread_runtime.ex wake.
    startNotifiedRun(world, {{QStringLiteral("source"), QJsonObject{{QStringLiteral("kind"), QStringLiteral("background_task")}}},
                             {QStringLiteral("outcome"), QStringLiteral("updated")}, {QStringLiteral("summary"), QStringLiteral("Background activity updated")}});
  });
  step(QStringLiteral("a thread stored the agent's own wake-up as a user message"), [](World& world, const Captures&, const Table&) {
    const QString run = startRun(world);
    set(world, QStringLiteral("turn-item"), QStringLiteral("message:") + run,
        {{QStringLiteral("createdBy"), QStringLiteral("agent")}, {QStringLiteral("creationSource"), QStringLiteral("provider")}, {QStringLiteral("text"), QStringLiteral("Background task completed.")}});
    addItem(world, QStringLiteral("assistant_message"), {{QStringLiteral("text"), QStringLiteral("Noted.")}});
  });
  step(QStringLiteral("the user reads the parent thread"), [](World& world, const Captures&, const Table&) {
    expect(shownThread(world) == key(world, kThread), QStringLiteral("the window shows %1").arg(shownThread(world)));
  });
  step(QStringLiteral("the timeline says %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const int row = rowOf(world, QStringLiteral("marker"));
    expect(role(timeline(world), row, TimelineModel::TitleRole) == c[0], describe(timeline(world)));
    expect(role(timeline(world), row, TimelineModel::TextRole).toString().isEmpty(), describe(timeline(world)));
    expect(drawn(world, QStringLiteral("markerTitle"))->property("text") == c[0], QStringLiteral("the row is not drawn as \"%1\"").arg(c[0]));
  });
  const auto noUserMessage = [](World& world) {
    TimelineModel& model = timeline(world);
    for (int row = 0; row < model.rowCount(); ++row) {
      expect(role(model, row, TimelineModel::KindRole) != QLatin1String("message") || role(model, row, TimelineModel::AuthorRole) != QLatin1String("user"), describe(model));
      expect(!role(model, row, TimelineModel::TextRole).toString().contains(QLatin1String("delegated_task_result")), describe(model));
      expect(role(model, row, TimelineModel::AttributionRole).toString().isEmpty(), describe(model));
    }
    // The agent's reply to it is there, so the thread is drawn.
    drawn(world, QStringLiteral("markerTitle"));
    expect(!draws(world, QStringLiteral("messageAttribution")), QStringLiteral("a message is drawn with a sender"));
  };
  step(QStringLiteral("the result is not shown as a message of the user's"), [noUserMessage](World& world, const Captures&, const Table&) { noUserMessage(world); });
  step(QStringLiteral("nothing says a message was sent by another agent"), [noUserMessage](World& world, const Captures&, const Table&) { noUserMessage(world); });

  // The model a subagent runs on.
  step(QStringLiteral("the agent delegated work to a subagent on the model %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QJsonObject& row = world.mc.threads[kThread];
    row.insert(QStringLiteral("modelSelection"), QJsonObject{{QStringLiteral("instanceId"), QStringLiteral("codex")}, {QStringLiteral("model"), QStringLiteral("gpt-5")}});
    world.mc.sendRow(kThread, row);
    world.sync();
    startRun(world);
    // The MC lists the task with the model it was delegated to (delegation.ex).
    delegate(world, {{QStringLiteral("model"), c[0]}});
  });
  step(QStringLiteral("the user looks at the parent's subagents"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("rightPanel.add"), QVariantMap{{QStringLiteral("kind"), QStringLiteral("agents")}});
    world.sync();
    world.waitFor([&] { return agents(world).agentCount() == 1; }, QStringLiteral("the Agents tab to list the subagent"));
  });
  step(QStringLiteral("the subagent is shown with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(role(timeline(world), rowOf(world, QStringLiteral("subagent")), TimelineModel::ModelRole) == c[0], describe(timeline(world)));
    const QString detail = drawn(world, QStringLiteral("subagentDetail"))->property("text").toString();
    expect(detail == c[0] + QStringLiteral(" · write the tax tests"), QStringLiteral("the subagent reads \"%1\"").arg(detail));
    expect(agents(world).value(0, AgentsModel::ModelRole) == c[0], QStringLiteral("the Agents tab names %1").arg(agents(world).value(0, AgentsModel::ModelRole).toString()));
  });
  step(QStringLiteral("the parent's model is not shown for it"), [](World& world, const Captures&, const Table&) {
    const QString parentModel = world.mc.threads.value(kThread).value(QLatin1String("modelSelection")).toObject().value(QLatin1String("model")).toString();
    expect(parentModel == QLatin1String("gpt-5"), QStringLiteral("the parent runs on %1").arg(parentModel));
    const QString detail = drawn(world, QStringLiteral("subagentDetail"))->property("text").toString();
    expect(!detail.contains(parentModel + QStringLiteral(" ·")) && agents(world).value(0, AgentsModel::ModelRole) != parentModel,
           QStringLiteral("the subagent reads \"%1\"").arg(detail));
  });

  // A finished subagent that left work running.
  step(QStringLiteral("a subagent returned its result while background work it started is still running"), [](World& world, const Captures&, const Table&) {
    startRun(world, 30);
    addItem(world, QStringLiteral("command_execution"), {{QStringLiteral("input"), QStringLiteral("npm run dev")}, {QStringLiteral("status"), QStringLiteral("running")}});
    delegate(world, {{QStringLiteral("status"), QStringLiteral("completed")}, {QStringLiteral("result"), QStringLiteral("Dev server started")}});
    addItem(world, QStringLiteral("assistant_message"), {{QStringLiteral("text"), QStringLiteral("The dev server is up.")}});
    // The turn is over; the command the subagent started is what is still pending.
    settleRun(world, QStringLiteral("completed"), 30);
    QJsonObject& row = world.mc.threads[kThread];
    row.insert(QStringLiteral("activeRunId"), QJsonValue());
    row.insert(QStringLiteral("pendingBackgroundTasks"),
               QJsonArray{QJsonObject{{QStringLiteral("taskType"), QStringLiteral("command_execution")}, {QStringLiteral("description"), QStringLiteral("npm run dev")}}});
    world.mc.sendRow(kThread, row);
    world.sync();
  });
  step(QStringLiteral("the user looks at the parent thread"), [](World& world, const Captures&, const Table&) {
    expect(shownThread(world) == key(world, kThread) && timeline(world).status() == QLatin1String("live"), QStringLiteral("the window shows %1").arg(shownThread(world)));
    view(world);
  });
  step(QStringLiteral("the subagent's result is shown"), [](World& world, const Captures&, const Table&) {
    TimelineModel& model = timeline(world);
    const int row = rowOf(world, QStringLiteral("subagent"));
    expect(role(model, row, TimelineModel::TextRole) == QLatin1String("Dev server started") && role(model, row, TimelineModel::StatusLabelRole) == QLatin1String("Completed"),
           describe(model));
    expect(drawn(world, QStringLiteral("subagentDetail"))->property("text").toString().endsWith(QLatin1String("Dev server started")), QStringLiteral("the result is not drawn"));
  });
  step(QStringLiteral("its background work is still shown as running"), [](World& world, const Captures&, const Table&) {
    // Out of the settled turn's fold, marked as running.
    TimelineModel& model = timeline(world);
    const QVariantList entries = role(model, rowOf(world, QStringLiteral("work")), TimelineModel::EntriesRole).toList();
    expect(entries.size() == 1 && entries.first().toMap().value(QStringLiteral("command")) == QLatin1String("npm run dev") &&
               entries.first().toMap().value(QStringLiteral("statusLabel")) == QLatin1String("Running"),
           describe(model));
    world.waitFor([&] { return view(world).shows(QStringLiteral("Running")); }, QStringLiteral("the running command to be drawn"));
    // And the Agents tab lists it beside the finished subagent.
    world.bridge().dispatch(QStringLiteral("rightPanel.add"), QVariantMap{{QStringLiteral("kind"), QStringLiteral("agents")}});
    world.sync();
    bool listed = false;
    for (int row = 0; row < agents(world).rowCount(); ++row) {
      listed = listed || (agents(world).value(row, AgentsModel::KindRole) == QLatin1String("command") && agents(world).value(row, AgentsModel::TitleRole) == QLatin1String("npm run dev") &&
                          agents(world).value(row, AgentsModel::RunningRole).toBool());
    }
    expect(listed, QStringLiteral("the Agents tab does not list the running command"));
  });

  // A subagent's approval, answered from the parent.
  step(QStringLiteral("a subagent asks for approval to run a command"), [](World& world, const Captures&, const Table&) {
    startWorkingTurn(world);
    delegate(world);
    // The request is the parent's: the subagent's own thread holds none.
    const QString request = QStringLiteral("request-subagent");
    set(world, QStringLiteral("runtime-request"), request,
        {{QStringLiteral("id"), request}, {QStringLiteral("status"), QStringLiteral("pending")}, {QStringLiteral("kind"), QStringLiteral("command")},
         {QStringLiteral("responseCapability"), QJsonObject{{QStringLiteral("type"), QStringLiteral("live")}}}});
    addItem(world, QStringLiteral("approval_request"), {{QStringLiteral("requestId"), request}, {QStringLiteral("status"), QStringLiteral("waiting")},
                                                        {QStringLiteral("requestKind"), QStringLiteral("command")}, {QStringLiteral("prompt"), QStringLiteral("npm test")}});
  });
  const auto approvals = [](World& world) { return world.state(QStringLiteral("turn")).toMap().value(QStringLiteral("approvals")).toList(); };
  step(QStringLiteral("the approval is listed there"), [approvals](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return approvals(world).size() == 1; }, [&] { return QStringLiteral("the approval; the turn is %1").arg(show(world.state(QStringLiteral("turn")))); });
    const QVariantMap approval = approvals(world).first().toMap();
    expect(approval.value(QStringLiteral("requestId")) == QLatin1String("request-subagent") && approval.value(QStringLiteral("detail")) == QLatin1String("npm test") &&
               approval.value(QStringLiteral("canRespond")).toBool(),
           QStringLiteral("the approval is %1").arg(show(approval)));
    // Beside the subagent that asked, still working.
    expect(role(timeline(world), rowOf(world, QStringLiteral("subagent")), TimelineModel::StatusLabelRole) == QLatin1String("Working"), describe(timeline(world)));
  });
  step(QStringLiteral("the user answers it"), [approvals](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("composer.approval.respond"),
                            QVariantMap{{QStringLiteral("requestId"), approvals(world).first().toMap().value(QStringLiteral("requestId"))}, {QStringLiteral("decision"), QStringLiteral("accept")}});
    world.sync();
  });
  step(QStringLiteral("the subagent continues with the answer"), [approvals](World& world, const Captures&, const Table&) {
    const QJsonObject answer = lastCommandOf(world, QStringLiteral("runtime-request.respond"));
    expect(answer.value(QLatin1String("threadId")) == kThread && answer.value(QLatin1String("requestId")) == QLatin1String("request-subagent") &&
               answer.value(QLatin1String("decision")) == QLatin1String("accept"),
           QStringLiteral("the MC was told %1; it has %2").arg(show(answer.toVariantMap()), world.describeCommands()));
    // What the MC makes of it: the request is resolved and the subagent finishes.
    set(world, QStringLiteral("runtime-request"), QStringLiteral("request-subagent"), {{QStringLiteral("status"), QStringLiteral("resolved")}, {QStringLiteral("decision"), QStringLiteral("accept")}});
    set(world, QStringLiteral("turn-item"), QStringLiteral("turn-item:subagent:") + kTask, {{QStringLiteral("status"), QStringLiteral("completed")}, {QStringLiteral("result"), QStringLiteral("ran npm test")}});
    world.waitFor([&] { return approvals(world).isEmpty(); }, [&] { return QStringLiteral("the approval to close; the turn is %1").arg(show(world.state(QStringLiteral("turn")))); });
    expect(role(timeline(world), rowOf(world, QStringLiteral("subagent")), TimelineModel::TextRole) == QLatin1String("ran npm test"), describe(timeline(world)));
  });
});

}  // namespace
