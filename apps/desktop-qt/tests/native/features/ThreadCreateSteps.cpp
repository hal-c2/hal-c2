// The model a new thread starts with (features/threads/creating.feature):
// the project's default, whatever the thread the user came from runs on.

#include <QJsonObject>

#include "Harness.h"
#include "NavigationController.h"
#include "ThreadList.h"
#include "World.h"

namespace {

QJsonObject selectionOf(const QString& model) {
  return {{QStringLiteral("instanceId"), QStringLiteral("claudeAgent")},
          {QStringLiteral("model"), QStringLiteral("claude-") + model.toLower()}};
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("%1 has the default model %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(world.mc.projects.contains(c[0]), QStringLiteral("there is no project %1").arg(c[0]));
    QJsonObject row = world.mc.projects.value(c[0]);
    row.insert(QStringLiteral("defaultModelSelection"), selectionOf(c[1]));
    world.mc.projects.insert(c[0], row);
    world.mc.sendRow(c[0], row, QStringLiteral("project"));
    world.sync();
  });
  step(QStringLiteral("the current thread uses the model %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString key = world.native().controller<NavigationController>()->threadKey();
    expect(!key.isEmpty(), QStringLiteral("no thread is open"));
    updateThreadRow(world, key.mid(key.indexOf(QLatin1Char(':')) + 1), [&](QJsonObject& row) { row.insert(QStringLiteral("modelSelection"), selectionOf(c[0])); });
    world.waitFor([&] { return world.state(QStringLiteral("composer")).toMap().value(QStringLiteral("selectedModel")) == selectionOf(c[0]).value(QLatin1String("model")).toString(); },
                  [&] { return QStringLiteral("the thread's model; the composer is %1").arg(show(world.state(QStringLiteral("composer")))); });
  });
  step(QStringLiteral("the draft uses the model %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      const QVariantMap composer = world.state(QStringLiteral("composer")).toMap();
      return world.state(QStringLiteral("route")).toMap().value(QStringLiteral("kind")) == QLatin1String("draft") &&
             composer.value(QStringLiteral("target")) == world.draftId &&
             composer.value(QStringLiteral("selectedModel")) == selectionOf(c[0]).value(QLatin1String("model")).toString();
    }, [&] { return QStringLiteral("the draft on %1; the composer is %2").arg(c[0], show(world.state(QStringLiteral("composer")))); });
  });
});

}  // namespace
