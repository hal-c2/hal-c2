// The composer as the user drives it across threads and a new thread's draft,
// against a fake MC that accepts, refuses or holds each send
// (ComposerController, DraftController): typing, images, the model and
// permissions picked, sends and follow-ups while a turn runs, the stash, the
// connection dropping and the app restarting, with sends in flight that the MC
// did or did not get: each reaches the thread once or comes back to its draft,
// unless a newer user message is in the thread by then.

#include <QBuffer>
#include <QImage>

#include "ComposerController.h"
#include "DraftController.h"
#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "Prop.h"
#include "ShellBridge.h"
#include "SettingsController.h"
#include "ShellStore.h"
#include "ThreadStore.h"
#include "TimelineModel.h"
#include "ToastController.h"

namespace prop = halc2::prop;

namespace {

const QStringList kThreads{QStringLiteral("t1"), QStringLiteral("t2"), QStringLiteral("t3")};
// How the model names the new thread's draft.
const QString kDraft = QStringLiteral("draft");
const QStringList kTexts{QString(), QStringLiteral("hello"), QStringLiteral("fix the bug"), QStringLiteral("  ")};
const QStringList kModels{QStringLiteral("gpt-a"), QStringLiteral("gpt-b")};
const QStringList kRuntimeModes{QStringLiteral("approval-required"), QStringLiteral("auto"), QStringLiteral("full-access")};

// rc::gen::elementOf finds begin() by ADL alone, which a QList lacks.
QString pick(const QStringList& pool) { return *rc::gen::elementOf(std::vector<QString>(pool.cbegin(), pool.cend())); }

QString keyOf(const QString& thread) { return QStringLiteral("env-a:") + thread; }

// What a target's composer holds.
struct Target {
  QString text;
  int images = 0;
  QString model;    // picked, else the default
  QString runtime;  // picked, else the thread's
};

// A send on its way: the first of a thread's is at the MC, the rest wait behind it.
struct Send {
  QString prompt;
  int images = 0;
  QString model;
  QString runtime;
  QString delivery;  // auto, steer or queue
  bool refusedAtMc = false;  // what the MC holding it will answer
  bool superseded = false;   // a newer user message reached the thread since
};

// A "Failed to send message" or "A prompt was not sent" toast; what its
// "Restore prompt" gives back.
struct Toast {
  QString thread;
  QString prompt;
  int images = 0;
  bool restore = false;  // whether it offers "Restore prompt"
};

struct Model {
  QString open = QStringLiteral("t1");  // a thread, or kDraft
  QMap<QString, Target> targets;
  QSet<QString> running;
  QMap<QString, QList<Send>> queues;
  // What reached the MC for each thread, as commandOf writes it.
  QMap<QString, QStringList> commands;
  // The threads whose first send the MC holds, in the order it took them.
  QStringList held;
  bool holding = false;
  bool refusing = false;
  // The toasts, newest first; the app drops none.
  QList<Toast> toasts;
  QList<std::pair<QString, int>> stash;  // newest first: text, images
  QString lastModel;  // the model last sent with, a new thread's default
  // The sends a restart cut off that the MC never got, by thread, until the
  // thread is open again.
  QMap<QString, QList<Send>> limbo;

  int total() const {
    int count = 0;
    for (const QStringList& list : commands) count += int(list.size());
    return count;
  }
  bool isThread(const QString& target) const { return kThreads.contains(target); }
  QString selected(const QString& target) const {
    const QString picked = targets.value(target).model;
    if (!picked.isEmpty()) return picked;
    if (target == kDraft && !lastModel.isEmpty()) return lastModel;
    return kModels.first();
  }
};

QStringList commandsOf(const Send& send) {
  QStringList list;
  if (!send.runtime.isEmpty()) list.append(QStringLiteral("runtime|") + send.runtime);
  list.append(QStringList{QStringLiteral("message"), send.prompt.trimmed(), QString::number(send.images),
                          send.model.isEmpty() ? kModels.first() : send.model, send.delivery}
                  .join(u'|'));
  return list;
}

void dispatchFirst(Model& m, const QString& thread);

void accept(Model& m, const QString& thread) {
  QList<Send>& queue = m.queues[thread];
  queue.removeFirst();
  if (queue.isEmpty()) {
    m.queues.remove(thread);
  } else {
    dispatchFirst(m, thread);
  }
}

// The thread's sends stop and come back to its draft: the prompts only into
// an empty one, else the toast that gives them back.
void fail(Model& m, const QString& thread) {
  QStringList prompts;
  int images = 0;
  for (const Send& send : m.queues.take(thread)) {
    if (!send.prompt.isEmpty()) prompts.append(send.prompt);
    images += send.images;
  }
  Target& target = m.targets[thread];
  const QString restored = prompts.join(QStringLiteral("\n\n"));
  if (restored.isEmpty() || target.text.isEmpty()) {
    m.toasts.prepend({thread, QString()});
    if (!restored.isEmpty()) target.text = restored;
  } else {
    m.toasts.prepend({thread, restored, 0, true});
  }
  target.images += images;
}

// The thread is open after a restart: what the MC never got comes back,
// into an empty draft, else behind a toast. A newer user message drops it.
void settleLimbo(Model& m, const QString& thread) {
  QStringList prompts;
  int images = 0;
  bool any = false;
  for (const Send& send : m.limbo.take(thread)) {
    if (send.superseded) continue;
    any = true;
    if (!send.prompt.isEmpty()) prompts.append(send.prompt);
    images += send.images;
  }
  if (!any) return;
  const QString restored = prompts.join(QStringLiteral("\n\n"));
  Target& target = m.targets[thread];
  if (target.text.isEmpty() && target.images == 0) {
    target.text = restored;
    target.images = images;
    return;
  }
  m.toasts.prepend({thread, restored, images, true});
}

void dispatchFirst(Model& m, const QString& thread) {
  Send& send = m.queues[thread].first();
  const QStringList commands = commandsOf(send);
  m.commands[thread].append(commands.first());
  if (m.holding) {
    send.refusedAtMc = m.refusing;
    m.held.append(thread);
  } else if (m.refusing) {
    fail(m, thread);
  } else {
    m.commands[thread].append(commands.mid(1));
    accept(m, thread);
  }
}

// The MC answers what it held; the commands after each go out as it now answers,
// and their answers come back after every held one.
void answerHeld(Model& m) {
  m.holding = false;
  QStringList refused;  // whose next command the MC refuses, in the order they went out
  for (const QString& thread : std::exchange(m.held, {})) {
    const Send send = m.queues[thread].first();
    if (send.refusedAtMc) {
      fail(m, thread);
      continue;
    }
    const QStringList rest = commandsOf(send).mid(1);
    if (!rest.isEmpty() && m.refusing) {
      m.commands[thread].append(rest.first());
      refused.append(thread);
      continue;
    }
    m.commands[thread].append(rest);
    if (m.refusing && m.queues[thread].size() > 1) {
      m.queues[thread].removeFirst();
      m.commands[thread].append(commandsOf(m.queues[thread].first()).first());
      refused.append(thread);
      continue;
    }
    accept(m, thread);
  }
  for (const QString& thread : refused) fail(m, thread);
}

QString png() {
  static const QString encoded = [] {
    QImage picture(4, 4, QImage::Format_RGB32);
    picture.fill(Qt::darkCyan);
    QByteArray bytes;
    QBuffer buffer(&bytes);
    buffer.open(QIODevice::WriteOnly);
    picture.save(&buffer, "PNG");
    return QString::fromLatin1(bytes.toBase64());
  }();
  return encoded;
}

// The app as main.cpp wires it, on a fake MC with one project of three
// threads whose provider offers two models; stores in a home of its own.
struct Sut {
  QTemporaryDir home{QDir::tempPath() + QStringLiteral("/composer-XXXXXX")};
  FakeMc mc;
  std::unique_ptr<ShellBridge> bridge;
  std::unique_ptr<NativeShell> native;
  QString draftId;
  int edit = 0;
  // Each thread's user messages, as its stream sends them, and the stream's offset.
  QMap<QString, QList<QJsonObject>> messages;
  int seq = 0;
  // While set, what the MC answers never reached it: a restart cut it off.
  bool losing = false;
  // Those commands, by their place in mc.commands.
  QSet<qsizetype> lost;

  Sut() {
    mc.projects.insert(QStringLiteral("p1"), QJsonObject{
                                                 {QStringLiteral("id"), QStringLiteral("p1")},
                                                 {QStringLiteral("title"), QStringLiteral("Shop")},
                                                 {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")},
                                                 {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                 {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                 {QStringLiteral("scripts"), QJsonArray()},
                                             });
    for (const QString& id : kThreads) mc.threads.insert(id, row(id, false));
    const QJsonObject provider{
        {QStringLiteral("instanceId"), QStringLiteral("codex")},
        {QStringLiteral("driver"), QStringLiteral("codex")},
        {QStringLiteral("enabled"), true},
        {QStringLiteral("status"), QStringLiteral("ready")},
        {QStringLiteral("models"), QJsonArray{QJsonObject{{QStringLiteral("slug"), kModels.at(0)}},
                                              QJsonObject{{QStringLiteral("slug"), kModels.at(1)}}}},
    };
    mc.onShape(QStringLiteral("config"), [this, provider](int id, const QJsonObject& shape) {
      if (shape.value(QLatin1String("environment")).toString() != mc.environmentId) return;
      mc.send({{QStringLiteral("t"), QStringLiteral("config")},
               {QStringLiteral("id"), id},
               {QStringLiteral("mc"), mc.name},
               {QStringLiteral("config"), QJsonObject{{QStringLiteral("providers"), QJsonArray{provider}},
                                                     {QStringLiteral("settings"), QJsonObject()}}}});
    });
    // The images the MC stores for a message.
    mc.onRpc(QStringLiteral("assets.persistChatAttachments"), [this](const FakeMc::Rpc& rpc) {
      QJsonArray stored;
      for (const QJsonValue& value : rpc.payload.value(QLatin1String("attachments")).toArray()) {
        QJsonObject image = value.toObject();
        image.remove(QStringLiteral("dataUrl"));
        image.insert(QStringLiteral("id"), QStringLiteral("image-%1").arg(rpc.id));
        stored.append(image);
      }
      mc.reply(rpc, QJsonObject{{QStringLiteral("attachments"), stored}});
    });
    // Each thread's messages, whole on every subscription, then as they come.
    mc.onShape(QStringLiteral("stream"), [this](int id, const QJsonObject& shape) {
      QJsonArray rows;
      for (const QJsonObject& message : messages.value(shape.value(QLatin1String("stream")).toString())) {
        rows.append(QJsonArray{QStringLiteral("message"), message.value(QLatin1String("id")), message});
      }
      mc.send({{QStringLiteral("t"), QStringLiteral("snapshot")}, {QStringLiteral("id"), id}, {QStringLiteral("part"), 0},
               {QStringLiteral("rows"), rows}, {QStringLiteral("done"), true}, {QStringLiteral("offset"), seq},
               {QStringLiteral("floor"), QJsonValue::Null}, {QStringLiteral("handle"), QStringLiteral("log-1")}});
      mc.send({{QStringLiteral("t"), QStringLiteral("live")}, {QStringLiteral("id"), id}, {QStringLiteral("offset"), seq},
               {QStringLiteral("handle"), QStringLiteral("log-1")}});
    });
    mc.effects.append([this](const QJsonObject& command) {
      if (losing || command.value(QLatin1String("type")) != QLatin1String("message.dispatch")) return;
      addMessage(command.value(QLatin1String("threadId")).toString(), command.value(QLatin1String("messageId")).toString());
    });
    start();
    draftId = native->controller<DraftController>()->start(mc.environmentId, QStringLiteral("p1"));
    open(QStringLiteral("t1"));
    settle(0);
  }

  ~Sut() {
    native.reset();
    bridge.reset();
  }

  static QJsonObject row(const QString& id, bool running) {
    QJsonObject thread{{QStringLiteral("id"), id},
                       {QStringLiteral("projectId"), QStringLiteral("p1")},
                       {QStringLiteral("title"), id},
                       {QStringLiteral("modelSelection"), QJsonObject{{QStringLiteral("instanceId"), QStringLiteral("codex")},
                                                                     {QStringLiteral("model"), kModels.first()}}},
                       {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                       {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}};
    if (running) {
      thread.insert(QStringLiteral("activeRunId"), QStringLiteral("run-") + id);
      thread.insert(QStringLiteral("latestRunId"), QStringLiteral("run-") + id);
    }
    return thread;
  }

  // As World::start, then connected and every controller started.
  void start() {
    bridge = std::make_unique<ShellBridge>();
    native = std::make_unique<NativeShell>(bridge.get());
    native->client()->setRetryDelays({20});
    native->setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")),
                         home.filePath(QStringLiteral("cache")));
    native->controller<SettingsController>()->setDevicePath(home.filePath(QStringLiteral("config/preferences.json")));
    // Toasts stay until the user closes them.
    native->controller<ToastController>()->setClock([] { return QDateTime(QDate(2026, 9, 23), QTime(10, 0), QTimeZone::UTC); });
    native->restoreWindows();
    native->open(mc.origin(), QStringLiteral("mc-token"));
    RC_ASSERT(prop::until([this] { return online(); }));
  }

  // A user message reaches the thread, and whoever follows it hears.
  void addMessage(const QString& thread, const QString& id) {
    ++seq;
    const QString at = QDateTime(QDate(2026, 9, 23), QTime(10, 0), QTimeZone::UTC).addSecs(seq).toString(Qt::ISODateWithMs);
    const QJsonObject message{{QStringLiteral("id"), id}, {QStringLiteral("role"), QStringLiteral("user")},
                              {QStringLiteral("createdBy"), QStringLiteral("user")}, {QStringLiteral("createdAt"), at}};
    messages[thread].append(message);
    if (!mc.connected()) return;
    for (const int sub : mc.subscribers(QStringLiteral("stream"))) {
      if (mc.shapeOf(sub).value(QLatin1String("stream")).toString() != thread) continue;
      mc.send({{QStringLiteral("t"), QStringLiteral("events")}, {QStringLiteral("id"), sub}, {QStringLiteral("offset"), seq},
               {QStringLiteral("events"), QJsonArray{QJsonArray{seq, QStringLiteral("message"), id,
                                                                QJsonObject{{QStringLiteral("s"), message}}, at}}}});
    }
  }

  // The app quits, with the MC holding the first sends of `held` (each the
  // thread's last command): once it is gone the MC gets them (`received`) or
  // never did.
  void restart(const QStringList& held = {}, bool received = false) {
    native.reset();
    bridge.reset();
    RC_ASSERT(prop::until([this] { return !mc.connected(); }));
    if (!held.isEmpty()) {
      for (const QString& thread : held) {
        for (qsizetype i = mc.commands.size() - 1; i >= 0; --i) {
          if (mc.commands.at(i).value(QLatin1String("threadId")).toString() != thread) continue;
          if (!received) lost.insert(i);
          break;
        }
      }
      losing = !received;
      mc.answerHeld();
      losing = false;
    }
    start();
  }

  // Connected, the threads in and the controllers started.
  bool online() const {
    if (!native->isActive() || !native->client()->isReady() || !mc.connected()) return false;
    return std::all_of(kThreads.cbegin(), kThreads.cend(), [this](const QString& id) {
      return native->store()->threadOnline(keyOf(id));
    });
  }

  ComposerController* composer() const { return native->controller<ComposerController>(); }

  QString keyFor(const QString& target) const { return target == kDraft ? draftId : keyOf(target); }

  void open(const QString& target) {
    if (target == kDraft) {
      bridge->dispatch(QStringLiteral("draft.open"), QVariantMap{{QStringLiteral("draftId"), draftId}});
    } else {
      bridge->dispatch(QStringLiteral("thread.open"), QVariantMap{{QStringLiteral("key"), keyOf(target)}});
    }
  }

  QVariantMap editOf() { return {{QStringLiteral("clientId"), QStringLiteral("qml")}, {QStringLiteral("revision"), ++edit}}; }

  // The composer's commands the MC took for each thread, as commandOf writes them.
  QMap<QString, QStringList> commands() const {
    QMap<QString, QStringList> byThread;
    for (qsizetype i = 0; i < mc.commands.size(); ++i) {
      if (lost.contains(i)) continue;
      const QJsonObject& command = mc.commands.at(i);
      const QString type = command.value(QLatin1String("type")).toString();
      const QString thread = command.value(QLatin1String("threadId")).toString();
      if (type == QLatin1String("thread.runtime-mode.set")) {
        byThread[thread].append(QStringLiteral("runtime|") + command.value(QLatin1String("runtimeMode")).toString());
      } else if (type == QLatin1String("message.dispatch")) {
        const QJsonObject mode = command.value(QLatin1String("dispatchMode")).toObject();
        const QString delivery = mode.value(QLatin1String("type")) == QLatin1String("queue_after_active")
                                     ? QStringLiteral("queue")
                                     : command.value(QLatin1String("deliveryIntent")).toString();
        byThread[thread].append(QStringList{QStringLiteral("message"), command.value(QLatin1String("text")).toString(),
                                            QString::number(command.value(QLatin1String("attachments")).toArray().size()),
                                            command.value(QLatin1String("modelSelection")).toObject().value(QLatin1String("model")).toString(),
                                            delivery}
                                    .join(u'|'));
      }
    }
    return byThread;
  }

  int total() const {
    int count = 0;
    for (const QStringList& list : commands()) count += int(list.size());
    return count;
  }

  // Waits for the MC to have taken `expected` of the composer's commands,
  // then for a round trip, so their answers have landed too.
  void settle(int expected) {
    RC_ASSERT(prop::until([&] { return total() >= expected; }));
    bool done = false;
    native->client()->call(native.get(), mc.environmentId, QStringLiteral("test.barrier"), QJsonValue::Null,
                           [&done](const QJsonValue&, const std::optional<QString>&) { done = true; });
    RC_ASSERT(prop::until([&] { return done; }));
  }

  // The toasts shown, newest first: whether each offers "Restore prompt".
  QList<bool> toasts() const {
    QList<bool> shown;
    for (const QVariant& toast : bridge->state()->value(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList()) {
      const QVariantList actions = toast.toMap().value(QStringLiteral("actions")).toList();
      shown.append(std::any_of(actions.cbegin(), actions.cend(), [](const QVariant& action) {
        return action.toMap().value(QStringLiteral("label")) == QLatin1String("Restore prompt");
      }));
    }
    return shown;
  }
};

// What the app shows agrees with the model.
void verify(const Model& m, Sut& sut) {
  // An open thread's messages are known: what a restart cut off is settled.
  if (m.isThread(m.open)) {
    RC_ASSERT(prop::until([&] {
      const auto* timeline = sut.native->controller<ThreadStore>()->timeline(keyOf(m.open));
      return timeline && timeline->status() == QLatin1String("live");
    }));
  }
  sut.settle(m.total());
  RC_ASSERT(sut.commands() == m.commands);
  auto* composer = sut.composer();
  for (const QString& target : kThreads + QStringList{kDraft}) {
    const Target expected = m.targets.value(target);
    RC_ASSERT(composer->draft(sut.keyFor(target)) == expected.text);
    RC_ASSERT(composer->attachments(sut.keyFor(target)).size() == expected.images);
  }
  const QVariantMap shown = sut.bridge->state()->value(QStringLiteral("composer")).toMap();
  RC_ASSERT(shown.value(QStringLiteral("target")).toString() == sut.keyFor(m.open));
  RC_ASSERT(shown.value(QStringLiteral("text")).toString() == m.targets.value(m.open).text);
  RC_ASSERT(composer->currentSelection().value(QLatin1String("model")).toString() == m.selected(m.open));
  QList<bool> toasts;
  for (const Toast& toast : m.toasts) toasts.append(toast.restore);
  RC_ASSERT(sut.toasts() == toasts);
  const QVariantMap stash = sut.bridge->state()->value(QStringLiteral("composerStash")).toMap();
  RC_ASSERT(stash.value(QStringLiteral("entries")).toList().size() == m.stash.size());
}

using Command = rc::state::Command<Model, Sut>;

struct Open : Command {
  QString target = pick(kThreads + QStringList{kDraft});
  void apply(Model& m) const override {
    m.open = target;
    if (m.isThread(target)) settleLimbo(m, target);
  }
  void run(const Model& m0, Sut& sut) const override {
    sut.open(target);
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "Open(" << target.toStdString() << ")"; }
};

struct Type : Command {
  QString text = pick(kTexts);
  void apply(Model& m) const override { m.targets[m.open].text = text; }
  void run(const Model& m0, Sut& sut) const override {
    sut.bridge->dispatch(QStringLiteral("composer.text.set"), QVariantMap{{QStringLiteral("target"), sut.keyFor(m0.open)},
                                                                         {QStringLiteral("edit"), sut.editOf()},
                                                                         {QStringLiteral("text"), text},
                                                                         {QStringLiteral("cursor"), text.size()}});
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "Type(\"" << text.toStdString() << "\")"; }
};

struct Attach : Command {
  void checkPreconditions(const Model& m) const override { RC_PRE(m.targets.value(m.open).images < 2); }
  void apply(Model& m) const override { ++m.targets[m.open].images; }
  void run(const Model& m0, Sut& sut) const override {
    sut.bridge->dispatch(QStringLiteral("composer.attach"),
                         QVariantMap{{QStringLiteral("files"), QVariantList{QVariantMap{{QStringLiteral("name"), QStringLiteral("shot.png")},
                                                                                        {QStringLiteral("mimeType"), QStringLiteral("image/png")},
                                                                                        {QStringLiteral("base64"), png()}}}}});
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "Attach"; }
};

struct RemoveImage : Command {
  void checkPreconditions(const Model& m) const override { RC_PRE(m.targets.value(m.open).images > 0); }
  void apply(Model& m) const override { --m.targets[m.open].images; }
  void run(const Model& m0, Sut& sut) const override {
    const QVariantList images = sut.composer()->attachments(sut.keyFor(m0.open));
    RC_ASSERT(!images.isEmpty());
    sut.bridge->dispatch(QStringLiteral("composer.attachment.remove"),
                         QVariantMap{{QStringLiteral("id"), images.first().toMap().value(QStringLiteral("id"))}});
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "RemoveImage"; }
};

struct PickModel : Command {
  QString model = pick(kModels);
  void apply(Model& m) const override { m.targets[m.open].model = model; }
  void run(const Model& m0, Sut& sut) const override {
    sut.bridge->dispatch(QStringLiteral("composer.model.select"),
                         QVariantMap{{QStringLiteral("instanceId"), QStringLiteral("codex")}, {QStringLiteral("model"), model}});
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "PickModel(" << model.toStdString() << ")"; }
};

// The thread's permissions; one the thread already has changes nothing.
struct PickRuntime : Command {
  QString mode = pick(kRuntimeModes);
  void checkPreconditions(const Model& m) const override { RC_PRE(m.isThread(m.open)); }
  void apply(Model& m) const override {
    Target& target = m.targets[m.open];
    if (mode != (target.runtime.isEmpty() ? QStringLiteral("full-access") : target.runtime)) target.runtime = mode;
  }
  void run(const Model& m0, Sut& sut) const override {
    sut.bridge->dispatch(QStringLiteral("composer.runtimeMode.set"), QVariantMap{{QStringLiteral("mode"), mode}});
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "PickRuntime(" << mode.toStdString() << ")"; }
};

// A send from a thread's composer: the draft empties as it goes, and a send
// behind one the MC still holds waits its turn.
struct Submit : Command {
  bool alternate = *rc::gen::arbitrary<bool>();
  void checkPreconditions(const Model& m) const override { RC_PRE(m.isThread(m.open)); }
  void apply(Model& m) const override {
    Target& target = m.targets[m.open];
    if (target.text.trimmed().isEmpty() && target.images == 0) return;
    const QString delivery = !m.running.contains(m.open) ? QStringLiteral("auto")
                             : alternate                  ? QStringLiteral("queue")
                                                          : QStringLiteral("steer");
    QList<Send>& queue = m.queues[m.open];
    queue.append({target.text, target.images, target.model, target.runtime, delivery});
    m.lastModel = target.model.isEmpty() ? kModels.first() : target.model;
    // Newer than what a restart cut off.
    m.limbo.remove(m.open);
    target.text.clear();
    target.images = 0;
    if (queue.size() == 1) dispatchFirst(m, m.open);
  }
  void run(const Model& m0, Sut& sut) const override {
    sut.bridge->dispatch(QStringLiteral("composer.submit"),
                         QVariantMap{{QStringLiteral("edit"), sut.editOf()},
                                     {QStringLiteral("text"), m0.targets.value(m0.open).text},
                                     {QStringLiteral("intent"), alternate ? QStringLiteral("alternate") : QStringLiteral("foreground")}});
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "Submit(" << (alternate ? "alternate" : "foreground") << ")"; }
};

// Type a prompt and send it at once, so the restart check has sends to cut off.
struct Prompt : Command {
  Type type;
  Submit submit;
  Prompt() { type.text = pick(kTexts.mid(1, 2)); }
  void checkPreconditions(const Model& m) const override { submit.checkPreconditions(m); }
  void apply(Model& m) const override {
    type.apply(m);
    submit.apply(m);
  }
  void run(const Model& m0, Sut& sut) const override {
    type.run(m0, sut);
    submit.run(type.nextState(m0), sut);
  }
  void show(std::ostream& os) const override {
    os << "Prompt(\"" << type.text.toStdString() << "\", " << (submit.alternate ? "alternate" : "foreground") << ")";
  }
};

// The web's stash: the draft goes aside, or an empty draft takes back the only entry.
struct Stash : Command {
  void apply(Model& m) const override {
    Target& target = m.targets[m.open];
    if (target.text.trimmed().isEmpty() && target.images == 0) {
      if (m.stash.size() != 1) return;
      const auto [text, images] = m.stash.takeFirst();
      target.text = text;
      target.images += images;
      return;
    }
    m.stash.prepend({target.text.trimmed(), target.images});
    if (m.stash.size() > 20) m.stash.removeLast();
    target.text.clear();
    target.images = 0;
  }
  void run(const Model& m0, Sut& sut) const override {
    sut.bridge->dispatch(QStringLiteral("composer.stash"));
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "Stash"; }
};

// "Restore prompt" on the newest toast offering it: the prompt comes back
// into its thread's draft if that is empty, and the thread opens.
struct RestorePrompt : Command {
  void checkPreconditions(const Model& m) const override {
    RC_PRE(std::any_of(m.toasts.cbegin(), m.toasts.cend(), [](const Toast& toast) { return toast.restore; }));
  }
  void apply(Model& m) const override {
    const auto newest = std::find_if(m.toasts.cbegin(), m.toasts.cend(), [](const Toast& toast) { return toast.restore; });
    const Toast toast = *newest;
    m.toasts.erase(newest);
    Target& target = m.targets[toast.thread];
    if (!target.text.isEmpty()) return;
    target.text = toast.prompt;
    target.images += toast.images;
    m.open = toast.thread;
    settleLimbo(m, toast.thread);
  }
  void run(const Model& m0, Sut& sut) const override {
    RC_ASSERT(sut.native->controller<ToastController>()->runAction(QStringLiteral("Restore prompt")));
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "RestorePrompt"; }
};

struct SetRunning : Command {
  QString thread = pick(kThreads);
  bool on = *rc::gen::arbitrary<bool>();
  void apply(Model& m) const override {
    if (on) {
      m.running.insert(thread);
    } else {
      m.running.remove(thread);
    }
  }
  void run(const Model& m0, Sut& sut) const override {
    sut.mc.threads.insert(thread, Sut::row(thread, on));
    sut.mc.sendRow(thread, sut.mc.threads.value(thread));
    RC_ASSERT(prop::until([&] {
      const auto row = sut.native->store()->thread(keyOf(thread));
      return row && row->activeRunId.has_value() == on;
    }));
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "SetRunning(" << thread.toStdString() << ", " << on << ")"; }
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
    for (const QString type : {QStringLiteral("message.dispatch"), QStringLiteral("thread.runtime-mode.set")}) {
      if (on) {
        sut.mc.refusals.insert(type, QStringLiteral("The thread is busy."));
      } else {
        sut.mc.refusals.remove(type);
      }
    }
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "Refuse(" << on << ")"; }
};

struct AnswerHeld : Command {
  void checkPreconditions(const Model& m) const override { RC_PRE(m.holding); }
  void apply(Model& m) const override { answerHeld(m); }
  void run(const Model& m0, Sut& sut) const override {
    sut.mc.answerHeld();
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "AnswerHeld"; }
};

// The connection drops with sends held: they fail as the client gives up on
// them, and the client connects again.
struct Drop : Command {
  // McClient fails the calls a drop cut off in no set order, so their toasts
  // would be too.
  void checkPreconditions(const Model& m) const override { RC_PRE(m.held.size() <= 1); }
  void apply(Model& m) const override {
    m.holding = false;
    for (const QString& thread : std::exchange(m.held, {})) fail(m, thread);
  }
  void run(const Model& m0, Sut& sut) const override {
    sut.mc.drop();
    // What it held answers no one.
    sut.mc.answerHeld();
    RC_ASSERT(prop::until([&] { return !sut.native->client()->isReady(); }));
    RC_ASSERT(prop::until([&] { return sut.online(); }));
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "Drop"; }
};

// Another device's prompt reaches the thread: newer than anything sent here
// that has not reached it yet.
struct Elsewhere : Command {
  QString thread;
  // Mostly a thread with sends on their way or cut off, where it matters.
  explicit Elsewhere(const Model& m) {
    const QStringList pending = m.queues.keys() + m.limbo.keys();
    thread = pending.isEmpty() || *rc::gen::arbitrary<bool>() ? pick(kThreads) : pick(pending);
  }
  void apply(Model& m) const override {
    for (Send& send : m.queues[thread]) send.superseded = true;
    if (m.queues.value(thread).isEmpty()) m.queues.remove(thread);
    for (Send& send : m.limbo[thread]) send.superseded = true;
    if (m.limbo.value(thread).isEmpty()) m.limbo.remove(thread);
  }
  void run(const Model& m0, Sut& sut) const override {
    sut.addMessage(thread, QStringLiteral("elsewhere-%1").arg(sut.seq + 1));
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "Elsewhere(" << thread.toStdString() << ")"; }
};

// The app quits and starts again: the drafts, picks and stash are read back.
// The sends the MC holds are cut off: it gets the first of each thread's
// (`received`) or never did, and the rest never left. What it never got
// comes back once the thread is open.
struct Restart : Command {
  bool received = *rc::gen::arbitrary<bool>();
  void apply(Model& m) const override {
    m.toasts.clear();
    for (const QString& thread : std::exchange(m.held, {})) {
      QList<Send> cut = m.queues.take(thread);
      const Send& first = cut.first();
      // The held command is the send's message, unless a runtime change goes first.
      const bool message = commandsOf(first).size() == 1;
      if (!received) {
        m.commands[thread].removeLast();
        if (m.commands.value(thread).isEmpty()) m.commands.remove(thread);
      }
      if (received && message && !first.refusedAtMc) cut.removeFirst();
      m.limbo[thread].append(cut);
      if (m.limbo.value(thread).isEmpty()) m.limbo.remove(thread);
      m.holding = false;
    }
    if (m.isThread(m.open)) settleLimbo(m, m.open);
  }
  void run(const Model& m0, Sut& sut) const override {
    sut.restart(m0.held, received);
    sut.open(m0.open);
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override {
    os << "Restart(" << (received ? "the MC got what it held" : "the MC never got what it held") << ")";
  }
};

}  // namespace

class ComposerProp : public QObject {
  Q_OBJECT

private slots:
  void composerAcrossThreads() {
    QVERIFY(rc::check("each thread keeps its own draft through sends the MC accepts, refuses or holds", [] {
      Sut sut;
      RC_ASSERT(!sut.draftId.isEmpty());
      Model model;
      verify(model, sut);
      // Each restart starts the whole shell again: shorter runs keep a case quick.
      const auto commands = *rc::gen::scale(
          0.4, rc::state::gen::commands(model, rc::state::gen::execOneOfWithArgs<
                                                   Open, Open, Type, Type, Type, Attach, RemoveImage, PickModel, PickRuntime, Submit,
                                                   Submit, Submit, Stash, RestorePrompt, SetRunning, SetRunning, Hold, Refuse,
                                                   AnswerHeld, Drop, Hold, Elsewhere, Restart>()));
      rc::state::runAll(commands, model, sut);
    }));
  }

  // The same, crowded with sends in flight when the app quits: each reaches
  // the thread once, or comes back as its draft (or behind a toast when the
  // draft has newer typing), unless a newer user message is there.
  void sendsCutOffByARestart() {
    QVERIFY(rc::check("a send cut off by a restart reaches the MC once or comes back, never lost or doubled", [] {
      Sut sut;
      Model model;
      verify(model, sut);
      // A thread open with the MC holding its answers, so sends are in flight.
      Open open;
      open.target = kThreads.first();
      open.run(model, sut);
      open.apply(model);
      Hold().run(model, sut);
      Hold().apply(model);
      const auto commands = *rc::gen::scale(
          0.3, rc::state::gen::commands(model, rc::state::gen::execOneOfWithArgs<
                                                   Open, Type, Attach, PickRuntime, Prompt, Prompt, Prompt, Submit, Hold, Hold, Refuse,
                                                   AnswerHeld, Elsewhere, Elsewhere, RestorePrompt, Restart, Restart>()));
      rc::state::runAll(commands, model, sut);
    }));
  }
};

HAL_C2_PROP_MAIN(ComposerProp)
#include "tst_ComposerProp.moc"
