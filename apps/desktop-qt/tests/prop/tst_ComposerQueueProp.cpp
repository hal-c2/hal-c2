// The composer's view of a queue the MC holds (ComposerController, the `turn`
// state): the queue is held while any queued run of the open thread is
// (after a restart or a usage limit), and "Resume queue" asks the MC to
// resume it, once at a time per thread and only while it is held. The MC
// holds or releases queues, queues more behind a held one, runs and cancels
// queued messages, answers a resume late or refuses it, and the connection
// drops with an answer outstanding.

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
  bool holding = false;         // the MC holds its answers
  bool refusing = false;
  int failures = 0;  // "Failed to resume the queue." toasts

  bool held(const QString& thread) const { return queued.value(thread).contains(true); }
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
    mc.onShape(QStringLiteral("stream"), [this](int id, const QJsonObject& shape) { sendThread(id, shape); });
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
    native->controller<ToastController>()->setClock([] { return QDateTime(QDate(2026, 9, 23), QTime(10, 0), QTimeZone::UTC); });
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
      if (mc.shapeOf(sub).value(QLatin1String("stream")).toString() != thread) continue;
      mc.send({{QStringLiteral("t"), QStringLiteral("events")}, {QStringLiteral("id"), sub}, {QStringLiteral("offset"), seq},
               {QStringLiteral("events"), QJsonArray{QJsonArray{seq, kind, state.value(QLatin1String("id")), QJsonObject{{QStringLiteral("s"), state}}, at}}}});
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

  void open(const QString& thread) {
    bridge->dispatch(QStringLiteral("thread.open"), QVariantMap{{QStringLiteral("key"), keyOf(thread)}});
  }

  QVariantMap turn() const { return bridge->state()->value(QStringLiteral("turn")).toMap(); }

  int resumes(const QString& thread) const {
    int count = 0;
    for (const QJsonObject& command : mc.commands) {
      if (command.value(QLatin1String("type")) == QLatin1String("queue.resume") && command.value(QLatin1String("threadId")) == thread) ++count;
    }
    return count;
  }

  int failures() const {
    int count = 0;
    for (const QVariant& toast : bridge->state()->value(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList()) {
      if (toast.toMap().value(QStringLiteral("title")) == kFailure) ++count;
    }
    return count;
  }

  // The MC has sent what it was going to, and the app has read it: a round
  // trip on the connection every frame came on.
  void settle(const QString& thread) {
    bool done = false;
    native->client()->call(native.get(), mc.environmentId, QStringLiteral("test.barrier"), QJsonValue::Null,
                           [&done](const QJsonValue&, const std::optional<QString>&) { done = true; });
    RC_ASSERT(prop::until([&] { return done; }));
    RC_ASSERT(prop::until([&] {
      const auto* timeline = native->controller<ThreadStore>()->timeline(keyOf(thread));
      return timeline && timeline->status() == QLatin1String("live");
    }));
  }

  int counter = 0;
};

void verify(const Model& m, Sut& sut) {
  sut.settle(m.open);
  const QVariantMap turn = sut.turn();
  RC_ASSERT(turn.value(QStringLiteral("threadKey")).toString() == keyOf(m.open));
  RC_ASSERT(turn.value(QStringLiteral("queueHeld")).toBool() == m.held(m.open));
  RC_ASSERT(turn.value(QStringLiteral("queueResuming")).toBool() == m.pending.contains(m.open));
  RC_ASSERT(int(turn.value(QStringLiteral("queue")).toList().size()) == m.queued.value(m.open).size());
  for (const QString& thread : kThreads) RC_ASSERT(sut.resumes(thread) == m.resumes.value(thread));
  RC_ASSERT(sut.failures() == m.failures);
}

using Command = rc::state::Command<Model, Sut>;

struct Open : Command {
  QString thread = pick(kThreads);
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
  void checkPreconditions(const Model& m) const override { RC_PRE(m.queued.value(thread).size() < 3); }
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
  void checkPreconditions(const Model& m) const override { RC_PRE(!m.queued.value(thread).isEmpty()); }
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
    RC_PRE(!m.queued.value(thread).isEmpty());
    RC_PRE(cancel || !m.held(thread));
  }
  void apply(Model& m) const override { m.queued[thread].removeFirst(); }
  void run(const Model& m0, Sut& sut) const override {
    sut.leave(thread, cancel ? QStringLiteral("cancelled") : QStringLiteral("running"));
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << (cancel ? "Cancel(" : "Start(") << thread.toStdString() << ")"; }
};

// "Resume queue" on the open thread. It asks the MC only for a queue that is
// held and has no resume outstanding; the MC answers at once, late, or by
// refusing, and a refusal leaves the queue held and says so.
struct Resume : Command {
  void apply(Model& m) const override {
    if (!m.held(m.open) || m.pending.contains(m.open)) return;
    ++m.resumes[m.open];
    if (m.holding) {
      m.pending.insert(m.open, m.refusing);
    } else if (m.refusing) {
      ++m.failures;
    } else {
      m.queued[m.open].fill(false);
    }
  }
  void run(const Model& m0, Sut& sut) const override {
    sut.bridge->dispatch(QStringLiteral("composer.queue.resume"));
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "Resume"; }
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
        ++m.failures;
      } else {
        m.queued[it.key()].fill(false);
      }
    }
    m.pending.clear();
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
  void apply(Model& m) const override {
    m.failures += int(m.pending.size());
    m.pending.clear();
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
                                                                                 Resume, Resume, Resume, Hold, Refuse, AnswerHeld, Drop>()));
      rc::state::runAll(commands, model, sut);
    }));
  }
};

HAL_C2_PROP_MAIN(ComposerQueueProp)
#include "tst_ComposerQueueProp.moc"
