// A provider handoff as the desktop shows it (features/mc/orchestration/
// provider-handoff.feature): the context meter by the model picker reads
// the provider conversation's reported usage, so a model change on the same
// provider thread leaves it reading what it read. The MC's side is faked as
// the entities apps/server-ex writes (test/steps/orchestration/
// provider_handoff_steps.exs).

#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>

#include "ComposerBrick.h"
#include "Harness.h"
#include "NativeShell.h"
#include "Stream.h"
#include "TimelineModel.h"
#include "World.h"

namespace {

using namespace stream;

QString providerThreadId(const QString& thread) {
  return QStringLiteral("provider-thread:codex:") + thread;
}

QVariantMap composer(World& world) {
  return world.state(QStringLiteral("composer")).toMap();
}

// What the meter by the model picker says, or empty when it is not shown.
QString meter(World& world) {
  composerBrick(world);
  QQuickItem* label = composerPart(world, QStringLiteral("contextUsage"));
  return label ? label->property("text").toString() : QString();
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("thread %1 has completed runs on %1 with model %1").arg(q),
       [](World& world, const Captures& c, const Table&) {
         // As OrchestrationViewSteps opens one: the project (the Background's
         // step recorded it), the thread row, then looking at it.
         if (world.shellSubscriptions() == 0) {
           world.connect();
           world.sync();
         }
         const QString project = world.mc.projects.keys().value(0, QStringLiteral("demo"));
         if (!world.mc.projects.contains(project)) {
           world.mc.projects.insert(project,
                                    {{QStringLiteral("id"), project},
                                     {QStringLiteral("title"), project},
                                     {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + project},
                                     {QStringLiteral("scripts"), QJsonArray()}});
         }
         world.mc.sendRow(project, world.mc.projects.value(project), QStringLiteral("project"));
         world.mc.threads.insert(
             c[0], {{QStringLiteral("id"), c[0]},
                    {QStringLiteral("title"), c[0]},
                    {QStringLiteral("projectId"), project},
                    {QStringLiteral("modelSelection"),
                     QJsonObject{{QStringLiteral("instanceId"), c[1]}, {QStringLiteral("model"), c[2]}}},
                    {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                    {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}});
         world.mc.sendRow(c[0], world.mc.threads.value(c[0]));
         world.sync();
         FakeStreams& fake = world.mc.part<FakeStreams>();
         fake.thread = c[0];
         fake.environment = world.mc.environmentId;
         look(world, world.mc.environmentId + QLatin1Char(':') + c[0]);

         for (int ordinal = 1; ordinal <= 2; ++ordinal) {
           set(world, QStringLiteral("run"), QStringLiteral("run-%1").arg(ordinal),
               {{QStringLiteral("id"), QStringLiteral("run-%1").arg(ordinal)},
                {QStringLiteral("ordinal"), ordinal},
                {QStringLiteral("status"), QStringLiteral("completed")},
                {QStringLiteral("providerThreadId"), providerThreadId(c[0])},
                {QStringLiteral("providerInstanceId"), c[1]}});
         }
       });

  step(QStringLiteral("%1 has used 80 percent of its provider context").arg(q),
       [](World& world, const Captures& c, const Table&) {
         set(world, QStringLiteral("provider-thread"), providerThreadId(c[0]),
             {{QStringLiteral("id"), providerThreadId(c[0])},
              {QStringLiteral("providerInstanceId"), QStringLiteral("codex")},
              {QStringLiteral("contextUsage"),
               QJsonObject{{QStringLiteral("usedTokens"), 160000}, {QStringLiteral("maxTokens"), 200000}}}});
         world.waitFor([&] { return timeline(world).contextUsage() == QLatin1String("80%"); },
                       [&] { return QStringLiteral("the meter to read 80%%; it reads %1").arg(timeline(world).contextUsage()); });
       });

  step(QStringLiteral("the user changes %1 to another model on the same provider").arg(q), [](World& world, const Captures& c, const Table&) {
    // As the MC records a model change on the same instance: the thread's
    // selection moves, its provider thread (and its usage) does not.
    QJsonObject& row = world.mc.threads[c[0]];
    row.insert(QStringLiteral("modelSelection"),
               QJsonObject{{QStringLiteral("instanceId"), QStringLiteral("codex")}, {QStringLiteral("model"), QStringLiteral("gpt-b")}});
    world.mc.sendRow(c[0], row);
    world.sync();
  });

  step(QStringLiteral("the next run reports the context occupancy from before the change"),
       [](World& world, const Captures&, const Table&) {
         world.waitFor([&] { return composer(world).value(QStringLiteral("contextUsage")).toString() == QLatin1String("80%"); },
                       [&] { return QStringLiteral("the composer to keep 80%%; it has %1").arg(show(composer(world))); });
         expect(meter(world).contains(QLatin1String("80%")),
                QStringLiteral("the meter reads %1").arg(meter(world)));
       });

  step(QStringLiteral("the meter does not reset to zero until the provider reports new usage"),
       [](World& world, const Captures&, const Table&) {
         world.sync();
         expect(timeline(world).contextUsage() == QLatin1String("80%") && meter(world).contains(QLatin1String("80%")),
                QStringLiteral("the meter reads %1").arg(meter(world)));
       });
});

}  // namespace
