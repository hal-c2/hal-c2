// What the desktop tells the MC it is looking at (ClientActivityController,
// features/settings/background-service.feature).

#include <QJsonArray>
#include <QJsonObject>

#include "Harness.h"
#include "Turn.h"
#include "Stream.h"
#include "World.h"

namespace {

// The last `server.reportClientActivity` the MC got.
QJsonObject lastReport(World& world) {
  QJsonObject report;
  for (const FakeMc::Rpc& rpc : world.mc.calls) {
    if (rpc.method == QLatin1String("server.reportClientActivity")) report = rpc.payload;
  }
  return report;
}

bool watches(const QJsonObject& report, const QString& type, const QString& key, const QString& value) {
  for (const QJsonValue& scope : report.value(QLatin1String("scopes")).toArray()) {
    if (scope.toObject().value(QLatin1String("type")) == type && scope.toObject().value(key) == value) return true;
  }
  return false;
}

const Steps steps([] {
  step(QStringLiteral("the user opens a thread in the client"), [](World& world, const Captures&, const Table&) {
    openTurnThread(world);
    world.sync();
  });
  step(QStringLiteral("the client tells the MC it is watching that thread's git status"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return watches(lastReport(world), QStringLiteral("vcs-status"), QStringLiteral("cwd"), QStringLiteral("/work/shop")); },
                  [&] { return QStringLiteral("the MC was last told %1").arg(show(lastReport(world).toVariantMap())); });
    const QJsonObject report = lastReport(world);
    // As a lease the MC can let run out: who watches, what, and for how long.
    expect(watches(report, QStringLiteral("thread"), QStringLiteral("threadId"), stream::kThread) && report.value(QLatin1String("clientKind")) == QLatin1String("desktop-renderer") &&
               !report.value(QLatin1String("clientId")).toString().isEmpty() && report.value(QLatin1String("ttlMs")).toInt() > 0 &&
               report.value(QLatin1String("environmentId")) == world.mc.environmentId,
           QStringLiteral("the MC was told %1").arg(show(report.toVariantMap())));
  });
});

}  // namespace
