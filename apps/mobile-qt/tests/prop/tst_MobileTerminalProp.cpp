// The phone's terminal: TerminalController on a single screen and MobileTerminal
// on it, one thread, against a fake MC whose terminal manager behaves as the MC's
// does. The user toggles the screen, opens, picks and closes terminals, covers
// the screen with another, holds modifiers, types, pastes, clears, sizes the text
// and picks lines for the draft. Meanwhile other clients open, restart and close
// terminals, shells exit, and the connection drops, with shells exiting while it
// is down.
//
// The model is what the user should see: an uncovered screen never shows an ended
// shell. Leaving one moves to the nearest running terminal below it, else the
// first above, and with none running the screen shuts and the ended one stays
// active. A covered screen waits. An ended shell has no subscription, so what is
// typed goes nowhere. A held modifier applies to one character and goes when the
// terminal shown changes. Lines belong to the terminal they were picked from.
//
// Not covered: other threads, a darwin host's cmd key, the terminal menu's rows,
// the text size across restarts, and the screen itself (the phone's tst_Features).

#include "Prop.h"

#include <QClipboard>
#include <QDebug>
#include <QDir>
#include <QJsonArray>

#include <memory>

#include "FakeMc.h"
#include "McClient.h"
#include "MobileTerminal.h"
#include "NativeShell.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "TerminalController.h"
#include "ToastController.h"

namespace prop = halc2::prop;

namespace {

using S = QString;

const S kThread = S("t1");
const S kThreadKey = S("env-a:t1");
const S kRoot = S("/work/p1");
const S kClipboard = S("ab\ncd\te") + QChar(1);
const S kPasted = S("ab\rcd\te ");
const QChar kEscape(0x1b);

S idOf(int number) { return S("term-%1").arg(number); }

// What the user can type: the text, and what Control makes of it.
struct Typed {
  S data;
  S control;
};
const QList<Typed> kTyped{{S("a"), S(QChar(1))},
                          {S("C"), S(QChar(3))},
                          {S("["), S(QChar(0x1b))},
                          {S("?"), S(QChar(0x7f))},
                          {S("1"), S("1")},
                          {S::fromUtf8("é"), S::fromUtf8("é")},
                          {S::fromUtf8("😀"), S::fromUtf8("😀")},
                          {S("v"), S()},
                          {S("ab"), S("ab")}};

const QStringList kLines{S("$ ls"), S(), S("   "), S(32000, QLatin1Char('x')), S(64001, QLatin1Char('y'))};

struct Model {
  // By number, whether its shell has ended.
  QMap<int, bool> terms;
  bool open = false;
  int active = 0;
  bool attached = false;
  bool covered = false;
  S held;
  int heldFor = 0;
  QStringList writes;
  double textSize = mobileterminal::kDefaultTextSize;
  bool choosing = false;
  QStringList lines;
  int start = 0;
  int end = 0;
  int anchor = -1;
  int contextFor = 0;
  QStringList contexts;

  QList<int> live() const {
    QList<int> running;
    for (auto it = terms.cbegin(); it != terms.cend(); ++it) {
      if (!it.value()) running.append(it.key());
    }
    return running;
  }
  bool running(int id) const { return terms.contains(id) && !terms.value(id); }
  bool hasSession() const { return attached && running(active); }
  int shown() const { return active ? active : terms.isEmpty() ? 0 : terms.firstKey(); }
  int nextId() const {
    int next = 1;
    while (terms.contains(next)) ++next;
    return next;
  }

  void settle() {
    if (terms.isEmpty()) open = false;
    if (!covered) {
      const QList<int> running = live();
      if (open && !running.contains(active)) {
        // Nothing active is after them all.
        int next = running.isEmpty() ? 0 : running.constFirst();
        for (const int id : running) {
          if (!active || id < active) next = id;
        }
        if (next) {
          active = next;
        } else {
          open = false;
        }
      }
      if (!terms.contains(active)) active = running.isEmpty() ? 0 : running.constFirst();
    }
    attached = attached || open;
    if (!held.isEmpty() && heldFor != shown()) held.clear();
  }
  void openTerminal(int id) {
    terms[id] = false;
    active = id;
    open = true;
    settle();
  }
  void toggle() {
    if (open) {
      open = false;
      settle();
      return;
    }
    const QList<int> running = live();
    const int first = !running.isEmpty() ? running.constFirst() : !terms.isEmpty() ? terms.firstKey() : nextId();
    openTerminal(running.contains(active) || (running.isEmpty() && terms.contains(active)) ? active : first);
  }
  void close(int id) {
    terms.remove(id);
    if (active == id) active = 0;
    settle();
  }
  S contextText() const { return lines.mid(start, end - start + 1).join(QLatin1Char('\n')); }
};

template <typename T>
void same(const char* what, const T& actual, const T& expected) {
  if (actual == expected) return;
  S message;
  QDebug(&message) << what << "is" << actual << "and should be" << expected;
  RC_FAIL(message.toStdString());
}

// The phone as MobileApp wires it, on a fake MC with one thread, and the MC's
// terminal manager.
struct Sut {
  QTemporaryDir home{QDir::tempPath() + S("/mobile-terminals-XXXXXX")};
  FakeMc mc;
  QMap<int, bool> terms;
  QStringList writes;
  std::unique_ptr<ShellBridge> bridge;
  std::unique_ptr<NativeShell> native;
  std::unique_ptr<MobileTerminal> terminal;
  QObject barrier;

  Sut() {
    TerminalSession::setAckDelay(0);
    QGuiApplication::clipboard()->setText(kClipboard);
    mc.projects.insert(S("p1"), QJsonObject{{S("id"), S("p1")},
                                            {S("title"), S("p1")},
                                            {S("workspaceRoot"), kRoot},
                                            {S("createdAt"), S("2026-09-01T09:00:00Z")},
                                            {S("updatedAt"), S("2026-09-01T09:00:00Z")},
                                            {S("scripts"), QJsonArray()}});
    mc.threads.insert(kThread, QJsonObject{{S("id"), kThread},
                                           {S("projectId"), S("p1")},
                                           {S("title"), kThread},
                                           {S("worktreePath"), QJsonValue::Null},
                                           {S("createdAt"), S("2026-09-23T09:00:00Z")},
                                           {S("updatedAt"), S("2026-09-23T09:00:00Z")}});
    mc.onShape(S("terminals"), [this](int id, const QJsonObject&) {
      QJsonArray list;
      for (auto it = terms.cbegin(); it != terms.cend(); ++it) list.append(summary(it.key()));
      mc.send({{S("t"), S("terminals")}, {S("id"), id}, {S("event"), QJsonObject{{S("type"), S("snapshot")}, {S("terminals"), list}}}});
    });
    // HalC2.Terminal.attach: a terminal that is not there opens when the input has a cwd.
    mc.onShape(S("terminal"), [this](int id, const QJsonObject& shape) {
      const QJsonObject input = shape.value(QLatin1String("input")).toObject();
      const int number = numberOf(input.value(QLatin1String("terminalId")).toString());
      if (!terms.contains(number)) {
        terms.insert(number, false);
        sendList({{S("type"), S("upsert")}, {S("terminal"), summary(number)}});
      }
      QJsonObject snapshot = summary(number);
      snapshot.insert(S("history"), S("$ "));
      snapshot.insert(S("sequence"), 0);
      mc.send({{S("t"), S("terminal")}, {S("id"), id}, {S("event"), QJsonObject{{S("type"), S("snapshot")}, {S("snapshot"), snapshot}}}});
    });
    mc.onRpc(S("terminal.open"), [this](const FakeMc::Rpc& rpc) {
      const int number = numberOf(rpc.payload.value(QLatin1String("terminalId")).toString());
      terms.insert(number, false);
      sendList({{S("type"), S("upsert")}, {S("terminal"), summary(number)}});
      mc.reply(rpc, QJsonValue::Null);
    });
    mc.onRpc(S("terminal.close"), [this](const FakeMc::Rpc& rpc) {
      closeShell(numberOf(rpc.payload.value(QLatin1String("terminalId")).toString()));
      mc.reply(rpc, QJsonValue::Null);
    });
    mc.onRpc(S("terminal.write"), [this](const FakeMc::Rpc& rpc) {
      writes.append(rpc.payload.value(QLatin1String("terminalId")).toString() + QLatin1Char(':') + rpc.payload.value(QLatin1String("data")).toString());
      mc.reply(rpc, QJsonValue::Null);
    });
    mc.onRpc(S("terminal.clear"), [this](const FakeMc::Rpc& rpc) {
      writes.append(rpc.payload.value(QLatin1String("terminalId")).toString() + S(":<clear>"));
      mc.reply(rpc, QJsonValue::Null);
    });
    mc.onRpc(S("terminal.resize"), [this](const FakeMc::Rpc& rpc) { mc.reply(rpc, QJsonValue::Null); });

    bridge = std::make_unique<ShellBridge>();
    native = std::make_unique<NativeShell>(bridge.get());
    native->client()->setRetryDelays({20});
    native->setStoreDirs(home.filePath(S("state")), home.filePath(S("data")), home.filePath(S("cache")));
    native->controller<SettingsController>()->setDevicePath(home.filePath(S("config/preferences.json")));
    native->restoreWindows();
    terminals()->setSingleScreen(true);
    terminal = std::make_unique<MobileTerminal>(bridge.get(), native.get(), home.filePath(S("config/terminal.json")));
    native->open(mc.origin(), S("mc-token"));
    RC_ASSERT(prop::until([this] { return online(); }));
    bridge->dispatch(S("thread.open"), QVariantMap{{S("key"), kThreadKey}});
    RC_ASSERT(sync());
  }

  ~Sut() {
    TerminalSession::setAckDelay();
    terminal.reset();
    native.reset();
    bridge.reset();
  }

  TerminalController* terminals() const { return native->controller<TerminalController>(); }

  bool online() const { return native->isActive() && native->client()->isReady() && mc.connected() && native->store()->threadOnline(kThreadKey); }

  // Once this is back, what the client sent has reached the MC, and what the
  // MC sent before it has been read; deleted sessions have let go of their terminals.
  bool sync() {
    for (int round = 0; round < 3; ++round) {
      prop::settle();
      auto answered = std::make_shared<bool>(false);
      native->client()->call(&barrier, {}, S("test.barrier"), {}, [answered](const QJsonValue&, const std::optional<QString>&) { *answered = true; });
      if (!prop::until([&] { return *answered; })) return false;
    }
    prop::settle();
    return true;
  }

  static int numberOf(const QString& id) { return id.mid(5).toInt(); }

  QJsonObject summary(int number) const {
    return {{S("threadId"), kThread},
            {S("terminalId"), idOf(number)},
            {S("cwd"), kRoot},
            {S("status"), terms.value(number) ? S("exited") : S("running")},
            {S("hasRunningSubprocess"), false},
            {S("label"), S()}};
  }
  void sendList(const QJsonObject& event) {
    for (const int id : mc.subscribers(S("terminals"))) mc.send({{S("t"), S("terminals")}, {S("id"), id}, {S("event"), event}});
  }
  void sendTerminal(int number, const QJsonObject& event) {
    for (const int id : mc.subscribers(S("terminal"))) {
      if (mc.shapeOf(id).value(QLatin1String("input")).toObject().value(QLatin1String("terminalId")).toString() != idOf(number)) continue;
      mc.send({{S("t"), S("terminal")}, {S("id"), id}, {S("event"), event}});
    }
  }
  void closeShell(int number) {
    if (!terms.remove(number)) return;
    sendTerminal(number, {{S("type"), S("closed")}});
    sendList({{S("type"), S("remove")}, {S("threadId"), kThread}, {S("terminalId"), idOf(number)}});
  }
  void exitShell(int number) {
    terms[number] = true;
    sendTerminal(number, {{S("type"), S("exited")}});
    sendList({{S("type"), S("upsert")}, {S("terminal"), summary(number)}});
  }

  QVariantMap published() const { return bridge->state()->value(S("mobileTerminal")).toMap(); }

  void check(const Model& expected) {
    RC_ASSERT(sync());
    same("the screen being open", terminals()->isOpen(), expected.open);
    same("the active terminal", terminals()->activeTerminalId(), expected.active ? idOf(expected.active) : S());

    QStringList listed;
    for (const QVariant& value : terminals()->listing()) {
      const QVariantMap row = value.toMap();
      listed.append(row.value(S("terminalId")).toString() + QLatin1Char(' ') + row.value(S("status")).toString());
    }
    QStringList owed;
    for (auto it = expected.terms.cbegin(); it != expected.terms.cend(); ++it) owed.append(idOf(it.key()) + (it.value() ? S(" exited") : S(" running")));
    same("the listing", listed, owed);

    same("having a session", terminals()->activeSession() != nullptr, expected.hasSession());
    // An ended shell has no subscription, and every running one has one once attached.
    QStringList subscribed;
    for (const int id : mc.subscribers(S("terminal"))) {
      subscribed.append(mc.shapeOf(id).value(QLatin1String("input")).toObject().value(QLatin1String("terminalId")).toString());
    }
    subscribed.sort();
    QStringList attached;
    if (expected.attached) {
      for (const int id : expected.live()) attached.append(idOf(id));
      attached.sort();
    }
    same("the subscriptions", subscribed, attached);

    same("what the MC was sent", writes, expected.writes);
    const QVariantMap state = published();
    same("the held modifier", state.value(S("held")).toString(), expected.held);
    same("the text size", state.value(S("textSize")).toDouble(), expected.textSize);
    // A covered screen keeps the terminal it had, gone or not; there is nothing to say of a gone one.
    const bool named = expected.terms.contains(expected.shown());
    same("the terminal's name", state.value(S("terminal")).toString(), named ? S("Terminal %1").arg(expected.shown()) : S());
    same("the terminal's state", state.value(S("label")).toString(), !named ? S("Not started") : expected.terms.value(expected.shown()) ? S("Exited") : S("Ready"));

    const QVariant context = state.value(S("context"));
    same("choosing lines", context.typeId() == QMetaType::QVariantMap, expected.choosing);
    if (expected.choosing) {
      const QVariantMap chosen = context.toMap();
      same("the lines", chosen.value(S("lines")).toStringList(), expected.lines);
      same("the first line", chosen.value(S("start")).toInt(), expected.start);
      same("the last line", chosen.value(S("end")).toInt(), expected.end);
      RC_ASSERT(expected.start >= 0 && expected.start <= expected.end && expected.end < expected.lines.size());
      same("being too large", chosen.value(S("tooLarge")).toBool(), expected.contextText().size() > mobileterminal::kMaxContextChars);
    }
    QStringList contexts;
    const QVariantMap composer = bridge->state()->value(S("composer")).toMap();
    for (const QVariant& value : composer.value(S("terminalContexts")).toList()) {
      const QVariantMap row = value.toMap();
      contexts.append(S("%1 %2-%3").arg(row.value(S("label")).toString()).arg(row.value(S("lineStart")).toInt()).arg(row.value(S("lineEnd")).toInt()));
    }
    same("the draft's lines", contexts, expected.contexts);
  }
};

using Command = rc::state::Command<Model, Sut>;

template <typename Self>
struct Step : Command {
  void run(const Model& before, Sut& sut) const override {
    Model expected = before;
    apply(expected);
    static_cast<const Self*>(this)->act(before, sut);
    sut.check(expected);
  }
};

rc::Gen<int> anyTerminal() { return rc::gen::inRange(1, 5); }

// --- The user ----------------------------------------------------------------------

struct Toggle : Step<Toggle> {
  explicit Toggle(const Model&) {}
  void apply(Model& model) const override { model.toggle(); }
  void act(const Model&, Sut& sut) const { sut.bridge->dispatch(S("terminal.toggle")); }
  void show(std::ostream& os) const override { os << "toggle the screen"; }
};

struct New : Step<New> {
  explicit New(const Model&) {}
  void apply(Model& model) const override {
    if (model.live().size() < TerminalController::maxTerminals) model.openTerminal(model.nextId());
  }
  void act(const Model&, Sut& sut) const { sut.bridge->dispatch(S("terminal.new")); }
  void show(std::ostream& os) const override { os << "open a new terminal"; }
};

struct Select : Step<Select> {
  int id = *anyTerminal();
  explicit Select(const Model&) {}
  void apply(Model& model) const override {
    if (model.terms.contains(id)) model.openTerminal(id);
  }
  void act(const Model&, Sut& sut) const { sut.bridge->dispatch(S("terminal.select"), QVariantMap{{S("terminalId"), idOf(id)}}); }
  void show(std::ostream& os) const override { os << "pick term-" << id; }
};

struct Close : Step<Close> {
  int id = *anyTerminal();
  explicit Close(const Model&) {}
  void apply(Model& model) const override {
    if (model.terms.contains(id)) model.close(id);
  }
  void act(const Model& before, Sut& sut) const {
    sut.bridge->dispatch(S("terminal.close"), QVariantMap{{S("terminalId"), idOf(id)}});
    if (!before.terms.contains(id)) return;
    sut.bridge->dispatch(S("confirmation.answer"),
                         QVariantMap{{S("requestId"), sut.bridge->state()->value(S("confirmation")).toMap().value(S("requestId"))}, {S("accepted"), true}});
  }
  void show(std::ostream& os) const override { os << "close term-" << id; }
};

struct Cover : Step<Cover> {
  bool covered = *rc::gen::arbitrary<bool>();
  explicit Cover(const Model&) {}
  void apply(Model& model) const override {
    model.covered = covered;
    model.settle();
  }
  void act(const Model&, Sut& sut) const { sut.bridge->dispatch(S("mobileTerminal.covered"), QVariantMap{{S("covered"), covered}}); }
  void show(std::ostream& os) const override { os << (covered ? "cover the screen" : "uncover the screen"); }
};

struct Modifier : Step<Modifier> {
  S key = *rc::gen::elementOf(std::vector<S>{S("ctrl"), S("alt")});
  explicit Modifier(const Model&) {}
  void apply(Model& model) const override {
    model.held = model.held == key ? S() : key;
    model.heldFor = model.shown();
  }
  void act(const Model&, Sut& sut) const { sut.bridge->dispatch(S("mobileTerminal.modifier"), QVariantMap{{S("key"), key}}); }
  void show(std::ostream& os) const override { os << "press " << key.toStdString(); }
};

struct Type : Step<Type> {
  Typed typed = *rc::gen::elementOf(std::vector<Typed>(kTyped.begin(), kTyped.end()));
  explicit Type(const Model&) {}
  void apply(Model& model) const override {
    if (!model.hasSession()) return;
    const S to = idOf(model.active) + QLatin1Char(':');
    const bool one = typed.data != S("ab");
    if (model.held.isEmpty() || !one) {
      model.writes.append(to + typed.data);
      return;
    }
    const S held = std::exchange(model.held, S());
    if (held == S("alt")) {
      model.writes.append(to + kEscape + typed.data);
    } else if (typed.data == S("v")) {
      model.writes.append(to + kPasted);
    } else {
      model.writes.append(to + typed.control);
    }
  }
  void act(const Model&, Sut& sut) const { sut.bridge->dispatch(S("mobileTerminal.input"), QVariantMap{{S("data"), typed.data}}); }
  void show(std::ostream& os) const override { os << "type " << typed.data.toStdString(); }
};

struct Paste : Step<Paste> {
  explicit Paste(const Model&) {}
  void apply(Model& model) const override {
    if (model.hasSession()) model.writes.append(idOf(model.active) + QLatin1Char(':') + kPasted);
  }
  void act(const Model&, Sut& sut) const { sut.bridge->dispatch(S("mobileTerminal.paste")); }
  void show(std::ostream& os) const override { os << "paste"; }
};

struct Clear : Step<Clear> {
  explicit Clear(const Model&) {}
  void apply(Model& model) const override {
    if (!model.hasSession()) return;
    model.held.clear();
    model.writes.append(idOf(model.active) + S(":<clear>"));
  }
  void act(const Model&, Sut& sut) const { sut.bridge->dispatch(S("mobileTerminal.clear")); }
  void show(std::ostream& os) const override { os << "clear"; }
};

struct TextSize : Step<TextSize> {
  double points = *rc::gen::inRange(0, 40) * 0.5;
  explicit TextSize(const Model&) {}
  void apply(Model& model) const override { model.textSize = std::clamp(points, mobileterminal::kMinTextSize, mobileterminal::kMaxTextSize); }
  void act(const Model&, Sut& sut) const { sut.bridge->dispatch(S("mobileTerminal.textSize"), QVariantMap{{S("points"), points}}); }
  void show(std::ostream& os) const override { os << "text size " << points; }
};

struct ContextOpen : Step<ContextOpen> {
  std::vector<S> lines = *rc::gen::container<std::vector<S>>(*rc::gen::inRange(0, 5), rc::gen::elementOf(std::vector<S>(kLines.begin(), kLines.end())));
  explicit ContextOpen(const Model&) {}
  QStringList list() const { return QStringList(lines.begin(), lines.end()); }
  void apply(Model& model) const override {
    QStringList kept = list();
    while (!kept.isEmpty() && kept.constLast().trimmed().isEmpty()) kept.removeLast();
    if (kept.isEmpty()) return;
    model.choosing = true;
    model.lines = kept;
    model.start = 0;
    model.end = int(kept.size()) - 1;
    model.anchor = -1;
    model.contextFor = model.shown();
  }
  void act(const Model&, Sut& sut) const { sut.bridge->dispatch(S("mobileTerminal.context.open"), QVariantMap{{S("lines"), list()}}); }
  void show(std::ostream& os) const override { os << "add visible lines, " << lines.size(); }
};

struct ContextTap : Step<ContextTap> {
  int index = *rc::gen::inRange(-1, 6);
  explicit ContextTap(const Model&) {}
  void apply(Model& model) const override {
    if (!model.choosing || index < 0 || index >= model.lines.size()) return;
    if (model.anchor < 0) {
      model.anchor = model.start = model.end = index;
    } else {
      model.start = std::min(model.anchor, index);
      model.end = std::max(model.anchor, index);
      model.anchor = -1;
    }
  }
  void act(const Model&, Sut& sut) const { sut.bridge->dispatch(S("mobileTerminal.context.tap"), QVariantMap{{S("index"), index}}); }
  void show(std::ostream& os) const override { os << "tap line " << index; }
};

struct ContextAttach : Step<ContextAttach> {
  explicit ContextAttach(const Model&) {}
  void apply(Model& model) const override {
    if (!model.choosing) return;
    const S text = model.contextText();
    if (text.trimmed().isEmpty() || text.size() > mobileterminal::kMaxContextChars) return;
    if (model.contextFor) model.contexts.append(S("Terminal %1 (visible output) %2-%3").arg(model.contextFor).arg(model.start + 1).arg(model.end + 1));
    model.choosing = false;
    if (model.open) model.toggle();
  }
  void act(const Model&, Sut& sut) const { sut.bridge->dispatch(S("mobileTerminal.context.attach")); }
  void show(std::ostream& os) const override { os << "attach the lines"; }
};

struct ContextCancel : Step<ContextCancel> {
  explicit ContextCancel(const Model&) {}
  void apply(Model& model) const override { model.choosing = false; }
  void act(const Model&, Sut& sut) const { sut.bridge->dispatch(S("mobileTerminal.context.cancel")); }
  void show(std::ostream& os) const override { os << "cancel the lines"; }
};

// --- Everyone else -----------------------------------------------------------------

struct Exit : Step<Exit> {
  int id = *anyTerminal();
  explicit Exit(const Model& model) { RC_PRE(model.running(id)); }
  void checkPreconditions(const Model& model) const override { RC_PRE(model.running(id)); }
  void apply(Model& model) const override {
    model.terms[id] = true;
    model.settle();
  }
  void act(const Model&, Sut& sut) const { sut.exitShell(id); }
  void show(std::ostream& os) const override { os << "term-" << id << "'s shell exits"; }
};

struct OpenElsewhere : Step<OpenElsewhere> {
  int id = *anyTerminal();
  explicit OpenElsewhere(const Model& model) { RC_PRE(!model.running(id)); }
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.running(id)); }
  void apply(Model& model) const override {
    model.terms[id] = false;
    model.settle();
  }
  void act(const Model&, Sut& sut) const {
    sut.terms[id] = false;
    sut.sendList({{S("type"), S("upsert")}, {S("terminal"), sut.summary(id)}});
  }
  void show(std::ostream& os) const override { os << "term-" << id << " starts on another device"; }
};

struct CloseElsewhere : Step<CloseElsewhere> {
  int id = *anyTerminal();
  explicit CloseElsewhere(const Model& model) { RC_PRE(model.terms.contains(id)); }
  void checkPreconditions(const Model& model) const override { RC_PRE(model.terms.contains(id)); }
  void apply(Model& model) const override {
    model.terms.remove(id);
    model.settle();
  }
  void act(const Model&, Sut& sut) const { sut.closeShell(id); }
  void show(std::ostream& os) const override { os << "term-" << id << " closes on another device"; }
};

// The connection drops, and a shell may exit before it is back.
struct Drop : Step<Drop> {
  int id = *rc::gen::inRange(0, 5);
  explicit Drop(const Model&) {}
  bool exits(const Model& model) const { return model.running(id); }
  void apply(Model& model) const override {
    if (!exits(model)) return;
    model.terms[id] = true;
    model.settle();
  }
  void act(const Model& before, Sut& sut) const {
    sut.mc.drop();
    if (exits(before)) sut.terms[id] = true;
    RC_ASSERT(prop::until([&] { return sut.online() && !sut.mc.subscribers(S("terminals")).isEmpty(); }));
  }
  void show(std::ostream& os) const override { os << "the connection drops, term-" << id << " exiting if it runs"; }
};

}  // namespace

class MobileTerminalProp : public QObject {
  Q_OBJECT

private slots:
  void screen() {
    QVERIFY(rc::check("a single screen shows no ended shell, and falls back as the user was promised", [] {
      Sut sut;
      const auto commands = *rc::gen::scale(
          0.5, rc::state::gen::commands(Model(), rc::state::gen::execOneOfWithArgs<Toggle, New, New, Select, Select, Close, Cover, Exit, Exit, OpenElsewhere,
                                                                                    CloseElsewhere, Drop>()));
      rc::state::runAll(commands, Model(), sut);
    }));
  }

  void keys() {
    QVERIFY(rc::check("a held modifier applies to one character of the terminal it was pressed in", [] {
      Sut sut;
      const auto commands = *rc::gen::scale(
          0.5, rc::state::gen::commands(Model(), rc::state::gen::execOneOfWithArgs<Toggle, New, Select, Exit, OpenElsewhere, Modifier, Modifier, Type, Type, Type,
                                                                                    Paste, Clear, TextSize>()));
      rc::state::runAll(commands, Model(), sut);
    }));
  }

  void lines() {
    QVERIFY(rc::check("the lines picked for the draft are in range and say whose they are", [] {
      Sut sut;
      const auto commands = *rc::gen::scale(
          0.5, rc::state::gen::commands(Model(), rc::state::gen::execOneOfWithArgs<Toggle, New, Exit, CloseElsewhere, ContextOpen, ContextOpen, ContextTap, ContextTap,
                                                                                    ContextTap, ContextAttach, ContextCancel>()));
      rc::state::runAll(commands, Model(), sut);
    }));
  }
};

HAL_C2_PROP_MAIN(MobileTerminalProp)
#include "tst_MobileTerminalProp.moc"
