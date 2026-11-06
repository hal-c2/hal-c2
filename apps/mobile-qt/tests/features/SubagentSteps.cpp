// Plans and subagents on the phone (features/timeline/plans-and-subagents.feature):
// a proposed plan's card and what the user does with it from the composer's
// plan card (TurnRequests), a subagent's row in its parent's timeline and the
// way between the two threads, what the MC sent the agent for itself, and the
// subagents of the turn above the composer. The thread is StreamingSteps'
// "Tax line" (the Background's), its stream FakeThreads'; the timeline is the
// desktop's TimelineModel and Timeline brick, so these read the model as the
// desktop harness's SubagentSteps.cpp does and tap what the phone draws.

#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>
#include <QQuickWindow>
#include <QTest>
#include <QTimeZone>

#include <algorithm>
#include <functional>

#include "FakeThreads.h"
#include "Harness.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "Phone.h"
#include "PlanController.h"
#include "ThreadStore.h"
#include "TimelineModel.h"
#include "World.h"

namespace {

using S = QString;

const QString kChild = S("thread-child");
const QString kChildTitle = S("Tax tests");
const QString kTask = S("task-1");
const QString kPlan = S("# Tax line\n\n- Add the line\n- Test it");

// The scenarios' clock, StreamingSteps': 2026-09-23 10:00, UTC.
QDateTime now() {
  return QDateTime(QDate(2026, 9, 23), QTime(10, 0), QTimeZone::UTC);
}

QString iso(const QDateTime& time) {
  return time.toUTC().toString(Qt::ISODateWithMs);
}

ThreadStore* store(World& world) {
  return world.native().controller<ThreadStore>();
}

TimelineModel& timeline(World& world) {
  TimelineModel* model = store(world)->activeTimeline();
  if (!model) fail(S("no thread is open"));
  return *model;
}

QVariant role(TimelineModel& model, int row, int role) {
  return model.data(model.index(row), role);
}

QString describe(TimelineModel& model) {
  QStringList rows;
  const QHash<int, QByteArray> names = model.roleNames();
  for (int row = 0; row < model.rowCount(); ++row) {
    QVariantMap shown;
    for (const int key : {int(TimelineModel::KindRole), int(TimelineModel::IdRole), int(TimelineModel::TitleRole), int(TimelineModel::TextRole),
                          int(TimelineModel::StatusLabelRole), int(TimelineModel::ExpandedRole)}) {
      const QVariant value = role(model, row, key);
      if (value.isValid() && !value.toString().isEmpty() && value != QVariant(false)) shown.insert(QString::fromUtf8(names.value(key)), value);
    }
    rows.append(show(shown));
  }
  return S("status %1, rows: %2").arg(model.status(), rows.isEmpty() ? S("(none)") : rows.join(S("; ")));
}

QList<int> rowsOf(TimelineModel& model, const QString& kind) {
  QList<int> rows;
  for (int row = 0; row < model.rowCount(); ++row) {
    if (role(model, row, TimelineModel::KindRole).toString() == kind) rows.append(row);
  }
  return rows;
}

// The last row of `kind`, waited for.
int rowOf(World& world, const QString& kind) {
  world.waitFor([&] { return !rowsOf(timeline(world), kind).isEmpty(); }, [&] { return S("a %1 row; %2").arg(kind, describe(timeline(world))); });
  return rowsOf(timeline(world), kind).last();
}

QString key(World& world, const QString& thread) {
  return world.mc.environmentId + QLatin1Char(':') + thread;
}

QString openKey(World& world) {
  return world.native().controller<NavigationController>()->threadKey();
}

// --- The parent's stream -----------------------------------------------------

// The background tool call the open scenario started.
QString backgroundTool;

void set(World& world, const QString& kind, const QString& id, const QJsonObject& fields) {
  changeEntity(world.mc, world.thread, kind, id, {{S("s"), fields}});
  world.sync();
}

// A run of the open thread started `since` seconds ago, with the user's
// message that asked for it.
QString startRun(World& world, int since = 0) {
  FakeStreams& fake = world.mc.part<FakeStreams>();
  const QString run = S("run-%1").arg(fake.ordinal + 1);
  world.run = run;
  set(world, S("run"), run,
      {{S("id"), run}, {S("ordinal"), ++fake.ordinal}, {S("status"), S("running")}, {S("requestedAt"), iso(now().addSecs(-since))},
       {S("startedAt"), iso(now().addSecs(-since))}});
  set(world, S("turn-item"), S("message:") + run,
      {{S("id"), S("message:") + run}, {S("type"), S("user_message")}, {S("runId"), run}, {S("ordinal"), ++fake.ordinal},
       {S("status"), S("completed")}, {S("text"), S("Add a tax line to the cart")}, {S("updatedAt"), iso(now().addSecs(-since))}});
  updateRow(world.mc, world.thread, {{S("activeRunId"), run}});
  world.sync();
  return run;
}

QString addItem(World& world, const QString& type, const QJsonObject& fields = {}) {
  FakeStreams& fake = world.mc.part<FakeStreams>();
  QJsonObject item{{S("id"), S("%1:%2").arg(type).arg(fake.ordinal + 1)}, {S("type"), type}, {S("runId"), world.run},
                   {S("ordinal"), ++fake.ordinal}, {S("status"), S("completed")}, {S("updatedAt"), iso(now())}};
  for (auto it = fields.begin(); it != fields.end(); ++it) item.insert(it.key(), it.value());
  const QString id = item.value(QLatin1String("id")).toString();
  set(world, S("turn-item"), id, item);
  return id;
}

// The run is over.
void settleRun(World& world, const QString& status = S("completed")) {
  set(world, S("run"), world.run, {{S("status"), status}, {S("completedAt"), iso(now())}});
  updateRow(world.mc, world.thread, {{S("activeRunId"), QJsonValue::Null}});
  world.sync();
}

// --- What the phone draws ----------------------------------------------------

// The visible item named `name`, scrolled into the timeline's view when it is
// in it, once the list has stopped moving: a tap on a list in motion only stops it.
QQuickItem* shown(World& world, const QString& name) {
  QQuickItem* target = world.item(name);
  QQuickItem* rows = world.find(S("timelineRows"));
  if (rows && rows->isAncestorOf(target)) {
    world.window().grabWindow();
    const qreal top = target->mapToItem(rows, QPointF(0, 0)).y();
    if (top < 0 || top + target->height() > rows->height()) {
      const qreal contentY = rows->property("contentY").toReal() + top - rows->height() / 2;
      const qreal lowest = rows->property("originY").toReal() + rows->property("contentHeight").toReal() - rows->height();
      rows->setProperty("contentY", std::max(rows->property("originY").toReal(), std::min(contentY, lowest)));
    }
    world.waitFor([&] { return !rows->property("moving").toBool(); }, S("the timeline to stop scrolling"));
    target = world.item(name);
  }
  return target;
}

void tap(World& world, const QString& name) {
  world.tap(shown(world, name));
  world.sync();
}

void expectOpen(World& world, const QString& thread, const QString& what) {
  world.waitFor([&] { return openKey(world) == key(world, thread) && store(world)->activeThread() == key(world, thread); },
                [&] { return S("%1 to open; the phone shows %2").arg(what, openKey(world)); });
}

// --- Subagents ---------------------------------------------------------------

// The MC lists the subagent's thread under its parent.
void listChildThread(World& world) {
  world.mc.threads.insert(kChild, {{S("id"), kChild}, {S("title"), kChildTitle}, {S("projectId"), S("shop")},
                                   {S("createdAt"), S("2026-09-23T09:30:00Z")}, {S("updatedAt"), S("2026-09-23T09:30:00Z")},
                                   {S("lineage"), QJsonObject{{S("rootThreadId"), world.thread}, {S("parentThreadId"), world.thread},
                                                               {S("relationshipToParent"), S("subagent")}}}});
  world.mc.sendRow(kChild, world.mc.threads.value(kChild));
  world.sync();
}

// A subagent of the running turn: its entity and the item that shows it.
void delegate(World& world, const QJsonObject& fields = {}) {
  QJsonObject entity{{S("id"), kTask}, {S("threadId"), world.thread}, {S("runId"), world.run}, {S("childThreadId"), kChild},
                     {S("prompt"), S("write the tax tests")}, {S("title"), kChildTitle}, {S("model"), S("gpt-5.5")},
                     {S("status"), S("running")}, {S("startedAt"), iso(now())}, {S("updatedAt"), iso(now())}};
  QJsonObject item{{S("id"), S("turn-item:subagent:") + kTask}, {S("subagentId"), kTask}, {S("origin"), S("app_owned")},
                   {S("childThreadId"), kChild}, {S("title"), kChildTitle}, {S("prompt"), S("write the tax tests")},
                   {S("result"), QJsonValue()}, {S("status"), S("running")}};
  for (auto it = fields.begin(); it != fields.end(); ++it) {
    entity.insert(it.key(), it.value());
    if (it.key() != QLatin1String("model")) item.insert(it.key(), it.value());
  }
  set(world, S("subagent"), kTask, entity);
  addItem(world, S("subagent"), item);
}

// A run the MC started for the agent itself: in place of a user's message its
// first item is the notification of what it was sent (orchestration.ex message_item).
void startNotifiedRun(World& world, const QJsonObject& notification) {
  FakeStreams& fake = world.mc.part<FakeStreams>();
  const QString run = S("run-%1").arg(fake.ordinal + 1);
  world.run = run;
  set(world, S("run"), run,
      {{S("id"), run}, {S("ordinal"), ++fake.ordinal}, {S("status"), S("running")}, {S("requestedAt"), iso(now())}, {S("startedAt"), iso(now())}});
  QJsonObject item{{S("id"), S("turn-item:user:message:") + run}, {S("type"), S("notification")}, {S("runId"), run},
                   {S("ordinal"), ++fake.ordinal}, {S("status"), S("completed")}, {S("updatedAt"), iso(now())}};
  for (auto it = notification.begin(); it != notification.end(); ++it) item.insert(it.key(), it.value());
  set(world, S("turn-item"), item.value(QLatin1String("id")).toString(), item);
  addItem(world, S("assistant_message"), {{S("text"), S("Noted.")}});
}

QJsonObject lastCommandOf(World& world, const QString& type) {
  world.sync();
  QJsonObject found;
  for (const QJsonObject& command : std::as_const(world.mc.commands)) {
    if (command.value(QLatin1String("type")) == type) found = command;
  }
  return found;
}

QList<QJsonObject> commandsOf(World& world, const QString& type) {
  world.sync();
  QList<QJsonObject> found;
  for (const QJsonObject& command : std::as_const(world.mc.commands)) {
    if (command.value(QLatin1String("type")) == type) found.append(command);
  }
  return found;
}

QString describeCommands(World& world) {
  QStringList lines;
  for (const QJsonObject& command : std::as_const(world.mc.commands)) lines.append(show(command.toVariantMap()));
  return lines.isEmpty() ? S("(none)") : lines.join(S("; "));
}

// --- Plans -------------------------------------------------------------------

// What the MC's `projects.writeFile` was asked to write.
struct FakeWrites {
  QList<QJsonObject> files;
};

QVariantMap turnState(World& world) {
  return world.state(S("turn")).toMap();
}

// A proposed plan in a settled run of the thread in plan mode.
void proposePlan(World& world) {
  startRun(world, 30);
  updateRow(world.mc, world.thread, {{S("interactionMode"), S("plan")}});
  addItem(world, S("proposed_plan"), {{S("markdown"), kPlan}, {S("planId"), S("plan-1")}});
  set(world, S("plan"), S("plan-1"),
      {{S("id"), S("plan-1")}, {S("kind"), S("proposed_plan")}, {S("status"), S("active")}, {S("runId"), world.run}, {S("markdown"), kPlan}});
  settleRun(world);
  world.waitFor([&] { return turnState(world).value(S("plan")).isValid(); },
                [&] { return S("the plan to be offered; the turn is %1").arg(show(turnState(world))); });
}

QString downloads(World& world) {
  return QDir(world.homeDir()).filePath(S("downloads"));
}

// An entry of the plan card's menu, over the composer.
void choose(World& world, const QString& entry) {
  world.native().controller<PlanController>()->setDownloadDirectory(downloads(world));
  world.mc.onRpc(S("projects.writeFile"), [&mc = world.mc](const FakeMc::Rpc& rpc) {
    mc.part<FakeWrites>().files.append(rpc.payload);
    mc.reply(rpc, QJsonObject{{S("relativePath"), rpc.payload.value(QLatin1String("relativePath"))}});
  });
  world.tap(S("planMore"));
  world.tap(S(entry));
  world.sync();
}

// Saves to `path`, typed over the file name the dialog starts from. Without a
// workspace the menu only says so, and no dialog opens.
void saveTo(World& world, const QString& path) {
  choose(world, S("planSave"));
  if (turnState(world).value(S("plan")).toMap().value(S("workspaceRoot")).toString().isEmpty()) return;
  world.tap(S("planSavePath"));
  QTest::keyClick(&world.window(), Qt::Key_A, Qt::ControlModifier);
  world.type(path);
  world.tap(S("planSaveConfirm"));
  world.sync();
}

QList<QJsonObject> launches(World& world) {
  QList<QJsonObject> found;
  for (const FakeMc::Rpc& rpc : std::as_const(world.mc.calls)) {
    if (rpc.method == QLatin1String("orchestration.launchThread")) found.append(rpc.payload);
  }
  return found;
}

const Steps steps([] {
  const QString q = kQuoted;

  // A plan's card in the timeline.
  step(S("the agent proposes a plan whose first heading is %1").arg(q), [](World& world, const Captures& c, const Table&) {
    startRun(world);
    addItem(world, S("proposed_plan"), {{S("markdown"), S("Here is the plan.\n\n## %1\n\n- Add the line\n- Test it").arg(c[0])}});
  });
  step(S("the agent proposes a plan that opens with the heading %1").arg(q), [](World& world, const Captures& c, const Table&) {
    startRun(world);
    addItem(world, S("proposed_plan"), {{S("markdown"), S("# %1\n\n## Summary\n\n- Add the line\n- Test it").arg(c[0])}});
  });
  step(S("the plan card is titled %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString title = role(timeline(world), rowOf(world, S("plan")), TimelineModel::TitleRole).toString();
    expect(title == c[0], S("the plan card is titled \"%1\"").arg(title));
    world.waitFor([&] { return world.shows(c[0]); }, [&] { return S("the plan card on screen; the screen says: %1").arg(world.texts().join(S(" | "))); });
  });
  step(S("a plan without a heading is titled %1").arg(q), [](World& world, const Captures& c, const Table&) {
    addItem(world, S("proposed_plan"), {{S("markdown"), S("Add the line, then test it.")}});
    const QString title = role(timeline(world), rowOf(world, S("plan")), TimelineModel::TitleRole).toString();
    expect(title == c[0], S("the plan card is titled \"%1\"").arg(title));
  });
  step(S("the plan's text starts with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString body = role(timeline(world), rowOf(world, S("plan")), TimelineModel::TextRole).toString();
    expect(body.startsWith(c[0]), S("the plan's text reads \"%1\"").arg(body));
  });

  // Implementing or refining it from the composer.
  step(S("the agent has proposed a plan"), [](World& world, const Captures&, const Table&) { proposePlan(world); });
  step(S("the user implements the plan with no feedback"), [](World& world, const Captures&, const Table&) {
    world.tap(S("planImplement"));
    world.sync();
  });
  step(S("the agent starts implementing it in this thread"), [](World& world, const Captures&, const Table&) {
    QJsonObject message;
    world.waitFor([&] { return !(message = lastCommandOf(world, S("message.dispatch"))).isEmpty(); },
                  [&] { return S("the plan's message; the MC has %1").arg(describeCommands(world)); });
    expect(message.value(QLatin1String("threadId")) == world.thread &&
               message.value(QLatin1String("text")).toString().startsWith(QLatin1String("PLEASE IMPLEMENT THIS PLAN:\n# Tax line")) &&
               message.value(QLatin1String("sourcePlanRef")).toObject().value(QLatin1String("planId")) == QLatin1String("plan-1"),
           S("the MC was sent %1").arg(show(message.toVariantMap())));
    const QJsonObject mode = lastCommandOf(world, S("thread.interaction-mode.set"));
    expect(mode.value(QLatin1String("interactionMode")) == QLatin1String("default"), S("the thread was set to %1").arg(show(mode.toVariantMap())));
  });
  step(S("the plan card is no longer offered"), [](World& world, const Captures&, const Table&) {
    // What the MC does with the message's sourcePlanRef.
    set(world, S("plan"), S("plan-1"), {{S("status"), S("completed")}});
    world.waitFor([&] { return !turnState(world).value(S("plan")).isValid() && world.find(S("planImplement")) == nullptr; },
                  [&] { return S("the plan to go; the turn is %1").arg(show(turnState(world))); });
  });
  step(S("the user sends %1 as feedback").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* input = world.item(S("input"));
    world.tap(input);
    world.type(c[0]);
    world.tap(S("primaryAction"));
    world.sync();
  });
  step(S("the agent revises the plan"), [](World& world, const Captures&, const Table&) {
    QJsonObject message;
    world.waitFor([&] { return !(message = lastCommandOf(world, S("message.dispatch"))).isEmpty(); },
                  [&] { return S("the feedback; the MC has %1").arg(describeCommands(world)); });
    expect(message.value(QLatin1String("text")) == QLatin1String("split the migration into its own step") && !message.contains(QLatin1String("sourcePlanRef")),
           S("the MC was sent %1").arg(show(message.toVariantMap())));
  });
  step(S("the thread stays in plan mode"), [](World& world, const Captures&, const Table&) {
    for (const QJsonObject& mode : commandsOf(world, S("thread.interaction-mode.set"))) {
      expect(mode.value(QLatin1String("interactionMode")) == QLatin1String("plan"), S("the thread was set to %1").arg(show(mode.toVariantMap())));
    }
  });

  // In a new thread.
  step(S("the user implements the plan in a new thread"), [](World& world, const Captures&, const Table&) { choose(world, S("planNewThread")); });
  step(S("a new thread starts implementing the plan"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return launches(world).size() == 1; }, [&] { return S("one new thread; the MC was asked for %1").arg(launches(world).size()); });
    const QJsonObject launch = launches(world).first();
    const QString threadId = launch.value(QLatin1String("threadId")).toString();
    expect(!threadId.isEmpty() && threadId != world.thread && launch.value(QLatin1String("projectId")) == QLatin1String("shop") &&
               launch.value(QLatin1String("title")) == QLatin1String("Implement Tax line") && launch.value(QLatin1String("interactionMode")) == QLatin1String("default"),
           S("the MC was asked to start %1").arg(show(launch.toVariantMap())));
    QJsonObject message;
    world.waitFor([&] { return !(message = lastCommandOf(world, S("message.dispatch"))).isEmpty(); },
                  [&] { return S("the thread's first message; the MC has %1").arg(describeCommands(world)); });
    const QJsonObject ref = message.value(QLatin1String("sourcePlanRef")).toObject();
    expect(message.value(QLatin1String("threadId")) == threadId && message.value(QLatin1String("text")).toString() == S("PLEASE IMPLEMENT THIS PLAN:\n") + kPlan &&
               ref.value(QLatin1String("threadId")) == world.thread && ref.value(QLatin1String("planId")) == QLatin1String("plan-1"),
           S("the MC was sent %1").arg(show(message.toVariantMap())));
    expectOpen(world, threadId, S("the new thread"));
  });
  step(S("the planning thread keeps the plan"), [](World& world, const Captures&, const Table&) {
    TimelineModel* planning = store(world)->timeline(key(world, world.thread));
    expect(planning != nullptr, S("the planning thread is gone"));
    bool card = false;
    for (int row = 0; row < planning->rowCount(); ++row) {
      card = card || (role(*planning, row, TimelineModel::KindRole) == QLatin1String("plan") && role(*planning, row, TimelineModel::TitleRole) == QLatin1String("Tax line"));
    }
    expect(card, S("the planning thread shows %1").arg(describe(*planning)));
    for (const QJsonObject& command : std::as_const(world.mc.commands)) {
      expect(command.value(QLatin1String("threadId")) != world.thread, S("the planning thread was sent %1").arg(show(command.toVariantMap())));
    }
  });
  step(S("the environment cannot start a new thread"), [](World& world, const Captures&, const Table&) {
    world.mc.refusals.insert(S("orchestration.launchThread"), S("Provider unavailable"));
  });
  // "the user is told %1" checks the toast (UpdateSteps.cpp).

  // A copy of it.
  step(S("the user copies the plan"), [](World& world, const Captures&, const Table&) { choose(world, S("planCopy")); });
  step(S("the plan's markdown is on the clipboard"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.clipboard == kPlan + QLatin1Char('\n'); }, [&] { return S("the plan on the clipboard; it holds \"%1\"").arg(world.clipboard); });
  });
  step(S("the user downloads the plan"), [](World& world, const Captures&, const Table&) { choose(world, S("planDownload")); });
  step(S("a markdown file of the plan is saved"), [](World& world, const Captures&, const Table&) {
    QFile file(QDir(downloads(world)).filePath(S("tax-line.md")));
    world.waitFor([&] { return file.exists(); }, [&] { return S("%1; the downloads are %2").arg(file.fileName(), QDir(downloads(world)).entryList(QDir::Files).join(u", ")); });
    expect(file.open(QIODevice::ReadOnly), S("%1 cannot be read").arg(file.fileName()));
    const QString written = QString::fromUtf8(file.readAll());
    expect(written == kPlan + QLatin1Char('\n'), S("the file holds \"%1\"").arg(written));
  });
  step(S("the user saves the plan to %1").arg(q), [](World& world, const Captures& c, const Table&) { saveTo(world, c[0]); });
  step(S("%1 holds the plan in the workspace").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return !world.mc.part<FakeWrites>().files.isEmpty(); }, S("the MC to be asked to write the plan"));
    const QList<QJsonObject> files = world.mc.part<FakeWrites>().files;
    expect(files.size() == 1 && files.first().value(QLatin1String("cwd")) == QLatin1String("/work/shop") &&
               files.first().value(QLatin1String("relativePath")) == c[0] && files.first().value(QLatin1String("contents")) == kPlan + QLatin1Char('\n'),
           S("the MC was asked to write %1").arg(show(files.first().toVariantMap())));
  });
  step(S("the thread's workspace is unavailable"), [](World& world, const Captures&, const Table&) {
    QJsonObject project = world.mc.projects.value(S("shop"));
    project.remove(S("workspaceRoot"));
    world.mc.projects.insert(S("shop"), project);
    world.mc.sendRow(S("shop"), QJsonObject{{S("id"), S("shop")}, {S("title"), S("shop")}, {S("scripts"), QJsonArray()}, {S("workspaceRoot"), QJsonValue()}},
                     S("project"));
    world.sync();
  });
  step(S("the user saves the plan to the workspace"), [](World& world, const Captures&, const Table&) {
    saveTo(world, S("docs/tax-plan.md"));
    expect(world.mc.part<FakeWrites>().files.isEmpty(), S("the MC was asked to write a file"));
  });

  // A subagent's row.
  step(S("the agent has a subagent that is (running|waiting on a request|idle and resumable|completed|failed|cancelled)"),
       [](World& world, const Captures& c, const Table&) {
         const QHash<QString, QString> statuses{{S("running"), S("running")},     {S("waiting on a request"), S("waiting")}, {S("idle and resumable"), S("idle")},
                                                {S("completed"), S("completed")}, {S("failed"), S("failed")},             {S("cancelled"), S("cancelled")}};
         startRun(world);
         addItem(world, S("subagent"), {{S("status"), statuses.value(c[0])}, {S("title"), kChildTitle}, {S("prompt"), S("write the tax tests")},
                                         {S("childThreadId"), kChild}});
       });
  step(S("the subagent is shown as %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString label = role(timeline(world), rowOf(world, S("subagent")), TimelineModel::StatusLabelRole).toString();
    expect(label == c[0], S("the subagent is shown as \"%1\"").arg(label));
    world.item(S("subagentRow"));
  });
  step(S("a subagent that reported %1 and then finished with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    startRun(world, 30);
    delegate(world, {{S("progress"), c[0]}, {S("status"), S("completed")}, {S("result"), c[1]}});
  });
  step(S("a subagent that is still working after reporting %1").arg(q), [](World& world, const Captures& c, const Table&) {
    startRun(world, 30);
    delegate(world, {{S("progress"), c[0]}, {S("result"), S("Earlier result")}});
  });
  step(S("the subagent's row reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString text = role(timeline(world), rowOf(world, S("subagent")), TimelineModel::TextRole).toString();
    expect(text == c[0], S("the row reads \"%1\"").arg(text));
    world.waitFor([&] { return world.item(S("subagentDetail"))->property("text").toString().endsWith(c[0]); },
                  [&] { return S("the row to read \"%1\"; it reads \"%2\"").arg(c[0], world.item(S("subagentDetail"))->property("text").toString()); });
  });

  // Between a subagent and its parent.
  step(S("the agent has a subagent"), [](World& world, const Captures&, const Table&) {
    listChildThread(world);
    startRun(world);
    delegate(world);
  });
  step(S("the user opens the subagent's thread"), [](World& world, const Captures&, const Table&) {
    tap(world, S("subagentRow"));
    expectOpen(world, kChild, S("the subagent's thread"));
  });
  step(S("the thread says it is a subagent of the parent"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      return at(world.state(S("lineage")), S("parent.key")) == key(world, world.thread) && at(world.state(S("lineage")), S("parent.subagent")).toBool();
    }, [&] { return S("the thread's parent; its lineage is %1").arg(show(world.state(S("lineage")))); });
    world.waitFor([&] { return world.shows(S("Subagent of Tax line")); }, [&] { return S("the thread to say where it came from; the screen says: %1").arg(world.texts().join(S(" | "))); });
  });
  step(S("the user opens the parent thread"), [](World& world, const Captures&, const Table&) { tap(world, S("lineageParent")); });
  step(S("the parent thread is shown"), [](World& world, const Captures&, const Table&) {
    expectOpen(world, world.thread, S("the parent thread"));
    expect(role(timeline(world), rowOf(world, S("subagent")), TimelineModel::TitleRole) == kChildTitle, describe(timeline(world)));
    world.waitFor([&] { return at(world.state(S("lineage")), S("parent")).isNull() && !world.shows(S("Subagent of Tax line")); },
                  S("the parent to say nothing of a parent"));
  });

  // A message from another agent.
  step(S("a subagent sent a message to its parent"), [](World& world, const Captures&, const Table&) {
    listChildThread(world);
    const QString run = startRun(world);
    // The MC records the sending thread on the message.
    set(world, S("turn-item"), S("message:") + run, {{S("text"), S("12 tests added")}, {S("createdBy"), S("agent")}, {S("senderThreadId"), kChild}});
  });
  step(S("the user reads the message in the parent thread"), [](World& world, const Captures&, const Table&) {
    expectOpen(world, world.thread, S("the parent thread"));
    expect(role(timeline(world), rowOf(world, S("message")), TimelineModel::TextRole) == QLatin1String("12 tests added"), describe(timeline(world)));
  });
  step(S("it says which thread it came from"), [](World& world, const Captures&, const Table&) {
    const QString attribution = role(timeline(world), rowOf(world, S("message")), TimelineModel::AttributionRole).toString();
    expect(attribution == QLatin1String("From Tax tests"), S("the message says \"%1\"").arg(attribution));
    expect(shown(world, S("messageAttribution"))->property("text") == QLatin1String("From Tax tests"), S("the message is not drawn with its sender"));
  });
  step(S("the user can open that thread"), [](World& world, const Captures&, const Table&) {
    tap(world, S("messageAttribution"));
    expectOpen(world, kChild, S("the sender's thread"));
  });

  // What the MC sent the agent for itself.
  step(S("a task the agent delegated as %1 finished").arg(q), [](World& world, const Captures& c, const Table&) {
    listChildThread(world);
    startNotifiedRun(world, {{S("source"), QJsonObject{{S("kind"), S("delegated_task")}, {S("taskIds"), QJsonArray{kTask}}}},
                             {S("outcome"), S("completed")}, {S("summary"), c[0] + S(" finished")}});
  });
  step(S("a task the agent delegated as %1 finished with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    listChildThread(world);
    startNotifiedRun(world, {{S("source"), QJsonObject{{S("kind"), S("delegated_task")}, {S("taskIds"), QJsonArray{kTask}}}},
                             {S("outcome"), S("completed")}, {S("summary"), c[0] + S(" finished")},
                             {S("workerThreadId"), kChild}, {S("workerTitle"), c[0]}, {S("detail"), c[1]}});
  });
  step(S("the worker's notification reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(role(timeline(world), rowOf(world, S("marker")), TimelineModel::TitleRole) == c[0], describe(timeline(world)));
    expect(shown(world, S("workerResultTitle"))->property("text") == c[0], S("the notification is not drawn as a card for \"%1\"").arg(c[0]));
    expect(world.find(S("markerTitle")) == nullptr, S("the notification is drawn as a plain divider"));
    expect(world.find(S("messageAttribution")) == nullptr, S("the notification is drawn as someone's message"));
  });
  step(S("the notification links to the worker's thread"), [](World& world, const Captures&, const Table&) {
    expect(role(timeline(world), rowOf(world, S("marker")), TimelineModel::ThreadRole) == kChild, describe(timeline(world)));
    tap(world, S("workerResultTitle"));
    expectOpen(world, kChild, S("the worker's thread"));
  });
  step(S("a thread stored the failed result of the delegated task %1 as a user message").arg(q), [](World& world, const Captures& c, const Table&) {
    listChildThread(world);
    const QString run = startRun(world);
    // What delegation.ex sent before the MC recorded it as a notification.
    set(world, S("turn-item"), S("message:") + run,
        {{S("createdBy"), S("system")}, {S("creationSource"), S("server")}, {S("inputIntent"), S("queued_turn")},
         {S("text"), S("<delegated_task_result taskId=\"task:1\" title=\"%1\" status=\"failed\" childThreadId=\"%2\">\nThe tests do not build.\n</delegated_task_result>").arg(c[0], kChild)}});
    addItem(world, S("assistant_message"), {{S("text"), S("Noted.")}});
  });
  step(S("the agent's background work woke it up"), [](World& world, const Captures&, const Table&) {
    startNotifiedRun(world, {{S("source"), QJsonObject{{S("kind"), S("background_task")}}}, {S("outcome"), S("updated")}, {S("summary"), S("Background activity updated")}});
  });
  step(S("a pull request the thread owns woke its agent because its checks failed"), [](World& world, const Captures&, const Table&) {
    startNotifiedRun(world, {{S("source"), QJsonObject{{S("kind"), S("pull_request")}, {S("pullRequests"), QJsonArray{S("github.com/acme/app#12")}}}},
                             {S("outcome"), S("failed")}, {S("summary"), S("acme/app#12: checks failing")}});
  });
  step(S("a thread stored the agent's own wake-up as a user message"), [](World& world, const Captures&, const Table&) {
    const QString run = startRun(world);
    set(world, S("turn-item"), S("message:") + run,
        {{S("createdBy"), S("agent")}, {S("creationSource"), S("provider")}, {S("text"), S("Background task completed.")}});
    addItem(world, S("assistant_message"), {{S("text"), S("Noted.")}});
  });
  step(S("the user reads the parent thread"), [](World& world, const Captures&, const Table&) { expectOpen(world, world.thread, S("the parent thread")); });
  step(S("the timeline says %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const int row = rowOf(world, S("marker"));
    expect(role(timeline(world), row, TimelineModel::TitleRole) == c[0], describe(timeline(world)));
    expect(role(timeline(world), row, TimelineModel::TextRole).toString().isEmpty(), describe(timeline(world)));
    expect(shown(world, S("markerTitle"))->property("text") == c[0], S("the row is not drawn as \"%1\"").arg(c[0]));
  });
  const auto noUserMessage = [](World& world) {
    TimelineModel& model = timeline(world);
    for (int row = 0; row < model.rowCount(); ++row) {
      expect(role(model, row, TimelineModel::KindRole) != QLatin1String("message") || role(model, row, TimelineModel::AuthorRole) != QLatin1String("user"), describe(model));
      expect(!role(model, row, TimelineModel::TextRole).toString().contains(QLatin1String("delegated_task_result")), describe(model));
      expect(role(model, row, TimelineModel::AttributionRole).toString().isEmpty(), describe(model));
    }
    // The agent's reply to it is there, so the thread is drawn.
    world.item(S("markerTitle"));
    expect(world.find(S("messageAttribution")) == nullptr, S("a message is drawn with a sender"));
  };
  step(S("the result is not shown as a message of the user's"), [noUserMessage](World& world, const Captures&, const Table&) { noUserMessage(world); });
  step(S("nothing says a message was sent by another agent"), [noUserMessage](World& world, const Captures&, const Table&) { noUserMessage(world); });

  // The model a subagent runs on.
  step(S("the agent delegated work to a subagent on the model %1").arg(q), [](World& world, const Captures& c, const Table&) {
    updateRow(world.mc, world.thread, {{S("modelSelection"), QJsonObject{{S("instanceId"), S("codex")}, {S("model"), S("gpt-5")}}}});
    world.sync();
    startRun(world);
    // The MC lists the task with the model it was delegated to (delegation.ex).
    delegate(world, {{S("model"), c[0]}});
  });
  step(S("the user looks at the parent's subagents"), [](World& world, const Captures&, const Table&) { shown(world, S("subagentRow")); });
  step(S("the subagent is shown with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(role(timeline(world), rowOf(world, S("subagent")), TimelineModel::ModelRole) == c[0], describe(timeline(world)));
    const QString detail = shown(world, S("subagentDetail"))->property("text").toString();
    expect(detail == c[0] + S(" · write the tax tests"), S("the subagent reads \"%1\"").arg(detail));
  });
  step(S("the parent's model is not shown for it"), [](World& world, const Captures&, const Table&) {
    const QString detail = shown(world, S("subagentDetail"))->property("text").toString();
    expect(!detail.contains(S("gpt-5 ·")), S("the subagent reads \"%1\"").arg(detail));
  });

  // A finished subagent that left work running.
  step(S("a subagent returned its result while background work it started is still running"), [](World& world, const Captures&, const Table&) {
    startRun(world, 30);
    // The MC's task id is the call's own id when it has no native one.
    const QString command = addItem(world, S("command_execution"), {{S("input"), S("npm run dev\n")}, {S("status"), S("running")}});
    delegate(world, {{S("status"), S("completed")}, {S("result"), S("Dev server started")}});
    addItem(world, S("assistant_message"), {{S("text"), S("The dev server is up.")}});
    // The turn is over; the command the subagent started is what is still pending.
    settleRun(world);
    updateRow(world.mc, world.thread,
              {{S("pendingBackgroundTasks"),
                QJsonArray{QJsonObject{{S("taskId"), command}, {S("taskType"), S("command_execution")}, {S("description"), S("npm run dev")}}}}});
    world.sync();
  });
  step(S("a later turn left %1 running without saying it ended").arg(q), [](World& world, const Captures& c, const Table&) {
    startRun(world, 10);
    addItem(world, S("command_execution"), {{S("input"), c[0]}, {S("status"), S("running")}});
    settleRun(world);
  });
  // A tool the provider runs on, with no title of its own: the MC names its
  // task after the tool and keys it by the call's native id.
  step(S("a turn left the tool %1 running in the background").arg(q), [](World& world, const Captures& c, const Table&) {
    startRun(world, 30);
    backgroundTool = addItem(world, S("dynamic_tool"),
                         {{S("toolName"), c[0]}, {S("input"), QJsonObject{{S("url"), S("http://localhost:3000")}}}, {S("status"), S("running")},
                          {S("nativeItemRef"), QJsonObject{{S("nativeId"), S("native-watch")}}}});
    settleRun(world);
    updateRow(world.mc, world.thread,
              {{S("pendingBackgroundTasks"),
                QJsonArray{QJsonObject{{S("taskId"), S("native-watch")}, {S("taskType"), S("dynamic_tool")}, {S("description"), c[0]}}}}});
    world.sync();
  });
  step(S("the tool is still shown as running"), [](World& world, const Captures&, const Table&) {
    TimelineModel& model = timeline(world);
    bool running = false;
    for (int row = 0; row < model.rowCount(); ++row) {
      for (const QVariant& entry : role(model, row, TimelineModel::EntriesRole).toList()) {
        running = running || (entry.toMap().value(S("id")) == backgroundTool && entry.toMap().value(S("statusLabel")) == QLatin1String("Running"));
      }
    }
    expect(running, describe(model));
  });
  step(S("the command %1 is not listed").arg(q), [](World& world, const Captures& c, const Table&) {
    TimelineModel& model = timeline(world);
    for (int row = 0; row < model.rowCount(); ++row) {
      for (const QVariant& entry : role(model, row, TimelineModel::EntriesRole).toList()) {
        expect(entry.toMap().value(S("command")) != c[0], describe(model));
      }
    }
    expect(!world.shows(c[0]), S("the screen says: %1").arg(world.texts().join(S(" | "))));
  });
  step(S("the user looks at the parent thread"), [](World& world, const Captures&, const Table&) {
    expectOpen(world, world.thread, S("the parent thread"));
    world.waitFor([&] { return timeline(world).status() == QLatin1String("live"); }, [&] { return describe(timeline(world)); });
  });
  step(S("the subagent's result is shown"), [](World& world, const Captures&, const Table&) {
    TimelineModel& model = timeline(world);
    const int row = rowOf(world, S("subagent"));
    expect(role(model, row, TimelineModel::TextRole) == QLatin1String("Dev server started") && role(model, row, TimelineModel::StatusLabelRole) == QLatin1String("Completed"),
           describe(model));
    expect(shown(world, S("subagentDetail"))->property("text").toString().endsWith(QLatin1String("Dev server started")), S("the result is not drawn"));
  });
  step(S("its background work is still shown as running"), [](World& world, const Captures&, const Table&) {
    TimelineModel& model = timeline(world);
    const QVariantList entries = role(model, rowOf(world, S("work")), TimelineModel::EntriesRole).toList();
    expect(entries.size() == 1 && entries.first().toMap().value(S("command")).toString().trimmed() == QLatin1String("npm run dev") &&
               entries.first().toMap().value(S("statusLabel")) == QLatin1String("Running"),
           describe(model));
    world.waitFor([&] { return world.shows(S("Running")); }, [&] { return S("the running command; the screen says: %1").arg(world.texts().join(S(" | "))); });
  });

  // A subagent's approval, answered from the parent.
  step(S("a subagent asks for approval to run a command"), [](World& world, const Captures&, const Table&) {
    startRun(world, 30);
    delegate(world);
    // The request is the parent's: the subagent's own thread holds none.
    const QString request = S("request-subagent");
    set(world, S("runtime-request"), request,
        {{S("id"), request}, {S("status"), S("pending")}, {S("kind"), S("command")}, {S("responseCapability"), QJsonObject{{S("type"), S("live")}}}});
    addItem(world, S("approval_request"), {{S("requestId"), request}, {S("status"), S("waiting")}, {S("requestKind"), S("command")}, {S("prompt"), S("npm test")}});
  });
  const auto approvals = [](World& world) { return turnState(world).value(S("approvals")).toList(); };
  step(S("the approval is listed there"), [approvals](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return approvals(world).size() == 1; }, [&] { return S("the approval; the turn is %1").arg(show(turnState(world))); });
    const QVariantMap approval = approvals(world).first().toMap();
    expect(approval.value(S("requestId")) == QLatin1String("request-subagent") && approval.value(S("detail")) == QLatin1String("npm test") &&
               approval.value(S("canRespond")).toBool(),
           S("the approval is %1").arg(show(approval)));
    expect(role(timeline(world), rowOf(world, S("subagent")), TimelineModel::StatusLabelRole) == QLatin1String("Working"), describe(timeline(world)));
    world.waitFor([&] { return world.shows(S("npm test"), false); }, [&] { return S("the approval on screen; the screen says: %1").arg(world.texts().join(S(" | "))); });
  });
  step(S("the user answers it"), [](World& world, const Captures&, const Table&) {
    world.tap(S("approvalOption-accept"));
    world.sync();
  });
  step(S("the subagent continues with the answer"), [approvals](World& world, const Captures&, const Table&) {
    QJsonObject answer;
    world.waitFor([&] { return !(answer = lastCommandOf(world, S("runtime-request.respond"))).isEmpty(); },
                  [&] { return S("the answer; the MC has %1").arg(describeCommands(world)); });
    expect(answer.value(QLatin1String("threadId")) == world.thread && answer.value(QLatin1String("requestId")) == QLatin1String("request-subagent") &&
               answer.value(QLatin1String("decision")) == QLatin1String("accept"),
           S("the MC was told %1").arg(show(answer.toVariantMap())));
    set(world, S("runtime-request"), S("request-subagent"), {{S("status"), S("resolved")}, {S("decision"), S("accept")}});
    set(world, S("turn-item"), S("turn-item:subagent:") + kTask, {{S("status"), S("completed")}, {S("result"), S("ran npm test")}});
    world.waitFor([&] { return approvals(world).isEmpty(); }, [&] { return S("the approval to close; the turn is %1").arg(show(turnState(world))); });
    expect(role(timeline(world), rowOf(world, S("subagent")), TimelineModel::TextRole) == QLatin1String("ran npm test"), describe(timeline(world)));
  });

  // Changes to the thread's context.
  const QList<std::pair<QString, QJsonObject>> contextEvents{
      {S("the conversation is forked"), {{S("type"), S("fork")}, {S("targetThreadId"), S("thread-2")}}},
      {S("the context is handed to another agent"), {{S("type"), S("handoff")}, {S("summary"), S("Cart tax so far")}}},
      {S("the agent creates a thread"), {{S("type"), S("thread_created")}, {S("title"), S("Tax tests")}}},
      {S("the context is compacted"), {{S("type"), S("compaction")}, {S("summary"), S("Earlier turns")}}},
  };
  for (const auto& [event, fields] : contextEvents) {
    step(event, [fields](World& world, const Captures&, const Table&) {
      startRun(world);
      addItem(world, fields.value(QLatin1String("type")).toString(), fields);
    });
  }
  step(S("the timeline marks %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString title = role(timeline(world), rowOf(world, S("marker")), TimelineModel::TitleRole).toString();
    expect(title == c[0], S("the timeline marks \"%1\"").arg(title));
    world.waitFor([&] { return world.shows(c[0]); }, [&] { return S("\"%1\" on screen; the screen says: %2").arg(c[0], world.texts().join(S(" | "))); });
  });
});

// --- The subagents of the turn -----------------------------------------------

QString slug(const QString& title) {
  return title.toLower().replace(QLatin1Char(' '), QLatin1Char('-'));
}

// A subagent of the running turn named `title`, with a thread of its own
// unless `fields` say otherwise; started `since` seconds ago.
void startSubagent(World& world, const QString& title, const QJsonObject& fields = {}, int since = 0) {
  const QString id = S("task-") + slug(title);
  QJsonObject entity{{S("id"), id}, {S("threadId"), world.thread}, {S("runId"), world.run}, {S("childThreadId"), S("thread-") + slug(title)},
                     {S("prompt"), S("work on ") + title.toLower()}, {S("title"), title}, {S("status"), S("running")},
                     {S("startedAt"), iso(now().addSecs(-since))}, {S("updatedAt"), iso(now().addSecs(-since))}};
  QJsonObject item{{S("subagentId"), id}, {S("origin"), S("app_owned")}, {S("childThreadId"), entity.value(QLatin1String("childThreadId"))},
                   {S("title"), title}, {S("prompt"), entity.value(QLatin1String("prompt"))}, {S("status"), S("running")}};
  for (auto it = fields.begin(); it != fields.end(); ++it) {
    // A null field is one the subagent does not have.
    if (it.value().isNull()) {
      entity.remove(it.key());
      item.remove(it.key());
      continue;
    }
    entity.insert(it.key(), it.value());
    item.insert(it.key(), it.value());
  }
  set(world, S("subagent"), id, entity);
  addItem(world, S("subagent"), item);
}

// The subagent named `title` moves on: its entity, and the item that shows it.
void moveSubagent(World& world, const QString& title, const QJsonObject& fields) {
  const QString id = S("task-") + slug(title);
  set(world, S("subagent"), id, fields);
  for (const auto& [itemId, item] : timeline(world).entities(S("turn-item")).asKeyValueRange()) {
    if (item.value(QLatin1String("subagentId")) == id) set(world, S("turn-item"), itemId, {{S("status"), fields.value(QLatin1String("status"))}});
  }
}

QQuickItem* childNamed(QQuickItem* item, const QString& name) {
  if (!item) return nullptr;
  for (QQuickItem* child : item->childItems()) {
    if (child->objectName() == name) return child;
    if (QQuickItem* found = childNamed(child, name)) return found;
  }
  return nullptr;
}

QString describeAgents(World& world) {
  QStringList rows;
  if (QQuickItem* list = world.find(S("agentsList"))) {
    for (QQuickItem* child : list->property("contentItem").value<QQuickItem*>()->childItems()) {
      if (!child->objectName().startsWith(QLatin1String("agent:"))) continue;
      QQuickItem* status = childNamed(child, S("agentStatus"));
      QQuickItem* elapsed = childNamed(child, S("agentElapsed"));
      rows.append(S("%1 (%2, %3)").arg(child->objectName().mid(6), status ? status->property("text").toString() : QString(),
                                       elapsed ? elapsed->property("text").toString() : QString()));
    }
  }
  return rows.isEmpty() ? S("(none)") : rows.join(S("; "));
}

QStringList listedAgents(World& world) {
  QStringList titles;
  if (QQuickItem* list = world.find(S("agentsList"))) {
    for (QQuickItem* child : list->property("contentItem").value<QQuickItem*>()->childItems()) {
      if (child->objectName().startsWith(QLatin1String("agent:")) && child->isVisible()) titles.append(child->objectName().mid(6));
    }
  }
  titles.sort();
  return titles;
}

QQuickItem* listedAgent(World& world, const QString& title) {
  return world.item(S("agent:") + title);
}

QString agentText(World& world, const QString& title, const QString& part) {
  QQuickItem* found = childNamed(listedAgent(world, title), part);
  return found ? found->property("text").toString() : QString();
}

void openAgents(World& world) {
  world.tap(S("agentsStatus"));
  world.awaitPopup(S("agentsSheet"));
}

QString agentsStatus(World& world) {
  QQuickItem* status = world.find(S("agentsStatus"));
  return status ? status->property("text").toString() : QString();
}

const Steps turnSteps([] {
  const QString q = kQuoted;

  // A group in the timeline.
  step(S("the agent started the subagents %1, %1 and %1 together").arg(q), [](World& world, const Captures& c, const Table&) {
    startRun(world);
    startSubagent(world, c[0]);
    startSubagent(world, c[1], {{S("status"), S("completed")}, {S("result"), S("Docs written")}});
    startSubagent(world, c[2], {{S("status"), S("failed")}, {S("result"), S("Lint crashed")}});
  });
  step(S("the timeline shows one entry reading %1 with how many are working, done or failed").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return rowsOf(timeline(world), S("subagents")).size() == 1; }, [&] { return S("one group; %1").arg(describe(timeline(world))); });
    TimelineModel& model = timeline(world);
    const int row = rowsOf(model, S("subagents")).first();
    expect(role(model, row, TimelineModel::TitleRole) == c[0] && role(model, row, TimelineModel::TextRole) == S("1 working · 1 done · 1 failed"),
           describe(model));
    expect(shown(world, S("subagentGroupTitle"))->property("text") == c[0], S("the group is not drawn as \"%1\"").arg(c[0]));
    expect(world.item(S("subagentGroupSummary"))->property("text") == S("1 working · 1 done · 1 failed"), S("the group's counts are not drawn"));
  });
  step(S("the rows of the subagents are shown only once the user opens the entry"), [](World& world, const Captures&, const Table&) {
    expect(rowsOf(timeline(world), S("subagent")).isEmpty() && world.find(S("subagentRow")) == nullptr, describe(timeline(world)));
    tap(world, S("subagentGroup"));
    world.waitFor([&] { return rowsOf(timeline(world), S("subagent")).size() == 3; }, [&] { return S("the group to open; %1").arg(describe(timeline(world))); });
    TimelineModel& model = timeline(world);
    QStringList titles;
    for (const int row : rowsOf(model, S("subagent"))) titles.append(role(model, row, TimelineModel::TitleRole).toString());
    expect(titles == QStringList{S("Tax tests"), S("Docs"), S("Lint")}, S("the group opens to %1").arg(titles.join(S(", "))));
    expect(rowsOf(model, S("subagents")).size() == 1 && role(model, rowsOf(model, S("subagents")).first(), TimelineModel::ExpandedRole).toBool(), describe(model));
    shown(world, S("subagentRow"));
  });
  step(S("the agent started the subagent %1 alone").arg(q), [](World& world, const Captures& c, const Table&) {
    startRun(world);
    startSubagent(world, c[0]);
  });
  step(S("the timeline shows the row of %1 directly").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(role(timeline(world), rowOf(world, S("subagent")), TimelineModel::TitleRole) == c[0], describe(timeline(world)));
    expect(rowsOf(timeline(world), S("subagents")).isEmpty(), describe(timeline(world)));
    shown(world, S("subagentRow"));
    expect(world.find(S("subagentGroup")) == nullptr, S("a group is drawn"));
  });

  // The thread's status.
  step(S("the agent started three subagents in this turn"), [](World& world, const Captures&, const Table&) {
    startRun(world);
    for (const QString& title : {S("Tax tests"), S("Docs"), S("Lint")}) startSubagent(world, title);
  });
  step(S("two of them are still working"), [](World& world, const Captures&, const Table&) {
    moveSubagent(world, S("Lint"), {{S("status"), S("completed")}, {S("completedAt"), iso(now())}});
  });
  step(S("all three have finished"), [](World& world, const Captures&, const Table&) {
    for (const QString& title : {S("Tax tests"), S("Docs"), S("Lint")}) moveSubagent(world, title, {{S("status"), S("completed")}, {S("completedAt"), iso(now())}});
  });
  step(S("the turn settles and every subagent has finished"), [](World& world, const Captures&, const Table&) {
    for (const QString& title : {S("Tax tests"), S("Docs"), S("Lint")}) moveSubagent(world, title, {{S("status"), S("completed")}, {S("completedAt"), iso(now())}});
    settleRun(world);
  });
  step(S("the thread's status says %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return agentsStatus(world) == c[0]; }, [&] { return S("the status to say \"%1\"; it says \"%2\"").arg(c[0], agentsStatus(world)); });
  });
  step(S("the thread's status does not mention subagents"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.find(S("agentsStatus")) == nullptr; }, [&] { return S("the status to go; it says \"%1\"").arg(agentsStatus(world)); });
    // The timeline's own group still reads "3 subagents"; the status's counts are gone.
    for (const QString& said : {S("agents working"), S("agents done"), S("agent done")}) {
      expect(!world.shows(said, false), S("the screen says: %1").arg(world.texts().join(S(" | "))));
    }
  });

  // Their list.
  step(S("the agent started the subagents %1 and %1 in this turn").arg(q), [](World& world, const Captures& c, const Table&) {
    startRun(world, 120);
    startSubagent(world, c[0], {}, 100);
    startSubagent(world, c[1], {}, 90);
  });
  step(S("%1 finished 75 seconds after it started").arg(q), [](World& world, const Captures& c, const Table&) {
    moveSubagent(world, c[0], {{S("status"), S("completed")}, {S("completedAt"), iso(now().addSecs(-15))}, {S("updatedAt"), iso(now().addSecs(-15))}});
  });
  step(S("the user opens the subagents from the thread's status"), [](World& world, const Captures&, const Table&) { openAgents(world); });
  step(S("the user opens the subagents of the thread"), [](World& world, const Captures&, const Table&) { openAgents(world); });
  step(S("%1 is listed as working and %1 as completed").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return agentText(world, c[0], S("agentStatus")) == QLatin1String("Working") && agentText(world, c[1], S("agentStatus")) == QLatin1String("Completed"); },
                  [&] { return S("the list to read so; it reads %1").arg(describeAgents(world)); });
  });
  step(S("%1 is shown to have taken %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return agentText(world, c[0], S("agentElapsed")) == c[1]; }, [&] { return S("\"%1\"; the list reads %2").arg(c[1], describeAgents(world)); });
  });
  step(S("the agent started the subagent %1 in the first turn").arg(q), [](World& world, const Captures& c, const Table&) {
    startRun(world, 300);
    startSubagent(world, c[0], {{S("status"), S("completed")}, {S("completedAt"), iso(now().addSecs(-200))}}, 290);
    settleRun(world);
  });
  step(S("the agent started the subagent %1 in the second turn").arg(q), [](World& world, const Captures& c, const Table&) {
    startRun(world, 60);
    startSubagent(world, c[0], {}, 50);
  });
  step(S("only %1 is listed among the subagents").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return listedAgents(world) == QStringList{c[0]}; }, [&] { return S("only %1; the list reads %2").arg(c[0], describeAgents(world)); });
  });
  step(S("the agent has a subagent that the provider manages and that has no thread"), [](World& world, const Captures&, const Table&) {
    startRun(world, 30);
    startSubagent(world, S("Explore"), {{S("origin"), S("provider_native")}, {S("childThreadId"), QJsonValue()}}, 20);
  });
  step(S("the subagent is listed with its status"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return listedAgents(world) == QStringList{S("Explore")} && agentText(world, S("Explore"), S("agentStatus")).startsWith(QLatin1String("Working")); },
                  [&] { return S("the subagent and its status; the list reads %1").arg(describeAgents(world)); });
  });
  step(S("it says its work appears in the conversation"), [](World& world, const Captures&, const Table&) {
    const QString status = agentText(world, S("Explore"), S("agentStatus"));
    expect(status.contains(QLatin1String("Its work appears in the conversation")), S("the subagent reads \"%1\"").arg(status));
  });
  step(S("it cannot be opened"), [](World& world, const Captures&, const Table&) {
    QQuickItem* row = listedAgent(world, S("Explore"));
    // A disabled row takes no tap: nothing leads to a thread.
    expect(!row->isEnabled() && row->property("thread").toString().isEmpty(), S("the subagent can be opened"));
    expect(world.popupShowing(S("agentsSheet")) && openKey(world) == key(world, world.thread), S("the phone shows %1").arg(openKey(world)));
  });
});

const Steps displaySteps([] {
  const QString q = kQuoted;

  // A group's counts (subagentDisplay.ts summarizeSubagentStatuses).
  step(S("the agent started a group of subagents of which (.+)"), [](World& world, const Captures& c, const Table&) {
    const QHash<QString, QStringList> groups{
        {S("two are working and one is done"), {S("running"), S("running"), S("completed")}},
        {S("one is waiting for the user and one is not started yet"), {S("waiting"), S("pending")}},
        {S("two are done, one failed and one was stopped"), {S("completed"), S("completed"), S("failed"), S("cancelled")}},
        {S("one is working, one is done, one failed, one stopped, one idle"), {S("running"), S("completed"), S("failed"), S("cancelled"), S("idle")}},
    };
    if (!groups.contains(c[0])) fail(S("no such group: %1").arg(c[0]));
    startRun(world);
    const QStringList statuses = groups.value(c[0]);
    for (qsizetype i = 0; i < statuses.size(); ++i) startSubagent(world, S("Agent %1").arg(i + 1), {{S("status"), statuses.at(i)}});
  });
  step(S("the group reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return rowsOf(timeline(world), S("subagents")).size() == 1; }, [&] { return S("one group; %1").arg(describe(timeline(world))); });
    TimelineModel& model = timeline(world);
    const QString summary = role(model, rowsOf(model, S("subagents")).first(), TimelineModel::TextRole).toString();
    expect(summary == c[0], S("the group reads \"%1\"").arg(summary));
    world.waitFor([&] {
      QQuickItem* drawn = world.find(S("subagentGroupSummary"));
      return drawn && drawn->property("text") == c[0];
    }, S("the group's counts to be drawn"));
  });

  // A subagent's title (subagentDisplay.ts formatSubagentDisplayTitle): in the
  // timeline, in the turn's subagents and in its own subagent's lineage.
  step(S("a subagent whose title is %1").arg(q), [](World& world, const Captures& c, const Table&) {
    startRun(world);
    const QString child = S("thread-sub");
    const auto list = [&](const QString& id, const QString& title, const QString& parent) {
      world.mc.threads.insert(id, {{S("id"), id}, {S("title"), title}, {S("projectId"), S("shop")},
                                   {S("createdAt"), S("2026-09-23T09:30:00Z")}, {S("updatedAt"), S("2026-09-23T09:30:00Z")},
                                   {S("lineage"), QJsonObject{{S("rootThreadId"), world.thread}, {S("parentThreadId"), parent},
                                                              {S("relationshipToParent"), S("subagent")}}}});
      world.mc.sendRow(id, world.mc.threads.value(id));
    };
    list(child, c[0], world.thread);
    // A subagent of the subagent, whose lineage names it as its parent.
    list(S("thread-sub-sub"), S("Grandchild"), child);
    startSubagent(world, c[0], {{S("childThreadId"), child}});
  });
  step(S("the user sees it in the timeline, the lineage or the agents list"), [](World& world, const Captures&, const Table&) { world.sync(); });
  step(S("it is shown as %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return rowsOf(timeline(world), S("subagent")).size() == 1; }, [&] { return S("the subagent's row; %1").arg(describe(timeline(world))); });
    TimelineModel& model = timeline(world);
    const QString inTimeline = role(model, rowsOf(model, S("subagent")).first(), TimelineModel::TitleRole).toString();
    expect(inTimeline == c[0], S("the timeline shows \"%1\"").arg(inTimeline));
    openAgents(world);
    world.waitFor([&] { return listedAgents(world).contains(c[0]); }, [&] { return S("the subagents to list \"%1\"; %2").arg(c[0], describeAgents(world)); });
    world.native().controller<NavigationController>()->open(NavigationController::Route::thread(key(world, S("thread-sub-sub"))));
    world.waitFor([&] { return at(world.state(S("lineage")), S("parent.title")) == c[0]; },
                  [&] { return S("the lineage to name \"%1\"; it is %2").arg(c[0], show(world.state(S("lineage")))); });
  });
});

}  // namespace
