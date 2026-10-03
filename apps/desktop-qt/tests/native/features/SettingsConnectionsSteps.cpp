// Settings → Connections beyond its environments and access lists: a session
// that may only look, and a pairing link the clipboard refuses
// (features/settings/connections.feature).

#include <QJsonObject>

#include "ConnectionsController.h"
#include "Harness.h"
#include "World.h"

namespace {

QVariantMap page(World& world) {
  return world.state(QStringLiteral("connections")).toMap();
}

QString describe(World& world) {
  return QStringLiteral("the Connections page is %1").arg(show(page(world)));
}

const QStringList kScopes{QStringLiteral("orchestration:read"), QStringLiteral("orchestration:operate")};

const Steps steps([] {
  // A session that may only look.
  step(QStringLiteral("the user looks at this machine"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !page(world).value(QStringLiteral("accessError")).isNull(); }, [&] { return describe(world); });
  });
  step(QStringLiteral("its controls cannot be changed"), [](World& world, const Captures&, const Table&) {
    // Nothing is listed to change, and what is asked anyway is refused.
    expect(page(world).value(QStringLiteral("access")).isNull() && page(world).value(QStringLiteral("created")).isNull(), describe(world));
    world.bridge().dispatch(QStringLiteral("connections.pairingLink.create"), QVariantMap{{QStringLiteral("label"), QStringLiteral("Phone")}, {QStringLiteral("scopes"), kScopes}});
    world.sync();
    world.waitFor([&] { return !page(world).value(QStringLiteral("busy")).toBool(); }, [&] { return describe(world); });
    expect(page(world).value(QStringLiteral("created")).isNull() && page(world).value(QStringLiteral("access")).isNull(), describe(world));
  });

  // The clipboard.
  step(QStringLiteral("the clipboard is unavailable"), [](World& world, const Captures&, const Table&) {
    world.native().controller<ConnectionsController>()->setClipboardWriter([](const QString&) { return false; });
  });
  step(QStringLiteral("the user copies a pairing link"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("connections.pairingLink.create"), QVariantMap{{QStringLiteral("label"), QStringLiteral("Phone")}, {QStringLiteral("scopes"), kScopes}});
    world.waitFor([&] { return !page(world).value(QStringLiteral("created")).isNull(); }, [&] { return describe(world); });
    world.bridge().dispatch(QStringLiteral("connections.pairingLink.copy"), {});
  });
  step(QStringLiteral("the link is shown so the user can copy it by hand"), [](World& world, const Captures&, const Table&) {
    const QVariantMap shown = page(world);
    const QString url = at(shown, QStringLiteral("created.url")).toString();
    expect(shown.value(QStringLiteral("revealed")).toBool() && url.contains(QLatin1String("/pair#token=")) &&
               at(shown, QStringLiteral("notice.kind")) == QLatin1String("error") &&
               at(shown, QStringLiteral("notice.text")).toString().contains(QLatin1String("by hand")),
           describe(world));
  });
});

}  // namespace
