// The phone's build of the connection-owner steps both surfaces share (see
// ConnectionClientSteps.h), and the phone's own of the steps the desktop's
// ConnectionHealthSteps.cpp has for the same texts.

#include <QCoreApplication>
#include <QTcpSocket>
#include <qpa/qwindowsysteminterface.h>

#include "ConnectionWatch.h"
#include "FakeMc.h"
#include "Harness.h"
#include "McClient.h"
#include "NativeShell.h"
#include "ShellBridge.h"
#include "World.h"

#include "ConnectionClientSteps.h"

// Whether "the connection is blocked" is about a saved environment, checked
// as such (ConnectionCatalogSteps.cpp).
bool savedEnvironmentBlocked(World &world);

namespace connection_client {

const Steps phoneSteps([] {
  const QString q = kQuoted;

  step(QStringLiteral("(?:a connected client|an established connection)"),
       [](World &world, const Captures &, const Table &) {
         watch(world);
         waitForConnected(world, 1);
       });
  step(QStringLiteral("the connection drops"),
       [](World &world, const Captures &, const Table &) {
         watch(world).connectionsBefore = world.mc.connections.size();
         world.mc.drop();
       });
  step(QStringLiteral("the client keeps retrying"),
       [](World &world, const Captures &, const Table &) {
         world.waitFor(
             [&] { return watch(world).retryDelays.size() >= 3; },
             [&] {
               return QStringLiteral(
                          "three retries; there were %1 and the client is %2")
                   .arg(watch(world).retryDelays.size())
                   .arg(describe(world));
             });
       });
  step(QStringLiteral("the client stops retrying"), [](World &world,
                                                       const Captures &,
                                                       const Table &) {
    waitForPhase(world, {McClient::Phase::Refused, McClient::Phase::Blocked});
    QCoreApplication::processEvents();
    const McClient::Phase now = client(world).phase();
    expect(
        (now == McClient::Phase::Refused || now == McClient::Phase::Blocked) &&
            world.mc.connections.size() == watch(world).connectionsBefore,
        QStringLiteral("the client went on: %1").arg(describe(world)));
  });
  step(QStringLiteral("(?:the|a) client (?:connects|tries to connect)"),
       [](World &world, const Captures &, const Table &) {
         watch(world).connectionsBefore = world.mc.connections.size();
         client(world).reconnect();
         waitForPhase(world, {McClient::Phase::Ready, McClient::Phase::Refused,
                              McClient::Phase::Blocked});
       });
  step(QStringLiteral("the app comes to the foreground(?: after a moment)?"),
       [](World &world, const Captures &, const Table &) {
         watch(world).checks.clear();
         watch(world).connectionsBefore = world.mc.connections.size();
         comeToForeground();
       });
  step(QStringLiteral(
           "(?:the connection|it) is blocked(?: before opening a socket)?"),
       [](World &world, const Captures &, const Table &) {
         if (savedEnvironmentBlocked(world))
           return;
         waitForPhase(world, {McClient::Phase::Blocked});
         QCoreApplication::processEvents();
         expect(world.mc.connections.size() == watch(world).connectionsBefore &&
                    client(world).phase() == McClient::Phase::Blocked,
                QStringLiteral("a socket was opened: %1").arg(describe(world)));
       });
  // The paired session is gone from the environment: its ticket is refused.
  step(QStringLiteral("the environment refuses the client's credential"),
       [](World &world, const Captures &, const Table &) {
         watch(world);
         world.environment.sessions.clear();
       });
  step(QStringLiteral("%1 is offline").arg(q),
       [](World &world, const Captures &c, const Table &) {
         world.mc.join(c[0]);
         world.mc.setOnline(c[0], false);
       });
  // The desktop's ToastSteps clock step. The connection scenarios wait out the
  // client's own timers, which their Givens shorten, so here it only marks
  // time.
  step(QStringLiteral("(\\d+) seconds? pass(?:es)?"),
       [](World &, const Captures &, const Table &) {});
});

} // namespace connection_client
