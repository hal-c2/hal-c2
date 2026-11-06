// How the phone's one connection to its environment behaves when things go
// wrong (features/connections/connection-health.feature): the desktop's
// McClient, ConnectionHealthController and ThreadStore under the phone's root,
// whose connection notice is the one the user taps. The desktop harness's
// ConnectionHealthSteps.cpp drives the same scenarios on the desktop; these
// read the phone's screen where the two differ. The steps that say what the
// client does with a refused credential, a drop and the foreground are
// ConnectionClientSteps.cpp's; what both record is ConnectionWatch's.

#include <QCoreApplication>
#include <QFile>
#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>
#include <QSet>
#include <QTimeZone>
#include <QUrlQuery>
#include <algorithm>

#include "ConnectionHealthController.h"
#include "ConnectionWatch.h"
#include "DraftController.h"
#include "FakeThreads.h"
#include "Harness.h"
#include "LocalCache.h"
#include "McClient.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "Phone.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ThreadStore.h"
#include "TimelineModel.h"
#include "World.h"

ConnectionWatch& watch(World& world) {
  ConnectionWatch& watched = world.mc.part<ConnectionWatch>();
  McClient* client = world.native().client();
  if (watched.watched == client) return watched;
  watched.watched = client;
  QObject::connect(client, &McClient::phaseChanged, client, [client, &watched] {
    if (client->phase() == McClient::Phase::Retrying) watched.retryDelays.append(client->retryDelay());
  });
  QObject::connect(client, &McClient::checked, client, [&watched](bool alive) { watched.checks.append(alive); });
  return watched;
}

namespace {

using S = QString;

const QString kTitle = S("Tax line");
const QString kKept = S("The cart total includes tax now.");
const QString kNext = S("Shipping is next.");

// The scenarios' clock: 2026-09-23 10:00, UTC.
QDateTime start() {
  return QDateTime(QDate(2026, 9, 23), QTime(10, 0), QTimeZone::UTC);
}

QString iso(const QDateTime& time) {
  return time.toUTC().toString(Qt::ISODateWithMs);
}

// What a scenario saw before it acted.
struct Seen {
  qsizetype connections = 0;
  qsizetype retries = 0;
  qsizetype subscriptions = 0;
  int streamSubs = 0;
  // The thread the scenario is about: its id on the MC, its key on the phone,
  // and how many rows it showed.
  QString threadId;
  QString thread;
  int rows = 0;
  QDateTime now;
  QString callError;
  QHash<QString, int> offsets;  // each followed thread's last offset
  QString draft;
  bool sawDown = false;    // whether the controller saw the client leave Ready
  bool shownDown = false;  // whether the phone said the connection was down
};

Seen& seen(World& world) {
  return world.mc.part<Seen>();
}

McClient& client(World& world) {
  return *world.native().client();
}

ConnectionHealthController& health(World& world) {
  auto* controller = world.native().shared<ConnectionHealthController>();
  if (!controller) fail(S("the phone has no connection health"));
  return *controller;
}

QVariantMap connection(World& world) {
  return world.state(S("connection")).toMap();
}

QString phase(World& world) {
  return connection(world).value(S("phase")).toString();
}

void waitForPhase(World& world, const QStringList& phases) {
  world.waitFor([&] { return phases.contains(phase(world)); },
                [&] { return S("the connection to be %1; it is %2").arg(phases.join(S(" or ")), show(connection(world))); });
}

void waitForReconnect(World& world, qsizetype connections) {
  world.waitFor([&] { return world.mc.connections.size() >= connections && phase(world) == QLatin1String("connected"); },
                [&] { return S("connection %1; there were %2 and it is %3").arg(connections).arg(world.mc.connections.size()).arg(show(connection(world))); });
}

// The MC goes away: it takes no new connection and drops the one it has.
void goDown(World& world, const QList<int>& delays) {
  client(world).setRetryDelays(delays);
  world.mc.stopAccepting();
  world.mc.drop();
  world.waitFor([&] { return client(world).phase() == McClient::Phase::Retrying; },
                [&] { return S("a retry to be scheduled; the connection is %1").arg(show(connection(world))); });
}

// The MC as a phone on another machine reaches it: at an address that is not
// loopback's. The any-address is not, and the system routes it to this machine.
QUrl remoteOrigin(World& world) {
  QUrl origin = world.mc.origin();
  origin.setHost(S("0.0.0.0"));
  return origin;
}

// The phone opens its environment anew at `origin`, with the session it paired
// with.
void openAt(World& world, const QUrl& origin) {
  world.native().close();
  world.native().open(origin, world.environment.sessions.last());
}

// What the system says of the device's network from here on, and that it
// changed.
void setNetwork(World& world, bool disconnected, bool interfaceUp) {
  health(world).setNetwork({[disconnected] { return disconnected; }, [interfaceUp] { return interfaceUp; }});
  health(world).networkChanged();
}

// The connection notice's panel, opened with a tap once a reconnect is past
// its grace (until then nothing shows), and whether it says `text`.
bool noticeSays(World& world, const QString& text) {
  world.waitFor([&] { return !connection(world).value(S("settling")).toBool(); },
                [&] { return S("the reconnect to be past its grace; the connection is %1").arg(show(connection(world))); });
  world.openConnectionNotice();
  return world.shows(text);
}

// The thread on the phone.
ThreadStore* store(World& world) {
  return world.native().controller<ThreadStore>();
}

TimelineModel& timeline(World& world) {
  TimelineModel* model = store(world)->activeTimeline();
  if (!model) fail(S("no thread is open"));
  return *model;
}

QString textOf(TimelineModel& model, int row) {
  return model.data(model.index(row), TimelineModel::TextRole).toString();
}

int rowOf(TimelineModel& model, const QString& text) {
  for (int row = 0; row < model.rowCount(); ++row) {
    if (textOf(model, row) == text) return row;
  }
  return -1;
}

QString describe(TimelineModel& model) {
  QStringList rows;
  for (int row = 0; row < model.rowCount(); ++row) rows.append(textOf(model, row));
  return S("status %1, rows: %2").arg(model.status(), rows.join(S(" | ")));
}

// A turn of the thread `threadId`: the user's message and the agent's answer.
void answer(World& world, const QString& threadId, const QString& text) {
  FakeStreams& streams = world.mc.part<FakeStreams>();
  const QString run = S("run-%1").arg(streams.ordinal + 1);
  const QString at = iso(start());
  setEntity(
      world.mc, threadId, S("run"), run,
      {{S("id"), run}, {S("ordinal"), ++streams.ordinal}, {S("status"), S("completed")}, {S("requestedAt"), at}, {S("startedAt"), at}, {S("completedAt"), at}});
  setEntity(world.mc, threadId, S("turn-item"), S("message:") + run,
            {{S("id"), S("message:") + run},
             {S("type"), S("user_message")},
             {S("runId"), run},
             {S("ordinal"), ++streams.ordinal},
             {S("status"), S("completed")},
             {S("text"), S("Add a tax line to the cart")},
             {S("updatedAt"), at}});
  setEntity(world.mc, threadId, S("turn-item"), S("reply:") + run,
            {{S("id"), S("reply:") + run},
             {S("type"), S("assistant_message")},
             {S("runId"), run},
             {S("ordinal"), ++streams.ordinal},
             {S("status"), S("completed")},
             {S("text"), text},
             {S("updatedAt"), at}});
  if (world.mc.connected()) world.sync();
}

// Opens the thread `key` by its route; waits for it to follow its MC unless
// it cannot.
void look(World& world, const QString& key, bool live = true) {
  world.native().controller<NavigationController>()->open(NavigationController::Route::thread(key));
  world.waitFor([&] { return store(world)->activeThread() == key && store(world)->activeTimeline(); }, S("the thread to open"));
  if (!live) return;
  world.waitFor([&] { return timeline(world).status() == QLatin1String("live"); },
                [&] { return S("the thread to follow its MC; %1").arg(describe(timeline(world))); });
}

// The thread "Tax line" with an answer in it, opened from the thread list and
// followed. Its MC names its log, so a phone that comes back may resume.
void followThread(World& world) {
  Seen& s = seen(world);
  world.mc.part<FakeStreams>().handle = S("log-1.1");
  s.now = start();
  world.setTime(s.now);
  s.threadId = haveThread(world, kTitle);
  s.thread = world.mc.environmentId + QLatin1Char(':') + s.threadId;
  world.thread = s.threadId;
  answer(world, s.threadId, kKept);
  openThread(world, kTitle);
  world.waitFor([&] { return store(world)->activeTimeline() && timeline(world).status() == QLatin1String("live") && rowOf(timeline(world), kKept) >= 0; },
                [&] { return S("the thread to show its answer; the screen says: %1").arg(world.texts().join(S(" | "))); });
  s.rows = timeline(world).rowCount();
}

void leaveThread(World& world) {
  world.native().controller<NavigationController>()->open(NavigationController::Route::of(S("home")));
  world.waitFor([&] { return store(world)->activeThread().isEmpty(); }, S("the thread to be left"));
}

int streamSubscriptions(World& world, const QString& threadId) {
  int count = 0;
  for (const QJsonObject& sub : world.mc.subscriptions) {
    const QJsonObject shape = sub.value(QLatin1String("shape")).toObject();
    if (shape.value(QLatin1String("type")) == QLatin1String("stream") && shape.value(QLatin1String("stream")) == threadId) ++count;
  }
  return count;
}

QList<int> followers(World& world, const QString& threadId) {
  QList<int> ids;
  for (const int id : world.mc.subscribers(S("stream"))) {
    if (world.mc.shapeOf(id).value(QLatin1String("stream")).toString() == threadId) ids.append(id);
  }
  return ids;
}

// What the agent says next arrives on the thread on screen.
void expectFollowed(World& world) {
  answer(world, seen(world).threadId, kNext);
  world.waitFor([&] { return rowOf(timeline(world), kNext) >= 0; }, [&] { return S("the next answer; %1").arg(describe(timeline(world))); });
}

// A cluster member with a project and one thread, online.
void joinMember(World& world, const QString& mc, const QString& environment) {
  world.mc.join(mc, environment);
  const QString thread = S("thread-") + environment;
  world.mc.sendRows(mc, QJsonArray{QJsonValue(QJsonArray{S("project-") + environment, S("project"),
                                                         QJsonObject{{S("id"), S("project-") + environment},
                                                                     {S("title"), environment},
                                                                     {S("workspaceRoot"), S("/work/") + environment},
                                                                     {S("scripts"), QJsonArray()}}}),
                                   QJsonValue(QJsonArray{thread, S("thread"),
                                                         QJsonObject{{S("id"), thread},
                                                                     {S("title"), S("On ") + environment},
                                                                     {S("projectId"), S("project-") + environment},
                                                                     {S("createdAt"), S("2026-09-23T09:00:00Z")},
                                                                     {S("updatedAt"), S("2026-09-23T09:00:00Z")}}})});
  for (const int id : world.mc.subscribers(S("shell"))) {
    world.mc.send({{S("t"), S("shell.mc")}, {S("id"), id}, {S("mc"), mc}, {S("online"), true}});
  }
  world.mc.part<FakeStreams>().threads[thread].insert(S("turn-item\nmessage:") + environment, QJsonObject{{S("id"), S("message:") + environment},
                                                                                                          {S("type"), S("user_message")},
                                                                                                          {S("ordinal"), 1},
                                                                                                          {S("status"), S("completed")},
                                                                                                          {S("text"), S("Hello from ") + environment},
                                                                                                          {S("updatedAt"), iso(start())}});
  world.sync();
}

// Opens the member's thread and waits for what it holds.
void followMember(World& world, const QString& environment) {
  look(world, environment + S(":thread-") + environment);
  world.waitFor([&] { return rowOf(timeline(world), S("Hello from ") + environment) >= 0; },
                [&] { return S("the thread of %1 to arrive; %2").arg(environment, describe(timeline(world))); });
}

cache::Thread keptCopy(World& world, const QString& key) {
  cache::Thread copy;
  LocalCache* kept = world.native().cache();
  kept->loadThread(key, kept, [&copy](const cache::Thread& thread) { copy = thread; });
  kept->drain();
  return copy;
}

const Steps steps([] {
  const QString q = kQuoted;

  // Retrying.
  step(S("the environment stops answering"), [](World& world, const Captures&, const Table&) {
    seen(world).retries = watch(world).retryDelays.size();
    seen(world).connections = world.mc.connections.size();
    // The shape of the real delays, a hundredth of their length.
    client(world).setRetryDelays({5, 10, 20, 40, 80});
    world.mc.stopAccepting();
  });
  step(S("the client retries with delays that grow up to a cap"), [](World& world, const Captures&, const Table&) {
    const QList<int> expected{5, 10, 20, 40, 80, 80, 80};
    const ConnectionWatch& watched = watch(world);
    const qsizetype from = seen(world).retries;
    world.waitFor([&] { return watched.retryDelays.size() >= from + expected.size(); },
                  [&] { return S("%1 retries; the connection is %2").arg(expected.size()).arg(show(connection(world))); });
    expect(watched.retryDelays.mid(from, expected.size()) == expected, S("the delays were %1").arg(show(QVariant::fromValue(watched.retryDelays))));
    // And the delays the phone starts with grow the same way.
    const QList<int> real = McClient().retryDelays();
    expect(real.size() > 2 && std::is_sorted(real.cbegin(), real.cend()) && real.first() < real.last(),
           S("the default delays are %1").arg(show(QVariant::fromValue(real))));
  });
  step(S("reconnects when the environment answers again"), [](World& world, const Captures&, const Table&) {
    world.mc.startAccepting();
    waitForReconnect(world, seen(world).connections + 1);
  });

  // No network.
  step(S("the device has no network"), [](World& world, const Captures&, const Table&) {
    seen(world).connections = world.mc.connections.size();
    client(world).setOnline(false);
  });
  step(S("the client waits for the network to return before trying again"), [](World& world, const Captures&, const Table&) {
    waitForPhase(world, {S("offline")});
    // The environment would answer; nothing is asked of it while offline.
    QCoreApplication::processEvents();
    expect(client(world).phase() == McClient::Phase::Offline && world.mc.connections.size() == seen(world).connections,
           S("the phone tried again: %1 connections, %2").arg(world.mc.connections.size()).arg(show(connection(world))));
    noticeSays(world, S("This device is offline"));
    client(world).setOnline(true);
    waitForReconnect(world, seen(world).connections + 1);
  });

  // The device's network as the system reports it, for an MC that needs one.
  step(S("the environment is on another machine"), [](World& world, const Captures&, const Table&) {
    const qsizetype connections = world.mc.connections.size();
    openAt(world, remoteOrigin(world));
    waitForReconnect(world, connections + 1);
  });
  step(S("the device loses one of its two networks"), [](World& world, const Captures&, const Table&) {
    // As Android has it: disconnected, says the system, with a network
    // still up.
    setNetwork(world, true, true);
  });
  step(S("the device loses every network"), [](World& world, const Captures&, const Table&) { setNetwork(world, true, false); });
  step(S("the client is waiting for the network"), [](World& world, const Captures&, const Table&) {
    setNetwork(world, true, false);
    world.mc.drop();
    waitForPhase(world, {S("offline")});
  });
  step(S("a network comes back"), [](World& world, const Captures&, const Table&) {
    watch(world).connectionsBefore = world.mc.connections.size();
    setNetwork(world, false, true);
  });
  step(S("the user pairs the client with an environment on this machine"), [](World& world, const Captures&, const Table&) {
    watch(world).connectionsBefore = world.mc.connections.size();
    openAt(world, world.mc.origin());
  });
  step(S("the client is opened at an environment on another machine"), [](World& world, const Captures&, const Table&) {
    // Which a device with no network does not reach.
    world.mc.stopAccepting();
    openAt(world, remoteOrigin(world));
  });
  step(S("does not say the device is offline"), [](World& world, const Captures&, const Table&) {
    expect(phase(world) == QLatin1String("reconnecting") && !noticeSays(world, S("This device is offline")),
           S("the connection is %1; the screen says: %2").arg(show(connection(world)), world.texts().join(S(" | "))));
  });
  step(S("the client waits for the network"), [](World& world, const Captures&, const Table&) {
    waitForPhase(world, {S("offline")});
    // Nothing is asked of the environment while the device has no network.
    const qsizetype connections = world.mc.connections.size();
    QCoreApplication::processEvents();
    expect(client(world).phase() == McClient::Phase::Offline && world.mc.connections.size() == connections,
           S("the phone tried again: %1 connections, %2").arg(world.mc.connections.size()).arg(show(connection(world))));
  });
  step(S("says the device is offline"), [](World& world, const Captures&, const Table&) {
    expect(connection(world).value(S("status")) == QLatin1String("Offline") && noticeSays(world, S("This device is offline")),
           S("the connection is %1; the screen says: %2").arg(show(connection(world)), world.texts().join(S(" | "))));
  });

  // A refused credential: the phone's notice offers to pair again.
  step(S("asks the user to pair again"), [](World& world, const Captures&, const Table&) {
    expect(connection(world).value(S("needsPairing")).toBool(), S("the connection is %1").arg(show(connection(world))));
    expect(noticeSays(world, S("Pair again with a fresh pairing link from the environment.")) && world.find(S("connectionPair")) != nullptr &&
               world.find(S("connectionPairingLink")) != nullptr,
           S("the phone does not ask for a pairing link; the screen says: %1").arg(world.texts().join(S(" | "))));
  });

  // Coming to the foreground.
  step(S("the client is waiting to retry"), [](World& world, const Captures&, const Table&) {
    goDown(world, {600000});
    world.mc.startAccepting();
    watch(world).connectionsBefore = world.mc.connections.size();
  });
  step(S("it (?:tries again|connects) at once"), [](World& world, const Captures&, const Table&) {
    // Ten minutes were left on the retry, or no network to wait for.
    waitForReconnect(world, watch(world).connectionsBefore + 1);
  });
  step(S("the client checks the connection"), [](World& world, const Captures&, const Table&) {
    const ConnectionWatch& watched = watch(world);
    world.waitFor([&] { return !watched.checks.isEmpty(); }, S("the connection to be checked"));
    expect(watched.checks.last(), S("the check found the connection dead"));
  });
  step(S("keeps it when it answers"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(world.mc.connections.size() == watch(world).connectionsBefore && phase(world) == QLatin1String("connected"),
           S("the connection was replaced: %1 connections, %2").arg(world.mc.connections.size()).arg(show(connection(world))));
  });

  // What the phone says of its connection.
  step(S("the socket opens"), [](World& world, const Captures&, const Table&) {
    world.mc.holdSnapshot = true;
    client(world).reconnect();
    world.waitFor([&] { return client(world).isReady(); }, S("the socket to open"));
  });
  step(S("the client reports connecting until the environment's configuration "
         "arrives"),
       [](World& world, const Captures&, const Table&) {
         world.sync();
         expect(phase(world) == QLatin1String("connecting") && connection(world).value(S("status")) == QLatin1String("Connecting"),
                S("before the environment described itself the connection is %1").arg(show(connection(world))));
         world.mc.sendSnapshot();
         waitForPhase(world, {S("connected")});
       });
  step(S("its shell subscription fails"), [](World& world, const Captures&, const Table&) {
    seen(world).connections = world.mc.connections.size();
    for (const int id : world.mc.subscribers(S("shell"))) {
      world.mc.send({{S("t"), S("error")}, {S("id"), id}, {S("reason"), S("the shell is unavailable")}});
    }
    world.sync();
  });
  step(S("the client reports the data problem"), [](World& world, const Captures&, const Table&) {
    waitForPhase(world, {S("problem")});
    // The MC's own words stay out of it.
    const QVariantMap said = connection(world);
    expect(said.value(S("status")) == QLatin1String("Can't load data") && !show(said).contains(QLatin1String("the shell is unavailable")) &&
               noticeSays(world, S("Could not load projects and threads")),
           S("the connection is %1; the screen says: %2").arg(show(connection(world)), world.texts().join(S(" | "))));
  });
  step(S("does not claim to be reconnecting"), [](World& world, const Captures&, const Table&) {
    expect(client(world).isReady() && world.mc.connections.size() == seen(world).connections &&
               !connection(world).value(S("status")).toString().contains(QLatin1String("econnecting")) &&
               !connection(world).value(S("title")).toString().contains(QLatin1String("econnecting")) && !world.shows(S("econnecting"), false),
           S("the connection is %1").arg(show(connection(world))));
  });
  step(S("the connection dropped because of a timeout"), [](World& world, const Captures&, const Table&) {
    // The MC's socket stays open and says nothing more; nothing listens
    // for the retry.
    client(world).setRetryDelays({600000});
    client(world).setPongTimeout(20);
    world.mc.answerPings = false;
    world.mc.stopAccepting();
    client(world).wake();
    world.waitFor([&] { return client(world).phase() == McClient::Phase::Retrying; },
                  [&] { return S("the unanswered connection to be dropped; it is %1").arg(show(connection(world))); });
  });
  step(S("the environment reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    // Once the reconnect is past its grace: until then it reads as connected.
    world.waitFor([&] { return !connection(world).value(S("settling")).toBool(); },
                  [&] { return S("the reconnect to be past its grace; the connection is %1").arg(show(connection(world))); });
    expect(connection(world).value(S("status")) == c[0], S("the connection is %1").arg(show(connection(world))));
    // As the notice's word beside its icon.
    QQuickItem* status = world.item(S("connectionNoticeStatus"));
    expect(status->property("text") == c[0], S("the notice reads \"%1\"").arg(status->property("text").toString()));
  });
  step(S("the notice says why: %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(connection(world).value(S("detail")) == c[0] && noticeSays(world, c[0]),
           S("the connection is %1; the screen says: %2").arg(show(connection(world)), world.texts().join(S(" | "))));
  });
  step(S("no surface shows the client's own reason %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap said = connection(world);
    for (const QString& key : {S("status"), S("title"), S("detail")}) {
      expect(!said.value(key).toString().contains(c[0], Qt::CaseInsensitive), S("its %1 says %2").arg(key, show(said)));
    }
    for (const QString& text : world.texts()) {
      expect(!text.contains(c[0], Qt::CaseInsensitive), S("the screen says \"%1\"").arg(text));
    }
  });

  // The icon. What the controller says of each state is the other scenarios';
  // these say it as it would and read the screen.
  step(S("the connection is (connecting|retrying after a drop|waiting for the "
         "network|refused its credential|on another protocol)"),
       [](World& world, const Captures& c, const Table&) {
         static const QHash<QString, QStringList> said{
             {S("connecting"), {S("connecting"), S("connecting"), S("Connecting")}},
             {S("retrying after a drop"), {S("reconnecting"), S("retrying"), S("Reconnecting")}},
             {S("waiting for the network"), {S("offline"), S("offline"), S("Offline")}},
             {S("refused its credential"), {S("refused"), S("needsPairing"), S("Needs pairing")}},
             {S("on another protocol"), {S("blocked"), S("blocked"), S("Update needed")}},
         };
         const QStringList words = said.value(c[0]);
         world.native();  // the app is open
         world.bridge().publish(S("connection"), QVariantMap{{S("phase"), words[0]},
                                                             {S("state"), words[1]},
                                                             {S("status"), words[2]},
                                                             {S("title"), S("About ") + c[0]},
                                                             {S("detail"), S("What to do.")},
                                                             {S("settling"), false},
                                                             {S("traceId"), QString()},
                                                             {S("canRetry"), false},
                                                             {S("needsPairing"), words[1] == QLatin1String("needsPairing")},
                                                             {S("pairing"), false},
                                                             {S("pairingError"), QString()},
                                                             {S("versionWarning"), QVariant::fromValue(nullptr)}});
       });
  step(S("the window shows the (\\S+) icon with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.item(S("connectionNotice"));
    const QString icon = world.item(S("connectionNoticeIcon"))->property("name").toString();
    const QString word = world.item(S("connectionNoticeStatus"))->property("text").toString();
    expect(icon == c[0] && word == c[1], S("the notice shows %1 with \"%2\"").arg(icon, word));
  });
  // A phone has no pointer to hover with: what a tooltip says on the desktop,
  // a tap on the icon opens.
  step(S("hovering it says what is going on"), [](World& world, const Captures&, const Table&) {
    const QString tip = world.item(S("connectionNotice"))->property("tip").toString();
    expect(tip.startsWith(QLatin1String("About ")) && tip.endsWith(QLatin1String("What to do.")), S("the notice's tip is \"%1\"").arg(tip));
    world.openConnectionNotice();
    expect(world.shows(S("What to do.")) && world.shows(tip.section(QLatin1Char('\n'), 0, 0)), S("the panel says: %1").arg(world.texts().join(S(" | "))));
  });

  // A reconnect over before its grace is never shown.
  step(S("the connection drops and comes back at once"), [](World& world, const Captures&, const Table&) {
    client(world).setRetryDelays({20});
    const qsizetype connections = world.mc.connections.size();
    // Every connection published, not only those a poll lands on.
    Seen& watched = seen(world);
    const QMetaObject::Connection watching =
        QObject::connect(&world.bridge(), &ShellBridge::stateEntryChanged, [&watched](const QString& key, const QVariant& value) {
          if (key != QLatin1String("connection")) return;
          const QVariantMap said = value.toMap();
          if (said.value(S("phase")) == QLatin1String("connected")) return;
          watched.sawDown = true;
          if (!said.value(S("settling")).toBool()) watched.shownDown = true;
        });
    world.mc.drop();
    world.waitFor([&] { return world.mc.connections.size() > connections && phase(world) == QLatin1String("connected"); },
                  [&] { return S("the phone to be back; the connection is %1").arg(show(connection(world))); });
    QObject::disconnect(watching);
    expect(watched.sawDown, S("the controller never saw the connection drop"));
  });
  step(S("no surface said the connection was down"), [](World& world, const Captures&, const Table&) {
    expect(!seen(world).shownDown && world.find(S("connectionNotice")) == nullptr, S("the connection was shown down; it is %1").arg(show(connection(world))));
  });

  // What was loaded stays readable.
  step(S("threads were loaded before the connection dropped"), [](World& world, const Captures&, const Table&) {
    followThread(world);
    leaveThread(world);
    goDown(world, {600000});
  });
  step(S("the user opens one offline"), [](World& world, const Captures&, const Table&) { look(world, seen(world).thread, false); });
  step(S("the thread shows its cached content"), [](World& world, const Captures&, const Table&) {
    expect(timeline(world).rowCount() == seen(world).rows && rowOf(timeline(world), kKept) >= 0, S("the thread shows %1").arg(describe(timeline(world))));
    world.waitFor([&] { return world.shows(kKept); }, [&] { return S("the answer on screen; it says: %1").arg(world.texts().join(S(" | "))); });
  });
  step(S("the client does not claim a live connection"), [](World& world, const Captures&, const Table&) {
    expect(timeline(world).status() == QLatin1String("unreachable") && phase(world) == QLatin1String("reconnecting"),
           S("the thread is %1 and the connection %2").arg(timeline(world).status(), show(connection(world))));
  });

  // Removing an environment: the phone's one, forgotten from its settings.
  step(S("a saved environment with cached threads and drafts"), [](World& world, const Captures&, const Table&) {
    followThread(world);
    leaveThread(world);
    auto* drafts = world.native().controller<DraftController>();
    seen(world).draft = drafts->start(world.mc.environmentId, S("shop"));
    drafts->setText(seen(world).draft, S("roll back the deploy"));
    leaveThread(world);
    expect(store(world)->timeline(seen(world).thread) && drafts->draft(seen(world).draft).has_value() && keptCopy(world, seen(world).thread).found(),
           S("nothing was kept for the environment"));
  });
  step(S("the user removes it"), [](World& world, const Captures&, const Table&) {
    world.tap(S("environment"));
    world.item(S("pairingSettings"));
    world.tap(S("environmentForget"));
    world.awaitPopup(S("confirmDialog"));
    world.tap(S("confirmAccept"));
  });
  step(S("its credential, cached data and drafts are cleared"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return pairingPhase(world) == QLatin1String("unpaired"); },
                  [&] { return S("the environment to go; the phone is %1").arg(pairingPhase(world)); });
    // The session the phone kept is its credential.
    expect(!QFile::exists(world.homeDir() + S("/data/pairing.json")), S("the phone still keeps its session"));
    QStringList drafts;
    for (const DraftController::Draft& draft : world.native().controller<DraftController>()->drafts()) drafts.append(draft.text);
    expect(!world.native().store()->thread(seen(world).thread).has_value() && world.native().store()->projectRows(world.mc.environmentId).isEmpty() &&
               !store(world)->timeline(seen(world).thread) && !store(world)->openThreads().contains(seen(world).thread),
           S("its threads are still kept"));
    expect(drafts.isEmpty(), S("its drafts are still kept: %1").arg(drafts.join(S(", "))));
    expect(!keptCopy(world, seen(world).thread).found(), S("the phone still keeps a copy of %1").arg(seen(world).thread));
  });

  // Leaving a thread and coming back.
  step(S("the user left a thread( more than five minutes ago)?"), [](World& world, const Captures& c, const Table&) {
    followThread(world);
    leaveThread(world);
    seen(world).streamSubs = streamSubscriptions(world, seen(world).threadId);
    if (!c.value(0).isEmpty()) {
      seen(world).now = seen(world).now.addSecs(6 * 60);
      world.setTime(seen(world).now);
    }
  });
  step(S("the agent answered %1 meanwhile").arg(q), [](World& world, const Captures& c, const Table&) {
    // The MC has heard that the thread is no longer followed.
    world.sync();
    answer(world, seen(world).threadId, c[0]);
  });
  step(S("the user returns(?: within five minutes)?"), [](World& world, const Captures&, const Table&) {
    if (seen(world).now == start()) world.setTime(start().addSecs(4 * 60));
    look(world, seen(world).thread);
  });
  step(S("the client resumes the thread from where it stopped"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(streamSubscriptions(world, seen(world).threadId) == seen(world).streamSubs && timeline(world).rowCount() == seen(world).rows,
           S("the thread was asked for %1 times; %2").arg(streamSubscriptions(world, seen(world).threadId)).arg(describe(timeline(world))));
    // And it is still followed: what the agent says next arrives.
    expectFollowed(world);
  });
  step(S("the client asks for the thread from where its copy stands"), [](World& world, const Captures&, const Table&) {
    world.sync();
    const FakeStreams& streams = world.mc.part<FakeStreams>();
    expect(!streams.asked.isEmpty(), S("the MC was never asked for the thread"));
    const QJsonObject sub = streams.asked.last().sub;
    expect(streams.asked.last().thread == seen(world).threadId && sub.value(QLatin1String("offset")).isDouble() &&
               sub.value(QLatin1String("handle")) == streams.handle,
           S("it asked with %1").arg(show(sub.toVariantMap())));
  });
  step(S("the thread shows %1 after the conversation it kept").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return rowOf(timeline(world), c[0]) > rowOf(timeline(world), kKept) && rowOf(timeline(world), kKept) >= 0; },
                  [&] { return S("\"%1\" after the answer kept; %2").arg(c[0], describe(timeline(world))); });
    world.waitFor([&] { return world.shows(c[0]); }, [&] { return S("\"%1\" on screen; it says: %2").arg(c[0], world.texts().join(S(" | "))); });
  });

  // A replaced connection.
  step(S("a client subscribed to a thread"), [](World& world, const Captures&, const Table&) { followThread(world); });
  step(S("the connection is replaced"), [](World& world, const Captures&, const Table&) {
    seen(world).streamSubs = streamSubscriptions(world, seen(world).threadId);
    const qsizetype connections = world.mc.connections.size();
    world.mc.drop();
    waitForReconnect(world, connections + 1);
  });
  step(S("the subscription continues on the new connection"), [](World& world, const Captures&, const Table&) {
    const QString thread = seen(world).threadId;
    world.waitFor(
        [&] {
          return streamSubscriptions(world, thread) == seen(world).streamSubs + 1 && !followers(world, thread).isEmpty() &&
                 timeline(world).status() == QLatin1String("live");
        },
        [&] { return S("the thread to be followed again; %1").arg(describe(timeline(world))); });
    expectFollowed(world);
  });
  step(S("the user sent a command just before the connection dropped"), [](World& world, const Captures&, const Table&) {
    seen(world).connections = world.mc.connections.size();
    world.mc.hold(S("answers"));
    client(world).dispatchCommand(&client(world), world.mc.environmentId, {{S("type"), S("thread.archive")}, {S("threadId"), world.mc.threads.firstKey()}},
                                  [&world](const QJsonValue&, const std::optional<QString>& error) { seen(world).callError = error.value_or(S("answered")); });
    world.waitFor([&] { return world.mc.commands.size() == 1; }, S("the command to reach the MC"));
    world.mc.drop();
    world.waitFor([&] { return !client(world).isReady(); }, S("the phone to see the drop"));
  });
  step(S("the client reconnects"), [](World& world, const Captures&, const Table&) { waitForReconnect(world, seen(world).connections + 1); });
  step(S("the command is not sent again automatically"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(world.mc.commands.size() == 1 && seen(world).callError == QLatin1String("disconnected"),
           S("%1 commands reached the MC; the sender was told \"%2\"").arg(world.mc.commands.size()).arg(seen(world).callError));
  });

  // Protocols and versions.
  step(S("an environment whose MC speaks (a newer|an older) protocol than the "
         "client"),
       [](World& world, const Captures& c, const Table&) { world.environment.protocol = McClient::kProtocol + (c[0] == QLatin1String("a newer") ? 1 : -1); });
  step(S("the client says (update HAL-C2 on this device|update HAL-C2 on that "
         "environment)"),
       [](World& world, const Captures& c, const Table&) {
         const QString detail = connection(world).value(S("detail")).toString();
         expect(detail.contains(c[0], Qt::CaseInsensitive) && noticeSays(world, detail),
                S("the phone says \"%1\"; the screen says: %2").arg(detail, world.texts().join(S(" | "))));
       });
  step(S("this client runs HAL-C2 (\\S+)"), [](World& world, const Captures& c, const Table&) { health(world).setClientVersion(c[0]); });
  step(S("the environment's MC runs HAL-C2 (\\S+)"),
       [](World& world, const Captures& c, const Table&) { world.mc.descriptors[world.mc.environmentId].insert(S("serverVersion"), c[0]); });
  step(S("the connection is used as normal"), [](World& world, const Captures&, const Table&) {
    waitForPhase(world, {S("connected")});
    world.sync();
    expect(client(world).isReady() && connection(world).value(S("title")).toString().isEmpty(), S("the connection is %1").arg(show(connection(world))));
  });
  step(S("the client (warns of a version mismatch|does not warn)"), [](World& world, const Captures& c, const Table&) {
    const QVariant warning = connection(world).value(S("versionWarning"));
    if (c[0] == QLatin1String("does not warn")) {
      expect(warning.isNull() && world.find(S("connectionNotice")) == nullptr, S("the phone warns: %1").arg(show(warning)));
      return;
    }
    const QString text = warning.toMap().value(S("text")).toString();
    const QString server = world.mc.descriptors.value(world.mc.environmentId).value(QLatin1String("serverVersion")).toString();
    expect(text.startsWith(QLatin1String("Version mismatch")) && text.contains(server), S("the warning is %1").arg(show(warning)));
    world.openConnectionNotice();
    expect(world.shows(text), S("the notice says: %1").arg(world.texts().join(S(" | "))));
    // Dismissed, it stays away for this pair of versions.
    world.tap(S("connectionDismissWarning"));
    world.waitFor([&] { return connection(world).value(S("versionWarning")).isNull() && world.find(S("connectionNotice")) == nullptr; },
                  S("the warning to go"));
  });

  // A cluster over one connection.
  step(S("a client connected to a cluster of three MCs"), [](World& world, const Captures&, const Table&) {
    followThread(world);
    seen(world).connections = world.mc.connections.size();
    joinMember(world, S("mc-b"), S("env-b"));
    joinMember(world, S("mc-c"), S("env-c"));
  });
  step(S("the client keeps one connection for the cluster"), [](World& world, const Captures&, const Table&) {
    const QStringList environments = world.native().store()->environments();
    expect(world.mc.connections.size() == seen(world).connections && environments.size() == 3 && client(world).isReady(),
           S("%1 connections for %2").arg(world.mc.connections.size()).arg(environments.join(S(", "))));
  });
  step(S("streams from every MC arrive over it"), [](World& world, const Captures&, const Table&) {
    followMember(world, S("env-b"));
    followMember(world, S("env-c"));
    QSet<QString> followed;
    for (const int id : world.mc.subscribers(S("stream"))) followed.insert(world.mc.shapeOf(id).value(QLatin1String("environment")).toString());
    expect(followed.contains(S("env-b")) && followed.contains(S("env-c")) && world.mc.connections.size() == seen(world).connections,
           S("streams of %1 over %2 connections").arg(QStringList(followed.values()).join(S(", "))).arg(world.mc.connections.size()));
  });
  step(S("a client following threads on two cluster members"), [](World& world, const Captures&, const Table&) {
    followThread(world);
    FakeStreams& streams = world.mc.part<FakeStreams>();
    seen(world).offsets.insert(seen(world).threadId, streams.seq);
    joinMember(world, S("mc-b"), S("env-b"));
    followMember(world, S("env-b"));
    // The member's thread moves on, past where the first one stopped.
    answer(world, S("thread-env-b"), S("Deployed."));
    seen(world).offsets.insert(S("thread-env-b"), streams.seq);
    expect(seen(world).offsets.value(seen(world).threadId) != streams.seq, S("both threads stopped at %1").arg(streams.seq));
  });
  step(S("the cluster connection drops and returns"), [](World& world, const Captures&, const Table&) {
    seen(world).subscriptions = world.mc.subscriptions.size();
    const qsizetype connections = world.mc.connections.size();
    world.mc.drop();
    waitForReconnect(world, connections + 1);
    world.sync();
  });
  step(S("each thread stream resumes from its last offset"), [](World& world, const Captures&, const Table&) {
    QHash<QString, QJsonValue> resumed;
    for (qsizetype i = seen(world).subscriptions; i < world.mc.subscriptions.size(); ++i) {
      const QJsonObject shape = world.mc.subscriptions[i].value(QLatin1String("shape")).toObject();
      if (shape.value(QLatin1String("type")) == QLatin1String("stream")) {
        resumed.insert(shape.value(QLatin1String("stream")).toString(), world.mc.subscriptions[i].value(QLatin1String("offset")));
      }
    }
    const QHash<QString, int>& offsets = seen(world).offsets;
    for (auto it = offsets.cbegin(); it != offsets.cend(); ++it) {
      expect(resumed.value(it.key()).isDouble() && resumed.value(it.key()).toInt() == it.value(),
             S("%1 stopped at %2 and resumed from %3").arg(it.key()).arg(it.value()).arg(show(resumed.value(it.key()).toVariant())));
    }
  });
  step(S("the thread list asks only for the rows changed since"), [](World& world, const Captures&, const Table&) {
    QJsonObject shell;
    for (qsizetype i = seen(world).subscriptions; i < world.mc.subscriptions.size(); ++i) {
      if (world.mc.subscriptions[i].value(QLatin1String("shape")).toObject().value(QLatin1String("type")) == QLatin1String("shell"))
        shell = world.mc.subscriptions[i];
    }
    // It says what it holds of each member, and none of them sends its
    // rows again.
    const QJsonObject have = shell.value(QLatin1String("have")).toObject();
    const QJsonObject answered = world.mc.shellFrames.last();
    int resets = 0;
    for (const QJsonValue& mc : answered.value(QLatin1String("mcs")).toArray()) resets += mc.toObject().value(QLatin1String("reset")).toBool() ? 1 : 0;
    expect(have.contains(world.mc.name) && have.contains(S("mc-b")) && resets == 0 && answered.value(QLatin1String("rows")).toArray().isEmpty(),
           S("the thread list was asked for with %1 and answered with %2").arg(show(shell.toVariantMap()), show(answered.toVariantMap())));
    // What it held is still there.
    expect(world.native().store()->thread(S("env-b:thread-env-b")).has_value() && world.native().store()->thread(seen(world).thread).has_value(),
           S("a thread went missing"));
  });
});

}  // namespace
