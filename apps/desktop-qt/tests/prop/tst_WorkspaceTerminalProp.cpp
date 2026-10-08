// TerminalController: the drawer's terminals across three threads, against a
// fake MC whose terminal manager behaves as the MC's does (HalC2.Terminal:
// attaching with a cwd opens a terminal that is not there yet). The user
// switches thread, toggles the drawer, opens, picks, focuses, splits and
// closes terminals. Meanwhile other clients open, rename and close terminals,
// shells print, exit and restart, output arrives for terminals that are
// gone, the MC holds closes and answers them late, a thread moves to a
// worktree, and the connection drops and comes back.
//
// The model is what the user should see: the shown thread's tabs in order
// with their labels, groups and current one; an open drawer always shows a
// terminal that exists; each tab's screen is what its shell printed; the
// terminals of threads the user left stay attached and keep printing; the
// MC is never asked to attach a terminal nobody shows, and so never reopens
// one that was closed. `changed` fires once when what it notifies changes
// and never otherwise.
//
// Not covered: the right panel's terminal tabs (addPanelGroup), project
// scripts (runScript), the store across restarts, links, writes and resizes,
// and more than maxParkedThreads threads.

#include "Prop.h"
#include "WorkspaceModels.h"

#include <QJsonArray>
#include <QSignalSpy>

#include <memory>

#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "TerminalController.h"
#include "ToastController.h"

namespace prop = halc2::prop;

namespace {

rc::Gen<QString> oneOf(const QStringList& values) { return rc::gen::elementOf(std::vector<QString>(values.begin(), values.end())); }

const QString kEnvironment = QStringLiteral("env-a");
const QStringList kThreads{QStringLiteral("t1"), QStringLiteral("t2"), QStringLiteral("t3")};
const QStringList kIds{QStringLiteral("term-1"), QStringLiteral("term-2"), QStringLiteral("term-3"), QStringLiteral("term-4"),
                       QStringLiteral("term-5")};
const QStringList kLabels{QString(), QStringLiteral(" build "), QStringLiteral("server")};
const QString kRoot = QStringLiteral("/work/p1");
const QString kWorktree = QStringLiteral("/work/p1-wt");
// What a session says in its terminal when its shell exits.
const QString kExited = QStringLiteral("\r\n[process exited]\r\n");
// What a restarted shell starts with.
const QString kPrompt = QStringLiteral("$ ");

QString threadKeyOf(const QString& thread) { return kEnvironment + QLatin1Char(':') + thread; }
QString keyOf(const QString& thread, const QString& id) { return thread + QLatin1Char('/') + id; }
QString threadOf(const QString& key) { return key.section(QLatin1Char('/'), 0, 0); }
QString idOf(const QString& key) { return key.section(QLatin1Char('/'), 1); }

int number(const QString& id) { return id.startsWith(QLatin1String("term-")) ? id.mid(5).toInt() : -1; }

// packages/shared terminalLabels.
QString labelOf(const QString& id, const QString& label) {
  return label.trimmed().isEmpty() ? QStringLiteral("Terminal %1").arg(number(id)) : label.trimmed();
}

// A terminal the MC runs.
struct Term {
  QString label;
  bool busy = false;
  QString history;
  bool exited = false;
  bool operator==(const Term&) const = default;
};

void showValue(const Term& term, std::ostream& os) {
  os << "{label '" << term.label.toStdString() << "'" << (term.busy ? " busy" : "") << (term.exited ? " exited" : "") << " history ";
  rc::show(term.history.toStdString(), os);
  os << "}";
}

// By "thread/terminal".
using Terms = QMap<QString, Term>;

struct Group {
  QString id;
  QStringList terminals;
  bool vertical = false;
  QString active;
};

// A thread's drawer.
struct Ui {
  bool open = false;
  QString active;
  QList<Group> groups;
  // Closes the MC has not answered.
  QSet<QString> closing;
};

// What a tab shows.
struct Row {
  QString id;
  QString label;
  bool busy = false;
  QString group;
  int slot = 0;
  int span = 1;
  bool vertical = false;
  bool current = false;
  QString transcript;
  bool operator==(const Row&) const = default;
};

void showValue(const Row& row, std::ostream& os) {
  os << "{" << row.id.toStdString() << " '" << row.label.toStdString() << "'" << (row.busy ? " busy" : "") << " in "
     << row.group.toStdString() << " " << row.slot << "/" << row.span << (row.vertical ? " vertical" : "") << (row.current ? " current" : "")
     << " screen ";
  rc::show(row.transcript.toStdString(), os);
  os << "}";
}

// What `changed` notifies.
struct Facts {
  bool open = false;
  QString active;
  QString activeGroup;
  QVariantMap groupSizes;
  bool operator==(const Facts&) const = default;
};

void showValue(const Facts& facts, std::ostream& os) {
  os << "{" << (facts.open ? "open" : "closed") << " on '" << facts.active.toStdString() << "' in '" << facts.activeGroup.toStdString()
     << "' groups " << prop::debug(facts.groupSizes) << "}";
}

struct Model {
  Terms mc;
  // Threads checked out on the worktree rather than the project root.
  QSet<QString> worktree;
  QMap<QString, Ui> ui;
  QString thread = kThreads.first();
  // Where the shown thread's terminals were placed.
  QString placedCwd = kRoot;
  // The shown thread's terminals are attached, and the tabs it shows.
  bool attached = false;
  QStringList tabs;
  QString focused;
  // The attached sessions of threads the user left, and where they ran.
  QMap<QString, QStringList> parked;
  QMap<QString, QString> parkedCwd;
  // What each attached session's screen shows, by "thread/terminal".
  QMap<QString, QString> screens;
  bool holding = false;
  // Closes the MC holds, oldest first.
  QStringList held;
  int groupCount = 0;
  int serial = 0;

  QString cwd(const QString& of) const { return worktree.contains(of) ? kWorktree : kRoot; }

  // The thread's terminals the user sees, in order.
  QStringList ids(const QString& of) const {
    QStringList out;
    for (auto it = mc.cbegin(); it != mc.cend(); ++it) {
      if (threadOf(it.key()) == of && !ui.value(of).closing.contains(idOf(it.key()))) out.append(idOf(it.key()));
    }
    std::sort(out.begin(), out.end(), [](const QString& a, const QString& b) { return number(a) < number(b); });
    return out;
  }
  QStringList terminalsOf(const QString& of) const {
    QStringList out;
    for (auto it = mc.cbegin(); it != mc.cend(); ++it) {
      if (threadOf(it.key()) == of) out.append(idOf(it.key()));
    }
    return out;
  }
  // The lowest free id; ids still closing stay taken.
  QString nextId() const {
    const QStringList taken = terminalsOf(thread);
    const QSet<QString> closing = ui.value(thread).closing;
    int next = 1;
    while (taken.contains(QStringLiteral("term-%1").arg(next)) || closing.contains(QStringLiteral("term-%1").arg(next))) ++next;
    return QStringLiteral("term-%1").arg(next);
  }
  static Group* groupOf(Ui& of, const QString& id) {
    for (Group& group : of.groups) {
      if (group.terminals.contains(id)) return &group;
    }
    return nullptr;
  }
  static const Group* groupOf(const Ui& of, const QString& id) {
    for (const Group& group : of.groups) {
      if (group.terminals.contains(id)) return &group;
    }
    return nullptr;
  }

  QStringList live() const {
    QStringList keys;
    if (attached) {
      for (const QString& id : tabs) keys.append(keyOf(thread, id));
    }
    for (auto it = parked.cbegin(); it != parked.cend(); ++it) {
      for (const QString& id : it.value()) keys.append(keyOf(it.key(), id));
    }
    std::sort(keys.begin(), keys.end());
    return keys;
  }

  // The shown thread's drawer and tabs, brought in line with its terminals.
  void sync() {
    Ui& u = ui[thread];
    const QStringList now = ids(thread);
    for (auto it = u.groups.begin(); it != u.groups.end();) {
      it->terminals.removeIf([&now](const QString& id) { return !now.contains(id); });
      if (!it->terminals.contains(it->active)) it->active = it->terminals.isEmpty() ? QString() : it->terminals.constLast();
      it = it->terminals.isEmpty() ? u.groups.erase(it) : std::next(it);
    }
    // An open drawer shows a terminal; with none left it hides.
    if (u.open && now.isEmpty()) u.open = false;
    if (!now.contains(u.active)) u.active = now.isEmpty() ? QString() : now.constLast();
    if (u.open || attached) {
      attached = true;
      const QStringList kept = parked.take(thread);
      parkedCwd.remove(thread);
      for (const QString& id : now) {
        // A new session attaches: its screen is the history.
        if (!tabs.contains(id) && !kept.contains(id)) screens[keyOf(thread, id)] = mc.value(keyOf(thread, id)).history;
      }
      tabs = now;
    }
    const QStringList keys = live();
    for (auto it = screens.begin(); it != screens.end();) it = keys.contains(it.key()) ? std::next(it) : screens.erase(it);
  }

  // The route's thread or its checkout changed.
  void refresh(const QString& next) {
    if (next != thread || cwd(next) != placedCwd) {
      if (next != thread && attached && !tabs.isEmpty()) {
        parked[thread] = tabs;
        parkedCwd[thread] = placedCwd;
      }
      tabs.clear();
      attached = false;
      focused.clear();
      if (parked.contains(next)) {
        if (parkedCwd.value(next) == cwd(next)) {
          attached = true;
          tabs = parked.value(next);
        }
        parked.remove(next);
        parkedCwd.remove(next);
      }
    }
    thread = next;
    placedCwd = cwd(next);
    sync();
  }

  // A terminal the shown thread opens: attaching opens it on the MC.
  void opened(const QString& id) { mc.insert(keyOf(thread, id), {}); }

  void openTerminal(const QString& id) {
    Ui& u = ui[thread];
    if (!ids(thread).contains(id)) opened(id);
    u.active = id;
    u.open = true;
    sync();
  }

  void close(const QString& id) {
    Ui& u = ui[thread];
    u.closing.insert(id);
    if (Group* group = groupOf(u, id)) {
      group->terminals.removeOne(id);
      if (group->active == id) group->active = group->terminals.isEmpty() ? QString() : group->terminals.constLast();
      if (u.active == id) u.active = group->active;
    } else if (u.active == id) {
      u.active.clear();
    }
    if (ids(thread).isEmpty()) u.open = false;
    if (holding) {
      held.append(keyOf(thread, id));
    } else {
      closed(keyOf(thread, id));
    }
    sync();
  }

  // The MC answered the user's close.
  void closed(const QString& key) {
    ui[threadOf(key)].closing.remove(idOf(key));
    gone(key);
  }

  // The MC closed the terminal and said so. A close of the user's it has not
  // answered keeps the id taken, so the answer cannot close a new one.
  void gone(const QString& key) {
    mc.remove(key);
    // A session whose terminal is gone is no use to anyone.
    if (parked.contains(threadOf(key))) {
      parked[threadOf(key)].removeAll(idOf(key));
      if (parked.value(threadOf(key)).isEmpty()) {
        parked.remove(threadOf(key));
        parkedCwd.remove(threadOf(key));
      }
    }
    sync();
  }

  Facts facts() const {
    Facts out;
    const Ui u = ui.value(thread);
    out.open = u.open;
    out.active = u.active;
    if (!u.active.isEmpty()) {
      const Group* group = groupOf(u, u.active);
      out.activeGroup = group ? group->id : u.active;
    }
    for (const Group& group : u.groups) out.groupSizes.insert(group.id, int(group.terminals.size()));
    return out;
  }

  QList<Row> rows() const {
    QList<Row> out;
    if (!attached) return out;
    const Ui u = ui.value(thread);
    for (const QString& id : tabs) {
      const Term term = mc.value(keyOf(thread, id));
      Row row{id, labelOf(id, term.label), term.busy, id};
      if (const Group* group = groupOf(u, id)) {
        row.group = group->id;
        row.slot = int(group->terminals.indexOf(id));
        row.span = int(group->terminals.size());
        row.vertical = group->vertical;
      }
      row.current = u.active == id;
      row.transcript = screens.value(keyOf(thread, id));
      out.append(row);
    }
    return out;
  }
};

QJsonObject threadRow(const QString& id, bool worktree) {
  return {{QStringLiteral("id"), id},
          {QStringLiteral("projectId"), QStringLiteral("p1")},
          {QStringLiteral("title"), id},
          {QStringLiteral("worktreePath"), worktree ? QJsonValue(kWorktree) : QJsonValue::Null},
          {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")},
          {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}};
}

// The app as main.cpp wires it, on a fake MC with one project of three
// threads, and the MC's terminal manager.
struct Sut {
  QTemporaryDir home{QDir::tempPath() + QStringLiteral("/terminals-XXXXXX")};
  FakeMc mc;
  Terms terms;
  bool holding = false;
  QList<FakeMc::Rpc> held;
  std::unique_ptr<ShellBridge> bridge;
  std::unique_ptr<NativeShell> native;
  std::unique_ptr<prop::ModelMirror> mirror;
  std::unique_ptr<QSignalSpy> changed;
  QObject barrier;

  Sut() {
    mc.projects.insert(QStringLiteral("p1"), QJsonObject{{QStringLiteral("id"), QStringLiteral("p1")},
                                                         {QStringLiteral("title"), QStringLiteral("p1")},
                                                         {QStringLiteral("workspaceRoot"), kRoot},
                                                         {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                         {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                         {QStringLiteral("scripts"), QJsonArray()}});
    for (const QString& id : kThreads) mc.threads.insert(id, threadRow(id, false));
    mc.onShape(QStringLiteral("terminals"), [this](int id, const QJsonObject& shape) {
      if (shape.value(QLatin1String("environment")).toString() != mc.environmentId) {
        mc.forget(id);
        return;
      }
      QJsonArray list;
      for (auto it = terms.cbegin(); it != terms.cend(); ++it) list.append(summary(it.key()));
      mc.send({{QStringLiteral("t"), QStringLiteral("terminals")},
               {QStringLiteral("id"), id},
               {QStringLiteral("event"), QJsonObject{{QStringLiteral("type"), QStringLiteral("snapshot")}, {QStringLiteral("terminals"), list}}}});
    });
    // HalC2.Terminal.attach: a terminal that is not there opens when the input has a cwd.
    mc.onShape(QStringLiteral("terminal"), [this](int id, const QJsonObject& shape) {
      const QJsonObject input = shape.value(QLatin1String("input")).toObject();
      const QString key = keyOf(input.value(QLatin1String("threadId")).toString(), input.value(QLatin1String("terminalId")).toString());
      if (!terms.contains(key)) {
        if (!input.contains(QLatin1String("cwd"))) {
          mc.forget(id);
          mc.send({{QStringLiteral("t"), QStringLiteral("error")}, {QStringLiteral("id"), id}, {QStringLiteral("reason"), QStringLiteral("Unknown terminal")}});
          return;
        }
        terms.insert(key, {});
        sendTerminals({{QStringLiteral("type"), QStringLiteral("upsert")}, {QStringLiteral("terminal"), summary(key)}});
      }
      QJsonObject snapshot = summary(key);
      snapshot.insert(QStringLiteral("history"), terms.value(key).history);
      mc.send({{QStringLiteral("t"), QStringLiteral("terminal")},
               {QStringLiteral("id"), id},
               {QStringLiteral("event"), QJsonObject{{QStringLiteral("type"), QStringLiteral("snapshot")}, {QStringLiteral("snapshot"), snapshot}}}});
    });
    mc.onRpc(QStringLiteral("terminal.close"), [this](const FakeMc::Rpc& rpc) {
      if (holding) {
        held.append(rpc);
      } else {
        answerClose(rpc);
      }
    });
    const auto existing = [this](const FakeMc::Rpc& rpc) {
      if (terms.contains(keyOfRpc(rpc))) {
        mc.reply(rpc, QJsonValue::Null);
      } else {
        mc.refuse(rpc, QStringLiteral("Unknown terminal"));
      }
    };
    mc.onRpc(QStringLiteral("terminal.write"), existing);
    mc.onRpc(QStringLiteral("terminal.resize"), existing);
    start();
    open(kThreads.first());
    RC_ASSERT(sync());
    changed->clear();
  }

  ~Sut() {
    changed.reset();
    mirror.reset();
    native.reset();
    bridge.reset();
  }

  // As World::start, then connected and every controller started.
  void start() {
    bridge = std::make_unique<ShellBridge>();
    native = std::make_unique<NativeShell>(bridge.get());
    native->client()->setRetryDelays({20});
    native->setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")),
                         home.filePath(QStringLiteral("cache")));
    native->controller<SettingsController>()->setDevicePath(home.filePath(QStringLiteral("config/preferences.json")));
    native->controller<ToastController>()->setClock([] { return QDateTime(QDate(2026, 9, 23), QTime(10, 0), QTimeZone::UTC); });
    native->restoreWindows();
    native->open(mc.origin(), QStringLiteral("mc-token"));
    RC_ASSERT(prop::until([this] { return online(); }));
    mirror = std::make_unique<prop::ModelMirror>(terminals()->tabs());
    changed = std::make_unique<QSignalSpy>(terminals(), &TerminalController::changed);
  }

  bool online() const {
    if (!native->isActive() || !native->client()->isReady() || !mc.connected()) return false;
    return std::all_of(kThreads.cbegin(), kThreads.cend(), [this](const QString& id) { return native->store()->threadOnline(threadKeyOf(id)); });
  }

  TerminalController* terminals() const { return native->controller<TerminalController>(); }

  void open(const QString& thread) { bridge->dispatch(QStringLiteral("thread.open"), QVariantMap{{QStringLiteral("key"), threadKeyOf(thread)}}); }

  // Once this is back, what the client sent has reached the MC, and what the
  // MC sent before it (frames, answers) has been read; deleted sessions have
  // let go of their terminals.
  bool sync() {
    for (int round = 0; round < 2; ++round) {
      prop::settle();
      auto answered = std::make_shared<bool>(false);
      native->client()->call(&barrier, {}, QStringLiteral("test.barrier"), {},
                             [answered](const QJsonValue&, const std::optional<QString>&) { *answered = true; });
      if (!prop::until([&] { return *answered; })) return false;
    }
    prop::settle();
    return true;
  }

  static QString keyOfRpc(const FakeMc::Rpc& rpc) {
    return keyOf(rpc.payload.value(QLatin1String("threadId")).toString(), rpc.payload.value(QLatin1String("terminalId")).toString());
  }

  QJsonObject summary(const QString& key) const {
    const Term term = terms.value(key);
    return {{QStringLiteral("threadId"), threadOf(key)},
            {QStringLiteral("terminalId"), idOf(key)},
            {QStringLiteral("cwd"), kRoot},
            {QStringLiteral("status"), term.exited ? QStringLiteral("exited") : QStringLiteral("running")},
            {QStringLiteral("hasRunningSubprocess"), term.busy},
            {QStringLiteral("label"), term.label}};
  }

  void sendTerminal(const QString& key, const QJsonObject& event) {
    for (const int id : mc.subscribers(QStringLiteral("terminal"))) {
      const QJsonObject input = mc.shapeOf(id).value(QLatin1String("input")).toObject();
      if (keyOf(input.value(QLatin1String("threadId")).toString(), input.value(QLatin1String("terminalId")).toString()) != key) continue;
      mc.send({{QStringLiteral("t"), QStringLiteral("terminal")}, {QStringLiteral("id"), id}, {QStringLiteral("event"), event}});
    }
  }
  void sendTerminals(const QJsonObject& event) {
    for (const int id : mc.subscribers(QStringLiteral("terminals"))) {
      mc.send({{QStringLiteral("t"), QStringLiteral("terminals")}, {QStringLiteral("id"), id}, {QStringLiteral("event"), event}});
    }
  }

  void upsert(const QString& key) { sendTerminals({{QStringLiteral("type"), QStringLiteral("upsert")}, {QStringLiteral("terminal"), summary(key)}}); }

  // The terminal's shell is stopped: its sessions and the list hear of it.
  void close(const QString& key) {
    if (!terms.remove(key)) return;
    sendTerminal(key, {{QStringLiteral("type"), QStringLiteral("closed")}});
    sendTerminals({{QStringLiteral("type"), QStringLiteral("remove")},
                   {QStringLiteral("threadId"), threadOf(key)},
                   {QStringLiteral("terminalId"), idOf(key)}});
  }

  void answerClose(const FakeMc::Rpc& rpc) {
    close(keyOfRpc(rpc));
    mc.reply(rpc, QJsonValue::Null);
  }

  // The client's `terminal` subscriptions the MC holds, by key.
  QStringList attached() const {
    QStringList keys;
    for (const int id : mc.subscribers(QStringLiteral("terminal"))) {
      const QJsonObject input = mc.shapeOf(id).value(QLatin1String("input")).toObject();
      keys.append(keyOf(input.value(QLatin1String("threadId")).toString(), input.value(QLatin1String("terminalId")).toString()));
    }
    std::sort(keys.begin(), keys.end());
    return keys;
  }

  QList<Row> rows() const {
    QList<Row> out;
    for (const TerminalTabs::Row& tab : terminals()->tabs()->rows()) {
      Row row{tab.terminalId, tab.label, tab.busy, tab.group, tab.slot, tab.span, tab.vertical, tab.current};
      if (!tab.session) {
        row.transcript = QStringLiteral("<no session>");
      } else if (tab.session->terminalId() != tab.terminalId) {
        row.transcript = QStringLiteral("<the session of ") + tab.session->terminalId() + QLatin1Char('>');
      } else {
        row.transcript = tab.session->transcript();
      }
      if (tab.panel) row.group += QStringLiteral(" (panel)");
      out.append(row);
    }
    return out;
  }

  Facts facts() const {
    TerminalController* t = terminals();
    return {t->isOpen(), t->activeTerminalId(), t->activeGroup(), t->groupSizes()};
  }
};

void check(const Facts& before, const Model& expected, Sut& sut) {
  RC_ASSERT(sut.sync());
  RC_ASSERT(sut.terms == expected.mc);
  TerminalController* t = sut.terminals();
  RC_ASSERT(t->available());
  RC_ASSERT(t->threadKey() == threadKeyOf(expected.thread));
  RC_ASSERT(sut.rows() == expected.rows());
  const Facts now = expected.facts();
  RC_ASSERT(sut.facts() == now);
  // The drawer never shows a terminal that is not there.
  const QStringList ids = expected.ids(expected.thread);
  RC_ASSERT(now.active.isEmpty() || ids.contains(now.active));
  RC_ASSERT(!now.open || ids.contains(now.active));
  // The MC attaches what the client shows and keeps, nothing else.
  RC_ASSERT(sut.attached() == expected.live());
  RC_ASSERT(sut.changed->count() == (before == now ? 0 : 1));
  sut.changed->clear();
  const QStringList problems = sut.mirror->problems();
  RC_ASSERT(problems.isEmpty());
}

using Command = rc::state::Command<Model, Sut>;

// run() checks the copy of the model the command was applied to.
template <typename Self>
struct Step : Command {
  void run(const Model& before, Sut& sut) const override {
    Model expected = before;
    apply(expected);
    static_cast<const Self*>(this)->act(before, sut);
    check(before.facts(), expected, sut);
  }
};

// --- The user ----------------------------------------------------------------------

struct Show : Step<Show> {
  QString thread = *oneOf(kThreads);
  explicit Show(const Model&) {}
  void apply(Model& model) const override { model.refresh(thread); }
  void act(const Model&, Sut& sut) const { sut.open(thread); }
  void show(std::ostream& os) const override { os << "show " << thread.toStdString(); }
};

struct Toggle : Step<Toggle> {
  explicit Toggle(const Model&) {}
  void apply(Model& model) const override {
    Ui& u = model.ui[model.thread];
    u.open = !u.open;
    // A drawer with no terminal yet gets its first one.
    if (u.open && model.ids(model.thread).isEmpty()) {
      const QString id = model.nextId();
      model.opened(id);
    }
    model.sync();
  }
  void act(const Model&, Sut& sut) const { sut.bridge->dispatch(QStringLiteral("terminal.toggle")); }
  void show(std::ostream& os) const override { os << "toggle the drawer"; }
};

struct New : Step<New> {
  explicit New(const Model&) {}
  void apply(Model& model) const override {
    if (model.ids(model.thread).size() >= TerminalController::maxTerminals) return;
    model.openTerminal(model.nextId());
  }
  void act(const Model&, Sut& sut) const { sut.bridge->dispatch(QStringLiteral("terminal.new")); }
  void show(std::ostream& os) const override { os << "new terminal"; }
};

struct Select : Step<Select> {
  QString id = *oneOf(kIds);
  explicit Select(const Model&) {}
  void apply(Model& model) const override {
    if (model.ids(model.thread).contains(id)) model.openTerminal(id);
  }
  void act(const Model&, Sut& sut) const { sut.bridge->dispatch(QStringLiteral("terminal.select"), QVariantMap{{QStringLiteral("terminalId"), id}}); }
  void show(std::ostream& os) const override { os << "select " << id.toStdString(); }
};

struct Focus : Step<Focus> {
  QString id = *oneOf(kIds);
  explicit Focus(const Model&) {}
  void apply(Model& model) const override {
    if (!model.ids(model.thread).contains(id)) return;
    model.focused = id;
    model.ui[model.thread].active = id;
    model.sync();
  }
  void act(const Model&, Sut& sut) const { sut.terminals()->focusTerminal(id); }
  void show(std::ostream& os) const override { os << "focus " << id.toStdString(); }
};

struct Split : Step<Split> {
  // Empty: the focused or active one.
  QString id = *rc::gen::weightedOneOf<QString>({{2, rc::gen::just(QString())}, {3, oneOf(kIds)}});
  bool vertical = *rc::gen::arbitrary<bool>();
  explicit Split(const Model&) {}
  void apply(Model& model) const override {
    Ui& u = model.ui[model.thread];
    const QStringList ids = model.ids(model.thread);
    QString target = ids.contains(id) ? id : ids.contains(model.focused) ? model.focused : u.active;
    if (target.isEmpty() || !ids.contains(target)) {
      // A drawer with no terminal yet gets its first one, then the split.
      if (!ids.isEmpty()) return;
      target = model.nextId();
      model.opened(target);
      u.active = target;
    }
    Group* group = Model::groupOf(u, target);
    if ((group && group->terminals.size() >= TerminalController::maxPerGroup) || ids.size() >= TerminalController::maxTerminals) {
      model.sync();
      return;
    }
    const QString next = model.nextId();
    model.opened(next);
    if (!group) {
      u.groups.append({QStringLiteral("group-%1").arg(++model.groupCount), {target}, vertical, target});
      group = &u.groups.last();
    }
    group->terminals.insert(group->terminals.indexOf(target) + 1, next);
    group->vertical = vertical;
    group->active = next;
    u.active = next;
    u.open = true;
    model.sync();
  }
  void act(const Model&, Sut& sut) const {
    QVariantMap payload;
    if (!id.isEmpty()) payload.insert(QStringLiteral("terminalId"), id);
    sut.bridge->dispatch(vertical ? QStringLiteral("terminal.splitVertical") : QStringLiteral("terminal.split"), payload);
  }
  void show(std::ostream& os) const override {
    os << (vertical ? "split under " : "split beside ") << (id.isEmpty() ? std::string("the focused one") : id.toStdString());
  }
};

struct Close : Step<Close> {
  // Empty: the focused or active one, as a keybinding's.
  QString id = *rc::gen::weightedOneOf<QString>({{1, rc::gen::just(QString())}, {3, oneOf(kIds)}});
  explicit Close(const Model&) {}
  QString target(const Model& model) const {
    const QStringList ids = model.ids(model.thread);
    if (!id.isEmpty()) return ids.contains(id) ? id : QString();
    const QString fallback = ids.contains(model.focused) ? model.focused : model.ui.value(model.thread).active;
    return ids.contains(fallback) ? fallback : QString();
  }
  void apply(Model& model) const override {
    const QString closing = target(model);
    if (!closing.isEmpty()) model.close(closing);
  }
  void act(const Model& before, Sut& sut) const {
    QVariantMap payload;
    if (!id.isEmpty()) payload.insert(QStringLiteral("terminalId"), id);
    sut.bridge->dispatch(QStringLiteral("terminal.close"), payload);
    const QVariant question = sut.bridge->state()->value(QStringLiteral("confirmation"));
    // Closing asks first, and only when there is something to close.
    RC_ASSERT((question.typeId() == QMetaType::QVariantMap) == !target(before).isEmpty());
    if (question.typeId() != QMetaType::QVariantMap) return;
    sut.bridge->dispatch(QStringLiteral("confirmation.answer"), QVariantMap{{QStringLiteral("requestId"), question.toMap().value(QStringLiteral("requestId"))},
                                                                           {QStringLiteral("accepted"), true}});
  }
  void show(std::ostream& os) const override { os << "close " << (id.isEmpty() ? std::string("the focused one") : id.toStdString()); }
};

// --- The MC -------------------------------------------------------------------------

struct Hold : Step<Hold> {
  bool holding = *rc::gen::arbitrary<bool>();
  explicit Hold(const Model&) {}
  void apply(Model& model) const override { model.holding = holding; }
  void act(const Model&, Sut& sut) const { sut.holding = holding; }
  void show(std::ostream& os) const override { os << (holding ? "the MC holds closes" : "the MC answers closes"); }
};

struct AnswerClose : Step<AnswerClose> {
  int index = 0;
  explicit AnswerClose(const Model& model) {
    RC_PRE(!model.held.isEmpty());
    index = *rc::gen::inRange<int>(0, int(model.held.size()));
  }
  void checkPreconditions(const Model& model) const override { RC_PRE(index < model.held.size()); }
  void apply(Model& model) const override { model.closed(model.held.takeAt(index)); }
  void act(const Model&, Sut& sut) const { sut.answerClose(sut.held.takeAt(index)); }
  void show(std::ostream& os) const override { os << "the MC answers close #" << index; }
};

// A terminal of the thread on the MC, or one it does not have.
struct Pick {
  QString thread = *oneOf(kThreads);
  QString id = *oneOf(kIds);
  QString key() const { return keyOf(thread, id); }
};

struct Elsewhere : Step<Elsewhere> {
  QString thread = *oneOf(kThreads);
  explicit Elsewhere(const Model& model) { RC_PRE(model.terminalsOf(thread).size() < kIds.size()); }
  void checkPreconditions(const Model& model) const override { RC_PRE(model.terminalsOf(thread).size() < kIds.size()); }
  QString id(const Model& model) const {
    const QStringList taken = model.terminalsOf(thread);
    int next = 1;
    while (taken.contains(QStringLiteral("term-%1").arg(next))) ++next;
    return QStringLiteral("term-%1").arg(next);
  }
  void apply(Model& model) const override {
    model.mc.insert(keyOf(thread, id(model)), {});
    model.sync();
  }
  void act(const Model& before, Sut& sut) const {
    const QString key = keyOf(thread, id(before));
    sut.terms.insert(key, {});
    sut.upsert(key);
  }
  void show(std::ostream& os) const override { os << "another client opens a terminal of " << thread.toStdString(); }
};

struct Rename : Step<Rename>, Pick {
  QString label = *oneOf(kLabels);
  bool busy = *rc::gen::arbitrary<bool>();
  explicit Rename(const Model& model) { RC_PRE(model.mc.contains(key())); }
  void checkPreconditions(const Model& model) const override { RC_PRE(model.mc.contains(key())); }
  void apply(Model& model) const override {
    model.mc[key()].label = label;
    model.mc[key()].busy = busy;
    model.sync();
  }
  void act(const Model&, Sut& sut) const {
    sut.terms[key()].label = label;
    sut.terms[key()].busy = busy;
    sut.upsert(key());
  }
  void show(std::ostream& os) const override {
    os << key().toStdString() << " is labelled '" << label.toStdString() << "'" << (busy ? ", busy" : "");
  }
};

struct CloseElsewhere : Step<CloseElsewhere>, Pick {
  explicit CloseElsewhere(const Model& model) { RC_PRE(model.mc.contains(key())); }
  void checkPreconditions(const Model& model) const override { RC_PRE(model.mc.contains(key())); }
  void apply(Model& model) const override { model.gone(key()); }
  void act(const Model&, Sut& sut) const { sut.close(key()); }
  void show(std::ostream& os) const override { os << "another client closes " << key().toStdString(); }
};

struct Print : Step<Print>, Pick {
  explicit Print(const Model& model) { RC_PRE(model.mc.contains(key()) && !model.mc.value(key()).exited); }
  void checkPreconditions(const Model& model) const override { RC_PRE(model.mc.contains(key()) && !model.mc.value(key()).exited); }
  QString data(const Model& model) const { return QStringLiteral("out%1\r\n").arg(model.serial + 1); }
  void apply(Model& model) const override {
    const QString printed = data(model);
    ++model.serial;
    model.mc[key()].history += printed;
    if (model.screens.contains(key())) model.screens[key()] += printed;
  }
  void act(const Model& before, Sut& sut) const {
    sut.terms[key()].history += data(before);
    sut.sendTerminal(key(), {{QStringLiteral("type"), QStringLiteral("output")}, {QStringLiteral("data"), data(before)}});
  }
  void show(std::ostream& os) const override { os << key().toStdString() << " prints"; }
};

// Output of a terminal the MC no longer has, sent before its close.
struct LateOutput : Step<LateOutput>, Pick {
  explicit LateOutput(const Model& model) { RC_PRE(!model.mc.contains(key())); }
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.mc.contains(key())); }
  void apply(Model&) const override {}
  void act(const Model&, Sut& sut) const {
    sut.sendTerminal(key(), {{QStringLiteral("type"), QStringLiteral("output")}, {QStringLiteral("data"), QStringLiteral("late\r\n")}});
  }
  void show(std::ostream& os) const override { os << "late output of " << key().toStdString(); }
};

// The shell ended on its own; a shown terminal goes with it.
struct Exit : Step<Exit>, Pick {
  explicit Exit(const Model& model) { RC_PRE(model.mc.contains(key()) && !model.mc.value(key()).exited); }
  void checkPreconditions(const Model& model) const override { RC_PRE(model.mc.contains(key()) && !model.mc.value(key()).exited); }
  void apply(Model& model) const override {
    model.mc[key()].exited = true;
    if (model.screens.contains(key())) model.screens[key()] += kExited;
    if (thread == model.thread && model.attached && model.tabs.contains(id) && model.ids(thread).contains(id)) model.close(id);
  }
  void act(const Model&, Sut& sut) const {
    sut.terms[key()].exited = true;
    sut.sendTerminal(key(), {{QStringLiteral("type"), QStringLiteral("exited")}});
  }
  void show(std::ostream& os) const override { os << key().toStdString() << " exits"; }
};

struct Restart : Step<Restart>, Pick {
  explicit Restart(const Model& model) { RC_PRE(model.mc.contains(key())); }
  void checkPreconditions(const Model& model) const override { RC_PRE(model.mc.contains(key())); }
  void apply(Model& model) const override {
    model.mc[key()].history = kPrompt;
    model.mc[key()].exited = false;
    if (model.screens.contains(key())) model.screens[key()] = kPrompt;
  }
  void act(const Model&, Sut& sut) const {
    sut.terms[key()].history = kPrompt;
    sut.terms[key()].exited = false;
    QJsonObject snapshot = sut.summary(key());
    snapshot.insert(QStringLiteral("history"), kPrompt);
    sut.sendTerminal(key(), {{QStringLiteral("type"), QStringLiteral("restarted")}, {QStringLiteral("snapshot"), snapshot}});
  }
  void show(std::ostream& os) const override { os << key().toStdString() << " restarts"; }
};

// The thread moves to the worktree, or back to the project root.
struct Move : Step<Move> {
  QString thread = *oneOf(kThreads);
  explicit Move(const Model&) {}
  void apply(Model& model) const override {
    if (!model.worktree.remove(thread)) model.worktree.insert(thread);
    if (thread == model.thread) model.refresh(thread);
  }
  void act(const Model& before, Sut& sut) const {
    const QJsonObject row = threadRow(thread, !before.worktree.contains(thread));
    sut.mc.threads.insert(thread, row);
    sut.mc.sendRow(thread, row);
  }
  void show(std::ostream& os) const override { os << thread.toStdString() << " moves"; }
};

// The connection drops and comes back. The MC closes what it held; the client
// hears no answer, and every session starts over from its terminal's history.
struct Drop : Step<Drop> {
  explicit Drop(const Model&) {}
  void apply(Model& model) const override {
    for (const QString& key : std::as_const(model.held)) model.closed(key);
    model.held.clear();
    for (auto it = model.screens.begin(); it != model.screens.end(); ++it) it.value() = model.mc.value(it.key()).history;
  }
  void act(const Model&, Sut& sut) const {
    sut.mc.drop();
    for (const FakeMc::Rpc& rpc : std::as_const(sut.held)) sut.close(Sut::keyOfRpc(rpc));
    sut.held.clear();
    RC_ASSERT(prop::until([&] { return sut.online() && !sut.mc.subscribers(QStringLiteral("terminals")).isEmpty(); }));
  }
  void show(std::ostream& os) const override { os << "the connection drops"; }
};

}  // namespace

class WorkspaceTerminalProp : public QObject {
  Q_OBJECT

private slots:
  void terminals() {
    QVERIFY(rc::check("the drawer shows the shown thread's terminals as the MC has them, and attaches nothing else", [] {
      Sut sut;
      // Half as many steps: each starts a whole app, and a frame the MC sends
      // unasked costs a delayed ACK (~40 ms) before the next barrier returns.
      const auto commands = *rc::gen::scale(
          0.5, rc::state::gen::commands(Model(), rc::state::gen::execOneOfWithArgs<Show, Show, Toggle, New, New, Select, Focus, Split, Close,
                                                                                    Close, Hold, AnswerClose, Elsewhere, Rename, CloseElsewhere,
                                                                                    Print, LateOutput, Exit, Restart, Move, Drop>()));
      rc::state::runAll(commands, Model(), sut);
    }));
  }
};

HAL_C2_PROP_MAIN(WorkspaceTerminalProp)
#include "tst_WorkspaceTerminalProp.moc"
