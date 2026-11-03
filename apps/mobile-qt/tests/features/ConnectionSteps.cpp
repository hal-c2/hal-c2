// The connection to the paired environment once it is lost (features/mobile/
// pairing-and-environments.feature): what the phone's notice offers, tapped
// as the user taps it.

#include <QQuickItem>

#include "ConnectionHealthController.h"
#include "Harness.h"
#include "McClient.h"
#include "NativeShell.h"
#include "Phone.h"
#include "ShellBridge.h"
#include "World.h"

namespace {

// Longer than any scenario: nothing the phone does on its own is due.
const int kLater = 60 * 60 * 1000;

QVariantMap connection(World& world) {
  return world.state(QStringLiteral("connection")).toMap();
}

// What the scenario saw of the connection before the user acted.
struct Before {
  qsizetype sockets = 0;
  QString traceId;
  bool saidConnected = false;  // whether the phone said it was connected since it started
};

// The environment goes away under a paired phone, which tries once more and
// then waits, its next try an hour off.
void loseConnection(World& world) {
  pairWithEnvironment(world);
  McClient* client = world.native().client();
  client->setRetryDelays({20, kLater});
  world.mc.stopAccepting();
  world.mc.drop();
  world.waitFor([&] { return client->phase() == McClient::Phase::Retrying && client->retryDelay() == kLater; },
                [&] { return QStringLiteral("the phone to give up for now; the connection is %1").arg(show(connection(world))); });
  // Its icon, once the reconnect is past its grace; its panel says why.
  world.openConnectionNotice();
  world.item(QStringLiteral("connectionNoticeTitle"));
}

const Steps steps([] {
  using S = QString;

  // features/connections/connection-health.feature, as far as the phone runs it.
  step(S("(?:a client paired with an environment|a paired client)"), [](World& world, const Captures&, const Table&) { pairWithEnvironment(world); });

  // A fresh start, its first connection never coming up.
  step(S("the environment takes no connections"), [](World& world, const Captures&, const Table&) { world.mc.stopAccepting(); });
  step(S("the app starts and connects to it"), [](World& world, const Captures&, const Table&) {
    world.close();
    world.open();
    // A grace long enough that nothing in the scenario could outlast it.
    world.native().shared<ConnectionHealthController>()->setGrace(600000);
    Before& seen = world.mc.part<Before>();
    seen.saidConnected = connection(world).value(S("phase")) == QLatin1String("connected") || connection(world).value(S("settling")).toBool();
    QObject::connect(&world.bridge(), &ShellBridge::stateEntryChanged, &world.native(), [&seen](const QString& key, const QVariant& value) {
      if (key != QLatin1String("connection")) return;
      const QVariantMap said = value.toMap();
      if (said.value(QStringLiteral("phase")) == QLatin1String("connected") || said.value(QStringLiteral("settling")).toBool()) seen.saidConnected = true;
    });
  });
  step(S("within a second and a half the window shows it is not connected"), [](World& world, const Captures&, const Table&) {
    QQuickItem* status = world.item(S("connectionNoticeStatus"));
    const QString word = connection(world).value(S("status")).toString();
    expect(status->property("text") == word && word != S("Connected"),
           S("the notice reads \"%1\"; the connection is %2").arg(status->property("text").toString(), show(connection(world))));
  });
  step(S("nothing said it was connected"), [](World& world, const Captures&, const Table&) {
    expect(!world.mc.part<Before>().saidConnected && !connection(world).value(S("settling")).toBool(),
           S("the phone said it was connected; the connection is %1").arg(show(connection(world))));
  });

  // It is back by the time the user looks, which nothing tells the phone.
  step(S("an environment has lost its connection"), [](World& world, const Captures&, const Table&) {
    loseConnection(world);
    world.mc.startAccepting();
  });

  step(S("the user asks to reconnect it"), [](World& world, const Captures&, const Table&) {
    world.mc.part<Before>().sockets = world.mc.connections.size();
    world.tap(S("connectionRetry"));
  });

  step(S("the phone tries to connect again straight away"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.mc.connections.size() > world.mc.part<Before>().sockets; },
                  [&] { return S("the phone to try; its next try is in %1 ms").arg(world.native().client()->retryDelay()); });
    world.waitFor([&] { return connection(world).value(S("phase")) == QLatin1String("connected") && world.find(S("connectionNotice")) == nullptr; },
                  [&] { return S("the connection; it is %1").arg(show(connection(world))); });
  });

  step(S("an environment connection has a trace id"), [](World& world, const Captures&, const Table&) {
    loseConnection(world);
    world.mc.part<Before>().traceId = connection(world).value(S("traceId")).toString();
    expect(!world.mc.part<Before>().traceId.isEmpty(), S("the failed connection has no trace id: %1").arg(show(connection(world))));
  });

  step(S("the user copies the trace id"), [](World& world, const Captures&, const Table&) { world.tap(S("connectionCopyTraceId")); });

  step(S("the trace id is on the clipboard"), [](World& world, const Captures&, const Table&) {
    expect(world.clipboard == world.mc.part<Before>().traceId, S("the clipboard has \"%1\", not %2").arg(world.clipboard, world.mc.part<Before>().traceId));
    world.waitFor([&] { return world.shows(S("Trace ID copied")); }, [&] { return S("the phone to say it copied; the screen says: %1").arg(world.texts().join(S(" | "))); });
  });
});

}  // namespace
