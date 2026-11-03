// A thread's queue on the phone (features/mc/orchestration/queue-and-steering.feature):
// what a usage limit leaves of it. The thread's stream is ComposerSteps' fake
// (FakeThreads.h), fed as HalC2.Orchestration records a limited run.

#include <QJsonArray>
#include <QJsonObject>

#include "FakeThreads.h"
#include "Harness.h"
#include "Phone.h"
#include "World.h"

namespace {

using S = QString;

const QString kNow = QStringLiteral("2026-09-23T10:00:00Z");

// The texts of the queue under the composer, front first.
QStringList queued(World& world) {
  QStringList texts;
  for (const QVariant& entry : world.state(S("turn")).toMap().value(S("queue")).toList()) texts.append(entry.toMap().value(S("text")).toString());
  return texts;
}

int commandsBefore = 0;

const Steps steps([] {
  // The orchestration features' Background: the fake MC serves the one
  // project, and the phone is paired with it.
  step(S("an MC with a project %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    world.mc.projects.clear();
    world.mc.threads.clear();
    world.mc.projects.insert(c[0], {{S("id"), c[0]}, {S("title"), c[0]}, {S("workspaceRoot"), S("/work/") + c[0]},
                                     {S("scripts"), QJsonArray()}, {S("createdAt"), S("2026-09-01T09:00:00Z")},
                                     {S("updatedAt"), S("2026-09-01T09:00:00Z")}});
    pairWithEnvironment(world);
    threadList(world);
  });
  step(S("thread %1 exists in %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    world.thread = haveThread(world, c[0]);
    world.mc.threads[world.thread].insert(S("projectId"), c[1]);
    updateRow(world.mc, world.thread, {{S("projectId"), c[1]}});
    openThread(world, c[0]);
  });

  step(S("%1 has a running turn and queued messages %1 and %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    FakeStreams& fake = world.mc.part<FakeStreams>();
    world.run = S("run-%1").arg(fake.ordinal + 1);
    setEntity(world.mc, world.thread, S("run"), world.run,
              {{S("id"), world.run}, {S("ordinal"), ++fake.ordinal}, {S("status"), S("running")}, {S("requestedAt"), kNow}, {S("startedAt"), kNow}});
    updateRow(world.mc, world.thread, {{S("activeRunId"), world.run}, {S("latestRunId"), world.run}});
    int position = 0;
    for (const QString& text : {c[1], c[2]}) {
      const QString run = S("run-queued-") + text;
      setEntity(world.mc, world.thread, S("message"), S("message:") + run, {{S("id"), S("message:") + run}, {S("role"), S("user")}, {S("text"), text}});
      setEntity(world.mc, world.thread, S("run"), run,
                {{S("id"), run}, {S("ordinal"), ++fake.ordinal}, {S("status"), S("queued")}, {S("queuePosition"), ++position},
                 {S("userMessageId"), S("message:") + run}, {S("requestedAt"), kNow}});
    }
    world.waitFor([&] { return queued(world) == QStringList{c[1], c[2]}; },
                  [&] { return S("the queue; the turn is %1").arg(show(world.state(S("turn")))); });
  });

  step(S("the provider stops %1 because its usage limit was reached").arg(kQuoted), [](World& world, const Captures&, const Table&) {
    FakeStreams& fake = world.mc.part<FakeStreams>();
    world.sync();
    commandsBefore = world.mc.commands.size();
    // The run fails as a usage limit, which holds the queue where it is.
    setEntity(world.mc, world.thread, S("turn-item"), S("item-limit"),
              {{S("id"), S("item-limit")}, {S("type"), S("error")}, {S("runId"), world.run}, {S("ordinal"), ++fake.ordinal},
               {S("status"), S("failed")}, {S("updatedAt"), kNow},
               {S("failure"), QJsonObject{{S("class"), S("usage_limit")}, {S("message"), S("You've hit your usage limit.")}}}});
    setEntity(world.mc, world.thread, S("run"), world.run, {{S("status"), S("failed")}, {S("completedAt"), kNow}});
    const QMap<QString, QJsonObject> entities = fake.threads.value(world.thread);
    for (auto it = entities.cbegin(); it != entities.cend(); ++it) {
      if (it.key().startsWith(S("run\n")) && it->value(QLatin1String("status")) == QLatin1String("queued")) {
        setEntity(world.mc, world.thread, S("run"), it->value(QLatin1String("id")).toString(), {{S("queueHeld"), true}});
      }
    }
    updateRow(world.mc, world.thread, {{S("activeRunId"), QJsonValue::Null}});
    world.sync();
  });

  step(S("%1 and %1 stay queued in their original order").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return !world.state(S("turn")).toMap().value(S("running")).toBool(); },
                  [&] { return S("the turn to stop; it is %1").arg(show(world.state(S("turn")))); });
    expect(queued(world) == QStringList{c[0], c[1]},
           S("the composer lists [%1]; the turn is %2").arg(queued(world).join(S(", ")), show(world.state(S("turn")))));
  });

  step(S("neither is discarded or sent early"), [](World& world, const Captures&, const Table&) {
    world.sync();
    // The phone asked nothing of the MC on its own: no cancel, no steer, no send.
    QStringList sent;
    for (qsizetype i = commandsBefore; i < world.mc.commands.size(); ++i) sent.append(show(world.mc.commands.at(i).toVariantMap()));
    expect(sent.isEmpty() && queued(world).size() == 2, S("the phone sent %1").arg(sent.join(S("; "))));
    // The limit is one line; the provider's own words are not shown.
    world.waitFor([&] { return world.shows(S("Usage limit reached"), false); },
                  [&] { return S("the usage limit; the screen says: %1").arg(world.texts().join(S(" | "))); });
    expect(!world.shows(S("You've hit your usage limit."), false), S("the provider's words are shown: %1").arg(world.texts().join(S(" | "))));
  });
});

}  // namespace
