// A model picked in a draft gives way once the thread runs it, so a change
// made on another client shows here (features/composer/model-and-mode.feature).

#include <QJsonObject>
#include <QVariantMap>

#include "ComposerBrick.h"
#include "Harness.h"
#include "Stream.h"
#include "World.h"

using namespace stream;

namespace {

using S = QString;

QVariantMap composer(World& world) {
  return world.state(S("composer")).toMap();
}

QString threadKey(const QString& id, World& world) {
  return world.mc.environmentId + QLatin1Char(':') + id;
}

// A second thread of the project, its draft untouched by the first's.
QString otherThread(World& world) {
  const QString id = S("thread-2");
  if (!world.mc.threads.contains(id)) {
    world.mc.threads.insert(id, {{S("id"), id}, {S("title"), S("Other")}, {S("projectId"), kProject},
                                   {S("createdAt"), S("2026-09-23T09:00:00Z")}, {S("updatedAt"), S("2026-09-23T09:00:00Z")},
                                   {S("modelSelection"), QJsonObject{{S("instanceId"), S("codex")}, {S("model"), S("gpt-5")}}}});
    world.mc.sendRow(id, world.mc.threads.value(id));
    world.sync();
  }
  return threadKey(id, world);
}

void setModel(World& world, const QString& instanceId, const QString& model) {
  QJsonObject& row = world.mc.threads[kThread];
  row.insert(S("modelSelection"), QJsonObject{{S("instanceId"), instanceId}, {S("model"), model}});
  world.mc.sendRow(kThread, row);
  world.sync();
}

void pick(World& world, const QString& model) {
  world.bridge().dispatch(S("composer.model.select"), QVariantMap{{S("instanceId"), S("codex")}, {S("model"), model}});
  world.waitFor([&] { return composer(world).value(S("selectedModel")) == model; },
                [&] { return S("the draft on %1; it is on %2").arg(model, composer(world).value(S("selectedModel")).toString()); });
}

void expectOn(World& world, const QString& instanceId, const QString& model) {
  world.waitFor([&] { return composer(world).value(S("selectedInstanceId")) == instanceId && composer(world).value(S("selectedModel")) == model; },
                [&] { return S("the draft on %1 of %2; it is on %3 of %4")
                          .arg(model, instanceId, composer(world).value(S("selectedModel")).toString(),
                               composer(world).value(S("selectedInstanceId")).toString()); });
}

const Steps steps([] {
  const QString q = kQuoted;

  step(S("the user picked %1 in the draft of a thread on this client").arg(q), [](World& world, const Captures& c, const Table&) {
    // Another thread's draft holds a pick its thread has not taken.
    look(world, otherThread(world), false);
    pick(world, S("gpt-5-codex"));
    look(world, threadKey(kThread, world));
    // This thread's pick, sent: the MC records the model the turn ran on.
    setModel(world, S("codex"), S("gpt-5-codex"));
    expectOn(world, S("codex"), S("gpt-5-codex"));
    pick(world, c[0]);
    setModel(world, S("codex"), c[0]);
  });
  step(S("then changed the thread to %1 on another client").arg(q), [](World& world, const Captures& c, const Table&) {
    setModel(world, S("claudeAgent"), c[0]);
  });
  step(S("the user returns to the thread here"), [](World& world, const Captures&, const Table&) {
    look(world, otherThread(world), false);
    look(world, threadKey(kThread, world));
  });
  step(S("the draft is on %1").arg(q), [](World& world, const Captures& c, const Table&) { expectOn(world, S("claudeAgent"), c[0]); });
  step(S("an unsent pick in another thread's draft is kept"), [](World& world, const Captures&, const Table&) {
    look(world, otherThread(world), false);
    expectOn(world, S("codex"), S("gpt-5-codex"));
  });
});

}  // namespace
