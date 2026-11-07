// ThreadNoticeController as a state machine over which thread is open, the MC
// settling and un-settling threads and leaving background work running, the
// notice's Un-settle and Stop, and the MC's answers held, refused or late.
// The notice speaks for the open thread only: background work a finished turn
// left comes first (none while a turn runs) and reads "Stopping..." only
// while that thread's own stop is unanswered; then a settled thread, reading
// "Un-settling..." only while its own un-settle is unanswered. Each is sent
// once per thread at a time; a refused un-settle leaves the thread settled
// with one toast, a refused stop is the thread's error (ThreadErrorController)
// and Stop is offered again.

#include "Prop.h"

#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"

#include <QJsonArray>
#include <QSet>
#include <QTemporaryDir>

#include <memory>

namespace prop = halc2::prop;

namespace {

const QStringList kThreads = {QStringLiteral("t1"), QStringLiteral("t2")};
const QString kFailed = QStringLiteral("Failed to un-settle thread");
const QString kStopRefused = QStringLiteral("The provider session has already exited.");

QString keyOf(const QString& thread) { return QStringLiteral("env-a:") + thread; }

struct Model {
  QSet<QString> settled;
  // The open thread, empty when settings are open.
  QString open;
  bool holding = false;
  bool refusing = false;
  // Un-settles sent and not answered, by thread: whether the MC refuses it.
  QMap<QString, bool> pending;
  int sent = 0;
  int toasts = 0;
  // Background tasks the MC says each thread's turn left, and the threads
  // whose turn is running.
  QMap<QString, int> tasks;
  QSet<QString> running;
  bool refusingStop = false;
  // Stops sent and not answered, by thread: whether the MC refuses it.
  QMap<QString, bool> stopping;
  int interrupts = 0;
  // The threads a refused stop gave an error.
  QSet<QString> errors;
};

struct Shell {
  QTemporaryDir home;
  FakeMc mc;
  ShellBridge bridge;
  NativeShell native{&bridge};
  QSet<QString> failures;  // the failure toasts shown, by id

  Shell() {
    mc.projects.insert(QStringLiteral("p1"), QJsonObject{{QStringLiteral("id"), QStringLiteral("p1")},
                                                         {QStringLiteral("title"), QStringLiteral("Shop")},
                                                         {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")},
                                                         {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                         {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                         {QStringLiteral("scripts"), QJsonArray()}});
    for (qsizetype i = 0; i < kThreads.size(); ++i) {
      mc.threads.insert(kThreads.at(i), QJsonObject{{QStringLiteral("id"), kThreads.at(i)},
                                                    {QStringLiteral("projectId"), QStringLiteral("p1")},
                                                    {QStringLiteral("title"), QStringLiteral("Thread %1").arg(i + 1)},
                                                    {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                    {QStringLiteral("updatedAt"), QStringLiteral("2026-09-0%1T09:00:00Z").arg(2 - i)}});
    }
    // The MC's projection of an un-settle (orchestration.ex).
    mc.effects.append([this](const QJsonObject& command) {
      if (command.value(QLatin1String("type")) != QLatin1String("thread.unsettle")) return;
      setSettled(command.value(QLatin1String("threadId")).toString(), false);
    });
    QObject::connect(&bridge, &ShellBridge::stateEntryChanged, &bridge, [this](const QString& key, const QVariant& value) {
      if (key != QLatin1String("toasts")) return;
      for (const QVariant& item : value.toMap().value(QStringLiteral("items")).toList()) {
        if (item.toMap().value(QStringLiteral("title")) == kFailed) failures.insert(item.toMap().value(QStringLiteral("id")).toString());
      }
    });
    native.client()->setRetryDelays({20});
    native.setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")), home.filePath(QStringLiteral("cache")));
    native.controller<SettingsController>()->setDevicePath(home.filePath(QStringLiteral("preferences.json")));
    native.restoreWindows();
    native.open(mc.origin(), QStringLiteral("mc-token"));
    if (!prop::until([this] {
          return native.isActive() && native.store()->threadOnline(keyOf(QStringLiteral("t1"))) && native.store()->threadOnline(keyOf(QStringLiteral("t2")));
        })) {
      qFatal("the shell did not start");
    }
    native.controller<NavigationController>()->open(NavigationController::Route::settings());
  }

  void setSettled(const QString& thread, bool settled) {
    QJsonObject row = mc.threads.value(thread);
    if (settled) {
      row.insert(QStringLiteral("settledOverride"), QStringLiteral("settled"));
      row.insert(QStringLiteral("settledAt"), QStringLiteral("2026-09-23T09:40:00Z"));
    } else {
      row.remove(QStringLiteral("settledOverride"));
      row.remove(QStringLiteral("settledAt"));
    }
    mc.threads.insert(thread, row);
    mc.sendRow(thread, row);
  }

  // The MC's row says `thread`'s turn left `tasks` running, or is running.
  void setBackground(const QString& thread, int tasks, bool running) {
    QJsonObject row = mc.threads.value(thread);
    QJsonArray pending;
    for (int i = 1; i <= tasks; ++i) {
      pending.append(QJsonObject{{QStringLiteral("taskId"), QStringLiteral("task-%1").arg(i)}, {QStringLiteral("description"), QStringLiteral("Task %1").arg(i)}});
    }
    row.insert(QStringLiteral("pendingBackgroundTasks"), pending);
    row.insert(QStringLiteral("latestRunId"), QStringLiteral("run-1"));
    row.insert(QStringLiteral("activeRunId"), running ? QJsonValue(QStringLiteral("run-1")) : QJsonValue());
    mc.threads.insert(thread, row);
    mc.sendRow(thread, row);
  }

  int count(const QString& type) const {
    int n = 0;
    for (const QJsonObject& command : mc.commands) n += command.value(QLatin1String("type")) == type;
    return n;
  }

  int unsettles() const {
    int n = 0;
    for (const QJsonObject& command : mc.commands) n += command.value(QLatin1String("type")) == QLatin1String("thread.unsettle");
    return n;
  }

  QVariant notice() const { return bridge.state()->value(QStringLiteral("threadNotice")); }
  QVariant error() const { return bridge.state()->value(QStringLiteral("threadError")); }
};

bool hasBackground(const Model& model, const QString& thread) {
  return !thread.isEmpty() && model.tasks.value(thread) > 0 && !model.running.contains(thread);
}

QVariant expectedNotice(const Model& model) {
  if (hasBackground(model, model.open)) {
    const int tasks = model.tasks.value(model.open);
    QStringList names;
    for (int i = 1; i <= tasks; ++i) names.append(QStringLiteral("Task %1").arg(i));
    const bool busy = model.stopping.contains(model.open);
    return QVariantMap{{QStringLiteral("threadKey"), keyOf(model.open)},
                       {QStringLiteral("kind"), QStringLiteral("background")},
                       {QStringLiteral("title"), tasks == 1 ? QStringLiteral("Waiting on background task") : QStringLiteral("Waiting on %1 background tasks").arg(tasks)},
                       {QStringLiteral("description"), names.join(QStringLiteral(", "))},
                       {QStringLiteral("actionLabel"), busy ? QStringLiteral("Stopping...") : QStringLiteral("Stop")},
                       {QStringLiteral("busy"), busy}};
  }
  if (model.open.isEmpty() || !model.settled.contains(model.open)) return QVariant::fromValue(nullptr);
  const bool busy = model.pending.contains(model.open);
  return QVariantMap{{QStringLiteral("threadKey"), keyOf(model.open)},
                     {QStringLiteral("kind"), QStringLiteral("settled")},
                     {QStringLiteral("title"), QStringLiteral("This thread is settled")},
                     {QStringLiteral("description"), QStringLiteral("Send a message to unsettle")},
                     {QStringLiteral("actionLabel"), busy ? QStringLiteral("Un-settling...") : QStringLiteral("Un-settle")},
                     {QStringLiteral("busy"), busy}};
}

QVariant expectedError(const Model& model) {
  if (model.open.isEmpty() || !model.errors.contains(model.open)) return QVariant::fromValue(nullptr);
  return QVariantMap{{QStringLiteral("threadKey"), keyOf(model.open)}, {QStringLiteral("message"), kStopRefused}, {QStringLiteral("warning"), false}};
}

void check(const Model& model, Shell& shell) {
  const QVariant wanted = expectedNotice(model);
  const QVariant wantedError = expectedError(model);
  const auto same = [&] {
    const QVariant now = shell.notice();
    return wanted.isNull() ? now.isNull() : now == wanted;
  };
  const auto stored = [&] {
    for (const QString& thread : kThreads) {
      if (shell.native.store()->thread(keyOf(thread))->settledOverride.has_value() != model.settled.contains(thread)) return false;
    }
    return true;
  };
  const auto error = [&] {
    const QVariant now = shell.error();
    return wantedError.isNull() ? now.isNull() : now == wantedError;
  };
  RC_ASSERT(prop::until([&] {
    return same() && error() && stored() && shell.failures.size() == model.toasts && shell.unsettles() == model.sent &&
           shell.count(QStringLiteral("run.interrupt")) == model.interrupts;
  }));
}

using Command = rc::state::Command<Model, Shell>;

// The user opens a thread, or settings.
struct Open : Command {
  QString thread = *rc::gen::elementOf(std::vector<QString>{QString(), QStringLiteral("t1"), QStringLiteral("t2")});
  void apply(Model& model) const override { model.open = thread; }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.native.controller<NavigationController>()->open(thread.isEmpty() ? NavigationController::Route::settings()
                                                                           : NavigationController::Route::thread(keyOf(thread)));
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Open(" << (thread.isEmpty() ? "settings" : thread.toStdString()) << ")"; }
};

// The MC settles or un-settles a thread on its own (a merged pull request, a
// message sent from another client). Not while an un-settle of it waits: the
// model would have to know which lands last.
struct McSets : Command {
  QString thread = *rc::gen::elementOf(std::vector<QString>(kThreads.begin(), kThreads.end()));
  bool settled = *rc::gen::arbitrary<bool>();
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.pending.contains(thread)); }
  void apply(Model& model) const override {
    if (settled) model.settled.insert(thread);
    else model.settled.remove(thread);
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.setSettled(thread, settled);
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "McSets(" << thread.toStdString() << ", " << (settled ? "settled" : "active") << ")"; }
};

// The MC says a thread's turn left background work running, or that a turn
// of it is running (whose stop stops that work).
struct McBackground : Command {
  QString thread = *rc::gen::elementOf(std::vector<QString>(kThreads.begin(), kThreads.end()));
  int tasks = *rc::gen::inRange(0, 3);
  bool running = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override {
    model.tasks.insert(thread, tasks);
    if (running) model.running.insert(thread);
    else model.running.remove(thread);
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.setBackground(thread, tasks, running);
    check(expected, shell);
  }
  void show(std::ostream& os) const override {
    os << "McBackground(" << thread.toStdString() << ", " << tasks << (running ? ", running" : "") << ")";
  }
};

// The notice's Stop, clicked twice before the MC answers.
struct Stop : Command {
  void apply(Model& model) const override {
    if (!hasBackground(model, model.open) || model.stopping.contains(model.open)) return;
    ++model.interrupts;
    if (model.holding) {
      model.stopping.insert(model.open, model.refusingStop);
    } else if (model.refusingStop) {
      model.errors.insert(model.open);
    }
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.bridge.dispatch(QStringLiteral("threadNotice.stop"), {});
    shell.bridge.dispatch(QStringLiteral("threadNotice.stop"), {});
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Stop"; }
};

// The MC starts or stops refusing stops.
struct RefusingStop : Command {
  bool refusing = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override { model.refusingStop = refusing; }
  void run(const Model& model, Shell& shell) const override {
    if (refusing) shell.mc.refusals.insert(QStringLiteral("run.interrupt"), kStopRefused);
    else shell.mc.refusals.remove(QStringLiteral("run.interrupt"));
    Model expected = model;
    apply(expected);
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "RefusingStop(" << refusing << ")"; }
};

// The notice's Un-settle, clicked twice before the MC answers.
struct Unsettle : Command {
  void apply(Model& model) const override {
    if (model.open.isEmpty() || !model.settled.contains(model.open) || model.pending.contains(model.open)) return;
    ++model.sent;
    if (model.holding) {
      model.pending.insert(model.open, model.refusing);
    } else if (model.refusing) {
      ++model.toasts;
    } else {
      model.settled.remove(model.open);
    }
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.bridge.dispatch(QStringLiteral("threadNotice.unsettle"), {});
    shell.bridge.dispatch(QStringLiteral("threadNotice.unsettle"), {});
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Unsettle"; }
};

// The MC starts or stops refusing un-settles.
struct Refusing : Command {
  bool refusing = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override { model.refusing = refusing; }
  void run(const Model& model, Shell& shell) const override {
    if (refusing) shell.mc.refusals.insert(QStringLiteral("thread.unsettle"), QStringLiteral("The thread cannot be un-settled"));
    else shell.mc.refusals.remove(QStringLiteral("thread.unsettle"));
    Model expected = model;
    apply(expected);
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Refusing(" << refusing << ")"; }
};

// The MC starts holding its answers.
struct Hold : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(!model.holding); }
  void apply(Model& model) const override { model.holding = true; }
  void run(const Model& model, Shell& shell) const override {
    shell.mc.hold(QStringLiteral("answers"));
    Model expected = model;
    apply(expected);
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Hold"; }
};

// The MC answers what it held, and stops holding.
struct Answer : Command {
  void checkPreconditions(const Model& model) const override { RC_PRE(model.holding); }
  void apply(Model& model) const override {
    for (auto it = model.pending.cbegin(); it != model.pending.cend(); ++it) {
      if (it.value()) ++model.toasts;
      else model.settled.remove(it.key());
    }
    model.pending.clear();
    for (auto it = model.stopping.cbegin(); it != model.stopping.cend(); ++it) {
      if (it.value()) model.errors.insert(it.key());
    }
    model.stopping.clear();
    model.holding = false;
  }
  void run(const Model& model, Shell& shell) const override {
    Model expected = model;
    apply(expected);
    shell.mc.answerHeld();
    check(expected, shell);
  }
  void show(std::ostream& os) const override { os << "Answer"; }
};

}  // namespace

class ThreadNoticeProp : public QObject {
  Q_OBJECT

private slots:
  void backgroundNotice() {
    QVERIFY(rc::check("background work comes first, one stop at a time, a refused stop is the thread's error", [] {
      Shell shell;
      rc::state::check(Model{}, shell,
                       rc::state::gen::execOneOfWithArgs<Open, McSets, McBackground, McBackground, Unsettle, Stop, Stop, Refusing, RefusingStop, Hold, Answer>());
    }));
  }

  void settledNotice() {
    QVERIFY(rc::check("the notice speaks for the open thread, one un-settle at a time, a refusal leaves it settled", [] {
      Shell shell;
      rc::state::check(Model{}, shell, rc::state::gen::execOneOfWithArgs<Open, McSets, McSets, Unsettle, Unsettle, Refusing, Hold, Answer>());
    }));
  }
};

HAL_C2_PROP_MAIN(ThreadNoticeProp)
#include "tst_ThreadNoticeProp.moc"
