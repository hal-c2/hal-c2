// The composer's turn on an open thread: the agent's requests and questions,
// its proposed plan, queued messages and follow-ups, as the MC streams them,
// and what the user's answers send (the `turn` key ComposerController
// publishes, and the commands the MC receives). The thread's stream is
// Stream.h's.

#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>
#include <QRegularExpression>
#include <QVariantMap>

#include <functional>
#include <memory>
#include <optional>

#include "CommandPaletteController.h"
#include "ComposerBrick.h"
#include "ComposerController.h"
#include "Brick.h"
#include "Harness.h"
#include "Keymap.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "RightPanelController.h"
#include "WorkspaceFiles.h"
#include "Onboarding.h"
#include "SettingsController.h"
#include "Stream.h"
#include "Turn.h"
#include "World.h"

using namespace stream;

namespace {

const QString kQuestion = QStringLiteral("database");

QString threadKey(World& world) {
  return world.mc.environmentId + QLatin1Char(':') + kThread;
}

QVariantMap turn(World& world) {
  return world.state(QStringLiteral("turn")).toMap();
}

QVariantList listed(World& world, const QString& field) {
  return turn(world).value(field).toList();
}

// Opens a thread of "shop" on a connected MC, unless one is open.
void openThread(World& world) {
  if (!world.mc.part<FakeStreams>().thread.isEmpty()) return;
  world.mc.projects.insert(kProject, {{QStringLiteral("id"), kProject},
                                        {QStringLiteral("title"), kProject},
                                        {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")},
                                        {QStringLiteral("scripts"), QJsonArray()}});
  if (world.shellSubscriptions() == 0) {
    world.connect();
  } else {
    // Already connected: the project arrives as a row.
    world.mc.sendRow(kProject, world.mc.projects.value(kProject), QStringLiteral("project"));
  }
  world.sync();
  lookAtThread(world, kProject);
}

// The thread's shell row says whether a turn runs.
void updateRow(World& world, const QJsonObject& fields) {
  QJsonObject& row = world.mc.threads[kThread];
  for (auto it = fields.begin(); it != fields.end(); ++it) row.insert(it.key(), it.value());
  world.mc.sendRow(kThread, row);
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
  FakeStreams& fake = world.mc.part<FakeStreams>();
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
// Two questions in one request, each long enough to wrap: the shape Claude's
// AskUserQuestion arrives in.
QJsonObject longQuestions() {
  const auto asked = [](const QString& id, const QString& text, const QStringList& labels) {
    QJsonArray options;
    for (const QString& label : labels) options.append(QJsonObject{{QStringLiteral("label"), label}, {QStringLiteral("description"), QString()}});
    return QJsonObject{{QStringLiteral("id"), id},
                       {QStringLiteral("header"), id},
                       {QStringLiteral("question"), text},
                       {QStringLiteral("options"), options},
                       {QStringLiteral("multiSelect"), false},
                       {QStringLiteral("allowCustomAnswer"), true}};
  };
  return {{QStringLiteral("questions"),
           QJsonArray{asked(QStringLiteral("lint"),
                            QStringLiteral("Should the lint get a family of rules that flags imperative QML which could be declarative "
                                           "(bindings, States, Transitions, SequentialAnimation)?"),
                            {QStringLiteral("Yes, start now (Recommended)"), QStringLiteral("After make-it-right"), QStringLiteral("Not now")}),
                      asked(QStringLiteral("direction"),
                            QStringLiteral("Which direction for the typed scripting language that replaces JavaScript (with JS kept as the "
                                           "compat mode)?"),
                            {QStringLiteral("Strict TS subset (Recommended)"), QStringLiteral("ReScript-like language"),
                             QStringLiteral("Decide later")})}}};
}

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

// The commands of a type the MC received, oldest first.
QList<QJsonObject> commandsOf(World& world, const QString& type) {
  world.sync();
  QList<QJsonObject> found;
  for (const QJsonObject& command : world.mc.commands) {
    if (command.value(QLatin1String("type")).toString() == type) found.append(command);
  }
  return found;
}

QJsonObject lastCommand(World& world, const QString& type) {
  const QList<QJsonObject> found = commandsOf(world, type);
  if (found.isEmpty()) fail(QStringLiteral("no %1 command; the MC has %2").arg(type, world.describeCommands()));
  return found.last();
}

void expectDecision(World& world, const QString& decision) {
  const QJsonObject command = lastCommand(world, QStringLiteral("runtime-request.respond"));
  expect(command.value(QLatin1String("decision")).toString() == decision && command.value(QLatin1String("threadId")) == kThread,
         QStringLiteral("the MC was told %1").arg(show(command.toVariantMap())));
}

QVariant receivedAnswer(World& world) {
  const QJsonObject command = lastCommand(world, QStringLiteral("runtime-request.respond"));
  return command.value(QLatin1String("answers")).toObject().value(kQuestion).toVariant();
}

QJsonObject lastMessage(World& world) {
  return lastCommand(world, QStringLiteral("message.dispatch"));
}

// The markdown of the plan the agent proposed last.
struct ProposedPlan {
  QString markdown;
};

const QString kPlanMarkdown = QStringLiteral("# Tax line\n\n- Add the line\n- Test it");

// A proposed plan in the latest run of a thread in plan mode; `settled` ends
// that run.
void proposePlan(World& world, bool settled, const QString& markdown = kPlanMarkdown) {
  startWorking(world);
  // Plans come from plan mode.
  updateRow(world, {{QStringLiteral("interactionMode"), QStringLiteral("plan")}});
  world.mc.part<ProposedPlan>().markdown = markdown;
  addItem(world, QStringLiteral("proposed_plan"), {{QStringLiteral("markdown"), markdown}, {QStringLiteral("planId"), QStringLiteral("plan-1")}});
  set(world, QStringLiteral("plan"), QStringLiteral("plan-1"),
      {{QStringLiteral("id"), QStringLiteral("plan-1")},
       {QStringLiteral("kind"), QStringLiteral("proposed_plan")},
       {QStringLiteral("status"), QStringLiteral("active")},
       {QStringLiteral("runId"), world.mc.part<FakeStreams>().run},
       {QStringLiteral("markdown"), markdown}});
  if (settled) finishTurn(world);
}

void queueMessage(World& world, const QString& text) {
  FakeStreams& fake = world.mc.part<FakeStreams>();
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

void queueWake(World& world) {
  FakeStreams& fake = world.mc.part<FakeStreams>();
  const QString run = QStringLiteral("run-queued-wake");
  const int position = ++fake.ordinal;
  set(world, QStringLiteral("message"), QStringLiteral("message-wake"),
      {{QStringLiteral("id"), QStringLiteral("message-wake")}, {QStringLiteral("role"), QStringLiteral("user")}, {QStringLiteral("providerWake"), true}});
  set(world, QStringLiteral("run"), run,
      {{QStringLiteral("id"), run},
       {QStringLiteral("ordinal"), position},
       {QStringLiteral("status"), QStringLiteral("queued")},
       {QStringLiteral("queuePosition"), position},
       {QStringLiteral("userMessageId"), QStringLiteral("message-wake")}});
}

QVariantList toasts(World& world) {
  return world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList();
}

// The composer the window shows: the open thread's, or a new thread's draft.
QString composerTarget(World& world) {
  const QVariantMap route = world.state(QStringLiteral("route")).toMap();
  if (route.value(QStringLiteral("kind")) == QLatin1String("draft")) return route.value(QStringLiteral("draftId")).toString();
  return world.native().controller<NavigationController>()->threadKey();
}

void typeInto(World& world, const QString& text) {
  world.bridge().dispatch(QStringLiteral("composer.text.set"),
                          QVariantMap{{QStringLiteral("target"), composerTarget(world)},
                                      {QStringLiteral("text"), text},
                                      {QStringLiteral("cursor"), text.size()}});
}

QString draftOf(World& world, const QString& key) {
  return world.native().controller<ComposerController>()->draft(key);
}

QString openDraft(World& world) {
  return draftOf(world, composerTarget(world));
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
  // Shared with WorkspaceSteps' renames: the message is why the pending
  // approval cannot be answered, a toast, or what Source Control settings
  // shows instead of the tools it found.
  step(QStringLiteral("the user is told %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const auto told = [&] {
      for (const QVariant& item : listed(world, QStringLiteral("approvals"))) {
        if (item.toMap().value(QStringLiteral("problem")) == c[0]) return true;
      }
      // What the file viewer and its path trail say in place of a file or a folder's list.
      if (auto* panel = world.native().controller<RightPanelController>(); panel && panel->files()) {
        if (panel->files()->fileProblem() == c[0] || panel->files()->trailProblem() == c[0]) return true;
      }
      // Why the pull request thread dialog cannot go on.
      if (world.state(QStringLiteral("pullRequestThread")).toMap().value(QStringLiteral("error")) == c[0]) return true;
      // What the attachment viewer says when it could not fetch.
      if (world.state(QStringLiteral("attachmentViewer")).toMap().value(QStringLiteral("problem")) == c[0]) return true;
      // A toast is told by its title, its description, or as "title — description".
      for (const QVariant& item : toasts(world)) {
        const QString title = item.toMap().value(QStringLiteral("title")).toString();
        const QString description = item.toMap().value(QStringLiteral("description")).toString();
        if (title == c[0] || description == c[0] || title + QStringLiteral(" — ") + description == c[0]) return true;
      }
      const QVariantMap discovery = world.state(QStringLiteral("sourceControlSettings")).toMap().value(QStringLiteral("discovery")).toMap();
      if (discovery.value(QStringLiteral("title")) == c[0]) return true;
      // What came of spending a reset credit on the usage page.
      const QVariantList pools = world.state(QStringLiteral("usage")).toMap().value(QStringLiteral("limits")).toMap()
                                     .value(QStringLiteral("pools")).toList();
      for (const QVariant& pool : pools) {
        for (const QVariant& credit : pool.toMap().value(QStringLiteral("credits")).toList()) {
          if (credit.toMap().value(QStringLiteral("status")) == c[0]) return true;
        }
      }
      // Or what an open command palette says of its search.
      if (auto* palette = world.native().controller<CommandPaletteController>(); palette && palette->isOpen() &&
                                                                               !palette->searching() &&
                                                                               (palette->emptyText() == c[0] || palette->status() == c[0])) {
        return true;
      }
      // Or the welcome wizard's pairing, setup terminal or import error.
      if (onboardingTells(world, c[0])) return true;
      if (world.toldInPlace && world.toldInPlace().contains(c[0])) return true;
      // Or why the add-provider wizard does not take the instance id.
      if (at(world.state(QStringLiteral("providerSettings")), QStringLiteral("wizard.instanceIdError")) == c[0]) return true;
      // Or what a brick on screen says.
      if (world.brick && world.brick->shows(c[0])) return true;
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
         world.mc.refusals.insert(QStringLiteral("runtime-request.respond"),
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
    if (composerMessageReceived(world, c[0])) return;
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
    expect(receivedAnswer(world) == QVariant(QStringLiteral("SQLite")), QStringLiteral("the answer did not reach the MC"));
  });
  step(QStringLiteral("the agent has asked %1 with options %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    startWorking(world);
    question(world, c[0], {c[1], c[2]});
  });
  step(QStringLiteral("the composer is on screen"), [](World& world, const Captures&, const Table&) { composerBrick(world); });
  step(QStringLiteral("the agent asks two long questions in place of the first"), [](World& world, const Captures&, const Table&) {
    const QString requestId = first(world, QStringLiteral("questions")).value(QStringLiteral("requestId")).toString();
    set(world, QStringLiteral("runtime-request"), requestId, {{QStringLiteral("status"), QStringLiteral("resolved")}});
    request(world, QStringLiteral("user_input_request"), longQuestions());
  });
  step(QStringLiteral("the questions, their options and the answer button sit above the composer's editor"),
       [](World& world, const Captures&, const Table&) {
         composerBrick(world);
         world.waitFor([&] { return composerPart(world, QStringLiteral("questionAnswer-direction")) != nullptr; },
                       QStringLiteral("the second question to show"));
         const qreal editorTop = composerEditor(world)->mapToScene(QPointF()).y();
         for (const QString& part : {QStringLiteral("questionOption-Yes, start now (Recommended)"), QStringLiteral("questionAnswer-lint"),
                                     QStringLiteral("questionOption-Decide later"), QStringLiteral("questionAnswer-direction"),
                                     QStringLiteral("questionSubmit")}) {
           QQuickItem* item = composerPart(world, part);
           expect(item != nullptr, QStringLiteral("the composer has no %1").arg(part));
           const qreal top = item->mapToScene(QPointF()).y();
           const qreal bottom = item->mapToScene(QPointF(0, item->height())).y();
           expect(item->isVisible() && top >= 0 && bottom <= editorTop,
                  QStringLiteral("%1 (visible: %2) spans %3..%4, the editor starts at %5")
                      .arg(part)
                      .arg(item->isVisible())
                      .arg(top)
                      .arg(bottom)
                      .arg(editorTop));
         }
       });
  step(QStringLiteral("the user dismisses the question without answering"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("composer.question.dismiss"),
                            QVariantMap{{QStringLiteral("requestId"), first(world, QStringLiteral("questions")).value(QStringLiteral("requestId"))}});
    world.sync();
  });
  step(QStringLiteral("the agent is told the question was dismissed"), [](World& world, const Captures&, const Table&) {
    const QJsonObject command = lastCommand(world, QStringLiteral("thread.user-input.dismiss"));
    expect(command.value(QLatin1String("threadId")) == kThread && !command.value(QLatin1String("requestId")).toString().isEmpty(),
           QStringLiteral("the MC was told %1").arg(show(command.toVariantMap())));
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
           QStringLiteral("the MC was sent %1").arg(show(message.toVariantMap())));
    const QJsonObject mode = lastCommand(world, QStringLiteral("thread.interaction-mode.set"));
    expect(mode.value(QLatin1String("interactionMode")) == QLatin1String("default"), QStringLiteral("the thread was set to %1").arg(show(mode.toVariantMap())));
  });
  step(QStringLiteral("the plan card is no longer offered"), [](World& world, const Captures&, const Table&) {
    // What the MC does with the message's sourcePlanRef.
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
           QStringLiteral("the MC was sent %1").arg(show(message.toVariantMap())));
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

  // A plan of a given shape (ProposedPlanCard's preview, its title and file
  // name, and its export).
  const auto offered = [](World& world, const QString& markdown) {
    proposePlan(world, true, markdown);
    world.waitFor([&] { return turn(world).value(QStringLiteral("plan")).isValid(); },
                  [&] { return QStringLiteral("the plan to be offered; the turn is %1").arg(show(turn(world))); });
  };
  step(QStringLiteral("the agent has proposed a plan (?:titled|headed) %1").arg(q), [offered](World& world, const Captures& c, const Table&) {
    const QString steps = QStringLiteral("- Add the line\n- Test it");
    offered(world, c[0] == QLatin1String("(no heading)") ? steps : QStringLiteral("# %1\n\n%2").arg(c[0], steps));
  });
  step(QStringLiteral("the agent has proposed a plan (of 30 short lines|of 1,000 characters on 5 lines|of 15 short lines|with no heading|with trailing blank lines)"),
       [offered](World& world, const Captures& c, const Table&) {
         QStringList lines;
         if (c[0] == QLatin1String("with no heading")) return offered(world, QStringLiteral("- Add the line\n- Test it"));
         if (c[0] == QLatin1String("with trailing blank lines")) return offered(world, kPlanMarkdown + QStringLiteral("\n\n\n  \n"));
         if (c[0] == QLatin1String("of 1,000 characters on 5 lines")) {
           for (int n = 1; n <= 5; ++n) lines.append(QStringLiteral("- Step %1 ").arg(n) + QString(200, QLatin1Char('x')));
         } else {
           const int count = c[0] == QLatin1String("of 30 short lines") ? 30 : 15;
           for (int n = 1; n <= count; ++n) lines.append(QStringLiteral("- Step %1").arg(n));
         }
         offered(world, QStringLiteral("# Tax line\n\n") + lines.join(QLatin1Char('\n')));
       });
  step(QStringLiteral("the user's message reads %1 followed by the plan").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject message = lastMessage(world);
    const QString expected = c[0] + QLatin1Char('\n') + proposedTurnPlan(world).trimmed();
    expect(message.value(QLatin1String("threadId")) == kThread && message.value(QLatin1String("text")).toString() == expected,
           QStringLiteral("the MC was sent %1").arg(show(message.toVariantMap())));
  });
  step(QStringLiteral("the thread leaves plan mode"), [](World& world, const Captures&, const Table&) {
    const QJsonObject mode = lastCommand(world, QStringLiteral("thread.interaction-mode.set"));
    expect(mode.value(QLatin1String("interactionMode")) == QLatin1String("default"), QStringLiteral("the thread was set to %1").arg(show(mode.toVariantMap())));
  });

  // The plan above the composer (ComposerPlanFollowUpBanner) and what
  // sending does to it (ComposerPrimaryActions).
  const auto said = [](World& world, const QString& name) {
    QQuickItem* item = turnRequestsBrick(world).find(name);
    return item && item->isVisible() ? item->property("text").toString() : QString();
  };
  step(QStringLiteral("the composer says %1 with %1").arg(q), [said](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return said(world, QStringLiteral("planReady")) == c[0] && said(world, QStringLiteral("planHeading")) == c[1]; },
                  [&] { return QStringLiteral("the composer says \"%1\" with \"%2\"").arg(said(world, QStringLiteral("planReady")), said(world, QStringLiteral("planHeading"))); });
  });
  step(QStringLiteral("a plan with no heading is announced as %1 alone").arg(q), [said](World& world, const Captures& c, const Table&) {
    set(world, QStringLiteral("plan"), QStringLiteral("plan-1"), {{QStringLiteral("markdown"), QStringLiteral("- Add the line\n- Test it")}});
    world.waitFor([&] { return said(world, QStringLiteral("planReady")) == c[0] && said(world, QStringLiteral("planHeading")).isEmpty(); },
                  [&] { return QStringLiteral("the composer says \"%1\" with \"%2\"").arg(said(world, QStringLiteral("planReady")), said(world, QStringLiteral("planHeading"))); });
  });
  const auto offers = [said](World& world, const QString& action, const QString& label) {
    world.waitFor([&] {
      return world.state(QStringLiteral("composer")).toMap().value(QStringLiteral("planAction")) == action && said(world, QStringLiteral("planImplement")) == label;
    }, [&] {
      return QStringLiteral("the composer offers \"%1\" (%2)").arg(said(world, QStringLiteral("planImplement")),
                                                                 world.state(QStringLiteral("composer")).toMap().value(QStringLiteral("planAction")).toString());
    });
  };
  step(QStringLiteral("the composer offers to implement the plan(?: again)?"), [offers](World& world, const Captures&, const Table&) {
    offers(world, QStringLiteral("implement"), QStringLiteral("Implement"));
  });
  step(QStringLiteral("the composer offers to refine the plan instead"), [offers](World& world, const Captures&, const Table&) {
    offers(world, QStringLiteral("refine"), QStringLiteral("Refine"));
  });
  step(QStringLiteral("the user clears the composer"), [](World& world, const Captures&, const Table&) {
    typeInto(world, QString());
    world.sync();
  });

  // Feedback the MC does not take.
  step(QStringLiteral("the environment refuses new messages"), [](World& world, const Captures&, const Table&) {
    world.mc.refusals.insert(QStringLiteral("message.dispatch"), QStringLiteral("Provider unavailable"));
  });
  step(QStringLiteral("the feedback is no longer shown as a sent message"), [](World& world, const Captures&, const Table&) {
    const QString feedback = QStringLiteral("split the migration into its own step");
    world.waitFor([&] { return !world.state(QStringLiteral("composer")).toMap().value(QStringLiteral("isSendBusy")).toBool(); },
                  QStringLiteral("the send to settle"));
    TimelineModel& model = timeline(world);
    for (int row = 0; row < model.rowCount(); ++row) {
      expect(role(model, row, TimelineModel::TextRole).toString() != feedback, QStringLiteral("the timeline shows %1").arg(describe(model)));
    }
    for (const QVariant& queued : listed(world, QStringLiteral("queue"))) {
      expect(queued.toMap().value(QStringLiteral("text")) != feedback, QStringLiteral("the queue shows %1").arg(show(queued)));
    }
  });
  step(QStringLiteral("the thread shows the reason, or %1 when none is given").arg(q), [](World& world, const Captures& c, const Table&) {
    const auto told = [&](const QString& description) {
      world.waitFor([&] {
        for (const QVariant& item : toasts(world)) {
          const QVariantMap toast = item.toMap();
          if (toast.value(QStringLiteral("title")) == QLatin1String("Plan follow-up not sent") && toast.value(QStringLiteral("description")) == description) return true;
        }
        return false;
      }, [&] { return QStringLiteral("\"%1\"; the toasts are %2").arg(description, show(world.state(QStringLiteral("toasts")))); });
    };
    told(QStringLiteral("Provider unavailable"));
    // Again, with no reason given.
    world.mc.refusals.insert(QStringLiteral("message.dispatch"), QString());
    world.bridge().dispatch(QStringLiteral("composer.submit"), QVariantMap{{QStringLiteral("text"), QStringLiteral("and keep the docs")}, {QStringLiteral("intent"), QStringLiteral("foreground")}});
    world.sync();
    told(c[0]);
  });

  // The agent's task list above the composer (ComposerTasksBadge).
  struct Tasks {
    QJsonArray steps;
  };
  const auto report = [](World& world) {
    const QString run = world.mc.part<FakeStreams>().run;
    set(world, QStringLiteral("plan"), QStringLiteral("todo-1"),
        {{QStringLiteral("id"), QStringLiteral("todo-1")},
         {QStringLiteral("kind"), QStringLiteral("todo_list")},
         {QStringLiteral("status"), QStringLiteral("active")},
         {QStringLiteral("runId"), run},
         {QStringLiteral("steps"), world.mc.part<Tasks>().steps}});
  };
  const auto task = [](const QString& text, const QString& status, std::optional<int> seconds = {}) {
    QJsonObject step{{QStringLiteral("id"), text}, {QStringLiteral("text"), text}, {QStringLiteral("status"), status}};
    if (seconds) step.insert(QStringLiteral("durationMs"), *seconds * 1000);
    return step;
  };
  const auto list = [report, task](World& world, const QStringList& texts) {
    startWorking(world);
    QJsonArray& steps = world.mc.part<Tasks>().steps;
    for (const QString& text : texts) steps.append(task(text, QStringLiteral("pending")));
    report(world);
  };
  const auto openTasks = [](World& world) {
    Brick& brick = turnRequestsBrick(world);
    world.waitFor([&] { return brick.find(QStringLiteral("tasksToggle")) && brick.find(QStringLiteral("tasksToggle"))->isVisible(); },
                  [&] { return QStringLiteral("the task summary; the turn is %1").arg(show(turn(world))); });
    brick.click(QStringLiteral("tasksToggle"));
    world.waitFor([&] { return brick.root()->property("tasksOpen").toBool(); }, QStringLiteral("the task list to open"));
  };
  const auto stepsShown = [](World& world) {
    QList<QQuickItem*> found;
    std::function<void(QQuickItem*)> walk = [&](QQuickItem* item) {
      if (item->objectName() == QLatin1String("taskStep") && item->isVisible()) found.append(item);
      for (QQuickItem* child : item->childItems()) walk(child);
    };
    walk(turnRequestsBrick(world).root());
    return found;
  };
  step(QStringLiteral("the agent's task list has the steps (.+)"), [list](World& world, const Captures& c, const Table&) {
    static const QRegularExpression quoted(QStringLiteral("\"([^\"]*)\""));
    QStringList texts;
    for (auto it = quoted.globalMatch(c[0]); it.hasNext();) texts.append(it.next().captured(1));
    list(world, texts);
  });
  step(QStringLiteral("%1 is finished and %1 is in progress").arg(q), [report](World& world, const Captures& c, const Table&) {
    QJsonArray& steps = world.mc.part<Tasks>().steps;
    for (qsizetype n = 0; n < steps.size(); ++n) {
      QJsonObject step = steps.at(n).toObject();
      if (step.value(QLatin1String("text")) == c[0]) step.insert(QStringLiteral("status"), QStringLiteral("completed"));
      if (step.value(QLatin1String("text")) == c[1]) step.insert(QStringLiteral("status"), QStringLiteral("running"));
      steps.replace(n, step);
    }
    report(world);
  });
  step(QStringLiteral("the composer shows %1 with the current step %1 and (\\d+) of (\\d+) done").arg(q), [said](World& world, const Captures& c, const Table&) {
    QQuickItem* card = nullptr;
    world.waitFor([&] {
      card = turnRequestsBrick(world).find(QStringLiteral("tasks"));
      return card && card->isVisible() && turnRequestsBrick(world).shows(c[0]) && said(world, QStringLiteral("tasksCurrent")) == c[1] &&
             said(world, QStringLiteral("tasksProgress")) == QStringLiteral("%1/%2").arg(c[2], c[3]);
    }, [&] {
      return QStringLiteral("the task summary reads \"%1\" %2; the turn is %3")
          .arg(said(world, QStringLiteral("tasksCurrent")), said(world, QStringLiteral("tasksProgress")), show(turn(world)));
    });
  });
  step(QStringLiteral("the agent finished %1 in (\\d+) seconds and is working on %1").arg(q), [report, task](World& world, const Captures& c, const Table&) {
    startWorking(world);
    QJsonArray& steps = world.mc.part<Tasks>().steps;
    steps.append(task(c[0], QStringLiteral("completed"), c[1].toInt()));
    steps.append(task(c[2], QStringLiteral("running")));
    report(world);
  });
  step(QStringLiteral("%1 has not started").arg(q), [report, task](World& world, const Captures& c, const Table&) {
    world.mc.part<Tasks>().steps.append(task(c[0], QStringLiteral("pending")));
    report(world);
  });
  step(QStringLiteral("the user opens the task summary"), [openTasks](World& world, const Captures&, const Table&) { openTasks(world); });
  step(QStringLiteral("%1 is listed as (completed|running|pending) with (?:%1|no time)").arg(q), [stepsShown](World& world, const Captures& c, const Table&) {
    QStringList listed;
    for (QQuickItem* item : stepsShown(world)) {
      const QString step = item->property("step").toString();
      const QString status = item->property("status").toString();
      const QString duration = item->property("duration").toString();
      if (step == c[0] && status == c[1] && duration == c[2]) return;
      listed.append(QStringLiteral("%1 %2 \"%3\"").arg(step, status, duration));
    }
    fail(QStringLiteral("the task list shows [%1]").arg(listed.join(QStringLiteral(", "))));
  });
  step(QStringLiteral("the agent has reported no task list"), [](World& world, const Captures&, const Table&) { startWorking(world); });
  step(QStringLiteral("the agent's task list is open and (an approval comes in|the agent asks a question)"),
       [list, openTasks](World& world, const Captures& c, const Table&) {
         list(world, {QStringLiteral("Add the tax line"), QStringLiteral("Write tests")});
         openTasks(world);
         if (c[0] == QLatin1String("an approval comes in")) {
           approval(world, QStringLiteral("command"), QStringLiteral("npm test"));
         } else {
           question(world, QStringLiteral("Which database?"), {QStringLiteral("Postgres"), QStringLiteral("SQLite")});
         }
       });
  step(QStringLiteral("the composer shows no task summary"), [](World& world, const Captures&, const Table&) {
    world.sync();
    QQuickItem* card = turnRequestsBrick(world).find(QStringLiteral("tasks"));
    expect(!turn(world).value(QStringLiteral("tasks")).isValid() && (!card || !card->isVisible()),
           QStringLiteral("the composer shows tasks; the turn is %1").arg(show(turn(world))));
  });
  step(QStringLiteral("the user opened the task summary in thread A"), [list, openTasks](World& world, const Captures&, const Table&) {
    list(world, {QStringLiteral("Add the tax line"), QStringLiteral("Write tests")});
    openTasks(world);
  });
  step(QStringLiteral("the task list is closed and only its summary is shown"), [stepsShown](World& world, const Captures&, const Table&) {
    Brick& brick = turnRequestsBrick(world);
    world.waitFor([&] { return brick.find(QStringLiteral("tasks")) && brick.find(QStringLiteral("tasks"))->isVisible(); },
                  [&] { return QStringLiteral("the task summary; the turn is %1").arg(show(turn(world))); });
    expect(!brick.root()->property("tasksOpen").toBool() && stepsShown(world).isEmpty(),
           QStringLiteral("the task list shows %1 steps").arg(stepsShown(world).size()));
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
           QStringLiteral("the MC was sent %1").arg(show(message.toVariantMap())));
  });
  step(QStringLiteral("%1 steers the running turn").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject message = lastMessage(world);
    expect(message.value(QLatin1String("text")) == c[0] && message.value(QLatin1String("deliveryIntent")) == QLatin1String("steer") &&
               message.value(QLatin1String("dispatchMode")).toObject().value(QLatin1String("type")) == QLatin1String("start_immediately"),
           QStringLiteral("the MC was sent %1").arg(show(message.toVariantMap())));
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
    expect(command.value(QLatin1String("runId")) == world.mc.part<FakeStreams>().run, QStringLiteral("the MC was told %1").arg(show(command.toVariantMap())));
  });
  step(QStringLiteral("%1 and %1 are queued").arg(q), [](World& world, const Captures& c, const Table&) {
    queueMessage(world, c[0]);
    queueMessage(world, c[1]);
  });
  // What the MC queued for the agent itself (delegation.ex and the Claude
  // runtime's wake): `fields` are what its message carries.
  const auto queueForAgent = [](const QString& text, const QJsonObject& fields) {
    return [text, fields](World& world, const Captures&, const Table&) {
      queueMessage(world, text);
      set(world, QStringLiteral("message"), QStringLiteral("message-") + text, fields);
    };
  };
  const QJsonObject completion{{QStringLiteral("taskId"), QStringLiteral("task:1")}, {QStringLiteral("status"), QStringLiteral("completed")}};
  step(QStringLiteral("the MC queued a delegated task's result for the agent"),
       queueForAgent(QStringLiteral("<delegated_task_result taskId=\"task:1\">done</delegated_task_result>"),
                     {{QStringLiteral("delegatedCompletion"), completion},
                      {QStringLiteral("notification"), QJsonObject{{QStringLiteral("outcome"), QStringLiteral("completed")}, {QStringLiteral("summary"), QStringLiteral("Tax tests finished")}}}}));
  step(QStringLiteral("the MC queued a delegated task's result stored before results were notifications for the agent"),
       queueForAgent(QStringLiteral("<delegated_task_result taskId=\"task:1\" title=\"Tax tests\" status=\"completed\" childThreadId=\"thread-9\">\n"
                                    "done\n</delegated_task_result>"),
                     {{QStringLiteral("delegatedCompletion"), completion}, {QStringLiteral("createdBy"), QStringLiteral("system")}}));
  step(QStringLiteral("the MC queued the agent's own wake-up for the agent"),
       queueForAgent(QStringLiteral("Background task completed."),
                     {{QStringLiteral("providerWake"), true},
                      {QStringLiteral("notification"), QJsonObject{{QStringLiteral("outcome"), QStringLiteral("updated")}, {QStringLiteral("summary"), QStringLiteral("Background activity updated")}}}}));
  step(QStringLiteral("the composer lists only the queued message %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QStringList texts;
    for (const QVariant& queued : listed(world, QStringLiteral("queue"))) texts.append(queued.toMap().value(QStringLiteral("text")).toString());
    expect(texts == QStringList{c[0]}, QStringLiteral("the queue lists %1").arg(texts.join(QStringLiteral(" | "))));
  });
  step(QStringLiteral("the composer shows %1 waiting behind it").arg(q), [](World& world, const Captures& c, const Table&) {
    QStringList summaries;
    for (const QVariant& waiting : listed(world, QStringLiteral("waiting"))) summaries.append(waiting.toMap().value(QStringLiteral("summary")).toString());
    expect(summaries == QStringList{c[0]}, QStringLiteral("waiting behind the queue: %1").arg(summaries.join(QStringLiteral(" | "))));
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
  step(QStringLiteral("the MC is asked to cancel the queued run of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject command = lastCommand(world, QStringLiteral("queued-run.cancel"));
    expect(command.value(QLatin1String("runId")) == QStringLiteral("run-queued-") + c[0], QStringLiteral("the MC was told %1").arg(show(command.toVariantMap())));
  });
  step(QStringLiteral("the MC is asked to steer the running turn with the queued run of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject command = lastCommand(world, QStringLiteral("queued-message.promote-to-steer"));
    expect(command.value(QLatin1String("queuedRunId")) == QStringLiteral("run-queued-") + c[0] &&
               command.value(QLatin1String("targetRunId")) == world.mc.part<FakeStreams>().run,
           QStringLiteral("the MC was told %1").arg(show(command.toVariantMap())));
  });

  // A queue the MC holds after a restart (HalC2.Orchestration.Recovery marks its
  // queued runs `queueHeld`) is resumed from the card the TurnRequests brick draws.
  step(QStringLiteral("%1 was queued when the MC restarted").arg(q), [](World& world, const Captures& c, const Table&) {
    queueMessage(world, c[0]);
  });
  step(QStringLiteral("a provider wake was queued when the MC restarted"), [](World& world, const Captures&, const Table&) { queueWake(world); });
  step(QStringLiteral("the MC comes back"), [](World& world, const Captures&, const Table&) {
    for (const QVariant& entry : listed(world, QStringLiteral("queue")) + listed(world, QStringLiteral("waiting"))) {
      set(world, QStringLiteral("run"), entry.toMap().value(QStringLiteral("runId")).toString(), {{QStringLiteral("queueHeld"), true}});
    }
    world.waitFor([&] { return turn(world).value(QStringLiteral("queueHeld")).toBool(); },
                  [&] { return QStringLiteral("the queue to be held; the turn is %1").arg(show(turn(world))); });
  });
  const auto requestsBrick = [](World& world) -> Brick& {
    if (world.brick && world.brick->root() && world.brick->root()->objectName() == QLatin1String("turnRequestsBrick")) return *world.brick;
    world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nTurnRequests { objectName: \"turnRequestsBrick\" }\n", QSize(820, 500));
    return *world.brick;
  };
  step(QStringLiteral("the queue is headed %1 and says %1").arg(q), [requestsBrick](World& world, const Captures& c, const Table&) {
    Brick& brick = requestsBrick(world);
    world.waitFor([&] { return brick.shows(c[0]) && brick.shows(c[1]); },
                  [&] { return QStringLiteral("the queue to read \"%1\" and \"%2\"; the turn is %3").arg(c[0], c[1], show(turn(world))); });
  });
  step(QStringLiteral("the user resumes the queue"), [requestsBrick](World& world, const Captures&, const Table&) {
    Brick& brick = requestsBrick(world);
    world.waitFor([&] { return brick.item(QStringLiteral("queueResume"))->isVisible(); }, QStringLiteral("the queue's Resume queue button"));
    brick.click(QStringLiteral("queueResume"));
    world.sync();
  });
  step(QStringLiteral("the MC is asked to resume the queue"), [](World& world, const Captures&, const Table&) {
    const QJsonObject command = lastCommand(world, QStringLiteral("queue.resume"));
    expect(command.value(QLatin1String("threadId")) == kThread, QStringLiteral("the MC was told %1").arg(show(command.toVariantMap())));
  });
  step(QStringLiteral("the MC is not asked to resume the queue"), [](World& world, const Captures&, const Table&) {
    const QList<QJsonObject> found = commandsOf(world, QStringLiteral("queue.resume"));
    expect(found.isEmpty(), QStringLiteral("the MC has %1").arg(world.describeCommands()));
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
  step(QStringLiteral("the MC is asked to change the queued run of %1 to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject command = lastCommand(world, QStringLiteral("queued-run.edit"));
    expect(command.value(QLatin1String("runId")) == QStringLiteral("run-queued-") + c[0] && command.value(QLatin1String("text")) == c[1],
           QStringLiteral("the MC was told %1").arg(show(command.toVariantMap())));
  });
  step(QStringLiteral("the MC is asked to change the queued run of %1 to %1 without attachments").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject command = lastCommand(world, QStringLiteral("queued-run.edit"));
    expect(command.value(QLatin1String("runId")) == QStringLiteral("run-queued-") + c[0] && command.value(QLatin1String("text")) == c[1] &&
               command.contains(QLatin1String("attachments")) && command.value(QLatin1String("attachments")).toArray().isEmpty(),
           QStringLiteral("the MC was told %1").arg(show(command.toVariantMap())));
  });

  // A queued message's attachments, on its row in the queue card.
  step(QStringLiteral("%1 is queued with the file %1").arg(q), [](World& world, const Captures& c, const Table&) {
    queueMessage(world, c[0]);
    set(world, QStringLiteral("message"), QStringLiteral("message-") + c[0],
        {{QStringLiteral("attachments"), QJsonArray{QJsonObject{{QStringLiteral("type"), QStringLiteral("file")},
                                                                {QStringLiteral("id"), QStringLiteral("file-") + c[1]},
                                                                {QStringLiteral("name"), c[1]},
                                                                {QStringLiteral("mimeType"), QStringLiteral("text/markdown")},
                                                                {QStringLiteral("sizeBytes"), 12}}}}});
  });
  step(QStringLiteral("the queue shows %1 on %1").arg(q), [requestsBrick](World& world, const Captures& c, const Table&) {
    Brick& brick = requestsBrick(world);
    world.waitFor([&] { return brick.shows(c[0]) && brick.shows(c[1]); },
                  [&] { return QStringLiteral("\"%1\" on \"%2\"; the turn is %3").arg(c[0], c[1], show(turn(world))); });
    expect(brick.item(QStringLiteral("queueAttachment-file-") + c[0])->isVisible(), QStringLiteral("the attachment is hidden"));
  });
  step(QStringLiteral("the user opens %1 from the queue").arg(q), [requestsBrick](World& world, const Captures& c, const Table&) {
    requestsBrick(world).click(QStringLiteral("queueAttachment-file-") + c[0]);
    world.sync();
  });
  step(QStringLiteral("the attachment viewer shows %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return world.state(QStringLiteral("attachmentViewer")).toMap().value(QStringLiteral("name")) == c[0]; },
                  [&] { return QStringLiteral("the viewer shows %1").arg(show(world.state(QStringLiteral("attachmentViewer")))); });
  });
  step(QStringLiteral("the queued message still reads %1").arg(q),[](World& world, const Captures& c, const Table&) {
    QStringList texts;
    for (const QVariant& queued : listed(world, QStringLiteral("queue"))) texts.append(queued.toMap().value(QStringLiteral("text")).toString());
    expect(texts.contains(c[0]) && commandsOf(world, QStringLiteral("queued-run.edit")).isEmpty(),
           QStringLiteral("the queue is [%1] and the MC has %2").arg(texts.join(QStringLiteral(", ")), world.describeCommands()));
  });

  // Answers in flight.
  step(QStringLiteral("the user approves it"), [](World& world, const Captures&, const Table&) { respond(world, QStringLiteral("accept")); });
  step(QStringLiteral("the approval shows it is being answered"), [](World& world, const Captures&, const Table&) {
    const QVariantMap shown = first(world, QStringLiteral("approvals"));
    expect(shown.value(QStringLiteral("responding")).toBool(), QStringLiteral("the approval is %1").arg(show(shown)));
  });
  step(QStringLiteral("the MC receives one answer"), [](World& world, const Captures&, const Table&) {
    const qsizetype answers = commandsOf(world, QStringLiteral("runtime-request.respond")).size();
    expect(answers == 1, QStringLiteral("the MC received %1 answers").arg(answers));
  });

  // Drafts.
  const auto threadB = [](World& world) {
    const QString id = QStringLiteral("thread-2");
    if (!world.mc.threads.contains(id)) {
      world.mc.threads.insert(id, {{QStringLiteral("id"), id}, {QStringLiteral("title"), QStringLiteral("Other")}, {QStringLiteral("projectId"), kProject},
                                     {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")}, {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}});
      world.mc.sendRow(id, world.mc.threads.value(id));
      world.sync();
    }
    return world.mc.environmentId + QStringLiteral(":") + id;
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
    world.mc.stopAccepting();
    world.mc.drop();
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
    expect(world.mc.commands.isEmpty(), QStringLiteral("the MC has %1").arg(world.describeCommands()));
  });
  step(QStringLiteral("the draft (?:still reads %1|reads %1 again)").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString expected = c[0].isEmpty() ? c[1] : c[0];
    world.waitFor([&] { return openDraft(world) == expected; }, [&] { return QStringLiteral("the draft reads \"%1\"").arg(openDraft(world)); });
  });
  step(QStringLiteral("the user sends it and the MC rejects the message"), [](World& world, const Captures&, const Table&) {
    world.mc.refusals.insert(QStringLiteral("message.dispatch"), QStringLiteral("Provider unavailable"));
    world.bridge().dispatch(QStringLiteral("composer.submit"), QVariantMap{{QStringLiteral("text"), openDraft(world)}, {QStringLiteral("intent"), QStringLiteral("foreground")}});
    world.sync();
  });
  step(QStringLiteral("the user sends it and the MC cannot start the thread"), [](World& world, const Captures&, const Table&) {
    world.mc.refusals.insert(QStringLiteral("orchestration.launchThread"), QStringLiteral("Provider unavailable"));
    world.bridge().dispatch(QStringLiteral("composer.submit"), QVariantMap{{QStringLiteral("text"), openDraft(world)}, {QStringLiteral("intent"), QStringLiteral("foreground")}});
    world.sync();
    world.waitFor([&] { return draftOf(world, world.draftId) == QLatin1String("Fix the failing test"); },
                  [&] { return QStringLiteral("the draft reads \"%1\"").arg(draftOf(world, world.draftId)); });
  });
  step(QStringLiteral("the new thread's draft reads %1 with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    auto* composer = world.native().controller<ComposerController>();
    const auto names = [&] {
      QStringList all;
      for (const QVariant& attachment : composer->attachments(world.draftId)) all.append(attachment.toMap().value(QStringLiteral("name")).toString());
      return all;
    };
    world.waitFor([&] { return composer->draft(world.draftId) == c[0] && names() == QStringList{c[1]}; },
                  [&] { return QStringLiteral("the draft reads \"%1\" with [%2]").arg(composer->draft(world.draftId), names().join(u", ")); });
  });
  step(QStringLiteral("the user starts a new thread in the project"), [](World& world, const Captures&, const Table&) {
    world.startNewThread(QVariantMap{{QStringLiteral("projectKey"), world.projectKey(kProject)}});
    expect(!world.draftId.isEmpty(), show(world.state(QStringLiteral("route"))));
  });
  step(QStringLiteral("the user sends it before the MC answers"), [](World& world, const Captures&, const Table&) {
    world.mc.hold(QStringLiteral("answers"));
    world.bridge().dispatch(QStringLiteral("composer.submit"), QVariantMap{{QStringLiteral("text"), openDraft(world)}, {QStringLiteral("intent"), QStringLiteral("foreground")}});
    world.sync();
  });
  step(QStringLiteral("the user types %1 while it is sending").arg(q), [](World& world, const Captures& c, const Table&) { typeInto(world, c[0]); });
  step(QStringLiteral("the new thread's composer reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const auto opened = [&world] { return world.state(QStringLiteral("route")).toMap().value(QStringLiteral("kind")) == QLatin1String("thread"); };
    world.waitFor([&] { return opened() && openDraft(world) == c[0]; },
                  [&] { return QStringLiteral("the %1 composer reads \"%2\"").arg(opened() ? QStringLiteral("thread's") : QStringLiteral("draft's"), openDraft(world)); });
  });
  step(QStringLiteral("the MC takes the message"), [](World& world, const Captures&, const Table&) {
    world.mc.answerHeld();
    world.sync();
  });
  step(QStringLiteral("the thread (no longer )?says the message is sending"), [](World& world, const Captures& c, const Table&) {
    // An optional group that did not match is left out of the captures.
    const bool sending = c.value(0).isEmpty();
    const auto busy = [&world] { return world.state(QStringLiteral("composer")).toMap().value(QStringLiteral("isSendBusy")).toBool(); };
    world.waitFor([&] { return busy() == sending; }, [&] { return QStringLiteral("the composer's send is %1busy").arg(busy() ? QString() : QStringLiteral("not ")); });
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

void startWorkingTurn(World& world) {
  startWorking(world);
}

void queueTurnMessage(World& world, const QString& text) {
  queueMessage(world, text);
}

void proposeTurnPlan(World& world, const QString& markdown) {
  proposePlan(world, true, markdown);
}

QString proposedTurnPlan(World& world) {
  const QString markdown = world.mc.part<ProposedPlan>().markdown;
  return markdown.isEmpty() ? kPlanMarkdown : markdown;
}

Brick& turnRequestsBrick(World& world) {
  if (!world.brick) world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nTurnRequests {}\n", QSize(820, 500));
  return *world.brick;
}

bool planFeedbackTypes(World& world, const QString& text) {
  if (auto* palette = world.native().controller<CommandPaletteController>(); palette && palette->isOpen()) return false;
  if (!turn(world).value(QStringLiteral("plan")).isValid()) return false;
  typeInto(world, text);
  world.sync();
  return true;
}
