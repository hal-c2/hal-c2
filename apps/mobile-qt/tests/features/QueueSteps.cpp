// A thread's queue on the phone (features/mc/orchestration/queue-and-steering.feature):
// what the composer lists of the messages waiting behind a turn, against the
// stream ComposerSteps.cpp fakes.

#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>
#include <algorithm>

#include "FakeThreads.h"
#include "Harness.h"
#include "Phone.h"
#include "World.h"

namespace {

const QString kNow = QStringLiteral("2026-09-23T10:00:00Z");

// The commands the MC had when the provider stopped, to tell what the phone sent since.
struct QueueWatch {
  qsizetype commandsBefore = 0;
};

// The texts of the queued messages the composer lists, top to bottom.
QStringList queued(World& world) {
  QList<QQuickItem*> items;
  world.findWhere([&](QQuickItem* item) {
    if (item->objectName().startsWith(QLatin1String("queueText-")) && item->isVisible()) items.append(item);
    return false;
  });
  std::sort(items.begin(), items.end(), [](QQuickItem* a, QQuickItem* b) { return a->mapToScene({0, 0}).y() < b->mapToScene({0, 0}).y(); });
  QStringList texts;
  for (QQuickItem* item : std::as_const(items)) texts.append(item->property("text").toString());
  return texts;
}

const Steps steps([] {
  using S = QString;

  step(S("an MC with a project %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    world.mc.projects.insert(c[0], {{S("id"), c[0]}, {S("title"), c[0]}, {S("workspaceRoot"), S("/work/") + c[0]},
                                    {S("scripts"), QJsonArray()}, {S("createdAt"), S("2026-09-01T09:00:00Z")},
                                    {S("updatedAt"), S("2026-09-01T09:00:00Z")}});
    pairWithEnvironment(world);
  });
  step(S("thread %1 exists in %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    world.thread = haveThread(world, c[0]);
    updateRow(world.mc, world.thread, {{S("projectId"), c[1]}});
    threadRow(world, c[0]);
  });

  step(S("%1 has a running turn and queued messages %1 and %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    openThread(world, c[0]);
    FakeStreams& fake = world.mc.part<FakeStreams>();
    world.run = S("run-%1").arg(++fake.ordinal);
    setEntity(world.mc, world.thread, S("run"), world.run,
              {{S("id"), world.run}, {S("ordinal"), fake.ordinal}, {S("status"), S("running")}, {S("requestedAt"), kNow}, {S("startedAt"), kNow}});
    int position = 0;
    for (const QString& text : {c[1], c[2]}) {
      const QString run = S("run-queued-") + text;
      setEntity(world.mc, world.thread, S("message"), S("message:") + run, {{S("id"), S("message:") + run}, {S("role"), S("user")}, {S("text"), text}});
      setEntity(world.mc, world.thread, S("run"), run,
                {{S("id"), run}, {S("ordinal"), ++fake.ordinal}, {S("status"), S("queued")}, {S("queuePosition"), ++position},
                 {S("userMessageId"), S("message:") + run}, {S("requestedAt"), kNow}});
    }
    updateRow(world.mc, world.thread, {{S("activeRunId"), world.run}, {S("latestRunId"), world.run}});
    world.waitFor([&] { return queued(world) == QStringList{c[1], c[2]}; },
                  [&] { return S("the composer to list the queue; it lists [%1]").arg(queued(world).join(S(", "))); });
  });

  // The run fails as a usage limit, which holds the queue where it is.
  step(S("the provider stops %1 because its usage limit was reached").arg(kQuoted), [](World& world, const Captures&, const Table&) {
    world.sync();
    world.mc.part<QueueWatch>().commandsBefore = world.mc.commands.size();
    FakeStreams& fake = world.mc.part<FakeStreams>();
    const QString error = S("error:") + world.run;
    setEntity(world.mc, world.thread, S("turn-item"), error,
              {{S("id"), error}, {S("type"), S("error")}, {S("runId"), world.run}, {S("ordinal"), ++fake.ordinal}, {S("status"), S("failed")},
               {S("failure"), QJsonObject{{S("class"), S("usage_limit")}, {S("message"), S("You've hit your usage limit.")}}},
               {S("updatedAt"), kNow}});
    setEntity(world.mc, world.thread, S("run"), world.run, {{S("status"), S("failed")}, {S("completedAt"), kNow}});
    const QMap<QString, QJsonObject> entities = fake.threads.value(world.thread);
    for (auto it = entities.cbegin(); it != entities.cend(); ++it) {
      if (it.key().startsWith(QLatin1String("run\n")) && it->value(QLatin1String("status")) == QLatin1String("queued")) {
        setEntity(world.mc, world.thread, S("run"), it->value(QLatin1String("id")).toString(), {{S("queueHeld"), true}});
      }
    }
    updateRow(world.mc, world.thread, {{S("activeRunId"), QJsonValue::Null}});
    world.sync();
  });

  step(S("%1 and %1 stay queued in their original order").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return !world.item(S("primaryAction"))->property("stopMode").toBool(); },
                  [&] { return S("the turn to end; the composer is %1").arg(show(world.state(S("composer")))); });
    expect(queued(world) == QStringList{c[0], c[1]}, S("the composer lists [%1]").arg(queued(world).join(S(", "))));
  });

  step(S("neither is discarded or sent early"), [](World& world, const Captures&, const Table&) {
    world.sync();
    // The phone asked nothing of the MC on its own: no cancel, no steer, no send.
    QStringList sent;
    for (qsizetype i = world.mc.part<QueueWatch>().commandsBefore; i < world.mc.commands.size(); ++i) sent.append(show(world.mc.commands.at(i).toVariantMap()));
    expect(sent.isEmpty() && queued(world).size() == 2, S("the phone sent %1").arg(sent.join(S("; "))));
    // The limit is one line, the row's title.
    world.waitFor([&] { return world.texts().join(S(" | ")).contains(S("Usage limit reached")); },
                  [&] { return S("the limit in the thread; the screen says: %1").arg(world.texts().join(S(" | "))); });
  });
});

}  // namespace
