// The agent's questions answered from the phone's composer
// (features/composer/question-answers.feature): the question card over the
// composer (TurnRequests.qml, shared with the desktop), tapped as a finger
// does. The thread's stream is ComposerSteps' fake (FakeThreads.h).

#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>

#include <algorithm>
#include <functional>

#include "FakeThreads.h"
#include "Harness.h"
#include "Phone.h"
#include "World.h"

namespace {

using S = QString;

const QString kTitle = QStringLiteral("Pick a database");
const QString kRun = QStringLiteral("run-question");

// The questions a step can ask, by their text: the id the answer goes under
// and the options offered.
const QHash<QString, QPair<QString, QStringList>> kAsked{
    {S("Which database?"), {S("database"), {S("Postgres"), S("SQLite")}}},
    {S("Which cache?"), {S("cache"), {S("Redis"), S("Memcached")}}},
};

QString screenTexts(World& world) { return world.texts().join(S(" | ")); }

QVariantMap shownQuestion(World& world) {
  return world.state(S("turn")).toMap().value(S("questions")).toList().value(0).toMap();
}

// The request the thread waits on: its runtime-request and its turn item.
// `questions` are the item's; the request before it, if any, is resolved.
int asks = 0;

void ask(World& world, const QJsonArray& questions, const QString& capability = S("live")) {
  if (asks > 0) setEntity(world.mc, world.thread, S("runtime-request"), S("request-%1").arg(asks), {{S("status"), S("resolved")}});
  const QString request = S("request-%1").arg(++asks);
  const QString item = S("question-%1").arg(asks);
  setEntity(world.mc, world.thread, S("runtime-request"), request,
            {{S("id"), request}, {S("status"), S("pending")}, {S("nodeId"), S("node:") + item},
             {S("responseCapability"), QJsonObject{{S("type"), capability}}}});
  setEntity(world.mc, world.thread, S("turn-item"), item,
            {{S("id"), item}, {S("type"), S("user_input_request")}, {S("runId"), kRun}, {S("ordinal"), 10 + asks},
             {S("status"), S("waiting")}, {S("requestId"), request}, {S("updatedAt"), S("2026-09-23T09:55:00Z")},
             {S("questions"), questions}});
  world.sync();
  world.waitFor([&] { return shownQuestion(world).value(S("requestId")) == request; },
                [&] { return S("the question to be asked; the composer has %1").arg(show(world.state(S("turn")))); });
}

QJsonObject asked(const QString& text, const QStringList& labels, bool multiSelect = false, bool custom = true) {
  QJsonArray options;
  for (const QString& label : labels) options.append(QJsonObject{{S("label"), label}, {S("description"), QString()}});
  const QString id = kAsked.contains(text) ? kAsked.value(text).first : S("question");
  return {{S("id"), id}, {S("header"), id}, {S("question"), text}, {S("options"), options},
          {S("multiSelect"), multiSelect}, {S("allowCustomAnswer"), custom}};
}

// The one question of the request asked again, changed by `change`.
void reask(World& world, const std::function<void(QJsonObject&)>& change) {
  QJsonObject question = asked(S("Which database?"), {S("Postgres"), S("SQLite")});
  change(question);
  ask(world, {question});
}

// The card's control `name`, once a pick is no longer about to move it on.
QQuickItem* part(World& world, const QString& name) {
  QQuickItem* requests = world.item(S("turnRequests"));
  world.waitFor([&] { return !requests->property("advancing").toBool(); }, S("the pick to settle"));
  return world.item(name);
}

void tapOption(World& world, const QString& label) {
  world.tap(part(world, S("questionOption-") + label));
  world.sync();
}

bool picked(World& world, const QString& label) {
  QQuickItem* option = world.find(S("questionOption-") + label);
  return option && option->property("checked").toBool();
}

QList<QJsonObject> answersSent(World& world) {
  world.sync();
  QList<QJsonObject> sent;
  for (const QJsonObject& command : std::as_const(world.mc.commands)) {
    if (command.value(QLatin1String("type")) == QLatin1String("runtime-request.respond")) sent.append(command);
  }
  return sent;
}

void typeAnswer(World& world, const QString& text, const QString& id = S("database")) {
  world.tap(part(world, S("questionAnswer-") + id));
  world.type(text);
  world.sync();
}

const Steps steps([] {
  step(S("the agent has asked %1 with options %1 and %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    asks = 0;
    world.thread = haveThread(world, kTitle);
    pairWithEnvironment(world);
    openThread(world, kTitle);
    setEntity(world.mc, world.thread, S("run"), kRun,
              {{S("id"), kRun}, {S("ordinal"), 1}, {S("status"), S("running")},
               {S("requestedAt"), S("2026-09-23T09:50:00Z")}, {S("startedAt"), S("2026-09-23T09:50:00Z")}});
    updateRow(world.mc, world.thread, {{S("activeRunId"), kRun}, {S("latestRunId"), kRun}, {S("hasPendingUserInput"), true}});
    ask(world, {asked(c[0], {c[1], c[2]})});
  });

  step(S("the agent asked %1 and %1 in one request").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    ask(world, {asked(c[0], kAsked.value(c[0]).second), asked(c[1], kAsked.value(c[1]).second)});
  });

  step(S("the agent asked a question and its session can no longer take the answer"), [](World& world, const Captures&, const Table&) {
    ask(world, {asked(S("Which database?"), {S("Postgres"), S("SQLite")})}, S("not_resumable"));
  });

  step(S("the question allows several answers"), [](World& world, const Captures&, const Table&) {
    // The question on screen (this file's, or ApprovalSteps' in
    // approvals-and-questions.feature), asked again allowing several
    // answers, its options kept.
    const QVariantMap shown = shownQuestion(world);
    const QVariantMap one = shown.value(S("questions")).toList().first().toMap();
    QStringList labels;
    for (const QVariant& option : one.value(S("options")).toList()) labels.append(option.toMap().value(S("label")).toString());
    setEntity(world.mc, world.thread, S("runtime-request"), shown.value(S("requestId")).toString(), {{S("status"), S("resolved")}});
    // Past the shown request's number, whoever asked it: ask() numbers its
    // own from here, and reusing the shown id would ask it twice.
    const QString shownId = shown.value(S("requestId")).toString();
    asks = std::max(asks, shownId.section(QLatin1Char('-'), 1).toInt());
    ask(world, {asked(one.value(S("question")).toString(), labels, true)});
  });

  step(S("the question allows only its listed options"), [](World& world, const Captures&, const Table&) {
    reask(world, [](QJsonObject& question) { question.insert(S("allowCustomAnswer"), false); });
  });

  step(S("the user dismisses the question without answering"), [](World& world, const Captures&, const Table&) {
    world.tap(part(world, S("questionDismiss")));
    world.sync();
  });

  step(S("the agent is told the question was dismissed"), [](World& world, const Captures&, const Table&) {
    QJsonObject dismissed;
    world.waitFor([&] {
      for (const QJsonObject& command : std::as_const(world.mc.commands)) {
        if (command.value(QLatin1String("type")) == QLatin1String("thread.user-input.dismiss")) dismissed = command;
      }
      return !dismissed.isEmpty();
    }, [&] { return S("the dismiss; the MC was sent %1 commands").arg(world.mc.commands.size()); });
    expect(dismissed.value(QLatin1String("threadId")) == world.thread && dismissed.value(QLatin1String("requestId")) == QLatin1String("request-1"),
           S("the MC was told %1").arg(show(dismissed.toVariantMap())));
    expect(answersSent(world).isEmpty(), S("the agent was also given an answer"));
  });

  step(S("the user typed %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) { typeAnswer(world, c[0]); });

  step(S("the user typed %1 as the answer to %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    typeAnswer(world, c[0], kAsked.value(c[1]).first);
  });

  step(S("submitting the answer fails"), [](World& world, const Captures&, const Table&) {
    world.mc.refusals.insert(S("runtime-request.respond"), S("The provider went away"));
    world.tap(part(world, S("questionSubmit")));
    world.waitFor([&] { return !world.state(S("toasts")).toMap().value(S("items")).toList().isEmpty(); },
                  [&] { return S("the failure to be told; the screen says: %1").arg(screenTexts(world)); });
  });

  step(S("the answer still reads %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    QQuickItem* field = world.item(S("questionAnswer-database"));
    world.waitFor([&] { return field->property("text").toString() == c[0] && !shownQuestion(world).value(S("responding")).toBool(); },
                  [&] { return S("the answer \"%1\"; it reads \"%2\"").arg(c[0], field->property("text").toString()); });
    expect(field->property("enabled").toBool(), S("the answer cannot be changed"));
  });

  step(S("the user folds the question panel away"), [](World& world, const Captures&, const Table&) {
    world.tap(part(world, S("questionFold")));
    world.sync();
  });

  step(S("the conversation can be read and the question stays pending"), [](World& world, const Captures&, const Table&) {
    const QStringList controls{S("questionOption-Postgres"), S("questionOption-Redis"), S("questionAnswer-database"), S("questionAnswer-cache")};
    world.waitFor([&] { return std::none_of(controls.begin(), controls.end(), [&](const QString& name) { return world.find(name) != nullptr; }); },
                  [&] { return S("the question's options to fold away; the screen says: %1").arg(screenTexts(world)); });
    expect(world.find(S("questionTitle")) != nullptr, S("the folded question shows no title"));
    expect(shownQuestion(world).value(S("requestId")) == S("request-%1").arg(asks), S("the question is no longer pending"));
    expect(answersSent(world).isEmpty(), S("folding the question answered it"));
  });

  step(S("the user opens the question panel again"), [](World& world, const Captures&, const Table&) {
    world.tap(world.item(S("questionFold")));
    world.sync();
  });

  step(S("%1 still reads %1 and %1 still has %1 picked").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    QQuickItem* field = world.item(S("questionAnswer-") + kAsked.value(c[0]).first);
    expect(world.shows(c[0]) && field->property("text") == c[1],
           S("the answer to %1 reads \"%2\"; the screen says: %3").arg(c[0], field->property("text").toString(), screenTexts(world)));
    world.tap(part(world, S("questionPrevious")));
    world.sync();
    world.waitFor([&] { return world.shows(c[2]); }, [&] { return S("%1 again; the screen says: %2").arg(c[2], screenTexts(world)); });
    expect(picked(world, c[3]), S("%1 is no longer picked").arg(c[3]));
  });

  step(S("the user cannot submit an answer to it"), [](World& world, const Captures&, const Table&) {
    QQuickItem* submit = world.item(S("questionSubmit"));
    QQuickItem* option = world.item(S("questionOption-Postgres"));
    QQuickItem* field = world.item(S("questionAnswer-database"));
    expect(!submit->property("enabled").toBool() && !option->property("enabled").toBool() && !field->property("enabled").toBool(),
           S("the question's controls still take an answer"));
    expect(!picked(world, S("Postgres")) && answersSent(world).isEmpty(), S("an answer was taken"));
  });

  step(S("the user submitted the answer to %1").arg(kQuoted), [](World& world, const Captures&, const Table&) {
    world.mc.hold(S("answers"));
    // One question that takes one answer is sent by the pick.
    tapOption(world, S("Postgres"));
  });

  step(S("the answer is still on its way to the agent"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return shownQuestion(world).value(S("responding")).toBool(); },
                  [&] { return S("the answer to be on its way; the composer has %1").arg(show(world.state(S("turn")))); });
  });

  step(S("submitting is unavailable"), [](World& world, const Captures&, const Table&) {
    QQuickItem* submit = world.item(S("questionSubmit"));
    expect(!submit->property("enabled").toBool(), S("the answer can be submitted again"));
    expect(answersSent(world).size() == 1, S("the answer was sent %1 times").arg(answersSent(world).size()));
    world.mc.dropHeld();
  });

  step(S("the user picked %1 and %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    tapOption(world, c[0]);
    tapOption(world, c[1]);
  });

  step(S("the user picks %1 again").arg(kQuoted), [](World& world, const Captures& c, const Table&) { tapOption(world, c[0]); });

  step(S("only %1 is picked").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    for (const QString& label : kAsked.value(S("Which database?")).second) {
      expect(picked(world, label) == (label == c[0]), S("%1 is %2picked").arg(label, picked(world, label) ? S("") : S("not ")));
    }
  });

  step(S("the user submits without picking an option"), [](World& world, const Captures&, const Table&) {
    expect(world.find(S("questionAnswer-database")) == nullptr, S("the question offers a typed answer"));
    // Nothing picked, nothing to submit: the button cannot be tapped.
    expect(!part(world, S("questionSubmit"))->property("enabled").toBool(), S("an empty answer can be submitted"));
  });

  // Neither an answer nor a message reached the MC.
  step(S("nothing is sent"), [](World& world, const Captures&, const Table&) {
    world.sync();
    for (const QJsonObject& command : std::as_const(world.mc.commands)) {
      const QString type = command.value(QLatin1String("type")).toString();
      expect(type != QLatin1String("runtime-request.respond") && type != QLatin1String("message.dispatch"),
             S("the agent was sent %1").arg(show(command.toVariantMap())));
    }
  });

  step(S("the user answered only %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    tapOption(world, kAsked.value(c[0]).second.first());
    // The pick moves on to the question still unanswered.
    world.waitFor([&] { return world.find(S("questionOption-Redis")) != nullptr; },
                  [&] { return S("the next question; the screen says: %1").arg(screenTexts(world)); });
  });

  step(S("the answers cannot be submitted"), [](World& world, const Captures&, const Table&) {
    QQuickItem* submit = part(world, S("questionSubmit"));
    expect(!submit->property("enabled").toBool(), S("half the answers can be submitted"));
    expect(answersSent(world).isEmpty(), S("half the answers were sent"));
  });

  step(S("the user answers %1 too").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    // A pick on the last question sends them all.
    tapOption(world, kAsked.value(c[0]).second.first());
  });

  step(S("both answers are sent together"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !answersSent(world).isEmpty(); },
                  [&] { return S("the answers; the MC was sent %1 commands").arg(world.mc.commands.size()); });
    const QList<QJsonObject> sent = answersSent(world);
    const QJsonObject answers = sent.first().value(QLatin1String("answers")).toObject();
    expect(sent.size() == 1 && answers.value(QLatin1String("database")) == QLatin1String("Postgres") &&
               answers.value(QLatin1String("cache")) == QLatin1String("Redis"),
           S("the agent was sent %1").arg(show(sent.last().toVariantMap())));
  });
});

}  // namespace
