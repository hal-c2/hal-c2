// ThreadNoticeController as a state machine over which thread is open, the MC
// settling and un-settling threads, the notice's Un-settle and the MC's
// answers held, refused or late. The notice speaks for the open thread only:
// it shows while that thread is settled, reads "Un-settling..." only while
// that thread's own un-settle is unanswered, sends one un-settle per thread at
// a time, and a refused one leaves the thread settled with one toast.

#include "Prop.h"

#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"

#include <QSet>
#include <QTemporaryDir>

#include <memory>

namespace prop = halc2::prop;

namespace {

const QStringList kThreads = {QStringLiteral("t1"), QStringLiteral("t2")};
const QString kFailed = QStringLiteral("Failed to un-settle thread");

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

  int unsettles() const {
    int n = 0;
    for (const QJsonObject& command : mc.commands) n += command.value(QLatin1String("type")) == QLatin1String("thread.unsettle");
    return n;
  }

  QVariant notice() const { return bridge.state()->value(QStringLiteral("threadNotice")); }
};

QVariant expectedNotice(const Model& model) {
  if (model.open.isEmpty() || !model.settled.contains(model.open)) return QVariant::fromValue(nullptr);
  const bool busy = model.pending.contains(model.open);
  return QVariantMap{{QStringLiteral("threadKey"), keyOf(model.open)},
                     {QStringLiteral("kind"), QStringLiteral("settled")},
                     {QStringLiteral("title"), QStringLiteral("This thread is settled")},
                     {QStringLiteral("description"), QStringLiteral("Send a message to unsettle")},
                     {QStringLiteral("actionLabel"), busy ? QStringLiteral("Un-settling...") : QStringLiteral("Un-settle")},
                     {QStringLiteral("busy"), busy}};
}

void check(const Model& model, Shell& shell) {
  const QVariant wanted = expectedNotice(model);
  const auto same = [&] {
    const QVariant now = shell.notice();
    return wanted.isNull() ? now.isNull() : now == wanted;
  };
  RC_ASSERT(prop::until([&] { return same() && shell.failures.size() == model.toasts; }));
  RC_ASSERT(shell.unsettles() == model.sent);
  for (const QString& thread : kThreads) {
    RC_ASSERT(shell.native.store()->thread(keyOf(thread))->settledOverride.has_value() == model.settled.contains(thread));
  }
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
  void settledNotice() {
    QVERIFY(rc::check("the notice speaks for the open thread, one un-settle at a time, a refusal leaves it settled", [] {
      Shell shell;
      rc::state::check(Model{}, shell, rc::state::gen::execOneOfWithArgs<Open, McSets, McSets, Unsettle, Unsettle, Refusing, Hold, Answer>());
    }));
  }
};

HAL_C2_PROP_MAIN(ThreadNoticeProp)
#include "tst_ThreadNoticeProp.moc"
