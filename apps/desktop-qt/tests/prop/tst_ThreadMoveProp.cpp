// ThreadMenuController's move to another machine as a state machine over the
// thread's turn starting and stopping, the MC keeping the thread on its
// machine or letting it go, the move chosen from the thread's menu or the
// command palette, and the "Stop and move" question answered either way.
// A running turn is stopped only when the user accepted a question that was
// asked after the MC listed where the thread can go, so a thread the MC keeps
// is never stopped for a move it refuses; each refusal is one toast with the
// MC's message, and a stopped turn is followed by its move.

#include "Prop.h"

#include "CommandPaletteController.h"
#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ThreadMenuController.h"

#include <QJsonArray>
#include <QTemporaryDir>

namespace prop = halc2::prop;

namespace {

const QString kThread = QStringLiteral("t1");
const QString kKey = QStringLiteral("env-a:t1");
const QString kPeer = QStringLiteral("desktop");
const QString kFailed = QStringLiteral("Failed to move thread");
const QString kKept = QStringLiteral("Review was started by code-review, which keeps it on this machine.");
const QString kNotMoved = QStringLiteral("desktop is not taking threads.");

struct Model {
  bool running = false;
  bool kept = false;
  bool asking = false;  // "Stop and move" is on screen
  int interrupts = 0;
  int moves = 0;  // hal-c2.moveThread asked
  QStringList told;  // the failure toasts' messages, oldest first
};

struct Shell {
  QTemporaryDir home;
  FakeMc mc;
  ShellBridge bridge;
  NativeShell native{&bridge};
  bool kept = false;
  QStringList told;

  Shell() {
    mc.label = QStringLiteral("laptop");
    mc.join(kPeer);
    mc.projects.insert(QStringLiteral("p1"), QJsonObject{{QStringLiteral("id"), QStringLiteral("p1")},
                                                         {QStringLiteral("title"), QStringLiteral("Shop")},
                                                         {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")},
                                                         {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                         {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                         {QStringLiteral("scripts"), QJsonArray()}});
    mc.threads.insert(kThread, QJsonObject{{QStringLiteral("id"), kThread},
                                           {QStringLiteral("projectId"), QStringLiteral("p1")},
                                           {QStringLiteral("title"), QStringLiteral("Review")},
                                           {QStringLiteral("latestRunId"), QStringLiteral("r1")},
                                           {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                           {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")}});
    // HalC2.ThreadMove: a kept thread is refused before anything is listed or
    // moved; any other move this fake refuses too, so the thread stays put.
    mc.onRpc(QStringLiteral("hal-c2.moveDestinations"), [this](const FakeMc::Rpc& rpc) {
      if (kept) return mc.refuse(rpc, kKept);
      mc.reply(rpc, QJsonArray{QJsonObject{{QStringLiteral("machine"), kPeer},
                                           {QStringLiteral("environmentId"), kPeer},
                                           {QStringLiteral("online"), true},
                                           {QStringLiteral("projects"), QJsonArray()}}});
    });
    mc.onRpc(QStringLiteral("hal-c2.moveThread"), [this](const FakeMc::Rpc& rpc) { mc.refuse(rpc, kept ? kKept : kNotMoved); });
    mc.effects.append([this](const QJsonObject& command) {
      if (command.value(QLatin1String("type")) == QLatin1String("run.interrupt")) setRunning(false);
    });
    QObject::connect(&bridge, &ShellBridge::stateEntryChanged, &bridge, [this](const QString& key, const QVariant& value) {
      if (key != QLatin1String("toasts")) return;
      for (const QVariant& item : value.toMap().value(QStringLiteral("items")).toList()) {
        const QVariantMap toast = item.toMap();
        if (toast.value(QStringLiteral("title")) != kFailed || seen.contains(toast.value(QStringLiteral("id")).toString())) continue;
        seen.insert(toast.value(QStringLiteral("id")).toString());
        told.append(toast.value(QStringLiteral("description")).toString());
      }
    });
    native.client()->setRetryDelays({20});
    native.setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")), home.filePath(QStringLiteral("cache")));
    native.controller<SettingsController>()->setDevicePath(home.filePath(QStringLiteral("preferences.json")));
    native.restoreWindows();
    native.open(mc.origin(), QStringLiteral("mc-token"));
    if (!prop::until([this] {
          return native.isActive() && native.store()->thread(kKey) && native.store()->environments().contains(kPeer);
        })) {
      qFatal("the shell did not start");
    }
    native.controller<NavigationController>()->open(NavigationController::Route::thread(kKey));
  }

  void setRunning(bool running) {
    QJsonObject row = mc.threads.value(kThread);
    row.insert(QStringLiteral("activeRunId"), running ? QJsonValue(QStringLiteral("r1")) : QJsonValue());
    row.insert(QStringLiteral("status"), running ? QStringLiteral("running") : QStringLiteral("interrupted"));
    mc.threads.insert(kThread, row);
    mc.sendRow(kThread, row);
  }

  int count(const QString& type) const {
    int n = 0;
    for (const QJsonObject& command : mc.commands) n += command.value(QLatin1String("type")) == type;
    return n;
  }

  int moves() const {
    int n = 0;
    for (const FakeMc::Rpc& rpc : mc.calls) n += rpc.method == QLatin1String("hal-c2.moveThread");
    return n;
  }

  QVariant question() const { return bridge.state()->value(QStringLiteral("confirmation")); }
  bool asking() const { return question().toMap().value(QStringLiteral("title")).toString().startsWith(QLatin1String("Stop ")); }
  QVariantList menu() const { return bridge.state()->value(QStringLiteral("menu")).toMap().value(QStringLiteral("items")).toList(); }
  bool offers(const QString& id) const {
    return std::any_of(menu().cbegin(), menu().cend(), [&](const QVariant& item) { return item.toMap().value(QStringLiteral("id")) == id; });
  }
  void select(const QString& id) {
    bridge.dispatch(QStringLiteral("menu.select"),
                    QVariantMap{{QStringLiteral("requestId"), bridge.state()->value(QStringLiteral("menu")).toMap().value(QStringLiteral("requestId"))},
                                {QStringLiteral("id"), id}});
  }

  // A round trip through the MC: every answer it sent before has been handled.
  void sync() {
    bool done = false;
    native.client()->call(&native, mc.environmentId, QStringLiteral("test.barrier"), QJsonValue::Null,
                          [&done](const QJsonValue&, const std::optional<QString>&) { done = true; });
    RC_ASSERT(prop::until([&done] { return done; }));
  }

private:
  QSet<QString> seen;
};

void check(const Model& expected, Shell& shell) {
  const auto matches = [&] {
    return shell.asking() == expected.asking && shell.count(QStringLiteral("run.interrupt")) == expected.interrupts &&
           shell.moves() == expected.moves && shell.told == expected.told &&
           shell.native.store()->thread(kKey)->activeRunId.has_value() == expected.running;
  };
  prop::until(matches);
  shell.sync();
  RC_ASSERT(shell.asking() == expected.asking);
  RC_ASSERT(shell.count(QStringLiteral("run.interrupt")) == expected.interrupts);
  RC_ASSERT(shell.moves() == expected.moves);
  RC_ASSERT(shell.told == expected.told);
  RC_ASSERT(shell.native.store()->thread(kKey)->activeRunId.has_value() == expected.running);
}

using Command = rc::state::Command<Model, Shell>;

// A turn starts or ends in the thread, never under an open question.
struct Turn : Command {
  bool running = *rc::gen::arbitrary<bool>();
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.asking); }
  void apply(Model& model) const override { model.running = running; }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.setRunning(running);
    RC_ASSERT(prop::until([&] { return shell.native.store()->thread(kKey)->activeRunId.has_value() == running; }));
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Turn(" << running << ")"; }
};

// The MC starts or stops keeping the thread on its machine (a plugin's mark).
struct Keep : Command {
  bool kept = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override { model.kept = kept; }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.kept = kept;
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Keep(" << kept << ")"; }
};

// What choosing the machine leads to, once the MC has answered.
void chosen(Model& model) {
  if (!model.running) {
    ++model.moves;
    model.told.append(model.kept ? kKept : kNotMoved);
  } else if (model.kept) {
    model.told.append(kKept);
  } else {
    model.asking = true;
  }
}

// The user moves the thread to the other machine, from the thread's menu
// (which lists what the MC offers) or from the palette (which lists the
// cluster's machines without asking).
struct Move : Command {
  bool palette = *rc::gen::arbitrary<bool>();
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.asking); }
  void apply(Model& model) const override {
    if (!palette && model.kept) model.told.append(kKept);
    else chosen(model);
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    if (palette) {
      auto* commands = shell.native.controller<CommandPaletteController>();
      commands->show();
      commands->setQuery(QStringLiteral("Move to another machine"));
      RC_ASSERT(prop::until([commands] { return !commands->searching(); }));
      int row = 0;
      while (row < commands->count() && commands->idAt(row) != ThreadMenuController::kMove) ++row;
      RC_ASSERT(row < commands->count());
      commands->run(row);
      RC_ASSERT(commands->count() == 1);
      commands->run(0);
    } else {
      shell.bridge.dispatch(QStringLiteral("thread.menu"),
                            QVariantMap{{QStringLiteral("key"), kKey}, {QStringLiteral("x"), 40}, {QStringLiteral("y"), 120}});
      RC_ASSERT(prop::until([&] { return shell.offers(QStringLiteral("move")); }));
      shell.select(QStringLiteral("move"));
      if (!model.kept) {
        RC_ASSERT(prop::until([&] { return shell.offers(QStringLiteral("machine:") + kPeer); }));
        shell.select(QStringLiteral("machine:") + kPeer);
      }
    }
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Move(" << (palette ? "palette" : "menu") << ")"; }
};

// The user answers "Stop and move": a stop is followed by the move.
struct Answer : Command {
  bool accepted = *rc::gen::arbitrary<bool>();
  void checkPreconditions(const Model& model) const override { RC_PRE(model.asking); }
  void apply(Model& model) const override {
    model.asking = false;
    if (!accepted) return;
    ++model.interrupts;
    model.running = false;
    ++model.moves;
    model.told.append(model.kept ? kKept : kNotMoved);
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.bridge.dispatch(QStringLiteral("confirmation.answer"),
                          QVariantMap{{QStringLiteral("requestId"), shell.question().toMap().value(QStringLiteral("requestId"))},
                                      {QStringLiteral("accepted"), accepted}});
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Answer(" << accepted << ")"; }
};

}  // namespace

class ThreadMoveProp : public QObject {
  Q_OBJECT

private slots:
  void stopsOnlyWhatMayMove() {
    QVERIFY(rc::check("a turn is stopped only for a move the MC allowed, each refusal told once", [] {
      Shell shell;
      rc::state::check(Model{}, shell, rc::state::gen::execOneOfWithArgs<Turn, Keep, Move, Move, Answer>());
    }));
  }
};

HAL_C2_PROP_MAIN(ThreadMoveProp)
#include "tst_ThreadMoveProp.moc"
