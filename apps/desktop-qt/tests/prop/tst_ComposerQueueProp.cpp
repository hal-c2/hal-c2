// The composer's view of a queue the MC holds (ComposerController, the `turn`
// state): the queue is held while any queued run of the open thread is
// (after a restart or a usage limit), and "Resume queue" asks the MC to
// resume it, once at a time per thread (across windows) and only while it is
// held and the thread's stream is current. The MC holds or releases queues,
// queues more behind a held one, runs and cancels queued messages, answers a
// resume late or refuses it, and the connection drops with an answer
// outstanding, or comes back before the streams are caught up. A second window
// shows the same thread, and may close with its request outstanding; a refusal
// shows in the window that asked, else in the main one.

#include "ComposerController.h"
#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "Prop.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ThreadStore.h"
#include "TimelineModel.h"
#include "ToastController.h"

namespace prop = halc2::prop;

namespace {

const QStringList kThreads{QStringLiteral("t1"), QStringLiteral("t2")};
QDateTime fixedClock() { return QDateTime(QDate(2026, 9, 23), QTime(10, 0), QTimeZone::UTC); }

const QString kFailure = QStringLiteral("Failed to resume the queue.");

QString pick(const QStringList& pool) { return *rc::gen::elementOf(std::vector<QString>(pool.cbegin(), pool.cend())); }

QString keyOf(const QString& thread) { return QStringLiteral("env-a:") + thread; }

// What the MC keeps for each thread: the queued runs, each held or not.
struct Model {
  QString open = QStringLiteral("t1");
  QMap<QString, QList<bool>> queued;
  // Resumes sent to the MC, by thread, and the threads whose answer is outstanding.
  QMap<QString, int> resumes;
  QMap<QString, bool> pending;  // thread -> whether the MC will refuse it
  QMap<QString, bool> askedInSecond;  // thread -> whether the second window asked for the outstanding resume
  bool holding = false;         // the MC holds its answers
  bool refusing = false;
  // "Failed to resume the queue." toasts: a failure shows in the window that
  // asked, or in the main one once the asker has closed.
  int failures = 0;
  int secondFailures = 0;
  bool secondOpen = true;
  // Reconnected, but the MC has not caught the thread streams up: what the
  // windows show may be out of date.
  bool stale = false;

  bool held(const QString& thread) const { return queued.value(thread).contains(true); }
  void fail(bool inSecond) { ++(inSecond && secondOpen ? secondFailures : failures); }
  // The connection dropped: every outstanding resume failed.
  void failPending() {
    for (auto it = askedInSecond.cbegin(); it != askedInSecond.cend(); ++it) fail(it.value());
    pending.clear();
    askedInSecond.clear();
  }
};

struct Sut {
  QTemporaryDir home{QDir::tempPath() + QStringLiteral("/composer-queue-XXXXXX")};
  FakeMc mc;
  std::unique_ptr<ShellBridge> bridge;
  std::unique_ptr<NativeShell> native;
  // Each thread's queued runs and their messages, as its stream holds them.
  QMap<QString, QList<QJsonObject>> runs;
  QMap<QString, QList<QJsonObject>> messages;
  int seq = 0;
  // A second window on the same MC, until it is closed.
  QPointer<NativeWindow> second;
  // After a reconnect the MC has taken the thread streams' subscriptions but
  // not answered them: the subscriptions it is yet to answer.
  bool streamsHeld = false;
  QSet<int> awaiting;

  Sut() {
    mc.projects.insert(QStringLiteral("p1"), QJsonObject{
                                                 {QStringLiteral("id"), QStringLiteral("p1")},
                                                 {QStringLiteral("title"), QStringLiteral("Shop")},
                                                 {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")},
                                                 {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                 {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                 {QStringLiteral("scripts"), QJsonArray()},
                                             });
    for (const QString& id : kThreads) {
      mc.threads.insert(id, QJsonObject{{QStringLiteral("id"), id},
                                        {QStringLiteral("projectId"), QStringLiteral("p1")},
                                        {QStringLiteral("title"), id},
                                        {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                                        {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}});
    }
    mc.onShape(QStringLiteral("stream"), [this](int id, const QJsonObject& shape) {
      if (streamsHeld) {
        awaiting.insert(id);
      } else {
        sendThread(id, shape);
      }
    });
    // The MC resumes a thread's queue: its queued runs are no longer held.
    mc.effects.append([this](const QJsonObject& command) {
      if (command.value(QLatin1String("type")) != QLatin1String("queue.resume")) return;
      const QString thread = command.value(QLatin1String("threadId")).toString();
      for (QJsonObject& run : runs[thread]) {
        if (run.value(QLatin1String("status")) != QLatin1String("queued")) continue;
        run.insert(QStringLiteral("queueHeld"), false);
        publish(thread, QStringLiteral("run"), run);
      }
    });
    start();
    second = native->openWindow();
    second->controller<ToastController>()->setClock(fixedClock);
    open(QStringLiteral("t1"));
    settle(QStringLiteral("t1"));
  }

  ~Sut() {
    native.reset();
    bridge.reset();
  }

  void start() {
    bridge = std::make_unique<ShellBridge>();
    native = std::make_unique<NativeShell>(bridge.get());
    native->client()->setRetryDelays({20});
    native->setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")),
                         home.filePath(QStringLiteral("cache")));
    // Toasts stay until the user closes them.
    native->controller<ToastController>()->setClock(fixedClock);
    native->restoreWindows();
    native->open(mc.origin(), QStringLiteral("mc-token"));
    RC_ASSERT(prop::until([this] { return online(); }));
  }

  bool online() const {
    if (!native->isActive() || !native->client()->isReady() || !mc.connected()) return false;
    return std::all_of(kThreads.cbegin(), kThreads.cend(), [this](const QString& id) {
      return native->store()->threadOnline(keyOf(id));
    });
  }

  // A thread's queue, whole, then as it changes.
  void sendThread(int id, const QJsonObject& shape) {
    const QString thread = shape.value(QLatin1String("stream")).toString();
    QJsonArray rows;
    for (const QJsonObject& message : messages.value(thread)) {
      rows.append(QJsonArray{QStringLiteral("message"), message.value(QLatin1String("id")), message});
    }
    for (const QJsonObject& run : runs.value(thread)) rows.append(QJsonArray{QStringLiteral("run"), run.value(QLatin1String("id")), run});
    mc.send({{QStringLiteral("t"), QStringLiteral("snapshot")}, {QStringLiteral("id"), id}, {QStringLiteral("part"), 0},
             {QStringLiteral("rows"), rows}, {QStringLiteral("done"), true}, {QStringLiteral("offset"), seq},
             {QStringLiteral("floor"), QJsonValue::Null}, {QStringLiteral("handle"), QStringLiteral("log-1")}});
    mc.send({{QStringLiteral("t"), QStringLiteral("live")}, {QStringLiteral("id"), id}, {QStringLiteral("offset"), seq},
             {QStringLiteral("handle"), QStringLiteral("log-1")}});
  }

  void publish(const QString& thread, const QString& kind, const QJsonObject& state) {
    ++seq;
    if (!mc.connected()) return;
    const QString at = QDateTime(QDate(2026, 9, 23), QTime(10, 0), QTimeZone::UTC).addSecs(seq).toString(Qt::ISODateWithMs);
    for (const int sub : mc.subscribers(QStringLiteral("stream"))) {
      if (mc.shapeOf(sub).value(QLatin1String("stream")).toString() != thread || awaiting.contains(sub)) continue;
      // QJsonValue keeps the event nested: Apple clang before 20 reads
      // QJsonArray{QJsonArray{...}} as a copy of the inner array.
      mc.send({{QStringLiteral("t"), QStringLiteral("events")}, {QStringLiteral("id"), sub}, {QStringLiteral("offset"), seq},
               {QStringLiteral("events"),
                QJsonArray{QJsonValue(QJsonArray{seq, kind, state.value(QLatin1String("id")), QJsonObject{{QStringLiteral("s"), state}}, at})}}});
    }
  }

  // A user message queued behind the thread's turn; held when the queue is.
  void enqueue(const QString& thread, bool held) {
    const int n = ++counter;
    const QString message = QStringLiteral("message-%1").arg(n);
    const QString run = QStringLiteral("run-%1").arg(n);
    const QJsonObject text{{QStringLiteral("id"), message}, {QStringLiteral("role"), QStringLiteral("user")},
                           {QStringLiteral("createdBy"), QStringLiteral("user")},
                           {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T10:00:00.000Z")},
                           {QStringLiteral("text"), QStringLiteral("queued %1").arg(n)}};
    const QJsonObject queued{{QStringLiteral("id"), run}, {QStringLiteral("ordinal"), n}, {QStringLiteral("queuePosition"), n},
                             {QStringLiteral("status"), QStringLiteral("queued")}, {QStringLiteral("userMessageId"), message},
                             {QStringLiteral("queueHeld"), held}};
    messages[thread].append(text);
    runs[thread].append(queued);
    publish(thread, QStringLiteral("message"), text);
    publish(thread, QStringLiteral("run"), queued);
  }

  // The first queued run of the thread leaves the queue (it starts, or is cancelled).
  void leave(const QString& thread, const QString& status) {
    for (QJsonObject& run : runs[thread]) {
      if (run.value(QLatin1String("status")) != QLatin1String("queued")) continue;
      run.insert(QStringLiteral("status"), status);
      publish(thread, QStringLiteral("run"), run);
      return;
    }
  }

  // Recovery: every queued run of the thread waits for the user.
  void hold(const QString& thread) {
    for (QJsonObject& run : runs[thread]) {
      if (run.value(QLatin1String("status")) != QLatin1String("queued")) continue;
      run.insert(QStringLiteral("queueHeld"), true);
      publish(thread, QStringLiteral("run"), run);
    }
  }

  // Both windows show the thread.
  void open(const QString& thread) {
    bridge->dispatch(QStringLiteral("thread.open"), QVariantMap{{QStringLiteral("key"), keyOf(thread)}});
    if (second) second->bridge()->dispatch(QStringLiteral("thread.open"), QVariantMap{{QStringLiteral("key"), keyOf(thread)}});
  }

  void closeSecond() {
    native->closeWindow(second->id());
    // Its controllers go with it, with a request it asked outstanding.
    RC_ASSERT(prop::until([this] { return second.isNull(); }));
  }

  // The reconnect, then the MC answering the thread streams it has been asked for.
  void holdStreams() {
    streamsHeld = true;
    awaiting.clear();
  }
  void releaseStreams() {
    streamsHeld = false;
    for (const int id : std::exchange(awaiting, {})) sendThread(id, mc.shapeOf(id));
  }

  QVariantMap turn() const { return bridge->state()->value(QStringLiteral("turn")).toMap(); }
  QVariantMap secondTurn() const { return second->bridge()->state()->value(QStringLiteral("turn")).toMap(); }

  int resumes(const QString& thread) const {
    int count = 0;
    for (const QJsonObject& command : mc.commands) {
      if (command.value(QLatin1String("type")) == QLatin1String("queue.resume") && command.value(QLatin1String("threadId")) == thread) ++count;
    }
    return count;
  }

  static int failures(const ShellBridge* bridge) {
    int count = 0;
    for (const QVariant& toast : bridge->state()->value(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList()) {
      if (toast.toMap().value(QStringLiteral("title")) == kFailure) ++count;
    }
    return count;
  }

  // The MC has sent what it was going to, and the app has read it: a round
  // trip on the connection every frame came on.
  void barrier() {
    bool done = false;
    native->client()->call(native.get(), mc.environmentId, QStringLiteral("test.barrier"), QJsonValue::Null,
                           [&done](const QJsonValue&, const std::optional<QString>&) { done = true; });
    RC_ASSERT(prop::until([&] { return done; }));
  }

  void settle(const QString& thread) {
    barrier();
    RC_ASSERT(prop::until([&] {
      const auto* timeline = native->controller<ThreadStore>()->timeline(keyOf(thread));
      return timeline && timeline->status() == QLatin1String("live");
    }));
  }

  int counter = 0;
};

void verify(const Model& m, Sut& sut) {
  sut.barrier();
  for (const QString& thread : kThreads) RC_ASSERT(sut.resumes(thread) == m.resumes.value(thread));
  RC_ASSERT(Sut::failures(sut.bridge.get()) == m.failures);
  if (m.secondOpen) RC_ASSERT(Sut::failures(sut.second->bridge()) == m.secondFailures);
  // Until the streams catch up the windows show what they last knew.
  if (m.stale) return;
  sut.settle(m.open);
  // The windows agree, and a request one asked shows in the other.
  RC_ASSERT(m.secondOpen == !sut.second.isNull());
  for (const QVariantMap& turn : m.secondOpen ? QList<QVariantMap>{sut.turn(), sut.secondTurn()} : QList<QVariantMap>{sut.turn()}) {
    RC_ASSERT(turn.value(QStringLiteral("threadKey")).toString() == keyOf(m.open));
    RC_ASSERT(turn.value(QStringLiteral("queueHeld")).toBool() == m.held(m.open));
    RC_ASSERT(turn.value(QStringLiteral("queueResuming")).toBool() == m.pending.contains(m.open));
    RC_ASSERT(int(turn.value(QStringLiteral("queue")).toList().size()) == m.queued.value(m.open).size());
  }
}

using Command = rc::state::Command<Model, Sut>;

struct Open : Command {
  QString thread = pick(kThreads);
  void checkPreconditions(const Model& m) const override { RC_PRE(!m.stale); }
  void apply(Model& m) const override { m.open = thread; }
  void run(const Model& m0, Sut& sut) const override {
    sut.open(thread);
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "Open(" << thread.toStdString() << ")"; }
};

// A message queued behind the turn: held when the queue is.
struct Enqueue : Command {
  QString thread = pick(kThreads);
  void checkPreconditions(const Model& m) const override { RC_PRE(!m.stale && m.queued.value(thread).size() < 3); }
  void apply(Model& m) const override { m.queued[thread].append(m.held(thread)); }
  void run(const Model& m0, Sut& sut) const override {
    sut.enqueue(thread, m0.held(thread));
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "Enqueue(" << thread.toStdString() << ")"; }
};

// The MC restarted: what was queued waits for the user.
struct HoldQueue : Command {
  QString thread = pick(kThreads);
  void checkPreconditions(const Model& m) const override { RC_PRE(!m.stale && !m.queued.value(thread).isEmpty()); }
  void apply(Model& m) const override { m.queued[thread].fill(true); }
  void run(const Model& m0, Sut& sut) const override {
    sut.hold(thread);
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "HoldQueue(" << thread.toStdString() << ")"; }
};

// The first queued message starts (a queue that is not held) or is cancelled
// from another device (any queue); a queue with nothing left is not held.
struct Leave : Command {
  QString thread = pick(kThreads);
  bool cancel = *rc::gen::arbitrary<bool>();
  void checkPreconditions(const Model& m) const override {
    RC_PRE(!m.stale && !m.queued.value(thread).isEmpty());
    RC_PRE(cancel || !m.held(thread));
  }
  void apply(Model& m) const override { m.queued[thread].removeFirst(); }
  void run(const Model& m0, Sut& sut) const override {
    sut.leave(thread, cancel ? QStringLiteral("cancelled") : QStringLiteral("running"));
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << (cancel ? "Cancel(" : "Start(") << thread.toStdString() << ")"; }
};

// "Resume queue" on the open thread, in either window. It asks the MC only for
// a queue that is held, has no resume outstanding (in any window) and is
// current; the MC answers at once, late, or by refusing, and a refusal leaves
// the queue held and says so.
struct Resume : Command {
  bool inSecond;
  explicit Resume(const Model& m) : inSecond(m.secondOpen && *rc::gen::arbitrary<bool>()) {}
  void checkPreconditions(const Model& m) const override { RC_PRE(!inSecond || m.secondOpen); }
  void apply(Model& m) const override {
    if (m.stale || !m.held(m.open) || m.pending.contains(m.open)) return;
    ++m.resumes[m.open];
    if (m.holding) {
      m.pending.insert(m.open, m.refusing);
      m.askedInSecond.insert(m.open, inSecond);
    } else if (m.refusing) {
      m.fail(inSecond);
    } else {
      m.queued[m.open].fill(false);
    }
  }
  void run(const Model& m0, Sut& sut) const override {
    (inSecond ? sut.second->bridge() : sut.bridge.get())->dispatch(QStringLiteral("composer.queue.resume"));
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << (inSecond ? "ResumeInSecond" : "Resume"); }
};

// The window that asked closes with its request outstanding: the other
// window still shows it, and the answer still clears it.
struct CloseSecond : Command {
  void checkPreconditions(const Model& m) const override { RC_PRE(m.secondOpen); }
  void apply(Model& m) const override {
    m.secondOpen = false;
    m.secondFailures = 0;
  }
  void run(const Model& m0, Sut& sut) const override {
    sut.closeSecond();
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "CloseSecond"; }
};

// The connection comes back and the MC has not yet caught the thread streams
// up: the held flag the windows show may be one the MC has since cleared, so
// "Resume queue" asks nothing.
struct Reconnect : Command {
  void checkPreconditions(const Model& m) const override { RC_PRE(!m.stale); }
  void apply(Model& m) const override {
    m.failPending();
    m.holding = false;
    m.stale = true;
  }
  void run(const Model& m0, Sut& sut) const override {
    sut.mc.dropHeld();
    sut.holdStreams();
    sut.mc.drop();
    RC_ASSERT(prop::until([&] { return sut.native->client()->isReady() && !sut.awaiting.isEmpty(); }));
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "Reconnect"; }
};

// The MC answers the thread streams; the windows are current again.
struct CatchUp : Command {
  void checkPreconditions(const Model& m) const override { RC_PRE(m.stale); }
  void apply(Model& m) const override { m.stale = false; }
  void run(const Model& m0, Sut& sut) const override {
    sut.releaseStreams();
    RC_ASSERT(prop::until([&] { return sut.online(); }));
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "CatchUp"; }
};

struct Hold : Command {
  void checkPreconditions(const Model& m) const override { RC_PRE(!m.holding); }
  void apply(Model& m) const override { m.holding = true; }
  void run(const Model& m0, Sut& sut) const override {
    sut.mc.hold(QStringLiteral("answers"));
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "Hold"; }
};

struct Refuse : Command {
  bool on = *rc::gen::arbitrary<bool>();
  void apply(Model& m) const override { m.refusing = on; }
  void run(const Model& m0, Sut& sut) const override {
    if (on) {
      sut.mc.refusals.insert(QStringLiteral("queue.resume"), QStringLiteral("The thread is archived."));
    } else {
      sut.mc.refusals.remove(QStringLiteral("queue.resume"));
    }
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "Refuse(" << on << ")"; }
};

// The MC answers the resumes it held, in the order they came.
struct AnswerHeld : Command {
  void checkPreconditions(const Model& m) const override { RC_PRE(m.holding); }
  void apply(Model& m) const override {
    m.holding = false;
    for (auto it = m.pending.cbegin(); it != m.pending.cend(); ++it) {
      if (it.value()) {
        m.fail(m.askedInSecond.value(it.key()));
      } else {
        m.queued[it.key()].fill(false);
      }
    }
    m.pending.clear();
    m.askedInSecond.clear();
  }
  void run(const Model& m0, Sut& sut) const override {
    sut.mc.answerHeld();
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "AnswerHeld"; }
};

// The connection drops with answers outstanding, which never reach the MC's
// queue: the app says the resume failed, and the queue is still held.
struct Drop : Command {
  void checkPreconditions(const Model& m) const override { RC_PRE(!m.stale); }
  void apply(Model& m) const override {
    m.failPending();
    m.holding = false;
  }
  void run(const Model& m0, Sut& sut) const override {
    sut.mc.dropHeld();
    sut.mc.drop();
    RC_ASSERT(prop::until([&] { return !sut.native->client()->isReady(); }));
    RC_ASSERT(prop::until([&] { return sut.online(); }));
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "Drop"; }
};

}  // namespace

class ComposerQueueProp : public QObject {
  Q_OBJECT

private slots:
  void heldQueue() {
    QVERIFY(rc::check("a held queue is resumed once at a time, and only while it is held", [] {
      Sut sut;
      Model model;
      verify(model, sut);
      const auto commands = *rc::gen::scale(
          0.5, rc::state::gen::commands(model, rc::state::gen::execOneOfWithArgs<Open, Enqueue, Enqueue, HoldQueue, HoldQueue, Leave,
                                                                                 Resume, Resume, Resume, Hold, Refuse, AnswerHeld, Drop, CloseSecond,
                                                                                 Reconnect, CatchUp>()));
      rc::state::runAll(commands, model, sut);
    }));
  }
};

HAL_C2_PROP_MAIN(ComposerQueueProp)
#include "tst_ComposerQueueProp.moc"
