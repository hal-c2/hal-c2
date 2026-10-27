// The composer as the user drives it across threads and a new thread's draft,
// against a fake MC that accepts, refuses or holds each send
// (ComposerController, DraftController): typing, images, the model and
// permissions picked, sends and follow-ups while a turn runs, the stash, the
// connection dropping and the app restarting, with sends in flight that the MC
// did or did not get: each reaches the thread once or comes back to its draft,
// unless a newer user message is in the thread by then. A model of another
// provider than the thread's moves the thread to it before its message.

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
// Codex's two models, then Claude's.
const QStringList kModels{QStringLiteral("gpt-a"), QStringLiteral("gpt-b"), QStringLiteral("claude-a")};
const QStringList kRuntimeModes{QStringLiteral("approval-required"), QStringLiteral("auto"), QStringLiteral("full-access")};

// rc::gen::elementOf finds begin() by ADL alone, which a QList lacks.
QString pick(const QStringList& pool) { return *rc::gen::elementOf(std::vector<QString>(pool.cbegin(), pool.cend())); }

QString keyOf(const QString& thread) { return QStringLiteral("env-a:") + thread; }

QString instanceOf(const QString& model) {
  return model.startsWith(QLatin1String("claude")) ? QStringLiteral("claudeAgent") : QStringLiteral("codex");
}

// What a target's composer holds.
struct Target {
  QString text;
  int images = 0;
  QString model;  // picked, else the default
};

// A send on its way: the first of a thread's is at the MC, the rest wait behind it.
struct Send {
  QString prompt;
  int images = 0;
  QString model;
  QString delivery;  // auto, steer or queue
  bool switches = false;  // its model is another provider's than the thread's when sent
  bool refusedAtMc = false;  // what the MC holding it will answer
  bool superseded = false;   // a newer user message reached the thread since
  bool measured = false;     // the thread's messages were known while it was on its way
};

// A "Failed to send message" or "A prompt was not sent" toast; what its
// "Restore prompt" gives back.
struct Toast {
  QString thread;
  QString prompt;
  int images = 0;
  bool restore = false;  // whether it offers "Restore prompt"
};

// An access change the MC holds the answer to; whether it will refuse it.
struct HeldPick {
  QString thread;
  QString mode;
  bool refused = false;
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
  // Each thread's provider at the MC, Codex until a provider change reaches it.
  QMap<QString, QString> providers;
  // The sends a restart or a drop cut off that the MC never got, by thread,
  // until the thread is open again.
  QMap<QString, QList<Send>> limbo;
  // The MC is slow to send threads: one opened now waits, unknown, until it does.
  bool slow = false;
  QSet<QString> loaded{QStringLiteral("t1")};
  QSet<QString> waiting;
  // Each thread's access at the MC, none until a change reaches it.
  QMap<QString, QString> runtimes;
  // The access picked for a thread, shown until the MC has it or refuses it,
  // and the change last sent for it.
  QMap<QString, QString> picked;
  QMap<QString, QString> setting;
  // The access changes whose answers the MC holds, in the order they went out.
  QList<HeldPick> heldPicks;

  int total() const {
    int count = 0;
    for (const QStringList& list : commands) count += int(list.size());
    return count;
  }
  bool isThread(const QString& target) const { return kThreads.contains(target); }
  QString provider(const QString& thread) const { return providers.value(thread, QStringLiteral("codex")); }
  QString selected(const QString& target) const {
    const QString picked = targets.value(target).model;
    if (!picked.isEmpty()) return picked;
    if (target == kDraft && !lastModel.isEmpty()) return lastModel;
    return kModels.first();
  }
  // The access the composer shows for a thread.
  QString runtime(const QString& thread) const {
    if (const QString mode = picked.value(thread); !mode.isEmpty()) return mode;
    return runtimes.value(thread, QStringLiteral("full-access"));
  }
};

QStringList commandsOf(const Send& send) {
  QStringList list;
  if (send.switches) list.append(QStringLiteral("provider|") + instanceOf(send.model));
  list.append(QStringList{QStringLiteral("message"), send.prompt.trimmed(), QString::number(send.images),
                          send.model.isEmpty() ? kModels.first() : send.model, send.delivery}
                  .join(u'|'));
  return list;
}

void dispatchFirst(Model& m, const QString& thread);

// The MC answers an access change: the thread takes it, and the pick goes once
// the thread shows it; a refused one goes too, with a toast, unless a newer
// one is on its way.
void answerPick(Model& m, const HeldPick& pick) {
  if (!pick.refused) {
    m.runtimes[pick.thread] = pick.mode;
    if (m.setting.value(pick.thread) != pick.mode) return;
  } else {
    if (m.setting.value(pick.thread) != pick.mode) return;
    m.toasts.prepend({pick.thread, QString()});
  }
  m.setting.remove(pick.thread);
  if (m.picked.value(pick.thread) == pick.mode) m.picked.remove(pick.thread);
}

// The MC carried out `commands` for the thread: a provider change moves it.
void took(Model& m, const QString& thread, const QStringList& commands) {
  for (const QString& command : commands) {
    if (command.startsWith(QLatin1String("provider|"))) m.providers[thread] = command.section(u'|', 1);
  }
}

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

// The open thread's messages are known: the sends on their way to it measure
// newer messages from there.
void measure(Model& m, const QString& thread) {
  for (Send& send : m.queues[thread]) send.measured = true;
  if (m.queues.value(thread).isEmpty()) m.queues.remove(thread);
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

// A quit or a dropped connection cuts off the sends the MC holds: it gets
// the first of each thread's (`received`) or never did, and the rest never
// left. They wait to be settled when their thread is open.
void cutOff(Model& m, bool received) {
  m.holding = false;
  for (const QString& thread : std::exchange(m.held, {})) {
    QList<Send> cut = m.queues.take(thread);
    const Send& first = cut.first();
    // The held command is the send's message, unless a provider change goes first.
    const bool message = commandsOf(first).size() == 1;
    if (!received) {
      m.commands[thread].removeLast();
      if (m.commands.value(thread).isEmpty()) m.commands.remove(thread);
    }
    if (received && !first.refusedAtMc) took(m, thread, commandsOf(first).mid(0, 1));
    if (received && message && !first.refusedAtMc) cut.removeFirst();
    m.limbo[thread].append(cut);
    if (m.limbo.value(thread).isEmpty()) m.limbo.remove(thread);
  }
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
    took(m, thread, commands);
    accept(m, thread);
  }
}

// The MC answers what it held; the commands after each go out as it now answers,
// and their answers come back after every held one.
void answerHeld(Model& m) {
  m.holding = false;
  for (const HeldPick& pick : std::exchange(m.heldPicks, {})) answerPick(m, pick);
  QStringList refused;  // whose next command the MC refuses, in the order they went out
  for (const QString& thread : std::exchange(m.held, {})) {
    const Send send = m.queues[thread].first();
    if (send.refusedAtMc) {
      fail(m, thread);
      continue;
    }
    took(m, thread, commandsOf(send).mid(0, 1));
    const QStringList rest = commandsOf(send).mid(1);
    if (!rest.isEmpty() && m.refusing) {
      m.commands[thread].append(rest.first());
      refused.append(thread);
      continue;
    }
    m.commands[thread].append(rest);
    took(m, thread, rest);
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

// The app as main.cpp wires it, on a fake MC with one project of three Codex
// threads, Codex offering two models and Claude one; stores in a home of its own.
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
  // While set, the MC is slow to send threads: each `sub` to one waits here.
  bool slow = false;
  QList<std::pair<int, QJsonObject>> waiting;
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
    QJsonArray providers;
    for (const QString& instance : {QStringLiteral("codex"), QStringLiteral("claudeAgent")}) {
      QJsonArray models;
      for (const QString& model : kModels) {
        if (instanceOf(model) == instance) models.append(QJsonObject{{QStringLiteral("slug"), model}});
      }
      providers.append(QJsonObject{
          {QStringLiteral("instanceId"), instance},
          {QStringLiteral("driver"), instance},
          {QStringLiteral("enabled"), true},
          {QStringLiteral("status"), QStringLiteral("ready")},
          {QStringLiteral("models"), models},
      });
    }
    mc.onShape(QStringLiteral("config"), [this, providers](int id, const QJsonObject& shape) {
      if (shape.value(QLatin1String("environment")).toString() != mc.environmentId) return;
      mc.send({{QStringLiteral("t"), QStringLiteral("config")},
               {QStringLiteral("id"), id},
               {QStringLiteral("mc"), mc.name},
               {QStringLiteral("config"), QJsonObject{{QStringLiteral("providers"), providers},
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
      if (slow) {
        waiting.append({id, shape});
        return;
      }
      sendThread(id, shape);
    });
    // A provider change moves the thread, as the MC's projection does.
    mc.effects.append([this](const QJsonObject& command) {
      if (losing || command.value(QLatin1String("type")) != QLatin1String("provider.switch")) return;
      const QString thread = command.value(QLatin1String("threadId")).toString();
      QJsonObject row = mc.threads.value(thread);
      row.insert(QStringLiteral("modelSelection"), command.value(QLatin1String("modelSelection")));
      mc.threads.insert(thread, row);
      mc.sendRow(thread, row);
    });
    // An access change too.
    mc.effects.append([this](const QJsonObject& command) {
      if (losing || command.value(QLatin1String("type")) != QLatin1String("thread.runtime-mode.set")) return;
      const QString thread = command.value(QLatin1String("threadId")).toString();
      QJsonObject row = mc.threads.value(thread);
      row.insert(QStringLiteral("runtimeMode"), command.value(QLatin1String("runtimeMode")));
      mc.threads.insert(thread, row);
      mc.sendRow(thread, row);
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

  // A thread's messages, whole, then as they come.
  void sendThread(int id, const QJsonObject& shape) {
    QJsonArray rows;
    for (const QJsonObject& message : messages.value(shape.value(QLatin1String("stream")).toString())) {
      rows.append(QJsonArray{QStringLiteral("message"), message.value(QLatin1String("id")), message});
    }
    mc.send({{QStringLiteral("t"), QStringLiteral("snapshot")}, {QStringLiteral("id"), id}, {QStringLiteral("part"), 0},
             {QStringLiteral("rows"), rows}, {QStringLiteral("done"), true}, {QStringLiteral("offset"), seq},
             {QStringLiteral("floor"), QJsonValue::Null}, {QStringLiteral("handle"), QStringLiteral("log-1")}});
    mc.send({{QStringLiteral("t"), QStringLiteral("live")}, {QStringLiteral("id"), id}, {QStringLiteral("offset"), seq},
             {QStringLiteral("handle"), QStringLiteral("log-1")}});
  }

  // The MC sends the threads it was slow to.
  void load() {
    slow = false;
    const QList<int> following = mc.subscribers(QStringLiteral("stream"));
    for (const auto& [id, shape] : std::exchange(waiting, {})) {
      if (following.contains(id)) sendThread(id, shape);
    }
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
      // One the MC has not sent the thread yet gets it whole when it does.
      if (std::any_of(waiting.cbegin(), waiting.cend(), [sub](const auto& wait) { return wait.first == sub; })) continue;
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
    slow = false;
    waiting.clear();
    if (!held.isEmpty()) cutOff(held, received);
    start();
  }

  // With the client gone, the MC carries out the first sends of `held` it
  // holds (`received`), or they never reached it; no one hears its answers.
  void cutOff(const QStringList& held, bool received) {
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
      } else if (type == QLatin1String("provider.switch")) {
        byThread[thread].append(QStringLiteral("provider|") +
                                command.value(QLatin1String("modelSelection")).toObject().value(QLatin1String("instanceId")).toString());
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
  if (m.loaded.contains(m.open)) {
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
  if (m.isThread(m.open)) RC_ASSERT(shown.value(QStringLiteral("runtimeMode")).toString() == m.runtime(m.open));
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
    if (!m.isThread(target)) return;
    if (!m.slow) {
      m.loaded.insert(target);
    } else if (!m.loaded.contains(target)) {
      m.waiting.insert(target);
      return;
    }
    measure(m, target);
    settleLimbo(m, target);
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
                         QVariantMap{{QStringLiteral("instanceId"), instanceOf(model)}, {QStringLiteral("model"), model}});
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "PickModel(" << model.toStdString() << ")"; }
};

// The thread's access, which goes to the MC at once; one the composer already
// shows changes nothing. Its answer can be held only among other access
// changes: a held send's would race it for the toasts.
struct PickRuntime : Command {
  QString mode = pick(kRuntimeModes);
  void checkPreconditions(const Model& m) const override {
    RC_PRE(m.isThread(m.open));
    RC_PRE(!m.holding || m.held.isEmpty());
  }
  void apply(Model& m) const override {
    if (mode == m.runtime(m.open)) return;
    m.picked[m.open] = mode;
    if (!m.setting.contains(m.open) && m.runtimes.value(m.open) == mode) return;
    m.commands[m.open].append(QStringLiteral("runtime|") + mode);
    m.setting[m.open] = mode;
    // One the thread already shows (another device made it) settles at once.
    if (m.runtimes.value(m.open) == mode) {
      m.setting.remove(m.open);
      m.picked.remove(m.open);
    }
    const HeldPick sent{m.open, mode, m.refusing};
    if (m.holding) {
      m.heldPicks.append(sent);
    } else {
      answerPick(m, sent);
    }
  }
  void run(const Model& m0, Sut& sut) const override {
    sut.bridge->dispatch(QStringLiteral("composer.runtimeMode.set"), QVariantMap{{QStringLiteral("mode"), mode}});
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "PickRuntime(" << mode.toStdString() << ")"; }
};

// Another device changes a thread's access: a change from here still on its
// way lands after it, unless the thread now shows the one it was making.
struct AccessElsewhere : Command {
  QString thread = pick(kThreads);
  QString mode = pick(kRuntimeModes);
  void apply(Model& m) const override {
    m.runtimes[thread] = mode;
    if (m.setting.value(thread) != mode) return;
    m.setting.remove(thread);
    if (m.picked.value(thread) == mode) m.picked.remove(thread);
  }
  void run(const Model& m0, Sut& sut) const override {
    QJsonObject row = sut.mc.threads.value(thread);
    row.insert(QStringLiteral("runtimeMode"), mode);
    sut.mc.threads.insert(thread, row);
    sut.mc.sendRow(thread, row);
    RC_ASSERT(prop::until([&] {
      const auto row = sut.native->store()->thread(keyOf(thread));
      return row && row->runtimeMode == mode;
    }));
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "AccessElsewhere(" << thread.toStdString() << ", " << mode.toStdString() << ")"; }
};

// A send from a thread's composer: the draft empties as it goes, and a send
// behind one the MC still holds waits its turn.
struct Submit : Command {
  bool alternate = *rc::gen::arbitrary<bool>();
  void checkPreconditions(const Model& m) const override {
    RC_PRE(m.isThread(m.open));
    RC_PRE(m.heldPicks.isEmpty());
  }
  void apply(Model& m) const override {
    Target& target = m.targets[m.open];
    if (target.text.trimmed().isEmpty() && target.images == 0) return;
    const QString delivery = !m.running.contains(m.open) ? QStringLiteral("auto")
                             : alternate                  ? QStringLiteral("queue")
                                                          : QStringLiteral("steer");
    QList<Send>& queue = m.queues[m.open];
    const QString model = target.model.isEmpty() ? kModels.first() : target.model;
    queue.append({target.text, target.images, target.model, delivery, instanceOf(model) != m.provider(m.open)});
    if (m.loaded.contains(m.open)) measure(m, m.open);
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

// The stash: the draft goes aside, or an empty draft takes back the only entry.
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
    // Only the run changes: the thread keeps the provider and access it moved to.
    QJsonObject row = Sut::row(thread, on);
    for (const QLatin1String field : {QLatin1String("modelSelection"), QLatin1String("runtimeMode")}) {
      if (const QJsonValue value = sut.mc.threads.value(thread).value(field); !value.isUndefined()) row.insert(field, value);
    }
    sut.mc.threads.insert(thread, row);
    sut.mc.sendRow(thread, row);
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
    for (const QString type : {QStringLiteral("message.dispatch"), QStringLiteral("thread.runtime-mode.set"), QStringLiteral("provider.switch")}) {
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

// The connection drops with sends held, which the MC got (`received`) or
// not: the client cannot tell, so they are cut off as by a quit, and the
// client connects again. Nothing is sent twice or lost.
struct Drop : Command {
  bool received = *rc::gen::arbitrary<bool>();
  // An access change cut off is not modelled yet (hal-c2#609).
  void checkPreconditions(const Model& m) const override { RC_PRE(m.heldPicks.isEmpty()); }
  void apply(Model& m) const override {
    cutOff(m, received);
    // The threads followed are asked for again, and a slow MC keeps them waiting.
    if (m.slow) {
      m.waiting.unite(std::exchange(m.loaded, {}));
    } else if (m.loaded.contains(m.open)) {
      settleLimbo(m, m.open);
    }
  }
  void run(const Model& m0, Sut& sut) const override {
    sut.mc.drop();
    sut.cutOff(m0.held, received);
    RC_ASSERT(prop::until([&] { return !sut.native->client()->isReady(); }));
    RC_ASSERT(prop::until([&] { return sut.online(); }));
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override {
    os << "Drop(" << (received ? "the MC got what it held" : "the MC never got what it held") << ")";
  }
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
    // Only a send that knows the thread's messages from before can tell.
    for (Send& send : m.queues[thread]) send.superseded = send.superseded || send.measured;
    if (m.queues.value(thread).isEmpty()) m.queues.remove(thread);
    for (Send& send : m.limbo[thread]) send.superseded = send.superseded || send.measured;
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
  void checkPreconditions(const Model& m) const override { RC_PRE(m.heldPicks.isEmpty()); }
  void apply(Model& m) const override {
    m.toasts.clear();
    if (!m.held.isEmpty()) cutOff(m, received);
    m.slow = false;
    m.waiting.clear();
    m.loaded.clear();
    if (m.isThread(m.open)) {
      m.loaded.insert(m.open);
      settleLimbo(m, m.open);
    }
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

// The MC is slow to send threads: one opened now is not known until Load.
struct Slow : Command {
  void checkPreconditions(const Model& m) const override { RC_PRE(!m.slow); }
  void apply(Model& m) const override { m.slow = true; }
  void run(const Model& m0, Sut& sut) const override {
    sut.slow = true;
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "Slow"; }
};

// The MC sends the threads it was slow to.
struct Load : Command {
  void checkPreconditions(const Model& m) const override { RC_PRE(m.slow); }
  void apply(Model& m) const override {
    m.slow = false;
    m.loaded.unite(std::exchange(m.waiting, {}));
    if (!m.loaded.contains(m.open)) return;
    measure(m, m.open);
    settleLimbo(m, m.open);
  }
  void run(const Model& m0, Sut& sut) const override {
    sut.load();
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "Load"; }
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
                                                   AnswerHeld, Drop, Hold, Elsewhere, Restart, Slow, Load>()));
      rc::state::runAll(commands, model, sut);
    }));
  }

  // The same, crowded with sends in flight when the app quits or the
  // connection drops: each reaches the thread once, or comes back as its
  // draft (or behind a toast when the draft has newer typing), unless a newer
  // user message is there.
  void sendsCutOffByARestart() {
    QVERIFY(rc::check("a send cut off by a restart or a drop reaches the MC once or comes back, never lost or doubled", [] {
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
                                                   AnswerHeld, Elsewhere, Elsewhere, RestorePrompt, Restart, Restart, Drop, Drop,
                                                   Slow, Load>()));
      rc::state::runAll(commands, model, sut);
    }));
  }

  // The same, with sends made before their thread's messages are known: a
  // newer message from elsewhere once they are still drops them.
  void sendsWhileTheThreadLoads() {
    QVERIFY(rc::check("a send made while its thread loads is dropped by a newer message from elsewhere, else comes back", [] {
      Sut sut;
      Model model;
      verify(model, sut);
      // The MC holds its answers and is slow to send the thread opened, and
      // a prompt goes to it.
      Hold().run(model, sut);
      Hold().apply(model);
      Slow().run(model, sut);
      Slow().apply(model);
      Open open;
      open.target = kThreads.at(1);
      open.run(model, sut);
      open.apply(model);
      Prompt prompt;
      prompt.run(model, sut);
      prompt.apply(model);
      const auto commands = *rc::gen::scale(
          0.3, rc::state::gen::commands(model, rc::state::gen::execOneOfWithArgs<
                                                   Open, Prompt, Prompt, Hold, AnswerHeld, Elsewhere, Elsewhere, Restart,
                                                   Restart, Slow, Load, Load>()));
      rc::state::runAll(commands, model, sut);
    }));
  }

  // The same, picking models and sending often: a thread moves to another
  // provider only when it is not already on it, and only a provider change
  // the MC carried out counts, refused, held or cut off as the send was.
  void providerChanges() {
    QVERIFY(rc::check("a send moves its thread to the model's provider only when the thread is on another", [] {
      Sut sut;
      Model model;
      verify(model, sut);
      const auto commands = *rc::gen::scale(
          0.3, rc::state::gen::commands(model, rc::state::gen::execOneOfWithArgs<
                                                   Open, PickModel, PickModel, PickModel, Prompt, Prompt, Prompt, SetRunning,
                                                   Hold, AnswerHeld, Refuse, Restart, Drop>()));
      rc::state::runAll(commands, model, sut);
    }));
  }

  // Picking a thread's access often, with the MC holding or refusing the
  // changes: the composer shows the pick while it is on its way, then what the
  // thread really has, and a pick back to the thread's access still goes.
  void accessChanges() {
    QVERIFY(rc::check("a thread takes the access picked at once, and the composer shows what the thread has", [] {
      Sut sut;
      Model model;
      verify(model, sut);
      const auto commands = *rc::gen::scale(
          0.3, rc::state::gen::commands(model, rc::state::gen::execOneOfWithArgs<
                                                   Open, PickRuntime, PickRuntime, PickRuntime, AccessElsewhere, Prompt, SetRunning,
                                                   Hold, Hold, AnswerHeld, Refuse, Restart>()));
      rc::state::runAll(commands, model, sut);
    }));
  }
};

HAL_C2_PROP_MAIN(ComposerProp)
#include "tst_ComposerProp.moc"
