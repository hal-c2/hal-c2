// How the desktop's one connection to its MC behaves when things go wrong
// (McClient, ConnectionHealthController, ThreadStore): the @desktop and
// @shared scenarios of features/connections/connection-health.feature and of
// mc/platform/websocket-protocol.feature. The client's environment is the MC
// the shell connects to; a second paired environment is one the MC links to.

#include <QCoreApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <QSet>
#include <QSignalSpy>
#include <QTcpSocket>
#include <QUrlQuery>
#include <qpa/qwindowsysteminterface.h>

#include "Brick.h"
#include "ConnectionHealthController.h"
#include "DraftController.h"
#include "Harness.h"
#include "SharedSteps.h"
#include "McClient.h"
#include "NativeShell.h"
#include "ShellStore.h"
#include "Stream.h"
#include "World.h"

namespace {

using namespace stream;

// The MC's HTTP side of a connection: its descriptor
// (`/.well-known/hal-c2/environment`), whether it still knows a credential
// (`/api/auth/session`), and the sessions it revoked, whose sockets it turns
// away with a 401 as apps/server-ex router.ex does.
struct FakeHealth {
  int protocol = McClient::kProtocol;
  QString serverVersion;
  QSet<QString> revoked;
  QStringList tickets;  // socket tickets it issued
  // Pairing tokens it takes at `/oauth/token`, and the session each buys.
  QHash<QString, QString> pairingTokens;
  // What the scenario watches.
  QList<int> retryDelays;
  qsizetype connectionsBefore = 0;
  qsizetype streamSubsBefore = 0;
  std::unique_ptr<QSignalSpy> checks;
  QString callError;
  QHash<QString, int> offsets;  // each followed thread's last offset
  QString thread;  // the thread the scenario is about
  QString savedEnvironment;  // the cluster member the scenario removes
  qsizetype rowsBefore = 0;
};

FakeHealth& fake(World& world) {
  return world.mc.part<FakeHealth>();
}

void answer(QTcpSocket* socket, int status, const QByteArray& body, const QByteArray& type = "application/json") {
  socket->readAll();
  socket->write("HTTP/1.1 " + QByteArray::number(status) + (status < 300 ? " OK" : " Refused") + "\r\nContent-Type: " + type +
                "\r\nContent-Length: " + QByteArray::number(body.size()) + "\r\nConnection: close\r\n\r\n" + body);
  socket->disconnectFromHost();
}

QByteArray json(const QJsonObject& object) {
  return QJsonDocument(object).toJson(QJsonDocument::Compact);
}

const FakeMc::Extension extension([](FakeMc& mc) {
  mc.onRaw(QStringLiteral("/.well-known/hal-c2/environment"), [&mc](QTcpSocket* socket, const QByteArray&) {
    const FakeHealth& health = mc.part<FakeHealth>();
    QJsonObject descriptor{{QStringLiteral("environmentId"), mc.environmentId},
                           {QStringLiteral("label"), mc.label.isEmpty() ? QStringLiteral("Workstation") : mc.label},
                           {QStringLiteral("orchestrationProtocolVersion"), health.protocol},
                           {QStringLiteral("mc"), mc.name}};
    if (!health.serverVersion.isEmpty()) descriptor.insert(QStringLiteral("serverVersion"), health.serverVersion);
    answer(socket, 200, json(descriptor));
  });
  // A socket ticket for a credential the MC knows (router.ex `/api/auth/websocket-ticket`).
  mc.onRaw(QStringLiteral("/api/auth/websocket-ticket"), [&mc](QTcpSocket* socket, const QByteArray& head) {
    static const QRegularExpression bearer(QStringLiteral("[Aa]uthorization: Bearer ([^\\r\\n]+)"));
    const QString token = bearer.match(QString::fromUtf8(head)).captured(1);
    FakeHealth& health = mc.part<FakeHealth>();
    if (health.revoked.contains(token)) {
      answer(socket, 401, json({{QStringLiteral("_tag"), QStringLiteral("EnvironmentAuthInvalidError")}, {QStringLiteral("reason"), QStringLiteral("invalid_credential")}}));
      return;
    }
    health.tickets.append(QStringLiteral("ticket-%1").arg(health.tickets.size() + 1));
    answer(socket, 200, json({{QStringLiteral("ticket"), health.tickets.last()}}));
  });
});

McClient& client(World& world) {
  return *world.native().client();
}

ConnectionHealthController& health(World& world) {
  auto* controller = world.native().shared<ConnectionHealthController>();
  if (!controller) fail(QStringLiteral("the shell has no connection health"));
  return *controller;
}

QVariantMap connection(World& world) {
  return world.state(QStringLiteral("connection")).toMap();
}

QString phase(World& world) {
  return connection(world).value(QStringLiteral("phase")).toString();
}

void waitForPhase(World& world, const QStringList& phases) {
  world.waitFor([&] { return phases.contains(phase(world)); },
                [&] { return QStringLiteral("the connection to be %1; it is %2").arg(phases.join(QStringLiteral(" or ")), show(connection(world))); });
}

void ensureConnected(World& world) {
  if (world.shellSubscriptions() == 0) world.connect();
  waitForPhase(world, {QStringLiteral("connected")});
}

// The MC goes away: it takes no new connection and drops the one it has. The
// client's next retry is `delay` ms off.
void goDown(World& world, const QList<int>& delays) {
  client(world).setRetryDelays(delays);
  world.mc.stopAccepting();
  world.mc.drop();
  world.waitFor([&] { return client(world).phase() == McClient::Phase::Retrying; },
                [&] { return QStringLiteral("a retry to be scheduled; the connection is %1").arg(show(connection(world))); });
}

void waitForReconnect(World& world, qsizetype connections) {
  world.waitFor([&] { return world.mc.connections.size() >= connections && phase(world) == QLatin1String("connected"); },
                [&] { return QStringLiteral("connection %1; there were %2 and it is %3").arg(connections).arg(world.mc.connections.size()).arg(show(connection(world))); });
}

// The notice every window shows over its layout.
Brick& notice(World& world) {
  world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nItem { ConnectionNotice {} }\n", QSize(900, 600));
  return *world.brick;
}

int streamSubscriptions(World& world, const QString& thread) {
  int count = 0;
  for (const QJsonObject& sub : world.mc.subscriptions) {
    const QJsonObject shape = sub.value(QLatin1String("shape")).toObject();
    if (shape.value(QLatin1String("type")) == QLatin1String("stream") && shape.value(QLatin1String("stream")) == thread) ++count;
  }
  return count;
}

// A thread of the MC's own, with an answer in it, opened and followed.
void followThread(World& world) {
  world.mc.projects.insert(kProject, {{QStringLiteral("id"), kProject}, {QStringLiteral("title"), kProject},
                                       {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + kProject}, {QStringLiteral("scripts"), QJsonArray()}});
  world.mc.sendRow(kProject, world.mc.projects.value(kProject), QStringLiteral("project"));
  lookAtThread(world, kProject);
  startRun(world);
  addItem(world, QStringLiteral("assistant_message"), {{QStringLiteral("text"), QStringLiteral("The cart total includes tax now.")}});
  fake(world).thread = world.mc.environmentId + QLatin1Char(':') + kThread;
  fake(world).rowsBefore = timeline(world).rowCount();
  expect(fake(world).rowsBefore > 0, QStringLiteral("the thread shows nothing: %1").arg(describe(timeline(world))));
}

void leaveThread(World& world) {
  world.native().controller<NavigationController>()->open(NavigationController::Route::of(QStringLiteral("home")));
  world.waitFor([&] { return store(world)->activeThread().isEmpty(); }, QStringLiteral("the thread to be left"));
}

// A cluster member with a project and one thread, online.
void joinMember(World& world, const QString& mc, const QString& environment) {
  world.mc.join(mc, environment);
  const QString thread = QStringLiteral("thread-") + environment;
  world.mc.sendRows(mc, QJsonArray{
      QJsonValue(QJsonArray{QStringLiteral("project-") + environment, QStringLiteral("project"),
                            QJsonObject{{QStringLiteral("id"), QStringLiteral("project-") + environment}, {QStringLiteral("title"), environment},
                                        {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + environment}, {QStringLiteral("scripts"), QJsonArray()}}}),
      QJsonValue(QJsonArray{thread, QStringLiteral("thread"),
                            QJsonObject{{QStringLiteral("id"), thread}, {QStringLiteral("title"), QStringLiteral("On ") + environment},
                                        {QStringLiteral("projectId"), QStringLiteral("project-") + environment},
                                        {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                                        {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}}})});
  for (const int id : world.mc.subscribers(QStringLiteral("shell"))) {
    world.mc.send({{QStringLiteral("t"), QStringLiteral("shell.mc")}, {QStringLiteral("id"), id}, {QStringLiteral("mc"), mc}, {QStringLiteral("online"), true}});
  }
  // What its thread holds.
  world.mc.part<FakeStreams>().threads[thread].insert(
      QStringLiteral("turn-item\nmessage:") + environment,
      QJsonObject{{QStringLiteral("id"), QStringLiteral("message:") + environment}, {QStringLiteral("type"), QStringLiteral("user_message")},
                  {QStringLiteral("ordinal"), 1}, {QStringLiteral("status"), QStringLiteral("completed")},
                  {QStringLiteral("text"), QStringLiteral("Hello from ") + environment}, {QStringLiteral("updatedAt"), iso(now())}});
  world.sync();
}

bool shows(TimelineModel& model, const QString& text) {
  for (int row = 0; row < model.rowCount(); ++row) {
    if (role(model, row, TimelineModel::TextRole).toString() == text) return true;
  }
  return false;
}

// Opens the member's thread and waits for what it holds.
void followMember(World& world, const QString& environment) {
  look(world, environment + QStringLiteral(":thread-") + environment);
  world.waitFor([&] { return shows(timeline(world), QStringLiteral("Hello from ") + environment); },
                [&] { return QStringLiteral("the thread of %1 to arrive; %2").arg(environment, describe(timeline(world))); });
}

void foreground(World&) {
  // Away, then back: the change is what the shell hears.
  QWindowSystemInterface::handleApplicationStateChanged<QWindowSystemInterface::SynchronousDelivery>(Qt::ApplicationInactive);
  QWindowSystemInterface::handleApplicationStateChanged<QWindowSystemInterface::SynchronousDelivery>(Qt::ApplicationActive);
}

}  // namespace

bool removeSavedEnvironment(World& world) {
  const QString environment = fake(world).savedEnvironment;
  if (environment.isEmpty()) return false;
  // From Cluster settings; the MC then drops the member for every client.
  world.bridge().dispatch(QStringLiteral("cluster.remove"), QVariantMap{{QStringLiteral("id"), environment}});
  world.mc.remove(environment);
  return true;
}

namespace {

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("(?:a client paired with an environment|a paired client)"), [](World& world, const Captures&, const Table&) {
    ensureConnected(world);
  });
  step(QStringLiteral("(?:a connected (?:client|environment)|an established connection)"), [](World& world, const Captures&, const Table&) {
    ensureConnected(world);
  });

  // Retrying.
  step(QStringLiteral("the environment stops answering"), [](World& world, const Captures&, const Table&) {
    FakeHealth& watched = fake(world);
    McClient* socket = &client(world);
    QObject::connect(socket, &McClient::phaseChanged, socket, [socket, &watched] {
      if (socket->phase() == McClient::Phase::Retrying) watched.retryDelays.append(socket->retryDelay());
    });
    // The shape of the real delays, a hundredth of their length.
    client(world).setRetryDelays({5, 10, 20, 40, 80});
    world.mc.stopAccepting();
  });
  step(QStringLiteral("the connection drops"), [](World& world, const Captures&, const Table&) {
    world.mc.drop();
    world.waitFor([&] { return !client(world).isReady(); }, QStringLiteral("the client to see the drop"));
  });
  step(QStringLiteral("the client retries with delays that grow up to a cap"), [](World& world, const Captures&, const Table&) {
    const QList<int> expected{5, 10, 20, 40, 80, 80, 80};
    world.waitFor([&] { return fake(world).retryDelays.size() >= expected.size(); },
                  [&] { return QStringLiteral("%1 retries; the connection is %2").arg(expected.size()).arg(show(connection(world))); });
    expect(fake(world).retryDelays.first(expected.size()) == expected,
           QStringLiteral("the delays were %1").arg(show(QVariant::fromValue(fake(world).retryDelays))));
    // And the delays a client starts with grow the same way.
    const QList<int> real = McClient().retryDelays();
    expect(real.size() > 2 && std::is_sorted(real.cbegin(), real.cend()) && real.first() < real.last(),
           QStringLiteral("the default delays are %1").arg(show(QVariant::fromValue(real))));
  });
  step(QStringLiteral("reconnects when the environment answers again"), [](World& world, const Captures&, const Table&) {
    world.mc.startAccepting();
    waitForReconnect(world, 2);
  });

  // No network.
  step(QStringLiteral("the device has no network"), [](World& world, const Captures&, const Table&) {
    client(world).setOnline(false);
  });
  step(QStringLiteral("the client waits for the network to return before trying again"), [](World& world, const Captures&, const Table&) {
    waitForPhase(world, {QStringLiteral("offline")});
    // The environment would answer; nothing is asked of it while offline.
    QCoreApplication::processEvents();
    expect(client(world).phase() == McClient::Phase::Offline && world.mc.connections.size() == 1,
           QStringLiteral("the client tried again: %1 connections, %2").arg(world.mc.connections.size()).arg(show(connection(world))));
    client(world).setOnline(true);
    waitForReconnect(world, 2);
  });

  // A refused credential.
  step(QStringLiteral("the environment refuses the client's credential"), [](World& world, const Captures&, const Table&) {
    const QString token = QStringLiteral("mc-token");
    fake(world).revoked.insert(token);
    world.mc.onRaw(QStringLiteral("/ws?token=") + token, [](QTcpSocket* socket, const QByteArray&) { answer(socket, 401, "unauthorized", "text/plain"); });
  });
  step(QStringLiteral("(?:the|a) client (?:connects|tries to connect)"), [](World& world, const Captures&, const Table&) {
    fake(world).connectionsBefore = world.mc.connections.size();
    client(world).reconnect();
    waitForPhase(world, {QStringLiteral("connected"), QStringLiteral("refused"), QStringLiteral("blocked")});
  });
  step(QStringLiteral("the client stops retrying"), [](World& world, const Captures&, const Table&) {
    waitForPhase(world, {QStringLiteral("refused")});
    QCoreApplication::processEvents();
    expect(client(world).phase() == McClient::Phase::Refused && world.mc.connections.size() == fake(world).connectionsBefore,
           QStringLiteral("the client went on: %1").arg(show(connection(world))));
  });
  step(QStringLiteral("asks the user to pair again"), [](World& world, const Captures&, const Table&) {
    expect(connection(world).value(QStringLiteral("needsPairing")).toBool(), QStringLiteral("the connection is %1").arg(show(connection(world))));
    Brick& shown = notice(world);
    expect(shown.item(QStringLiteral("connectionNotice"))->isVisible() && shown.shows(QStringLiteral("Pair again")) &&
               shown.shows(QStringLiteral("Pair again with a fresh pairing link from the environment.")),
           QStringLiteral("the window does not ask for a pairing link"));
  });

  // Pairing again (connections/pairing.feature).
  step(QStringLiteral("a device whose session was revoked"), [](World& world, const Captures&, const Table&) {
    ensureConnected(world);
    followThread(world);
    const QString token = QStringLiteral("mc-token");
    fake(world).revoked.insert(token);
    world.mc.onRaw(QStringLiteral("/ws?token=") + token, [](QTcpSocket* socket, const QByteArray&) { answer(socket, 401, "unauthorized", "text/plain"); });
    world.mc.drop();
    waitForPhase(world, {QStringLiteral("refused")});
  });
  step(QStringLiteral("the user pairs it again with a fresh link"), [](World& world, const Captures&, const Table&) {
    // The MC sells a new session for the link's token (`/oauth/token`), once.
    world.mc.onRaw(QStringLiteral("/oauth/token"), [&world](QTcpSocket* socket, const QByteArray&) {
      const auto exchange = [&world, socket] {
        const QByteArray request = socket->peek(socket->bytesAvailable());
        if (!request.contains("subject_token=")) return false;
        const bool fresh = request.contains("subject_token=fresh-1&") && fake(world).pairingTokens.isEmpty();
        if (fresh) fake(world).pairingTokens.insert(QStringLiteral("fresh-1"), QStringLiteral("session-2"));
        answer(socket, fresh ? 200 : 400, fresh ? json({{QStringLiteral("access_token"), QStringLiteral("session-2")}})
                                                : json({{QStringLiteral("error"), QStringLiteral("invalid_grant")}}));
        return true;
      };
      if (!exchange()) QObject::connect(socket, &QTcpSocket::readyRead, socket, exchange);
    });
    // A session's token does not open the socket itself, as on the real MC: it buys a ticket.
    world.mc.onRaw(QStringLiteral("/ws?token=session-2"), [](QTcpSocket* socket, const QByteArray&) { answer(socket, 401, "unauthorized", "text/plain"); });
    fake(world).connectionsBefore = world.mc.connections.size();
    Brick& shown = notice(world);
    shown.item(QStringLiteral("connectionPairingLink"))->setProperty("text", world.mc.origin().toString() + QStringLiteral("/pair#token=fresh-1"));
    shown.click(QStringLiteral("connectionPair"));
  });
  step(QStringLiteral("it reconnects with a new session"), [](World& world, const Captures&, const Table&) {
    waitForReconnect(world, fake(world).connectionsBefore + 1);
    // The new session was bought with the link, and its ticket opened the socket.
    const QString ticket = QUrlQuery(world.mc.connections.last()).queryItemValue(QStringLiteral("wsTicket"));
    expect(fake(world).pairingTokens.value(QStringLiteral("fresh-1")) == QLatin1String("session-2") && !ticket.isEmpty() &&
               fake(world).tickets.contains(ticket) && !connection(world).value(QStringLiteral("needsPairing")).toBool(),
           QStringLiteral("it connected to %1; the connection is %2").arg(world.mc.connections.last().toString(), show(connection(world))));
  });
  step(QStringLiteral("keeps its local view of the environment"), [](World& world, const Captures&, const Table&) {
    // The thread it showed is still the one it shows, with what it held, and live again.
    world.waitFor([&] { return timeline(world).status() == QLatin1String("live"); }, [&] { return describe(timeline(world)); });
    expect(store(world)->activeThread() == fake(world).thread && timeline(world).rowCount() == fake(world).rowsBefore &&
               shows(timeline(world), QStringLiteral("The cart total includes tax now.")) &&
               world.native().store()->thread(fake(world).thread).has_value(),
           QStringLiteral("the window shows %1: %2").arg(store(world)->activeThread(), describe(timeline(world))));
  });

  // Coming to the foreground.
  step(QStringLiteral("the client is waiting to retry"), [](World& world, const Captures&, const Table&) {
    goDown(world, {600000});
    world.mc.startAccepting();
  });
  step(QStringLiteral("the app comes to the foreground(?: after a moment)?"), [](World& world, const Captures&, const Table&) {
    fake(world).checks = std::make_unique<QSignalSpy>(&client(world), &McClient::checked);
    fake(world).connectionsBefore = world.mc.connections.size();
    foreground(world);
  });
  step(QStringLiteral("it tries again at once"), [](World& world, const Captures&, const Table&) {
    // Ten minutes were left on the retry.
    waitForReconnect(world, fake(world).connectionsBefore + 1);
  });
  step(QStringLiteral("the client checks the connection"), [](World& world, const Captures&, const Table&) {
    QSignalSpy& checks = *fake(world).checks;
    world.waitFor([&] { return !checks.isEmpty(); }, QStringLiteral("the connection to be checked"));
    expect(checks.first().first().toBool(), QStringLiteral("the check found the connection dead"));
  });
  step(QStringLiteral("keeps it when it answers"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(world.mc.connections.size() == fake(world).connectionsBefore && phase(world) == QLatin1String("connected"),
           QStringLiteral("the connection was replaced: %1 connections, %2").arg(world.mc.connections.size()).arg(show(connection(world))));
  });

  // What the client says of its connection.
  step(QStringLiteral("the socket opens"), [](World& world, const Captures&, const Table&) {
    world.mc.holdSnapshot = true;
    client(world).reconnect();
    world.waitFor([&] { return client(world).isReady(); }, QStringLiteral("the socket to open"));
  });
  step(QStringLiteral("the client reports connecting until the environment's configuration arrives"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(phase(world) == QLatin1String("connecting") && connection(world).value(QStringLiteral("status")) == QLatin1String("Connecting"),
           QStringLiteral("before the environment described itself the connection is %1").arg(show(connection(world))));
    world.mc.sendSnapshot();
    waitForPhase(world, {QStringLiteral("connected")});
  });
  step(QStringLiteral("its shell subscription fails"), [](World& world, const Captures&, const Table&) {
    fake(world).connectionsBefore = world.mc.connections.size();
    for (const int id : world.mc.subscribers(QStringLiteral("shell"))) {
      world.mc.send({{QStringLiteral("t"), QStringLiteral("error")}, {QStringLiteral("id"), id}, {QStringLiteral("reason"), QStringLiteral("the shell is unavailable")}});
    }
    world.sync();
  });
  step(QStringLiteral("the client reports the data problem"), [](World& world, const Captures&, const Table&) {
    waitForPhase(world, {QStringLiteral("problem")});
    expect(connection(world).value(QStringLiteral("status")) == QLatin1String("Could not load its data: the shell is unavailable") &&
               notice(world).shows(QStringLiteral("Could not load projects and threads")),
           QStringLiteral("the connection is %1").arg(show(connection(world))));
  });
  step(QStringLiteral("does not claim to be reconnecting"), [](World& world, const Captures&, const Table&) {
    expect(client(world).isReady() && world.mc.connections.size() == fake(world).connectionsBefore &&
               !connection(world).value(QStringLiteral("status")).toString().contains(QLatin1String("econnecting")) &&
               !connection(world).value(QStringLiteral("title")).toString().contains(QLatin1String("econnecting")),
           QStringLiteral("the connection is %1").arg(show(connection(world))));
  });
  step(QStringLiteral("the connection dropped because of a timeout"), [](World& world, const Captures&, const Table&) {
    // The MC's socket stays open and says nothing more; nothing listens for the retry.
    client(world).setRetryDelays({600000});
    client(world).setPongTimeout(20);
    world.mc.answerPings = false;
    world.mc.stopAccepting();
    client(world).wake();
    world.waitFor([&] { return client(world).phase() == McClient::Phase::Retrying; },
                  [&] { return QStringLiteral("the unanswered connection to be dropped; it is %1").arg(show(connection(world))); });
  });
  step(QStringLiteral("the environment reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(connection(world).value(QStringLiteral("status")) == c[0], QStringLiteral("the connection is %1").arg(show(connection(world))));
    // As Connections settings lists it.
    world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nConnectionStatusRow {}\n", QSize(640, 40));
    expect(world.brick->shows(c[0]), QStringLiteral("Connections settings does not read \"%1\"").arg(c[0]));
  });
  step(QStringLiteral("a connection that failed"), [](World& world, const Captures&, const Table&) { goDown(world, {600000}); });
  step(QStringLiteral("the user copies its trace id"), [](World& world, const Captures&, const Table&) {
    health(world).setClipboardWriter([&world](const QString& text) {
      world.clipboard = text;
      return true;
    });
    // From the notice's own button.
    notice(world).click(QStringLiteral("connectionCopyTraceId"));
  });
  step(QStringLiteral("the trace id is on the clipboard"), [](World& world, const Captures&, const Table&) {
    static const QRegularExpression traceId(QStringLiteral("^[0-9a-f]{32}$"));
    expect(traceId.match(world.clipboard).hasMatch() && world.clipboard == client(world).failureTraceId() &&
               world.clipboard == connection(world).value(QStringLiteral("traceId")),
           QStringLiteral("the clipboard holds \"%1\"; the connection is %2").arg(world.clipboard, show(connection(world))));
  });

  // What was loaded stays readable.
  step(QStringLiteral("threads were loaded before the connection dropped"), [](World& world, const Captures&, const Table&) {
    followThread(world);
    leaveThread(world);
    goDown(world, {600000});
  });
  step(QStringLiteral("the user opens one offline"), [](World& world, const Captures&, const Table&) {
    look(world, fake(world).thread, false);
  });
  step(QStringLiteral("the thread shows its cached content"), [](World& world, const Captures&, const Table&) {
    expect(timeline(world).rowCount() == fake(world).rowsBefore && shows(timeline(world), QStringLiteral("The cart total includes tax now.")),
           QStringLiteral("the thread shows %1").arg(describe(timeline(world))));
  });
  step(QStringLiteral("the client does not claim a live connection"), [](World& world, const Captures&, const Table&) {
    expect(timeline(world).status() == QLatin1String("unreachable") && phase(world) == QLatin1String("reconnecting"),
           QStringLiteral("the thread is %1 and the connection %2").arg(timeline(world).status(), show(connection(world))));
  });

  // Removing an environment.
  step(QStringLiteral("a saved environment with cached threads and drafts"), [](World& world, const Captures&, const Table&) {
    const QString environment = QStringLiteral("Build box");
    const QString thread = QStringLiteral("thread-ops");
    world.mc.join(environment);
    world.mc.sendPeerRow(environment, QStringLiteral("ops"),
                         {{QStringLiteral("id"), QStringLiteral("ops")}, {QStringLiteral("title"), QStringLiteral("ops")},
                          {QStringLiteral("workspaceRoot"), QStringLiteral("/work/ops")}, {QStringLiteral("scripts"), QJsonArray()}},
                         QStringLiteral("project"));
    world.mc.sendPeerRow(environment, thread,
                         {{QStringLiteral("id"), thread}, {QStringLiteral("title"), QStringLiteral("Deploy")}, {QStringLiteral("projectId"), QStringLiteral("ops")},
                          {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")}, {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}});
    world.sync();
    // A thread of it loaded and left, and a draft with unsent text.
    fake(world).savedEnvironment = environment;
    fake(world).thread = environment + QLatin1Char(':') + thread;
    look(world, fake(world).thread);
    leaveThread(world);
    auto* drafts = world.native().controller<DraftController>();
    const QString draft = drafts->start(environment, QStringLiteral("ops"));
    drafts->setText(draft, QStringLiteral("roll back the deploy"));
    leaveThread(world);
    expect(store(world)->timeline(fake(world).thread) && drafts->draft(draft).has_value(), QStringLiteral("nothing was kept for %1").arg(environment));
  });
  step(QStringLiteral("its credential, cached data and drafts are cleared"), [](World& world, const Captures&, const Table&) {
    const QString environment = QStringLiteral("Build box");
    world.waitFor([&] { return !world.native().store()->servesEnvironment(environment); }, QStringLiteral("the environment to go"));
    world.sync();
    // The credential is the MC's, which is told to drop the member.
    bool forgotten = false;
    for (const FakeMc::Rpc& rpc : world.mc.calls) {
      if (rpc.method == QLatin1String("cluster.remove") && rpc.payload.value(QLatin1String("id")) == environment) forgotten = true;
    }
    QStringList drafts;
    for (const DraftController::Draft& draft : world.native().controller<DraftController>()->drafts()) {
      if (draft.environmentId == environment) drafts.append(draft.text);
    }
    expect(forgotten && !world.mc.members.contains(environment), QStringLiteral("the MC still holds the member"));
    expect(!world.native().store()->thread(fake(world).thread).has_value() && world.native().store()->projectRows(environment).isEmpty() &&
               !store(world)->timeline(fake(world).thread) && !store(world)->openThreads().contains(fake(world).thread),
           QStringLiteral("its threads are still kept"));
    expect(drafts.isEmpty(), QStringLiteral("its drafts are still kept: %1").arg(drafts.join(QStringLiteral(", "))));
  });

  // Leaving a thread and coming back.
  step(QStringLiteral("the user left a thread( more than five minutes ago)?"), [](World& world, const Captures& c, const Table&) {
    followThread(world);
    leaveThread(world);
    fake(world).streamSubsBefore = streamSubscriptions(world, kThread);
    if (!c.value(0).isEmpty()) world.setTime(world.now().addSecs(6 * 60));
  });
  step(QStringLiteral("the user returns(?: within five minutes)?"), [](World& world, const Captures&, const Table&) {
    if (world.now() == now().toLocalTime()) world.setTime(world.now().addSecs(4 * 60));
    look(world, fake(world).thread);
  });
  step(QStringLiteral("the client resumes the thread from where it stopped"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(streamSubscriptions(world, kThread) == fake(world).streamSubsBefore && timeline(world).rowCount() == fake(world).rowsBefore,
           QStringLiteral("the thread was asked for %1 times; %2").arg(streamSubscriptions(world, kThread)).arg(describe(timeline(world))));
    // And it is still followed: what the agent says next arrives.
    addItem(world, QStringLiteral("assistant_message"), {{QStringLiteral("text"), QStringLiteral("Shipping is next.")}});
    expect(shows(timeline(world), QStringLiteral("Shipping is next.")), QStringLiteral("the thread shows %1").arg(describe(timeline(world))));
  });
  step(QStringLiteral("the client loads the thread again"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return streamSubscriptions(world, kThread) == fake(world).streamSubsBefore + 1 &&
                               timeline(world).rowCount() == fake(world).rowsBefore; },
                  [&] { return QStringLiteral("a fresh snapshot; the thread was asked for %1 times and shows %2")
                            .arg(streamSubscriptions(world, kThread)).arg(describe(timeline(world))); });
    // Whole: from no offset.
    QJsonObject last;
    for (const QJsonObject& sub : world.mc.subscriptions) {
      if (sub.value(QLatin1String("shape")).toObject().value(QLatin1String("stream")) == kThread) last = sub;
    }
    expect(last.value(QLatin1String("offset")).isNull(), QStringLiteral("it resumed from %1").arg(show(last.toVariantMap())));
  });

  // A replaced connection.
  step(QStringLiteral("a client subscribed to a thread"), [](World& world, const Captures&, const Table&) { followThread(world); });
  step(QStringLiteral("the connection is replaced"), [](World& world, const Captures&, const Table&) {
    fake(world).streamSubsBefore = streamSubscriptions(world, kThread);
    world.mc.drop();
    waitForReconnect(world, 2);
  });
  step(QStringLiteral("the subscription continues on the new connection"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return streamSubscriptions(world, kThread) == fake(world).streamSubsBefore + 1 && !followers(world, kThread).isEmpty() &&
                               timeline(world).status() == QLatin1String("live"); },
                  [&] { return QStringLiteral("the thread to be followed again; %1").arg(describe(timeline(world))); });
    addItem(world, QStringLiteral("assistant_message"), {{QStringLiteral("text"), QStringLiteral("Shipping is next.")}});
    expect(shows(timeline(world), QStringLiteral("Shipping is next.")), QStringLiteral("the thread shows %1").arg(describe(timeline(world))));
  });
  step(QStringLiteral("the user sent a command just before the connection dropped"), [](World& world, const Captures&, const Table&) {
    world.mc.hold(QStringLiteral("answers"));
    client(world).dispatchCommand(&client(world), world.mc.environmentId,
                                  {{QStringLiteral("type"), QStringLiteral("thread.archive")}, {QStringLiteral("threadId"), kThread}},
                                  [&world](const QJsonValue&, const std::optional<QString>& error) {
                                    fake(world).callError = error.value_or(QStringLiteral("answered"));
                                  });
    world.waitFor([&] { return world.mc.commands.size() == 1; }, QStringLiteral("the command to reach the MC"));
    world.mc.drop();
    world.waitFor([&] { return !client(world).isReady(); }, QStringLiteral("the client to see the drop"));
  });
  step(QStringLiteral("the command is not sent again automatically"), [](World& world, const Captures&, const Table&) {
    waitForReconnect(world, 2);
    world.sync();
    expect(world.mc.commands.size() == 1 && fake(world).callError == QLatin1String("disconnected"),
           QStringLiteral("%1 commands reached the MC; the sender was told \"%2\"").arg(world.mc.commands.size()).arg(fake(world).callError));
  });

  // Protocols and versions.
  step(QStringLiteral("an environment whose MC speaks (a newer|an older) protocol than the client"), [](World& world, const Captures& c, const Table&) {
    fake(world).protocol = McClient::kProtocol + (c[0] == QLatin1String("a newer") ? 1 : -1);
  });
  step(QStringLiteral("an environment whose descriptor declares an unsupported protocol"), [](World& world, const Captures&, const Table&) {
    fake(world).protocol = McClient::kProtocol + 4;
  });
  step(QStringLiteral("(?:the connection|it) is blocked(?: before opening a socket)?"), [](World& world, const Captures&, const Table&) {
    waitForPhase(world, {QStringLiteral("blocked")});
    QCoreApplication::processEvents();
    expect(world.mc.connections.size() == fake(world).connectionsBefore && client(world).phase() == McClient::Phase::Blocked,
           QStringLiteral("a socket was opened: %1 connections, %2 before").arg(world.mc.connections.size()).arg(fake(world).connectionsBefore));
  });
  step(QStringLiteral("the client says (update HAL-C2 on this device|update HAL-C2 on that environment)"), [](World& world, const Captures& c, const Table&) {
    const QString detail = connection(world).value(QStringLiteral("detail")).toString();
    expect(detail.contains(c[0], Qt::CaseInsensitive) && notice(world).shows(detail),
           QStringLiteral("the client says \"%1\"").arg(detail));
  });
  step(QStringLiteral("it says which side to update"), [](World& world, const Captures&, const Table&) {
    const QString detail = connection(world).value(QStringLiteral("detail")).toString();
    expect(detail == QLatin1String("Update HAL-C2 on this device to connect.") && notice(world).shows(detail),
           QStringLiteral("the client says \"%1\"").arg(detail));
  });
  step(QStringLiteral("this client runs HAL-C2 (\\S+)"), [](World& world, const Captures& c, const Table&) {
    health(world).setClientVersion(c[0]);
  });
  step(QStringLiteral("the environment's MC runs HAL-C2 (\\S+)"), [](World& world, const Captures& c, const Table&) {
    fake(world).serverVersion = c[0];
  });
  step(QStringLiteral("the connection is used as normal"), [](World& world, const Captures&, const Table&) {
    waitForPhase(world, {QStringLiteral("connected")});
    world.sync();
    expect(client(world).isReady() && connection(world).value(QStringLiteral("title")).toString().isEmpty(),
           QStringLiteral("the connection is %1").arg(show(connection(world))));
  });
  step(QStringLiteral("the client (warns of a version mismatch|does not warn)"), [](World& world, const Captures& c, const Table&) {
    const QVariant warning = connection(world).value(QStringLiteral("versionWarning"));
    Brick& shown = notice(world);
    if (c[0] == QLatin1String("does not warn")) {
      expect(warning.isNull() && !shown.item(QStringLiteral("connectionNotice"))->isVisible(),
             QStringLiteral("the client warns: %1").arg(show(warning)));
      return;
    }
    const QString text = warning.toMap().value(QStringLiteral("text")).toString();
    expect(text.startsWith(QLatin1String("Version mismatch")) && text.contains(fake(world).serverVersion) && shown.shows(text),
           QStringLiteral("the warning is %1").arg(show(warning)));
    // Dismissed, it stays away for this pair of versions.
    shown.click(QStringLiteral("connectionDismissWarning"));
    expect(connection(world).value(QStringLiteral("versionWarning")).isNull(), QStringLiteral("the warning stayed"));
  });

  // Events the client does not know.
  step(QStringLiteral("a connected client does not recognize an event type the MC publishes"), [](World& world, const Captures&, const Table&) {
    ensureConnected(world);
    followThread(world);
    fake(world).connectionsBefore = world.mc.connections.size();
  });
  step(QStringLiteral("the MC publishes an event of that type"), [](World& world, const Captures&, const Table&) {
    // A frame type, a shell change and a thread entity from a later MC.
    for (const int id : world.mc.subscribers(QStringLiteral("shell"))) {
      world.mc.send({{QStringLiteral("t"), QStringLiteral("shell.holograms")}, {QStringLiteral("id"), id}, {QStringLiteral("holograms"), QJsonArray{1, 2}}});
    }
    for (const int id : followers(world, kThread)) {
      world.mc.send({{QStringLiteral("t"), QStringLiteral("hologram")}, {QStringLiteral("id"), id}, {QStringLiteral("event"), QJsonObject()}});
    }
    set(world, QStringLiteral("hologram"), QStringLiteral("hologram-1"), {{QStringLiteral("id"), QStringLiteral("hologram-1")}, {QStringLiteral("shape"), QStringLiteral("cube")}});
  });
  step(QStringLiteral("the client skips the event"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(timeline(world).rowCount() == fake(world).rowsBefore && timeline(world).status() == QLatin1String("live"),
           QStringLiteral("the thread shows %1").arg(describe(timeline(world))));
  });
  step(QStringLiteral("it keeps its connection and processes the later events it knows"), [](World& world, const Captures&, const Table&) {
    addItem(world, QStringLiteral("assistant_message"), {{QStringLiteral("text"), QStringLiteral("Shipping is next.")}});
    world.mc.sendRow(QStringLiteral("thread-later"), {{QStringLiteral("id"), QStringLiteral("thread-later")}, {QStringLiteral("title"), QStringLiteral("Later")},
                                                      {QStringLiteral("projectId"), kProject},
                                                      {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:30:00Z")},
                                                      {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:30:00Z")}});
    world.sync();
    expect(world.mc.connections.size() == fake(world).connectionsBefore && phase(world) == QLatin1String("connected") &&
               shows(timeline(world), QStringLiteral("Shipping is next.")) &&
               world.native().store()->thread(world.mc.environmentId + QStringLiteral(":thread-later")).has_value(),
           QStringLiteral("the connection is %1 and the thread shows %2").arg(show(connection(world)), describe(timeline(world))));
  });

  // A cluster over one connection.
  step(QStringLiteral("a client connected to a cluster of three MCs"), [](World& world, const Captures&, const Table&) {
    ensureConnected(world);
    followThread(world);
    joinMember(world, QStringLiteral("mc-b"), QStringLiteral("env-b"));
    joinMember(world, QStringLiteral("mc-c"), QStringLiteral("env-c"));
  });
  step(QStringLiteral("the client keeps one connection for the cluster"), [](World& world, const Captures&, const Table&) {
    const QStringList environments = world.native().store()->environments();
    expect(world.mc.connections.size() == 1 && environments.size() == 3,
           QStringLiteral("%1 connections for %2").arg(world.mc.connections.size()).arg(environments.join(QStringLiteral(", "))));
  });
  step(QStringLiteral("streams from every MC arrive over it"), [](World& world, const Captures&, const Table&) {
    followMember(world, QStringLiteral("env-b"));
    followMember(world, QStringLiteral("env-c"));
    QSet<QString> followed;
    for (const int id : world.mc.subscribers(QStringLiteral("stream"))) followed.insert(world.mc.shapeOf(id).value(QLatin1String("environment")).toString());
    expect(followed == QSet<QString>{world.mc.environmentId, QStringLiteral("env-b"), QStringLiteral("env-c")} && world.mc.connections.size() == 1,
           QStringLiteral("streams of %1 over %2 connections").arg(QStringList(followed.values()).join(QStringLiteral(", "))).arg(world.mc.connections.size()));
  });
  step(QStringLiteral("a client paired with a cluster of two machines"), [](World& world, const Captures&, const Table&) {
    ensureConnected(world);
    joinMember(world, QStringLiteral("mc-b"), QStringLiteral("env-b"));
  });
  step(QStringLiteral("a third machine joins the cluster"), [](World& world, const Captures&, const Table&) {
    joinMember(world, QStringLiteral("mc-c"), QStringLiteral("env-c"));
  });
  step(QStringLiteral("the client lists the third machine's environment within a minute"), [](World& world, const Captures&, const Table&) {
    // As soon as the cluster announces it: nothing is polled for.
    expect(world.native().store()->environments().contains(QStringLiteral("env-c")) &&
               world.native().store()->thread(QStringLiteral("env-c:thread-env-c")).has_value(),
           QStringLiteral("the client knows %1").arg(world.native().store()->environments().join(QStringLiteral(", "))));
    QStringList projects;
    for (const QVariant& project : world.state(QStringLiteral("sidebar")).toMap().value(QStringLiteral("projects")).toList()) {
      projects.append(project.toMap().value(QStringLiteral("displayName")).toString());
    }
    expect(projects.contains(QStringLiteral("env-c")), QStringLiteral("the sidebar lists %1").arg(projects.join(QStringLiteral(", "))));
  });
  step(QStringLiteral("reaches it with the same credential"), [](World& world, const Captures&, const Table&) {
    followMember(world, QStringLiteral("env-c"));
    expect(world.mc.connections.size() == 1 && QUrlQuery(world.mc.connections.first()).queryItemValue(QStringLiteral("token")) == QLatin1String("mc-token"),
           QStringLiteral("it took %1 connections").arg(world.mc.connections.size()));
  });
  step(QStringLiteral("a client following threads on two cluster members"), [](World& world, const Captures&, const Table&) {
    ensureConnected(world);
    followThread(world);
    FakeStreams& streams = world.mc.part<FakeStreams>();
    fake(world).offsets.insert(kThread, streams.seq);
    joinMember(world, QStringLiteral("mc-b"), QStringLiteral("env-b"));
    followMember(world, QStringLiteral("env-b"));
    // The member's thread moves on, past where the first one stopped.
    streams.thread = QStringLiteral("thread-env-b");
    streams.environment = QStringLiteral("env-b");
    addItem(world, QStringLiteral("assistant_message"), {{QStringLiteral("text"), QStringLiteral("Deployed.")}});
    fake(world).offsets.insert(streams.thread, streams.seq);
    expect(fake(world).offsets.value(kThread) != streams.seq, QStringLiteral("both threads stopped at %1").arg(streams.seq));
  });
  step(QStringLiteral("the cluster connection drops and returns"), [](World& world, const Captures&, const Table&) {
    fake(world).connectionsBefore = world.mc.subscriptions.size();
    world.mc.drop();
    waitForReconnect(world, 2);
    world.sync();
  });
  step(QStringLiteral("each thread stream resumes from its last offset"), [](World& world, const Captures&, const Table&) {
    QHash<QString, QJsonValue> resumed;
    for (qsizetype i = fake(world).connectionsBefore; i < world.mc.subscriptions.size(); ++i) {
      const QJsonObject shape = world.mc.subscriptions[i].value(QLatin1String("shape")).toObject();
      if (shape.value(QLatin1String("type")) == QLatin1String("stream")) {
        resumed.insert(shape.value(QLatin1String("stream")).toString(), world.mc.subscriptions[i].value(QLatin1String("offset")));
      }
    }
    for (auto it = fake(world).offsets.cbegin(); it != fake(world).offsets.cend(); ++it) {
      expect(resumed.value(it.key()).isDouble() && resumed.value(it.key()).toInt() == it.value(),
             QStringLiteral("%1 stopped at %2 and resumed from %3").arg(it.key()).arg(it.value()).arg(show(resumed.value(it.key()).toVariant())));
    }
  });
  step(QStringLiteral("the shell is sent again whole"), [](World& world, const Captures&, const Table&) {
    QJsonObject shell;
    for (qsizetype i = fake(world).connectionsBefore; i < world.mc.subscriptions.size(); ++i) {
      if (world.mc.subscriptions[i].value(QLatin1String("shape")).toObject().value(QLatin1String("type")) == QLatin1String("shell")) shell = world.mc.subscriptions[i];
    }
    expect(!shell.isEmpty() && shell.value(QLatin1String("offset")).isNull() && world.native().store()->snapshots() == 2,
           QStringLiteral("the shell was asked for with %1; %2 snapshots landed").arg(show(shell.toVariantMap())).arg(world.native().store()->snapshots()));
  });
});

}  // namespace
