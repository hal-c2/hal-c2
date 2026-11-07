// The phone's outbox (ComposerController with setWaitsOffline): a message the
// user sends while the MC cannot be reached waits on the phone, shown in the
// thread's outbox, and goes once the MC is back and has sent its thread list,
// in the order the user sent it, each thread's apart. The MC goes away and comes
// back, drops the connection under a send it took (so the phone sends it again
// with the same message id, which the MC takes once), holds a steer its
// provider has not taken yet under such a drop (answering the repeat "still
// being sent" until it has), and the app is closed and opened again, online
// or not; a restart offline shows the cached thread and takes sends before the
// MC has answered. No message is lost, none reaches the MC twice, none comes
// back to the draft to be sent again, and none is sent while it is away.

#include "ComposerController.h"
#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "Prop.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ToastController.h"

namespace prop = halc2::prop;

namespace {

const QStringList kThreads{QStringLiteral("t1"), QStringLiteral("t2")};
QDateTime fixedClock() { return QDateTime(QDate(2026, 11, 7), QTime(10, 0), QTimeZone::UTC); }

QString pick(const QStringList& pool) { return *rc::gen::elementOf(std::vector<QString>(pool.cbegin(), pool.cend())); }

QString keyOf(const QString& thread) { return QStringLiteral("env-a:") + thread; }

struct Model {
  QString open = QStringLiteral("t1");
  bool up = true;
  // What each thread's MC holds from the user, and what waits on the phone.
  QMap<QString, QStringList> sent;
  QMap<QString, QStringList> waiting;
  int written = 0;
};

struct Sut {
  QTemporaryDir home{QDir::tempPath() + QStringLiteral("/composer-outbox-XXXXXX")};
  FakeMc mc;
  std::unique_ptr<ShellBridge> bridge;
  std::unique_ptr<NativeShell> native;
  // Each thread's user messages, as its stream holds them.
  QMap<QString, QList<QJsonObject>> messages;
  int seq = 0;
  int edit = 0;
  // The next send the MC takes, it takes and then drops the connection under.
  bool dropNext = false;
  // And holds as a steer its provider has not taken: the message is kept
  // but not in the thread yet, and its repeats are still being sent.
  bool pendNext = false;
  std::optional<QJsonObject> pending;

  Sut() {
    mc.projects.insert(QStringLiteral("p1"), QJsonObject{
                                                 {QStringLiteral("id"), QStringLiteral("p1")},
                                                 {QStringLiteral("title"), QStringLiteral("Shop")},
                                                 {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")},
                                                 {QStringLiteral("createdAt"), QStringLiteral("2026-11-01T09:00:00Z")},
                                                 {QStringLiteral("updatedAt"), QStringLiteral("2026-11-01T09:00:00Z")},
                                                 {QStringLiteral("scripts"), QJsonArray()},
                                             });
    for (const QString& id : kThreads) {
      mc.threads.insert(id, QJsonObject{{QStringLiteral("id"), id},
                                        {QStringLiteral("projectId"), QStringLiteral("p1")},
                                        {QStringLiteral("title"), id},
                                        {QStringLiteral("createdAt"), QStringLiteral("2026-11-07T09:00:00Z")},
                                        {QStringLiteral("updatedAt"), QStringLiteral("2026-11-07T09:00:00Z")}});
    }
    const QJsonArray providers{QJsonObject{
        {QStringLiteral("instanceId"), QStringLiteral("claudeAgent")},
        {QStringLiteral("driver"), QStringLiteral("claudeAgent")},
        {QStringLiteral("enabled"), true},
        {QStringLiteral("status"), QStringLiteral("ready")},
        {QStringLiteral("models"), QJsonArray{QJsonObject{{QStringLiteral("slug"), QStringLiteral("claude-sonnet")}}}},
    }};
    mc.onShape(QStringLiteral("config"), [this, providers](int id, const QJsonObject& shape) {
      if (shape.value(QLatin1String("environment")).toString() != mc.environmentId) return;
      mc.send({{QStringLiteral("t"), QStringLiteral("config")},
               {QStringLiteral("id"), id},
               {QStringLiteral("mc"), mc.name},
               {QStringLiteral("config"), QJsonObject{{QStringLiteral("providers"), providers}, {QStringLiteral("settings"), QJsonObject()}}}});
    });
    mc.onShape(QStringLiteral("stream"), [this](int id, const QJsonObject& shape) { sendThread(id, shape); });
    // The MC keeps a message once, by its id, as the real one does.
    mc.effects.append([this](const QJsonObject& command) {
      if (command.value(QLatin1String("type")) != QLatin1String("message.dispatch")) return;
      if (std::exchange(pendNext, false)) {
        pending = command;
        const QString key = QStringLiteral("message.dispatch:") + command.value(QLatin1String("threadId")).toString();
        mc.refusals.insert(key, QStringLiteral("This message is still being sent. Try again."));
        mc.refusalDetails.insert(key, QJsonObject{{QStringLiteral("code"), QStringLiteral("message_still_sending")}});
      } else {
        keep(command);
      }
      if (std::exchange(dropNext, false)) mc.drop();
    });
    start(true);
    open(QStringLiteral("t1"));
  }

  ~Sut() {
    native.reset();
    bridge.reset();
  }

  ComposerController* composer() const { return native->controller<ComposerController>(); }

  // The app opens: with the MC there, once it has its thread list; without,
  // once it shows its cached one.
  void start(bool up) {
    bridge = std::make_unique<ShellBridge>();
    native = std::make_unique<NativeShell>(bridge.get());
    native->client()->setRetryDelays({20});
    native->setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")),
                         home.filePath(QStringLiteral("cache")));
    native->controller<ToastController>()->setClock(fixedClock);
    composer()->setWaitsOffline(true);
    composer()->setOutboxRetryDelays({10});
    native->restoreWindows();
    native->open(mc.origin(), QStringLiteral("mc-token"));
    if (up) {
      RC_ASSERT(prop::until([this] { return online(); }));
    } else {
      RC_ASSERT(prop::until([this] { return native->store()->previewing(); }));
    }
  }

  void restart(bool up) {
    native.reset();
    bridge.reset();
    start(up);
  }

  bool online() const {
    if (!native->isActive() || !native->client()->isReady() || !mc.connected()) return false;
    return std::all_of(kThreads.cbegin(), kThreads.cend(), [this](const QString& id) { return native->store()->threadOnline(keyOf(id)); });
  }

  void sendThread(int id, const QJsonObject& shape) {
    const QString thread = shape.value(QLatin1String("stream")).toString();
    QJsonArray rows;
    for (const QJsonObject& message : messages.value(thread)) {
      rows.append(QJsonArray{QStringLiteral("message"), message.value(QLatin1String("id")), message});
    }
    mc.send({{QStringLiteral("t"), QStringLiteral("snapshot")}, {QStringLiteral("id"), id}, {QStringLiteral("part"), 0},
             {QStringLiteral("rows"), rows}, {QStringLiteral("done"), true}, {QStringLiteral("offset"), seq},
             {QStringLiteral("floor"), QJsonValue::Null}, {QStringLiteral("handle"), QStringLiteral("log-1")}});
    mc.send({{QStringLiteral("t"), QStringLiteral("live")}, {QStringLiteral("id"), id}, {QStringLiteral("offset"), seq},
             {QStringLiteral("handle"), QStringLiteral("log-1")}});
  }

  void publish(const QString& thread, const QJsonObject& message) {
    if (!mc.connected()) return;
    for (const int sub : mc.subscribers(QStringLiteral("stream"))) {
      if (mc.shapeOf(sub).value(QLatin1String("stream")).toString() != thread) continue;
      // QJsonValue keeps the event nested: Apple clang before 20 reads
      // QJsonArray{QJsonArray{...}} as a copy of the inner array.
      mc.send({{QStringLiteral("t"), QStringLiteral("events")}, {QStringLiteral("id"), sub}, {QStringLiteral("offset"), seq},
               {QStringLiteral("events"), QJsonArray{QJsonValue(QJsonArray{seq, QStringLiteral("message"), message.value(QLatin1String("id")),
                                                                           QJsonObject{{QStringLiteral("s"), message}},
                                                                           message.value(QLatin1String("createdAt"))})}}});
    }
  }

  void open(const QString& thread) {
    bridge->dispatch(QStringLiteral("thread.open"), QVariantMap{{QStringLiteral("key"), keyOf(thread)}});
    RC_ASSERT(prop::until([&] {
      return bridge->state()->value(QStringLiteral("composer")).toMap().value(QStringLiteral("target")) == keyOf(thread);
    }));
  }

  void send(const QString& thread, const QString& text) {
    open(thread);
    bridge->dispatch(QStringLiteral("composer.text.set"),
                     QVariantMap{{QStringLiteral("target"), keyOf(thread)},
                                 {QStringLiteral("edit"), QVariantMap{{QStringLiteral("clientId"), QStringLiteral("qml")}, {QStringLiteral("revision"), ++edit}}},
                                 {QStringLiteral("text"), text},
                                 {QStringLiteral("cursor"), text.size()}});
    bridge->dispatch(QStringLiteral("composer.submit"),
                     QVariantMap{{QStringLiteral("edit"), QVariantMap{{QStringLiteral("clientId"), QStringLiteral("qml")}, {QStringLiteral("revision"), ++edit}}},
                                 {QStringLiteral("text"), text},
                                 {QStringLiteral("intent"), QStringLiteral("foreground")}});
  }

  void keep(const QJsonObject& command) {
    const QString thread = command.value(QLatin1String("threadId")).toString();
    const QString id = command.value(QLatin1String("messageId")).toString();
    const bool known = std::any_of(messages[thread].cbegin(), messages[thread].cend(),
                                   [&](const QJsonObject& message) { return message.value(QLatin1String("id")) == id; });
    if (known) return;
    const QJsonObject message{{QStringLiteral("id"), id},
                              {QStringLiteral("role"), QStringLiteral("user")},
                              {QStringLiteral("createdBy"), QStringLiteral("user")},
                              {QStringLiteral("createdAt"), fixedClock().addSecs(++seq).toString(Qt::ISODateWithMs)},
                              {QStringLiteral("text"), command.value(QLatin1String("text"))}};
    messages[thread].append(message);
    publish(thread, message);
  }

  // The pending steer's provider takes it: it joins its thread, and the next
  // repeat hears it was sent.
  void takePending() {
    const QJsonObject command = *std::exchange(pending, std::nullopt);
    mc.refusals.remove(QStringLiteral("message.dispatch:") + command.value(QLatin1String("threadId")).toString());
    keep(command);
  }

  QString draft() const { return bridge->state()->value(QStringLiteral("composer")).toMap().value(QStringLiteral("text")).toString(); }

  // What the MC holds from the user in a thread.
  QStringList sent(const QString& thread) const {
    QStringList texts;
    for (const QJsonObject& message : messages.value(thread)) texts.append(message.value(QLatin1String("text")).toString());
    return texts;
  }

  // The texts the open thread's outbox lists.
  QStringList outbox() const {
    QStringList texts;
    for (const QVariant& entry : bridge->state()->value(QStringLiteral("turn")).toMap().value(QStringLiteral("outbox")).toList()) {
      texts.append(entry.toMap().value(QStringLiteral("text")).toString());
    }
    return texts;
  }

  // Every message the MC was sent, by id: a message is sent again only after
  // a drop under it.
  QStringList dispatched() const {
    QStringList ids;
    for (const QJsonObject& command : mc.commands) {
      if (command.value(QLatin1String("type")) == QLatin1String("message.dispatch")) ids.append(command.value(QLatin1String("messageId")).toString());
    }
    return ids;
  }
};

std::string show(const QStringList& texts) { return ("[" + texts.join(QStringLiteral(", ")) + "]").toStdString(); }

void verify(const Model& m, Sut& sut) {
  if (m.up) RC_ASSERT(prop::until([&] { return sut.online(); }));
  // The outbox goes on its own once the MC is back.
  for (const QString& thread : kThreads) {
    (void)prop::until([&] { return sut.sent(thread) == m.sent.value(thread); });
    RC_LOG() << thread.toStdString() << " sent " << show(sut.sent(thread)) << " expected " << show(m.sent.value(thread)) << std::endl;
    RC_ASSERT(sut.sent(thread) == m.sent.value(thread));
  }
  (void)prop::until([&] { return sut.outbox() == m.waiting.value(m.open); });
  RC_LOG() << "outbox " << show(sut.outbox()) << " expected " << show(m.waiting.value(m.open)) << std::endl;
  RC_ASSERT(sut.outbox() == m.waiting.value(m.open));
  // Nothing the phone sent comes back to be sent again.
  RC_ASSERT(sut.draft().isEmpty());
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

// The user sends a message in a thread: it goes at once while the MC is there
// (behind any that wait, which went when it came back), and waits otherwise.
// `dropped`: the MC takes it, and the connection drops before the answer.
struct Send : Command {
  QString thread = pick(kThreads);
  QString text;
  bool dropped = *rc::gen::arbitrary<bool>();
  explicit Send(const Model& m) : text(QStringLiteral("message %1").arg(m.written + 1)) {}
  void checkPreconditions(const Model& m) const override { RC_PRE(m.up || !dropped); }
  void apply(Model& m) const override {
    ++m.written;
    m.open = thread;
    (m.up ? m.sent : m.waiting)[thread].append(text);
  }
  void run(const Model& m0, Sut& sut) const override {
    const qsizetype connections = sut.mc.connections.size();
    sut.dropNext = dropped;
    sut.send(thread, text);
    // Until it is back the phone cannot know the MC took it, and keeps it.
    if (dropped) RC_ASSERT(prop::until([&] { return sut.mc.connections.size() > connections; }));
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << (dropped ? "SendDropped(" : "Send(") << thread.toStdString() << ", " << text.toStdString() << ")"; }
};

// A steer the MC takes and holds until its provider has it, and the
// connection drops before the answer: the phone asks again, hears "still being
// sent", and keeps it in the outbox, out of the draft, until the MC has it.
struct SendStillSending : Command {
  QString thread = pick(kThreads);
  QString text;
  explicit SendStillSending(const Model& m) : text(QStringLiteral("message %1").arg(m.written + 1)) {}
  void checkPreconditions(const Model& m) const override { RC_PRE(m.up); }
  void apply(Model& m) const override {
    ++m.written;
    m.open = thread;
    m.sent[thread].append(text);
  }
  void run(const Model& m0, Sut& sut) const override {
    const auto attempts = [&] { return qsizetype(sut.dispatched().size()); };
    const qsizetype before = attempts();
    sut.dropNext = true;
    sut.pendNext = true;
    sut.send(thread, text);
    // The first, and two repeats the MC answered "still being sent".
    RC_ASSERT(prop::until([&] { return attempts() >= before + 3; }));
    RC_ASSERT(sut.draft().isEmpty());
    RC_ASSERT(sut.outbox().contains(text));
    sut.takePending();
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "SendStillSending(" << thread.toStdString() << ", " << text.toStdString() << ")"; }
};

struct GoDown : Command {
  void checkPreconditions(const Model& m) const override { RC_PRE(m.up); }
  void apply(Model& m) const override { m.up = false; }
  void run(const Model& m0, Sut& sut) const override {
    sut.mc.stopAccepting();
    sut.mc.drop();
    RC_ASSERT(prop::until([&] { return !sut.native->client()->isReady(); }));
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "GoDown"; }
};

struct ComeBack : Command {
  void checkPreconditions(const Model& m) const override { RC_PRE(!m.up); }
  void apply(Model& m) const override {
    m.up = true;
    for (auto it = m.waiting.cbegin(); it != m.waiting.cend(); ++it) m.sent[it.key()].append(it.value());
    m.waiting.clear();
  }
  void run(const Model& m0, Sut& sut) const override {
    sut.mc.startAccepting();
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "ComeBack"; }
};

// The app is closed and opened again on the thread it showed.
struct Restart : Command {
  void run(const Model& m0, Sut& sut) const override {
    sut.restart(m0.up);
    sut.open(m0.open);
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "Restart"; }
};

}  // namespace

class ComposerOutboxProp : public QObject {
  Q_OBJECT

private slots:
  void outbox() {
    QVERIFY(rc::check("a message sent offline waits, survives a restart, and reaches the MC once and in order", [] {
      Sut sut;
      Model model;
      verify(model, sut);
      const auto commands = *rc::gen::scale(
          0.5, rc::state::gen::commands(model, rc::state::gen::execOneOfWithArgs<Open, Send, Send, Send, SendStillSending, GoDown, ComeBack, Restart>()));
      rc::state::runAll(commands, model, sut);
      // Every message the MC was sent twice was sent again after a drop.
      const QStringList ids = sut.dispatched();
      RC_ASSERT(QSet<QString>(ids.cbegin(), ids.cend()).size() == qsizetype(sut.sent(kThreads[0]).size() + sut.sent(kThreads[1]).size()));
    }));
  }
};

HAL_C2_PROP_MAIN(ComposerOutboxProp)
#include "tst_ComposerOutboxProp.moc"
