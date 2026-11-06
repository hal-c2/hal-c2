// The client's view of its MC (McClient, ShellStore, LocalCache) against a fake
// MC (tests/native/features/FakeMc) whose rows change, which drops and comes
// back, restarts with a new epoch, takes sockets and never says hello, stops
// answering the foreground check, refuses the client's credential or answers
// as another environment, answers calls, refuses them or holds them, while the
// client reconnects, is opened again (paired anew), restarts from its cache,
// comes to the foreground and subscribes. It holds one socket to the MC at
// most, and does not retry an MC that turned it away.

#include "Prop.h"

#include <QJsonArray>
#include <QTcpSocket>

#include <map>
#include <memory>
#include <set>

#include "FakeMc.h"
#include "LocalCache.h"
#include "McClient.h"
#include "ShellStore.h"

namespace {

QString q(const std::string& text) {
  return QString::fromStdString(text);
}

const std::vector<std::string> kThreads{"t1", "t2", "t3"};
const std::vector<std::string> kProjects{"p1", "p2"};

bool isThread(const std::string& id) {
  return id.starts_with("t");
}

// How a call is answered, and what its caller is owed.
enum class Mode { Answer, Refuse, Hold };
enum class Owed { Nothing, Pending, Result, Refused, Disconnected, NotConnected };

const char* name(Owed owed) {
  switch (owed) {
    case Owed::Nothing: return "nothing";
    case Owed::Pending: return "pending";
    case Owed::Result: return "result";
    case Owed::Refused: return "error:no";
    case Owed::Disconnected: return "error:disconnected";
    case Owed::NotConnected: return "error:not connected";
  }
  return "?";
}

const char* name(Mode mode) {
  switch (mode) {
    case Mode::Answer: return "answer";
    case Mode::Refuse: return "refuse";
    case Mode::Hold: return "hold";
  }
  return "?";
}

// How the MC turns the client away, and the phase that leaves it in.
enum class Refusal { None, Invalid, Scope, Request, Missing, Elsewhere };

const char* name(Refusal refusal) {
  switch (refusal) {
    case Refusal::None: return "none";
    case Refusal::Invalid: return "credential invalid";
    case Refusal::Scope: return "scope missing";
    case Refusal::Request: return "request rejected";
    case Refusal::Missing: return "no endpoint";
    case Refusal::Elsewhere: return "another environment";
  }
  return "?";
}

struct Model {
  // The MC's rows by id, each its version `n`.
  std::map<std::string, int> rows;
  // What the client last saw of them: shown while the MC is away.
  std::map<std::string, int> known;
  bool up = true;
  // The MC is up but turns the client away; it waits for the foreground.
  Refusal refused = Refusal::None;
  int epoch = 1;
  std::vector<Owed> calls;
  // Each subscription's, live or ended.
  std::vector<bool> subscriptions;
};

void respond(QTcpSocket* socket, int status, const QByteArray& body) {
  socket->readAll();
  socket->write("HTTP/1.1 " + QByteArray::number(status) + " Status\r\nContent-Type: application/json\r\nContent-Length: " +
                QByteArray::number(body.size()) + "\r\nConnection: close\r\n\r\n" + body);
  socket->disconnectFromHost();
}

struct Sut {
  struct CallRecord {
    std::unique_ptr<QObject> context = std::make_unique<QObject>();
    QStringList replies;
  };
  struct SubscriptionRecord {
    std::unique_ptr<QObject> context = std::make_unique<QObject>();
    int id = 0;
    int frames = 0;
    // Frames it had when it ended; none come after.
    int framesAtEnd = -1;
  };

  QTemporaryDir dir;
  FakeMc mc;
  LocalCache cache;
  std::unique_ptr<McClient> client;
  std::unique_ptr<ShellStore> store;
  QObject barrier;
  std::vector<std::shared_ptr<CallRecord>> calls;
  std::vector<std::shared_ptr<SubscriptionRecord>> subscriptions;

  Sut() {
    cache.open(dir.path());
    // The environment the address answers as, read before every socket.
    mc.onRaw(QStringLiteral("/.well-known/hal-c2/environment"), [this](QTcpSocket* socket, const QByteArray&) {
      respond(socket, 200, QJsonDocument(QJsonObject{{QStringLiteral("environmentId"), mc.environmentId}}).toJson(QJsonDocument::Compact));
    });
    mc.onRpc(QStringLiteral("prop.call"), [this](const FakeMc::Rpc& rpc) {
      const QString mode = rpc.payload.value(QLatin1String("mode")).toString();
      if (mode == QLatin1String("refuse")) {
        mc.refuse(rpc, QStringLiteral("no"));
      } else if (mode == QLatin1String("hold")) {
        mc.defer([this, rpc] { mc.reply(rpc, true); });
      } else {
        mc.reply(rpc, true);
      }
    });
    // A held subscription is answered when held answers are, on the connection
    // it came on.
    mc.onShape(QStringLiteral("prop"), [this](int id, const QJsonObject& shape) {
      const QJsonObject frame{{QStringLiteral("t"), QStringLiteral("snapshot")}, {QStringLiteral("id"), id}};
      if (!shape.value(QLatin1String("hold")).toBool()) return mc.send(frame);
      mc.defer([this, frame, connection = mc.connections.size()] {
        if (mc.connections.size() == connection) mc.send(frame);
      });
    });
    start();
    // Every step starts from a client that is connected and answered.
    RC_ASSERT(halc2::prop::until([this] { return client->isReady(); }));
    RC_ASSERT(barrierCall());
  }
  ~Sut() { stop(); }

  // As NativeShell opens its MC: the rows kept first, then the socket.
  void start() {
    client = std::make_unique<McClient>();
    client->setRetryDelays({20});
    // A hushed MC's socket is given up on well within a step.
    client->setSetupTimeout(500);
    client->setProbeTimeout(100);
    store = std::make_unique<ShellStore>(client.get());
    store->setCache(&cache);
    store->open(mc.origin());
    open();
  }
  // As the phone opens what it paired with: the environment named.
  void open() { client->open(mc.origin(), QStringLiteral("token"), QStringLiteral("env-a")); }
  void stop() {
    store.reset();
    client.reset();
  }

  void setRow(const std::string& id, int n) {
    const QJsonObject row{{QStringLiteral("id"), q(id)}, {QStringLiteral("n"), n}};
    (isThread(id) ? mc.threads : mc.projects).insert(q(id), row);
    mc.sendRow(q(id), row, isThread(id) ? QStringLiteral("thread") : QStringLiteral("project"));
  }
  void removeRow(const std::string& id) {
    (isThread(id) ? mc.threads : mc.projects).remove(q(id));
    mc.sendRow(q(id), {{QStringLiteral("id"), q(id)}, {QStringLiteral("deletedAt"), QStringLiteral("2026-10-08T10:00:00Z")}},
               isThread(id) ? QStringLiteral("thread") : QStringLiteral("project"));
  }

  // The MC answers in order: once this comes back, whatever it sent before has
  // been read.
  bool barrierCall() {
    auto answered = std::make_shared<std::optional<std::optional<QString>>>();
    client->call(&barrier, {}, QStringLiteral("test.barrier"), {}, [answered](const QJsonValue&, const std::optional<QString>& error) {
      *answered = error;
    });
    return halc2::prop::until([&] { return answered->has_value(); }) && !answered->value();
  }
};

// What the client shows equals what the MC holds once it is connected, and
// what it last saw while it is not; its cache holds the same; every call gets
// the one reply it is owed; an ended subscription hears nothing more, and the
// MC holds the ones still live.
void expectSame(const Model& model, Sut& sut) {
  const bool connected = model.up && model.refused == Refusal::None;
  if (model.refused != Refusal::None) {
    const McClient::Phase phase = model.refused == Refusal::Invalid ? McClient::Phase::Refused : McClient::Phase::Blocked;
    if (!halc2::prop::until([&] { return sut.client->phase() == phase; })) {
      RC_FAIL("turned away (" + std::string(name(model.refused)) + "), the client is in phase " + std::to_string(int(sut.client->phase())));
    }
    RC_ASSERT(!sut.client->failureMessage().isEmpty());
    // It waits: no attempt of its own.
    const qsizetype attempts = sut.mc.connections.size();
    halc2::prop::settle();
    RC_ASSERT(sut.client->phase() == phase);
    RC_ASSERT(sut.mc.connections.size() == attempts);
  } else if (model.up) {
    RC_ASSERT(halc2::prop::until([&] { return sut.client->isReady(); }));
    RC_ASSERT(sut.barrierCall());
    // The sockets it left close; only the one it is on stays.
    if (!halc2::prop::until([&] { return sut.mc.openSockets() == 1; })) {
      RC_FAIL("the MC holds " + std::to_string(sut.mc.openSockets()) + " sockets of the client's");
    }
    RC_ASSERT(sut.store->synchronized());
    RC_ASSERT(sut.client->phase() == McClient::Phase::Ready);
  } else {
    RC_ASSERT(!sut.client->isReady());
    halc2::prop::settle();
    const McClient::Phase phase = sut.client->phase();
    RC_ASSERT(phase == McClient::Phase::Retrying || phase == McClient::Phase::Connecting);
  }

  const auto& rows = connected ? model.rows : model.known;
  for (const auto& ids : {kThreads, kProjects}) {
    for (const std::string& id : ids) {
      const QJsonObject shown = isThread(id) ? sut.store->threadRow(QStringLiteral("env-a:") + q(id))
                                             : sut.store->projectRow(QStringLiteral("env-a"), q(id));
      const auto expected = rows.find(id);
      if (expected == rows.end()) {
        if (!shown.isEmpty()) RC_FAIL("shows " + id + " the MC " + (connected ? "removed: " : "had not: ") + rc::toString(shown));
      } else if (shown.value(QLatin1String("n")).toInt(-1) != expected->second) {
        RC_FAIL("shows " + id + " as " + rc::toString(shown) + ", the MC's is " + std::to_string(expected->second));
      }
    }
  }

  // The cache keeps the MC's word, at the version the store resumes from.
  sut.store->flush();
  sut.cache.drain();
  const cache::Shell kept = sut.cache.shell();
  std::map<std::string, int> keptRows;
  for (const cache::ShellMc& mc : kept.mcs) {
    RC_ASSERT(mc.mc == QStringLiteral("mc-a"));
    const QJsonArray version{mc.epoch, mc.rev};
    RC_ASSERT(version == sut.store->have().value(mc.mc).toArray());
    for (const cache::ShellRow& row : mc.rows) keptRows[row.id.toStdString()] = row.fields.value(QLatin1String("n")).toInt();
  }
  if (keptRows != rows) RC_FAIL("the cache keeps " + rc::toString(keptRows) + ", the client was told " + rc::toString(rows));

  for (size_t i = 0; i < model.calls.size(); ++i) {
    const Owed owed = model.calls[i];
    const auto& record = *sut.calls[i];
    if (owed != Owed::Nothing && owed != Owed::Pending) {
      RC_ASSERT(halc2::prop::until([&] { return !record.replies.isEmpty(); }));
    }
    const QStringList expected = owed == Owed::Nothing || owed == Owed::Pending ? QStringList() : QStringList{QLatin1String(name(owed))};
    if (record.replies != expected) {
      RC_FAIL("call " + std::to_string(i) + " was owed " + name(owed) + ", got " + rc::toString(record.replies));
    }
  }

  std::set<int> live;
  for (size_t i = 0; i < model.subscriptions.size(); ++i) {
    const auto& record = *sut.subscriptions[i];
    if (model.subscriptions[i]) {
      live.insert(record.id);
    } else if (record.frames != record.framesAtEnd) {
      RC_FAIL("subscription " + std::to_string(i) + " heard " + std::to_string(record.frames - record.framesAtEnd) + " frames after it ended");
    }
  }
  if (connected) {
    const QList<int> held = sut.mc.subscribers(QStringLiteral("prop"));
    RC_ASSERT(std::set<int>(held.begin(), held.end()) == live);
  }
}

// What a client that was or is connected again owes: the replies its socket
// was carrying fail.
void disconnect(Model& model) {
  for (Owed& owed : model.calls) {
    if (owed == Owed::Pending) owed = Owed::Disconnected;
  }
}

void settled(Model& model) {
  if (model.up && model.refused == Refusal::None) model.known = model.rows;
}

using Command = rc::state::Command<Model, Sut>;

// Commands apply to the model and check the client against it.
template <class Self>
struct Step : Command {
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    static_cast<const Self*>(this)->act(model, sut);
    expectSame(next, sut);
  }
};

struct PutRow : Step<PutRow> {
  std::string id = *rc::gen::elementOf(*rc::gen::arbitrary<bool>() ? kThreads : kProjects);
  int n = *rc::gen::inRange(0, 100);

  explicit PutRow(const Model&) {}
  void apply(Model& model) const override {
    model.rows[id] = n;
    settled(model);
  }
  void act(const Model&, Sut& sut) const { sut.setRow(id, n); }
  void show(std::ostream& os) const override { os << "PutRow(" << id << "=" << n << ")"; }
};

struct RemoveRow : Step<RemoveRow> {
  std::string id = *rc::gen::elementOf(*rc::gen::arbitrary<bool>() ? kThreads : kProjects);

  explicit RemoveRow(const Model&) {}
  void apply(Model& model) const override {
    model.rows.erase(id);
    settled(model);
  }
  void act(const Model&, Sut& sut) const { sut.removeRow(id); }
  void show(std::ostream& os) const override { os << "RemoveRow(" << id << ")"; }
};

// The MC drops the client; it stays down, or comes straight back, a new run
// of it (another epoch) or the same.
struct DropMc : Step<DropMc> {
  bool down = *rc::gen::arbitrary<bool>();
  bool restart = *rc::gen::arbitrary<bool>();

  explicit DropMc(const Model&) {}
  void checkPreconditions(const Model& model) const override { RC_PRE(model.up && model.refused == Refusal::None); }
  void apply(Model& model) const override {
    disconnect(model);
    model.up = !down;
    if (restart) ++model.epoch;
    settled(model);
  }
  void act(const Model& model, Sut& sut) const {
    QSignalSpy ready(sut.client.get(), &McClient::readyChanged);
    if (down) sut.mc.stopAccepting();
    if (restart) sut.mc.epoch = QStringLiteral("epoch-%1").arg(model.epoch + 1);
    sut.mc.drop();
    RC_ASSERT(halc2::prop::until([&] { return !ready.isEmpty(); }));
    RC_ASSERT(!ready.first().first().toBool());
  }
  void show(std::ostream& os) const override { os << "DropMc(" << (down ? "down" : "back") << (restart ? ", new epoch" : "") << ")"; }
};

// The MC drops the client and takes its next sockets without a word, as one
// stuck before its hello: the client gives up on each and tries again.
struct Hush : Step<Hush> {
  explicit Hush(const Model&) {}
  void checkPreconditions(const Model& model) const override { RC_PRE(model.up && model.refused == Refusal::None); }
  void apply(Model& model) const override {
    disconnect(model);
    model.up = false;
    settled(model);
  }
  void act(const Model&, Sut& sut) const {
    QSignalSpy ready(sut.client.get(), &McClient::readyChanged);
    sut.mc.sayHello = false;
    sut.mc.drop();
    RC_ASSERT(halc2::prop::until([&] { return !ready.isEmpty(); }));
    // It reaches the MC again, which says nothing.
    const qsizetype before = sut.mc.connections.size();
    RC_ASSERT(halc2::prop::until([&] { return sut.mc.connections.size() > before; }));
  }
  void show(std::ostream& os) const override { os << "Hush"; }
};

struct ComeBack : Step<ComeBack> {
  explicit ComeBack(const Model&) {}
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.up); }
  void apply(Model& model) const override {
    model.up = true;
    settled(model);
  }
  void act(const Model&, Sut& sut) const {
    sut.mc.sayHello = true;
    sut.mc.startAccepting();
  }
  void show(std::ostream& os) const override { os << "ComeBack"; }
};

struct Reconnect : Step<Reconnect> {
  explicit Reconnect(const Model&) {}
  void apply(Model& model) const override { disconnect(model); }
  void act(const Model&, Sut& sut) const { sut.client->reconnect(); }
  void show(std::ostream& os) const override { os << "Reconnect"; }
};

// Opened again without being closed, as pairing anew does.
struct Reopen : Step<Reopen> {
  explicit Reopen(const Model&) {}
  void apply(Model& model) const override { disconnect(model); }
  void act(const Model&, Sut& sut) const { sut.open(); }
  void show(std::ostream& os) const override { os << "Reopen"; }
};

// The app quits and starts again: it shows what it kept until its MC answers.
struct RestartClient : Step<RestartClient> {
  explicit RestartClient(const Model&) {}
  void apply(Model& model) const override {
    // Nobody is left to hear the replies the old client was owed.
    for (Owed& owed : model.calls) {
      if (owed == Owed::Pending) owed = Owed::Nothing;
    }
    model.subscriptions.assign(model.subscriptions.size(), false);
  }
  void act(const Model& model, Sut& sut) const {
    for (size_t i = 0; i < model.subscriptions.size(); ++i) {
      if (model.subscriptions[i]) sut.subscriptions[i]->framesAtEnd = sut.subscriptions[i]->frames;
    }
    sut.stop();
    sut.start();
  }
  void show(std::ostream& os) const override { os << "RestartClient"; }
};

struct Call : Step<Call> {
  Mode mode = *rc::gen::element(Mode::Answer, Mode::Refuse, Mode::Hold);
  // Its caller goes before any reply.
  bool gone = *rc::gen::weightedElement<bool>({{1, true}, {4, false}});

  explicit Call(const Model&) {}
  Owed owed(const Model& model) const {
    if (gone) return Owed::Nothing;
    if (!model.up || model.refused != Refusal::None) return Owed::NotConnected;
    switch (mode) {
      case Mode::Answer: return Owed::Result;
      case Mode::Refuse: return Owed::Refused;
      case Mode::Hold: return Owed::Pending;
    }
    return Owed::Nothing;
  }
  void apply(Model& model) const override { model.calls.push_back(owed(model)); }
  void act(const Model&, Sut& sut) const {
    auto record = std::make_shared<Sut::CallRecord>();
    sut.calls.push_back(record);
    sut.client->call(record->context.get(), {}, QStringLiteral("prop.call"), QJsonObject{{QStringLiteral("mode"), QLatin1String(name(mode))}},
                     [record = record.get()](const QJsonValue&, const std::optional<QString>& error) {
                       record->replies.append(error ? QStringLiteral("error:") + *error : QStringLiteral("result"));
                     });
    if (gone) record->context.reset();
  }
  void show(std::ostream& os) const override { os << "Call(" << name(mode) << (gone ? ", caller gone" : "") << ")"; }
};

// The MC answers what it held: calls on the connection still open, and
// subscriptions.
struct AnswerHeld : Step<AnswerHeld> {
  explicit AnswerHeld(const Model&) {}
  void apply(Model& model) const override {
    for (Owed& owed : model.calls) {
      if (owed == Owed::Pending) owed = Owed::Result;
    }
  }
  void act(const Model&, Sut& sut) const { sut.mc.answerHeld(); }
  void show(std::ostream& os) const override { os << "AnswerHeld"; }
};

struct Subscribe : Step<Subscribe> {
  bool held = *rc::gen::arbitrary<bool>();

  explicit Subscribe(const Model&) {}
  void apply(Model& model) const override { model.subscriptions.push_back(true); }
  void act(const Model&, Sut& sut) const {
    auto record = std::make_shared<Sut::SubscriptionRecord>();
    sut.subscriptions.push_back(record);
    QJsonObject shape{{QStringLiteral("type"), QStringLiteral("prop")}};
    if (held) shape.insert(QStringLiteral("hold"), true);
    record->id = sut.client->subscribe(record->context.get(), shape, [record = record.get()](const QJsonObject& frame) {
      RC_ASSERT(frame.value(QLatin1String("id")).toInt() == record->id);
      ++record->frames;
    });
  }
  void show(std::ostream& os) const override { os << "Subscribe(" << (held ? "held" : "answered") << ")"; }
};

// Ends a live subscription, its answer perhaps still on the way; or its owner
// goes, which ends it too.
struct Unsubscribe : Step<Unsubscribe> {
  int index = -1;
  bool ownerGone = *rc::gen::arbitrary<bool>();

  explicit Unsubscribe(const Model& model) {
    std::vector<int> live;
    for (size_t i = 0; i < model.subscriptions.size(); ++i) {
      if (model.subscriptions[i]) live.push_back(int(i));
    }
    if (!live.empty()) index = *rc::gen::elementOf(live);
  }
  void checkPreconditions(const Model& model) const override {
    const bool live = index >= 0 && size_t(index) < model.subscriptions.size() && model.subscriptions[size_t(index)];
    RC_PRE(live);
  }
  void apply(Model& model) const override { model.subscriptions[size_t(index)] = false; }
  void act(const Model&, Sut& sut) const {
    auto& record = *sut.subscriptions[size_t(index)];
    record.framesAtEnd = record.frames;
    if (ownerGone) {
      record.context.reset();
    } else {
      sut.client->unsubscribe(record.id);
    }
  }
  void show(std::ostream& os) const override { os << "Unsubscribe(" << index << (ownerGone ? ", owner gone" : "") << ")"; }
};

// The MC turns the client's next attempt away: its credential needs a ticket,
// which is refused, or the address answers as another environment.
struct TurnAway : Step<TurnAway> {
  Refusal refusal = *rc::gen::element(Refusal::Invalid, Refusal::Scope, Refusal::Request, Refusal::Missing, Refusal::Elsewhere);

  explicit TurnAway(const Model&) {}
  void checkPreconditions(const Model& model) const override { RC_PRE(model.up && model.refused == Refusal::None); }
  void apply(Model& model) const override {
    disconnect(model);
    model.refused = refusal;
  }
  void act(const Model&, Sut& sut) const {
    if (refusal == Refusal::Elsewhere) {
      sut.mc.environmentId = QStringLiteral("env-elsewhere");
    } else {
      const int status = refusal == Refusal::Invalid ? 401 : refusal == Refusal::Scope ? 403 : refusal == Refusal::Request ? 400 : 404;
      sut.mc.onRaw(QStringLiteral("/ws?token="), [](QTcpSocket* socket, const QByteArray&) { respond(socket, 401, "{}"); });
      sut.mc.onRaw(QStringLiteral("/api/auth/websocket-ticket"), [status](QTcpSocket* socket, const QByteArray&) { respond(socket, status, "{}"); });
    }
    sut.client->reconnect();
  }
  void show(std::ostream& os) const override { os << "TurnAway(" << name(refusal) << ")"; }
};

// The MC takes the client again, and the app comes to the foreground.
struct TakeBack : Step<TakeBack> {
  explicit TakeBack(const Model&) {}
  void checkPreconditions(const Model& model) const override { RC_PRE(model.refused != Refusal::None); }
  void apply(Model& model) const override {
    model.refused = Refusal::None;
    settled(model);
  }
  void act(const Model&, Sut& sut) const {
    sut.mc.environmentId = QStringLiteral("env-a");
    sut.mc.offRaw(QStringLiteral("/ws?token="));
    sut.mc.offRaw(QStringLiteral("/api/auth/websocket-ticket"));
    sut.client->wake();
  }
  void show(std::ostream& os) const override { os << "TakeBack"; }
};

// The app comes to the foreground: a waiting client tries at once, one turned
// away tries once more, and a connected one checks its socket, which the MC
// answers or, gone silent, does not, and is replaced.
struct Foreground : Step<Foreground> {
  bool silent = *rc::gen::arbitrary<bool>();

  explicit Foreground(const Model&) {}
  bool replaced(const Model& model) const { return silent && model.up && model.refused == Refusal::None; }
  void apply(Model& model) const override {
    if (replaced(model)) disconnect(model);
  }
  void act(const Model& model, Sut& sut) const {
    if (!model.up || model.refused != Refusal::None) return sut.client->wake();
    QSignalSpy checked(sut.client.get(), &McClient::checked);
    const qsizetype before = sut.mc.connections.size();
    sut.mc.answerPings = !silent;
    sut.client->wake();
    RC_ASSERT(halc2::prop::until([&] { return !checked.isEmpty(); }));
    RC_ASSERT(checked.first().first().toBool() == !silent);
    if (silent) RC_ASSERT(halc2::prop::until([&] { return sut.mc.connections.size() > before; }));
    sut.mc.answerPings = true;
    if (!silent) RC_ASSERT(sut.mc.connections.size() == before);
  }
  void show(std::ostream& os) const override { os << "Foreground(" << (silent ? "silent" : "answered") << ")"; }
};

}  // namespace

class SyncClientProp : public QObject {
  Q_OBJECT

private slots:
  void showsWhatTheMcSaid() {
    QVERIFY(rc::check("the client shows and keeps what its MC said, and every call gets the reply it is owed", [] {
      Sut sut;
      rc::state::check(Model{}, sut,
                       rc::state::gen::execOneOfWithArgs<PutRow, PutRow, RemoveRow, DropMc, Hush, ComeBack, ComeBack, Reconnect, Reopen,
                                                         RestartClient, Call, Call, AnswerHeld, Subscribe, Unsubscribe, TurnAway,
                                                         TakeBack, Foreground>());
    }));
  }
};

HAL_C2_PROP_MAIN(SyncClientProp)
#include "tst_SyncClientProp.moc"
