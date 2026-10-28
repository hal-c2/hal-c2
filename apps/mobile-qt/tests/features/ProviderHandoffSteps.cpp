// A provider handoff as the phone shows it (features/mc/orchestration/
// provider-handoff.feature): the context meter by the model picker reads
// the provider conversation's reported usage, so a model change on the same
// provider thread leaves it reading what it read. The MC's side is faked as
// the entities apps/server-ex writes, over ComposerSteps' stream fake
// (FakeThreads.h).

#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>

#include "FakeThreads.h"
#include "Harness.h"
#include "Phone.h"
#include "World.h"

namespace {

using S = QString;

QString providerThreadId(const QString& thread) {
  return S("provider-thread:codex:") + thread;
}

QVariantMap composer(World& world) {
  return world.state(S("composer")).toMap();
}

// What the meter by the model picker says.
QString meter(World& world) {
  QQuickItem* label = world.find(S("contextUsage"));
  return label ? label->property("text").toString() : QString();
}

const Steps steps([] {
  // The provider-handoff feature's Background: the fake MC serves the one
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

  step(S("thread %1 has completed runs on %1 with model %1").arg(kQuoted),
       [](World& world, const Captures& c, const Table&) {
         world.thread = haveThread(world, c[0]);
         updateRow(world.mc, world.thread,
                   {{S("modelSelection"), QJsonObject{{S("instanceId"), c[1]}, {S("model"), c[2]}}}});
         openThread(world, c[0]);
         for (int ordinal = 1; ordinal <= 2; ++ordinal) {
           setEntity(world.mc, world.thread, S("run"), S("run-%1").arg(ordinal),
                     {{S("id"), S("run-%1").arg(ordinal)},
                      {S("ordinal"), ordinal},
                      {S("status"), S("completed")},
                      {S("providerThreadId"), providerThreadId(world.thread)},
                      {S("providerInstanceId"), c[1]}});
         }
       });

  step(S("%1 has used 80 percent of its provider context").arg(kQuoted),
       [](World& world, const Captures&, const Table&) {
         setEntity(world.mc, world.thread, S("provider-thread"), providerThreadId(world.thread),
                   {{S("id"), providerThreadId(world.thread)},
                    {S("providerInstanceId"), S("codex")},
                    {S("contextUsage"), QJsonObject{{S("usedTokens"), 160000}, {S("maxTokens"), 200000}}}});
         world.waitFor([&] { return composer(world).value(S("contextUsage")).toString() == S("80%"); },
                       [&] { return S("the meter to read 80%%; the composer is %1").arg(show(composer(world))); });
       });

  step(S("the user changes %1 to another model on the same provider").arg(kQuoted),
       [](World& world, const Captures&, const Table&) {
         // As the MC records a model change on the same instance: the
         // thread's selection moves, its provider thread does not.
         updateRow(world.mc, world.thread,
                   {{S("modelSelection"), QJsonObject{{S("instanceId"), S("codex")}, {S("model"), S("gpt-b")}}}});
         world.sync();
       });

  step(S("the next run reports the context occupancy from before the change"),
       [](World& world, const Captures&, const Table&) {
         world.waitFor([&] { return meter(world).contains(S("80%")); },
                       [&] { return S("the meter to keep 80%%; the screen says: %1").arg(world.texts().join(S(" | "))); });
       });

  step(S("the meter does not reset to zero until the provider reports new usage"),
       [](World& world, const Captures&, const Table&) {
         world.sync();
         expect(composer(world).value(S("contextUsage")).toString() == S("80%") && meter(world).contains(S("80%")),
                S("the meter reads %1").arg(meter(world)));
       });
});

}  // namespace
