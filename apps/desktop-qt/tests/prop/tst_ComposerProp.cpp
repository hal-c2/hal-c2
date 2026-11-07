// The composer as the user drives it across threads and a new thread's draft,
// against a fake MC that accepts, refuses or holds each send
// (ComposerController, DraftController): typing, images, the model and
// permissions picked, sends and follow-ups while a turn runs, the stash, the
// connection dropping and the app restarting, with sends in flight that the MC
// did or did not get: each reaches the thread once or comes back to its draft,
// unless a newer user message is in the thread by then. A thread names no
// provider until the MC records one, and a model of another provider than the
// one it names moves the thread to it; a thread naming none is not moved. The
// interaction mode picked goes before the message, and a provider change between.
// A Space page's prompt keeps a draft of its own: plain words write a block,
// and words starting with @agent ask an agent, which the MC takes, refuses or
// holds; a refused ask keeps every word and image. A Space's images have a
// prompt of their own that draws an image with the image model picked: it
// keeps its words until the image is made, and takes nothing a turn carries.

#include <QBuffer>
#include <QImage>
#include <QRegularExpression>

#include "ComposerController.h"
#include "DraftController.h"
#include "FakeMc.h"
#include "McClient.h"
#include "NavigationController.h"
#include "NativeShell.h"
#include "Prop.h"
#include "ShellBridge.h"
#include "SettingsController.h"
#include "ShellStore.h"
#include "SpaceController.h"
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
const QStringList kInteractionModes{QStringLiteral("default"), QStringLiteral("plan")};
// Two pages of one Space, and what their prompts are given: a block's words, or an ask.
const QStringList kPages{QStringLiteral("pg1"), QStringLiteral("pg2")};
const QStringList kPageTexts{QStringLiteral("a note"), QStringLiteral("@agent tidy this"), QStringLiteral("@Agent"),
                             QStringLiteral("@agents meet"), QStringLiteral("  ")};

// How the model names the Space's images, whose prompt draws an image.
const QString kImages = QStringLiteral("images");
const QStringList kImageTexts{QStringLiteral("a red fox"), QStringLiteral("a lighthouse at dusk"), QStringLiteral("  ")};
// The image models picked ("instance|model"): the MC offers the first three, not a chat model.
const QStringList kImageModels{QStringLiteral("codex|auto"), QStringLiteral("grok|auto"), QStringLiteral("grok|grok-imagine-image-2.0"),
                               QStringLiteral("codex|gpt-a")};
// The MC's own pick, until the user picks another.
const QString kImageDefault = QStringLiteral("codex|auto");
// The toasts drawing an image shows, which the model leaves out: it says what the prompt keeps instead.
const QStringList kImageToasts{QStringLiteral("Generating an image…"), QStringLiteral("Image generated"),
                               QStringLiteral("The image could not be made.")};

// Words that ask an agent: they start with @agent.
bool asks(const QString& text) {
  static const QRegularExpression ask(QStringLiteral("^@agent(\\s|$)"), QRegularExpression::CaseInsensitiveOption);
  return ask.match(text.trimmed()).hasMatch();
}

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
  int pending = 0;  // of a page's images, the first ones, those its ask on its way carries
  QString interaction;  // the interaction mode picked, else the thread's
};

// A page's ask whose answer the MC holds; whether it will refuse it.
struct Ask {
  QString page;
  QString text;
  int images = 0;
  bool refused = false;
};

// A send on its way: the first of a thread's is at the MC, the rest wait behind it.
struct Send {
  QString prompt;
  int images = 0;
  QString model;
  QString delivery;  // auto, steer or queue
  bool switches = false;  // its model is another provider's than the one the thread names when sent
  bool refusedAtMc = false;  // what the MC holding it will answer
  bool superseded = false;   // a newer user message reached the thread since
  bool measured = false;     // the thread's messages were known while it was on its way
  QString interaction;       // the interaction mode it sets first, when the thread has another
};

// A "Failed to send message" or "A prompt was not sent" toast; what its
// "Restore prompt" gives back.
struct Toast {
  QString thread;
  QString prompt;
  int images = 0;
  bool restore = false;  // whether it offers "Restore prompt"
};

// An image the MC is drawing: the prompt's words, by whom ("instance|model"), and whether it will refuse it.
struct Generation {
  QString text;
  QString by;
  bool refused = false;
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
  // A page's ask went since: it sends with its project's latest model, which the
  // model leaves out, and that is the new thread's default until a send here.
  bool lastModelUnknown = false;
  // The model each thread names at the MC, none until one is recorded: a
  // provider change that reached it, or the MC's own record.
  QMap<QString, QString> recorded;
  // Each thread's interaction mode at the MC, default until a change reaches it.
  QMap<QString, QString> interactions;
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
  // While set, the MC's rows reach the client after its answers, which do not
  // wait for them: the access each row will show, by thread, in order.
  bool lagging = false;
  QList<std::pair<QString, QString>> lagged;
  // The changes the MC took whose rows have not come, by thread.
  QMap<QString, QString> landing;
  // The pages with an ask on its way, and those whose answers the MC holds.
  QSet<QString> asking;
  QList<Ask> heldAsks;
  // The asks the MC took ("page|request|images"), and the blocks the pages' prompts wrote ("page|text").
  QStringList asked;
  QStringList written;
  // The image model picked for the images ("instance|model"), none for the MC's pick;
  // the image being drawn, held while the MC holds its answer; and those drawn ("prompt|instance|model").
  QString imageModel;
  bool generating = false;
  std::optional<Generation> heldGeneration;
  QStringList generated;

  int total() const {
    int count = 0;
    for (const QStringList& list : commands) count += int(list.size());
    return count;
  }
  bool isThread(const QString& target) const { return kThreads.contains(target); }
  bool isPage(const QString& target) const { return kPages.contains(target); }
  QString imageBy() const { return imageModel.isEmpty() ? kImageDefault : imageModel; }
  // The provider the thread names, if any.
  QString provider(const QString& thread) const {
    const QString model = recorded.value(thread);
    return model.isEmpty() ? QString() : instanceOf(model);
  }
  QString selected(const QString& target) const {
    const QString picked = targets.value(target).model;
    if (!picked.isEmpty()) return picked;
    if (isThread(target) && !recorded.value(target).isEmpty()) return recorded.value(target);
    if (target == kDraft && !lastModel.isEmpty()) return lastModel;
    return kModels.first();
  }
  // The interaction mode the composer shows for a thread.
  QString interaction(const QString& thread) const {
    if (const QString mode = targets.value(thread).interaction; !mode.isEmpty()) return mode;
    return interactions.value(thread, QStringLiteral("default"));
  }
  // The access the composer shows for a thread.
  QString runtime(const QString& thread) const {
    if (const QString mode = picked.value(thread); !mode.isEmpty()) return mode;
    return runtimes.value(thread, QStringLiteral("full-access"));
  }
};

// A send's commands, in the order they go: its mode, a provider change, its message.
QStringList commandsOf(const Send& send) {
  QStringList list;
  if (!send.interaction.isEmpty()) list.append(QStringLiteral("interaction|") + send.interaction);
  if (send.switches) list.append(QStringLiteral("provider|") + instanceOf(send.model) + u'|' + send.model);
  list.append(QStringList{QStringLiteral("message"), send.prompt.trimmed(), QString::number(send.images), send.model, send.delivery}
                  .join(u'|'));
  return list;
}

void dispatchFirst(Model& m, const QString& thread);
void answerAsk(Model& m, const Ask& ask);

// The MC answers an image: one it drew empties the prompt (if it still holds the
// words it was drawn from), a refused one leaves them to try again.
void answerGeneration(Model& m, const Generation& generation) {
  m.generating = false;
  if (generation.refused) return;
  m.generated.append(generation.text.trimmed() + u'|' + generation.by);
  Target& target = m.targets[kImages];
  if (target.text == generation.text) target.text.clear();
}

// The MC answers an access change: the thread takes it, and the pick goes once
// the row with it has come, whatever the row shows; a refused one goes too,
// with a toast, unless a newer one is on its way.
void answerPick(Model& m, const HeldPick& pick) {
  if (!pick.refused) {
    if (m.lagging) {
      m.lagged.append({pick.thread, pick.mode});
    } else {
      m.runtimes[pick.thread] = pick.mode;
    }
    if (m.setting.value(pick.thread) != pick.mode) return;
    if (m.lagging) return void(m.landing[pick.thread] = pick.mode);
  } else {
    if (m.setting.value(pick.thread) != pick.mode) return;
    m.toasts.prepend({pick.thread, QString()});
  }
  m.setting.remove(pick.thread);
  if (m.picked.value(pick.thread) == pick.mode) m.picked.remove(pick.thread);
}

// The MC carried out `commands` for the thread: a provider change moves it,
// and a mode change sets its mode.
void took(Model& m, const QString& thread, const QStringList& commands) {
  for (const QString& command : commands) {
    if (command.startsWith(QLatin1String("provider|"))) m.recorded[thread] = command.section(u'|', 2);
    if (command.startsWith(QLatin1String("interaction|"))) m.interactions[thread] = command.section(u'|', 1);
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
  for (const Ask& ask : std::exchange(m.heldAsks, {})) answerAsk(m, ask);
  if (const auto generation = std::exchange(m.heldGeneration, std::nullopt)) answerGeneration(m, *generation);
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

// The MC answers a page's ask: one it took empties the prompt of what it
// carried (its words only if they are still all there), a refused one leaves
// everything to try again.
void answerAsk(Model& m, const Ask& ask) {
  m.asking.remove(ask.page);
  Target& target = m.targets[ask.page];
  if (ask.refused) {
    target.pending = 0;
    m.toasts.prepend({ask.page, QString()});
    return;
  }
  m.asked.append(QStringList{ask.page, ask.text.trimmed(), QString::number(ask.images)}.join(u'|'));
  target.images -= std::exchange(target.pending, 0);
  if (target.text == ask.text) target.text.clear();
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
// threads, each naming the model `recorded` gives it or none, Codex offering
// two models and Claude one, both with plan mode, and a Space of two pages
// whose agents run in that project; stores in a home of its own.
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
  // The asks the MC took and the blocks the pages' prompts wrote, as the model has them.
  QStringList asked;
  QStringList written;
  bool refusingAsks = false;
  // The images the MC drew ("prompt|instance|model").
  QStringList generated;

  explicit Sut(const QMap<QString, QString>& recorded) {
    mc.projects.insert(QStringLiteral("p1"), QJsonObject{
                                                 {QStringLiteral("id"), QStringLiteral("p1")},
                                                 {QStringLiteral("title"), QStringLiteral("Shop")},
                                                 {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")},
                                                 {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                 {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                 {QStringLiteral("scripts"), QJsonArray()},
                                             });
    for (const QString& id : kThreads) {
      QJsonObject thread = row(id);
      if (const QString model = recorded.value(id); !model.isEmpty()) thread.insert(QStringLiteral("modelSelection"), selectionOf(model));
      mc.threads.insert(id, thread);
    }
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
    // Each thread's messages, whole on every subscription, then as they come;
    // the Space and its pages, which never change.
    mc.onShape(QStringLiteral("stream"), [this](int id, const QJsonObject& shape) {
      const QString stream = shape.value(QLatin1String("stream")).toString();
      if (stream == QLatin1String("spaces") || stream.startsWith(QLatin1String("space:"))) return sendSpace(id, stream);
      if (slow) {
        waiting.append({id, shape});
        return;
      }
      sendThread(id, shape);
    });
    // A page's agents run in p1. An ask is taken, refused, or held with the
    // commands' answers.
    mc.onRpc(QStringLiteral("space."), [this](const FakeMc::Rpc& rpc) {
      if (rpc.method == QLatin1String("space.page.agentTarget")) return mc.reply(rpc, QJsonObject{{QStringLiteral("projectId"), QStringLiteral("p1")}});
      if (rpc.method == QLatin1String("space.image.providers")) return mc.reply(rpc, imageOffer());
      if (rpc.method == QLatin1String("space.image.generate")) return generate(rpc);
      if (rpc.method != QLatin1String("space.page.askAgent")) return mc.reply(rpc, QJsonObject());
      const QString took = QStringList{rpc.payload.value(QLatin1String("pageId")).toString(),
                                       rpc.payload.value(QLatin1String("request")).toString(),
                                       QString::number(rpc.payload.value(QLatin1String("attachments")).toArray().size())}
                               .join(u'|');
      const auto answer = [this, rpc, took, refused = refusingAsks] {
        if (refused) return mc.refuse(rpc, QStringLiteral("The agent could not start."));
        asked.append(took);
        mc.reply(rpc, QJsonObject{{QStringLiteral("threadId"), QStringLiteral("agent-%1").arg(rpc.id)}});
      };
      if (mc.holding(QStringLiteral("answers"))) return mc.defer(answer);
      answer();
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
    // And an interaction mode change.
    mc.effects.append([this](const QJsonObject& command) {
      if (losing || command.value(QLatin1String("type")) != QLatin1String("thread.interaction-mode.set")) return;
      const QString thread = command.value(QLatin1String("threadId")).toString();
      QJsonObject row = mc.threads.value(thread);
      row.insert(QStringLiteral("interactionMode"), command.value(QLatin1String("interactionMode")));
      mc.threads.insert(thread, row);
      mc.sendRow(thread, row);
    });
    mc.effects.append([this](const QJsonObject& command) {
      if (losing || command.value(QLatin1String("type")) != QLatin1String("message.dispatch")) return;
      addMessage(command.value(QLatin1String("threadId")).toString(), command.value(QLatin1String("messageId")).toString());
    });
    start();
    // Plan mode, a beta setting, kept on the device across restarts.
    RC_ASSERT(native->controller<SettingsController>()->writeDevice(QStringLiteral("planModeEnabled"), true));
    draftId = native->controller<DraftController>()->start(mc.environmentId, QStringLiteral("p1"));
    open(QStringLiteral("t1"));
    settle(0);
  }

  // Codex and Grok can draw, each with its image models; Codex's is the MC's pick.
  static QJsonObject imageOffer() {
    const auto provider = [](const QString& id, const QStringList& models) {
      QJsonArray list;
      for (const QString& model : models) list.append(QJsonObject{{QStringLiteral("slug"), model}, {QStringLiteral("name"), model}});
      return QJsonObject{{QStringLiteral("instanceId"), id}, {QStringLiteral("driver"), id}, {QStringLiteral("status"), QStringLiteral("ready")},
                         {QStringLiteral("models"), list}};
    };
    return {{QStringLiteral("providers"), QJsonArray{provider(QStringLiteral("codex"), {QStringLiteral("auto")}),
                                                     provider(QStringLiteral("grok"), {QStringLiteral("auto"), QStringLiteral("grok-imagine-image-2.0")})}},
            {QStringLiteral("selection"), QJsonObject{{QStringLiteral("instanceId"), QStringLiteral("codex")}, {QStringLiteral("model"), QStringLiteral("auto")}}}};
  }

  // An image drawn, refused, or held with the commands' answers.
  void generate(const FakeMc::Rpc& rpc) {
    const QJsonObject by = rpc.payload.value(QLatin1String("modelSelection")).toObject();
    const QString drawn = QStringList{rpc.payload.value(QLatin1String("prompt")).toString(), by.value(QLatin1String("instanceId")).toString(),
                                      by.value(QLatin1String("model")).toString()}
                              .join(u'|');
    const auto answer = [this, rpc, drawn, refused = refusingAsks] {
      if (refused) return mc.refuse(rpc, kImageToasts.last());
      generated.append(drawn);
      mc.reply(rpc, QJsonObject{{QStringLiteral("imageId"), QStringLiteral("image-%1").arg(rpc.id)}});
    };
    if (mc.holding(QStringLiteral("answers"))) return mc.defer(answer);
    answer();
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

  // The Space's index, or its stream: Notes, with the pages pg1 and pg2.
  void sendSpace(int id, const QString& stream) {
    const QString at = QStringLiteral("2026-09-01T09:00:00Z");
    QJsonArray rows;
    if (stream == QLatin1String("spaces")) {
      rows.append(QJsonArray{QStringLiteral("space"), QStringLiteral("sp1"),
                             QJsonObject{{QStringLiteral("id"), QStringLiteral("sp1")}, {QStringLiteral("name"), QStringLiteral("Notes")},
                                         {QStringLiteral("createdAt"), at}, {QStringLiteral("updatedAt"), at}}});
    } else {
      for (const QString& page : kPages) {
        rows.append(QJsonArray{QStringLiteral("page"), page,
                               QJsonObject{{QStringLiteral("id"), page},
                                           {QStringLiteral("spaceId"), QStringLiteral("sp1")},
                                           {QStringLiteral("title"), page},
                                           {QStringLiteral("parentPageId"), QJsonValue::Null},
                                           {QStringLiteral("sourceThreadId"), QJsonValue::Null},
                                           {QStringLiteral("trashedAt"), QJsonValue::Null},
                                           {QStringLiteral("createdAt"), at},
                                           {QStringLiteral("updatedAt"), at}}});
      }
    }
    mc.send({{QStringLiteral("t"), QStringLiteral("snapshot")}, {QStringLiteral("id"), id}, {QStringLiteral("part"), 0},
             {QStringLiteral("rows"), rows}, {QStringLiteral("done"), true}, {QStringLiteral("offset"), 1},
             {QStringLiteral("floor"), QJsonValue::Null}, {QStringLiteral("handle"), QStringLiteral("space-log")}});
    mc.send({{QStringLiteral("t"), QStringLiteral("live")}, {QStringLiteral("id"), id}, {QStringLiteral("offset"), 1},
             {QStringLiteral("handle"), QStringLiteral("space-log")}});
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

  static QJsonObject selectionOf(const QString& model) {
    return {{QStringLiteral("instanceId"), instanceOf(model)}, {QStringLiteral("model"), model}};
  }

  // A thread that names no model, not running.
  static QJsonObject row(const QString& id) {
    return {{QStringLiteral("id"), id},
            {QStringLiteral("projectId"), QStringLiteral("p1")},
            {QStringLiteral("title"), id},
            {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")},
            {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}};
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
    // The blocks a page's prompt writes, which SpacePage would put on the page.
    QObject::connect(bridge.get(), &ShellBridge::actionRequested, [this](const QString& action, const QVariant& payload) {
      if (action != QLatin1String("space.prompt.write")) return;
      const QVariantMap write = payload.toMap();
      written.append(write.value(QStringLiteral("pageId")).toString() + u'|' + write.value(QStringLiteral("text")).toString());
    });
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

  QString keyFor(const QString& target) const {
    if (kPages.contains(target)) return ComposerController::pageKey(target);
    if (target == kImages) return ComposerController::imagesKey(QStringLiteral("sp1"));
    return target == kDraft ? draftId : keyOf(target);
  }

  void open(const QString& target) {
    if (kPages.contains(target) || target == kImages) {
      auto* spaces = native->controller<SpaceController>();
      if (native->controller<NavigationController>()->route().kind != QLatin1String("space")) {
        bridge->dispatch(SpaceController::kOpen, QVariantMap{});
      }
      RC_ASSERT(prop::until([&] { return spaces->spaceId() == QLatin1String("sp1") && spaces->space().live(); }));
      // The images browser shows instead of the page, as SpaceWorkspace has it.
      bridge->dispatch(QStringLiteral("space.images.show"), QVariantMap{{QStringLiteral("shown"), target == kImages}});
    }
    if (target == kImages) {
      auto* spaces = native->controller<SpaceController>();
      RC_ASSERT(prop::until([&] {
        return bridge->state()->value(QStringLiteral("composer")).toMap().value(QStringLiteral("target")).toString() == keyFor(target) &&
               !spaces->imageProviders().isEmpty();
      }));
    } else if (kPages.contains(target)) {
      bridge->dispatch(QStringLiteral("space.selectPage"), QVariantMap{{QStringLiteral("pageId"), target}});
      RC_ASSERT(prop::until([&] {
        return bridge->state()->value(QStringLiteral("composer")).toMap().value(QStringLiteral("target")).toString() == keyFor(target);
      }));
    } else if (target == kDraft) {
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
      } else if (type == QLatin1String("thread.interaction-mode.set")) {
        byThread[thread].append(QStringLiteral("interaction|") + command.value(QLatin1String("interactionMode")).toString());
      } else if (type == QLatin1String("provider.switch")) {
        const QJsonObject selection = command.value(QLatin1String("modelSelection")).toObject();
        byThread[thread].append(QStringLiteral("provider|") + selection.value(QLatin1String("instanceId")).toString() + u'|' +
                                selection.value(QLatin1String("model")).toString());
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
      if (kImageToasts.contains(toast.toMap().value(QStringLiteral("title")).toString())) continue;
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
  for (const QString& target : kThreads + QStringList{kDraft, kImages} + kPages) {
    const Target expected = m.targets.value(target);
    RC_ASSERT(composer->draft(sut.keyFor(target)) == expected.text);
    RC_ASSERT(composer->attachments(sut.keyFor(target)).size() == expected.images);
  }
  const QVariantMap shown = sut.bridge->state()->value(QStringLiteral("composer")).toMap();
  RC_ASSERT(shown.value(QStringLiteral("target")).toString() == sut.keyFor(m.open));
  RC_ASSERT(shown.value(QStringLiteral("text")).toString() == m.targets.value(m.open).text);
  // A page's ask defaults to the model its project last worked with, which the model leaves out.
  const bool unknown = m.open == kDraft && m.lastModelUnknown && m.targets.value(kDraft).model.isEmpty();
  if (!m.isPage(m.open) && m.open != kImages && !unknown) {
    RC_ASSERT(composer->currentSelection().value(QLatin1String("model")).toString() == m.selected(m.open));
  }
  // The images' prompt draws with the image model picked, and is busy while one is drawn.
  if (m.open == kImages) {
    RC_ASSERT(shown.value(QStringLiteral("routeKind")).toString() == kImages);
    RC_ASSERT(shown.value(QStringLiteral("selectedInstanceId")).toString() + u'|' + shown.value(QStringLiteral("selectedModel")).toString() ==
              m.imageBy());
    RC_ASSERT(shown.value(QStringLiteral("isSendBusy")).toBool() == m.generating);
    RC_ASSERT(shown.value(QStringLiteral("canSend")).toBool() == (!m.generating && !m.targets.value(kImages).text.trimmed().isEmpty()));
  }
  RC_ASSERT(sut.generated == m.generated);
  RC_ASSERT(sut.asked == m.asked);
  RC_ASSERT(sut.written == m.written);
  if (m.isThread(m.open)) {
    RC_ASSERT(shown.value(QStringLiteral("runtimeMode")).toString() == m.runtime(m.open));
    RC_ASSERT(shown.value(QStringLiteral("interactionMode")).toString() == m.interaction(m.open));
  }
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
  // The images' prompt takes no attachments.
  void apply(Model& m) const override {
    if (m.open != kImages) ++m.targets[m.open].images;
  }
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
  void apply(Model& m) const override {
    Target& target = m.targets[m.open];
    --target.images;
    if (target.pending > 0) --target.pending;
  }
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

// Plan or default for the open thread's next sends: it goes to the MC with the
// next message, before it.
struct PickInteraction : Command {
  QString mode = pick(kInteractionModes);
  void checkPreconditions(const Model& m) const override { RC_PRE(m.isThread(m.open)); }
  void apply(Model& m) const override {
    if (mode != m.interaction(m.open)) m.targets[m.open].interaction = mode;
  }
  void run(const Model& m0, Sut& sut) const override {
    sut.bridge->dispatch(QStringLiteral("composer.interactionMode.set"), QVariantMap{{QStringLiteral("mode"), mode}});
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "PickInteraction(" << mode.toStdString() << ")"; }
};

// The MC records a model for a thread after its sends, as it does when a run
// starts on another provider than the one the thread names (orchestration.ex):
// a thread that named none names one from then on.
struct Recorded : Command {
  QString thread = pick(kThreads);
  QString model = pick(kModels);
  // Not under a send on its way or cut off, nor with rows lagging.
  void checkPreconditions(const Model& m) const override {
    RC_PRE(!m.lagging && !m.queues.contains(thread) && !m.limbo.contains(thread));
  }
  void apply(Model& m) const override { m.recorded[thread] = model; }
  void run(const Model& m0, Sut& sut) const override {
    QJsonObject row = sut.mc.threads.value(thread);
    row.insert(QStringLiteral("modelSelection"), Sut::selectionOf(model));
    sut.mc.threads.insert(thread, row);
    sut.mc.sendRow(thread, row);
    RC_ASSERT(prop::until([&] {
      const auto row = sut.native->store()->thread(keyOf(thread));
      return row && row->modelSelection.value(QLatin1String("model")).toString() == model;
    }));
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "Recorded(" << thread.toStdString() << ", " << model.toStdString() << ")"; }
};

// The thread's access, which goes to the MC at once; one the composer already
// shows changes nothing. Its answer can be held only among other access
// changes: a held send's would race it for the toasts.
struct PickRuntime : Command {
  QString mode = pick(kRuntimeModes);
  void checkPreconditions(const Model& m) const override {
    RC_PRE(m.isThread(m.open));
    RC_PRE(!m.holding || (m.held.isEmpty() && m.heldAsks.isEmpty()));
  }
  void apply(Model& m) const override {
    if (mode == m.runtime(m.open)) return;
    m.picked[m.open] = mode;
    if (!m.setting.contains(m.open) && m.runtimes.value(m.open) == mode) return;
    m.commands[m.open].append(QStringLiteral("runtime|") + mode);
    m.setting[m.open] = mode;
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
// way shows until its own answer and row have come.
struct AccessElsewhere : Command {
  QString thread = pick(kThreads);
  QString mode = pick(kRuntimeModes);
  void apply(Model& m) const override {
    if (m.lagging) {
      m.lagged.append({thread, mode});
    } else {
      m.runtimes[thread] = mode;
    }
  }
  void run(const Model& m0, Sut& sut) const override {
    QJsonObject row = sut.mc.threads.value(thread);
    row.insert(QStringLiteral("runtimeMode"), mode);
    sut.mc.threads.insert(thread, row);
    sut.mc.sendRow(thread, row);
    RC_ASSERT(m0.lagging || prop::until([&] {
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
    // A held ask's answer would race the send's for the toasts.
    RC_PRE(m.heldAsks.isEmpty());
    RC_PRE(!m.lagging);
  }
  void apply(Model& m) const override {
    Target& target = m.targets[m.open];
    if (target.text.trimmed().isEmpty() && target.images == 0) return;
    const QString delivery = !m.running.contains(m.open) ? QStringLiteral("auto")
                             : alternate                  ? QStringLiteral("queue")
                                                          : QStringLiteral("steer");
    QList<Send>& queue = m.queues[m.open];
    Send send{target.text, target.images, m.selected(m.open), delivery};
    // Only a thread that names a provider is moved off it.
    const QString provider = m.provider(m.open);
    send.switches = !provider.isEmpty() && instanceOf(send.model) != provider;
    if (const QString mode = m.interaction(m.open); mode != m.interactions.value(m.open, QStringLiteral("default"))) {
      send.interaction = mode;
    }
    queue.append(send);
    if (m.loaded.contains(m.open)) measure(m, m.open);
    m.lastModel = send.model;
    m.lastModelUnknown = false;
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
    // The images' prompt has no stash.
    if (m.open == kImages) return;
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
    target.pending = 0;
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
  // Its row would bring the access rows still lagging.
  void checkPreconditions(const Model& m) const override { RC_PRE(!m.lagging); }
  void apply(Model& m) const override {
    if (on) {
      m.running.insert(thread);
    } else {
      m.running.remove(thread);
    }
  }
  void run(const Model& m0, Sut& sut) const override {
    // Only the run changes: the thread keeps its model, modes and access.
    QJsonObject row = sut.mc.threads.value(thread);
    for (const QString field : {QStringLiteral("activeRunId"), QStringLiteral("latestRunId")}) {
      if (on) {
        row.insert(field, QStringLiteral("run-") + thread);
      } else {
        row.remove(field);
      }
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

// The MC's rows start to lag behind its answers.
struct Lag : Command {
  void checkPreconditions(const Model& m) const override { RC_PRE(!m.lagging); }
  void apply(Model& m) const override { m.lagging = true; }
  void run(const Model& m0, Sut& sut) const override {
    sut.mc.lagRows = true;
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "Lag"; }
};

// The rows that lagged come, in order: the changes they carry settle.
struct CatchUp : Command {
  void checkPreconditions(const Model& m) const override { RC_PRE(m.lagging); }
  void apply(Model& m) const override {
    m.lagging = false;
    for (const auto& [thread, mode] : std::exchange(m.lagged, {})) m.runtimes[thread] = mode;
    for (auto it = m.landing.cbegin(); it != m.landing.cend(); ++it) {
      if (m.setting.value(it.key()) != it.value()) continue;
      m.setting.remove(it.key());
      if (m.picked.value(it.key()) == it.value()) m.picked.remove(it.key());
    }
    m.landing.clear();
  }
  void run(const Model& m0, Sut& sut) const override {
    sut.mc.catchUp();
    const Model m = nextState(m0);
    RC_ASSERT(prop::until([&] {
      for (const QString& thread : kThreads) {
        const auto row = sut.native->store()->thread(keyOf(thread));
        if (!row || row->runtimeMode != m.runtimes.value(thread)) return false;
      }
      return true;
    }));
    verify(m, sut);
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
    for (const QString type : {QStringLiteral("message.dispatch"), QStringLiteral("thread.runtime-mode.set"),
                               QStringLiteral("thread.interaction-mode.set"), QStringLiteral("provider.switch")}) {
      if (on) {
        sut.mc.refusals.insert(type, QStringLiteral("The thread is busy."));
      } else {
        sut.mc.refusals.remove(type);
      }
    }
    sut.refusingAsks = on;
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
  // An access change cut off is not modelled yet (hal-c2#609), nor is an ask.
  // Lagging rows are not modelled across a reconnect, which sends them whole.
  void checkPreconditions(const Model& m) const override { RC_PRE(m.heldPicks.isEmpty() && m.heldAsks.isEmpty() && !m.lagging); }
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
  // Lagging rows are not modelled across a reconnect, which sends them whole;
  // nor is an ask or an image cut off.
  void checkPreconditions(const Model& m) const override {
    RC_PRE(m.heldPicks.isEmpty() && m.heldAsks.isEmpty() && !m.heldGeneration && !m.lagging);
  }
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

// A page of the Space, shown with its prompt.
struct OpenPage : Command {
  QString page = pick(kPages);
  void apply(Model& m) const override { m.open = page; }
  void run(const Model& m0, Sut& sut) const override {
    sut.open(page);
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "OpenPage(" << page.toStdString() << ")"; }
};

// What the user types into a page's prompt: a block's words, or an ask.
struct TypeOnPage : Command {
  Type type;
  TypeOnPage() { type.text = pick(kPageTexts); }
  void checkPreconditions(const Model& m) const override { RC_PRE(m.isPage(m.open)); }
  void apply(Model& m) const override { type.apply(m); }
  void run(const Model& m0, Sut& sut) const override { type.run(m0, sut); }
  void show(std::ostream& os) const override { os << "TypeOnPage(\"" << type.text.toStdString() << "\")"; }
};

// A send from a page's prompt: plain words write a block (SpacePage empties the
// prompt as it does, which the model leaves to it), and an image without an ask
// is refused. An ask goes to the MC with its images, one at a time.
struct SubmitOnPage : Command {
  void checkPreconditions(const Model& m) const override {
    RC_PRE(m.isPage(m.open));
    // Its answer would race a held send's or access change's for the toasts.
    RC_PRE(m.held.isEmpty() && m.heldPicks.isEmpty());
  }
  void apply(Model& m) const override {
    Target& target = m.targets[m.open];
    const QString trimmed = target.text.trimmed();
    if (!asks(trimmed)) {
      if (target.images > 0) {
        m.toasts.prepend({m.open, QString()});
      } else if (!trimmed.isEmpty()) {
        m.written.append(m.open + u'|' + trimmed);
      }
      return;
    }
    if (m.asking.contains(m.open)) return;
    m.asking.insert(m.open);
    m.lastModelUnknown = true;
    target.pending = target.images;
    const Ask ask{m.open, target.text, target.images, m.refusing};
    if (m.holding) {
      m.heldAsks.append(ask);
    } else {
      answerAsk(m, ask);
    }
  }
  void run(const Model& m0, Sut& sut) const override {
    sut.bridge->dispatch(QStringLiteral("composer.submit"),
                         QVariantMap{{QStringLiteral("edit"), sut.editOf()},
                                     {QStringLiteral("text"), m0.targets.value(m0.open).text},
                                     {QStringLiteral("intent"), QStringLiteral("foreground")}});
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "SubmitOnPage"; }
};

// The Space's images, shown with their prompt.
struct OpenImages : Command {
  void apply(Model& m) const override { m.open = kImages; }
  void run(const Model& m0, Sut& sut) const override {
    sut.open(kImages);
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "OpenImages"; }
};

// What the user asks the image to show.
struct TypeImage : Command {
  Type type;
  TypeImage() { type.text = pick(kImageTexts); }
  void checkPreconditions(const Model& m) const override { RC_PRE(m.open == kImages); }
  void apply(Model& m) const override { type.apply(m); }
  void run(const Model& m0, Sut& sut) const override { type.run(m0, sut); }
  void show(std::ostream& os) const override { os << "TypeImage(\"" << type.text.toStdString() << "\")"; }
};

// An image model from the picker; one the MC does not offer for images (a chat model) is ignored.
struct PickImageModel : Command {
  QString model = pick(kImageModels);
  void checkPreconditions(const Model& m) const override { RC_PRE(m.open == kImages); }
  void apply(Model& m) const override {
    if (model != kImageModels.last()) m.imageModel = model;
  }
  void run(const Model& m0, Sut& sut) const override {
    sut.bridge->dispatch(QStringLiteral("composer.model.select"),
                         QVariantMap{{QStringLiteral("instanceId"), model.section(u'|', 0, 0)}, {QStringLiteral("model"), model.section(u'|', 1)}});
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "PickImageModel(" << model.toStdString() << ")"; }
};

// A send from the images' prompt: an image of its words, one at a time.
struct SubmitImage : Command {
  void checkPreconditions(const Model& m) const override {
    RC_PRE(m.open == kImages);
    // Its answer would race a held send's or access change's.
    RC_PRE(m.held.isEmpty() && m.heldPicks.isEmpty());
  }
  void apply(Model& m) const override {
    const QString text = m.targets.value(kImages).text;
    if (text.trimmed().isEmpty() || m.generating) return;
    m.generating = true;
    const Generation generation{text, m.imageBy(), m.refusing};
    if (m.holding) {
      m.heldGeneration = generation;
    } else {
      answerGeneration(m, generation);
    }
  }
  void run(const Model& m0, Sut& sut) const override {
    sut.bridge->dispatch(QStringLiteral("composer.submit"),
                         QVariantMap{{QStringLiteral("edit"), sut.editOf()},
                                     {QStringLiteral("text"), m0.targets.value(m0.open).text},
                                     {QStringLiteral("intent"), QStringLiteral("foreground")}});
    verify(nextState(m0), sut);
  }
  void show(std::ostream& os) const override { os << "SubmitImage"; }
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

// The model each thread names to start with, or none.
QMap<QString, QString> recordedAtStart() {
  QMap<QString, QString> recorded;
  for (const QString& thread : kThreads) recorded.insert(thread, pick(QStringList{QString()} + kModels));
  return recorded;
}

}  // namespace

class ComposerProp : public QObject {
  Q_OBJECT

private slots:
  void composerAcrossThreads() {
    QVERIFY(rc::check("each thread keeps its own draft through sends the MC accepts, refuses or holds", [] {
      const auto recorded = recordedAtStart();
      Sut sut(recorded);
      RC_ASSERT(!sut.draftId.isEmpty());
      Model model;
      model.recorded = recorded;
      verify(model, sut);
      // Each restart starts the whole shell again: shorter runs keep a case quick.
      const auto commands = *rc::gen::scale(
          0.4, rc::state::gen::commands(model, rc::state::gen::execOneOfWithArgs<
                                                   Open, Open, Type, Type, Type, Attach, RemoveImage, PickModel, PickRuntime,
                                                   PickInteraction, Submit, Submit, Submit, Stash, RestorePrompt, SetRunning,
                                                   SetRunning, Hold, Refuse, AnswerHeld, Drop, Hold, Elsewhere, Restart, Slow,
                                                   Load, Recorded>()));
      rc::state::runAll(commands, model, sut);
    }));
  }

  // The same, crowded with sends in flight when the app quits or the
  // connection drops: each reaches the thread once, or comes back as its
  // draft (or behind a toast when the draft has newer typing), unless a newer
  // user message is there.
  void sendsCutOffByARestart() {
    QVERIFY(rc::check("a send cut off by a restart or a drop reaches the MC once or comes back, never lost or doubled", [] {
      const auto recorded = recordedAtStart();
      Sut sut(recorded);
      Model model;
      model.recorded = recorded;
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
                                                   Open, Type, Attach, PickRuntime, PickInteraction, Prompt, Prompt, Prompt, Submit,
                                                   Hold, Hold, Refuse, AnswerHeld, Elsewhere, Elsewhere, RestorePrompt, Restart,
                                                   Restart, Drop, Drop, Slow, Load>()));
      rc::state::runAll(commands, model, sut);
    }));
  }

  // The same, with sends made before their thread's messages are known: a
  // newer message from elsewhere once they are still drops them.
  void sendsWhileTheThreadLoads() {
    QVERIFY(rc::check("a send made while its thread loads is dropped by a newer message from elsewhere, else comes back", [] {
      const auto recorded = recordedAtStart();
      Sut sut(recorded);
      Model model;
      model.recorded = recorded;
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

  // The same, picking models and modes and sending often, on threads that name
  // no provider, one, or one the MC records after their sends: a thread moves
  // to another provider only when it names one and the model is not its, a
  // send's mode goes before its message, and only a provider change the MC
  // carried out counts, refused, held or cut off as the send was.
  void providerChanges() {
    QVERIFY(rc::check("a send moves its thread to the model's provider only when the thread names another", [] {
      const auto recorded = recordedAtStart();
      Sut sut(recorded);
      Model model;
      model.recorded = recorded;
      verify(model, sut);
      const auto commands = *rc::gen::scale(
          0.3, rc::state::gen::commands(model, rc::state::gen::execOneOfWithArgs<
                                                   Open, PickModel, PickModel, PickModel, PickInteraction, Prompt, Prompt, Prompt,
                                                   SetRunning, Hold, AnswerHeld, Refuse, Restart, Drop, Recorded, Recorded>()));
      rc::state::runAll(commands, model, sut);
    }));
  }

  // A Space's pages among the threads: each page's prompt keeps its own draft,
  // writes plain words as a block, and asks with words to @agent; an ask the
  // MC took empties the prompt of what it carried, a refused one keeps it all,
  // and a second ask waits for the first's answer.
  void pagePrompts() {
    QVERIFY(rc::check("each page's prompt keeps its own draft, and only an ask the MC took empties it", [] {
      const auto recorded = recordedAtStart();
      Sut sut(recorded);
      Model model;
      model.recorded = recorded;
      verify(model, sut);
      const auto commands = *rc::gen::scale(
          0.4, rc::state::gen::commands(model, rc::state::gen::execOneOfWithArgs<
                                                   Open, OpenPage, OpenPage, Type, TypeOnPage, TypeOnPage, TypeOnPage, Attach,
                                                   RemoveImage, SubmitOnPage, SubmitOnPage, SubmitOnPage, Prompt, Stash, Hold,
                                                   AnswerHeld, Refuse, Restart>()));
      rc::state::runAll(commands, model, sut);
    }));
  }

  // The Space's images among the threads and pages: their prompt keeps its own
  // words and image model, takes no attachment or stash, draws one image at a
  // time with the model picked (or the MC's), and keeps its words until the
  // image is made: a refused one leaves them to try again.
  void imagesPrompt() {
    QVERIFY(rc::check("the images' prompt draws with the image model picked, and keeps its words until the image is made", [] {
      const auto recorded = recordedAtStart();
      Sut sut(recorded);
      Model model;
      model.recorded = recorded;
      verify(model, sut);
      const auto commands = *rc::gen::scale(
          0.4, rc::state::gen::commands(model, rc::state::gen::execOneOfWithArgs<
                                                   Open, OpenPage, OpenImages, OpenImages, TypeImage, TypeImage, TypeImage,
                                                   PickImageModel, PickImageModel, SubmitImage, SubmitImage, SubmitImage, Attach,
                                                   Stash, Type, Prompt, Hold, AnswerHeld, Refuse, Restart>()));
      rc::state::runAll(commands, model, sut);
    }));
  }

  // Picking a thread's access often, with the MC holding or refusing the
  // changes and its rows lagging behind its answers: the composer shows the
  // pick while it is on its way, then what the thread really has, and a pick
  // back to the thread's access still goes.
  void accessChanges() {
    QVERIFY(rc::check("a thread takes the access picked at once, and the composer shows what the thread has", [] {
      const auto recorded = recordedAtStart();
      Sut sut(recorded);
      Model model;
      model.recorded = recorded;
      verify(model, sut);
      const auto commands = *rc::gen::scale(
          0.3, rc::state::gen::commands(model, rc::state::gen::execOneOfWithArgs<
                                                   Open, PickRuntime, PickRuntime, PickRuntime, AccessElsewhere, Prompt, SetRunning,
                                                   Hold, Hold, AnswerHeld, Refuse, Restart, Lag, CatchUp>()));
      rc::state::runAll(commands, model, sut);
    }));
  }
};

HAL_C2_PROP_MAIN(ComposerProp)
#include "tst_ComposerProp.moc"
