// The composer's turn on an open thread: the agent's requests and questions,
// its proposed plan, queued messages and follow-ups, as the node streams them,
// and what the user's answers send (the `turn` key ComposerController
// publishes, and the commands the node receives). The thread's stream is
// Stream.h's.

#include <QJsonArray>
#include <QJsonObject>
#include <QVariantMap>

#include "ComposerController.h"
#include "Harness.h"
#include "Keymap.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "Stream.h"
#include "Turn.h"
#include "World.h"

using namespace stream;

namespace {

const QString kQuestion = QStringLiteral("database");

QString threadKey(World& world) {
  return world.node.environmentId + QLatin1Char(':') + kThread;
}

QVariantMap turn(World& world) {
  return world.state(QStringLiteral("turn")).toMap();
}

QVariantList listed(World& world, const QString& field) {
  return turn(world).value(field).toList();
}

// Opens a thread of "shop" on a connected node, unless one is open.
void openThread(World& world) {
  if (!world.node.part<FakeStreams>().thread.isEmpty()) return;
  world.node.projects.insert(kProject, {{QStringLiteral("id"), kProject},
                                        {QStringLiteral("title"), kProject},
                                        {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")},
                                        {QStringLiteral("scripts"), QJsonArray()}});
  world.connect();
  world.sync();
  lookAtThread(world, kProject);
}

// The thread's shell row says whether a turn runs.
void updateRow(World& world, const QJsonObject& fields) {
  QJsonObject& row = world.node.threads[kThread];
  for (auto it = fields.begin(); it != fields.end(); ++it) row.insert(it.key(), it.value());
  world.node.sendRow(kThread, row);
  world.sync();
}

void startWorking(World& world) {
  openThread(world);
  const QString run = startRun(world);
  updateRow(world, {{QStringLiteral("activeRunId"), run}, {QStringLiteral("latestRunId"), run}});
}

void finishTurn(World& world) {
  settleRun(world, QStringLiteral("completed"), 30);
  updateRow(world, {{QStringLiteral("activeRunId"), QJsonValue::Null}});
}

// A pending request of the running turn: its runtime-request and its item.
QString request(World& world, const QString& type, const QJsonObject& fields,
                const QString& capability = QStringLiteral("live")) {
  FakeStreams& fake = world.node.part<FakeStreams>();
  const QString id = QStringLiteral("request-%1").arg(fake.ordinal + 1);
  set(world, QStringLiteral("runtime-request"), id,
      {{QStringLiteral("id"), id},
       {QStringLiteral("status"), QStringLiteral("pending")},
       {QStringLiteral("responseCapability"), QJsonObject{{QStringLiteral("type"), capability}}}});
  QJsonObject item = fields;
  item.insert(QStringLiteral("requestId"), id);
  item.insert(QStringLiteral("status"), QStringLiteral("waiting"));
  addItem(world, type, item);
  return id;
}

QString approval(World& world, const QString& kind, const QString& prompt, const QJsonArray& options = {},
                 const QString& capability = QStringLiteral("live")) {
  QJsonObject fields{{QStringLiteral("requestKind"), kind}, {QStringLiteral("prompt"), prompt}};
  if (!options.isEmpty()) fields.insert(QStringLiteral("options"), options);
  return request(world, QStringLiteral("approval_request"), fields, capability);
}

QString question(World& world, const QString& text, const QStringList& labels, bool multiSelect = false,
                 const QString& capability = QStringLiteral("live")) {
  QJsonArray options;
  for (const QString& label : labels) options.append(QJsonObject{{QStringLiteral("label"), label}, {QStringLiteral("description"), QString()}});
  return request(world, QStringLiteral("user_input_request"),
                 {{QStringLiteral("questions"), QJsonArray{QJsonObject{{QStringLiteral("id"), kQuestion},
                                                                       {QStringLiteral("header"), QStringLiteral("Database")},
                                                                       {QStringLiteral("question"), text},
                                                                       {QStringLiteral("options"), options},
                                                                       {QStringLiteral("multiSelect"), multiSelect},
                                                                       {QStringLiteral("allowCustomAnswer"), true}}}}},
                 capability);
}

// The pending approval or question the composer shows first.
QVariantMap first(World& world, const QString& field) {
  const QVariantList requests = listed(world, field);
  if (requests.isEmpty()) fail(QStringLiteral("the composer shows no %1; the turn is %2").arg(field, show(turn(world))));
  return requests.first().toMap();
}

void respond(World& world, const QString& decision) {
  world.bridge().dispatch(QStringLiteral("composer.approval.respond"),
                          QVariantMap{{QStringLiteral("requestId"), first(world, QStringLiteral("approvals")).value(QStringLiteral("requestId"))},
                                      {QStringLiteral("decision"), decision}});
  world.sync();
}

void answer(World& world, const QVariant& value) {
  world.bridge().dispatch(QStringLiteral("composer.question.answer"),
                          QVariantMap{{QStringLiteral("requestId"), first(world, QStringLiteral("questions")).value(QStringLiteral("requestId"))},
                                      {QStringLiteral("answers"), QVariantMap{{kQuestion, value}}}});
  world.sync();
}

// The commands of a type the node received, oldest first.
QList<QJsonObject> commandsOf(World& world, const QString& type) {
  world.sync();
  QList<QJsonObject> found;
  for (const QJsonObject& command : world.node.commands) {
    if (command.value(QLatin1String("type")).toString() == type) found.append(command);
  }
  return found;
}

QJsonObject lastCommand(World& world, const QString& type) {
  const QList<QJsonObject> found = commandsOf(world, type);
  if (found.isEmpty()) fail(QStringLiteral("no %1 command; the node has %2").arg(type, world.describeCommands()));
  return found.last();
}

void expectDecision(World& world, const QString& decision) {
  const QJsonObject command = lastCommand(world, QStringLiteral("runtime-request.respond"));
  expect(command.value(QLatin1String("decision")).toString() == decision && command.value(QLatin1String("threadId")) == kThread,
         QStringLiteral("the node was told %1").arg(show(command.toVariantMap())));
}

QVariant receivedAnswer(World& world) {
  const QJsonObject command = lastCommand(world, QStringLiteral("runtime-request.respond"));
  return command.value(QLatin1String("answers")).toObject().value(kQuestion).toVariant();
}

QJsonObject lastMessage(World& world) {
  return lastCommand(world, QStringLiteral("message.dispatch"));
}

// A proposed plan in the latest run of a thread in plan mode; `settled` ends
// that run.
void proposePlan(World& world, bool settled) {
  startWorking(world);
  // Plans come from plan mode.
  updateRow(world, {{QStringLiteral("interactionMode"), QStringLiteral("plan")}});
  const QString markdown = QStringLiteral("# Tax line\n\n- Add the line\n- Test it");
  addItem(world, QStringLiteral("proposed_plan"), {{QStringLiteral("markdown"), markdown}, {QStringLiteral("planId"), QStringLiteral("plan-1")}});
  set(world, QStringLiteral("plan"), QStringLiteral("plan-1"),
      {{QStringLiteral("id"), QStringLiteral("plan-1")},
       {QStringLiteral("kind"), QStringLiteral("proposed_plan")},
       {QStringLiteral("status"), QStringLiteral("active")},
       {QStringLiteral("runId"), world.node.part<FakeStreams>().run},
       {QStringLiteral("markdown"), markdown}});
  if (settled) finishTurn(world);
}

void queueMessage(World& world, const QString& text) {
  FakeStreams& fake = world.node.part<FakeStreams>();
  const QString run = QStringLiteral("run-queued-%1").arg(text);
  const int position = ++fake.ordinal;
  set(world, QStringLiteral("message"), QStringLiteral("message-") + text,
      {{QStringLiteral("id"), QStringLiteral("message-") + text}, {QStringLiteral("role"), QStringLiteral("user")}, {QStringLiteral("text"), text}});
  set(world, QStringLiteral("run"), run,
      {{QStringLiteral("id"), run},
       {QStringLiteral("ordinal"), position},
       {QStringLiteral("status"), QStringLiteral("queued")},
       {QStringLiteral("queuePosition"), position},
       {QStringLiteral("userMessageId"), QStringLiteral("message-") + text}});
}

QVariantList toasts(World& world) {
  return world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList();
}

void typeInto(World& world, const QString& text) {
  world.bridge().dispatch(QStringLiteral("composer.text.set"),
                          QVariantMap{{QStringLiteral("target"), world.native().controller<NavigationController>()->threadKey()},
                                      {QStringLiteral("text"), text},
                                      {QStringLiteral("cursor"), text.size()}});
}

QString draftOf(World& world, const QString& key) {
  return world.native().controller<ComposerController>()->draft(key);
}

QString openDraft(World& world) {
  return draftOf(world, world.native().controller<NavigationController>()->threadKey());
}

const Steps steps([] {
  const QString q = kQuoted;

  // Threads.
  step(QStringLiteral("the user is looking at a thread in %1 whose agent is working").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAtThread(world, c[0]);
    startWorking(world);
  });
  step(QStringLiteral("a thread whose agent is working on a turn"), [](World& world, const Captures&, const Table&) {
    startWorking(world);
  });
  step(QStringLiteral("a project with an open thread"), [](World& world, const Captures&, const Table&) { openThread(world); });
  step(QStringLiteral("the thread's provider is ready"), [](World&, const Captures&, const Table&) {});

  // Approvals.
  step(QStringLiteral("the agent asks to run %1").arg(q), [](World& world, const Captures& c, const Table&) {
    approval(world, QStringLiteral("command"), c[0]);
  });
  const QHash<QString, QString> decisions{
      {QStringLiteral("approve it"), QStringLiteral("accept")},
      {QStringLiteral("decline it"), QStringLiteral("decline")},
      {QStringLiteral("always allow it this session"), QStringLiteral("acceptForSession")},
      {QStringLiteral("cancel the request"), QStringLiteral("cancel")},
  };
  step(QStringLiteral("the user chooses to (approve it|decline it|always allow it this session|cancel the request)"),
       [decisions](World& world, const Captures& c, const Table&) {
         // The option the approval offers for it, as the panel's buttons.
         const QString decision = decisions.value(c[0]);
         const QVariantList options = first(world, QStringLiteral("approvals")).value(QStringLiteral("options")).toList();
         expect(std::any_of(options.cbegin(), options.cend(), [&](const QVariant& option) { return option.toMap().value(QStringLiteral("decision")) == decision; }),
                QStringLiteral("the approval offers %1").arg(show(options)));
         respond(world, decision);
       });
  step(QStringLiteral("the command runs and the agent continues"), [](World& world, const Captures&, const Table&) {
    expectDecision(world, QStringLiteral("accept"));
  });
  step(QStringLiteral("the command is not run and the agent is told it was declined"), [](World& world, const Captures&, const Table&) {
    expectDecision(world, QStringLiteral("decline"));
  });
  step(QStringLiteral("the command runs and matching requests stop asking this session"), [](World& world, const Captures&, const Table&) {
    expectDecision(world, QStringLiteral("acceptForSession"));
  });
  step(QStringLiteral("the command is not run and the turn stops waiting"), [](World& world, const Captures&, const Table&) {
    expectDecision(world, QStringLiteral("cancel"));
  });
  const QHash<QString, QString> kinds{
      {QStringLiteral("to run a command"), QStringLiteral("command")},
      {QStringLiteral("to read a file"), QStringLiteral("file-read")},
      {QStringLiteral("to change a file"), QStringLiteral("file-change")},
      {QStringLiteral("access for an app"), QStringLiteral("mcp-elicitation")},
      {QStringLiteral("a permission for an app"), QStringLiteral("permission")},
  };
  step(QStringLiteral("the agent requests (to run a command|to read a file|to change a file|access for an app|a permission for an app)"),
       [kinds](World& world, const Captures& c, const Table&) { approval(world, kinds.value(c[0]), QString()); });
  step(QStringLiteral("the request is titled %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString title = first(world, QStringLiteral("approvals")).value(QStringLiteral("title")).toString();
    expect(title == c[0], QStringLiteral("the request is titled \"%1\"").arg(title));
  });
  step(QStringLiteral("the provider warns that an option may follow injected instructions"), [](World& world, const Captures&, const Table&) {
    approval(world, QStringLiteral("mcp-elicitation"), QStringLiteral("Allow the browser app?"),
             QJsonArray{QJsonObject{{QStringLiteral("decision"), QStringLiteral("accept")}, {QStringLiteral("label"), QStringLiteral("Allow")}},
                        QJsonObject{{QStringLiteral("decision"), QStringLiteral("acceptForSession")},
                                    {QStringLiteral("label"), QStringLiteral("Always allow")},
                                    {QStringLiteral("warning"), QStringLiteral("The app may follow instructions injected into pages it reads.")}},
                        QJsonObject{{QStringLiteral("decision"), QStringLiteral("decline")}, {QStringLiteral("label"), QStringLiteral("Deny")}}});
  });
  step(QStringLiteral("the user reviews the approval"), [](World&, const Captures&, const Table&) {});
  step(QStringLiteral("the warning is shown next to that option"), [](World& world, const Captures&, const Table&) {
    const QVariantList options = first(world, QStringLiteral("approvals")).value(QStringLiteral("options")).toList();
    QStringList warned;
    for (const QVariant& option : options) {
      if (!option.toMap().value(QStringLiteral("warning")).toString().isEmpty()) warned.append(option.toMap().value(QStringLiteral("label")).toString());
    }
    expect(warned == QStringList{QStringLiteral("Always allow")}, QStringLiteral("the options are %1").arg(show(options)));
  });
  step(QStringLiteral("the provider process stopped while an approval was pending"), [](World& world, const Captures&, const Table&) {
    approval(world, QStringLiteral("command"), QStringLiteral("rm -rf dist"), {}, QStringLiteral("not_resumable"));
  });
  step(QStringLiteral("the approval cannot be answered"), [](World& world, const Captures&, const Table&) {
    const QVariantMap shown = first(world, QStringLiteral("approvals"));
    expect(!shown.value(QStringLiteral("canRespond")).toBool(), QStringLiteral("the approval is %1").arg(show(shown)));
  });
  // Shared with WorkspaceSteps' renames: the message is either why the
  // pending approval cannot be answered or a toast's title.
  step(QStringLiteral("the user is told %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const auto told = [&] {
      for (const QVariant& item : listed(world, QStringLiteral("approvals"))) {
        if (item.toMap().value(QStringLiteral("problem")) == c[0]) return true;
      }
      // A toast is told by its title, or as "title — description".
      for (const QVariant& item : toasts(world)) {
        const QString title = item.toMap().value(QStringLiteral("title")).toString();
        if (title == c[0] || title + QStringLiteral(" — ") + item.toMap().value(QStringLiteral("description")).toString() == c[0]) return true;
      }
      return conditionProblem(world) == c[0];
    };
    world.waitFor(told, [&] {
      return QStringLiteral("\"%1\"; the turn is %2, the toasts are %3")
          .arg(c[0], show(turn(world)), show(world.state(QStringLiteral("toasts"))));
    });
  });
  step(QStringLiteral("the user approved a pending request"), [](World& world, const Captures&, const Table&) {
    approval(world, QStringLiteral("command"), QStringLiteral("npm test"));
  });
  step(QStringLiteral("sending the answer fails because (the request was already resolved|the connection dropped for a moment)"),
       [](World& world, const Captures& c, const Table&) {
         world.node.refusals.insert(QStringLiteral("runtime-request.respond"),
                                    c[0] == QLatin1String("the request was already resolved") ? QStringLiteral("no pending request")
                                                                                              : QStringLiteral("connection closed"));
         respond(world, QStringLiteral("accept"));
       });
  step(QStringLiteral("the approval is closed"), [](World& world, const Captures&, const Table&) {
    expect(listed(world, QStringLiteral("approvals")).isEmpty(), QStringLiteral("the turn is %1").arg(show(turn(world))));
  });
  step(QStringLiteral("the approval is still open so the user can answer again"), [](World& world, const Captures&, const Table&) {
    const QVariantMap shown = first(world, QStringLiteral("approvals"));
    expect(shown.value(QStringLiteral("canRespond")).toBool() && !shown.value(QStringLiteral("responding")).toBool(),
           QStringLiteral("the approval is %1").arg(show(shown)));
  });

  // Questions.
  step(QStringLiteral("the agent asks %1 with the options %1, %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    question(world, c[0], {c[1], c[2], c[3]});
  });
  step(QStringLiteral("the agent asks %1 with three options").arg(q), [](World& world, const Captures& c, const Table&) {
    question(world, c[0], {QStringLiteral("Postgres"), QStringLiteral("SQLite"), QStringLiteral("MySQL")});
  });
  step(QStringLiteral("the question allows (one answer|several answers)"), [](World& world, const Captures& c, const Table&) {
    // The question as the agent asked it, again with the choice it allows.
    const QString requestId = first(world, QStringLiteral("questions")).value(QStringLiteral("requestId")).toString();
    const QVariantMap shown = first(world, QStringLiteral("questions")).value(QStringLiteral("questions")).toList().first().toMap();
    QStringList labels;
    for (const QVariant& option : shown.value(QStringLiteral("options")).toList()) labels.append(option.toMap().value(QStringLiteral("label")).toString());
    set(world, QStringLiteral("runtime-request"), requestId, {{QStringLiteral("status"), QStringLiteral("resolved")}});
    question(world, shown.value(QStringLiteral("question")).toString(), labels, c[0] == QLatin1String("several answers"));
  });
  step(QStringLiteral("the user picks %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    answer(world, QVariantList{c[0], c[1]});
  });
  step(QStringLiteral("the user answers %1").arg(q), [](World& world, const Captures& c, const Table&) { answer(world, c[0]); });
  step(QStringLiteral("the agent receives %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariant received = receivedAnswer(world);
    expect(received == QVariant(c[0]), QStringLiteral("the agent received %1").arg(show(received)));
  });
  step(QStringLiteral("the agent receives %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariant received = receivedAnswer(world);
    expect(received.toStringList() == QStringList{c[0], c[1]}, QStringLiteral("the agent received %1").arg(show(received)));
  });
  step(QStringLiteral("the agent asked a question that can be answered by message"), [](World& world, const Captures&, const Table&) {
    question(world, QStringLiteral("Which database?"), {QStringLiteral("Postgres"), QStringLiteral("SQLite")}, false, QStringLiteral("message"));
  });
  step(QStringLiteral("the turn ends before the user answers"), [](World& world, const Captures&, const Table&) { finishTurn(world); });
  step(QStringLiteral("the user can still answer the question"), [](World& world, const Captures&, const Table&) {
    const QVariantMap shown = first(world, QStringLiteral("questions"));
    expect(shown.value(QStringLiteral("canRespond")).toBool(), QStringLiteral("the question is %1").arg(show(shown)));
    answer(world, QStringLiteral("SQLite"));
    expect(receivedAnswer(world) == QVariant(QStringLiteral("SQLite")), QStringLiteral("the answer did not reach the node"));
  });
  step(QStringLiteral("the agent has asked %1 with options %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    startWorking(world);
    question(world, c[0], {c[1], c[2]});
  });
  step(QStringLiteral("the user dismisses the question without answering"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("composer.question.dismiss"),
                            QVariantMap{{QStringLiteral("requestId"), first(world, QStringLiteral("questions")).value(QStringLiteral("requestId"))}});
    world.sync();
  });
  step(QStringLiteral("the agent is told the question was dismissed"), [](World& world, const Captures&, const Table&) {
    const QJsonObject command = lastCommand(world, QStringLiteral("thread.user-input.dismiss"));
    expect(command.value(QLatin1String("threadId")) == kThread && !command.value(QLatin1String("requestId")).toString().isEmpty(),
           QStringLiteral("the node was told %1").arg(show(command.toVariantMap())));
    expect(commandsOf(world, QStringLiteral("runtime-request.respond")).isEmpty(), QStringLiteral("the agent was also given an answer"));
  });

  // Plans.
  step(QStringLiteral("the agent (?:has proposed|proposed) a plan(?: and the thread is idle)?"), [](World& world, const Captures&, const Table&) {
    proposePlan(world, true);
    world.waitFor([&] { return turn(world).value(QStringLiteral("plan")).isValid(); },
                  [&] { return QStringLiteral("the plan to be offered; the turn is %1").arg(show(turn(world))); });
  });
  step(QStringLiteral("the user (?:implements the plan with no feedback|chooses to implement the plan)"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("composer.plan.implement"));
    world.sync();
  });
  step(QStringLiteral("(?:the agent starts implementing it in this thread|a turn starts that carries out the plan)"), [](World& world, const Captures&, const Table&) {
    const QJsonObject message = lastMessage(world);
    expect(message.value(QLatin1String("threadId")) == kThread &&
               message.value(QLatin1String("text")).toString().startsWith(QLatin1String("PLEASE IMPLEMENT THIS PLAN:\n# Tax line")) &&
               message.value(QLatin1String("sourcePlanRef")).toObject().value(QLatin1String("planId")) == QLatin1String("plan-1"),
           QStringLiteral("the node was sent %1").arg(show(message.toVariantMap())));
    const QJsonObject mode = lastCommand(world, QStringLiteral("thread.interaction-mode.set"));
    expect(mode.value(QLatin1String("interactionMode")) == QLatin1String("default"), QStringLiteral("the thread was set to %1").arg(show(mode.toVariantMap())));
  });
  step(QStringLiteral("the plan card is no longer offered"), [](World& world, const Captures&, const Table&) {
    // What the node does with the message's sourcePlanRef.
    set(world, QStringLiteral("plan"), QStringLiteral("plan-1"), {{QStringLiteral("status"), QStringLiteral("completed")}});
    expect(!turn(world).value(QStringLiteral("plan")).isValid(), QStringLiteral("the turn is %1").arg(show(turn(world))));
  });
  step(QStringLiteral("the user sends %1 as feedback").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("composer.submit"), QVariantMap{{QStringLiteral("text"), c[0]}, {QStringLiteral("intent"), QStringLiteral("foreground")}});
    world.sync();
  });
  step(QStringLiteral("the agent revises the plan"), [](World& world, const Captures&, const Table&) {
    const QJsonObject message = lastMessage(world);
    expect(message.value(QLatin1String("text")) == QLatin1String("split the migration into its own step") && !message.contains(QLatin1String("sourcePlanRef")),
           QStringLiteral("the node was sent %1").arg(show(message.toVariantMap())));
  });
  step(QStringLiteral("the thread stays in plan mode"), [](World& world, const Captures&, const Table&) {
    for (const QJsonObject& mode : commandsOf(world, QStringLiteral("thread.interaction-mode.set"))) {
      expect(mode.value(QLatin1String("interactionMode")) == QLatin1String("plan"), QStringLiteral("the thread was set to %1").arg(show(mode.toVariantMap())));
    }
  });
  step(QStringLiteral("the agent is proposing a plan in the running turn"), [](World& world, const Captures&, const Table&) {
    proposePlan(world, false);
  });
  step(QStringLiteral("no plan is offered"), [](World& world, const Captures&, const Table&) {
    expect(!turn(world).value(QStringLiteral("plan")).isValid(), QStringLiteral("the turn is %1").arg(show(turn(world))));
  });

  // Follow-ups and the queue.
  step(QStringLiteral("the follow-up behaviour setting is %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.native().controller<SettingsController>()->writeDevice(QStringLiteral("followUpBehavior"), c[0]);
  });
  step(QStringLiteral("%1 is queued").arg(q), [](World& world, const Captures& c, const Table&) {
    // As a precondition it is waiting in the thread's queue.
    if (!world.checking) return queueMessage(world, c[0]);
    const QJsonObject message = lastMessage(world);
    expect(message.value(QLatin1String("text")) == c[0] &&
               message.value(QLatin1String("dispatchMode")).toObject().value(QLatin1String("type")) == QLatin1String("queue_after_active") &&
               !message.contains(QLatin1String("deliveryIntent")),
           QStringLiteral("the node was sent %1").arg(show(message.toVariantMap())));
  });
  step(QStringLiteral("%1 steers the running turn").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject message = lastMessage(world);
    expect(message.value(QLatin1String("text")) == c[0] && message.value(QLatin1String("deliveryIntent")) == QLatin1String("steer") &&
               message.value(QLatin1String("dispatchMode")).toObject().value(QLatin1String("type")) == QLatin1String("start_immediately"),
           QStringLiteral("the node was sent %1").arg(show(message.toVariantMap())));
  });
  step(QStringLiteral("the composer is empty"), [](World& world, const Captures&, const Table&) {
    expect(openDraft(world).isEmpty(), QStringLiteral("the draft reads \"%1\"").arg(openDraft(world)));
  });
  step(QStringLiteral("the user chooses to stop"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("composer.interrupt"));
    world.sync();
  });
  step(QStringLiteral("the running turn is interrupted"), [](World& world, const Captures&, const Table&) {
    const QJsonObject command = lastCommand(world, QStringLiteral("run.interrupt"));
    expect(command.value(QLatin1String("runId")) == world.node.part<FakeStreams>().run, QStringLiteral("the node was told %1").arg(show(command.toVariantMap())));
  });
  step(QStringLiteral("%1 and %1 are queued").arg(q), [](World& world, const Captures& c, const Table&) {
    queueMessage(world, c[0]);
    queueMessage(world, c[1]);
  });
  step(QStringLiteral("the composer lists the queued messages %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QStringList texts;
    for (const QVariant& queued : listed(world, QStringLiteral("queue"))) texts.append(queued.toMap().value(QStringLiteral("text")).toString());
    expect(texts == QStringList{c[0], c[1]}, QStringLiteral("the composer lists [%1]").arg(texts.join(QStringLiteral(", "))));
  });
  const auto queued = [](World& world, const QString& text) {
    for (const QVariant& entry : listed(world, QStringLiteral("queue"))) {
      if (entry.toMap().value(QStringLiteral("text")) == text) return entry.toMap().value(QStringLiteral("runId")).toString();
    }
    fail(QStringLiteral("\"%1\" is not queued; the turn is %2").arg(text, show(turn(world))));
  };
  step(QStringLiteral("the user removes %1 from the queue").arg(q), [queued](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("composer.queue.remove"), QVariantMap{{QStringLiteral("runId"), queued(world, c[0])}});
    world.sync();
  });
  step(QStringLiteral("the user steers the running turn with the queued %1").arg(q), [queued](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("composer.queue.steer"), QVariantMap{{QStringLiteral("runId"), queued(world, c[0])}});
    world.sync();
  });
  step(QStringLiteral("the node is asked to cancel the queued run of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject command = lastCommand(world, QStringLiteral("queued-run.cancel"));
    expect(command.value(QLatin1String("runId")) == QStringLiteral("run-queued-") + c[0], QStringLiteral("the node was told %1").arg(show(command.toVariantMap())));
  });
  step(QStringLiteral("the node is asked to steer the running turn with the queued run of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject command = lastCommand(world, QStringLiteral("queued-message.promote-to-steer"));
    expect(command.value(QLatin1String("queuedRunId")) == QStringLiteral("run-queued-") + c[0] &&
               command.value(QLatin1String("targetRunId")) == world.node.part<FakeStreams>().run,
           QStringLiteral("the node was told %1").arg(show(command.toVariantMap())));
  });

  // Editing a queued message.
  step(QStringLiteral("the user starts editing the last queued message from the start of the composer"), [](World& world, const Captures&, const Table&) {
    // The brick sends this for its edit key with the caret at the start.
    world.bridge().dispatch(QStringLiteral("composer.queue.edit"), QVariantMap());
    world.sync();
  });
  step(QStringLiteral("the user changes the edit to %1").arg(q), [](World& world, const Captures& c, const Table&) { typeInto(world, c[0]); });
  step(QStringLiteral("the user sends %1 from the composer").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("composer.submit"), QVariantMap{{QStringLiteral("text"), c[0]}, {QStringLiteral("intent"), QStringLiteral("foreground")}});
    world.sync();
  });
  step(QStringLiteral("the user cancels the edit"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("composer.queue.edit.cancel"));
  });
  step(QStringLiteral("the composer holds %1(?: again)?").arg(q), [](World& world, const Captures& c, const Table&) {
    const auto shown = [&world] { return world.state(QStringLiteral("composer")).toMap(); };
    world.waitFor([&] { return shown().value(QStringLiteral("text")) == c[0]; },
                  [&] { return QStringLiteral("the composer shows %1").arg(show(shown())); });
  });
  step(QStringLiteral("the queued run of %1 starts").arg(q), [](World& world, const Captures& c, const Table&) {
    set(world, QStringLiteral("run"), QStringLiteral("run-queued-") + c[0], {{QStringLiteral("status"), QStringLiteral("running")}});
  });
  step(QStringLiteral("the node is asked to change the queued run of %1 to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject command = lastCommand(world, QStringLiteral("queued-run.edit"));
    expect(command.value(QLatin1String("runId")) == QStringLiteral("run-queued-") + c[0] && command.value(QLatin1String("text")) == c[1],
           QStringLiteral("the node was told %1").arg(show(command.toVariantMap())));
  });
  step(QStringLiteral("the queued message still reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QStringList texts;
    for (const QVariant& queued : listed(world, QStringLiteral("queue"))) texts.append(queued.toMap().value(QStringLiteral("text")).toString());
    expect(texts.contains(c[0]) && commandsOf(world, QStringLiteral("queued-run.edit")).isEmpty(),
           QStringLiteral("the queue is [%1] and the node has %2").arg(texts.join(QStringLiteral(", ")), world.describeCommands()));
  });

  // Answers in flight.
  step(QStringLiteral("the user approves it"), [](World& world, const Captures&, const Table&) { respond(world, QStringLiteral("accept")); });
  step(QStringLiteral("the approval shows it is being answered"), [](World& world, const Captures&, const Table&) {
    const QVariantMap shown = first(world, QStringLiteral("approvals"));
    expect(shown.value(QStringLiteral("responding")).toBool(), QStringLiteral("the approval is %1").arg(show(shown)));
  });
  step(QStringLiteral("the node receives one answer"), [](World& world, const Captures&, const Table&) {
    const qsizetype answers = commandsOf(world, QStringLiteral("runtime-request.respond")).size();
    expect(answers == 1, QStringLiteral("the node received %1 answers").arg(answers));
  });

  // Drafts.
  const auto threadB = [](World& world) {
    const QString id = QStringLiteral("thread-2");
    if (!world.node.threads.contains(id)) {
      world.node.threads.insert(id, {{QStringLiteral("id"), id}, {QStringLiteral("title"), QStringLiteral("Other")}, {QStringLiteral("projectId"), kProject},
                                     {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")}, {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}});
      world.node.sendRow(id, world.node.threads.value(id));
      world.sync();
    }
    return world.node.environmentId + QStringLiteral(":") + id;
  };
  step(QStringLiteral("the user has typed %1 in thread A").arg(q), [](World& world, const Captures& c, const Table&) { typeInto(world, c[0]); });
  step(QStringLiteral("the user switches to thread B and back to thread A"), [threadB](World& world, const Captures&, const Table&) {
    look(world, threadB(world));
    look(world, threadKey(world));
  });
  step(QStringLiteral("thread A's draft reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap shown = world.state(QStringLiteral("composer")).toMap();
    expect(shown.value(QStringLiteral("target")) == threadKey(world) && shown.value(QStringLiteral("text")) == c[0],
           QStringLiteral("the composer shows %1").arg(show(shown)));
  });
  step(QStringLiteral("thread B's draft is empty"), [threadB](World& world, const Captures&, const Table&) {
    expect(draftOf(world, threadB(world)).isEmpty(), QStringLiteral("thread B's draft reads \"%1\"").arg(draftOf(world, threadB(world))));
  });
  step(QStringLiteral("the environment is disconnected"), [](World& world, const Captures&, const Table&) {
    world.node.stopAccepting();
    world.node.drop();
    world.waitFor([&world] { return !world.native().client()->isReady(); }, QStringLiteral("the shell to see the drop"));
  });
  step(QStringLiteral("the user has typed %1").arg(q), [](World& world, const Captures& c, const Table&) { typeInto(world, c[0]); });
  step(QStringLiteral("the user tries to send it"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("composer.submit"), QVariantMap{{QStringLiteral("text"), openDraft(world)}, {QStringLiteral("intent"), QStringLiteral("foreground")}});
  });
  step(QStringLiteral("the user is told the message was not sent because they are not connected"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return toasts(world).size() > 0; }, QStringLiteral("a toast"));
    const QVariantMap toast = toasts(world).last().toMap();
    expect(toast.value(QStringLiteral("type")) == QLatin1String("warning") && toast.value(QStringLiteral("title")) == QLatin1String("Not connected: message not sent"),
           QStringLiteral("the toast is %1").arg(show(toast)));
    expect(world.node.commands.isEmpty(), QStringLiteral("the node has %1").arg(world.describeCommands()));
  });
  step(QStringLiteral("the draft (?:still reads %1|reads %1 again)").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString expected = c[0].isEmpty() ? c[1] : c[0];
    world.waitFor([&] { return openDraft(world) == expected; }, [&] { return QStringLiteral("the draft reads \"%1\"").arg(openDraft(world)); });
  });
  step(QStringLiteral("the user sends it and the node rejects the message"), [](World& world, const Captures&, const Table&) {
    world.node.refusals.insert(QStringLiteral("message.dispatch"), QStringLiteral("Provider unavailable"));
    world.bridge().dispatch(QStringLiteral("composer.submit"), QVariantMap{{QStringLiteral("text"), openDraft(world)}, {QStringLiteral("intent"), QStringLiteral("foreground")}});
    world.sync();
  });
  step(QStringLiteral("the user sees why the send failed"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return toasts(world).size() > 0; }, QStringLiteral("a toast"));
    const QVariantMap toast = toasts(world).last().toMap();
    expect(toast.value(QStringLiteral("title")) == QLatin1String("Failed to send message") &&
               toast.value(QStringLiteral("description")) == QLatin1String("Provider unavailable"),
           QStringLiteral("the toast is %1").arg(show(toast)));
  });
});

}  // namespace

void pickAnswer(World& world, const QString& label) {
  answer(world, label);
}

void openTurnThread(World& world) {
  openThread(world);
}
