// What the timeline makes of the agent's work once a turn settles
// (features/timeline/tool-calls.feature, streaming.feature,
// approvals-and-questions.feature): groups of calls that read as a summary
// and open into their calls, an ACP agent's reads and searches, a turn the
// user stopped here, a long message of the user's, and several approvals
// answered one at a time. The stream is Stream.h's; the rows are read from
// the TimelineModel and from the Timeline brick drawing it.

#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>
#include <QRegularExpression>
#include <QTest>

#include <functional>
#include <memory>

#include "Brick.h"
#include "Harness.h"
#include "Stream.h"
#include "Turn.h"
#include "World.h"

namespace {

using namespace stream;

const QString kSend = QStringLiteral("mcp__hal-c2__hal_c2_thread_send");

QList<int> rowsOf(TimelineModel& model, const QString& kind) {
  QList<int> rows;
  for (int row = 0; row < model.rowCount(); ++row) {
    if (role(model, row, TimelineModel::KindRole).toString() == kind) rows.append(row);
  }
  return rows;
}

int lastRowOf(World& world, const QString& kind) {
  TimelineModel& model = timeline(world);
  const QList<int> rows = rowsOf(model, kind);
  if (rows.isEmpty()) fail(QStringLiteral("no %1 row; %2").arg(kind, describe(model)));
  return rows.last();
}

QVariantList entries(World& world) {
  return role(timeline(world), lastRowOf(world, QStringLiteral("work")), TimelineModel::EntriesRole).toList();
}

QString summary(World& world) {
  return role(timeline(world), lastRowOf(world, QStringLiteral("work")), TimelineModel::SummaryRole).toString();
}

// The open thread's timeline as the Timeline brick draws it.
Brick& timelineBrick(World& world) {
  if (!world.brick) {
    world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nTimeline {}\n", QSize(820, 1400));
    world.brick->root()->setProperty("model", QVariant::fromValue(static_cast<QObject*>(&timeline(world))));
  }
  return *world.brick;
}

void collect(QQuickItem* item, const QString& name, QList<QQuickItem*>& out) {
  if (item->objectName() == name) out.append(item);
  for (QQuickItem* child : item->childItems()) collect(child, name, out);
}

// The visible item named `name` the brick drew last.
QQuickItem* drawn(World& world, const QString& name) {
  Brick& brick = timelineBrick(world);
  QQuickItem* found = nullptr;
  world.waitFor([&] {
    QList<QQuickItem*> items;
    collect(brick.window().contentItem(), name, items);
    for (QQuickItem* item : std::as_const(items)) {
      if (item->isVisible()) found = item;
    }
    return found != nullptr;
  }, QStringLiteral("the timeline to draw %1").arg(name));
  return found;
}

void click(World& world, QQuickItem* item) {
  Brick& brick = timelineBrick(world);
  QTest::mouseClick(&brick.window(), Qt::LeftButton, Qt::NoModifier, brick.at(item, 0.3, 0.5));
}

void sendMessage(World& world, const QString& thread, int n, bool failed = false) {
  QJsonObject fields{{QStringLiteral("toolName"), kSend},
                     {QStringLiteral("input"), QJsonObject{{QStringLiteral("threadId"), thread}, {QStringLiteral("message"), QStringLiteral("Check the tax line")}}}};
  if (failed) {
    // An MCP error comes back as the call's result, the call itself completed.
    fields.insert(QStringLiteral("output"), QJsonObject{{QStringLiteral("isError"), true},
                                                        {QStringLiteral("content"), QJsonArray{QJsonObject{{QStringLiteral("type"), QStringLiteral("text")}, {QStringLiteral("text"), QStringLiteral("thread not found")}}}}});
  } else {
    fields.insert(QStringLiteral("output"), QJsonObject{{QStringLiteral("structuredContent"),
                                                         QJsonObject{{QStringLiteral("threadId"), thread}, {QStringLiteral("messageId"), QStringLiteral("message-%1").arg(n)}}}});
  }
  addItem(world, QStringLiteral("dynamic_tool"), fields);
}

// The turn's reply, and its end: the work folds behind how long it took.
void finishTurn(World& world) {
  addItem(world, QStringLiteral("assistant_message"), {{QStringLiteral("text"), QStringLiteral("Done.")}});
  settleRun(world, QStringLiteral("completed"), 30);
}

// What the group's line reads: its summary, or a lone call's own label.
QString groupLine(World& world) {
  const QString text = summary(world);
  const QVariantList shown = entries(world);
  return !text.isEmpty() || shown.size() != 1 ? text : shown.first().toMap().value(QStringLiteral("label")).toString();
}

// The latest call the group shows.
QVariantMap lastCall(World& world) {
  const QVariantList shown = entries(world);
  if (shown.isEmpty()) fail(QStringLiteral("the group shows no call; %1").arg(describe(timeline(world))));
  return shown.last().toMap();
}

// A "quoted" step argument whose \" and \\ are escapes, as an example table writes a command.
const QString kEscaped = QStringLiteral(R"re("((?:[^"\\]|\\.)*)")re");
QString unescaped(const QString& quoted) {
  static const QRegularExpression escape(QStringLiteral(R"(\\(.))"));
  return QString(quoted).replace(escape, QStringLiteral("\\1"));
}

// A call to one of HAL-C2's own tools, as Codex names it, that returned `result`.
QJsonObject halC2Call(const QString& tool, const QJsonObject& input, const QJsonObject& result = {}) {
  return {{QStringLiteral("toolName"), QStringLiteral("mcp__hal-c2__") + tool},
          {QStringLiteral("input"), input},
          {QStringLiteral("output"), QJsonObject{{QStringLiteral("structuredContent"), result}}}};
}

// A call through a browser, the computer or an integration, as the MC names it (codex/tool_presentation.ex).
QJsonObject sourcedCall(const QString& key, const QString& name, const QString& kind) {
  return {{QStringLiteral("toolName"), QStringLiteral("mcp__%1__navigate").arg(key)},
          {QStringLiteral("toolSource"), QJsonObject{{QStringLiteral("key"), key}, {QStringLiteral("name"), name}, {QStringLiteral("kind"), kind}}}};
}

// The calls an activity group holds, by how a scenario describes them.
void addCalls(World& world, const QString& calls) {
  const auto tool = [&](const QJsonObject& fields) { addItem(world, QStringLiteral("dynamic_tool"), fields); };
  const auto edit = [&](const QString& file) { addItem(world, QStringLiteral("file_change"), {{QStringLiteral("fileName"), file}}); };
  const auto web = [&] { addItem(world, QStringLiteral("web_search"), {{QStringLiteral("patterns"), QJsonArray{QStringLiteral("vat rates")}}}); };
  const auto thought = [&] { addItem(world, QStringLiteral("reasoning"), {{QStringLiteral("text"), QString()}}); };
  const auto integration = [&](const QString& name) { tool(sourcedCall(name.toLower(), name, QStringLiteral("integration"))); };
  const QHash<QString, std::function<void()>> known{
      {QStringLiteral("one file read"), [&] {
         addItem(world, QStringLiteral("file_search"), {{QStringLiteral("pattern"), QStringLiteral("cart.ts")},
                                                       {QStringLiteral("results"), QJsonArray{QJsonObject{{QStringLiteral("fileName"), QStringLiteral("cart.ts")}}}}});
       }},
      {QStringLiteral("edits to three different files"), [&] {
         for (const char* file : {"src/a.ts", "src/b.ts", "src/c.ts"}) edit(QLatin1String(file));
       }},
      {QStringLiteral("two edits to the same file"), [&] {
         edit(QStringLiteral("src/cart.ts"));
         edit(QStringLiteral("src/cart.ts"));
       }},
      {QStringLiteral("one command"), [&] { addCommand(world, 1); }},
      {QStringLiteral("two web searches"), [&] {
         web();
         web();
       }},
      {QStringLiteral("one search of the project's code"), [&] {
         addItem(world, QStringLiteral("file_search"), {{QStringLiteral("pattern"), QStringLiteral("taxLine")}, {QStringLiteral("results"), QJsonArray{}}});
       }},
      {QStringLiteral("three browser calls"), [&] {
         for (int n = 0; n < 3; ++n) tool(halC2Call(QStringLiteral("preview_open"), {{QStringLiteral("url"), QStringLiteral("http://localhost:3000")}}));
       }},
      {QStringLiteral("two device controls"), [&] {
         for (int n = 0; n < 2; ++n) tool(halC2Call(QStringLiteral("device_screenshot"), {}));
       }},
      {QStringLiteral("one tool with no more specific kind"), [&] { tool({{QStringLiteral("toolName"), QStringLiteral("lookup_rates")}}); }},
      {QStringLiteral("two progress updates"), [&] {
         addItem(world, QStringLiteral("system_notice"), {{QStringLiteral("message"), QStringLiteral("Indexing")}});
         addItem(world, QStringLiteral("system_notice"), {{QStringLiteral("message"), QStringLiteral("Indexed")}});
       }},
      {QStringLiteral("one thread the agent created"), [&] {
         tool(halC2Call(QStringLiteral("create_threads"), {}, {{QStringLiteral("threads"), QJsonArray{QJsonObject{{QStringLiteral("threadId"), QStringLiteral("thread-9")}}}}}));
       }},
      {QStringLiteral("two links of a pull request and one check"), [&] {
         for (int n = 1; n <= 2; ++n) tool(halC2Call(QStringLiteral("link_pull_request"), {{QStringLiteral("url"), QStringLiteral("https://github.com/o/r/pull/%1").arg(n)}}));
         tool(halC2Call(QStringLiteral("list_thread_pull_requests"), {}));
       }},
      {QStringLiteral("one pull request unlinked"), [&] {
         tool(halC2Call(QStringLiteral("unlink_pull_request"), {{QStringLiteral("url"), QStringLiteral("https://github.com/o/r/pull/1")}}));
       }},
      {QStringLiteral("two checks of the linked pull requests"), [&] {
         for (int n = 0; n < 2; ++n) tool(halC2Call(QStringLiteral("list_thread_pull_requests"), {}));
       }},
      {QStringLiteral("two thoughts and one command"), [&] {
         thought();
         thought();
         addCommand(world, 1);
       }},
      {QStringLiteral("one thought"), thought},
      {QStringLiteral("three thoughts"), [&] {
         for (int n = 0; n < 3; ++n) thought();
       }},
      {QStringLiteral("two calls through the \"Chrome\" integration and one command"), [&] {
         integration(QStringLiteral("Chrome"));
         integration(QStringLiteral("Chrome"));
         addCommand(world, 1);
       }},
      {QStringLiteral("calls through the \"Chrome\" and \"Slack\" integrations"), [&] {
         integration(QStringLiteral("Chrome"));
         integration(QStringLiteral("Slack"));
       }},
      {QStringLiteral("calls through the \"Chrome\", \"Slack\" and \"Linear\" integrations"), [&] {
         integration(QStringLiteral("Chrome"));
         integration(QStringLiteral("Slack"));
         integration(QStringLiteral("Linear"));
       }},
      {QStringLiteral("calls through the built-in browser and computer controls"), [&] {
         tool(sourcedCall(QStringLiteral("browser"), QStringLiteral("Browser"), QStringLiteral("browser")));
         tool(sourcedCall(QStringLiteral("computer"), QStringLiteral("Computer Use"), QStringLiteral("computer")));
       }},
      {QStringLiteral("commands, file changes and four web searches"), [&] {
         addCommand(world, 1);
         addCommand(world, 2);
         edit(QStringLiteral("src/cart.ts"));
         for (int n = 0; n < 4; ++n) web();
       }},
      {QStringLiteral("two tasks delegated to subagents"), [&] {
         for (int n = 1; n <= 2; ++n) tool(halC2Call(QStringLiteral("delegate_task"), {}, {{QStringLiteral("taskId"), QStringLiteral("task-%1").arg(n)}}));
       }},
      {QStringLiteral("the same task cancelled twice"), [&] {
         for (int n = 0; n < 2; ++n) tool(halC2Call(QStringLiteral("task_cancel"), {{QStringLiteral("taskId"), QStringLiteral("task-1")}}));
       }},
      {QStringLiteral("one thread read and the same thread read again"), [&] {
         for (int n = 0; n < 2; ++n) tool(halC2Call(QStringLiteral("hal_c2_thread_read"), {{QStringLiteral("threadId"), QStringLiteral("thread-2")}}));
       }},
      {QStringLiteral("one wait on a thread"), [&] {
         tool(halC2Call(QStringLiteral("hal_c2_thread_wait"), {{QStringLiteral("threadId"), QStringLiteral("thread-2")}}));
       }},
      {QStringLiteral("one scheduled task created"), [&] {
         tool(halC2Call(QStringLiteral("schedule_task"), {}, {{QStringLiteral("scheduledTaskId"), QStringLiteral("schedule-1")}}));
       }},
      {QStringLiteral("one scheduled task run on request"), [&] {
         tool(halC2Call(QStringLiteral("run_scheduled_task_now"), {{QStringLiteral("scheduledTaskId"), QStringLiteral("schedule-1")}}));
       }},
      {QStringLiteral("a queued message edited and another reordered"), [&] {
         tool(halC2Call(QStringLiteral("hal_c2_queue_edit"), {{QStringLiteral("queuedRunId"), QStringLiteral("queued-1")}}));
         tool(halC2Call(QStringLiteral("hal_c2_queue_reorder"), {{QStringLiteral("queuedRunId"), QStringLiteral("queued-2")}}));
       }},
      {QStringLiteral("a pending question answered"), [&] {
         tool(halC2Call(QStringLiteral("hal_c2_pending_request_respond"), {{QStringLiteral("requestId"), QStringLiteral("request-1")}}));
       }},
      {QStringLiteral("one handoff to a worktree"), [&] {
         tool(halC2Call(QStringLiteral("hal_c2_worktree_handoff"), {{QStringLiteral("worktreePath"), QStringLiteral("/work/shop-tax")}}));
       }},
      {QStringLiteral("one project registered and one cloned"), [&] {
         tool(halC2Call(QStringLiteral("hal_c2_project_create"), {}, {{QStringLiteral("id"), QStringLiteral("project-2")}}));
         tool(halC2Call(QStringLiteral("hal_c2_project_clone"), {{QStringLiteral("cwd"), QStringLiteral("/work/rates")}}));
       }},
      {QStringLiteral("two attachments sent to one thread"), [&] {
         tool(halC2Call(QStringLiteral("hal_c2_thread_send_attachments"),
                        {{QStringLiteral("threadId"), QStringLiteral("thread-2")}, {QStringLiteral("attachments"), QJsonArray{QStringLiteral("a.png"), QStringLiteral("b.png")}}},
                        {{QStringLiteral("messageId"), QStringLiteral("message-1")}}));
       }},
      {QStringLiteral("two attempts to send a message that both failed"), [&] {
         // Neither said which thread it was for.
         for (int n = 0; n < 2; ++n) {
           tool({{QStringLiteral("toolName"), kSend}, {QStringLiteral("status"), QStringLiteral("failed")},
                 {QStringLiteral("input"), QJsonObject{{QStringLiteral("message"), QStringLiteral("Check the tax line")}}}});
         }
       }},
      {QStringLiteral("a command that exited with a failure"), [&] {
         addCommand(world, 1);
         addItem(world, QStringLiteral("command_execution"), {{QStringLiteral("input"), QStringLiteral("bun lint")}, {QStringLiteral("exitCode"), 2}});
       }},
  };
  const auto found = known.constFind(calls);
  if (found == known.cend()) fail(QStringLiteral("no calls described as \"%1\"").arg(calls));
  (*found)();
}

void openFold(World& world) {
  TimelineModel& model = timeline(world);
  const int fold = lastRowOf(world, QStringLiteral("fold"));
  if (!role(model, fold, TimelineModel::ExpandedRole).toBool()) model.toggle(role(model, fold, TimelineModel::IdRole).toString());
}

const Steps steps([] {
  const QString q = kQuoted;

  // Summaries.
  step(QStringLiteral("the agent ran two commands and sent messages to three threads"), [](World& world, const Captures&, const Table&) {
    startRun(world, 30);
    addCommand(world, 1);
    addCommand(world, 2);
    for (int n = 1; n <= 3; ++n) sendMessage(world, QStringLiteral("thread-%1").arg(n + 1), n);
    finishTurn(world);
  });
  step(QStringLiteral("the agent ran commands, changed files, searched the web and read files"), [](World& world, const Captures&, const Table&) {
    startRun(world, 30);
    addItem(world, QStringLiteral("dynamic_tool"), {{QStringLiteral("toolName"), QStringLiteral("Read")}, {QStringLiteral("input"), QJsonObject{{QStringLiteral("path"), QStringLiteral("src/cart.ts")}}}});
    addItem(world, QStringLiteral("web_search"), {{QStringLiteral("patterns"), QJsonArray{QStringLiteral("vat rates")}}});
    addCommand(world, 1);
    addCommand(world, 2);
    addItem(world, QStringLiteral("file_change"), {{QStringLiteral("fileName"), QStringLiteral("src/cart.ts")}});
    finishTurn(world);
  });
  step(QStringLiteral("the agent sent three messages and one of them failed"), [](World& world, const Captures&, const Table&) {
    startRun(world, 30);
    sendMessage(world, QStringLiteral("thread-2"), 1);
    sendMessage(world, QStringLiteral("thread-2"), 2, true);
    sendMessage(world, QStringLiteral("thread-2"), 3);
    finishTurn(world);
  });
  step(QStringLiteral("the user reads the activity group"), [](World& world, const Captures&, const Table&) {
    openFold(world);
    // Collapsed, the group is its summary alone; a lone call is its own line.
    const QVariantList shown = entries(world);
    expect(shown.isEmpty() || role(timeline(world), lastRowOf(world, QStringLiteral("work")), TimelineModel::HiddenCountRole).toInt() == 0,
           QStringLiteral("the collapsed group shows %1").arg(show(shown)));
  });
  step(QStringLiteral("it reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(groupLine(world) == c[0], QStringLiteral("the group reads \"%1\"").arg(groupLine(world)));
    Brick& brick = timelineBrick(world);
    world.waitFor([&] { return brick.shows(c[0]); }, QStringLiteral("the timeline to draw \"%1\"").arg(c[0]));
  });
  step(QStringLiteral("the summary names commands and file changes"), [](World& world, const Captures&, const Table&) {
    const QString text = summary(world);
    expect(text.startsWith(QLatin1String("Ran 2 commands, changed 1 file")), QStringLiteral("the group reads \"%1\"").arg(text));
  });
  step(QStringLiteral("it counts the rest instead of naming them"), [](World& world, const Captures&, const Table&) {
    const QString text = summary(world);
    expect(text == QLatin1String("Ran 2 commands, changed 1 file, and performed 2 other actions"), QStringLiteral("the group reads \"%1\"").arg(text));
    Brick& brick = timelineBrick(world);
    world.waitFor([&] { return brick.shows(text); }, QStringLiteral("the timeline to draw \"%1\"").arg(text));
  });
  step(QStringLiteral("the summary counts two messages sent"), [](World& world, const Captures&, const Table&) {
    const QString text = summary(world);
    expect(text == QLatin1String("Sent 2 messages to 1 thread"), QStringLiteral("the group reads \"%1\"").arg(text));
    expect(role(timeline(world), lastRowOf(world, QStringLiteral("work")), TimelineModel::SummaryFailedRole).toBool(),
           QStringLiteral("the group does not say a call failed"));
  });

  // What a call is labelled by.
  step(QStringLiteral("the agent ran %1 through a shell and changed a file in the workspace").arg(q), [](World& world, const Captures& c, const Table&) {
    startRun(world, 30);
    addItem(world, QStringLiteral("command_execution"), {{QStringLiteral("input"), QStringLiteral("bash -lc '%1'").arg(c[0])}, {QStringLiteral("exitCode"), 0}});
    const QString root = world.mc.projects.value(kProject).value(QLatin1String("workspaceRoot")).toString();
    addItem(world, QStringLiteral("file_change"), {{QStringLiteral("fileName"), root + QStringLiteral("/src/cart.ts")}});
    finishTurn(world);
    openFold(world);
  });
  step(QStringLiteral("the user opens the activity group"), [](World& world, const Captures&, const Table&) {
    click(world, drawn(world, QStringLiteral("workGroupToggle")));
    world.waitFor([&] { return entries(world).size() == 2; }, [&] { return QStringLiteral("the group to open; %1").arg(describe(timeline(world))); });
  });
  step(QStringLiteral("the command is labelled %1 and the file change %2").arg(q, q), [](World& world, const Captures& c, const Table&) {
    const QVariantList calls = entries(world);
    expect(calls.at(0).toMap().value(QStringLiteral("label")) == c[0] && calls.at(1).toMap().value(QStringLiteral("label")) == c[1],
           QStringLiteral("the calls read %1").arg(show(calls)));
  });

  // A usage limit on the thread's timeline.
  step(QStringLiteral("the provider stopped the turn at its usage limit, resetting at the top of an hour"), [](World& world, const Captures&, const Table&) {
    startRun(world, 30);
    addItem(world, QStringLiteral("error"),
            {{QStringLiteral("status"), QStringLiteral("failed")},
             {QStringLiteral("failure"), QJsonObject{{QStringLiteral("class"), QStringLiteral("usage_limit")},
                                                     {QStringLiteral("message"), QStringLiteral("You've hit your usage limit.")},
                                                     {QStringLiteral("resetAt"), iso(now().addSecs(3 * 3600))}}}});
    settleRun(world, QStringLiteral("failed"), 5);
  });
  step(QStringLiteral("the timeline shows one warning line naming when to retry"), [](World& world, const Captures&, const Table&) {
    TimelineModel& model = timeline(world);
    const int row = lastRowOf(world, QStringLiteral("error"));
    const QString title = role(model, row, TimelineModel::TitleRole).toString();
    expect(title.startsWith(QLatin1String("Usage limit reached. Retry after ")) && title.endsWith(QLatin1Char('.')) &&
               role(model, row, TimelineModel::TextRole).toString().isEmpty() && role(model, row, TimelineModel::WarningRole).toBool(),
           QStringLiteral("the error row is %1").arg(describe(model)));
  });

  // Opening a group.
  step(QStringLiteral("a collapsed group of tool calls"), [](World& world, const Captures&, const Table&) {
    startRun(world, 30);
    addItem(world, QStringLiteral("command_execution"), {{QStringLiteral("input"), QStringLiteral("bun test cart")}, {QStringLiteral("exitCode"), 0}});
    addItem(world, QStringLiteral("command_execution"), {{QStringLiteral("input"), QStringLiteral("bun lint")}, {QStringLiteral("status"), QStringLiteral("failed")}, {QStringLiteral("exitCode"), 2}});
    sendMessage(world, QStringLiteral("thread-2"), 1);
    finishTurn(world);
    openFold(world);
    expect(entries(world).isEmpty() && !summary(world).isEmpty(), QStringLiteral("the group is not collapsed; %1").arg(describe(timeline(world))));
  });
  const auto toggleGroup = [](World& world, const Captures&, const Table&) {
    // The line the user clicks: the group's summary.
    click(world, drawn(world, QStringLiteral("workGroupToggle")));
  };
  step(QStringLiteral("the user opens the group"), toggleGroup);
  step(QStringLiteral("the user closes the group"), toggleGroup);
  step(QStringLiteral("each call shows its command or input, its status and its exit code"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return entries(world).size() == 3; }, [&] { return QStringLiteral("the group to open; %1").arg(describe(timeline(world))); });
    const QVariantList calls = entries(world);
    const QVariantMap passed = calls.at(0).toMap();
    const QVariantMap failed = calls.at(1).toMap();
    const QVariantMap sent = calls.at(2).toMap();
    expect(passed.value(QStringLiteral("command")) == QLatin1String("bun test cart") && passed.value(QStringLiteral("status")) == QLatin1String("completed") &&
               passed.value(QStringLiteral("exitCode")) == 0,
           QStringLiteral("the first call is %1").arg(show(passed)));
    expect(failed.value(QStringLiteral("command")) == QLatin1String("bun lint") && failed.value(QStringLiteral("statusLabel")) == QLatin1String("Failed") &&
               failed.value(QStringLiteral("exitCode")) == 2,
           QStringLiteral("the second call is %1").arg(show(failed)));
    expect(sent.value(QStringLiteral("detail")).toString().contains(QLatin1String("\"threadId\": \"thread-2\"")) &&
               sent.value(QStringLiteral("status")) == QLatin1String("completed") && !sent.contains(QStringLiteral("exitCode")),
           QStringLiteral("the third call is %1").arg(show(sent)));
    // As drawn: the failed call says so, and an opened call shows its command and exit code.
    Brick& brick = timelineBrick(world);
    world.waitFor([&] { return brick.shows(QStringLiteral("Failed")); }, QStringLiteral("the timeline to mark the failed call"));
    QList<QQuickItem*> lines;
    world.waitFor([&] {
      lines.clear();
      collect(brick.window().contentItem(), QStringLiteral("workCall"), lines);
      return lines.size() == 3;
    }, QStringLiteral("the timeline to draw the three calls"));
    click(world, lines.at(1));
    world.waitFor([&] { return brick.shows(QStringLiteral("$ bun lint")) && brick.shows(QStringLiteral("Exit code 2")); },
                  QStringLiteral("the call's command and exit code"));
  });
  step(QStringLiteral("the calls collapse back into the summary"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return entries(world).isEmpty(); }, [&] { return QStringLiteral("the group to close; %1").arg(describe(timeline(world))); });
    const QString text = summary(world);
    expect(text == QLatin1String("Ran 2 commands and sent 1 message to 1 thread"), QStringLiteral("the group reads \"%1\"").arg(text));
    Brick& brick = timelineBrick(world);
    world.waitFor([&] { return brick.shows(text) && !brick.shows(QStringLiteral("$ bun lint")); }, QStringLiteral("the timeline to draw only the summary"));
  });

  // An ACP agent's read, search and fetch, as the MC projects them
  // (acp/thread_runtime.ex tool_kind; apps/server-ex/test/steps/timeline/tool_calls_steps.exs).
  step(QStringLiteral("an ACP agent's tool call is of kind %1").arg(q), [](World& world, const Captures& c, const Table&) {
    startRun(world);
    if (c[0] == QLatin1String("read")) {
      addItem(world, QStringLiteral("file_search"), {{QStringLiteral("pattern"), QStringLiteral("src/app.ts")},
                                                     {QStringLiteral("results"), QJsonArray{QJsonObject{{QStringLiteral("fileName"), QStringLiteral("src/app.ts")}}}}});
    } else if (c[0] == QLatin1String("search")) {
      addItem(world, QStringLiteral("file_search"), {{QStringLiteral("pattern"), QStringLiteral("TODO")}});
    } else if (c[0] == QLatin1String("fetch")) {
      addItem(world, QStringLiteral("web_search"), {{QStringLiteral("patterns"), QJsonArray{QStringLiteral("https://example.com/docs")}}});
    } else {
      fail(QStringLiteral("unknown ACP tool kind: %1").arg(c[0]));
    }
  });
  // The item above is the projected call; the shell has it once it is streamed.
  step(QStringLiteral("the MC projects the call"), [](World& world, const Captures&, const Table&) {
    expect(entries(world).size() == 1, QStringLiteral("the timeline shows %1").arg(describe(timeline(world))));
  });
  step(QStringLiteral("the timeline shows it as (a file read|a file search|a web search)"), [](World& world, const Captures& c, const Table&) {
    const QHash<QString, QStringList> shown{
        {QStringLiteral("a file read"), {QStringLiteral("Read file"), QStringLiteral("eye"), QStringLiteral("src/app.ts")}},
        {QStringLiteral("a file search"), {QStringLiteral("Searched files"), QStringLiteral("search"), QStringLiteral("TODO")}},
        {QStringLiteral("a web search"), {QStringLiteral("Searched the web"), QStringLiteral("globe"), QStringLiteral("https://example.com/docs")}},
    };
    const QStringList want = shown.value(c[0]);
    const QVariantMap call = entries(world).last().toMap();
    expect(call.value(QStringLiteral("label")) == want.at(0) && call.value(QStringLiteral("icon")) == want.at(1) && call.value(QStringLiteral("detail")) == want.at(2),
           QStringLiteral("the call is shown as %1").arg(show(call)));
    Brick& brick = timelineBrick(world);
    world.waitFor([&] { return brick.shows(want.at(0)); }, QStringLiteral("the timeline to draw \"%1\"").arg(want.at(0)));
  });

  // A turn the user stops here.
  step(QStringLiteral("the user interrupted the running turn a moment ago"), [](World& world, const Captures&, const Table&) {
    startWorkingTurn(world);
    addCommand(world, 1);
    addCommand(world, 2, QStringLiteral("running"));
    world.bridge().dispatch(QStringLiteral("composer.interrupt"));
    world.sync();
    bool asked = false;
    for (const QJsonObject& command : std::as_const(world.mc.commands)) asked = asked || command.value(QLatin1String("type")) == QLatin1String("run.interrupt");
    expect(asked, QStringLiteral("the MC was not asked to stop; it has %1").arg(world.describeCommands()));
    // What the MC makes of the stop: the running call was cut off.
    const QString running = entries(world).last().toMap().value(QStringLiteral("id")).toString();
    set(world, QStringLiteral("turn-item"), running, {{QStringLiteral("status"), QStringLiteral("interrupted")}});
  });
  step(QStringLiteral("its work stays expanded so the user can see where it stopped"), [](World& world, const Captures&, const Table&) {
    TimelineModel& model = timeline(world);
    const int fold = lastRowOf(world, QStringLiteral("fold"));
    expect(role(model, fold, TimelineModel::ExpandedRole).toBool() && role(model, fold, TimelineModel::TitleRole).toString().startsWith(QLatin1String("You stopped")),
           QStringLiteral("the fold is not open; %1").arg(describe(model)));
    const QVariantList calls = entries(world);
    expect(calls.size() == 2 && calls.last().toMap().value(QStringLiteral("command")) == QLatin1String("bun test cart-2") &&
               calls.last().toMap().value(QStringLiteral("statusLabel")) == QLatin1String("Stopped"),
           QStringLiteral("the calls shown are %1").arg(show(calls)));
    // The reverse: the user can still fold it away.
    model.toggle(role(model, fold, TimelineModel::IdRole).toString());
    expect(rowsOf(model, QStringLiteral("work")).isEmpty(), QStringLiteral("the work cannot be folded away; %1").arg(describe(model)));
  });

  // A long message of the user's.
  step(QStringLiteral("a message longer than the preview length"), [](World& world, const Captures&, const Table&) {
    const QString run = startRun(world);
    QStringList lines;
    for (int n = 1; n <= 30; ++n) lines.append(QStringLiteral("Requirement %1").arg(n));
    set(world, QStringLiteral("turn-item"), QStringLiteral("message:") + run, {{QStringLiteral("text"), lines.join(QLatin1Char('\n'))}});
    QQuickItem* body = drawn(world, QStringLiteral("userMessageBody"));
    world.waitFor([&] { return body->property("collapsed").toBool() && body->height() <= 200; },
                  [&] { return QStringLiteral("the message to show its preview; it is %1 high").arg(body->height()); });
  });
  step(QStringLiteral("the user shows the full message"), [](World& world, const Captures&, const Table&) {
    QQuickItem* link = drawn(world, QStringLiteral("messageExpand"));
    expect(link->property("text") == QLatin1String("Show full message"), QStringLiteral("the message offers \"%1\"").arg(link->property("text").toString()));
    click(world, link);
  });
  step(QStringLiteral("the whole message is shown"), [](World& world, const Captures&, const Table&) {
    QQuickItem* body = drawn(world, QStringLiteral("userMessageBody"));
    // Thirty lines are taller than the preview, and nothing is cut off.
    world.waitFor([&] { return !body->property("collapsed").toBool() && body->height() > 400 && !body->clip(); },
                  [&] { return QStringLiteral("the whole message; it is %1 high").arg(body->height()); });
    expect(drawn(world, QStringLiteral("messageExpand"))->property("text") == QLatin1String("Show less"), QStringLiteral("the message does not offer to show less"));
  });
  step(QStringLiteral("the user shows less"), [](World& world, const Captures&, const Table&) {
    click(world, drawn(world, QStringLiteral("messageExpand")));
  });
  step(QStringLiteral("the message returns to its preview"), [](World& world, const Captures&, const Table&) {
    QQuickItem* body = drawn(world, QStringLiteral("userMessageBody"));
    world.waitFor([&] { return body->property("collapsed").toBool() && body->height() <= 200 && body->clip(); },
                  [&] { return QStringLiteral("the preview; the message is %1 high").arg(body->height()); });
    expect(drawn(world, QStringLiteral("messageExpand"))->property("text") == QLatin1String("Show full message"), QStringLiteral("the message does not offer to show it in full"));
  });

  // Several approvals, on the request brick the composer stacks over its prompt.
  step(QStringLiteral("the agent has three pending approvals"), [](World& world, const Captures&, const Table&) {
    FakeStreams& fake = world.mc.part<FakeStreams>();
    for (const QString& command : {QStringLiteral("npm test"), QStringLiteral("npm run lint"), QStringLiteral("npm run build")}) {
      const QString id = QStringLiteral("request-%1").arg(fake.ordinal + 1);
      set(world, QStringLiteral("runtime-request"), id,
          {{QStringLiteral("id"), id}, {QStringLiteral("status"), QStringLiteral("pending")},
           {QStringLiteral("responseCapability"), QJsonObject{{QStringLiteral("type"), QStringLiteral("live")}}}});
      addItem(world, QStringLiteral("approval_request"), {{QStringLiteral("requestId"), id}, {QStringLiteral("status"), QStringLiteral("waiting")},
                                                          {QStringLiteral("requestKind"), QStringLiteral("command")}, {QStringLiteral("prompt"), command}});
    }
    world.waitFor([&] { return world.state(QStringLiteral("turn")).toMap().value(QStringLiteral("approvals")).toList().size() == 3; },
                  [&] { return QStringLiteral("three approvals; the turn is %1").arg(show(world.state(QStringLiteral("turn")))); });
    world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nTurnRequests {}\n", QSize(820, 400));
    world.waitFor([&] { return world.brick->shows(QStringLiteral("npm test")); }, QStringLiteral("the first approval to be shown"));
  });
  step(QStringLiteral("the user moves to the next approval"), [](World& world, const Captures&, const Table&) {
    world.brick->click(QStringLiteral("approvalNext"));
    world.waitFor([&] { return world.brick->shows(QStringLiteral("npm run lint")); }, QStringLiteral("the second approval to be shown"));
  });
  step(QStringLiteral("the user moves back"), [](World& world, const Captures&, const Table&) {
    world.brick->click(QStringLiteral("approvalPrevious"));
    world.waitFor([&] { return world.brick->shows(QStringLiteral("npm test")); }, QStringLiteral("the first approval to be shown again"));
  });

  // What a group's calls were, and how a call is named.
  step(QStringLiteral("the activity group holds (.+)"), [](World& world, const Captures& c, const Table&) {
    startRun(world, 30);
    addCalls(world, c[0]);
    finishTurn(world);
  });
  step(QStringLiteral("it ends with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    // The count ends a sentence that starts with what was named.
    const QString text = summary(world);
    expect(text.endsWith(c[0], Qt::CaseInsensitive), QStringLiteral("the group reads \"%1\"").arg(text));
  });
  step(QStringLiteral("the group is marked as having a failure"), [](World& world, const Captures&, const Table&) {
    expect(role(timeline(world), lastRowOf(world, QStringLiteral("work")), TimelineModel::SummaryFailedRole).toBool(),
           QStringLiteral("the group \"%1\" is not marked failed").arg(summary(world)));
  });
  step(QStringLiteral("the provider reported a HAL-C2 tool call as completed"), [](World& world, const Captures&, const Table&) {
    startRun(world, 30);
  });
  step(QStringLiteral("the tool's answer says it is an error"), [](World& world, const Captures&, const Table&) {
    sendMessage(world, QStringLiteral("thread-2"), 1, true);
    finishTurn(world);
  });
  step(QStringLiteral("the (?:call|command) is shown as (failed|succeeded)"), [](World& world, const Captures& c, const Table&) {
    const QVariantMap call = lastCall(world);
    const bool failed = c[0] == QLatin1String("failed");
    expect(call.value(QStringLiteral("status")) == QLatin1String("completed") &&
               call.value(QStringLiteral("statusLabel")) == (failed ? QStringLiteral("Failed") : QString()),
           QStringLiteral("the call is %1").arg(show(call)));
    Brick& brick = timelineBrick(world);
    world.waitFor([&] { return brick.shows(call.value(QStringLiteral("label")).toString()) && brick.shows(QStringLiteral("Failed")) == failed; },
                  QStringLiteral("the timeline to draw the call as %1").arg(c[0]));
  });
  const auto callTool = [](World& world, const QString& name) {
    startRun(world, 30);
    addItem(world, QStringLiteral("dynamic_tool"), {{QStringLiteral("toolName"), name}, {QStringLiteral("input"), QJsonObject{{QStringLiteral("threadId"), QStringLiteral("thread-2")}}}});
    finishTurn(world);
    openFold(world);
  };
  step(QStringLiteral("the agent called HAL-C2's %1 tool").arg(q), [callTool](World& world, const Captures& c, const Table&) {
    callTool(world, QStringLiteral("mcp__hal-c2__") + c[0]);
  });
  step(QStringLiteral("the agent called HAL-C2's thread-reading tool and the provider named it %1").arg(q),
       [callTool](World& world, const Captures& c, const Table&) { callTool(world, c[0]); });
  step(QStringLiteral("the agent called a tool named %1").arg(q), [callTool](World& world, const Captures& c, const Table&) { callTool(world, c[0]); });
  step(QStringLiteral("the call reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString label = lastCall(world).value(QStringLiteral("label")).toString();
    expect(label == c[0], QStringLiteral("the call reads \"%1\"").arg(label));
    Brick& brick = timelineBrick(world);
    world.waitFor([&] { return brick.shows(c[0]); }, QStringLiteral("the timeline to draw \"%1\"").arg(c[0]));
  });
  step(QStringLiteral("the call is shown as an ordinary tool call"), [](World& world, const Captures&, const Table&) {
    const QString label = lastCall(world).value(QStringLiteral("label")).toString();
    expect(label == QLatin1String("mcp__other-server__hal_c2_thread_read"), QStringLiteral("the call reads \"%1\"").arg(label));
    Brick& brick = timelineBrick(world);
    world.waitFor([&] { return brick.shows(label); }, QStringLiteral("the timeline to draw \"%1\"").arg(label));
  });
  step(QStringLiteral("it does not carry HAL-C2's name for the tool"), [](World& world, const Captures&, const Table&) {
    expect(!timelineBrick(world).shows(QStringLiteral("Read a HAL-C2 thread")), QStringLiteral("the call carries HAL-C2's name"));
  });
  step(QStringLiteral("the provider reported a command as completed"), [](World& world, const Captures&, const Table&) {
    startRun(world, 30);
  });
  step(QStringLiteral("the command's output says %1").arg(q), [](World& world, const Captures& c, const Table&) {
    // The wire carries no output, only what the MC made of it: TurnWriter
    // flags a completed command whose output says it failed
    // (orchestration/command_output.ex, test/hal_c2/turn_writer_test.exs).
    QJsonObject fields{{QStringLiteral("input"), QStringLiteral("npm test")}, {QStringLiteral("status"), QStringLiteral("completed")}};
    if (c[0] != QLatin1String("exited with exit code 0")) fields.insert(QStringLiteral("outputIndicatesFailure"), true);
    addItem(world, QStringLiteral("command_execution"), fields);
    finishTurn(world);
  });

  // The running turn's latest command.
  step(QStringLiteral("the agent's latest command is %1").arg(kEscaped), [](World& world, const Captures& c, const Table&) {
    startRun(world, 30);
    addItem(world, QStringLiteral("command_execution"),
            {{QStringLiteral("id"), QStringLiteral("command:latest")}, {QStringLiteral("input"), unescaped(c[0])}, {QStringLiteral("status"), QStringLiteral("running")}});
  });
  const auto end = [](World& world, const QString& how) {
    const QHash<QString, QJsonObject> endings{
        {QStringLiteral("is running"), {{QStringLiteral("status"), QStringLiteral("running")}}},
        {QStringLiteral("succeeds"), {{QStringLiteral("status"), QStringLiteral("completed")}, {QStringLiteral("exitCode"), 0}}},
        {QStringLiteral("fails"), {{QStringLiteral("status"), QStringLiteral("failed")}, {QStringLiteral("exitCode"), 1}}},
        {QStringLiteral("is declined by the user"), {{QStringLiteral("status"), QStringLiteral("declined")}}},
        {QStringLiteral("is stopped"), {{QStringLiteral("status"), QStringLiteral("interrupted")}}},
    };
    set(world, QStringLiteral("turn-item"), QStringLiteral("command:latest"), endings.value(how));
  };
  step(QStringLiteral("it finishes"), [end](World& world, const Captures&, const Table&) { end(world, QStringLiteral("succeeds")); });
  step(QStringLiteral("the command (is running|succeeds|fails|is declined by the user|is stopped)"),
       [end](World& world, const Captures& c, const Table&) { end(world, c[0]); });
  step(QStringLiteral("the live row reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString label = lastCall(world).value(QStringLiteral("label")).toString();
    expect(label == c[0], QStringLiteral("the live row reads \"%1\"").arg(label));
    Brick& brick = timelineBrick(world);
    world.waitFor([&] { return brick.shows(c[0]); }, QStringLiteral("the timeline to draw \"%1\"").arg(c[0]));
  });

  // A command as the provider wrapped it.
  step(QStringLiteral("the agent ran %1").arg(kEscaped), [](World& world, const Captures& c, const Table&) {
    startRun(world, 30);
    addItem(world, QStringLiteral("command_execution"), {{QStringLiteral("input"), unescaped(c[0])}, {QStringLiteral("exitCode"), 0}});
    finishTurn(world);
  });
  step(QStringLiteral("the command reads %1").arg(kEscaped), [](World& world, const Captures& c, const Table&) {
    const QString label = lastCall(world).value(QStringLiteral("label")).toString();
    expect(label == unescaped(c[0]), QStringLiteral("the command reads \"%1\"").arg(label));
  });
  step(QStringLiteral("the user opens the call's details"), [](World& world, const Captures&, const Table&) {
    openFold(world);
    click(world, drawn(world, QStringLiteral("workCall")));
  });
  step(QStringLiteral("the details show %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(lastCall(world).value(QStringLiteral("command")) == c[0], QStringLiteral("the call is %1").arg(show(lastCall(world))));
    Brick& brick = timelineBrick(world);
    world.waitFor([&] { return brick.shows(QStringLiteral("$ ") + c[0]); }, QStringLiteral("the details to show the command"));
  });

  // Progress on a call already shown, while the agent writes.
  step(QStringLiteral("the agent is writing a message"), [](World& world, const Captures&, const Table&) {
    startRun(world, 30);
    addItem(world, QStringLiteral("command_execution"),
            {{QStringLiteral("id"), QStringLiteral("command:dev")}, {QStringLiteral("input"), QStringLiteral("npm run dev")}, {QStringLiteral("status"), QStringLiteral("running")}});
    addItem(world, QStringLiteral("assistant_message"),
            {{QStringLiteral("id"), QStringLiteral("reply")}, {QStringLiteral("streaming"), true}, {QStringLiteral("status"), QStringLiteral("running")},
             {QStringLiteral("text"), QStringLiteral("| Item | Tax |\n|---|---|\n")}});
  });
  step(QStringLiteral("a command it started in the background reports progress in the middle of the message"), [](World& world, const Captures&, const Table&) {
    change(world, QStringLiteral("turn-item"), QStringLiteral("command:dev"), {{QStringLiteral("a"), QJsonObject{{QStringLiteral("output"), QStringLiteral("ready on :3000\n")}}}});
    change(world, QStringLiteral("turn-item"), QStringLiteral("reply"), {{QStringLiteral("a"), QJsonObject{{QStringLiteral("text"), QStringLiteral("| Cart | 2.50 |")}}}});
  });
  step(QStringLiteral("the message stays one message"), [](World& world, const Captures&, const Table&) {
    TimelineModel& model = timeline(world);
    const QList<int> messages = rowsOf(model, QStringLiteral("message"));
    int replies = 0;
    for (const int row : messages) replies += role(model, row, TimelineModel::TextRole).toString().contains(QLatin1String("| Item | Tax |")) ? 1 : 0;
    expect(replies == 1 && messages.last() == model.rowCount() - 1, QStringLiteral("the reply is split; %1").arg(describe(model)));
  });
  step(QStringLiteral("the text the agent writes after the progress is part of it"), [](World& world, const Captures&, const Table&) {
    TimelineModel& model = timeline(world);
    const QString text = role(model, rowsOf(model, QStringLiteral("message")).last(), TimelineModel::TextRole).toString();
    expect(text.contains(QLatin1String("| Item | Tax |")) && text.contains(QLatin1String("| Cart | 2.50 |")), QStringLiteral("the reply reads \"%1\"").arg(text));
  });
});

}  // namespace
