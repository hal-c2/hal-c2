// The threads the shell follows (ThreadStore, each a TimelineModel on the MC's
// `stream` shape) and how it says its connection is doing
// (ConnectionHealthController), wired as NativeShell wires them, against a
// fake MC whose threads change, are deleted and come back, which drops and
// comes back, restarts with a new log, while the user opens and leaves
// threads and the app restarts from its cache.

#include "Prop.h"

#include <QJsonArray>

#include <map>
#include <memory>
#include <set>

#include "ConnectionHealthController.h"
#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "PluginController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ThreadStore.h"
#include "TimelineModel.h"

namespace {

QString q(const std::string& text) {
  return QString::fromStdString(text);
}

const std::vector<std::string> kThreads{"t1", "t2"};
const std::vector<std::string> kPlans{"a", "b"};

QString key(const std::string& thread) {
  return QStringLiteral("env-a:") + q(thread);
}

using Plans = std::map<std::string, int>;

struct Model {
  // The MC's plans of each thread, kept while the thread is deleted.
  std::map<std::string, Plans> plans;
  // The threads the MC lists, and the ones the client lists.
  std::set<std::string> threads{"t1", "t2"};
  std::set<std::string> listed{"t1", "t2"};
  // What the client last saw of each thread it followed, kept in its cache.
  std::map<std::string, Plans> kept;
  // The threads the user has open.
  std::set<std::string> open;
  bool up = true;
  int epoch = 1;
};

// Once the client is connected it lists what the MC lists, holds what the MC
// holds of its open threads, and has let go of the deleted ones.
void settled(Model& model) {
  if (!model.up) return;
  model.listed = model.threads;
  for (auto it = model.open.begin(); it != model.open.end();) {
    if (model.threads.contains(*it)) {
      model.kept[*it] = model.plans[*it];
      ++it;
    } else {
      it = model.open.erase(it);
    }
  }
  std::erase_if(model.kept, [&](const auto& kept) { return !model.threads.contains(kept.first); });
}

struct Sut {
  // The MC's stream of every thread: the plans, and the log of the changes
  // that made them, which a follower's offset counts. Another run of the MC
  // has another handle, so no offset of the last one resumes.
  struct Event {
    int seq = 0;
    QString thread;
    QString id;
    std::optional<int> n;
  };

  QTemporaryDir dir;
  FakeMc mc;
  std::map<std::string, Plans> plans;
  QList<Event> log;
  int seq = 0;
  QString handle = QStringLiteral("log-1");
  std::unique_ptr<ShellBridge> bridge;
  std::unique_ptr<NativeShell> shell;
  // Every `connection` the health published, and the first that lied.
  QStringList said;
  QString lie;
  bool sawReady = false;
  quint64 snapshotsAtReady = 0;
  QObject barrier;

  Sut() {
    mc.projects.insert(QStringLiteral("p1"), {{QStringLiteral("id"), QStringLiteral("p1")}, {QStringLiteral("title"), QStringLiteral("P")}});
    for (const std::string& thread : kThreads) mc.threads.insert(q(thread), row(thread));
    mc.onShape(QStringLiteral("stream"), [this](int id, const QJsonObject& shape) { answer(id, shape); });
    start();
  }
  ~Sut() { stop(); }

  static QJsonObject row(const std::string& thread) {
    return {{QStringLiteral("id"), q(thread)}, {QStringLiteral("title"), q(thread)}, {QStringLiteral("projectId"), QStringLiteral("p1")}};
  }

  // As World::start opens the shell, in a directory of its own.
  void start() {
    bridge = std::make_unique<ShellBridge>();
    shell = std::make_unique<NativeShell>(bridge.get());
    shell->client()->setRetryDelays({20});
    shell->setStoreDirs(dir.filePath(QStringLiteral("state")), dir.filePath(QStringLiteral("data")), dir.filePath(QStringLiteral("cache")));
    shell->controller<SettingsController>()->setDevicePath(dir.filePath(QStringLiteral("config/preferences.json")));
    shell->controller<PluginController>()->setConfigDir(dir.filePath(QStringLiteral("config")));
    sawReady = false;
    // Counted when the phase turns Ready, as the health must: whatever it
    // publishes in that same signal is checked against the count it has then.
    McClient* client = shell->client();
    QObject::connect(client, &McClient::phaseChanged, shell.get(), [this, client] {
      const bool ready = client->phase() == McClient::Phase::Ready;
      if (ready && !sawReady) snapshotsAtReady = shell->store()->snapshots();
      sawReady = ready;
    });
    QObject::connect(bridge.get(), &ShellBridge::stateEntryChanged, shell.get(), [this, client](const QString& key, const QVariant& value) {
      if (key != QLatin1String("connection")) return;
      const QString phase = value.toMap().value(QStringLiteral("phase")).toString();
      said.append(phase);
      if (phase != QLatin1String("connected") || !lie.isEmpty()) return;
      const quint64 snapshots = shell->store()->snapshots();
      const quint64 atReady = client->phase() == McClient::Phase::Ready && !sawReady ? snapshots : snapshotsAtReady;
      if (client->phase() != McClient::Phase::Ready) {
        lie = QStringLiteral("connected while the client is not ready");
      } else if (snapshots <= atReady) {
        lie = QStringLiteral("connected before this connection's snapshot");
      }
    });
    shell->open(mc.origin(), QStringLiteral("token"));
  }
  void stop() {
    shell.reset();
    bridge.reset();
  }

  ThreadStore* threads() const { return shell->controller<ThreadStore>(); }
  QString connection() const { return bridge->state()->value(QStringLiteral("connection")).toMap().value(QStringLiteral("phase")).toString(); }

  static QJsonArray event(const Event& event) {
    const QJsonObject patch = event.n ? QJsonObject{{QStringLiteral("s"), QJsonObject{{QStringLiteral("id"), event.id}, {QStringLiteral("n"), *event.n}}}}
                                      : QJsonObject{{QStringLiteral("d"), true}};
    return {event.seq, QStringLiteral("plan"), event.id, patch, QStringLiteral("2026-10-08T10:00:00Z")};
  }

  // Resumes a follower at its offset when it names this run's log, and
  // sends the thread whole otherwise; then says it is live.
  void answer(int id, const QJsonObject& shape) {
    const QString thread = shape.value(QLatin1String("stream")).toString();
    const QJsonValue offset = shape.value(QLatin1String("offset"));
    const bool resumes = offset.isDouble() && shape.value(QLatin1String("handle")).toString() == handle && offset.toInt() <= seq;
    if (resumes) {
      QJsonArray events;
      for (const Event& change : std::as_const(log)) {
        if (change.thread == thread && change.seq > offset.toInt()) events.append(QJsonValue(event(change)));
      }
      if (!events.isEmpty()) {
        mc.send({{QStringLiteral("t"), QStringLiteral("events")}, {QStringLiteral("id"), id}, {QStringLiteral("offset"), seq}, {QStringLiteral("events"), events}});
      }
    } else {
      QJsonArray rows;
      for (const auto& [plan, n] : plans[thread.toStdString()]) {
        rows.append(QJsonArray{QStringLiteral("plan"), q(plan), QJsonObject{{QStringLiteral("id"), q(plan)}, {QStringLiteral("n"), n}}});
      }
      mc.send({{QStringLiteral("t"), QStringLiteral("snapshot")}, {QStringLiteral("id"), id}, {QStringLiteral("part"), 0},
               {QStringLiteral("rows"), rows}, {QStringLiteral("done"), true}, {QStringLiteral("offset"), seq},
               {QStringLiteral("floor"), QJsonValue::Null}, {QStringLiteral("handle"), handle}});
    }
    mc.send({{QStringLiteral("t"), QStringLiteral("live")}, {QStringLiteral("id"), id}, {QStringLiteral("offset"), seq}, {QStringLiteral("handle"), handle}});
  }

  // A change to a thread's plan, sent to whoever follows the thread.
  void change(const std::string& thread, const std::string& plan, std::optional<int> n) {
    if (n) {
      plans[thread][plan] = *n;
    } else {
      plans[thread].erase(plan);
    }
    log.append({++seq, q(thread), q(plan), n});
    if (!mc.connected()) return;
    for (const int id : mc.subscribers(QStringLiteral("stream"))) {
      if (mc.shapeOf(id).value(QLatin1String("stream")).toString() != q(thread)) continue;
      mc.send({{QStringLiteral("t"), QStringLiteral("events")}, {QStringLiteral("id"), id}, {QStringLiteral("offset"), seq},
               {QStringLiteral("events"), QJsonArray{QJsonValue(event(log.last()))}}});
    }
  }

  // The MC answers in order: once this comes back, whatever it sent before has
  // been read.
  bool barrierCall() {
    auto answered = std::make_shared<bool>(false);
    shell->client()->call(&barrier, {}, QStringLiteral("test.barrier"), {}, [answered](const QJsonValue&, const std::optional<QString>&) {
      *answered = true;
    });
    return halc2::prop::until([&] { return *answered; });
  }
};

Plans shown(const TimelineModel* timeline) {
  Plans plans;
  const QHash<QString, QJsonObject> entities = timeline->entities(QStringLiteral("plan"));
  for (auto it = entities.cbegin(); it != entities.cend(); ++it) plans[it.key().toStdString()] = it->value(QLatin1String("n")).toInt(-1);
  return plans;
}

std::string showStatus(const TimelineModel* timeline) {
  return timeline ? timeline->status().toStdString() + " " + rc::toString(shown(timeline)) : "none";
}

// Connected: every open thread is live and holds what the MC holds, each is
// followed once, a deleted one is let go, and the health says connected.
// Away: the open threads show what was last seen, none passes for live, and
// the health does not say connected. It never said connected early.
void expectSame(const Model& model, Sut& sut) {
  const auto opened = [&] {
    const QStringList open = sut.threads()->openThreads();
    std::set<std::string> keys;
    for (const QString& key : open) keys.insert(key.mid(key.indexOf(QLatin1Char(':')) + 1).toStdString());
    return keys;
  };
  if (model.up) {
    const auto caughtUp = [&] {
      if (sut.connection() != QLatin1String("connected") || opened() != model.open) return false;
      for (const std::string& thread : model.open) {
        const TimelineModel* timeline = sut.threads()->timeline(key(thread));
        const auto plans = model.plans.find(thread);
        if (!timeline || timeline->status() != QLatin1String("live") || shown(timeline) != (plans == model.plans.end() ? Plans() : plans->second)) return false;
      }
      return true;
    };
    halc2::prop::until(caughtUp);
    RC_ASSERT(sut.barrierCall());
    RC_ASSERT(sut.shell->store()->synchronized());
    if (sut.connection() != QLatin1String("connected")) RC_FAIL("the connection is " + sut.connection().toStdString() + " while the MC is up");
    if (opened() != model.open) RC_FAIL("open are " + rc::toString(opened()) + ", expected " + rc::toString(model.open));
    for (const std::string& thread : model.open) {
      const TimelineModel* timeline = sut.threads()->timeline(key(thread));
      const auto plans = model.plans.find(thread);
      const Plans expected = plans == model.plans.end() ? Plans() : plans->second;
      if (!timeline || timeline->status() != QLatin1String("live") || shown(timeline) != expected) {
        RC_FAIL(thread + " shows " + showStatus(timeline) + ", the MC holds " + rc::toString(expected));
      }
    }
    std::multiset<std::string> followed;
    for (const int id : sut.mc.subscribers(QStringLiteral("stream"))) {
      followed.insert(sut.mc.shapeOf(id).value(QLatin1String("stream")).toString().toStdString());
    }
    if (followed != std::multiset<std::string>(model.open.begin(), model.open.end())) {
      RC_FAIL("the MC streams " + rc::toString(followed) + " for the open " + rc::toString(model.open));
    }
  } else {
    RC_ASSERT(!sut.shell->client()->isReady());
    for (const std::string& thread : model.open) {
      const auto kept = model.kept.find(thread);
      const Plans expected = kept == model.kept.end() ? Plans() : kept->second;
      halc2::prop::until([&] {
        const TimelineModel* timeline = sut.threads()->timeline(key(thread));
        return timeline && shown(timeline) == expected;
      });
    }
    halc2::prop::settle();
    if (opened() != model.open) RC_FAIL("open are " + rc::toString(opened()) + ", expected " + rc::toString(model.open));
    for (const std::string& thread : model.open) {
      const TimelineModel* timeline = sut.threads()->timeline(key(thread));
      const auto kept = model.kept.find(thread);
      const Plans expected = kept == model.kept.end() ? Plans() : kept->second;
      if (!timeline || timeline->status() == QLatin1String("live") || shown(timeline) != expected) {
        RC_FAIL(thread + " shows " + showStatus(timeline) + " while the MC is away; it last saw " + rc::toString(expected));
      }
    }
    if (sut.connection() == QLatin1String("connected")) RC_FAIL("connected while the MC is away");
  }
  if (!sut.lie.isEmpty()) RC_FAIL(sut.lie.toStdString() + " after " + rc::toString(sut.said));
}

using Command = rc::state::Command<Model, Sut>;

template <class Self>
struct Step : Command {
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    static_cast<const Self*>(this)->act(model, sut);
    expectSame(next, sut);
  }
};

// The user opens a thread the sidebar lists.
struct Open : Step<Open> {
  std::string thread;

  explicit Open(const Model& model) {
    if (!model.listed.empty()) thread = *rc::gen::elementOf(model.listed);
  }
  void checkPreconditions(const Model& model) const override { RC_PRE(model.listed.contains(thread)); }
  void apply(Model& model) const override {
    model.open.insert(thread);
    settled(model);
  }
  void act(const Model&, Sut& sut) const { sut.threads()->open(key(thread)); }
  void show(std::ostream& os) const override { os << "Open(" << thread << ")"; }
};

// The user leaves a thread for good, or opens one and leaves it before its
// stream has answered.
struct Close : Step<Close> {
  std::string thread = *rc::gen::elementOf(kThreads);
  bool passing = *rc::gen::arbitrary<bool>();

  explicit Close(const Model&) {}
  void checkPreconditions(const Model& model) const override {
    const bool can = passing ? model.listed.contains(thread) && !model.open.contains(thread) : model.open.contains(thread);
    RC_PRE(can);
  }
  void apply(Model& model) const override {
    model.open.erase(thread);
    // Left before its stream or the cache answered, a passing thread was shown
    // nothing and keeps what it kept before.
    settled(model);
  }
  void act(const Model&, Sut& sut) const {
    if (passing) {
      sut.threads()->open(key(thread));
      sut.threads()->open({});
    }
    sut.threads()->close(key(thread));
  }
  void show(std::ostream& os) const override { os << (passing ? "PassThrough(" : "Close(") << thread << ")"; }
};

// A plan of a thread changes, or goes.
struct Change : Step<Change> {
  std::string thread = *rc::gen::elementOf(kThreads);
  std::string plan = *rc::gen::elementOf(kPlans);
  std::optional<int> n = *rc::gen::weightedElement<bool>({{3, true}, {1, false}}) ? std::optional<int>(*rc::gen::inRange(0, 100)) : std::nullopt;

  explicit Change(const Model&) {}
  void apply(Model& model) const override {
    if (n) {
      model.plans[thread][plan] = *n;
    } else {
      model.plans[thread].erase(plan);
    }
    settled(model);
  }
  void act(const Model&, Sut& sut) const { sut.change(thread, plan, n); }
  void show(std::ostream& os) const override { os << "Change(" << thread << "." << plan << "=" << (n ? std::to_string(*n) : "gone") << ")"; }
};

// A thread is deleted, or comes back.
struct Delete : Step<Delete> {
  std::string thread = *rc::gen::elementOf(kThreads);

  explicit Delete(const Model&) {}
  void checkPreconditions(const Model& model) const override { RC_PRE(model.threads.contains(thread)); }
  void apply(Model& model) const override {
    model.threads.erase(thread);
    settled(model);
  }
  void act(const Model&, Sut& sut) const {
    sut.mc.threads.remove(q(thread));
    sut.mc.sendRow(q(thread), {{QStringLiteral("id"), q(thread)}, {QStringLiteral("deletedAt"), QStringLiteral("2026-10-08T10:00:00Z")}});
  }
  void show(std::ostream& os) const override { os << "Delete(" << thread << ")"; }
};

struct Restore : Step<Restore> {
  std::string thread = *rc::gen::elementOf(kThreads);

  explicit Restore(const Model&) {}
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.threads.contains(thread)); }
  void apply(Model& model) const override {
    model.threads.insert(thread);
    settled(model);
  }
  void act(const Model&, Sut& sut) const {
    sut.mc.threads.insert(q(thread), Sut::row(thread));
    sut.mc.sendRow(q(thread), Sut::row(thread));
  }
  void show(std::ostream& os) const override { os << "Restore(" << thread << ")"; }
};

// The MC drops the client; it stays down, or comes straight back, a new run
// of it (another epoch, another log) or the same.
struct DropMc : Step<DropMc> {
  bool down = *rc::gen::arbitrary<bool>();
  bool restart = *rc::gen::arbitrary<bool>();

  explicit DropMc(const Model&) {}
  void checkPreconditions(const Model& model) const override { RC_PRE(model.up); }
  void apply(Model& model) const override {
    model.up = !down;
    if (restart) ++model.epoch;
    settled(model);
  }
  void act(const Model& model, Sut& sut) const {
    QSignalSpy ready(sut.shell->client(), &McClient::readyChanged);
    if (down) sut.mc.stopAccepting();
    if (restart) {
      sut.mc.epoch = QStringLiteral("epoch-%1").arg(model.epoch + 1);
      sut.handle = QStringLiteral("log-%1").arg(model.epoch + 1);
    }
    sut.mc.drop();
    RC_ASSERT(halc2::prop::until([&] { return !ready.isEmpty(); }));
  }
  void show(std::ostream& os) const override { os << "DropMc(" << (down ? "down" : "back") << (restart ? ", restarted" : "") << ")"; }
};

struct ComeBack : Step<ComeBack> {
  explicit ComeBack(const Model&) {}
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.up); }
  void apply(Model& model) const override {
    model.up = true;
    settled(model);
  }
  void act(const Model&, Sut& sut) const { sut.mc.startAccepting(); }
  void show(std::ostream& os) const override { os << "ComeBack"; }
};

struct Reconnect : Step<Reconnect> {
  explicit Reconnect(const Model&) {}
  void apply(Model&) const override {}
  void act(const Model&, Sut& sut) const { sut.shell->client()->reconnect(); }
  void show(std::ostream& os) const override { os << "Reconnect"; }
};

// The app quits and starts again, with no thread open.
struct RestartClient : Step<RestartClient> {
  explicit RestartClient(const Model&) {}
  void apply(Model& model) const override {
    model.open.clear();
    settled(model);
  }
  void act(const Model&, Sut& sut) const {
    sut.stop();
    sut.start();
  }
  void show(std::ostream& os) const override { os << "RestartClient"; }
};

}  // namespace

class SyncThreadProp : public QObject {
  Q_OBJECT

private slots:
  void followsWhatTheMcSaid() {
    QVERIFY(rc::check("open threads hold what the MC holds, and the connection says how it is", [] {
      Sut sut;
      expectSame(Model{}, sut);
      // A shell takes a while to start, the client's restarts included: shorter
      // runs, and rarer restarts, keep a case quick.
      const auto commands = *rc::gen::scale(
          0.5, rc::state::gen::commands(Model{}, rc::state::gen::execOneOfWithArgs<
                                                     Open, Open, Open, Close, Close, Change, Change, Change, Change, Change, Delete,
                                                     Restore, DropMc, ComeBack, ComeBack, Reconnect, RestartClient>()));
      rc::state::runAll(commands, Model{}, sut);
    }));
  }
};

HAL_C2_PROP_MAIN(SyncThreadProp)
#include "tst_SyncThreadProp.moc"
