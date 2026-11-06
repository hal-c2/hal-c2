// The connection owner both surfaces build (McClient, ConnectionHealthController)
// in features/connections/connection-health.feature: what the environment's
// answers mean for retrying, an address that answers as another environment,
// the foreground check, the setup and steady timers, keepalive pings, and how
// a call fails when its environment is not there. Included by the desktop's
// and the phone's ConnectionClientSteps.cpp, after the surface's World and its
// watch() (ConnectionHealthWatch.h, or the phone's ConnectionWatch.h); the
// steps each surface already had for the same texts stay its own.
//
// Timers are shortened through McClient's setters; the steps that name a real
// duration check it against a fresh client's default first.

#include <QCoreApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTcpSocket>
#include <QTimer>
#include <qpa/qwindowsysteminterface.h>

#include "ConnectionHealthController.h"
#include "McClient.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "ShellStore.h"
#include "ThreadStore.h"

namespace connection_client {

// What one scenario keeps between its steps.
struct Scenario {
  int lastDelay = 0;           // the last retry delay before the client connected
  qsizetype delaysBefore = 0;  // retries seen before the step acting
  int attempts = 0;            // attempts the client started (Connecting)
  int attemptsBefore = 0;
  QString message;  // what the client said when it stopped
  int pings = 0;
  bool hooked = false;
};

inline Scenario& scenario(World& world) {
  Scenario& kept = world.mc.part<Scenario>();
  if (!std::exchange(kept.hooked, true)) {
    McClient* client = world.native().client();
    QObject::connect(client, &McClient::phaseChanged, client, [client, &kept] {
      if (client->phase() == McClient::Phase::Connecting) ++kept.attempts;
    });
  }
  return kept;
}

inline McClient& client(World& world) {
  return *world.native().client();
}

inline QVariantMap connection(World& world) {
  return world.state(QStringLiteral("connection")).toMap();
}

inline QString said(World& world) {
  const QVariantMap now = connection(world);
  return QStringList{now.value(QStringLiteral("status")).toString(), now.value(QStringLiteral("title")).toString(),
                     now.value(QStringLiteral("detail")).toString()}
      .join(QStringLiteral(" | "));
}

inline QString describe(World& world) {
  return QStringLiteral("%1 (client phase %2, failure \"%3\", message \"%4\", %5 sockets)")
      .arg(said(world))
      .arg(int(client(world).phase()))
      .arg(client(world).failure(), client(world).failureMessage())
      .arg(world.mc.connections.size());
}

inline void waitForPhase(World& world, std::initializer_list<McClient::Phase> phases) {
  world.waitFor([&] { return std::find(phases.begin(), phases.end(), client(world).phase()) != phases.end(); },
                [&] { return QStringLiteral("the client's phase to change; it is %1").arg(describe(world)); });
}

inline void waitForConnected(World& world, qsizetype connections) {
  world.waitFor(
      [&] {
        return world.mc.connections.size() >= connections &&
               connection(world).value(QStringLiteral("phase")) == QLatin1String("connected");
      },
      [&] { return QStringLiteral("connection %1; the client is %2").arg(connections).arg(describe(world)); });
}

// Away, then back: the change is what the shell hears.
inline void comeToForeground() {
  QWindowSystemInterface::handleApplicationStateChanged<QWindowSystemInterface::SynchronousDelivery>(Qt::ApplicationInactive);
  QWindowSystemInterface::handleApplicationStateChanged<QWindowSystemInterface::SynchronousDelivery>(Qt::ApplicationActive);
}

inline void respond(QTcpSocket* socket, int status, const QByteArray& body, const QByteArray& type = "application/json") {
  socket->readAll();
  socket->write("HTTP/1.1 " + QByteArray::number(status) + (status < 300 ? " OK" : " Refused") + "\r\nContent-Type: " + type +
                "\r\nContent-Length: " + QByteArray::number(body.size()) + "\r\nConnection: close\r\n\r\n" + body);
  socket->disconnectFromHost();
}

// From now on the client's credential needs a socket ticket, and the MC
// answers the ticket request with `status` and `body`.
inline void answerTickets(World& world, int status, const QByteArray& body, const QByteArray& type = "application/json") {
  world.mc.onRaw(QStringLiteral("/ws?token="), [](QTcpSocket* socket, const QByteArray&) { respond(socket, 401, "unauthorized", "text/plain"); });
  world.mc.onRaw(QStringLiteral("/api/auth/websocket-ticket"),
                 [status, body, type](QTcpSocket* socket, const QByteArray&) { respond(socket, status, body, type); });
}

// A thread of `environment`'s, opened, and renamed: a command for that environment.
inline void askToDoSomething(World& world, const QString& environment) {
  const QString project = QStringLiteral("project-") + environment;
  const QString thread = QStringLiteral("thread-") + environment;
  world.mc.sendPeerRow(environment, project,
                       {{QStringLiteral("id"), project}, {QStringLiteral("title"), project},
                        {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + project}, {QStringLiteral("scripts"), QJsonArray()}},
                       QStringLiteral("project"));
  world.mc.sendPeerRow(environment, thread,
                       {{QStringLiteral("id"), thread}, {QStringLiteral("title"), QStringLiteral("Tax line")},
                        {QStringLiteral("projectId"), project}, {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                        {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}});
  const QString key = environment + QLatin1Char(':') + thread;
  world.waitFor([&] { return world.native().store()->thread(key).has_value(); },
                [&] { return QStringLiteral("the thread of %1 to be listed").arg(environment); });
  world.native().controller<NavigationController>()->open(NavigationController::Route::thread(key));
  world.waitFor([&] { return world.native().controller<ThreadStore>()->activeThread() == key; }, QStringLiteral("the thread to open"));
  world.bridge().dispatch(QStringLiteral("workspace.rename"), QVariantMap{{QStringLiteral("title"), QStringLiteral("Tax line, itemised")}});
}

inline qsizetype renames(World& world, const QString& environment) {
  qsizetype count = 0;
  for (const FakeMc::Rpc& rpc : std::as_const(world.mc.calls)) {
    if (rpc.method == QLatin1String("orchestration.dispatchCommand") && rpc.environment == environment &&
        rpc.payload.value(QLatin1String("type")) == QLatin1String("thread.metadata.update")) {
      ++count;
    }
  }
  return count;
}

inline bool toasted(World& world, const QString& description) {
  for (const QVariant& toast : world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList()) {
    if (toast.toMap().value(QStringLiteral("description")) == description) return true;
  }
  return false;
}

const Steps clientSteps([] {
  const QString q = kQuoted;

  // What the environment answers.
  step(QStringLiteral("the client is connecting to an environment"), [](World& world, const Captures&, const Table&) {
    watch(world);
    scenario(world);
    // The real delays' shape, short enough to watch three of.
    client(world).setRetryDelays({5, 10, 20, 40, 80});
  });
  step(QStringLiteral("the environment (says the credential is invalid|rejects the authentication request|has no such authentication "
                      "endpoint|answers with an internal error|answers with something that is not a reply)|the credential lacks a scope "
                      "the connection needs"),
       [](World& world, const Captures& c, const Table&) {
         const QString answer = c[0];
         if (answer.isEmpty()) {
           answerTickets(world, 403, R"({"_tag":"EnvironmentScopeRequiredError"})");
         } else if (answer.startsWith(QLatin1String("says"))) {
           answerTickets(world, 401, R"({"_tag":"EnvironmentAuthInvalidError"})");
         } else if (answer.startsWith(QLatin1String("rejects"))) {
           answerTickets(world, 400, R"({"_tag":"EnvironmentAuthRequestError"})");
         } else if (answer.startsWith(QLatin1String("has no"))) {
           answerTickets(world, 404, "<html>Not found</html>", "text/html");
         } else if (answer.contains(QLatin1String("internal error"))) {
           answerTickets(world, 500, R"({"_tag":"InternalError"})");
         } else {
           answerTickets(world, 200, "<html>Sign in</html>", "text/html");
         }
         watch(world).connectionsBefore = world.mc.connections.size();
         client(world).reconnect();
       });
  step(QStringLiteral("the status says %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return said(world).contains(c[0]); }, [&] { return QStringLiteral("\"%1\"; the status is %2").arg(c[0], describe(world)); });
  });

  // An address that answers as another environment.
  step(QStringLiteral("%1 was saved at an address").arg(q), [](World& world, const Captures&, const Table&) {
    watch(world);
    waitForConnected(world, 1);
  });
  step(QStringLiteral("a different environment now answers at that address"), [](World& world, const Captures&, const Table&) {
    world.mc.environmentId = QStringLiteral("env-elsewhere");
  });
  step(QStringLiteral("the status says the connected environment does not match the saved one"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return said(world).contains(QLatin1String("Connected environment env-elsewhere does not match")); },
                  [&] { return QStringLiteral("the mismatch; the status is %1").arg(describe(world)); });
  });
  step(QStringLiteral("the client does not keep retrying"), [](World& world, const Captures&, const Table&) {
    const qsizetype delays = watch(world).retryDelays.size();
    QCoreApplication::processEvents();
    expect(client(world).phase() == McClient::Phase::Blocked && watch(world).retryDelays.size() == delays &&
               world.mc.connections.size() == watch(world).connectionsBefore,
           QStringLiteral("the client went on: %1").arg(describe(world)));
  });

  // The foreground check.
  step(QStringLiteral("an established connection that has silently died"), [](World& world, const Captures&, const Table&) {
    watch(world);
    waitForConnected(world, 1);
    // The opening traffic is over: any frame would answer the check.
    world.sync();
    // Ten minutes to any retry: a new connection before then was not one.
    client(world).setRetryDelays({600000});
    client(world).setPongTimeout(600000);
    watch(world).probeTimeout = client(world).probeTimeout();
    client(world).setProbeTimeout(50);
    // Dead, not slow: nothing it is asked is answered, foregrounding's own calls
    // included, since any frame would answer the check.
    world.mc.answerPings = false;
    world.mc.onFrame(QStringLiteral("rpc"), [](const QJsonObject&) {});
  });
  step(QStringLiteral("the environment does not answer the check within 15 seconds"), [](World& world, const Captures&, const Table&) {
    expect(McClient().probeTimeout() == 15000, QStringLiteral("the check waits %1 ms").arg(McClient().probeTimeout()));
    world.waitFor([&] { return watch(world).checks.contains(false); }, [&] {
      QStringList checks;
      for (bool alive : watch(world).checks) checks << (alive ? QStringLiteral("answered") : QStringLiteral("unanswered"));
      return QStringLiteral("the check to fail; checks [%1]; %2").arg(checks.join(QStringLiteral(", ")), describe(world));
    });
  });
  step(QStringLiteral("the client opens a new connection without waiting out a retry delay"), [](World& world, const Captures&, const Table&) {
    waitForConnected(world, watch(world).connectionsBefore + 1);
    expect(client(world).failure().isEmpty(), QStringLiteral("the client is %1").arg(describe(world)));
  });
  step(QStringLiteral("a second failure in a row goes back to the growing delays"), [](World& world, const Captures&, const Table&) {
    // The replacement fails its check too, and the one after it cannot connect.
    const qsizetype delays = watch(world).retryDelays.size();
    world.mc.stopAccepting();
    comeToForeground();
    world.waitFor([&] { return watch(world).retryDelays.size() > delays; },
                  [&] { return QStringLiteral("a retry to be scheduled; the client is %1").arg(describe(world)); });
    expect(watch(world).retryDelays.at(delays) == 600000 && client(world).phase() == McClient::Phase::Retrying,
           QStringLiteral("the retry waits %1 ms; the client is %2").arg(watch(world).retryDelays.at(delays)).arg(describe(world)));
  });

  // The setup timer.
  step(QStringLiteral("the environment accepts the connection but never finishes introducing itself"), [](World& world, const Captures&, const Table&) {
    watch(world);
    waitForConnected(world, 1);
    client(world).setRetryDelays({600000, 1200000});
    client(world).setSetupTimeout(50);
    world.mc.sayHello = false;
    watch(world).connectionsBefore = world.mc.connections.size();
    client(world).reconnect();
  });
  // "15 seconds pass" is ToastSteps' clock step; the client's own setup timer,
  // shortened above, is what this waits out.
  step(QStringLiteral("the attempt is abandoned and reported as a timeout"), [](World& world, const Captures&, const Table&) {
    expect(McClient().setupTimeout() == 15000, QStringLiteral("the setup waits %1 ms").arg(McClient().setupTimeout()));
    waitForPhase(world, {McClient::Phase::Retrying});
    expect(world.mc.connections.size() > watch(world).connectionsBefore && client(world).failure() == QLatin1String("timeout") &&
               connection(world).value(QStringLiteral("phase")) == QLatin1String("reconnecting") &&
               said(world).contains(QLatin1String("It stopped answering.")),
           QStringLiteral("the client is %1").arg(describe(world)));
  });
  step(QStringLiteral("the client retries after the usual delay"), [](World& world, const Captures&, const Table&) {
    expect(client(world).retryDelay() == 600000, QStringLiteral("the retry waits %1 ms").arg(client(world).retryDelay()));
  });

  // The steady timer.
  step(QStringLiteral("the client has already failed to connect several times"), [](World& world, const Captures&, const Table&) {
    waitForConnected(world, 1);
    client(world).setRetryDelays({5, 10, 20, 40, 80, 160, 320, 640, 1280, 2560});
    const qsizetype delays = watch(world).retryDelays.size();
    world.mc.stopAccepting();
    world.mc.drop();
    world.waitFor([&] { return watch(world).retryDelays.size() >= delays + 3; },
                  [&] { return QStringLiteral("three retries; the client is %1").arg(describe(world)); });
  });
  step(QStringLiteral("it connects"), [](World& world, const Captures&, const Table&) {
    const qsizetype connections = world.mc.connections.size();
    world.mc.startAccepting();
    waitForConnected(world, connections + 1);
    scenario(world).lastDelay = watch(world).retryDelays.last();
  });
  step(QStringLiteral("the connection drops after (40|5) seconds"), [](World& world, const Captures& c, const Table&) {
    expect(McClient().steadyAfter() == 30000, QStringLiteral("a connection holds after %1 ms").arg(McClient().steadyAfter()));
    if (c[0] == QLatin1String("40")) {
      // The 30 s have run out: the timer, restarted at nothing, goes off before the marker.
      client(world).setSteadyAfter(0);
      bool past = false;
      QTimer::singleShot(0, &client(world), [&past] { past = true; });
      world.waitFor([&] { return past; }, QStringLiteral("the connection to have held"));
    } else {
      client(world).setSteadyAfter(600000);
    }
    scenario(world).delaysBefore = watch(world).retryDelays.size();
    world.mc.stopAccepting();
    world.mc.drop();
  });
  step(QStringLiteral("the next retry waits (the shortest delay|the next longer delay than before)"), [](World& world, const Captures& c, const Table&) {
    const qsizetype before = scenario(world).delaysBefore;
    world.waitFor([&] { return watch(world).retryDelays.size() > before; },
                  [&] { return QStringLiteral("a retry; the client is %1").arg(describe(world)); });
    const int delay = watch(world).retryDelays.at(before);
    const bool shortest = c[0] == QLatin1String("the shortest delay");
    expect(shortest ? delay == client(world).retryDelays().first() : delay > scenario(world).lastDelay,
           QStringLiteral("the retry waits %1 ms; the last before connecting waited %2").arg(delay).arg(scenario(world).lastDelay));
  });

  // Tried again on foregrounding.
  step(QStringLiteral("the client stopped retrying"), [](World& world, const Captures&, const Table&) {
    scenario(world);
    watch(world).connectionsBefore = world.mc.connections.size();
    client(world).reconnect();
    waitForPhase(world, {McClient::Phase::Refused, McClient::Phase::Blocked});
    scenario(world).attemptsBefore = scenario(world).attempts;
    scenario(world).message = said(world);
  });
  step(QStringLiteral("the client tries to connect once more"), [](World& world, const Captures&, const Table&) {
    world.waitFor(
        [&] {
          return scenario(world).attempts == scenario(world).attemptsBefore + 1 &&
                 (client(world).phase() == McClient::Phase::Refused || client(world).phase() == McClient::Phase::Blocked);
        },
        [&] { return QStringLiteral("one more attempt; there were %1 and the client is %2").arg(scenario(world).attempts - scenario(world).attemptsBefore).arg(describe(world)); });
  });
  step(QStringLiteral("stays blocked with the same reason if the environment still refuses"), [](World& world, const Captures&, const Table&) {
    QCoreApplication::processEvents();
    expect(scenario(world).attempts == scenario(world).attemptsBefore + 1 && said(world) == scenario(world).message &&
               world.mc.connections.size() == watch(world).connectionsBefore,
           QStringLiteral("it said \"%1\" before, and is %2").arg(scenario(world).message, describe(world)));
  });

  // Calls.
  step(QStringLiteral("the user asks %1 to do something").arg(q), [](World& world, const Captures& c, const Table&) {
    askToDoSomething(world, c[0]);
    world.waitFor([&] { return renames(world, c[0]) == 1; }, QStringLiteral("the command to reach the MC"));
  });
  step(QStringLiteral("the request is not queued for later"), [](World& world, const Captures&, const Table&) {
    const QString environment = world.mc.members.isEmpty() ? QString() : world.mc.members.last();
    world.mc.setOnline(environment, true);
    world.sync();
    expect(renames(world, environment) == 1, QStringLiteral("%1 was asked %2 times").arg(environment).arg(renames(world, environment)));
  });
  // "25 seconds pass" is ToastSteps' clock step; the client's ping interval,
  // shortened here once its default is checked, is what the Then waits out.
  step(QStringLiteral("a connected client with nothing open that streams"), [](World& world, const Captures&, const Table&) {
    waitForConnected(world, 1);
    expect(McClient().pingInterval() == 25000 && client(world).pingInterval() == 25000,
           QStringLiteral("the client pings every %1 ms").arg(client(world).pingInterval()));
    Scenario& kept = scenario(world);
    world.mc.onFrame(QStringLiteral("ping"), [&world, &kept](const QJsonObject&) {
      ++kept.pings;
      world.mc.send({{QStringLiteral("t"), QStringLiteral("pong")}});
    });
    client(world).setPingInterval(10);
  });
  step(QStringLiteral("the client has pinged the MC"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return scenario(world).pings > 0; }, QStringLiteral("a ping"));
  });
  step(QStringLiteral("the user asked %1 to do something and it has not answered").arg(q), [](World& world, const Captures& c, const Table&) {
    watch(world);
    waitForConnected(world, 1);
    world.mc.join(c[0]);
    world.mc.hold(QStringLiteral("answers"));
    askToDoSomething(world, c[0]);
    world.waitFor([&] { return renames(world, c[0]) == 1; }, QStringLiteral("the command to reach the MC"));
  });
  step(QStringLiteral("the connection to %1 drops").arg(q), [](World& world, const Captures&, const Table&) {
    watch(world).connectionsBefore = world.mc.connections.size();
    world.mc.drop();
  });
  step(QStringLiteral("the action fails as disconnected"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return toasted(world, QStringLiteral("disconnected")); },
                  [&] { return QStringLiteral("the rename to fail; the toasts are %1").arg(show(world.state(QStringLiteral("toasts")))); });
  });
  step(QStringLiteral("it is not sent again on the new connection"), [](World& world, const Captures&, const Table&) {
    waitForConnected(world, watch(world).connectionsBefore + 1);
    world.mc.answerHeld();
    world.sync();
    const QString environment = world.mc.members.last();
    expect(renames(world, environment) == 1, QStringLiteral("%1 was asked %2 times").arg(environment).arg(renames(world, environment)));
  });
});

}  // namespace connection_client
