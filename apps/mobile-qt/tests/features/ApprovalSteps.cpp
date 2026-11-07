// Approvals and the agent's questions on the phone
// (features/timeline/approvals-and-questions.feature): the request cards
// over the composer (TurnRequests.qml, shared with the desktop), tapped as
// a finger does. The thread's stream is ComposerSteps' fake
// (FakeThreads.h); the request shapes are the ones QuestionSteps.cpp asks
// questions with.

#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>

#include <algorithm>

#include "FakeThreads.h"
#include "Harness.h"
#include "Phone.h"
#include "World.h"

namespace {

using S = QString;

const QString kTitle = QStringLiteral("Tax line");
const QString kRun = QStringLiteral("run-approval");
const QString kQuestionId = QStringLiteral("database");

// The requests this scenario has asked, and the question it can ask again
// with another choice allowed.
struct Asked {
  int count = 0;
  QString lastRequest;
  QString questionText;
  QStringList labels;
  bool multiSelect = false;
};

Asked& asked(World& world) { return world.mc.part<Asked>(); }

QString screenTexts(World& world) { return world.texts().join(S(" | ")); }

QVariantList listed(World& world, const QString& field) {
  return world.state(S("turn")).toMap().value(field).toList();
}

QVariantMap first(World& world, const QString& field) {
  const QVariantList requests = listed(world, field);
  if (requests.isEmpty()) fail(S("the composer shows no %1; the turn is %2").arg(field, show(world.state(S("turn")))));
  return requests.first().toMap();
}

// A pending runtime-request and its turn item; returns once the composer
// shows it under `field` ("approvals" or "questions").
QString request(World& world, const QString& type, const QString& field, QJsonObject item,
                const QString& capability = S("live")) {
  Asked& them = asked(world);
  const QString id = S("request-%1").arg(++them.count);
  const QString itemId = S("%1-%2").arg(type).arg(them.count);
  setEntity(world.mc, world.thread, S("runtime-request"), id,
            {{S("id"), id}, {S("status"), S("pending")}, {S("nodeId"), S("node:") + itemId},
             {S("responseCapability"), QJsonObject{{S("type"), capability}}}});
  item.insert(S("id"), itemId);
  item.insert(S("type"), type);
  item.insert(S("runId"), kRun);
  item.insert(S("ordinal"), 10 + them.count);
  item.insert(S("status"), S("waiting"));
  item.insert(S("requestId"), id);
  item.insert(S("updatedAt"), S("2026-09-23T09:55:00Z"));
  setEntity(world.mc, world.thread, S("turn-item"), itemId, item);
  world.sync();
  world.waitFor([&] {
    return std::any_of(listed(world, field).cbegin(), listed(world, field).cend(),
                        [&](const QVariant& shown) { return shown.toMap().value(S("requestId")) == id; });
  }, [&] { return S("the request to be shown; the turn is %1").arg(show(world.state(S("turn")))); });
  them.lastRequest = id;
  return id;
}

QString approval(World& world, const QString& kind, const QString& prompt, const QJsonArray& options = {},
                 const QString& capability = S("live")) {
  QJsonObject item{{S("requestKind"), kind}, {S("prompt"), prompt}};
  if (!options.isEmpty()) item.insert(S("options"), options);
  return request(world, S("approval_request"), S("approvals"), item, capability);
}

QString question(World& world, const QString& text, const QStringList& labels, bool multiSelect = false,
                 const QString& capability = S("live")) {
  QJsonArray options;
  for (const QString& label : labels) options.append(QJsonObject{{S("label"), label}, {S("description"), QString()}});
  asked(world).questionText = text;
  asked(world).labels = labels;
  asked(world).multiSelect = multiSelect;
  return request(world, S("user_input_request"), S("questions"),
                 {{S("questions"), QJsonArray{QJsonObject{{S("id"), kQuestionId},
                                                          {S("header"), S("Database")},
                                                          {S("question"), text},
                                                          {S("options"), options},
                                                          {S("multiSelect"), multiSelect},
                                                          {S("allowCustomAnswer"), true}}}}},
                 capability);
}

// The card's control `name`, once a pick is no longer about to move it on
// (QuestionSteps.cpp's part(), for the same card).
QQuickItem* part(World& world, const QString& name) {
  QQuickItem* requests = world.item(S("turnRequests"));
  world.waitFor([&] { return !requests->property("advancing").toBool(); }, S("the pick to settle"));
  return world.item(name);
}

void tapOption(World& world, const QString& label) {
  world.tap(part(world, S("questionOption-") + label));
  world.sync();
}

QList<QJsonObject> answersSent(World& world) {
  world.sync();
  QList<QJsonObject> sent;
  for (const QJsonObject& command : std::as_const(world.mc.commands)) {
    if (command.value(QLatin1String("type")) == QLatin1String("runtime-request.respond")) sent.append(command);
  }
  return sent;
}

QJsonObject lastAnswer(World& world) {
  QJsonObject found;
  world.waitFor([&] { return !(found = answersSent(world).value(answersSent(world).size() - 1)).isEmpty(); },
                [&] { return S("the answer; the MC was sent %1 commands").arg(world.mc.commands.size()); });
  return found;
}

void expectDecision(World& world, const QString& decision) {
  const QJsonObject command = lastAnswer(world);
  expect(command.value(QLatin1String("decision")).toString() == decision && command.value(QLatin1String("threadId")) == world.thread,
         S("the MC was told %1").arg(show(command.toVariantMap())));
}

QVariant receivedAnswer(World& world) {
  return lastAnswer(world).value(QLatin1String("answers")).toObject().value(kQuestionId).toVariant();
}

const Steps steps([] {
  // The file's Background: the project step (PlanSteps.cpp) paired the
  // phone; the user is in a thread of it with a turn running.
  step(S("the user is looking at a thread in %1 whose agent is working").arg(kQuoted),
       [](World& world, const Captures&, const Table&) {
         world.thread = haveThread(world, kTitle);
         openThread(world, kTitle);
         setEntity(world.mc, world.thread, S("run"), kRun,
                   {{S("id"), kRun}, {S("ordinal"), 1}, {S("status"), S("running")},
                    {S("requestedAt"), S("2026-09-23T09:50:00Z")}, {S("startedAt"), S("2026-09-23T09:50:00Z")}});
         updateRow(world.mc, world.thread, {{S("activeRunId"), kRun}, {S("latestRunId"), kRun}});
         world.sync();
       });

  // Approvals.
  step(S("the agent asks to run %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    approval(world, S("command"), c[0]);
    world.waitFor([&] { return world.shows(c[0], false); },
                  [&] { return S("the command on the approval card; the screen says: %1").arg(screenTexts(world)); });
  });
  const QHash<QString, QString> decisions{
      {S("approve it"), S("accept")},
      {S("decline it"), S("decline")},
      {S("always allow it this session"), S("acceptForSession")},
      {S("cancel the request"), S("cancel")},
  };
  step(S("the user chooses to (approve it|decline it|always allow it this session|cancel the request)"),
       [decisions](World& world, const Captures& c, const Table&) {
         world.tap(S("approvalOption-") + decisions.value(c[0]));
         world.sync();
       });
  step(S("the command runs and the agent continues"), [](World& world, const Captures&, const Table&) {
    expectDecision(world, S("accept"));
  });
  step(S("the command is not run and the agent is told it was declined"), [](World& world, const Captures&, const Table&) {
    expectDecision(world, S("decline"));
  });
  step(S("the command runs and matching requests stop asking this session"), [](World& world, const Captures&, const Table&) {
    expectDecision(world, S("acceptForSession"));
  });
  step(S("the command is not run and the turn stops waiting"), [](World& world, const Captures&, const Table&) {
    expectDecision(world, S("cancel"));
  });

  const QHash<QString, QString> kinds{
      {S("to run a command"), S("command")},
      {S("to read a file"), S("file-read")},
      {S("to change a file"), S("file-change")},
      {S("access for an app"), S("mcp-elicitation")},
      {S("a permission for an app"), S("permission")},
  };
  step(S("the agent requests (to run a command|to read a file|to change a file|access for an app|a permission for an app)"),
       [kinds](World& world, const Captures& c, const Table&) { approval(world, kinds.value(c[0]), QString()); });
  step(S("the request is titled %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    const QString title = first(world, S("approvals")).value(S("title")).toString();
    expect(title == c[0], S("the request is titled \"%1\"").arg(title));
    world.waitFor([&] { return world.shows(c[0]); },
                  [&] { return S("\"%1\" on the approval card; the screen says: %2").arg(c[0], screenTexts(world)); });
  });

  step(S("the provider warns that an option may follow injected instructions"), [](World& world, const Captures&, const Table&) {
    approval(world, S("mcp-elicitation"), S("Allow the browser app?"),
             QJsonArray{QJsonObject{{S("decision"), S("accept")}, {S("label"), S("Allow")}},
                        QJsonObject{{S("decision"), S("acceptForSession")},
                                    {S("label"), S("Always allow")},
                                    {S("warning"), S("The app may follow instructions injected into pages it reads.")}},
                        QJsonObject{{S("decision"), S("decline")}, {S("label"), S("Deny")}}});
  });
  step(S("the user reviews the approval"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.shows(S("Allow the browser app?"), false); },
                  [&] { return S("the approval on screen; the screen says: %1").arg(screenTexts(world)); });
  });
  step(S("the warning is shown next to that option"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.shows(S("Always allow: The app may follow instructions injected into pages it reads."), false); },
                  [&] { return S("the warning with its option; the screen says: %1").arg(screenTexts(world)); });
  });

  step(S("the agent has three pending approvals"), [](World& world, const Captures&, const Table&) {
    for (const QString& command : {S("npm test"), S("npm run lint"), S("npm run build")}) approval(world, S("command"), command);
    world.waitFor([&] { return world.shows(S("npm test"), false); },
                  [&] { return S("the first approval on screen; the screen says: %1").arg(screenTexts(world)); });
  });
  step(S("the user sees %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    QQuickItem* position = world.item(S("approvalPosition"));
    world.waitFor([&] { return position->property("text").toString() == c[0]; },
                  [&] { return S("\"%1\"; the card is at \"%2\"").arg(c[0], position->property("text").toString()); });
  });
  step(S("the user moves to the next approval"), [](World& world, const Captures&, const Table&) {
    world.tap(S("approvalNext"));
    world.waitFor([&] { return world.shows(S("npm run lint"), false); },
                  [&] { return S("the second approval; the screen says: %1").arg(screenTexts(world)); });
  });
  step(S("the user moves back"), [](World& world, const Captures&, const Table&) {
    world.tap(S("approvalPrevious"));
    world.waitFor([&] { return world.shows(S("npm test"), false); },
                  [&] { return S("the first approval again; the screen says: %1").arg(screenTexts(world)); });
  });

  step(S("the provider process stopped while an approval was pending"), [](World& world, const Captures&, const Table&) {
    approval(world, S("command"), S("rm -rf dist"), {}, S("not_resumable"));
  });
  step(S("the approval cannot be answered"), [](World& world, const Captures&, const Table&) {
    const QVariantMap shown = first(world, S("approvals"));
    expect(!shown.value(S("canRespond")).toBool(), S("the approval is %1").arg(show(shown)));
    QQuickItem* option = world.item(S("approvalOption-accept"));
    expect(!option->property("enabled").toBool(), S("the approval's options still take an answer"));
    expect(answersSent(world).isEmpty(), S("an answer was sent"));
  });

  // Questions.
  step(S("the agent asks %1 with the options %1, %1 and %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    question(world, c[0], {c[1], c[2], c[3]});
  });
  step(S("the agent asks %1 with three options").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    question(world, c[0], {S("Postgres"), S("SQLite"), S("MySQL")});
  });
  // "Several answers" is QuestionSteps.cpp's step: it asks the question on
  // screen again allowing several. One answer is how it was asked here.
  step(S("the question allows one answer"), [](World& world, const Captures&, const Table&) {
    const QVariantMap shown = first(world, S("questions")).value(S("questions")).toList().first().toMap();
    expect(!shown.value(S("multiSelect")).toBool(), S("the question allows several answers: %1").arg(show(shown)));
  });
  step(S("the user picks %1 and %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    tapOption(world, c[0]);
    tapOption(world, c[1]);
    // Several answers are sent together by the card's answer button.
    world.tap(part(world, S("questionSubmit")));
    world.sync();
  });
  step(S("the user picks %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) { tapOption(world, c[0]); });
  step(S("the user answers %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    world.tap(part(world, S("questionAnswer-") + kQuestionId));
    world.type(c[0]);
    world.tap(part(world, S("questionSubmit")));
    world.sync();
  });
  step(S("the agent receives %1 and %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    const QVariant received = receivedAnswer(world);
    expect(received.toStringList() == QStringList{c[0], c[1]}, S("the agent received %1").arg(show(received)));
  });
  step(S("the agent receives %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    const QVariant received = receivedAnswer(world);
    expect(received == QVariant(c[0]), S("the agent received %1").arg(show(received)));
  });

  step(S("the agent asked a question that can be answered by message"), [](World& world, const Captures&, const Table&) {
    question(world, S("Which database?"), {S("Postgres"), S("SQLite")}, false, S("message"));
  });
  step(S("the turn ends before the user answers"), [](World& world, const Captures&, const Table&) {
    setEntity(world.mc, world.thread, S("run"), kRun,
              {{S("status"), S("completed")}, {S("completedAt"), S("2026-09-23T10:00:00Z")}});
    updateRow(world.mc, world.thread, {{S("activeRunId"), QJsonValue::Null}});
    world.sync();
  });
  step(S("the user can still answer the question"), [](World& world, const Captures&, const Table&) {
    const QVariantMap shown = first(world, S("questions"));
    expect(shown.value(S("canRespond")).toBool(), S("the question is %1").arg(show(shown)));
    tapOption(world, S("SQLite"));
    expect(receivedAnswer(world) == QVariant(S("SQLite")), S("the answer did not reach the MC"));
  });

  // A settled request, heard of out of order: the resolution reaches the
  // phone (as the runtime-request entity) before the ask (its turn item).
  step(S("the client hears that an approval was resolved before it hears that it was asked"),
       [](World& world, const Captures&, const Table&) {
         setEntity(world.mc, world.thread, S("runtime-request"), S("request-settled"),
                   {{S("id"), S("request-settled")}, {S("status"), S("resolved")},
                    {S("responseCapability"), QJsonObject{{S("type"), S("live")}}}});
         world.sync();
         setEntity(world.mc, world.thread, S("turn-item"), S("approval-settled"),
                   {{S("id"), S("approval-settled")}, {S("type"), S("approval_request")}, {S("runId"), kRun},
                    {S("ordinal"), 20}, {S("status"), S("waiting")}, {S("requestId"), S("request-settled")},
                    {S("requestKind"), S("command")}, {S("prompt"), S("npm test")}, {S("updatedAt"), S("2026-09-23T09:55:00Z")}});
         world.sync();
       });
  step(S("the approval is not offered to the user"), [](World& world, const Captures&, const Table&) {
    expect(listed(world, S("approvals")).isEmpty(), S("the turn is %1").arg(show(world.state(S("turn")))));
    expect(world.find(S("approvalOption-accept")) == nullptr, S("the approval is on screen; the screen says: %1").arg(screenTexts(world)));
  });

  // A question nothing could answer.
  step(S("the agent asked a question that has no options and allows no custom answer"),
       [](World& world, const Captures&, const Table&) {
         setEntity(world.mc, world.thread, S("runtime-request"), S("request-empty"),
                   {{S("id"), S("request-empty")}, {S("status"), S("pending")},
                    {S("responseCapability"), QJsonObject{{S("type"), S("live")}}}});
         setEntity(world.mc, world.thread, S("turn-item"), S("question-empty"),
                   {{S("id"), S("question-empty")}, {S("type"), S("user_input_request")}, {S("runId"), kRun},
                    {S("ordinal"), 20}, {S("status"), S("waiting")}, {S("requestId"), S("request-empty")},
                    {S("updatedAt"), S("2026-09-23T09:55:00Z")},
                    {S("questions"), QJsonArray{QJsonObject{{S("id"), kQuestionId},
                                                            {S("header"), S("Database")},
                                                            {S("question"), S("Which database?")},
                                                            {S("options"), QJsonArray()},
                                                            {S("multiSelect"), false},
                                                            {S("allowCustomAnswer"), false}}}}});
         world.sync();
       });
  step(S("the user is not asked it"), [](World& world, const Captures&, const Table&) {
    expect(listed(world, S("questions")).isEmpty(), S("the turn is %1").arg(show(world.state(S("turn")))));
    expect(world.find(S("questionTitle")) == nullptr && !world.shows(S("Which database?"), false),
           S("the question is on screen; the screen says: %1").arg(screenTexts(world)));
  });

  // An approval an older version recorded, by its native type. The thread
  // is left so "the user opens the thread" (ConnectionCacheSteps.cpp) opens
  // it on the recording.
  step(S("a thread recorded an approval of the native type %1").arg(kQuoted),
       [](World& world, const Captures& c, const Table&) {
         request(world, S("approval_request"), S("approvals"), {{S("requestType"), c[0]}, {S("prompt"), S("npm test")}});
         const auto home = [&] { return world.state(S("route")).toMap().value(S("kind")) == QLatin1String("home") && world.find(S("homeScreen")) != nullptr; };
         for (int tries = 0; tries < 6 && !home(); ++tries) {
           world.back();
           world.sync();
         }
         world.waitFor(home, [&] { return S("the home screen; the route is %1").arg(show(world.state(S("route")))); });
       });
  const QHash<QString, QString> shownAs{
      {S("run a command"), S("Command approval")},
      {S("change files"), S("File change approval")},
      {S("read a file"), S("File read approval")},
      {S("answer an MCP request"), S("App access approval")},
  };
  step(S("the approval is shown as a request to (run a command|change files|read a file|answer an MCP request)"),
       [shownAs](World& world, const Captures& c, const Table&) {
         const QString title = first(world, S("approvals")).value(S("title")).toString();
         expect(title == shownAs.value(c[0]), S("the approval is titled \"%1\"").arg(title));
         world.waitFor([&] { return world.shows(shownAs.value(c[0])); },
                       [&] { return S("\"%1\" on the approval card; the screen says: %2").arg(shownAs.value(c[0]), screenTexts(world)); });
       });

  // A half-written answer, kept while the user is elsewhere.
  step(S("the agent asks %1 and the user has typed %1 without sending it").arg(kQuoted),
       [](World& world, const Captures& c, const Table&) {
         question(world, c[0], {S("Postgres"), S("SQLite"), S("MySQL")});
         QQuickItem* field = part(world, S("questionAnswer-") + kQuestionId);
         world.tap(field);
         world.type(c[1]);
         world.sync();
         expect(field->property("text").toString() == c[1], S("the answer reads \"%1\"").arg(field->property("text").toString()));
         expect(answersSent(world).isEmpty(), S("the half-written answer was sent"));
       });
  step(S("the user opens a new thread and comes back"), [](World& world, const Captures&, const Table&) {
    const auto route = [&] { return world.state(S("route")).toMap(); };
    const auto home = [&] { return route().value(S("kind")) == QLatin1String("home") && world.find(S("homeScreen")) != nullptr; };
    for (int tries = 0; tries < 6 && !home(); ++tries) {
      world.back();
      world.sync();
    }
    world.waitFor(home, [&] { return S("the home screen; the route is %1").arg(show(world.state(S("route")))); });
    world.tap(S("newThread"));
    world.waitFor([&] { return route().value(S("kind")) == QLatin1String("draft"); },
                  [&] { return S("a new thread; the route is %1").arg(show(world.state(S("route")))); });
    world.item(S("composer"));
    for (int tries = 0; tries < 6 && !home(); ++tries) {
      world.back();
      world.sync();
    }
    world.waitFor(home, [&] { return S("the home screen again; the route is %1").arg(show(world.state(S("route")))); });
    openThread(world, kTitle);
  });
  step(S("the answer still reads %1 on the same question").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    QQuickItem* title = world.item(S("questionTitle"));
    world.waitFor([&] { return title->property("text").toString() == QLatin1String("Which database?"); },
                  [&] { return S("the same question; the card shows \"%1\"").arg(title->property("text").toString()); });
    QQuickItem* field = world.item(S("questionAnswer-") + kQuestionId);
    world.waitFor([&] { return field->property("text").toString() == c[0]; },
                  [&] { return S("the answer \"%1\"; it reads \"%2\"").arg(c[0], field->property("text").toString()); });
  });
});

}  // namespace
