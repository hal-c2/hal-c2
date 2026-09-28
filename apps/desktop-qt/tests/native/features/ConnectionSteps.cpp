// Connecting the shell to its node, who owns what once it has, and the
// environments the page lends the node (features/desktop/native-connection.feature).

#include <QUrl>
#include <QUrlQuery>
#include <QVariantList>

#include "Harness.h"
#include "World.h"

namespace {

const Steps steps([] {
  const QString q = kQuoted;

  // The node and the page.
  step(QStringLiteral("the desktop's node %1 serves the environment %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.node.name = c[0];
    world.node.environmentId = c[1];
  });
  step(QStringLiteral("the node is clustered with %1, which serves %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.node.join(c[0], c[1]);
    world.sync();
  });
  step(QStringLiteral("the node is linked to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.node.link(c[0]);
    world.sync();
  });
  step(QStringLiteral("the page has access to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QVariantList access = world.state(QStringLiteral("environmentAccess")).toList();
    access.append(QVariantMap{
        {QStringLiteral("environmentId"), c[0]},
        {QStringLiteral("origin"), QStringLiteral("http://") + c[0] + QStringLiteral(":3780")},
        {QStringLiteral("token"), QStringLiteral("page-token-") + c[0]},
    });
    world.bridge().publish(QStringLiteral("environmentAccess"), access);
    world.sync();
  });
  step(QStringLiteral("the page loses its connection to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QVariantList access;
    for (const QVariant& entry : world.state(QStringLiteral("environmentAccess")).toList()) {
      const QString id = entry.toMap().value(QStringLiteral("environmentId")).toString();
      access.append(id == c[0] ? QVariant(QVariantMap{{QStringLiteral("environmentId"), id}}) : entry);
    }
    world.bridge().publish(QStringLiteral("environmentAccess"), access);
    world.sync();
  });
  step(QStringLiteral("the node is linked to %1 with the page's access").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(world.node.linked.contains(c[0]), QStringLiteral("the node is linked to %1").arg(world.node.linked.join(u", ")));
    expect(world.node.lent.value(c[0]) == QStringLiteral("page-token-") + c[0],
           QStringLiteral("the node was lent %1").arg(world.node.lent.value(c[0])));
  });
  step(QStringLiteral("the page forgets %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QVariantList access = world.state(QStringLiteral("environmentAccess")).toList();
    access.removeIf([&](const QVariant& entry) { return entry.toMap().value(QStringLiteral("environmentId")) == c[0]; });
    world.bridge().publish(QStringLiteral("environmentAccess"), access);
    world.sync();
  });
  step(QStringLiteral("the node is not linked to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(!world.node.linked.contains(c[0]), QStringLiteral("the node is linked to %1").arg(world.node.linked.join(u", ")));
  });

  // Connecting.
  step(QStringLiteral("the desktop shell connects to its node with the token %1").arg(q),
       [](World& world, const Captures& c, const Table&) { world.connect(c[0]); });
  step(QStringLiteral("the desktop shell connects to its node"), [](World& world, const Captures&, const Table&) { world.connect(); });
  step(QStringLiteral("the desktop shell is connected to its node"), [](World& world, const Captures&, const Table&) {
    world.connect();
    world.waitFor([&world] { return world.state(QStringLiteral("native")).isValid(); },
                  QStringLiteral("the shell to take over"));
  });
  step(QStringLiteral("the node holds back its snapshot"), [](World& world, const Captures&, const Table&) {
    world.node.holdSnapshot = true;
  });
  step(QStringLiteral("the node sends its snapshot"), [](World& world, const Captures&, const Table&) {
    world.node.sendSnapshot();
    world.sync();
  });
  step(QStringLiteral("the node stops accepting connections"), [](World& world, const Captures&, const Table&) {
    world.node.stopAccepting();
  });
  step(QStringLiteral("the node drops the connection"), [](World& world, const Captures&, const Table&) {
    world.node.drop();
    world.waitFor([&world] { return !world.native().client()->isReady(); }, QStringLiteral("the shell to see the drop"));
  });
  step(QStringLiteral("the node was reached with the token %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(!world.node.connections.isEmpty(), QStringLiteral("the node was never reached"));
    const QUrl url = world.node.connections.first();
    expect(url.path() == QLatin1String("/ws"), QStringLiteral("connected to %1, not /ws").arg(url.path()));
    const QString token = QUrlQuery(url).queryItemValue(QStringLiteral("token"));
    expect(token == c[0], QStringLiteral("connected with the token \"%1\"").arg(token));
  });
  step(QStringLiteral("the shell subscribed to the node's %1 shape( again)?").arg(q), [](World& world, const Captures& c, const Table&) {
    const int wanted = c.value(1).isEmpty() ? 1 : 2;
    world.waitFor([&] {
      int count = 0;
      for (const QJsonObject& sub : world.node.subscriptions) {
        if (sub.value(QLatin1String("shape")).toObject().value(QLatin1String("type")).toString() == c[0]) count++;
      }
      return count >= wanted;
    }, QStringLiteral("%1 subscription(s) to %2").arg(wanted).arg(c[0]));
  });
  step(QStringLiteral("the shell reconnects to the node"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&world] { return world.node.connections.size() >= 2 && world.native().client()->isReady(); },
                  QStringLiteral("a second connection"));
  });
  step(QStringLiteral("the shell has not taken over from the page"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(!world.state(QStringLiteral("native")).isValid(),
           QStringLiteral("native is %1").arg(show(world.state(QStringLiteral("native")))));
  });
  step(QStringLiteral("the shell tells the page it owns the sidebar and the composer"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&world] { return world.pageNative.isValid(); }, QStringLiteral("the page to be told"));
    const QVariantMap native = world.pageNative.toMap();
    expect(native.value(QStringLiteral("sidebar")).toBool() && native.value(QStringLiteral("composer")).toBool(),
           QStringLiteral("the page was told %1").arg(show(native)));
    expect(world.state(QStringLiteral("native")) == world.pageNative,
           QStringLiteral("native is %1").arg(show(world.state(QStringLiteral("native")))));
  });
  step(QStringLiteral("the page has not been told who owns the sidebar"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(!world.pageNative.isValid(), QStringLiteral("the page was told %1").arg(show(world.pageNative)));
  });
  step(QStringLiteral("the page forgets who owns the sidebar"), [](World& world, const Captures&, const Table&) {
    world.pageNative = QVariant();
  });
  step(QStringLiteral("the page asks who owns the sidebar"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("shell.native.query"));
  });
  step(QStringLiteral("the page publishes its own sidebar"), [](World& world, const Captures&, const Table&) {
    auto* channel = static_cast<ShellChannel*>(world.bridge().channel());
    channel->publish(QStringLiteral("sidebar"), QVariantMap{{QStringLiteral("active"), QVariantList()}});
  });
});

}  // namespace
