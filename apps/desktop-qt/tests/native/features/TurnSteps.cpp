// The composer's turn on an open thread: the agent's requests and questions,
// its proposed plan, queued messages and follow-ups, as the MC streams them,
// and what the user's answers send (the `turn` key ComposerController
// publishes, and the commands the MC receives). The thread's stream is
// Stream.h's.

#include <QFont>
#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>
#include <QRegularExpression>
#include <QTest>
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

// Several questions in one request, as Claude's AskUserQuestion asks them:
// "Which database?", "Which cache?" and "Which queue?", each with two options,
// in place of the question the agent asked first.
const QHash<QString, QPair<QString, QStringList>> kAsked{
    {QStringLiteral("Which database?"), {QStringLiteral("database"), {QStringLiteral("Postgres"), QStringLiteral("SQLite")}}},
    {QStringLiteral("Which cache?"), {QStringLiteral("cache"), {QStringLiteral("Redis"), QStringLiteral("Memcached")}}},
    {QStringLiteral("Which queue?"), {QStringLiteral("queue"), {QStringLiteral("RabbitMQ"), QStringLiteral("SQS")}}},
};

void askTogether(World& world, const QStringList& texts) {
  const QString requestId = first(world, QStringLiteral("questions")).value(QStringLiteral("requestId")).toString();
  set(world, QStringLiteral("runtime-request"), requestId, {{QStringLiteral("status"), QStringLiteral("resolved")}});
  QJsonArray asked;
  for (const QString& text : texts) {
    expect(kAsked.contains(text), QStringLiteral("no question \"%1\" to ask").arg(text));
    QJsonArray options;
    for (const QString& label : kAsked.value(text).second) options.append(QJsonObject{{QStringLiteral("label"), label}, {QStringLiteral("description"), QString()}});
    asked.append(QJsonObject{{QStringLiteral("id"), kAsked.value(text).first},
                             {QStringLiteral("header"), kAsked.value(text).first},
                             {QStringLiteral("question"), text},
                             {QStringLiteral("options"), options},
                             {QStringLiteral("multiSelect"), false},
                             {QStringLiteral("allowCustomAnswer"), true}});
  }
  request(world, QStringLiteral("user_input_request"), {{QStringLiteral("questions"), asked}});
}

// The question card above the composer on screen (TurnRequests.qml), once no
// pick is still about to move it to the next question.
void settleQuestion(World& world) {
  composerBrick(world);
  world.waitFor([&] {
    QQuickItem* requests = composerPart(world, QStringLiteral("turnRequests"));
    return requests && !requests->property("advancing").toBool();
  }, QStringLiteral("the question card to stop moving on"));
}

QString questionShownNow(World& world) {
  QQuickItem* title = composerPart(world, QStringLiteral("questionTitle"));
  return title && title->isVisible() ? title->property("text").toString() : QString();
}

void expectQuestionShown(World& world, const QString& text) {
  composerBrick(world);
  world.waitFor([&] { return questionShownNow(world) == text; }, [&] { return QStringLiteral("\"%1\"; the card shows \"%2\"").arg(text, questionShownNow(world)); });
}

bool optionPicked(World& world, const QString& label) {
  QQuickItem* option = composerPart(world, QStringLiteral("questionOption-") + label);
  return option && option->property("checked").toBool();
}

// Takes the keyboard out of the composer's editor (and any field), as a click
// on the conversation does.
// Takes the keyboard off the composer to the question card, as a click on
// the card does: number keys pick only there.
void keyboardToCard(World& world) {
  composerEditor(world)->setFocus(false);
  QQuickItem* card = composerPart(world, QStringLiteral("questionCard"));
  expect(card && card->isVisible(), QStringLiteral("no question card is shown"));
  card->forceActiveFocus(Qt::MouseFocusReason);
  world.sync();
  expect(card->hasActiveFocus(), QStringLiteral("the question card did not take the keyboard"));
}

// Clicks the question card's `name` as the user does.
void clickPart(World& world, const QString& name) {
  Brick& brick = composerBrick(world);
  QQuickItem* item = composerPart(world, name);
  expect(item && item->isVisible() && item->isEnabled(),
         QStringLiteral("%1 cannot be clicked (%2)").arg(name, item ? QStringLiteral("visible %1, enabled %2").arg(item->isVisible()).arg(item->isEnabled()) : QStringLiteral("none")));
  QTest::mouseClick(&brick.window(), Qt::LeftButton, Qt::NoModifier, brick.at(item));
  world.sync();
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
    // A question's hints are on its card above the composer.
    if (!world.brick && !listed(world, QStringLiteral("questions")).isEmpty()) composerBrick(world);
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
  step(QStringLiteral("each question, its options and the answer button sit above the composer's editor as the user steps through them"),
       [](World& world, const Captures&, const Table&) {
         composerBrick(world);
         world.waitFor([&] { return composerPart(world, QStringLiteral("questionAnswer-direction")) != nullptr; },
                       QStringLiteral("the second question to arrive"));
         const auto above = [&](const QStringList& parts) {
           const qreal editorTop = composerEditor(world)->mapToScene(QPointF()).y();
           for (const QString& part : parts) {
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
         };
         above({QStringLiteral("questionTitle"), QStringLiteral("questionOption-Yes, start now (Recommended)"), QStringLiteral("questionAnswer-lint"),
                QStringLiteral("questionNext"), QStringLiteral("questionSubmit")});
         clickPart(world, QStringLiteral("questionNext"));
         above({QStringLiteral("questionTitle"), QStringLiteral("questionOption-Decide later"), QStringLiteral("questionAnswer-direction"),
                QStringLiteral("questionSubmit")});
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

  // Answering from the composer's question card (composer/question-answers.feature):
  // one question of a request at a time, picked, typed and stepped through as
  // the user does.
  step(QStringLiteral("the agent asked %1 and %1 in one request").arg(q), [](World& world, const Captures& c, const Table&) {
    askTogether(world, {c[0], c[1]});
  });
  step(QStringLiteral("the agent asked %1, %1 and %1 in one request").arg(q), [](World& world, const Captures& c, const Table&) {
    askTogether(world, {c[0], c[1], c[2]});
  });
  step(QStringLiteral("%1 is shown with %1 kept as the first answer").arg(q), [](World& world, const Captures& c, const Table&) {
    expectQuestionShown(world, c[0]);
    expect(optionPicked(world, c[1]), QStringLiteral("\"%1\" is no longer picked").arg(c[1]));
  });
  step(QStringLiteral("%1 is still shown so %1 can be picked too").arg(q), [](World& world, const Captures& c, const Table&) {
    settleQuestion(world);
    expectQuestionShown(world, c[0]);
    QQuickItem* option = composerPart(world, QStringLiteral("questionOption-") + c[1]);
    expect(option && option->isVisible() && option->isEnabled() && !optionPicked(world, c[1]), QStringLiteral("\"%1\" cannot be picked").arg(c[1]));
  });
  step(QStringLiteral("%1 is still shown a moment later").arg(q), [](World& world, const Captures& c, const Table&) {
    settleQuestion(world);
    expectQuestionShown(world, c[0]);
  });
  step(QStringLiteral("the user picks %1 and at once (presses Next|goes back to a question already shown)").arg(q), [](World& world, const Captures& c, const Table&) {
    // The pick's move to the next question is still to come when the user moves.
    clickPart(world, QStringLiteral("questionOption-") + c[0]);
    QQuickItem* requests = composerPart(world, QStringLiteral("turnRequests"));
    expect(requests->property("advancing").toBool(), QStringLiteral("the pick did not wait to move on"));
    clickPart(world, QStringLiteral("questionNext"));
    if (c[1] == QLatin1String("goes back to a question already shown")) clickPart(world, QStringLiteral("questionPrevious"));
  });
  step(QStringLiteral("the question is marked %1 and the user can go on to the next question").arg(q), [](World& world, const Captures& c, const Table&) {
    composerBrick(world);
    world.waitFor([&] { return composerPart(world, QStringLiteral("questionPosition")) && composerPart(world, QStringLiteral("questionPosition"))->property("text") == c[0]; },
                  QStringLiteral("the question to be marked %1").arg(c[0]));
    clickPart(world, QStringLiteral("questionNext"));
    expectQuestionShown(world, QStringLiteral("Which cache?"));
  });
  step(QStringLiteral("the user answers both questions"), [](World& world, const Captures&, const Table&) {
    clickPart(world, QStringLiteral("questionPrevious"));
    expectQuestionShown(world, QStringLiteral("Which database?"));
    clickPart(world, QStringLiteral("questionOption-Postgres"));
    // Typed, as a pick on the last question would send the answers at once.
    expectQuestionShown(world, QStringLiteral("Which cache?"));
    Brick& brick = composerBrick(world);
    QQuickItem* field = composerPart(world, QStringLiteral("questionAnswer-cache"));
    QTest::mouseClick(&brick.window(), Qt::LeftButton, Qt::NoModifier, brick.at(field));
    typeInComposer(world, QStringLiteral("Redis"));
    expect(field->property("text") == QLatin1String("Redis"), QStringLiteral("the answer reads \"%1\"").arg(field->property("text").toString()));
  });
  step(QStringLiteral("the user can go back to the previous question to change its answer"), [](World& world, const Captures&, const Table&) {
    clickPart(world, QStringLiteral("questionPrevious"));
    expectQuestionShown(world, QStringLiteral("Which database?"));
    clickPart(world, QStringLiteral("questionOption-SQLite"));
    expect(optionPicked(world, QStringLiteral("SQLite")) && !optionPicked(world, QStringLiteral("Postgres")), QStringLiteral("the answer did not change"));
  });
  step(QStringLiteral("submitting sends both answers to the agent together"), [](World& world, const Captures&, const Table&) {
    settleQuestion(world);
    clickPart(world, QStringLiteral("questionSubmit"));
    const QList<QJsonObject> sent = commandsOf(world, QStringLiteral("runtime-request.respond"));
    const QJsonObject answers = sent.isEmpty() ? QJsonObject() : sent.last().value(QLatin1String("answers")).toObject();
    expect(sent.size() == 1 && answers.value(QLatin1String("database")) == QLatin1String("SQLite") && answers.value(QLatin1String("cache")) == QLatin1String("Redis"),
           QStringLiteral("the MC has %1").arg(world.describeCommands()));
  });
  step(QStringLiteral("the user answered %1 and left the thread").arg(q), [](World& world, const Captures& c, const Table&) {
    expectQuestionShown(world, c[0]);
    clickPart(world, QStringLiteral("questionOption-Postgres"));
    expectQuestionShown(world, QStringLiteral("Which cache?"));
    // Back on the first question, so coming back is what moves on.
    clickPart(world, QStringLiteral("questionPrevious"));
    expectQuestionShown(world, c[0]);
    world.startNewThread({});
    world.waitFor([&] { return questionShownNow(world).isEmpty(); }, QStringLiteral("the question to go with the thread"));
  });
  step(QStringLiteral("the agent asks %1 and the user has typed %1 without sending it").arg(q), [](World& world, const Captures& c, const Table&) {
    startWorking(world);
    question(world, c[0], {QStringLiteral("Postgres"), QStringLiteral("SQLite"), QStringLiteral("MySQL")});
    expectQuestionShown(world, c[0]);
    Brick& brick = composerBrick(world);
    QQuickItem* field = composerPart(world, QStringLiteral("questionAnswer-") + kQuestion);
    QTest::mouseClick(&brick.window(), Qt::LeftButton, Qt::NoModifier, brick.at(field));
    typeInComposer(world, c[1]);
    expect(field->property("text") == c[1], QStringLiteral("the answer reads \"%1\"").arg(field->property("text").toString()));
  });
  step(QStringLiteral("the user opens a new thread and comes back"), [](World& world, const Captures&, const Table&) {
    world.startNewThread({});
    world.waitFor([&] { return questionShownNow(world).isEmpty(); }, QStringLiteral("the question to go with the thread"));
    look(world, threadKey(world));
  });
  step(QStringLiteral("the answer still reads %1 on the same question").arg(q), [](World& world, const Captures& c, const Table&) {
    expectQuestionShown(world, QStringLiteral("Which database?"));
    QQuickItem* field = composerPart(world, QStringLiteral("questionAnswer-") + kQuestion);
    expect(field->isVisible() && field->property("text") == c[0], QStringLiteral("the answer reads \"%1\"").arg(field->property("text").toString()));
  });
  step(QStringLiteral("the user opens the thread again"), [](World& world, const Captures&, const Table&) {
    look(world, threadKey(world));
  });
  step(QStringLiteral("the user is not typing in the composer"), [](World& world, const Captures&, const Table&) {
    composerBrick(world);
    settleQuestion(world);
    keyboardToCard(world);
  });
  step(QStringLiteral("%1 is picked").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(optionPicked(world, c[0]), QStringLiteral("\"%1\" is not picked").arg(c[0]));
  });
  step(QStringLiteral("the user is typing an answer and presses (\\d)"), [](World& world, const Captures& c, const Table&) {
    Brick& brick = composerBrick(world);
    QQuickItem* field = composerPart(world, QStringLiteral("questionAnswer-") + kQuestion);
    expect(field && field->isVisible(), QStringLiteral("the question takes no typed answer"));
    QTest::mouseClick(&brick.window(), Qt::LeftButton, Qt::NoModifier, brick.at(field));
    expect(field->hasActiveFocus(), QStringLiteral("the answer field did not take the keyboard"));
    QTest::keyClick(&brick.window(), c[0].at(0).toLatin1());
    world.sync();
  });
  step(QStringLiteral("%1 is typed into the answer and no option is picked").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* field = composerPart(world, QStringLiteral("questionAnswer-") + kQuestion);
    expect(field->property("text") == c[0], QStringLiteral("the answer reads \"%1\"").arg(field->property("text").toString()));
    for (const QString& label : {QStringLiteral("Postgres"), QStringLiteral("SQLite")}) expect(!optionPicked(world, label), QStringLiteral("\"%1\" is picked").arg(label));
  });
  step(QStringLiteral("the user hides the question and its options"), [](World& world, const Captures&, const Table&) {
    composerBrick(world);
    settleQuestion(world);
    clickPart(world, QStringLiteral("questionFold"));
  });
  step(QStringLiteral("only the question's title stays above the composer"), [](World& world, const Captures&, const Table&) {
    QQuickItem* title = composerPart(world, QStringLiteral("questionTitle"));
    expect(title && title->isVisible() && title->property("text") == QLatin1String("Which database?"), QStringLiteral("the question's title is gone"));
    for (const QString& part : {QStringLiteral("questionOption-Postgres"), QStringLiteral("questionAnswer-database"), QStringLiteral("questionSubmit")}) {
      expect(!composerPart(world, part)->isVisible(), QStringLiteral("%1 is still shown").arg(part));
    }
  });
  step(QStringLiteral("number keys pick nothing while it is hidden"), [](World& world, const Captures&, const Table&) {
    Brick& brick = composerBrick(world);
    keyboardToCard(world);
    QTest::keyClick(&brick.window(), '1');
    world.sync();
    expect(!optionPicked(world, QStringLiteral("Postgres")), QStringLiteral("1 picked \"Postgres\""));
  });
  step(QStringLiteral("the user shows the question again"), [](World& world, const Captures&, const Table&) { clickPart(world, QStringLiteral("questionFold")); });
  step(QStringLiteral("the options and what the user already picked are shown"), [](World& world, const Captures&, const Table&) {
    for (const QString& part : {QStringLiteral("questionOption-Postgres"), QStringLiteral("questionOption-SQLite"), QStringLiteral("questionAnswer-database"),
                                QStringLiteral("questionSubmit")}) {
      expect(composerPart(world, part)->isVisible(), QStringLiteral("%1 is not shown").arg(part));
    }
    expect(!optionPicked(world, QStringLiteral("Postgres")) && !optionPicked(world, QStringLiteral("SQLite")), QStringLiteral("an option was picked while hidden"));
  });
  step(QStringLiteral("the environment refuses to dismiss the question"), [](World& world, const Captures&, const Table&) {
    world.mc.refusals.insert(QStringLiteral("thread.user-input.dismiss"), QStringLiteral("The provider is still writing the question"));
  });
  step(QStringLiteral("the question is still waiting for an answer"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !first(world, QStringLiteral("questions")).value(QStringLiteral("responding")).toBool(); }, QStringLiteral("the dismissal to settle"));
    const QVariantMap shown = first(world, QStringLiteral("questions"));
    expect(shown.value(QStringLiteral("canRespond")).toBool(), QStringLiteral("the question is %1").arg(show(shown)));
  });
  step(QStringLiteral("the agent asked the question while its turn is still running"), [](World& world, const Captures&, const Table&) {
    expect(turn(world).value(QStringLiteral("running")).toBool() && !listed(world, QStringLiteral("questions")).isEmpty(),
           QStringLiteral("the turn is %1").arg(show(turn(world))));
  });
  step(QStringLiteral("the user can stop the turn as well as answer the question"), [](World& world, const Captures&, const Table&) {
    composerBrick(world);
    settleQuestion(world);
    QQuickItem* option = composerPart(world, QStringLiteral("questionOption-Postgres"));
    expect(option && option->isVisible() && option->isEnabled(), QStringLiteral("the question cannot be answered"));
    QQuickItem* action = composerPart(world, QStringLiteral("primaryAction"));
    expect(action && action->isVisible() && action->property("stopMode").toBool(), QStringLiteral("the composer offers no Stop"));
    clickPart(world, QStringLiteral("primaryAction"));
    const QJsonObject command = lastCommand(world, QStringLiteral("run.interrupt"));
    // The user's Stop also stops what the thread delegated (delegation.feature).
    expect(command.value(QLatin1String("runId")) == world.mc.part<FakeStreams>().run && command.value(QLatin1String("stopDelegated")).toBool(),
           QStringLiteral("the MC was told %1").arg(show(command.toVariantMap())));
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
    // A question the MC would not dismiss: the reason it gave, under the fallback.
    if (c[0] == QLatin1String("Failed to dismiss the question.")) {
      world.waitFor([&] {
        const QVariantList shown = toasts(world);
        return std::any_of(shown.cbegin(), shown.cend(), [&](const QVariant& toast) {
          return toast.toMap().value(QStringLiteral("title")) == c[0] &&
                 toast.toMap().value(QStringLiteral("description")) == QLatin1String("The provider is still writing the question");
        });
      }, [&] { return QStringLiteral("the reason; the toasts are %1").arg(show(toasts(world))); });
      return;
    }
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
    // The user's Stop also stops what the thread delegated (delegation.feature).
    expect(command.value(QLatin1String("runId")) == world.mc.part<FakeStreams>().run && command.value(QLatin1String("stopDelegated")).toBool(),
           QStringLiteral("the MC was told %1").arg(show(command.toVariantMap())));
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

  // A queued row's controls (TurnRequests): Send now, then Edit and Remove.
  const auto rowPart = [requestsBrick](World& world, const QString& part, const QString& text) -> QQuickItem* {
    Brick& brick = requestsBrick(world);
    const QString name = part + QStringLiteral("-run-queued-") + text;
    world.waitFor([&] { return brick.find(name) && brick.find(name)->isVisible(); },
                  [&] { return QStringLiteral("%1 on the queue; the turn is %2").arg(name, show(turn(world))); });
    return brick.item(name);
  };
  const auto queuedAndHeld = [](World& world, const QStringList& texts) {
    for (const QString& text : texts) queueMessage(world, text);
    for (const QString& text : texts) set(world, QStringLiteral("run"), QStringLiteral("run-queued-") + text, {{QStringLiteral("queueHeld"), true}});
    finishTurn(world);
  };
  step(QStringLiteral("%1, %1 and %1 are queued and held, and the turn is no longer running").arg(q),
       [queuedAndHeld](World& world, const Captures& c, const Table&) { queuedAndHeld(world, {c[0], c[1], c[2]}); });
  step(QStringLiteral("%1 and %1 are queued and held, and the turn is no longer running").arg(q),
       [queuedAndHeld](World& world, const Captures& c, const Table&) { queuedAndHeld(world, {c[0], c[1]}); });
  step(QStringLiteral("the user looks at %1 in the queue").arg(q), [rowPart](World& world, const Captures& c, const Table&) {
    rowPart(world, QStringLiteral("queueText"), c[0]);
  });
  step(QStringLiteral("the user is offered to send %1 now, to edit it and to remove it").arg(q), [rowPart](World& world, const Captures& c, const Table&) {
    QStringList offered;
    for (const QString& part : {QStringLiteral("queueSendNow"), QStringLiteral("queueEdit"), QStringLiteral("queueRemove")}) {
      if (rowPart(world, part, c[0])->isEnabled()) offered.append(part);
    }
    expect(offered.size() == 3 && rowPart(world, QStringLiteral("queueSendNow"), c[0])->property("text") == QLatin1String("Send now"),
           QStringLiteral("the row offers %1").arg(offered.join(u", ")));
    // Send now comes first, as upstream's row has it.
    expect(rowPart(world, QStringLiteral("queueSendNow"), c[0])->x() < rowPart(world, QStringLiteral("queueEdit"), c[0])->x(),
           QStringLiteral("Send now is not first"));
  });
  step(QStringLiteral("the user is not offered to move %1 in the queue").arg(q), [requestsBrick](World& world, const Captures& c, const Table&) {
    QStringList moves;
    const std::function<void(QQuickItem*)> walk = [&](QQuickItem* item) {
      // Remove is not a move.
      static const QRegularExpression move(QStringLiteral("(?<![Rr]e)[Mm]ove|[Hh]andle|[Dd]rag|[Rr]eorder|[Pp]osition"));
      if (item->isVisible() && move.match(item->objectName()).hasMatch()) moves.append(item->objectName());
      for (QQuickItem* child : item->childItems()) walk(child);
    };
    walk(requestsBrick(world).item(QStringLiteral("queueRow-run-queued-") + c[0]));
    expect(moves.isEmpty(), QStringLiteral("the row offers %1").arg(moves.join(u", ")));
  });
  step(QStringLiteral("the user is offered to send %1 now instead of steering it").arg(q), [requestsBrick, rowPart](World& world, const Captures& c, const Table&) {
    QQuickItem* send = rowPart(world, QStringLiteral("queueSendNow"), c[0]);
    expect(send->isEnabled() && send->property("text") == QLatin1String("Send now"), QStringLiteral("Send now cannot be used"));
    requestsBrick(world).click(send->objectName());
    world.sync();
    const QJsonObject command = lastCommand(world, QStringLiteral("queued-run.start"));
    expect(command.value(QLatin1String("runId")) == QStringLiteral("run-queued-") + c[0] && commandsOf(world, QStringLiteral("queued-message.promote-to-steer")).isEmpty(),
           QStringLiteral("the MC has %1").arg(world.describeCommands()));
  });
  step(QStringLiteral("the user removes %1 and the MC has not answered yet").arg(q), [requestsBrick, rowPart](World& world, const Captures& c, const Table&) {
    world.mc.hold(QStringLiteral("answers"));
    requestsBrick(world).click(rowPart(world, QStringLiteral("queueRemove"), c[0])->objectName());
    world.sync();
    expect(commandsOf(world, QStringLiteral("queued-run.cancel")).size() == 1, QStringLiteral("the MC has %1").arg(world.describeCommands()));
  });
  const auto controls = [rowPart](World& world, const QString& text) {
    QStringList usable;
    for (const QString& part : {QStringLiteral("queueSendNow"), QStringLiteral("queueEdit"), QStringLiteral("queueRemove")}) {
      if (rowPart(world, part, text)->isEnabled()) usable.append(part);
    }
    return usable;
  };
  step(QStringLiteral("%1 cannot be edited, steered or removed until it has").arg(q), [controls](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return controls(world, c[0]).isEmpty(); }, [&] { return QStringLiteral("the row still offers %1").arg(controls(world, c[0]).join(u", ")); });
    // Nor by its actions or keys.
    const QVariantMap run{{QStringLiteral("runId"), QStringLiteral("run-queued-") + c[0]}};
    world.bridge().dispatch(QStringLiteral("composer.queue.steer"), run);
    world.bridge().dispatch(QStringLiteral("composer.queue.remove"), run);
    world.bridge().dispatch(QStringLiteral("composer.queue.edit"), run);
    world.sync();
    expect(commandsOf(world, QStringLiteral("queued-run.cancel")).size() == 1 && commandsOf(world, QStringLiteral("queued-message.promote-to-steer")).isEmpty() &&
               world.state(QStringLiteral("composer")).toMap().value(QStringLiteral("editingQueuedRunId")).isNull(),
           QStringLiteral("the MC has %1").arg(world.describeCommands()));
    world.mc.answerHeld();
    world.sync();
    world.waitFor([&] { return controls(world, c[0]).size() == 3; }, [&] { return QStringLiteral("the row offers only %1").arg(controls(world, c[0]).join(u", ")); });
  });

  // A follow-up on its way to the MC.
  step(QStringLiteral("the MC has not yet confirmed a message the user queued"), [](World& world, const Captures&, const Table&) {
    world.native().controller<SettingsController>()->writeDevice(QStringLiteral("followUpBehavior"), QStringLiteral("queue"));
    world.mc.hold(QStringLiteral("answers"));
    world.bridge().dispatch(QStringLiteral("composer.submit"), QVariantMap{{QStringLiteral("text"), QStringLiteral("tweak")}, {QStringLiteral("intent"), QStringLiteral("foreground")}});
    world.sync();
  });
  const auto pendingEntry = [](World& world) {
    for (const QVariant& entry : listed(world, QStringLiteral("queue"))) {
      if (entry.toMap().value(QStringLiteral("pending")).toBool()) return entry.toMap();
    }
    return QVariantMap();
  };
  step(QStringLiteral("the message is listed in the queue as being saved"), [requestsBrick, pendingEntry](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return pendingEntry(world).value(QStringLiteral("text")) == QLatin1String("tweak"); },
                  [&] { return QStringLiteral("a queued message being saved; the turn is %1").arg(show(turn(world))); });
    Brick& brick = requestsBrick(world);
    const QString id = pendingEntry(world).value(QStringLiteral("messageId")).toString();
    world.waitFor([&] { return brick.find(QStringLiteral("queueSaving-") + id) && brick.find(QStringLiteral("queueSaving-") + id)->isVisible(); },
                  QStringLiteral("the row's saving mark"));
    expect(brick.item(QStringLiteral("queueText-") + id)->property("text") == QLatin1String("tweak"), QStringLiteral("the row reads otherwise"));
  });
  step(QStringLiteral("it cannot be edited, reordered, steered or removed until the MC confirms it"), [requestsBrick, pendingEntry](World& world, const Captures&, const Table&) {
    Brick& brick = requestsBrick(world);
    QStringList offered;
    const std::function<void(QQuickItem*)> walk = [&](QQuickItem* item) {
      if (item->isVisible() && item->property("checkable").isValid() && !item->objectName().isEmpty()) offered.append(item->objectName());
      for (QQuickItem* child : item->childItems()) walk(child);
    };
    const QString id = pendingEntry(world).value(QStringLiteral("messageId")).toString();
    walk(brick.item(QStringLiteral("queueRow-") + id));
    expect(offered.isEmpty(), QStringLiteral("the row being saved offers %1").arg(offered.join(u", ")));
    // The edit-latest key passes it over: it has no run to edit yet.
    world.bridge().dispatch(QStringLiteral("composer.queue.edit"), QVariantMap());
    world.sync();
    expect(world.state(QStringLiteral("composer")).toMap().value(QStringLiteral("editingQueuedRunId")).isNull(), QStringLiteral("an edit opened"));
    // The MC has it: the message and its queued run arrive, and the row is a queued one.
    world.mc.answerHeld();
    queueMessage(world, QStringLiteral("tweak"));
    world.waitFor([&] { return pendingEntry(world).isEmpty(); }, [&] { return QStringLiteral("the row to be confirmed; the turn is %1").arg(show(turn(world))); });
  });

  // A queued message while a question is open.
  step(QStringLiteral("the agent has asked the user a question"), [](World& world, const Captures&, const Table&) {
    question(world, QStringLiteral("Which database?"), {QStringLiteral("Postgres"), QStringLiteral("SQLite")});
    world.waitFor([&] { return !listed(world, QStringLiteral("questions")).isEmpty(); }, QStringLiteral("the question"));
  });
  step(QStringLiteral("editing %1 is unavailable, saying %1").arg(q), [rowPart](World& world, const Captures& c, const Table&) {
    QQuickItem* edit = rowPart(world, QStringLiteral("queueEdit"), c[0]);
    world.waitFor([&] { return !edit->isEnabled(); }, QStringLiteral("Edit to be unavailable"));
    expect(edit->property("toolTip") == c[1] && turn(world).value(QStringLiteral("queueEditBlocked")) == c[1],
           QStringLiteral("Edit says \"%1\"").arg(edit->property("toolTip").toString()));
    world.bridge().dispatch(QStringLiteral("composer.queue.edit"), QVariantMap{{QStringLiteral("runId"), QStringLiteral("run-queued-") + c[0]}});
    world.sync();
    expect(world.state(QStringLiteral("composer")).toMap().value(QStringLiteral("editingQueuedRunId")).isNull(), QStringLiteral("an edit opened"));
  });
  step(QStringLiteral("the edit-latest shortcut does nothing"), [](World& world, const Captures&, const Table&) {
    const QString before = openDraft(world);
    world.bridge().dispatch(QStringLiteral("composer.queue.edit"), QVariantMap());
    world.sync();
    expect(world.state(QStringLiteral("composer")).toMap().value(QStringLiteral("editingQueuedRunId")).isNull() && openDraft(world) == before,
           QStringLiteral("the composer is %1").arg(show(world.state(QStringLiteral("composer")))));
  });

  // The row of the message being edited.
  step(QStringLiteral("%1 is queued with an image").arg(q), [](World& world, const Captures& c, const Table&) {
    queueMessage(world, c[0]);
    set(world, QStringLiteral("message"), QStringLiteral("message-") + c[0],
        {{QStringLiteral("attachments"), QJsonArray{QJsonObject{{QStringLiteral("type"), QStringLiteral("image")},
                                                                {QStringLiteral("id"), QStringLiteral("image-") + c[0]},
                                                                {QStringLiteral("name"), QStringLiteral("shot.png")},
                                                                {QStringLiteral("mimeType"), QStringLiteral("image/png")},
                                                                {QStringLiteral("sizeBytes"), 12}}}}});
  });
  step(QStringLiteral("the user starts editing it in the composer"), [requestsBrick](World& world, const Captures&, const Table&) {
    const QString run = listed(world, QStringLiteral("queue")).constLast().toMap().value(QStringLiteral("runId")).toString();
    Brick& brick = requestsBrick(world);
    world.waitFor([&] { return brick.find(QStringLiteral("queueEdit-") + run) && brick.find(QStringLiteral("queueEdit-") + run)->isVisible(); },
                  QStringLiteral("the row's Edit"));
    brick.click(QStringLiteral("queueEdit-") + run);
    world.sync();
  });
  step(QStringLiteral("the queue marks %1 as being edited and offers to cancel the edit").arg(q), [requestsBrick, rowPart](World& world, const Captures& c, const Table&) {
    QQuickItem* cancel = rowPart(world, QStringLiteral("queueEditCancel"), c[0]);
    Brick& brick = requestsBrick(world);
    QQuickItem* text = brick.item(QStringLiteral("queueText-run-queued-") + c[0]);
    expect(text->property("font").value<QFont>().italic(), QStringLiteral("the row is not marked"));
    for (const QString& part : {QStringLiteral("queueSendNow"), QStringLiteral("queueEdit"), QStringLiteral("queueRemove")}) {
      QQuickItem* item = brick.find(part + QStringLiteral("-run-queued-") + c[0]);
      expect(!item || !item->isVisible(), QStringLiteral("the row being edited offers %1").arg(part));
    }
    brick.click(cancel->objectName());
    world.sync();
    world.waitFor([&] { return world.state(QStringLiteral("composer")).toMap().value(QStringLiteral("editingQueuedRunId")).isNull(); },
                  QStringLiteral("the edit to end"));
  });

  // Saves of a queued edit, one at a time.
  step(QStringLiteral("the user saved %1 over it and the MC has not answered yet").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("composer.queue.edit"), QVariantMap());
    world.sync();
    world.mc.hold(QStringLiteral("answers"));
    world.bridge().dispatch(QStringLiteral("composer.submit"), QVariantMap{{QStringLiteral("text"), c[0]}, {QStringLiteral("intent"), QStringLiteral("foreground")}});
    world.sync();
    expect(commandsOf(world, QStringLiteral("queued-run.edit")).size() == 1, QStringLiteral("the MC has %1").arg(world.describeCommands()));
  });
  step(QStringLiteral("the user edits it again and saves %1").arg(q), [](World& world, const Captures& c, const Table&) {
    typeInto(world, c[0]);
    world.bridge().dispatch(QStringLiteral("composer.submit"), QVariantMap{{QStringLiteral("text"), c[0]}, {QStringLiteral("intent"), QStringLiteral("foreground")}});
    world.sync();
  });
  step(QStringLiteral("%1 is sent only after the MC answered the first save").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(commandsOf(world, QStringLiteral("queued-run.edit")).size() == 1, QStringLiteral("the MC has %1").arg(world.describeCommands()));
    world.mc.answerHeld();
    world.waitFor([&] { return commandsOf(world, QStringLiteral("queued-run.edit")).size() == 2; }, [&] { return QStringLiteral("the MC has %1").arg(world.describeCommands()); });
    const QJsonObject second = lastCommand(world, QStringLiteral("queued-run.edit"));
    expect(second.value(QLatin1String("text")) == c[0], QStringLiteral("the MC was told %1").arg(show(second.toVariantMap())));
  });
  step(QStringLiteral("the queued message ends as %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return world.state(QStringLiteral("composer")).toMap().value(QStringLiteral("editingQueuedRunId")).isNull(); },
                  QStringLiteral("the edit to end"));
    const QList<QJsonObject> saves = commandsOf(world, QStringLiteral("queued-run.edit"));
    expect(saves.size() == 2 && saves.last().value(QLatin1String("text")) == c[0], QStringLiteral("the MC has %1").arg(world.describeCommands()));
  });

  // The queue folds to its header.
  step(QStringLiteral("the queue is headed %1 with the count (\\d+)").arg(q), [requestsBrick](World& world, const Captures& c, const Table&) {
    Brick& brick = requestsBrick(world);
    world.waitFor([&] { return brick.shows(c[0]) && brick.item(QStringLiteral("queueCount"))->property("text").toString() == c[1]; },
                  [&] { return QStringLiteral("the queue's header; the turn is %1").arg(show(turn(world))); });
  });
  step(QStringLiteral("the user folds the queue away"), [requestsBrick](World& world, const Captures&, const Table&) {
    requestsBrick(world).click(QStringLiteral("queueToggle"));
  });
  step(QStringLiteral("%1 and %1 are hidden and the count is still shown").arg(q), [requestsBrick](World& world, const Captures& c, const Table&) {
    Brick& brick = requestsBrick(world);
    world.waitFor([&] { return !brick.shows(c[0]) && !brick.shows(c[1]); }, QStringLiteral("the queued messages to be hidden"));
    QQuickItem* count = brick.item(QStringLiteral("queueCount"));
    expect(count->isVisible() && count->property("text").toString() == QString::number(2), QStringLiteral("the count is gone"));
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
  settleQuestion(world);
  clickPart(world, QStringLiteral("questionOption-") + label);
  // One question that takes one answer is answered by the pick alone, as the
  // timeline's question card does.
  const QVariantList asked = first(world, QStringLiteral("questions")).value(QStringLiteral("questions")).toList();
  if (asked.size() == 1 && !asked.first().toMap().value(QStringLiteral("multiSelect")).toBool()) clickPart(world, QStringLiteral("questionSubmit"));
}

bool questionShown(World& world, const QString& text) {
  if (!composerBrickShown(world) || world.state(QStringLiteral("turn")).toMap().value(QStringLiteral("questions")).toList().isEmpty()) return false;
  if (!kAsked.contains(text)) return false;
  settleQuestion(world);
  expectQuestionShown(world, text);
  return true;
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

void awaitTurnApproval(World& world) {
  startWorking(world);
  approval(world, QStringLiteral("command"), QStringLiteral("Run the tests?"));
  world.waitFor([&] { return !listed(world, QStringLiteral("approvals")).isEmpty(); }, QStringLiteral("the approval to reach the composer"));
}

void awaitTurnQuestion(World& world) {
  startWorking(world);
  question(world, QStringLiteral("Which database?"), {QStringLiteral("Postgres"), QStringLiteral("SQLite")});
  world.waitFor([&] { return !listed(world, QStringLiteral("questions")).isEmpty(); }, QStringLiteral("the question to reach the composer"));
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
