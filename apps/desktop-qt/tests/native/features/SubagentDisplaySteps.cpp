// How the timeline shows subagents, where a message came from and the
// changes to a thread's context (features/timeline/plans-and-subagents.feature):
// subagent rows, groups and pointing cards, a message's sender, a fork's
// inherited work, compaction, handoff, fork and created-thread markers,
// interrupts, the result waiting to wake the parent and the agents-working
// banner. The open thread is Stream.h's thread-1 ("Tax line"), drawn by the
// ThreadView brick.

#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>
#include <QTest>

#include <memory>

#include "AgentsModel.h"
#include "Brick.h"
#include "ComposerBrick.h"
#include "FakeConfig.h"
#include "Harness.h"
#include "NavigationController.h"
#include "RightPanelController.h"
#include "Stream.h"
#include "World.h"

namespace {

using namespace stream;

const QString kSource = QStringLiteral("thread-source");
const QString kCreated = QStringLiteral("thread-tax-tests");

// What a step said that a later one compares against.
struct Said {
  QString note;
  QString runMessage;
  QString openedFrom;
};

QString key(World& world, const QString& thread) {
  return world.mc.environmentId + QLatin1Char(':') + thread;
}

QString shownThread(World& world) {
  return world.native().controller<NavigationController>()->threadKey();
}

// The MC lists a thread of the open thread's project.
void listThread(World& world, const QString& id, const QString& title, const QJsonObject& more = {}) {
  QJsonObject row{{QStringLiteral("id"), id}, {QStringLiteral("title"), title}, {QStringLiteral("projectId"), kProject},
                  {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:30:00Z")}, {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:30:00Z")}};
  for (auto it = more.begin(); it != more.end(); ++it) row.insert(it.key(), it.value());
  world.mc.threads.insert(id, row);
  world.mc.sendRow(id, row);
  world.sync();
}

// The open thread's row moves on.
void changeThreadRow(World& world, const QJsonObject& fields) {
  QJsonObject row = world.mc.threads.value(kThread);
  for (auto it = fields.begin(); it != fields.end(); ++it) row.insert(it.key(), it.value());
  world.mc.threads.insert(kThread, row);
  world.mc.sendRow(kThread, row);
  world.sync();
}

QList<int> rowsOf(World& world, const QString& kind) {
  TimelineModel& model = timeline(world);
  QList<int> rows;
  for (int row = 0; row < model.rowCount(); ++row) {
    if (role(model, row, TimelineModel::KindRole).toString() == kind) rows.append(row);
  }
  return rows;
}

int lastRowOf(World& world, const QString& kind) {
  const QList<int> rows = rowsOf(world, kind);
  if (rows.isEmpty()) fail(QStringLiteral("no %1 row; %2").arg(kind, describe(timeline(world))));
  return rows.last();
}

QVariant lastOf(World& world, const QString& kind, int which) {
  return role(timeline(world), lastRowOf(world, kind), which);
}

// Opens every closed turn fold, so the work in it is listed.
void openFolds(World& world) {
  TimelineModel& model = timeline(world);
  for (int row = 0; row < model.rowCount(); ++row) {
    if (role(model, row, TimelineModel::KindRole) == QLatin1String("fold") && !role(model, row, TimelineModel::ExpandedRole).toBool()) {
      model.toggle(role(model, row, TimelineModel::IdRole).toString());
      row = -1;
    }
  }
  world.sync();
}

// The calls the work rows list, with every fold and group opened.
QList<QVariantMap> calls(World& world) {
  openFolds(world);
  TimelineModel& model = timeline(world);
  QList<QVariantMap> found;
  for (const int row : rowsOf(world, QStringLiteral("work"))) {
    if (!role(model, row, TimelineModel::ExpandedRole).toBool()) model.toggle(role(model, row, TimelineModel::IdRole).toString());
    for (const QVariant& entry : role(model, row, TimelineModel::EntriesRole).toList()) found.append(entry.toMap());
  }
  return found;
}

QString describeCalls(World& world) {
  QStringList shown;
  for (const QVariantMap& call : calls(world)) shown.append(show(call));
  return (shown.isEmpty() ? QStringLiteral("no calls") : shown.join(QStringLiteral("; "))) + QStringLiteral("; rows: ") + describe(timeline(world));
}

// The open thread as the ThreadView brick draws it.
Brick& view(World& world) {
  if (!world.brick) world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nThreadView {}\n", QSize(820, 900));
  return *world.brick;
}

QList<QQuickItem*> drawnAll(World& world, const QString& name) {
  QList<QQuickItem*> found;
  const std::function<void(QQuickItem*)> find = [&](QQuickItem* item) {
    if (item->objectName() == name && item->isVisible()) found.append(item);
    for (QQuickItem* child : item->childItems()) find(child);
  };
  find(view(world).window().contentItem());
  return found;
}

QQuickItem* drawn(World& world, const QString& name) {
  QQuickItem* found = nullptr;
  world.waitFor([&] {
    const QList<QQuickItem*> all = drawnAll(world, name);
    found = all.isEmpty() ? nullptr : all.last();
    return found != nullptr;
  }, QStringLiteral("the thread to draw %1").arg(name));
  return found;
}

// Waits for an item of that name to read `text`.
void drawsText(World& world, const QString& name, const QString& text) {
  world.waitFor([&] {
    const QList<QQuickItem*> all = drawnAll(world, name);
    return std::any_of(all.begin(), all.end(), [&](QQuickItem* item) { return item->property("text").toString() == text; });
  }, [&] {
    QStringList texts;
    for (QQuickItem* item : drawnAll(world, name)) texts.append(item->property("text").toString());
    return QStringLiteral("the thread to draw %1 reading \"%2\"; it reads [%3]").arg(name, text, texts.join(QStringLiteral(", ")));
  });
}

void clickItem(World& world, QQuickItem* item) {
  QTest::mouseClick(&view(world).window(), Qt::LeftButton, Qt::NoModifier, view(world).at(item, 0.5, 0.5));
  world.sync();
}

void click(World& world, const QString& name) {
  clickItem(world, drawn(world, name));
}

AgentsModel& agents(World& world) {
  return *world.native().controller<RightPanelController>()->agents();
}

QString slugOf(const QString& title) {
  return title.toLower().replace(QLatin1Char(' '), QLatin1Char('-'));
}

// A subagent of the current run, as delegation.ex records it: its entity and
// the turn item that shows it. `fields` go on both.
QString addSubagent(World& world, const QString& title, const QJsonObject& fields = {}) {
  FakeStreams& fake = world.mc.part<FakeStreams>();
  if (fake.run.isEmpty()) startRun(world);
  const QString id = QStringLiteral("task-") + slugOf(title);
  const QString started = iso(now().addSecs(-60));
  QJsonObject entity{{QStringLiteral("id"), id}, {QStringLiteral("threadId"), fake.thread}, {QStringLiteral("runId"), fake.run},
                     {QStringLiteral("childThreadId"), QStringLiteral("thread-") + slugOf(title)}, {QStringLiteral("prompt"), QStringLiteral("write the tax tests")},
                     {QStringLiteral("title"), title}, {QStringLiteral("model"), QStringLiteral("gpt-5.5")}, {QStringLiteral("status"), QStringLiteral("running")},
                     {QStringLiteral("startedAt"), started}, {QStringLiteral("updatedAt"), started}};
  QJsonObject item{{QStringLiteral("id"), QStringLiteral("turn-item:subagent:") + id}, {QStringLiteral("subagentId"), id}, {QStringLiteral("origin"), QStringLiteral("app_owned")},
                   {QStringLiteral("childThreadId"), entity.value(QLatin1String("childThreadId"))}, {QStringLiteral("title"), title},
                   {QStringLiteral("prompt"), QStringLiteral("write the tax tests")}, {QStringLiteral("status"), QStringLiteral("running")}, {QStringLiteral("startedAt"), started}};
  for (auto it = fields.begin(); it != fields.end(); ++it) {
    entity.insert(it.key(), it.value());
    if (it.key() != QLatin1String("model")) item.insert(it.key(), it.value());
  }
  // A subagent with no thread names none.
  if (fields.contains(QLatin1String("childThreadId")) && fields.value(QLatin1String("childThreadId")).isNull()) {
    entity.remove(QStringLiteral("childThreadId"));
    item.remove(QStringLiteral("childThreadId"));
  }
  set(world, QStringLiteral("subagent"), id, entity);
  addItem(world, QStringLiteral("subagent"), item);
  return id;
}

void changeSubagent(World& world, const QString& id, const QJsonObject& fields) {
  set(world, QStringLiteral("subagent"), id, fields);
  set(world, QStringLiteral("turn-item"), QStringLiteral("turn-item:subagent:") + id, fields);
}

// Subagents the agent started in one go: one provider turn.
void startTogether(World& world, const QStringList& titles, const QStringList& statuses = {}) {
  world.setTime(now());
  startRun(world, 120);
  for (qsizetype i = 0; i < titles.size(); ++i) {
    addSubagent(world, titles.at(i), {{QStringLiteral("providerTurnId"), QStringLiteral("turn-a")},
                                      {QStringLiteral("status"), statuses.value(i, QStringLiteral("running"))}});
  }
}

QString describeGroup(World& world) {
  return describe(timeline(world));
}

// The fork's history: the open thread was forked from "Cart work" after its
// run run-1, which ran a command; the fork carried that run over.
void forkWithHistory(World& world) {
  listThread(world, kSource, QStringLiteral("Cart work"));
  changeThreadRow(world, {{QStringLiteral("forkedFrom"), QJsonObject{{QStringLiteral("type"), QStringLiteral("run")}, {QStringLiteral("threadId"), kSource},
                                                                     {QStringLiteral("runId"), QStringLiteral("run-1")}}}});
  startRun(world, 300);
  addCommand(world, 1);
  addItem(world, QStringLiteral("assistant_message"), {{QStringLiteral("text"), QStringLiteral("The cart has a tax line.")}});
  settleRun(world, QStringLiteral("completed"), 30);
}

QJsonObject provider(const QString& id, const QString& name, const QString& slug, const QString& model) {
  return {{QStringLiteral("instanceId"), id}, {QStringLiteral("driver"), id}, {QStringLiteral("displayName"), name},
          {QStringLiteral("enabled"), true}, {QStringLiteral("status"), QStringLiteral("ready")},
          {QStringLiteral("models"), QJsonArray{QJsonObject{{QStringLiteral("slug"), slug}, {QStringLiteral("name"), model}}}}};
}

// "Claude · Opus" as the run's model selection, from the providers the
// handoff steps publish.
QJsonObject selectionOf(const QString& said) {
  const QString name = said.section(QStringLiteral(" · "), 0, 0);
  return name == QLatin1String("Claude") ? QJsonObject{{QStringLiteral("instanceId"), QStringLiteral("claude")}, {QStringLiteral("model"), QStringLiteral("claude-opus-4-6")}}
                                         : QJsonObject{{QStringLiteral("instanceId"), QStringLiteral("codex")}, {QStringLiteral("model"), QStringLiteral("gpt-5.4")}};
}

void startRunOn(World& world, const QJsonObject& selection) {
  const QString run = startRun(world, 60);
  set(world, QStringLiteral("run"), run, {{QStringLiteral("modelSelection"), selection}});
}

// The last message row of the open thread.
int messageRow(World& world) {
  TimelineModel& model = timeline(world);
  const QString id = QStringLiteral("message:") + world.mc.part<FakeStreams>().run;
  for (int row = 0; row < model.rowCount(); ++row) {
    if (role(model, row, TimelineModel::IdRole) == id) return row;
  }
  fail(QStringLiteral("no row for %1; %2").arg(id, describe(model)));
}

void sendMessage(World& world, const QJsonObject& fields) {
  const QString run = startRun(world, 30);
  set(world, QStringLiteral("turn-item"), QStringLiteral("message:") + run, fields);
}

// A thread the agent created in the current run.
void createThread(World& world, const QString& title) {
  listThread(world, kCreated, title.isEmpty() ? QStringLiteral("New thread") : title);
  QJsonObject fields{{QStringLiteral("targetThreadId"), kCreated}};
  if (!title.isEmpty()) fields.insert(QStringLiteral("title"), title);
  addItem(world, QStringLiteral("thread_created"), fields);
}

// A row's title as it reads, with its detail after it.
QStringList rowTexts(World& world) {
  TimelineModel& model = timeline(world);
  QStringList texts;
  for (int row = 0; row < model.rowCount(); ++row) {
    const QString title = role(model, row, TimelineModel::TitleRole).toString();
    const QString detail = role(model, row, TimelineModel::TextRole).toString();
    texts.append(detail.isEmpty() || role(model, row, TimelineModel::KindRole) != QLatin1String("marker") ? title : title + QStringLiteral(" · ") + detail);
  }
  return texts;
}

// The pointing card of the last subagent row, as the hover draws it.
QVariantMap pointedCard(World& world) {
  return timeline(world).subagentCard(lastOf(world, QStringLiteral("subagent"), TimelineModel::IdRole).toString());
}

QStringList cardLines(World& world) {
  QStringList lines;
  for (QQuickItem* line : drawnAll(world, QStringLiteral("subagentCardLine"))) lines.append(line->property("text").toString());
  return lines;
}

const Steps steps([] {
  const QString q = kQuoted;

  // The result waiting to wake the parent (the composer's waiting list).
  step(QStringLiteral("the user looks at the result waiting to wake the parent"), [](World& world, const Captures&, const Table&) {
    FakeStreams& fake = world.mc.part<FakeStreams>();
    QJsonObject finished;
    for (const QJsonObject& entity : fake.threads.value(kThread)) {
      if (entity.contains(QLatin1String("subagentId")) || !entity.value(QLatin1String("result")).isString()) continue;
      if (entity.value(QLatin1String("status")) == QLatin1String("completed")) finished = entity;
    }
    if (finished.isEmpty()) fail(QStringLiteral("no subagent has finished"));
    const QString title = finished.value(QLatin1String("title")).toString();
    // The MC queues the parent's next run with the result as its message (delegation.ex).
    const QString run = QStringLiteral("run-wake");
    set(world, QStringLiteral("message"), QStringLiteral("message-wake"),
        {{QStringLiteral("id"), QStringLiteral("message-wake")}, {QStringLiteral("role"), QStringLiteral("user")}, {QStringLiteral("runId"), run},
         {QStringLiteral("notification"), QJsonObject{{QStringLiteral("summary"), title + QStringLiteral(" finished")}, {QStringLiteral("outcome"), QStringLiteral("completed")},
                                                      {QStringLiteral("workerThreadId"), finished.value(QLatin1String("childThreadId"))}, {QStringLiteral("workerTitle"), title},
                                                      {QStringLiteral("detail"), finished.value(QLatin1String("result"))}}}});
    set(world, QStringLiteral("run"), run,
        {{QStringLiteral("id"), run}, {QStringLiteral("ordinal"), ++fake.ordinal}, {QStringLiteral("status"), QStringLiteral("queued")},
         {QStringLiteral("queuePosition"), 1}, {QStringLiteral("userMessageId"), QStringLiteral("message-wake")}, {QStringLiteral("requestedAt"), iso(now())}});
    world.mc.part<Said>().openedFrom = finished.value(QLatin1String("childThreadId")).toString();
    composerBrick(world);
    world.waitFor([&] { return world.state(QStringLiteral("turn")).toMap().value(QStringLiteral("waiting")).toList().size() == 1; },
                  [&] { return QStringLiteral("the result to wait; the turn is %1").arg(show(world.state(QStringLiteral("turn")))); });
  });
  step(QStringLiteral("it names the worker"), [](World& world, const Captures&, const Table&) {
    QQuickItem* notice = nullptr;
    world.waitFor([&] { return (notice = composerPart(world, QStringLiteral("queueWaiting-run-wake"))) && notice->isVisible(); },
                  QStringLiteral("the composer to list the waiting result"));
    const QString text = notice->property("text").toString();
    expect(text.contains(QLatin1String("Tax tests")), QStringLiteral("the waiting result reads \"%1\"").arg(text));
  });
  step(QStringLiteral("the user can open the worker's thread from it"), [](World& world, const Captures&, const Table&) {
    QQuickItem* notice = composerPart(world, QStringLiteral("queueWaiting-run-wake"));
    if (!notice) fail(QStringLiteral("the composer lists no waiting result"));
    Brick& brick = composerBrick(world);
    QTest::mouseClick(&brick.window(), Qt::LeftButton, Qt::NoModifier, brick.at(notice, 0.2, 0.5));
    world.sync();
    const QString worker = key(world, world.mc.part<Said>().openedFrom);
    world.waitFor([&] { return shownThread(world) == worker; }, [&] { return QStringLiteral("%1 to open; %2 is shown").arg(worker, shownThread(world)); });
  });

  // Where a message came from.
  step(QStringLiteral("a scheduled task sent a message to the thread"), [](World& world, const Captures&, const Table&) {
    sendMessage(world, {{QStringLiteral("createdBy"), QStringLiteral("system")}, {QStringLiteral("scheduledTaskId"), QStringLiteral("task-nightly")},
                        {QStringLiteral("text"), QStringLiteral("Check the build")}});
  });
  step(QStringLiteral("a message was sent to the thread by automation that is not a scheduled task"), [](World& world, const Captures&, const Table&) {
    // An older MC's: the task named in the text, no task id (userMessage.ts LEGACY_AUTOMATION_PREFIX).
    sendMessage(world, {{QStringLiteral("createdBy"), QStringLiteral("agent")},
                        {QStringLiteral("text"), QStringLiteral("[Triggered by schedule task: Nightly]\n\nCheck the build")}});
  });
  step(QStringLiteral("another agent sent a message whose thread is not known"), [](World& world, const Captures&, const Table&) {
    sendMessage(world, {{QStringLiteral("createdBy"), QStringLiteral("agent")}, {QStringLiteral("senderThreadId"), QStringLiteral("thread-gone")},
                        {QStringLiteral("text"), QStringLiteral("The tests pass")}});
  });
  step(QStringLiteral("the user reads the message in the thread"), [](World& world, const Captures&, const Table&) {
    messageRow(world);
    drawn(world, QStringLiteral("messageAttribution"));
  });
  step(QStringLiteral("the message says %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString said = role(timeline(world), messageRow(world), TimelineModel::AttributionRole).toString();
    expect(said == c[0], QStringLiteral("the message says \"%1\"").arg(said));
    drawsText(world, QStringLiteral("messageAttribution"), c[0]);
    const QString text = role(timeline(world), messageRow(world), TimelineModel::TextRole).toString();
    expect(!text.startsWith(QLatin1String("[Triggered")), QStringLiteral("the message reads \"%1\"").arg(text));
  });
  step(QStringLiteral("the user can open that scheduled task from it"), [](World& world, const Captures&, const Table&) {
    click(world, QStringLiteral("openAutomation"));
    world.waitFor([&] { return !world.mc.subscribers(QStringLiteral("scheduledTasks")).isEmpty(); }, QStringLiteral("the scheduled tasks to be followed"));
    const QJsonObject task{{QStringLiteral("id"), QStringLiteral("task-nightly")}, {QStringLiteral("title"), QStringLiteral("Nightly")},
                           {QStringLiteral("prompt"), QStringLiteral("Check the build")}, {QStringLiteral("enabled"), true},
                           {QStringLiteral("schedule"), QJsonObject{{QStringLiteral("type"), QStringLiteral("fixed_time")}, {QStringLiteral("timeOfDay"), QStringLiteral("09:00")}}},
                           {QStringLiteral("projectId"), kProject}, {QStringLiteral("threadId"), kThread},
                           {QStringLiteral("workspaceStrategy"), QJsonObject{{QStringLiteral("type"), QStringLiteral("root")}}},
                           {QStringLiteral("modelSelection"), QJsonObject{{QStringLiteral("instanceId"), QStringLiteral("codex")}, {QStringLiteral("model"), QStringLiteral("codex-model")}}},
                           {QStringLiteral("runtimeMode"), QStringLiteral("full-access")}, {QStringLiteral("interactionMode"), QStringLiteral("default")},
                           {QStringLiteral("nextRunAt"), QStringLiteral("2099-01-01T09:00:00.000Z")}, {QStringLiteral("lastRunStatus"), QStringLiteral("succeeded")}};
    for (const int id : world.mc.subscribers(QStringLiteral("scheduledTasks"))) {
      world.mc.send({{QStringLiteral("t"), QStringLiteral("scheduledTasks")}, {QStringLiteral("id"), id}, {QStringLiteral("tasks"), QJsonArray{task}}});
    }
    world.waitFor([&] {
      const QVariantMap editor = world.state(QStringLiteral("scheduledTasks")).toMap().value(QStringLiteral("editor")).toMap();
      return editor.value(QStringLiteral("editing")).toBool() && editor.value(QStringLiteral("draft")).toMap().value(QStringLiteral("title")) == QLatin1String("Nightly");
    }, [&] { return QStringLiteral("the task to open; scheduled tasks are %1").arg(show(world.state(QStringLiteral("scheduledTasks")))); });
  });
  step(QStringLiteral("it cannot be opened"), [](World& world, const Captures&, const Table&) {
    const QString thread = role(timeline(world), messageRow(world), TimelineModel::ThreadRole).toString();
    expect(thread.isEmpty(), QStringLiteral("the message opens %1").arg(thread));
    const QString before = shownThread(world);
    click(world, QStringLiteral("messageAttribution"));
    expect(shownThread(world) == before, QStringLiteral("%1 opened").arg(shownThread(world)));
  });

  // Work a fork carried over, and what HAL-C2 recorded itself.
  step(QStringLiteral("the timeline shows work that (the fork's source thread did before the fork|HAL-C2 recorded rather than the agent)"),
       [](World& world, const Captures&, const Table&) {
         // A fork's history ends at the marker HAL-C2 adds, which no agent wrote.
         forkWithHistory(world);
         startRun(world, 10);
       });
  step(QStringLiteral("the work is marked %1").arg(q), [](World& world, const Captures& c, const Table&) {
    if (c[0] == QLatin1String("Inherited")) {
      const QList<QVariantMap> listed = calls(world);
      expect(std::any_of(listed.begin(), listed.end(), [](const QVariantMap& call) { return call.value(QStringLiteral("visibility")) == QLatin1String("Inherited"); }),
             QStringLiteral("no inherited call: %1").arg(describeCalls(world)));
      drawsText(world, QStringLiteral("workCallVisibility"), c[0]);
      return;
    }
    const QString marked = lastOf(world, QStringLiteral("marker"), TimelineModel::VisibilityRole).toString();
    expect(marked == c[0], QStringLiteral("the marker is marked \"%1\"; %2").arg(marked, describe(timeline(world))));
    drawsText(world, QStringLiteral("markerVisibility"), c[0]);
  });
  step(QStringLiteral("the user opens the work"), [](World& world, const Captures&, const Table&) {
    calls(world);
    click(world, QStringLiteral("workCall"));
  });
  step(QStringLiteral("the work says which thread it came from"), [](World& world, const Captures&, const Table&) {
    drawsText(world, QStringLiteral("workCallSource"), QStringLiteral("From Cart work"));
  });

  // Compaction.
  step(QStringLiteral("the context compaction (is in progress|finishes|fails|is cancelled|is interrupted)"), [](World& world, const Captures& c, const Table&) {
    const QHash<QString, QString> statuses{{QStringLiteral("is in progress"), QStringLiteral("running")}, {QStringLiteral("finishes"), QStringLiteral("completed")},
                                           {QStringLiteral("fails"), QStringLiteral("failed")}, {QStringLiteral("is cancelled"), QStringLiteral("cancelled")},
                                           {QStringLiteral("is interrupted"), QStringLiteral("interrupted")}};
    startRun(world);
    addItem(world, QStringLiteral("compaction"), {{QStringLiteral("status"), statuses.value(c[0])}});
  });
  step(QStringLiteral("the context compaction finishes with the summary %1").arg(q), [](World& world, const Captures& c, const Table&) {
    startRun(world);
    addItem(world, QStringLiteral("compaction"), {{QStringLiteral("summary"), c[0]}, {QStringLiteral("beforeTokenCount"), 120000}, {QStringLiteral("afterTokenCount"), 30000}});
  });
  step(QStringLiteral("the context compaction finishes from (\\d+) to (\\d+) tokens"), [](World& world, const Captures& c, const Table&) {
    startRun(world);
    addItem(world, QStringLiteral("compaction"), {{QStringLiteral("beforeTokenCount"), c[0].toInt()}, {QStringLiteral("afterTokenCount"), c[1].toInt()}});
  });
  step(QStringLiteral("the context compaction finishes knowing only that it ended at (\\d+) tokens"), [](World& world, const Captures& c, const Table&) {
    startRun(world);
    addItem(world, QStringLiteral("compaction"), {{QStringLiteral("afterTokenCount"), c[0].toInt()}});
  });
  step(QStringLiteral("the marker's detail reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString detail = lastOf(world, QStringLiteral("marker"), TimelineModel::TextRole).toString();
    expect(detail == c[0], QStringLiteral("the marker's detail reads \"%1\"").arg(detail));
  });

  // Handoff.
  step(QStringLiteral("the thread ran on %1 and then on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    publishProviders(world.mc, {provider(QStringLiteral("claude"), QStringLiteral("Claude"), QStringLiteral("claude-opus-4-6"), QStringLiteral("Opus")),
                                provider(QStringLiteral("codex"), QStringLiteral("Codex"), QStringLiteral("gpt-5.4"), QStringLiteral("GPT"))});
    world.sync();
    startRunOn(world, selectionOf(c[0]));
    addItem(world, QStringLiteral("assistant_message"), {{QStringLiteral("text"), QStringLiteral("Done on the first.")}});
    settleRun(world, QStringLiteral("completed"), 20);
    world.mc.part<Said>().note = c[1];
  });
  step(QStringLiteral("the context is handed to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject to = selectionOf(c[0]);
    startRunOn(world, to);
    addItem(world, QStringLiteral("handoff"), {{QStringLiteral("fromProviderInstanceIds"), QJsonArray{QStringLiteral("claude")}},
                                               {QStringLiteral("toProviderInstanceId"), to.value(QLatin1String("instanceId"))}});
  });
  step(QStringLiteral("the marker shows %1 and %1 with their models").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantList ends = lastOf(world, QStringLiteral("marker"), TimelineModel::HandoffRole).toList();
    expect(ends.size() == 2 && ends.at(0).toMap().value(QStringLiteral("provider")) == c[0] && ends.at(1).toMap().value(QStringLiteral("provider")) == c[1] &&
               !ends.at(0).toMap().value(QStringLiteral("model")).toString().isEmpty() && !ends.at(1).toMap().value(QStringLiteral("model")).toString().isEmpty(),
           QStringLiteral("the handoff's ends are %1").arg(show(ends)));
    drawsText(world, QStringLiteral("handoffEnd"), c[0]);
    drawsText(world, QStringLiteral("handoffEnd"), QStringLiteral("→ ") + c[1]);
  });
  step(QStringLiteral("pointing at either names its provider and model"), [](World& world, const Captures&, const Table&) {
    const QVariantList ends = lastOf(world, QStringLiteral("marker"), TimelineModel::HandoffRole).toList();
    QStringList tips;
    for (const QVariant& end : ends) tips.append(end.toMap().value(QStringLiteral("tooltip")).toString());
    expect(tips == QStringList{QStringLiteral("Claude · Opus"), QStringLiteral("Codex · GPT")}, QStringLiteral("pointing names %1").arg(tips.join(QStringLiteral(", "))));
  });
  step(QStringLiteral("the context handoff fails"), [](World& world, const Captures&, const Table&) {
    startRun(world);
    addItem(world, QStringLiteral("handoff"), {{QStringLiteral("status"), QStringLiteral("failed")}, {QStringLiteral("toProviderInstanceId"), QStringLiteral("codex")}});
  });
  step(QStringLiteral("the marker %1 is shown as a failure").arg(q), [](World& world, const Captures& c, const Table&) {
    const int row = lastRowOf(world, QStringLiteral("marker"));
    const QString title = role(timeline(world), row, TimelineModel::TitleRole).toString();
    const QString status = role(timeline(world), row, TimelineModel::StatusRole).toString();
    expect(title == c[0] && status == QLatin1String("failed"), QStringLiteral("the marker \"%1\" is %2").arg(title, status));
    drawsText(world, QStringLiteral("markerTitle"), c[0]);
    QQuickItem* drawnTitle = nullptr;
    for (QQuickItem* item : drawnAll(world, QStringLiteral("markerTitle"))) {
      if (item->property("text") == c[0]) drawnTitle = item;
    }
    QVariant error;
    for (QQuickItem* up = drawnTitle; up && !error.isValid(); up = up->parentItem()) error = up->property("errorColor");
    expect(error.isValid() && drawnTitle->property("color") == error, QStringLiteral("the marker is drawn in %1, not the error colour %2")
                                                                          .arg(drawnTitle->property("color").toString(), error.toString()));
  });

  // Fork markers.
  step(QStringLiteral("this thread was forked from another"), [](World& world, const Captures&, const Table&) { forkWithHistory(world); });
  step(QStringLiteral("the fork's history loaded before the thread said where it was forked from"), [](World& world, const Captures&, const Table&) {
    startRun(world, 300);
    addCommand(world, 1);
    addItem(world, QStringLiteral("assistant_message"), {{QStringLiteral("text"), QStringLiteral("The cart has a tax line.")}});
    settleRun(world, QStringLiteral("completed"), 30);
    listThread(world, kSource, QStringLiteral("Cart work"));
    changeThreadRow(world, {{QStringLiteral("forkedFrom"), QJsonObject{{QStringLiteral("type"), QStringLiteral("run")}, {QStringLiteral("threadId"), kSource},
                                                                       {QStringLiteral("runId"), QStringLiteral("run-1")}}}});
  });
  step(QStringLiteral("another thread was forked from this one"), [](World& world, const Captures&, const Table&) {
    listThread(world, QStringLiteral("thread-2"), QStringLiteral("Cart fork"));
    startRun(world);
    addItem(world, QStringLiteral("fork"), {{QStringLiteral("targetThreadId"), QStringLiteral("thread-2")}});
  });
  step(QStringLiteral("the user can open the other thread with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString action = lastOf(world, QStringLiteral("marker"), TimelineModel::ActionRole).toString();
    const QString other = lastOf(world, QStringLiteral("marker"), TimelineModel::ThreadRole).toString();
    expect(action == c[0], QStringLiteral("the marker offers \"%1\"").arg(action));
    drawsText(world, QStringLiteral("markerAction"), c[0]);
    click(world, QStringLiteral("markerAction"));
    world.waitFor([&] { return shownThread(world) == key(world, other); }, [&] { return QStringLiteral("%1 to open; %2 is shown").arg(other, shownThread(world)); });
  });

  // Created threads.
  step(QStringLiteral("the agent creates the thread %1").arg(q), [](World& world, const Captures& c, const Table&) {
    startRun(world);
    createThread(world, c[0]);
  });
  step(QStringLiteral("the agent creates a thread that has no title"), [](World& world, const Captures&, const Table&) {
    startRun(world);
    createThread(world, {});
  });
  step(QStringLiteral("the timeline shows %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(rowTexts(world).contains(c[0]), QStringLiteral("the timeline shows %1").arg(rowTexts(world).join(QStringLiteral(" | "))));
  });
  step(QStringLiteral("the user can open it with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString action = lastOf(world, QStringLiteral("marker"), TimelineModel::ActionRole).toString();
    expect(action == c[0], QStringLiteral("the marker offers \"%1\"").arg(action));
    drawsText(world, QStringLiteral("markerAction"), c[0]);
    click(world, QStringLiteral("markerAction"));
    world.waitFor([&] { return shownThread(world) == key(world, kCreated); }, [&] { return QStringLiteral("the created thread to open; %1 is shown").arg(shownThread(world)); });
  });
  step(QStringLiteral("the agent created the thread %1 and the timeline shows it as a resource").arg(q), [](World& world, const Captures& c, const Table&) {
    startRun(world, 60);
    createThread(world, c[0]);
    addItem(world, QStringLiteral("assistant_message"), {{QStringLiteral("text"), QStringLiteral("I made a thread for the tests.")}});
    settleRun(world, QStringLiteral("completed"), 30);
  });
  step(QStringLiteral("the card is titled %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString title = lastOf(world, QStringLiteral("resource"), TimelineModel::TitleRole).toString();
    expect(title == c[0], QStringLiteral("the card is titled \"%1\"").arg(title));
    drawsText(world, QStringLiteral("resourceTitle"), c[0]);
  });
  step(QStringLiteral("the user can open the thread with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString action = lastOf(world, QStringLiteral("resource"), TimelineModel::ActionRole).toString();
    expect(action == c[0], QStringLiteral("the card offers \"%1\"").arg(action));
    drawsText(world, QStringLiteral("resourceAction"), c[0]);
    click(world, QStringLiteral("resourceAction"));
    world.waitFor([&] { return shownThread(world) == key(world, kCreated); }, [&] { return QStringLiteral("the created thread to open; %1 is shown").arg(shownThread(world)); });
  });

  // Interrupts.
  step(QStringLiteral("the user interrupts the running turn with the message %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.setTime(now());
    startRun(world, 60);
    addCommand(world, 1, QStringLiteral("running"));
    addItem(world, QStringLiteral("run_interrupt_request"), {{QStringLiteral("message"), c[0]}});
  });
  step(QStringLiteral("the timeline shows %1 and the time").arg(q), [](World& world, const Captures& c, const Table&) {
    const QList<QVariantMap> listed = calls(world);
    expect(std::any_of(listed.begin(), listed.end(), [&](const QVariantMap& call) {
             return call.value(QStringLiteral("label")).toString() + QStringLiteral(" · ") + call.value(QStringLiteral("detail")).toString() == c[0] &&
                    !call.value(QStringLiteral("time")).toString().isEmpty();
           }),
           QStringLiteral("the timeline lists %1").arg(describeCalls(world)));
  });
  step(QStringLiteral("the run stops"), [](World& world, const Captures&, const Table&) {
    world.mc.part<Said>().runMessage = QStringLiteral("Stopped at the user's request");
    addItem(world, QStringLiteral("run_interrupt_result"), {{QStringLiteral("message"), world.mc.part<Said>().runMessage}});
    settleRun(world, QStringLiteral("interrupted"), 40);
  });
  step(QStringLiteral("the timeline shows %1 with the run's message").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString message = world.mc.part<Said>().runMessage;
    const QList<QVariantMap> listed = calls(world);
    expect(std::any_of(listed.begin(), listed.end(), [&](const QVariantMap& call) {
             return call.value(QStringLiteral("label")) == c[0] && call.value(QStringLiteral("detail")) == message;
           }),
           QStringLiteral("the timeline lists %1").arg(describeCalls(world)));
  });

  // A subagent's pointing card.
  step(QStringLiteral("the agent has a subagent that is (running|completed) and has (no model reported|the model %1|a result of (\\d+) characters|its own project|"
                      "its own branch, other than the parent's|its own worktree with no branch)")
           .arg(q),
       [](World& world, const Captures& c, const Table&) {
         world.setTime(now());
         startRun(world, 120);
         QJsonObject fields{{QStringLiteral("status"), c[0]}, {QStringLiteral("startedAt"), iso(now().addSecs(-42))}};
         QJsonObject child;
         const QString detail = c[1];
         if (detail == QLatin1String("no model reported")) {
           fields.insert(QStringLiteral("model"), QString());
         } else if (detail.startsWith(QLatin1String("the model"))) {
           fields.insert(QStringLiteral("model"), c[2]);
         } else if (detail.startsWith(QLatin1String("a result"))) {
           QString result;
           for (int i = 0; result.size() < c[3].toInt(); ++i) result += QChar(QLatin1Char('a' + i % 26));
           fields.insert(QStringLiteral("result"), result);
           fields.insert(QStringLiteral("completedAt"), iso(now()));
           world.mc.part<Said>().note = result;
         } else if (detail == QLatin1String("its own project")) {
           const QJsonObject project{{QStringLiteral("id"), QStringLiteral("billing")}, {QStringLiteral("title"), QStringLiteral("Billing")},
                                     {QStringLiteral("workspaceRoot"), QStringLiteral("/work/billing")}, {QStringLiteral("scripts"), QJsonArray()},
                                     {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")}, {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")}};
           world.mc.projects.insert(QStringLiteral("billing"), project);
           world.mc.sendRow(QStringLiteral("billing"), project, QStringLiteral("project"));
           child.insert(QStringLiteral("projectId"), QStringLiteral("billing"));
         } else if (detail.startsWith(QLatin1String("its own branch"))) {
           changeThreadRow(world, {{QStringLiteral("branch"), QStringLiteral("main")}});
           child.insert(QStringLiteral("branch"), QStringLiteral("tax-tests"));
         } else {
           child.insert(QStringLiteral("worktreePath"), QStringLiteral("/work/shop/.worktrees/tax-tests"));
         }
         listThread(world, QStringLiteral("thread-tax-tests"), QStringLiteral("Tax tests"), child);
         addSubagent(world, QStringLiteral("Tax tests"), fields);
       });
  step(QStringLiteral("the user points at the subagent in the parent's timeline"), [](World& world, const Captures&, const Table&) {
    QQuickItem* row = drawn(world, QStringLiteral("subagentRow"));
    QTest::mouseMove(&view(world).window(), view(world).at(row, 0.5, 0.5) + QPoint(0, 4));
    QTest::mouseMove(&view(world).window(), view(world).at(row, 0.5, 0.5));
    world.waitFor([&] { return !drawnAll(world, QStringLiteral("subagentCard")).isEmpty(); }, QStringLiteral("the subagent's card to show"));
  });
  step(QStringLiteral("the card shows (\"Not reported\" in place of the model|the model's name and how long it has worked|"
                      "its first 280 characters followed by an ellipsis|the subagent's project|the subagent's branch|the worktree's folder name)"),
       [](World& world, const Captures& c, const Table&) {
         const QVariantMap card = pointedCard(world);
         QString field;
         QString expected;
         if (c[0].startsWith(QLatin1String("\"Not reported\""))) {
           field = QStringLiteral("model");
           expected = QStringLiteral("Not reported");
         } else if (c[0].startsWith(QLatin1String("the model's"))) {
           expect(card.value(QStringLiteral("elapsed")) == QLatin1String("42s"), QStringLiteral("the card is %1").arg(show(card)));
           field = QStringLiteral("model");
           expected = QStringLiteral("model-b");
         } else if (c[0].startsWith(QLatin1String("its first"))) {
           field = QStringLiteral("preview");
           expected = world.mc.part<Said>().note.left(280) + QStringLiteral("…");
         } else if (c[0] == QLatin1String("the subagent's project")) {
           field = QStringLiteral("project");
           expected = QStringLiteral("Billing");
         } else {
           field = QStringLiteral("place");
           expected = QStringLiteral("tax-tests");
         }
         expect(card.value(field) == expected, QStringLiteral("the card is %1").arg(show(card)));
         world.waitFor([&] { return cardLines(world).contains(expected); },
                       [&] { return QStringLiteral("the card to read \"%1\"; it reads %2").arg(expected, cardLines(world).join(QStringLiteral(" | "))); });
       });

  // Subagent rows.
  step(QStringLiteral("a subagent ended with no answer and the note %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.part<Said>().note = c[0];
    addSubagent(world, QStringLiteral("Tax tests"), {{QStringLiteral("status"), QStringLiteral("completed")}, {QStringLiteral("result"), c[0]},
                                                     {QStringLiteral("completedAt"), iso(now())}});
  });
  step(QStringLiteral("the subagent row shows %1 and not that note").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString label = lastOf(world, QStringLiteral("subagent"), TimelineModel::StatusLabelRole).toString();
    const QString text = lastOf(world, QStringLiteral("subagent"), TimelineModel::TextRole).toString();
    expect(label == c[0] && !text.contains(world.mc.part<Said>().note), QStringLiteral("the row shows \"%1\" and \"%2\"").arg(label, text));
    drawn(world, QStringLiteral("subagentRow"));
  });
  step(QStringLiteral("the agent has a subagent that reported the progress %1").arg(q), [](World& world, const Captures& c, const Table&) {
    addSubagent(world, QStringLiteral("Tax tests"), {{QStringLiteral("progress"), c[0]}});
  });
  step(QStringLiteral("the row shows %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString label = lastOf(world, QStringLiteral("subagent"), TimelineModel::StatusLabelRole).toString();
    const QString text = lastOf(world, QStringLiteral("subagent"), TimelineModel::TextRole).toString();
    expect(label == c[0] && text == c[1], QStringLiteral("the row shows \"%1\" and \"%2\"").arg(label, text));
    drawn(world, QStringLiteral("subagentRow"));
  });
  step(QStringLiteral("the subagent finishes with the result %1").arg(q), [](World& world, const Captures& c, const Table&) {
    changeSubagent(world, QStringLiteral("task-tax-tests"),
                   {{QStringLiteral("status"), QStringLiteral("completed")}, {QStringLiteral("result"), c[0]}, {QStringLiteral("completedAt"), iso(now())}});
  });
  step(QStringLiteral("the row shows %1 instead of the progress").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString text = lastOf(world, QStringLiteral("subagent"), TimelineModel::TextRole).toString();
    expect(text == c[0], QStringLiteral("the row shows \"%1\"").arg(text));
  });
  step(QStringLiteral("the agent has a subagent that has not started a thread"), [](World& world, const Captures&, const Table&) {
    addSubagent(world, QStringLiteral("Tax tests"), {{QStringLiteral("childThreadId"), QJsonValue()}});
  });
  step(QStringLiteral("its row is shown with its status"), [](World& world, const Captures&, const Table&) {
    const QString label = lastOf(world, QStringLiteral("subagent"), TimelineModel::StatusLabelRole).toString();
    expect(label == QLatin1String("Working"), QStringLiteral("the row shows \"%1\"").arg(label));
    drawn(world, QStringLiteral("subagentRow"));
  });
  step(QStringLiteral("the row cannot be opened"), [](World& world, const Captures&, const Table&) {
    const QString thread = lastOf(world, QStringLiteral("subagent"), TimelineModel::ThreadRole).toString();
    expect(thread.isEmpty(), QStringLiteral("the row opens %1").arg(thread));
    const QString before = shownThread(world);
    click(world, QStringLiteral("subagentRow"));
    expect(shownThread(world) == before, QStringLiteral("%1 opened").arg(shownThread(world)));
  });

  // Groups of subagents.
  step(QStringLiteral("the agent started the subagents %1, %1 and %1 together").arg(q), [](World& world, const Captures& c, const Table&) {
    startTogether(world, {c[0], c[1], c[2]});
  });
  step(QStringLiteral("the agent started the subagents %1 and %1 together").arg(q), [](World& world, const Captures& c, const Table&) {
    startTogether(world, {c[0], c[1]});
  });
  step(QStringLiteral("the agent started five subagents together"), [](World& world, const Captures&, const Table&) {
    startTogether(world, {QStringLiteral("Tax tests"), QStringLiteral("Docs"), QStringLiteral("Lint"), QStringLiteral("Types"), QStringLiteral("Build")});
  });
  step(QStringLiteral("the agent started a group of subagents of which (.+)"), [](World& world, const Captures& c, const Table&) {
    const QHash<QString, QStringList> groups{
        {QStringLiteral("two are working and one is done"), {QStringLiteral("running"), QStringLiteral("running"), QStringLiteral("completed")}},
        {QStringLiteral("one is waiting for the user and one is not started yet"), {QStringLiteral("waiting"), QStringLiteral("pending")}},
        {QStringLiteral("two are done, one failed and one was stopped"),
         {QStringLiteral("completed"), QStringLiteral("completed"), QStringLiteral("failed"), QStringLiteral("cancelled")}},
        {QStringLiteral("one is working, one is done, one failed, one stopped, one idle"),
         {QStringLiteral("running"), QStringLiteral("completed"), QStringLiteral("failed"), QStringLiteral("cancelled"), QStringLiteral("idle")}},
    };
    if (!groups.contains(c[0])) fail(QStringLiteral("no such group: %1").arg(c[0]));
    const QStringList statuses = groups.value(c[0]);
    QStringList titles;
    for (qsizetype i = 0; i < statuses.size(); ++i) titles.append(QStringLiteral("Agent %1").arg(i + 1));
    startTogether(world, titles, statuses);
  });
  step(QStringLiteral("the group reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString summary = lastOf(world, QStringLiteral("subagents"), TimelineModel::TextRole).toString();
    expect(summary == c[0], QStringLiteral("the group reads \"%1\"").arg(summary));
    drawsText(world, QStringLiteral("subagentGroupSummary"), c[0]);
  });
  step(QStringLiteral("the timeline shows one entry reading %1 with how many are working, done, failed, stopped or idle").arg(q),
       [](World& world, const Captures& c, const Table&) {
         const QList<int> groups = rowsOf(world, QStringLiteral("subagents"));
         expect(groups.size() == 1 && rowsOf(world, QStringLiteral("subagent")).isEmpty(), describeGroup(world));
         const QString title = role(timeline(world), groups.first(), TimelineModel::TitleRole).toString();
         const QString summary = role(timeline(world), groups.first(), TimelineModel::TextRole).toString();
         expect(title == c[0] && summary == QLatin1String("3 working"), QStringLiteral("the entry reads \"%1\", \"%2\"").arg(title, summary));
         drawsText(world, QStringLiteral("subagentGroupTitle"), c[0]);
         drawsText(world, QStringLiteral("subagentGroupSummary"), summary);
       });
  step(QStringLiteral("the rows of the subagents are shown only once the user opens the entry"), [](World& world, const Captures&, const Table&) {
    expect(drawnAll(world, QStringLiteral("subagentRow")).isEmpty(), QStringLiteral("the rows are shown before the entry opens"));
    click(world, QStringLiteral("subagentGroup"));
    world.waitFor([&] { return rowsOf(world, QStringLiteral("subagent")).size() == 3 && drawnAll(world, QStringLiteral("subagentRow")).size() == 3; },
                  [&] { return QStringLiteral("the rows to show; %1").arg(describeGroup(world)); });
  });
  step(QStringLiteral("the entry stays open or closed the way the user left it while the thread is open"), [](World& world, const Captures&, const Table&) {
    changeSubagent(world, QStringLiteral("task-docs"), {{QStringLiteral("status"), QStringLiteral("completed")}, {QStringLiteral("completedAt"), iso(now())}});
    expect(lastOf(world, QStringLiteral("subagents"), TimelineModel::ExpandedRole).toBool() && rowsOf(world, QStringLiteral("subagent")).size() == 3,
           QStringLiteral("the entry closed as a subagent finished; %1").arg(describeGroup(world)));
    click(world, QStringLiteral("subagentGroup"));
    changeSubagent(world, QStringLiteral("task-lint"), {{QStringLiteral("status"), QStringLiteral("completed")}, {QStringLiteral("completedAt"), iso(now())}});
    expect(!lastOf(world, QStringLiteral("subagents"), TimelineModel::ExpandedRole).toBool() && rowsOf(world, QStringLiteral("subagent")).isEmpty(),
           QStringLiteral("the entry opened as a subagent finished; %1").arg(describeGroup(world)));
    world.waitFor([&] { return drawnAll(world, QStringLiteral("subagentRow")).isEmpty(); }, QStringLiteral("the rows to hide"));
  });
  step(QStringLiteral("%1 started at (\\d\\d:\\d\\d:\\d\\d) and finished at (\\d\\d:\\d\\d:\\d\\d)").arg(q), [](World& world, const Captures& c, const Table&) {
    changeSubagent(world, QStringLiteral("task-") + slugOf(c[0]),
                   {{QStringLiteral("status"), QStringLiteral("completed")}, {QStringLiteral("startedAt"), QStringLiteral("2026-09-23T%1Z").arg(c[1])},
                    {QStringLiteral("completedAt"), QStringLiteral("2026-09-23T%1Z").arg(c[2])}});
  });
  step(QStringLiteral("%1 started at (\\d\\d:\\d\\d:\\d\\d) and is still working").arg(q), [](World& world, const Captures& c, const Table&) {
    changeSubagent(world, QStringLiteral("task-") + slugOf(c[0]),
                   {{QStringLiteral("status"), QStringLiteral("running")}, {QStringLiteral("startedAt"), QStringLiteral("2026-09-23T%1Z").arg(c[1])}});
  });
  step(QStringLiteral("a second passes while the group works"), [](World& world, const Captures&, const Table&) {
    // The model's own once-a-second timer, without waiting a second for it.
    expect(timeline(world).spansTicking(), QStringLiteral("the group's span is not moving; %1").arg(describeGroup(world)));
    world.setTime(world.now().addSecs(1));
    timeline(world).tickSpans();
  });
  step(QStringLiteral("the group's span reads (.+) on screen"), [](World& world, const Captures& c, const Table&) {
    drawsText(world, QStringLiteral("subagentGroupSpan"), c[0]);
  });
  step(QStringLiteral("the span stands still once every subagent of the group has finished"), [](World& world, const Captures&, const Table&) {
    for (const QString& title : {QStringLiteral("Tax tests"), QStringLiteral("Docs")}) {
      changeSubagent(world, QStringLiteral("task-") + slugOf(title),
                     {{QStringLiteral("status"), QStringLiteral("completed")}, {QStringLiteral("completedAt"), iso(world.now().toUTC())}});
    }
    expect(!timeline(world).spansTicking(), QStringLiteral("the group's span still moves; %1").arg(describeGroup(world)));
  });
  step(QStringLiteral("both have finished but the end time of %1 was not reported").arg(q), [](World& world, const Captures& c, const Table&) {
    for (const QString& title : {QStringLiteral("Tax tests"), QStringLiteral("Docs")}) {
      changeSubagent(world, QStringLiteral("task-") + slugOf(title),
                     {{QStringLiteral("status"), QStringLiteral("completed")}, {QStringLiteral("completedAt"), title == c[0] ? QJsonValue() : QJsonValue(iso(now()))}});
    }
  });
  step(QStringLiteral("the user looks at the group"), [](World& world, const Captures&, const Table&) { drawn(world, QStringLiteral("subagentGroup")); });
  step(QStringLiteral("the group shows a span of (.+)"), [](World& world, const Captures& c, const Table&) {
    const QString span = lastOf(world, QStringLiteral("subagents"), TimelineModel::SpanRole).toString();
    expect(span == c[0], QStringLiteral("the group shows a span of \"%1\"").arg(span));
    drawsText(world, QStringLiteral("subagentGroupSpan"), c[0]);
  });
  step(QStringLiteral("the group shows no span"), [](World& world, const Captures&, const Table&) {
    const QString span = lastOf(world, QStringLiteral("subagents"), TimelineModel::SpanRole).toString();
    expect(span.isEmpty() && drawnAll(world, QStringLiteral("subagentGroupSpan")).isEmpty(), QStringLiteral("the group shows a span of \"%1\"").arg(span));
  });
  step(QStringLiteral("it shows the avatars of the first three and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantList avatars = lastOf(world, QStringLiteral("subagents"), TimelineModel::AvatarsRole).toList();
    QStringList titles;
    for (const QVariant& avatar : avatars) titles.append(avatar.toMap().value(QStringLiteral("title")).toString());
    expect(titles == QStringList{QStringLiteral("Tax tests"), QStringLiteral("Docs"), QStringLiteral("Lint")},
           QStringLiteral("the avatars are of %1").arg(titles.join(QStringLiteral(", "))));
    world.waitFor([&] { return drawnAll(world, QStringLiteral("subagentAvatar")).size() == 3; },
                  [&] { return QStringLiteral("three avatars; %1 are drawn").arg(drawnAll(world, QStringLiteral("subagentAvatar")).size()); });
    drawsText(world, QStringLiteral("subagentMore"), c[0]);
  });

  // Titles.
  step(QStringLiteral("a subagent whose title is %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.setTime(now());
    startRun(world, 60);
    const QString child = QStringLiteral("thread-sub");
    listThread(world, child, c[0],
               {{QStringLiteral("lineage"), QJsonObject{{QStringLiteral("rootThreadId"), kThread}, {QStringLiteral("parentThreadId"), kThread},
                                                         {QStringLiteral("relationshipToParent"), QStringLiteral("subagent")}}}});
    // A subagent of the subagent, whose lineage names it as its parent.
    listThread(world, QStringLiteral("thread-sub-sub"), QStringLiteral("Grandchild"),
               {{QStringLiteral("lineage"), QJsonObject{{QStringLiteral("rootThreadId"), kThread}, {QStringLiteral("parentThreadId"), child},
                                                         {QStringLiteral("relationshipToParent"), QStringLiteral("subagent")}}}});
    const QString id = QStringLiteral("task-sub");
    set(world, QStringLiteral("subagent"), id,
        {{QStringLiteral("id"), id}, {QStringLiteral("threadId"), kThread}, {QStringLiteral("runId"), world.mc.part<FakeStreams>().run},
         {QStringLiteral("childThreadId"), child}, {QStringLiteral("title"), c[0]}, {QStringLiteral("prompt"), QStringLiteral("fix the cart")},
         {QStringLiteral("model"), QStringLiteral("gpt-5.5")}, {QStringLiteral("status"), QStringLiteral("running")},
         {QStringLiteral("startedAt"), iso(now().addSecs(-30))}, {QStringLiteral("updatedAt"), iso(now())}});
    addItem(world, QStringLiteral("subagent"),
            {{QStringLiteral("id"), QStringLiteral("turn-item:subagent:") + id}, {QStringLiteral("subagentId"), id}, {QStringLiteral("childThreadId"), child},
             {QStringLiteral("title"), c[0]}, {QStringLiteral("prompt"), QStringLiteral("fix the cart")}, {QStringLiteral("status"), QStringLiteral("running")}});
  });
  step(QStringLiteral("the user sees it in the timeline, the lineage or the agents list"), [](World& world, const Captures&, const Table&) { world.sync(); });
  step(QStringLiteral("it is shown as %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString inTimeline = lastOf(world, QStringLiteral("subagent"), TimelineModel::TitleRole).toString();
    expect(inTimeline == c[0], QStringLiteral("the timeline shows \"%1\"").arg(inTimeline));
    AgentsModel& listed = agents(world);
    QStringList inAgents;
    for (int row = 0; row < listed.rowCount(); ++row) inAgents.append(listed.value(row, AgentsModel::TitleRole).toString());
    expect(inAgents.contains(c[0]), QStringLiteral("the agents list shows %1").arg(inAgents.join(QStringLiteral(", "))));
    // The subagent's own subagent names it as its parent.
    world.native().controller<NavigationController>()->open(NavigationController::Route::thread(key(world, QStringLiteral("thread-sub-sub"))));
    world.waitFor([&] {
      return world.state(QStringLiteral("lineage")).toMap().value(QStringLiteral("parent")).toMap().value(QStringLiteral("title")) == c[0];
    }, [&] { return QStringLiteral("the lineage to name \"%1\"; it is %2").arg(c[0], show(world.state(QStringLiteral("lineage")))); });
  });

  // The agents-working banner.
  step(QStringLiteral("the Agents tab is closed"), [](World& world, const Captures&, const Table&) {
    view(world);
    world.sync();
    const QString active = world.state(QStringLiteral("panel")).toMap().value(QStringLiteral("activeId")).toString();
    expect(active != QLatin1String("agents"), QStringLiteral("the Agents tab is open"));
  });
  step(QStringLiteral("the user chooses View on the agents-working banner"), [](World& world, const Captures&, const Table&) {
    drawn(world, QStringLiteral("agentsBanner"));
    click(world, QStringLiteral("agentsBannerView"));
  });
  step(QStringLiteral("the Agents tab opens"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.state(QStringLiteral("panel")).toMap().value(QStringLiteral("activeId")) == QLatin1String("agents"); },
                  [&] { return QStringLiteral("the Agents tab to open; the panel is %1").arg(show(world.state(QStringLiteral("panel")))); });
  });
});

}  // namespace
